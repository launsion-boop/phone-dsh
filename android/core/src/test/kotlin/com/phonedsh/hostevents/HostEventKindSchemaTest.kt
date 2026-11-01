// Host contract 1 — the executable parity check against harness-event.schema.json.
// SPDX-License-Identifier: MIT
//
// The closed kind set has three copies: the schema, `HarnessKindName` in the
// agentcore package, and `HostEventKind` in this package. Nothing compared the
// third with the first, so "the doc says fifteen, the enum has fourteen" stayed
// green until this test. It reads the normative schema from `spec/` (the :core
// test task passes `pdsh.repo.root`) and fails on:
//
//  * a wire value the schema does not pin, or a pinned kind the enum lacks;
//  * two schema variants pinning the same kind (kind is the only discriminator);
//  * a `durable` flag that disagrees with the variant's `required` list, which is
//    where the schema encodes "carries seq";
//  * the two Kotlin enumerations drifting apart, or `turn-event` becoming a host
//    kind (it is the UiState node kind of the `event/<seq>` level,
//    `spec/v1/trajectory.md` §7).
//
// The schema is the authority; the test never hard-codes a kind list of its own.

package com.phonedsh.hostevents

import com.phonedsh.agentcore.HarnessKindName
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostEventKindSchemaTest {
    private val repoRoot: Path = Path.of(
        System.getProperty("pdsh.repo.root")
            ?: error("pdsh.repo.root is not set; the :core test task supplies it"),
    )

    private val variants: List<JsonObject> by lazy {
        val document =
            JsonValue.parse(repoRoot.resolve(SCHEMA_PATH).toFile().readText()) as JsonObject
        (document["oneOf"] as JsonArray).values.map { it as JsonObject }
    }

    /** The schema's kind -> its variant, one entry per variant that pins a kind. */
    private val schemaKinds: Map<String, JsonObject> by lazy {
        variants.mapIndexed { index, variant -> kindOf(variant, index) to variant }.toMap()
    }

    @Test
    fun theWireSetIsExactlyTheSchemaKindSet() {
        assertEquals(
            schemaKinds.keys.sorted(),
            HostEventKind.entries.map { it.wire }.sorted(),
        )
    }

    @Test
    fun everySchemaVariantPinsExactlyOneKind() {
        val pinned = variants.mapIndexed { index, variant -> kindOf(variant, index) }
        assertEquals(pinned.size, pinned.toSet().size)
    }

    @Test
    fun theDurableFlagIsTheSchemaSeqRequirement() {
        schemaKinds.forEach { (wire, variant) ->
            val kind = HostEventKind.fromWire(wire)
                ?: error("the enum misses schema kind \"$wire\"")
            assertEquals("$wire durable", requiresSeq(variant), kind.durable)
        }
    }

    @Test
    fun theTwoKotlinEnumerationsAgree() {
        assertEquals(
            HostEventKind.entries.associate { it.wire to it.durable },
            HarnessKindName.entries.associate { it.wire to it.durable },
        )
    }

    @Test
    fun turnEventIsNotAHostKind() {
        // `turn-event` is the UiState node kind of the `event/<seq>` level
        // (`spec/v1/trajectory.md` §7): the parent of one event row, never an
        // event `kind`. The host kind count stays fifteen.
        assertNull(HostEventKind.fromWire("turn-event"))
        assertNull(HarnessKindName.fromWire("turn-event"))
        assertTrue("turn-event" !in schemaKinds)
    }

    private fun kindOf(variant: JsonObject, index: Int): String {
        val properties = variant["properties"] as? JsonObject
            ?: error("schema variant $index has no properties")
        val declaration = properties["kind"] as? JsonObject
            ?: error("schema variant $index has no kind declaration")
        (declaration["const"] as? JsonString)?.let { return it.value }
        val values = (declaration["enum"] as? JsonArray)?.values.orEmpty()
            .mapNotNull { (it as? JsonString)?.value }
        check(values.size == 1) {
            "schema variant $index must pin exactly one kind, got $values"
        }
        return values.single()
    }

    private fun requiresSeq(variant: JsonObject): Boolean =
        (variant["required"] as? JsonArray)?.values
            ?.any { it is JsonString && it.value == "seq" } == true

    private companion object {
        const val SCHEMA_PATH = "spec/host/v1/schema/harness-event.schema.json"
    }
}
