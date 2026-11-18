package io.github.ccch1mneyyy.dsh_app.runtime

/** The LAN entry's short login URL, kept separate from the raw TCP forwarder. */
internal object LanLogin {
    const val MAX_REQUEST_LINE = 8192

    private val REQUEST = Regex("""GET /login HTTP/1\.[01]""")
    private val TOKEN = Regex("""[A-Za-z0-9_-]+""")

    fun isLoginRequest(line: String?): Boolean = line != null && REQUEST.matches(line)

    fun tokenUrl(authority: String?, token: String?): String? {
        if (authority == null || token == null || !TOKEN.matches(token)) return null
        if (LaunchFlags.authorityPort(authority) == null) return null
        return "http://$authority/?token=$token"
    }

    fun redirect(authority: String?, token: String?): String? {
        val target = tokenUrl(authority, token) ?: return null
        return response("302 Found", target)
    }

    fun unavailable(): String = response("503 Service Unavailable")
    fun requestTooLarge(): String = response("414 URI Too Long")

    private fun response(status: String, location: String? = null): String {
        val headers = StringBuilder("HTTP/1.1 $status\r\n")
        if (location != null) headers.append("Location: $location\r\n")
        headers.append("Cache-Control: no-store\r\n")
        headers.append("Referrer-Policy: no-referrer\r\n")
        headers.append("Connection: close\r\nContent-Length: 0\r\n\r\n")
        return headers.toString()
    }
}
