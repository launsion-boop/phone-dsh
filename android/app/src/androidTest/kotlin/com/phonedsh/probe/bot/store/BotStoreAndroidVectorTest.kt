// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot.store

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotStoreException
import com.phonedsh.bot.store.BotStoreVectorRunner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Runs the same `store.phone.json` / `user-action-transaction.phone.json`
 * vectors as the JVM suite through the real `android.database.sqlite` driver.
 *
 * A device/emulator run needs the repository visible:
 *
 *   adb push spec <device>/data/local/tmp/pdsh/spec
 *   adb shell am instrument -w \
 *     -e pdsh.repo.root /data/local/tmp/pdsh \
 *     com.phonedsh.app.test/androidx.test.runner.AndroidJUnitRunner
 *
 * Without a device this test is NOT_RUN; it still has to compile.
 */
@RunWith(AndroidJUnit4::class)
class BotStoreAndroidVectorTest {
    @Test
    fun everySharedStoreVectorRunsThroughTheAndroidDriver() {
        runVectorFile("store.phone.json")
    }

    @Test
    fun everySharedUserActionVectorRunsThroughTheAndroidDriver() {
        runVectorFile("user-action-transaction.phone.json")
    }

    @Test
    fun everyMergedEnvelopeVectorUsesTheAndroidCodecPath() {
        val root = repositoryRoot()
        val upstream = parse(File(root, "spec/bot/v1/golden/event-envelope.json"))
        val overlay = parse(File(root, "spec/bot/v1/golden/event-envelope.phone.json"))
        var count = 0

        (upstream.members["valid"] as? JsonObject)?.members?.get("event")?.let {
            BotEventCodec.validate(BotEvent.fromJson(it), BotEventCodec.Mode.STORED)
            count += 1
        }
        (overlay.members["validCases"] as? JsonArray)?.values?.forEach {
            val event = BotEvent.fromJson((it as JsonObject).members.getValue("event"))
            BotEventCodec.validate(event, BotEventCodec.Mode.STORED)
            BotEventCodec.encodeData(event.data)
            count += 1
        }
        for (key in listOf("invalid", "invalidCases", "ephemeralInvalidCases")) {
            val cases = when (val value = if (key == "invalid") upstream.members[key] else overlay.members[key]) {
                is JsonArray -> value.values
                else -> emptyList()
            }
            for (vector in cases) {
                val expected = expectedCode(vector)
                val event = BotEvent.fromJson(
                    ((vector as JsonObject).members.getValue("event")),
                )
                val actual = try {
                    BotEventCodec.validate(event, BotEventCodec.Mode.STORED)
                    null
                } catch (error: BotStoreException) {
                    error.code
                }
                assertEquals("$key envelope code", expected, actual)
                count += 1
            }
        }
        assertTrue("event-envelope vectors must run", count > 0)
    }

    private fun runVectorFile(name: String) {
        val root = repositoryRoot()
        val fixture = parse(File(root, "spec/bot/v1/golden/$name"))
        val valid = (fixture.members["valid"] as? JsonArray)?.values ?: emptyList()
        val invalid = (fixture.members["invalid"] as? JsonArray)?.values ?: emptyList()
        assertTrue("$name.valid must not be empty", valid.isNotEmpty())
        assertTrue("$name.invalid must not be empty", invalid.isNotEmpty())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for ((index, value) in (valid + invalid).withIndex()) {
            val testCase = value as? JsonObject ?: throw AssertionError("$name[$index] is not an object")
            val dataRoot = File(context.filesDir, "PhoneDSHBot")
            if (dataRoot.exists()) dataRoot.deleteRecursively()
            val runner = BotStoreVectorRunner(
                driverFactory = { AndroidBotSqlDriver.open(context) },
                clock = long(testCase, "clock") ?: 1_000,
                leaseTtlMs = long(testCase, "leaseTTLms") ?: 30_000,
                ephemeralCapacity = (long(testCase, "ephemeralCapacity") ?: 256).toInt(),
            )
            try {
                runner.runCase(testCase)
            } catch (error: Throwable) {
                throw AssertionError(
                    "$name ${(testCase.members["name"] as? com.phonedsh.agentcore.JsonString)?.value} " +
                        "failed: ${error.message}",
                    error,
                )
            } finally {
                runner.close()
            }
        }
    }

    private fun expectedCode(vector: JsonValue): String {
        val errors = (((vector as JsonObject).members["validation"] as? JsonObject)
            ?.members?.get("errors") as? JsonArray)?.values ?: emptyList()
        return ((errors.first() as JsonObject).members.getValue("code") as
            com.phonedsh.agentcore.JsonString).value
    }

    private fun repositoryRoot(): File {
        val argument = InstrumentationRegistry.getArguments().getString("pdsh.repo.root").orEmpty()
        assumeTrue(
            "pdsh.repo.root is not set; push spec to the device and pass -e pdsh.repo.root <dir>",
            argument.isNotBlank() && File(argument).isDirectory,
        )
        return File(argument)
    }

    private fun parse(file: File): JsonObject {
        assertTrue("missing vector ${file.path}", file.isFile)
        return JsonValue.parse(file.readText()) as JsonObject
    }

    private fun long(value: JsonObject, key: String): Long? =
        (value.members[key] as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()
}
