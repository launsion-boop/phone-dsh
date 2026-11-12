// SPDX-License-Identifier: MIT
// Drives the production closed-shape validators with the non-admin samples of
// `golden/schema-samples.json`: 28 valid and 27 invalid pairs (the five/five
// admin-carrier samples are PC/CLI-side and outside the phone module, exactly as
// the Swift golden-schema test excludes them).
package com.phonedsh.pclink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GoldenSchemaSampleTest {
    private fun validate(sample: PclinkJson, schema: String) {
        when {
            schema.startsWith("relay-") -> PclinkWire.validateRelayFrame(sample)
            schema == "pairing-message.schema.json" -> PclinkWire.validatePairingMessage(sample)
            schema == "pairing-record.schema.json" ->
                PclinkWire.validatePairingRecordShape(sample, phoneRecord = false)
            schema == "phone-pairing-record.schema.json" ->
                PclinkWire.validatePairingRecordShape(sample, phoneRecord = true)
            schema == "e2e-frame.schema.json" -> PclinkWire.validateE2EFrame(sample)
            schema == "e2e-handshake.schema.json" -> PclinkWire.validateE2EHandshake(sample)
            schema == "inner-message.schema.json" -> PclinkWire.validateInnerMessage(sample)
            schema == "endpoints.schema.json" -> PclinkWire.validateEndpointsInventory(sample)
            else -> throw AssertionError("unmapped schema sample $schema")
        }
    }

    @Test
    fun validSamples() {
        val samples = TestSupport.objects(TestSupport.schemaSamples(), "valid")
        var seen = 0
        val names = HashSet<String>()
        for (sample in samples) {
            val schema = sample.requiredString("schema")
            if (schema.startsWith("admin")) continue
            seen++
            val name = sample.requiredString("name")
            names.add(name)
            val value = TestSupport.at(sample, "value")
                ?: throw AssertionError("$schema/$name has no value")
            validate(value, schema)
            if (name == "rpc-call-carried-nul") {
                assertEquals("a\u0000b", TestSupport.string(value, "args", "note"))
            }
            if (name == "stream-item-carried-nul") {
                assertEquals("a\u0000b", TestSupport.string(value, "value", "text"))
            }
        }
        assertEquals(28, seen)
        assertTrue(names.contains("rpc-call-carried-nul"))
        assertTrue(names.contains("stream-item-carried-nul"))
        assertTrue(names.contains("pc-record-legacy-cli"))
    }

    @Test
    fun invalidSamples() {
        val samples = TestSupport.objects(TestSupport.schemaSamples(), "invalid")
        var seen = 0
        val names = HashSet<String>()
        for (sample in samples) {
            val schema = sample.requiredString("schema")
            if (schema.startsWith("admin")) continue
            seen++
            val name = sample.requiredString("name")
            names.add(name)
            val value = TestSupport.at(sample, "value")
                ?: throw AssertionError("$schema/$name has no value")
            // Every non-admin invalid sample is a closed-shape violation. The
            // `direct-mode-is-v1-unknown` sample is missing the PC approval
            // fields too, so the closed-object check reports those first; the
            // unsupported-mode code path has its own complete-record test below.
            assertPclinkCode(
                "bad_frame",
                "$schema/$name: ${TestSupport.string(sample, "reason")}",
            ) {
                validate(value, schema)
            }
        }
        assertEquals(27, seen)
        assertTrue(names.contains("notice-name-nul"))
    }

    @Test
    fun completeRecordWithFutureConnectionModeIsVersionUnsupported() {
        val samples = TestSupport.objects(TestSupport.schemaSamples(), "valid")
        val record = samples.single { sample ->
            TestSupport.string(sample, "schema") == "pairing-record.schema.json" &&
                TestSupport.string(sample, "name") == "pc-record"
        }
        val value = TestSupport.at(record, "value") ?: throw AssertionError("missing pc-record")
        val members = LinkedHashMap(value.objectValue!!)
        members["connection"] = pclinkObject("mode" to PclinkJson.Text("future"))
        assertPclinkCode("version_unsupported") {
            PclinkWire.validatePairingRecordShape(PclinkJson.Object(members), phoneRecord = false)
        }
    }
}
