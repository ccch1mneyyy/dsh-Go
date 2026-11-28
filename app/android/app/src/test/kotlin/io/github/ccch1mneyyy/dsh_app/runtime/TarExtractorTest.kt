package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files

class TarExtractorTest {
    @Test fun zeroPagesBecomeHolesWithoutChangingContentOrLength() {
        // Zero pages inside and across the 64 KiB copy chunk, a page that is zero but for its last
        // byte; one file ends in an unaligned tail, the other in a run of zero pages.
        val unaligned = ByteArray(3 * 65_536 + 12_345).also { it[5_000] = 1; it[65_536 + 4_095] = 2; it[131_072 + 7] = 3 }
        val trailing = ByteArray(3 * 65_536 + 8_192).also { it[70_000] = 4 }
        val tar = entry("a", unaligned) + entry("b", trailing) + ByteArray(1024)
        val dir = Files.createTempDirectory("tar-test").toFile()
        try {
            TarExtractor(dir) {}.extractDecoded(ByteArrayInputStream(tar))
            assertArrayEquals(unaligned, File(dir, "a").readBytes())
            assertArrayEquals(trailing, File(dir, "b").readBytes())
            // On Linux (CI, GNU stat): b's two non-zero pages are all that is allocated.
            if (System.getProperty("os.name") == "Linux") {
                val blocks = ProcessBuilder("/usr/bin/stat", "-c", "%b", File(dir, "b").path).start()
                    .inputStream.bufferedReader().readText().trim().toLong()
                assertTrue("$blocks blocks", blocks * 512 <= 4 * 4096)
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun entry(name: String, data: ByteArray): ByteArray {
        val header = ByteArray(512)
        name.toByteArray().copyInto(header, 0)
        "0000644\u0000".toByteArray().copyInto(header, 100)
        "%011o\u0000".format(data.size).toByteArray().copyInto(header, 124)
        header[156] = '0'.code.toByte()
        "ustar\u0000".toByteArray().copyInto(header, 257)
        return header + data + ByteArray((512 - data.size % 512) % 512)
    }
}
