package io.github.ccch1mneyyy.dsh_app.phone.shell

import android.content.Context
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.concurrent.thread

/**
 * The root channel: the same [AndroidShellMain] host the self-ADB path runs, started by the
 * device's root manager. Only the fixed launch line goes through su; command text never does.
 * The grant in the manager is the only authorization, and every command still needs the
 * normal per-command confirmation.
 */
internal class ShellRootBackend(private val context: Context, private val onChanged: () -> Unit) {
    private val guard = Any()
    @Volatile private var channel: ShellLink? = null
    @Volatile private var pending: Process? = null
    private var generation = 0L
    private var busy = false
    @Volatile private var lastFailure: String? = null

    fun status(): Map<String, Any?> = synchronized(guard) {
        mapOf("connected" to (channel?.alive() == true), "reasonCode" to lastFailure)
    }

    /** Explicit setup only: status never prompts. su may wait for the person's answer. */
    fun connect(wanted: () -> Boolean): ShellConnection {
        channel?.takeIf { it.alive() }?.let { return ShellConnection(it) }
        val ticket = begin() ?: return ShellConnection(errorCode = "busy")
        var candidate: ShellLink? = null
        var published = false
        return try {
            if (!wanted()) return ShellConnection(errorCode = "cancelled")
            val info = context.applicationInfo
            val classpath = (listOf(info.sourceDir) + info.splitSourceDirs.orEmpty()).joinToString(":")
            require(classpath.isNotBlank() && '\u0000' !in classpath)
            val quoted = "'" + classpath.replace("'", "'\\''") + "'"
            val process = try {
                ProcessBuilder(
                    "su", "-c",
                    "CLASSPATH=$quoted exec /system/bin/app_process /system/bin ${AndroidShellMain::class.java.name}",
                ).start()
            } catch (_: Exception) {
                fail(ticket, null, "rootMissing")
                return ShellConnection(errorCode = "rootMissing")
            }
            synchronized(guard) {
                if (!valid(ticket) || !wanted()) { process.destroyForcibly(); return ShellConnection(errorCode = "cancelled") }
                pending = process
            }
            // su and the manager write here too (authorization prompts included): drain it so
            // the pipe never fills, keep nothing.
            thread(isDaemon = true, name = "dsh-shell-root-stderr") {
                runCatching { val buffer = ByteArray(4096); while (process.errorStream.read(buffer) >= 0) { } }
            }
            val io = Executors.newSingleThreadExecutor { task ->
                Thread(task, "dsh-shell-root-start").apply { isDaemon = true }
            }
            try {
                io.submit { ShellWire.sync(process.inputStream) }.get(START_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: TimeoutException) {
                fail(ticket, process, "rootTimeout")
                return ShellConnection(errorCode = "rootTimeout")
            } catch (_: Exception) {
                // A declined or failed su exits before the magic reaches us.
                fail(ticket, process, if (process.isAlive) "rootStartFailed" else "rootDenied")
                return ShellConnection(errorCode = if (process.isAlive) "rootStartFailed" else "rootDenied")
            } finally {
                io.shutdownNow()
            }
            candidate = ShellLink.root(process, synced = true)
            if (!candidate.probe()) {
                fail(ticket, process, "identityChanged")
                return ShellConnection(errorCode = "identityChanged")
            }
            synchronized(guard) {
                if (!valid(ticket) || !wanted()) return ShellConnection(errorCode = "cancelled")
                pending = null
                channel = candidate
                lastFailure = null
                published = true
            }
            ShellConnection(candidate)
        } catch (_: Exception) {
            ShellConnection(errorCode = "connectFailed")
        } finally {
            if (!published) candidate?.close()
            finish()
            onChanged()
        }
    }

    fun disconnect() {
        val current = synchronized(guard) {
            ++generation
            channel?.close()
            channel = null
            pending?.also { it.destroyForcibly() }
        }
        if (current != null) onChanged()
    }

    private fun begin(): Long? = synchronized(guard) {
        if (busy) null else { busy = true; generation }
    }

    private fun valid(ticket: Long): Boolean = synchronized(guard) { generation == ticket }

    private fun finish() = synchronized(guard) { busy = false }

    private fun fail(ticket: Long, process: Process?, code: String) {
        process?.destroyForcibly()
        synchronized(guard) {
            if (generation == ticket) lastFailure = code
            pending = null
        }
    }

    private companion object {
        // su shows the manager's own prompt; a person may take a while to answer it.
        const val START_TIMEOUT_MS = 90_000L
    }
}
