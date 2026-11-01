package io.github.ccch1mneyyy.dsh_app.phone.background

import java.io.Closeable
import java.io.IOException
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Owns private pipes. Neither stderr contents nor arbitrary process errors escape this class. */
internal class RootProcess private constructor(private val process: Process) : Closeable {
    private val closed = AtomicBoolean(false)
    private val io = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-root-pipe").apply { isDaemon = true }
    }
    private var synced = false

    init {
        Thread({
            try {
                val buffer = ByteArray(4096)
                while (process.errorStream.read(buffer) >= 0) { /* discard, including authorization output */ }
            } catch (_: Exception) { }
        }, "dsh-root-stderr").apply { isDaemon = true; start() }
    }

    fun alive(): Boolean = !closed.get() && process.isAlive

    fun exchange(request: ByteArray, timeoutMs: Long): ByteArray = bounded(timeoutMs) {
        if (!synced) {
            if (!Frames.syncToMagic(process.inputStream)) throw IOException("rootStartFailed")
            synced = true
        }
        Frames.write(process.outputStream, request)
        Frames.read(process.inputStream) ?: throw IOException("rootDisconnected")
    }

    /** For the fixed, short-lived pm grant command; drain stdout without retaining it. */
    fun exitCode(timeoutMs: Long): Int = bounded(timeoutMs) {
        val buffer = ByteArray(4096)
        while (process.inputStream.read(buffer) >= 0) { }
        process.waitFor()
    }

    private fun <T> bounded(timeoutMs: Long, action: () -> T): T {
        if (closed.get()) throw IOException("rootDisconnected")
        val task = io.submit(Callable { action() })
        try {
            return task.get(timeoutMs.coerceAtLeast(1), TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            task.cancel(true); close(); throw IOException("rootTimeout")
        } catch (_: InterruptedException) {
            task.cancel(true); close(); Thread.currentThread().interrupt(); throw IOException("rootCancelled")
        } catch (_: Exception) {
            close(); throw IOException("rootStartFailed")
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        io.shutdownNow()
        // A blocked pipe close may wait on another reader. Cleanup is a daemon, so the
        // caller's deadline never waits on it. Killing su does not revoke manager consent
        // or promise to kill a daemon's descendants; stdin EOF also ends our server loop.
        Thread({
            runCatching { process.destroyForcibly() }
            runCatching { process.outputStream.close() }
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
        }, "dsh-root-close").apply { isDaemon = true; start() }
    }

    companion object {
        /** Only called by an explicit start/grant action, never a constructor or status read. */
        fun launch(command: List<String>, timeoutMs: Long,
                   spawn: (List<String>) -> Process = { ProcessBuilder(it).start() }): RootProcess {
            val cancelled = AtomicBoolean(false)
            val result = AtomicReference<RootProcess?>()
            val task = FutureTask {
                val channel = RootProcess(spawn(command))
                result.set(channel)
                if (cancelled.get()) { channel.close(); throw IOException("rootCancelled") }
                channel
            }
            Thread(task, "dsh-root-launch").apply { isDaemon = true; start() }
            try {
                return task.get(timeoutMs.coerceAtLeast(1), TimeUnit.MILLISECONDS)
            } catch (error: Exception) {
                cancelled.set(true); task.cancel(true); result.get()?.close()
                if (error is InterruptedException) Thread.currentThread().interrupt()
                throw IOException(when (error) {
                    is TimeoutException -> "rootTimeout"
                    is InterruptedException -> "rootCancelled"
                    else -> "rootStartFailed"
                })
            }
        }
    }
}
