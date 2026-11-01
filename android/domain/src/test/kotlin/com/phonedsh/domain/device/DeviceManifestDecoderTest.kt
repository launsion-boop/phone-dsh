// The decoder contract of pdsh-device-caps/1.
// SPDX-License-Identifier: MIT
//
// One test group per rule in DeviceManifest.parse's KDoc: the tolerant read
// against the closed write, the missing-member boundary, the known-member type
// and range refusals, the pass-through namespaces and the schema's own
// capability-value member lists. The documents are raw JSON on purpose: building
// them from the encoder would make the encoder the only witness for its own
// decoder.

package com.phonedsh.domain.device

import com.phonedsh.domain.testing.MiniJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceManifestDecoderTest {
    // ---- round trip --------------------------------------------------------

    @Test
    fun aValidManifestSurvivesEncodeDecodeEncode() {
        listOf(TestManifests.everyCapability(), TestManifests.localAndroid()).forEach { original ->
            val decoded = DeviceManifest.parse(original.toJson())

            assertEquals(original.toJson(), decoded.toJson())
            assertSameManifest(original, decoded)
        }
    }

    @Test
    fun theEveryCapabilityFixtureDecodesWithExactlyTheSchemaNames() {
        val decoded = DeviceManifest.parse(TestManifests.everyCapability().toJson())

        assertEquals(
            DeviceCapability.entries.map { it.wireName }.toSet(),
            decoded.capabilities.keys,
        )
        DeviceCapability.entries.forEach { capability ->
            assertEquals(
                capability.wireName,
                capability.members,
                decoded.capabilities.getValue(capability.wireName).members.keys,
            )
        }
    }

    // ---- D5: unknown members are ignored -----------------------------------

    @Test
    fun unknownMembersAreIgnoredAndDroppedOnReEncode() {
        val document = manifestJson(
            protocol = """{"id":"p","version":"1.0","transport":"ws"}""",
            capabilities = """
                {
                  "audio.tts":{"codec":"opus","rate":24000,"turbo":true,"extra":{"deep":1}},
                  "vendor.acme.led":{"mode":"solid"}
                }
            """.trimIndent(),
            limits = """{"max_frame_bytes":1024,"jumbo":true}""",
            auth = """{"pairing":"code","replay":"counter+ttl","ttl_ms":30000}""",
            extraRootMembers = mapOf("future" to """{"revision":2}"""),
        )

        val encoded = MiniJson.parseObject(DeviceManifest.parse(document).toJson())

        assertEquals(
            setOf("schema", "device_id", "protocol", "capabilities", "limits", "auth"),
            encoded.keys,
        )
        assertEquals(setOf("id", "version"), (encoded["protocol"] as Map<*, *>).keys)
        assertEquals(setOf("max_frame_bytes"), (encoded["limits"] as Map<*, *>).keys)
        assertEquals(setOf("pairing", "replay"), (encoded["auth"] as Map<*, *>).keys)

        val capabilities = encoded["capabilities"] as Map<*, *>
        assertEquals(setOf("audio.tts", "vendor.acme.led"), capabilities.keys)
        // A vocabulary entry keeps exactly the declared members; the unknown
        // flat *and* nested members are dropped, not carried through.
        assertEquals(setOf("codec", "rate"), (capabilities["audio.tts"] as Map<*, *>).keys)
        // The vendor value is untouched, so its members survive.
        assertEquals(setOf("mode"), (capabilities["vendor.acme.led"] as Map<*, *>).keys)
    }

    @Test
    fun unknownCapabilityNamesAreDroppedInsteadOfRejected() {
        // The name is what this revision does not know, so the value is not
        // inspected at all: even a non-object value under an unknown name is
        // ignored rather than reported as a type error.
        val document = manifestJson(
            capabilities = """
                {
                  "memory.read":{"rows":1},
                  "light.blink":[1,2],
                  "audio.tts":{"codec":"opus","rate":24000}
                }
            """.trimIndent(),
        )

        val decoded = DeviceManifest.parse(document)

        assertEquals(setOf("audio.tts"), decoded.capabilities.keys)
        val encoded = MiniJson.parseObject(decoded.toJson())["capabilities"] as Map<*, *>
        assertEquals(setOf("audio.tts"), encoded.keys)
    }

    // ---- missing members ---------------------------------------------------

    @Test
    fun everyMissingRootMemberIsAMissingMemberFailure() {
        val cases = linkedMapOf(
            "schema" to manifestJson(schema = null),
            "device_id" to manifestJson(deviceId = null),
            "protocol" to manifestJson(protocol = null),
            "capabilities" to manifestJson(capabilities = null),
            "limits" to manifestJson(limits = null),
            "auth" to manifestJson(auth = null),
        )

        cases.forEach { (member, document) ->
            val failure = failureOf(document)

            assertEquals(member, DeviceManifestFailure.MISSING_MEMBER, failure.failure)
            assertEquals("DEVICE_MANIFEST_MISSING_MEMBER", failure.code)
            assertTrue(member, failure.detail.startsWith("$member "))
        }
    }

    @Test
    fun aMissingNestedRequiredMemberIsAlsoAMissingMember() {
        val cases = linkedMapOf(
            "protocol.version" to manifestJson(protocol = """{"id":"p"}"""),
            "limits.max_frame_bytes" to manifestJson(limits = """{"text_bytes":2048}"""),
            "auth.replay" to manifestJson(auth = """{"pairing":"code"}"""),
            "capabilities.audio.tts.rate" to manifestJson(
                capabilities = """{"audio.tts":{"codec":"opus"}}""",
            ),
            "capabilities.vehicle.speed.granted_by" to manifestJson(
                capabilities = """{"vehicle.speed":{"kmh":60}}""",
            ),
        )

        cases.forEach { (path, document) ->
            val failure = failureOf(document)

            assertEquals(path, DeviceManifestFailure.MISSING_MEMBER, failure.failure)
            assertTrue(path, failure.detail.startsWith(path))
        }
    }

    // ---- known-member types and values ------------------------------------

    @Test
    fun aVehicleGrantMustBePresentNonBlankAndAString() {
        listOf("\"\"", "\"  \"").forEach { grantedBy ->
            val failure = failureOf(
                manifestJson(capabilities = """{"vehicle.speed":{"granted_by":$grantedBy}}"""),
            )

            assertEquals(grantedBy, DeviceManifestFailure.OUT_OF_RANGE, failure.failure)
            assertEquals(
                "capabilities.vehicle.speed.granted_by",
                failure.detail.substringBefore(" must"),
            )
        }

        assertEquals(
            DeviceManifestFailure.WRONG_TYPE,
            failureOf(
                manifestJson(capabilities = """{"vehicle.speed":{"granted_by":7}}"""),
            ).failure,
        )
    }

    @Test
    fun knownMembersWithTheWrongJsonTypeAreRejected() {
        val cases = linkedMapOf(
            "device_id number" to manifestJson(deviceId = "7"),
            "device_id null" to manifestJson(deviceId = "null"),
            "protocol string" to manifestJson(protocol = "\"ws\""),
            "protocol.id number" to manifestJson(protocol = """{"id":7,"version":"1.0"}"""),
            "capabilities array" to manifestJson(capabilities = "[]"),
            "capability value string" to manifestJson(capabilities = """{"audio.tts":"opus"}"""),
            "capability required nested" to manifestJson(
                capabilities = """{"audio.tts":{"codec":{"name":"opus"},"rate":24000}}""",
            ),
            "limits string" to manifestJson(limits = """{"max_frame_bytes":"1024"}"""),
            "limits fractional" to manifestJson(limits = """{"max_frame_bytes":1.5}"""),
            "auth.replay number" to manifestJson(auth = """{"pairing":"code","replay":1}"""),
        )

        cases.forEach { (label, document) ->
            val failure = failureOf(document)

            assertEquals(label, DeviceManifestFailure.WRONG_TYPE, failure.failure)
            assertEquals("DEVICE_MANIFEST_WRONG_TYPE", failure.code)
        }
    }

    // ---- known-member ranges ----------------------------------------------

    @Test
    fun limitsAreBoundedLikeTheSchema() {
        val cases = linkedMapOf(
            "limits.max_frame_bytes low" to manifestJson(limits = """{"max_frame_bytes":0}"""),
            "limits.max_frame_bytes high" to manifestJson(limits = """{"max_frame_bytes":65537}"""),
            "limits.text_bytes" to manifestJson(
                limits = """{"max_frame_bytes":1024,"text_bytes":0}""",
            ),
            "limits.audio_kbps" to manifestJson(
                limits = """{"max_frame_bytes":1024,"audio_kbps":0}""",
            ),
        )

        cases.forEach { (label, document) ->
            val failure = failureOf(document)

            assertEquals(label, DeviceManifestFailure.OUT_OF_RANGE, failure.failure)
            assertEquals("DEVICE_MANIFEST_OUT_OF_RANGE", failure.code)
        }

        assertEquals(
            "limits.max_frame_bytes",
            failureOf(cases.getValue("limits.max_frame_bytes low")).detail.substringBefore(" must"),
        )
        assertEquals(
            "limits.text_bytes",
            failureOf(cases.getValue("limits.text_bytes")).detail.substringBefore(" must"),
        )
        assertEquals(
            "limits.audio_kbps",
            failureOf(cases.getValue("limits.audio_kbps")).detail.substringBefore(" must"),
        )
    }

    @Test
    fun theProtocolVersionIsMajorDotMinorAndTheIdIsBounded() {
        val missingMinor = failureOf(manifestJson(protocol = """{"id":"p","version":"1"}"""))
        assertEquals(DeviceManifestFailure.OUT_OF_RANGE, missingMinor.failure)
        assertEquals("protocol.version", missingMinor.detail.substringBefore(" must"))

        listOf("1", "1.0.0", "v1.0", "").forEach { version ->
            assertEquals(
                version,
                DeviceManifestFailure.OUT_OF_RANGE,
                failureOf(manifestJson(protocol = """{"id":"p","version":"$version"}""")).failure,
            )
        }

        val emptyId = failureOf(manifestJson(protocol = """{"id":"","version":"1.0"}"""))
        assertEquals(DeviceManifestFailure.OUT_OF_RANGE, emptyId.failure)
        assertEquals("protocol.id", emptyId.detail.substringBefore(" must"))

        val longId = failureOf(
            manifestJson(protocol = """{"id":"${"x".repeat(129)}","version":"1.0"}"""),
        )
        assertEquals(DeviceManifestFailure.OUT_OF_RANGE, longId.failure)

        // The schema's own example values still decode.
        assertEquals("2.1", DeviceManifest.parse(manifestJson(protocol = """{"id":"devicews","version":"2.1"}""")).protocol.version)
    }

    @Test
    fun thePairingEnumAndReplayConstAreEnforced() {
        assertEquals(
            DeviceManifestFailure.OUT_OF_RANGE,
            failureOf(manifestJson(auth = """{"pairing":"pin","replay":"counter+ttl"}""")).failure,
        )
        assertEquals(
            DeviceManifestFailure.OUT_OF_RANGE,
            failureOf(manifestJson(auth = """{"pairing":"code","replay":"timestamp"}""")).failure,
        )

        DeviceAuth.Pairing.entries.forEach { pairing ->
            val decoded = DeviceManifest.parse(
                manifestJson(auth = """{"pairing":"${pairing.wireName}","replay":"counter+ttl"}"""),
            )
            assertEquals(pairing, decoded.auth.pairing)
            assertEquals(DeviceAuth.REPLAY_COUNTER_TTL, decoded.auth.replay)
        }
    }

    @Test
    fun theDeviceIdPatternAndTheSchemaTagAreEnforced() {
        listOf("", "bad id", "-leading", "a".repeat(129)).forEach { deviceId ->
            val failure = failureOf(manifestJson(deviceId = "\"$deviceId\""))

            assertEquals(deviceId, DeviceManifestFailure.OUT_OF_RANGE, failure.failure)
            assertEquals("device_id", failure.detail.substringBefore(" must"))
        }

        val wrongTag = failureOf(manifestJson(schema = "\"pdsh-device-caps/2\""))
        assertEquals(DeviceManifestFailure.OUT_OF_RANGE, wrongTag.failure)
        assertEquals("schema", wrongTag.detail.substringBefore(" must"))

        // The schema's allowed punctuation still decodes.
        assertEquals(
            "a:b.c_d-e",
            DeviceManifest.parse(manifestJson(deviceId = "\"a:b.c_d-e\"")).deviceId,
        )
    }

    @Test
    fun integralNumbersAreAcceptedInAnyLiteralFormJsonAllows() {
        assertEquals(
            1000,
            DeviceManifest.parse(manifestJson(limits = """{"max_frame_bytes":1e3}"""))
                .limits.maxFrameBytes,
        )
        assertEquals(
            1000,
            DeviceManifest.parse(manifestJson(limits = """{"max_frame_bytes":1000.0}"""))
                .limits.maxFrameBytes,
        )
    }

    // ---- vendor / vehicle pass-through ------------------------------------

    @Test
    fun vendorNestedValuesSurviveTheRoundTrip() {
        val capabilities = """
            {
              "vendor.acme.thing": {
                "mode": "solid",
                "nested": {"level": 7, "modes": ["a", "b"]},
                "deep": [{"on": true}, {"on": false}]
              }
            }
        """.trimIndent()
        val document = manifestJson(capabilities = capabilities)

        val manifest = DeviceManifest.parse(document)
        val value = manifest.capabilities.getValue("vendor.acme.thing")

        assertEquals("solid", value.string("mode"))
        val nested = value.members["nested"] as Map<*, *>
        assertEquals(7, nested["level"])
        assertEquals(listOf("a", "b"), nested["modes"])

        // The nested value is bit-identical through encode/decode, not merely
        // "still present": parse both documents and compare the capability maps.
        val originalCapabilities = MiniJson.parseObject(document)["capabilities"]
        val reEncodedCapabilities = MiniJson.parseObject(manifest.toJson())["capabilities"]
        assertEquals(originalCapabilities, reEncodedCapabilities)

        assertFalse(manifest.isProvisional("vendor.acme.thing"))
    }

    @Test
    fun vehicleValuesKeepTheVendorGrantDetail() {
        val manifest = DeviceManifest.parse(
            manifestJson(
                capabilities = """
                    {"vehicle.speed":{"granted_by":"oem","kmh":60,"limits":{"city":50}}}
                """.trimIndent(),
            ),
        )

        val value = manifest.capabilities.getValue("vehicle.speed")
        assertEquals("oem", value.string("granted_by"))
        assertEquals(60, value.int("kmh"))
        assertTrue(manifest.isProvisional("vehicle.speed"))

        val encoded = MiniJson.parseObject(manifest.toJson())["capabilities"] as Map<*, *>
        val encodedVehicle = encoded["vehicle.speed"] as Map<*, *>
        assertEquals(setOf("granted_by", "kmh", "limits"), encodedVehicle.keys)
        assertEquals(60L, encodedVehicle["kmh"])
    }

    // ---- provisional marks, decoded ---------------------------------------

    @Test
    fun theSixProvisionalCapabilitiesCarryTheSchemaMarkAfterDecoding() {
        val manifest = DeviceManifest.parse(
            manifestJson(
                capabilities = """
                    {
                      "call.hfp":{"profile":"HF","codec":"msbc"},
                      "call.uac":{"telephony":"hid","codec":"usb"},
                      "render.light":{"effects":["breathe"]},
                      "render.epaper":{"w":250,"h":122,"format":"mono1"},
                      "render.screen":{"w":1280,"h":720,"formats":["png"]},
                      "vehicle.speed":{"granted_by":"oem"},
                      "audio.tts":{"codec":"opus","rate":24000},
                      "vendor.acme.led":{"mode":"solid"}
                    }
                """.trimIndent(),
            ),
        )

        val provisional = DeviceCapability.provisional.map { it.wireName }.toSet()
        assertEquals(
            setOf("call.hfp", "call.uac", "render.light", "render.epaper", "render.screen", "vehicle.*"),
            provisional,
        )
        assertEquals(6, provisional.size)
        provisional.forEach { name -> assertTrue(name, manifest.isProvisional(name)) }

        assertTrue(manifest.capabilities.containsKey("vehicle.speed"))
        assertTrue(manifest.isProvisional("vehicle.speed"))
        assertFalse(manifest.isProvisional("audio.tts"))
        assertFalse(manifest.isProvisional("vendor.acme.led"))
    }

    // ---- the read/absent boundary -----------------------------------------

    @Test
    fun parseOrNullReturnsNullOnlyForTextThatIsNotJson() {
        assertNull(DeviceManifest.parseOrNull(""))
        assertNull(DeviceManifest.parseOrNull("   "))
        assertNull(DeviceManifest.parseOrNull("not json"))
        assertNull(DeviceManifest.parseOrNull("""{"schema":"pdsh-device-caps/1",}"""))
        assertNull(DeviceManifest.parseOrNull("""{"schema":"pdsh-device-caps/1"} trailing"""))

        // A JSON document that is broken is not "absent": it still throws.
        assertEquals(
            DeviceManifestFailure.MISSING_MEMBER,
            assertThrows(DeviceManifestException::class.java) {
                DeviceManifest.parseOrNull("""{"schema":"pdsh-device-caps/1"}""")
            }.failure,
        )
        assertEquals(
            DeviceManifestFailure.ROOT_NOT_OBJECT,
            assertThrows(DeviceManifestException::class.java) {
                DeviceManifest.parseOrNull("[]")
            }.failure,
        )

        val decoded = DeviceManifest.parseOrNull(
            """  {
                "schema": "pdsh-device-caps/1",
                "device_id": "d-1",
                "protocol": {"id": "p", "version": "1.0"},
                "capabilities": {},
                "limits": {"max_frame_bytes": 1},
                "auth": {"pairing": "code", "replay": "counter+ttl"}
            }  """,
        )
        assertNotNull(decoded)
        assertEquals("d-1", decoded!!.deviceId)
    }

    @Test
    fun aDocumentWhoseRootIsNotAnObjectIsRejected() {
        listOf("[]", "\"manifest\"", "7", "true", "null").forEach { document ->
            assertEquals(
                document,
                DeviceManifestFailure.ROOT_NOT_OBJECT,
                failureOf(document).failure,
            )
        }
    }

    @Test
    fun malformedJsonHasItsOwnStableCode() {
        listOf("{", """{"schema":}""", """{"schema" "x"}""", "{} {}", """{"a":1,}""").forEach { document ->
            val failure = failureOf(document)

            assertEquals(document, DeviceManifestFailure.MALFORMED_JSON, failure.failure)
            assertEquals("DEVICE_MANIFEST_MALFORMED_JSON", failure.code)
        }
    }

    @Test
    fun aDuplicateMemberKeepsItsLastValue() {
        val document = """
            {"schema":"pdsh-device-caps/1","device_id":"first","device_id":"second",
             "protocol":{"id":"p","version":"1.0"},"capabilities":{},
             "limits":{"max_frame_bytes":1},"auth":{"pairing":"code","replay":"counter+ttl"}}
        """.trimIndent()

        assertEquals("second", DeviceManifest.parse(document).deviceId)
    }

    // ---- helpers -----------------------------------------------------------

    private fun manifestJson(
        schema: String? = "\"pdsh-device-caps/1\"",
        deviceId: String? = "\"d-1\"",
        protocol: String? = """{"id":"p","version":"1.0"}""",
        capabilities: String? = "{}",
        limits: String? = """{"max_frame_bytes":1024}""",
        auth: String? = """{"pairing":"code","replay":"counter+ttl"}""",
        extraRootMembers: Map<String, String> = emptyMap(),
    ): String {
        val members = LinkedHashMap<String, String>()
        schema?.let { members["schema"] = it }
        deviceId?.let { members["device_id"] = it }
        protocol?.let { members["protocol"] = it }
        capabilities?.let { members["capabilities"] = it }
        limits?.let { members["limits"] = it }
        auth?.let { members["auth"] = it }
        members.putAll(extraRootMembers)
        return members.entries.joinToString(separator = ",", prefix = "{", postfix = "}") { (name, raw) ->
            "\"$name\":$raw"
        }
    }

    private fun failureOf(document: String): DeviceManifestException =
        assertThrows(DeviceManifestException::class.java) { DeviceManifest.parse(document) }

    private fun assertSameManifest(expected: DeviceManifest, actual: DeviceManifest) {
        assertEquals(expected.deviceId, actual.deviceId)
        assertEquals(expected.protocol, actual.protocol)
        assertEquals(expected.limits, actual.limits)
        assertEquals(expected.auth, actual.auth)
        assertEquals(expected.capabilities.keys, actual.capabilities.keys)
        expected.capabilities.forEach { (name, value) ->
            assertEquals(
                "capability $name",
                value.members,
                actual.capabilities.getValue(name).members,
            )
        }
    }
}
