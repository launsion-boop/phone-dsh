// The executable alignment check against device-capabilities.schema.json.
// SPDX-License-Identifier: MIT
//
// The test reads the normative schema from `spec/` (the Gradle test task passes
// `pdsh.repo.root`) and compares it with what this module declares and emits:
//
//  * vocabulary names == the schema's `capabilities` property names,
//  * the six `provisional` marks == the schema's six marks,
//  * the emitted root/protocol/limits/auth member names == the schema's names,
//  * every value member of the every-capability fixture exists in that
//    capability's schema `properties`, and every `required` member is present,
//  * patterns, the schema tag, the pairing enum and the replay const are copied
//    verbatim.
//
// Nothing here reads a golden instance; the schema is the authority the task
// named, and the golden set is exactly what defines the provisional marks.

@file:Suppress("UNCHECKED_CAST")

package com.phonedsh.domain.device

import com.phonedsh.domain.testing.MiniJson
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceCapabilitiesSchemaTest {
    private val repoRoot: Path = Path.of(
        System.getProperty("pdsh.repo.root")
            ?: error("pdsh.repo.root is not set; the :domain test task supplies it"),
    )

    private val schema: Map<String, Any?> by lazy {
        MiniJson.parseObject(repoRoot.resolve(SCHEMA_PATH).toFile().readText())
    }

    private val rootProperties: Map<String, Any?> by lazy {
        schema["properties"] as Map<String, Any?>
    }

    private val capabilitySchemas: Map<String, Any?> by lazy {
        (rootProperties["capabilities"] as Map<String, Any?>)["properties"] as Map<String, Any?>
    }

    @Test
    fun theVocabularyIsExactlyTheSchemaVocabulary() {
        assertEquals(
            capabilitySchemas.keys.sorted(),
            DeviceCapability.entries.map { it.wireName }.sorted(),
        )
    }

    @Test
    fun theProvisionalMarksAreExactlyTheSchemaMarks() {
        val markedInSchema = capabilitySchemas
            .filterValues { (it as Map<String, Any?>)["provisional"] == true }
            .keys
        assertEquals(
            setOf("call.hfp", "call.uac", "render.light", "render.epaper", "render.screen", "vehicle.*"),
            markedInSchema,
        )
        assertEquals(6, markedInSchema.size)
        assertEquals(
            markedInSchema,
            DeviceCapability.provisional.map { it.wireName }.toSet(),
        )
    }

    @Test
    fun theEncodedManifestIsClosedOverTheSchemaRequiredRoot() {
        val document = MiniJson.parseObject(TestManifests.everyCapability().toJson())
        val required = (schema["required"] as List<Any?>).map { it as String }

        assertEquals(required.toSet(), document.keys)
        assertEquals(false, schema["additionalProperties"])
        assertEquals(
            (rootProperties["schema"] as Map<String, Any?>)["const"],
            document["schema"],
        )
    }

    @Test
    fun everyCapabilityValueUsesOnlySchemaMembersAndCarriesTheRequiredOnes() {
        val document = MiniJson.parseObject(TestManifests.everyCapability().toJson())
        val capabilities = document["capabilities"] as Map<String, Any?>

        // The fixture declares every vocabulary entry exactly once, so a missing
        // or extra name is caught before the per-value checks.
        assertEquals(capabilitySchemas.keys, capabilities.keys)

        capabilities.forEach { (name, value) ->
            val declaration = capabilitySchemas[name] as Map<String, Any?>
            val allowed = (declaration["properties"] as Map<String, Any?>).keys
            val required = (declaration["required"] as List<Any?>).map { it as String }
            val members = value as Map<String, Any?>

            assertTrue(
                "$name has members outside the schema: ${members.keys - allowed}",
                allowed.containsAll(members.keys),
            )
            assertTrue(
                "$name misses required members: ${required - members.keys}",
                members.keys.containsAll(required),
            )
        }
    }

    @Test
    fun theVocabularyMemberListsAreTheSchemaMemberLists() {
        // The decoder keeps exactly these members for a vocabulary entry, so a
        // missing or invented name changes what a decoded manifest contains:
        // compare the enum's own lists with the schema's `properties`/`required`.
        capabilitySchemas.forEach { (name, declaration) ->
            val schemaDeclaration = declaration as Map<String, Any?>
            val properties = (schemaDeclaration["properties"] as Map<String, Any?>).keys
            val required = (schemaDeclaration["required"] as List<Any?>)
                .map { it as String }
                .toSet()
            val capability = DeviceCapability.exact(name)
                ?: error("the vocabulary misses schema capability \"$name\"")

            assertEquals("$name required", required, capability.required)
            assertEquals("$name members", properties, capability.members)
            assertEquals("$name members", capability.required + capability.optional, capability.members)
        }
    }

    @Test
    fun limitsMembersAndBoundsMatchTheSchema() {        val document = MiniJson.parseObject(TestManifests.everyCapability().toJson())
        val declaration = rootProperties["limits"] as Map<String, Any?>
        val allowed = (declaration["properties"] as Map<String, Any?>).keys
        val required = (declaration["required"] as List<Any?>).map { it as String }
        val limits = document["limits"] as Map<String, Any?>

        assertTrue(allowed.containsAll(limits.keys))
        assertEquals(setOf("max_frame_bytes"), required.toSet())
        assertTrue(required.all { limits.containsKey(it) })

        val maxFrame = (declaration["properties"] as Map<String, Any?>)["max_frame_bytes"]
            as Map<String, Any?>
        assertEquals(
            (maxFrame["maximum"] as Long).toInt(),
            DeviceLimits.MAX_FRAME_BYTES,
        )
        assertTrue((limits["max_frame_bytes"] as Long) <= (maxFrame["maximum"] as Long))
    }

    @Test
    fun authEnumAndConstMatchTheSchema() {
        val document = MiniJson.parseObject(TestManifests.everyCapability().toJson())
        val declaration = rootProperties["auth"] as Map<String, Any?>
        val properties = declaration["properties"] as Map<String, Any?>
        val auth = document["auth"] as Map<String, Any?>

        assertEquals(setOf("pairing", "replay"), auth.keys)

        val pairingEnum = (properties["pairing"] as Map<String, Any?>)["enum"] as List<Any?>
        assertEquals(
            pairingEnum.map { it as String }.toSet(),
            DeviceAuth.Pairing.entries.map { it.wireName }.toSet(),
        )
        assertTrue(pairingEnum.map { it as String }.contains(auth["pairing"]))
        assertEquals(
            (properties["replay"] as Map<String, Any?>)["const"],
            DeviceAuth.REPLAY_COUNTER_TTL,
        )
    }

    @Test
    fun patternsAndVersionShapesAreCopiedVerbatim() {
        val deviceIdPattern = (rootProperties["device_id"] as Map<String, Any?>)["pattern"] as String
        assertEquals(deviceIdPattern, DeviceManifest.DEVICE_ID_PATTERN.pattern)
        assertTrue(Regex(deviceIdPattern).matches(TestManifests.everyCapability().deviceId))

        val protocolProperties =
            (rootProperties["protocol"] as Map<String, Any?>)["properties"] as Map<String, Any?>
        val versionPattern = (protocolProperties["version"] as Map<String, Any?>)["pattern"] as String
        assertEquals(versionPattern, DeviceProtocol.VERSION_PATTERN.pattern)
        assertTrue(Regex(versionPattern).matches(TestManifests.everyCapability().protocol.version))
    }

    @Test
    fun theVendorNamespaceIsTheSchemaPassThrough() {
        val vendor = DeviceManifest(
            deviceId = "d-1",
            protocol = DeviceProtocol("p", "1.0"),
            capabilities = mapOf(
                "vendor.acme.led" to CapabilityValue.of("mode" to "solid", "level" to 7),
            ),
            limits = DeviceLimits(maxFrameBytes = 1_024),
            auth = DeviceAuth(DeviceAuth.Pairing.CERT),
        )

        val capabilities = MiniJson.parseObject(vendor.toJson())["capabilities"] as Map<*, *>
        assertEquals(setOf("vendor.acme.led"), capabilities.keys)
        assertTrue(DeviceCapability.isVendorExtension("vendor.acme.led"))
        assertFalse(DeviceCapability.isDeclaredName("vendor.acme"))
    }

    private companion object {
        const val SCHEMA_PATH = "spec/host/v1/schema/device-capabilities.schema.json"
    }
}
