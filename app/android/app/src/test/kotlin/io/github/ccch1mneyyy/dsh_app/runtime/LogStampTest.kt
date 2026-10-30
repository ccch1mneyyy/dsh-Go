package io.github.ccch1mneyyy.dsh_app.runtime

import java.time.ZoneId
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Test

class LogStampTest {
    @Test fun prefixesIsoTimeWithOffsetAndKeepsTheLine() {
        val line = "[dsh-app] resolv.conf: result=written"
        assertEquals("2023-11-14T22:13:20.123Z $line", LogStamp.fileLine(line, 1700000000123L, ZoneOffset.UTC))
        assertEquals("2023-11-15T06:13:20.123+08:00 $line", LogStamp.fileLine(line, 1700000000123L, ZoneId.of("Asia/Shanghai")))
    }

    @Test fun lineIsUntouchedAfterThePrefix() {
        val line = "  engine output with  spaces and 中文 "
        assertTrue(LogStamp.fileLine(line, 0L, ZoneOffset.UTC).endsWith(" $line"))
        assertEquals("1970-01-01T00:00:00.000Z ", LogStamp.fileLine("", 0L, ZoneOffset.UTC))
    }
}
