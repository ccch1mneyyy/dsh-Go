package io.github.ccch1mneyyy.dsh_app.runtime

/** Launch-template edits shared by proot and direct engine. Pure JVM/testable. */
internal object LaunchFlags {
    private val IPV4_HOST_PORT = Regex("""((?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)):(\d{1,5})""")
    private val TEMPLATE = Regex("""echo \$\$ > /tmp/dsh-web\.pid; exec /usr/local/bin/dsh [^\n]*""")

    /** Pure address selection used by the native LAN entry and its JVM tests. */
    fun lanAddress(addresses: List<String>): String = addresses.asSequence()
        .mapNotNull { runCatching { java.net.InetAddress.getByName(it) }.getOrNull() }
        .filterIsInstance<java.net.Inet4Address>()
        .firstOrNull { it.isSiteLocalAddress && !it.isLoopbackAddress && !it.isLinkLocalAddress && !it.isMulticastAddress }
        ?.hostAddress ?: throw IllegalArgumentException("lan access needs a private Wi-Fi IPv4 address")

    /** A canonical private IPv4 authority, or null. Used by the direct launch gate. */
    fun authorityPort(authority: String): Int? {
        val match = IPV4_HOST_PORT.matchEntire(authority) ?: return null
        val address = runCatching { java.net.InetAddress.getByName(match.groupValues[1]) }.getOrNull()
            ?: return null
        if (!address.isSiteLocalAddress || address.isLoopbackAddress || address.isLinkLocalAddress ||
            address.isMulticastAddress) return null
        return match.groupValues[2].toIntOrNull()?.takeIf { it in 1..65535 }
    }

    /** Adds one concrete host:port to the `dsh web` arguments; refuses an unknown template. */
    fun trustedHost(argument: String, authority: String): String {
        val port = authorityPort(authority) ?: throw IllegalArgumentException("invalid LAN authority")
        require(!argument.contains("--trusted-host")) { "unsupported trusted-host launch template" }
        val launch = TEMPLATE.find(argument)?.value
            ?: throw IllegalArgumentException("unsupported trusted-host launch template")
        DirectLaunch.webArguments(launch)
        require(!launch.contains("--profile")) { "safe mode cannot use LAN access" }
        require(launch.contains("--port $port")) { "LAN authority does not match the engine port" }
        return argument.replaceRange(launch.indices, launch + " --trusted-host $authority")
    }

    /** Expands placeholders first; the boolean says whether this argument got the trusted host. */
    fun compose(argument: String, authority: String?, expand: (String) -> String): Pair<String, Boolean> {
        val expanded = expand(argument)
        if (authority == null || !TEMPLATE.containsMatchIn(expanded)) return expanded to false
        return trustedHost(expanded, authority) to true
    }
}
