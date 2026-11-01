// phone-dsh — :dsh unit test: the D6 boot_id shape.
// SPDX-License-Identifier: MIT

package com.phonedsh.dsh.host

import com.phonedsh.platform.testing.FakePlatform
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BootIdTest {
    @Test
    fun aBootIdIsExactly32LowercaseHexCharacters() {
        val pattern = Regex("^[0-9a-f]{32}$")
        repeat(256) {
            val id = BootId.generate()
            assertTrue("not 32 lowercase hex: \"$id\"", pattern.matches(id))
            assertEquals(BootId.LENGTH, id.length)
        }
    }

    @Test
    fun bootIdsDoNotCollideAcrossGenerations() {
        val seen = HashSet<String>()
        repeat(1_000) {
            assertTrue("boot id repeated after ${seen.size} draws", seen.add(BootId.generate()))
        }
    }

    @Test
    fun validationRejectsEverythingButTheExactShape() {
        assertTrue(BootId.isValid("00112233445566778899aabbccddeeff"))
        assertFalse(BootId.isValid("00112233445566778899AABBCCDDEEFF"))
        assertFalse(BootId.isValid("00112233445566778899aabbccddeef"))
        assertFalse(BootId.isValid("00112233445566778899aabbccddeeff0"))
        assertFalse(BootId.isValid("00112233445566778899aabbccddeefg"))
        assertFalse(BootId.isValid(""))
    }

    @Test
    fun aHostBootStampsTheInjectedClock() {
        val platform = FakePlatform(nowMillis = 1_700_000_000_000L)
        val boot = HostBoot.generate(platform)

        assertEquals(1_700_000_000_000L, boot.startedAtMillis)
        assertTrue(BootId.isValid(boot.bootId))
    }

    @Test
    fun aHostBootRefusesAMalformedId() {
        try {
            HostBoot(bootId = "not-a-boot-id", startedAtMillis = 0)
            fail("a malformed boot id should have been refused")
        } catch (expected: IllegalArgumentException) {
            // expected: the value is used as a filename component by the WAL lane.
        }
    }
}
