package io.github.ccch1mneyyy.dsh_app.phone.background

/** Fixed request shape for the app-hosted self-check tap. */
internal object SelfCheckTapRequest {
    private val fields = setOf(Proto.OP, Proto.OWNER, Proto.DISPLAY_ID, Proto.X, Proto.Y, Proto.TIME)
    private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun owner(keys: Set<String>, value: (String) -> Any?): String? {
        if (keys != fields) return null
        if (value(Proto.OP) != Proto.OP_SELF_CHECK_TAP) return null
        if (value(Proto.DISPLAY_ID) !is Int || value(Proto.X) !is Int || value(Proto.Y) !is Int ||
            value(Proto.TIME) !is Long) return null
        val owner = value(Proto.OWNER) as? String ?: return null
        return owner.takeIf { uuid.matches(it) }
    }
}
