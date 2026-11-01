// Root app_process path. Magisk/KernelSU/APatch command syntax checked against upstream
// source; authorization UI, SELinux and display behavior have NOT been verified on devices.
package io.github.ccch1mneyyy.dsh_app.phone.background

import android.content.Context
import android.os.Bundle
import android.os.Process
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Call start/grant only from an explicit user action on the existing IO worker. */
class RootStarter(private val context: Context, private val onChanged: () -> Unit) {
    private val guard = Any()
    private val startLock = Any()
    private val state = RootState()
    private var channel: RootChannel? = null
    private var pending: RootProcess? = null

    /** No probing, execution, authorization or reconnection. */
    fun status(): RootStatus = synchronized(guard) {
        discardDead()
        state.status()
    }

    /** Tasks may reuse a previously prepared channel, but can never initiate su. */
    fun connect(): PrivilegedChannel? = synchronized(guard) {
        discardDead()
        channel
    }

    /** The only long-lived root launch entry. A lost connection needs another user action. */
    fun start(mayStart: () -> Boolean = { true }): PrivilegedChannel? = synchronized(startLock) start@ {
        // The caller's gate can be invalidated on the UI thread. Acceptance and ticket
        // creation must happen under the same guard used by disconnect, after any queue wait.
        // mayStart must be a quick state read, never a blocking authorization operation.
        val ticket = synchronized(guard) {
            discardDead()
            channel?.let { return@start if (mayStart()) it else null }
            state.beginIfAllowed(mayStart) ?: return@start null
        }
        onChanged()
        val stillAccepted = synchronized(guard) {
            if (state.current(ticket) && mayStart()) true
            else { if (state.current(ticket)) state.disconnect(); false }
        }
        if (!stillAccepted) return@start null
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(START_TIMEOUT_MS)
        var process: RootProcess? = null
        var failure: String? = null
        try {
            val info = context.applicationInfo
            process = RootProcess.launch(
                RootCommands.appProcess(info.sourceDir, info.splitSourceDirs?.toList().orEmpty()),
                remaining(deadline),
            )
            val accepted = synchronized(guard) {
                if (!state.current(ticket) || !mayStart()) false else { pending = process; true }
            }
            if (!accepted) {
                process.close()
                synchronized(guard) { if (state.current(ticket)) state.disconnect() }
                return@start null
            }
            val probe = Bundles.unmarshal(process.exchange(Bundles.marshal(Bundle().apply {
                putString(Proto.OP, Proto.OP_PROBE)
            }), remaining(deadline)))
            failure = when {
                !probe.getBoolean(Proto.OK) -> "rootStartFailed"
                !RootProbe.accepted(true, probe.getInt(Proto.UID, -1), probe.getString("revision"), Proto.REVISION) -> "rootIdentityMismatch"
                else -> null
            }
        } catch (error: Exception) {
            failure = reason(error)
        }
        val result = synchronized(guard) {
            if (pending === process) pending = null
            if (!mayStart()) {
                if (state.current(ticket)) state.disconnect()
                null
            } else if (state.finish(ticket, failure)) {
                if (failure == null && process != null) {
                    RootChannel(process) { failed -> channelFailed(process, failed) }.also { channel = it }
                } else null
            } else null
        }
        if (result == null) process?.close()
        onChanged()
        result
    }

    /** Fixed pm grant only. Requires an already prepared root connection; never calls start. */
    fun grantSecureSettings(): Boolean {
        if (connect() == null) return false
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(GRANT_TIMEOUT_MS)
        var grant: RootProcess? = null
        val ok = try {
            grant = RootProcess.launch(RootCommands.grantSecureSettings(Process.myUid() / 100000), remaining(deadline))
            grant.exitCode(remaining(deadline)) == 0
        } catch (_: Exception) { false }
        finally { grant?.close() }
        if (!ok) synchronized(guard) { state.note("rootGrantFailed") }
        onChanged()
        // The caller also checks the App's actual WRITE_SECURE_SETTINGS permission.
        return ok
    }

    fun disconnect() {
        synchronized(guard) {
            state.disconnect()
            pending?.close(); pending = null
            channel?.close(); channel = null
        }
        onChanged()
    }

    private fun discardDead() {
        if (channel?.alive() == false) {
            channel?.close(); channel = null
            state.disconnect()
        }
    }

    private fun channelFailed(process: RootProcess, failure: String) {
        synchronized(guard) {
            if (channel?.process !== process) return
            channel = null
            state.disconnect()
            state.note(failure)
        }
        onChanged()
    }

    companion object {
        /** App policy deadlines, not an upstream manager authorization-time guarantee. */
        const val START_TIMEOUT_MS = 30_000L
        const val GRANT_TIMEOUT_MS = 10_000L
        private fun remaining(deadline: Long): Long =
            TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime()).coerceAtLeast(1)
        private fun reason(error: Exception): String = when {
            error is IOException && error.message == "rootTimeout" -> "rootTimeout"
            error is IOException && error.message == "rootCancelled" -> "rootCancelled"
            else -> "rootStartFailed"
        }
    }
}

private class RootChannel(
    val process: RootProcess,
    private val onFailure: (String) -> Unit,
) : PrivilegedChannel {
    override fun alive(): Boolean = process.alive()
    override fun close() = process.close()
    override fun execute(request: Bundle): Bundle = try {
        Bundles.unmarshal(process.exchange(Bundles.marshal(request), 30_000))
    } catch (error: Exception) {
        val timeout = error is IOException && error.message == "rootTimeout"
        process.close()
        onFailure(if (timeout) "rootTimeout" else "rootDisconnected")
        Bundle().apply {
            putBoolean(Proto.OK, false)
            putString(Proto.ERROR, if (timeout) "timeout" else "deviceUnavailable")
        }
    }
}
