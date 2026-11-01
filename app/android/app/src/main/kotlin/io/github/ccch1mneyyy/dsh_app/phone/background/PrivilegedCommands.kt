package io.github.ccch1mneyyy.dsh_app.phone.background

/** Fixed commands only. APK paths come from ApplicationInfo, never a request. */
object PrivilegedCommands {
    private const val MAIN = "io.github.ccch1mneyyy.dsh_app.phone.background.PrivilegedDisplayMain"
    private const val PACKAGE = "io.github.ccch1mneyyy.dsh_app"
    private const val PERMISSION = "android.permission.WRITE_SECURE_SETTINGS"

    fun appProcess(sourceDir: String, splitSourceDirs: List<String> = emptyList()): String {
        val paths = listOf(sourceDir) + splitSourceDirs
        require(paths.all { it.startsWith('/') && '\u0000' !in it && ':' !in it })
        return "CLASSPATH=${quote(paths.joinToString(":"))} exec /system/bin/app_process /system/bin $MAIN"
    }

    fun grantSecureSettings(userId: Int): String {
        require(userId >= 0)
        return "exec /system/bin/pm grant --user $userId $PACKAGE $PERMISSION"
    }

    private fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"
}

/** -c takes exactly one shell command argument on Magisk, KernelSU and APatch. */
internal object RootCommands {
    fun appProcess(sourceDir: String, splitSourceDirs: List<String> = emptyList()): List<String> =
        listOf("su", "-c", PrivilegedCommands.appProcess(sourceDir, splitSourceDirs))
    fun grantSecureSettings(userId: Int): List<String> =
        listOf("su", "-c", PrivilegedCommands.grantSecureSettings(userId))
}
