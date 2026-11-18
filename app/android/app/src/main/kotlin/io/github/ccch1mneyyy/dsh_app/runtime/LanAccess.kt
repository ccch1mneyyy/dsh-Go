package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * An explicit, opt-in LAN entry to the loopback-only DSH server. Raw TCP keeps
 * the browser's Host and Origin intact; DSH accepts the selected authority via
 * `--trusted-host`. Only a concrete private Wi-Fi IPv4 is ever exposed.
 */
internal class LanAccess(private val context: Context) {
    data class Endpoint(val host: String, val port: Int) {
        val authority: String get() = "$host:$port"
        val baseUrl: String get() = "http://$authority/"
    }

    class Unavailable(message: String) : IllegalStateException(message)

    private val lock = Any()
    private var server: ServerSocket? = null
    private var endpoint: Endpoint? = null
    private var token: String? = null
    private val connections = mutableSetOf<Socket>()
    private val workers = Executors.newCachedThreadPool { runnable -> Thread(runnable, "dsh-lan-forward").apply { isDaemon = true } }

    val current: Endpoint? get() = synchronized(lock) { endpoint }

    /** Picks the stable IPv4 of the default Wi-Fi network; fail closed otherwise. */
    fun address(): String {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val wifi = manager.allNetworks.asSequence().mapNotNull { network ->
            val capabilities = manager.getNetworkCapabilities(network)
            val properties = manager.getLinkProperties(network)
            if (capabilities != null && properties != null && isPrivateWifi(capabilities, properties)) {
                properties.linkAddresses.mapNotNull { it.address?.hostAddress }
            } else null
        }.firstOrNull() ?: throw Unavailable("lan access needs an active private Wi-Fi IPv4 address")
        return try {
            LaunchFlags.lanAddress(wifi)
        } catch (error: IllegalArgumentException) {
            throw Unavailable(error.message ?: "lan access needs a private Wi-Fi IPv4 address")
        }
    }

    /** A VPN may carry WIFI|VPN transports; only a wlan interface's own route is a LAN address. */
    private fun isPrivateWifi(capabilities: NetworkCapabilities, properties: LinkProperties): Boolean =
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
            properties.interfaceName?.startsWith("wlan") == true

    /** Checks that [port] is free on the selected address before DSH launches. */
    fun reserve(port: Int): Endpoint {
        val host = address()
        val socket = try {
            ServerSocket(port, 32, InetAddress.getByName(host))
        } catch (error: Exception) {
            throw Unavailable("could not listen on $host:$port for LAN access")
        }
        val next = Endpoint(host, socket.localPort)
        runCatching { socket.close() }
        return next
    }

    /** Binds the reserved concrete address and starts forwarding to loopback. */
    fun openBound(host: String, port: Int): Endpoint {
        close()
        if (address() != host) throw Unavailable("LAN address is no longer on the active Wi-Fi network")
        val socket = try {
            ServerSocket(port, 32, InetAddress.getByName(host))
        } catch (error: Exception) {
            throw Unavailable("could not listen on $host:$port for LAN access")
        }
        val next = Endpoint(host, socket.localPort)
        synchronized(lock) {
            server = socket
            endpoint = next
        }
        thread(name = "dsh-lan-accept", isDaemon = true) {
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                if (!forward(socket, client, port)) client.close()
            }
        }
        return next
    }

    fun setToken(value: String?) {
        synchronized(lock) { token = value }
    }

    private fun forward(owner: ServerSocket, client: Socket, port: Int): Boolean {
        client.soTimeout = 10_000
        val upstream = try {
            Socket().also { it.connect(InetSocketAddress("127.0.0.1", port), 3000) }
        } catch (_: Exception) {
            return false
        }
        val accepted = synchronized(lock) {
            if (server !== owner) false
            else {
                connections += client
                connections += upstream
                true
            }
        }
        if (!accepted) {
            runCatching { client.close() }
            runCatching { upstream.close() }
            return false
        }
        return try {
            workers.submit { pump(owner, client, upstream) }
            true
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            synchronized(lock) {
                connections -= client
                connections -= upstream
            }
            runCatching { client.close() }
            runCatching { upstream.close() }
            false
        }
    }

    private fun pump(owner: ServerSocket, client: Socket, upstream: Socket) {
        val clientInput = client.getInputStream()
        val clientOutput = client.getOutputStream()
        val upstreamInput = upstream.getInputStream()
        val upstreamOutput = upstream.getOutputStream()
        val done = AtomicBoolean(false)
        val closeBoth = {
            if (done.compareAndSet(false, true)) {
                synchronized(lock) {
                    connections -= client
                    connections -= upstream
                }
                runCatching { client.close() }
                runCatching { upstream.close() }
            }
        }
        fun copy(input: InputStream, output: java.io.OutputStream, initial: ByteArray = ByteArray(0)) {
            try {
                if (initial.isNotEmpty()) {
                    output.write(initial)
                    output.flush()
                }
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    output.flush()
                }
            } catch (_: Exception) {
            } finally {
                closeBoth()
            }
        }
        try {
            val head = readRequestHead(clientInput)
            client.soTimeout = 0
            if (head.tooLong) {
                writeResponse(clientOutput, LanLogin.requestTooLarge())
                return
            }
            if (LanLogin.isLoginRequest(head.line)) {
                val snapshot = synchronized(lock) {
                    if (server === owner) Triple(endpoint?.authority, token, true)
                    else Triple(null, null, false)
                }
                val response = if (snapshot.third) {
                    LanLogin.redirect(snapshot.first, snapshot.second) ?: LanLogin.unavailable()
                } else LanLogin.unavailable()
                writeResponse(clientOutput, response)
                return
            }
            val toUpstream = java.util.concurrent.FutureTask { copy(clientInput, upstreamOutput, head.bytes) }
            val toClient = java.util.concurrent.FutureTask { copy(upstreamInput, clientOutput) }
            thread(name = "dsh-lan-up", isDaemon = true, block = toUpstream::run)
            thread(name = "dsh-lan-down", isDaemon = true, block = toClient::run)
            toUpstream.get()
            toClient.get()
        } catch (_: Exception) {
        } finally {
            closeBoth()
        }
    }

    private data class Head(val line: String?, val bytes: ByteArray, val tooLong: Boolean)

    private fun readRequestHead(input: InputStream): Head {
        val buffer = ByteArrayOutputStream()
        var previous = -1
        while (buffer.size() < LanLogin.MAX_REQUEST_LINE) {
            val value = input.read()
            if (value < 0) break
            buffer.write(value)
            if (previous == '\r'.code && value == '\n'.code) {
                val bytes = buffer.toByteArray()
                val line = String(bytes, 0, bytes.size - 2, StandardCharsets.US_ASCII)
                return Head(line, bytes, false)
            }
            previous = value
        }
        return Head(null, buffer.toByteArray(), buffer.size() >= LanLogin.MAX_REQUEST_LINE)
    }

    private fun writeResponse(output: java.io.OutputStream, response: String) {
        output.write(response.toByteArray(StandardCharsets.US_ASCII))
        output.flush()
    }

    fun close() {
        val (socket, active) = synchronized(lock) {
            endpoint = null
            token = null
            val old = server
            server = null
            old to connections.toList().also { connections.clear() }
        }
        active.forEach { runCatching { it.close() } }
        runCatching { socket?.close() }
    }
}
