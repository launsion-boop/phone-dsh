// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/**
 * Runs every `user-action-transaction.phone.json` case through the real
 * Kotlin user-action transaction and outbox.
 */
class BotUserActionTransactionVectorTest {
    @Test
    fun everySharedUserActionVectorRunsThroughTheRealTransaction() {
        val fixture = GoldenFixture.rawObject("user-action-transaction.phone")
        val valid = GoldenFixture.objects(fixture, "valid")
        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("user-action-transaction.phone.valid must not be empty", valid.isNotEmpty())
        assertTrue("user-action-transaction.phone.invalid must not be empty", invalid.isNotEmpty())

        val directory = Files.createTempDirectory("bot-action-vectors").toFile()
        var validCount = 0
        var invalidCount = 0
        var steps = 0
        try {
            for (group in listOf(true to valid, false to invalid)) {
                for ((index, value) in group.second.withIndex()) {
                    val testCase = value as? JsonObject
                        ?: throw AssertionError("case[$index] is not an object")
                    val name = GoldenFixture.string(testCase, "name")
                        ?: throw AssertionError("case[$index] has no name")
                    steps += GoldenFixture.objects(testCase, "steps").size
                    val file = directory.toPath().resolve(
                        "${name.replace('/', '-')}-${index}-${System.nanoTime()}.sqlite",
                    )
                    val runner = BotStoreVectorRunner(
                        driverFactory = { SqliteJdbcDriver(file.toString()) },
                        clock = GoldenFixture.long(testCase, "clock") ?: 1_000,
                        leaseTtlMs = GoldenFixture.long(testCase, "leaseTTLms") ?: 30_000,
                        ephemeralCapacity = (GoldenFixture.long(testCase, "ephemeralCapacity") ?: 256).toInt(),
                    )
                    try {
                        runner.runCase(testCase)
                    } catch (error: Throwable) {
                        throw AssertionError(
                            "user-action-transaction.phone $name failed: ${error.message}", error,
                        )
                    }
                    if (group.first) validCount += 1 else invalidCount += 1
                }
            }
        } finally {
            directory.deleteRecursively()
        }
        println(
            "user-action-transaction.phone: valid=$validCount invalid=$invalidCount steps=$steps",
        )
        assertEquals("valid case count", valid.size, validCount)
        assertEquals("invalid case count", invalid.size, invalidCount)
    }
}
