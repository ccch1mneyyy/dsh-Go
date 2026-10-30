package io.github.ccch1mneyyy.dsh_app.runtime

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Wall-clock prefix for lines written to `dsh.log` (issue #55): without it a diagnostics
 * bundle only shows order, not whether failures came in five minutes or over three hours.
 * Only the file gets it; the in-memory buffer and the `log` events keep the bare line,
 * because the app matches on their content.
 */
object LogStamp {
    private val FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSSXXX")

    fun fileLine(line: String, epochMs: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        FORMAT.format(Instant.ofEpochMilli(epochMs).atZone(zone)) + " " + line
}
