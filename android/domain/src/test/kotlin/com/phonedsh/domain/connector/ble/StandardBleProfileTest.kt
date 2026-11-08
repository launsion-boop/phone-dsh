// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import com.phonedsh.domain.testing.MiniJson
import java.nio.file.Path
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class StandardBleProfileTest {
    private val root = Path.of(System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set"))

    private fun hex(text: String): ByteArray = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun sharedVectorsDriveTheRealDecoder() {
        val rows = root.resolve("spec/device/v1/golden/standard-gatt-decode.jsonl").toFile()
            .readLines().filter { it.isNotBlank() }.map(MiniJson::parseObject)
        var valid = 0
        var invalid = 0
        for (row in rows) {
            val level = row["alertLevel"]
            if (level != null) {
                val n = (level as Number).toInt()
                if (row.containsKey("error")) {
                    try { StandardBleProfile.alertCommand(n); fail("level $n accepted") } catch (_: StandardBleFailure) { invalid++ }
                } else {
                    assertArrayEquals(hex(row.getValue("hex") as String), StandardBleProfile.alertCommand(n)); valid++
                }
                continue
            }
            val profile = StandardBleProfile.entries.single { it.rawValue == row.getValue("profile") }
            val data = hex(row.getValue("hex") as String)
            if (row.containsKey("error")) {
                try {
                    val got = profile.decode(data)
                    fail("$profile ${row["hex"]} decoded to $got, expected ${row["error"]}")
                } catch (_: StandardBleFailure) { invalid++ }
            } else {
                assertEquals("$profile ${row["hex"]}", row.getValue("value"), profile.decode(data)); valid++
            }
        }
        // A truncated or valid-only fixture must not turn this green.
        assertTrue("valid=$valid", valid >= 14)
        assertTrue("invalid=$invalid", invalid >= 16)
    }

    @Test
    fun uuidsAreTheSigPairs() {
        assertEquals("0000180f-0000-1000-8000-00805f9b34fb", StandardBleProfile.BATTERY.service.toString())
        assertEquals(StandardBleProfile.ALERT, StandardBleProfile.matching(StandardBleProfile.ALERT.service, StandardBleProfile.ALERT.characteristic))
        assertEquals(null, StandardBleProfile.matching(StandardBleProfile.BATTERY.service, StandardBleProfile.MODEL.characteristic))
    }
}
