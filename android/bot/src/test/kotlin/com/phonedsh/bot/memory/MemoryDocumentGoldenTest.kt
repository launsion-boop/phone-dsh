// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.BotJsonException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives `memory-document.json` and `memory-document.schema.json` through the
 * real document codec. Expected values come from the fixture; the only
 * expectations in code are the frozen schema shape.
 */
class MemoryDocumentGoldenTest {
    private val fixture = MemoryVectors.golden("memory-document")

    @Test
    fun everyValidDocumentRoundTripsThroughTheRealCodec() {
        val valid = MemoryVectors.objects(fixture, "valid")
        assertTrue("memory-document.valid must not be empty", valid.isNotEmpty())
        for ((index, value) in valid.withIndex()) {
            val document = BotMemoryDocument.fromJson(value)
            assertEquals(
                "valid[$index] canonical round-trip",
                MemoryVectors.canonical(value),
                MemoryVectors.canonical(document.toJson()),
            )
            MemoryVectors.assertMatchesSchema("memory-document", document.toJson())
            assertNotNull("valid[$index] scope", document.scope)
        }
    }

    @Test
    fun everyInvalidDocumentIsRejectedByTheRealCodec() {
        val invalid = MemoryVectors.objects(fixture, "invalid")
        assertTrue("memory-document.invalid must not be empty", invalid.isNotEmpty())
        for ((index, entry) in invalid.withIndex()) {
            val reason = MemoryVectors.requireString(entry, "reason")
            val document = entry.members["document"]
            try {
                BotMemoryDocument.fromJson(document)
                fail("invalid[$index] $reason was accepted")
            } catch (_: BotJsonException) {
                // expected: the schema is authoritative
            }
        }
    }

    @Test
    fun pathRulesMatchTheContract() {
        for (path in listOf("user/profile.md", "agent/INDEX.md", "user/a/b/c.md", "agent/notes/2025-10.md")) {
            assertNotNull(path, BotMemoryPath.parse(path))
        }
        for (path in listOf(
            "", "/user/a.md", "user/", "shared/a.md", "USER/a.md",
            "user/../a.md", "user/./a.md", "user//a.md", "user/a\\b.md",
            "user/ a.md", "user/a\nb.md", "user/INDEX.md/",
        )) {
            assertNull(path, BotMemoryPath.parse(path))
        }
        assertNotNull("agent root", BotMemoryPath.parse("agent", allowRoot = true))
        assertNull("agent root is not a document", BotMemoryPath.parse("agent"))
        val longSegment = "a".repeat(65)
        assertNull("segment over 64 scalars", BotMemoryPath.parse("user/$longSegment"))
        assertNotNull("segment at 64 scalars", BotMemoryPath.parse("user/${"a".repeat(64)}"))
    }

    @Test
    fun pathAndIndexLimitsCountUnicodeScalarsNotUtf16Units() {
        // U+1F525 is one scalar but two UTF-16 units.
        val fire = "\uD83D\uDD25"
        val path = "user/" + fire.repeat(61) + ".md"
        assertEquals(64, BotMemoryText.scalarCount(fire.repeat(61) + ".md"))
        assertNotNull("64 scalar segment", BotMemoryPath.parse(path))
        assertNull("65 scalar segment", BotMemoryPath.parse("user/" + fire.repeat(64) + ".md"))

        val limit = fire.repeat(1500)
        assertEquals(1500, BotMemoryText.scalarCount(limit))
        assertNull("1500 scalars fit", BotMemoryPath.indexOverflow("agent/INDEX.md", limit))
        assertEquals(
            1501,
            BotMemoryPath.indexOverflow("agent/INDEX.md", fire.repeat(1501)),
        )
    }

    @Test
    fun authoredEvidenceMustStayCanonical() {
        val document = BotMemoryDocument.fromJson(MemoryVectors.objects(fixture, "valid").first())
        assertEquals(listOf("record://session/gb-main#3"), document.evidence)
        assertTrue(BotMemoryEvidence.isCanonicalStoredReference("record://event/1"))
        assertTrue(BotMemoryEvidence.isCanonicalStoredReference("record://session/gb-main#0"))
        assertTrue(!BotMemoryEvidence.isCanonicalStoredReference("record://session/../#1"))
        assertTrue(!BotMemoryEvidence.isCanonicalStoredReference("record://session/gb-main#01"))
        assertTrue(!BotMemoryEvidence.isCanonicalStoredReference("record://event/0"))
        assertTrue(!BotMemoryEvidence.isCanonicalStoredReference("record://session/gb-main"))
    }

    @Test
    fun evidenceParserCanonicalizesWhitespaceAndCaseButNotArbitraryInput() {
        assertEquals(
            "record://session/gb-main#3",
            BotMemoryEvidence.parse("  record://SESSION/gb-main#03  ")?.canonical,
        )
        assertEquals(
            "record://event/7",
            BotMemoryEvidence.parse("record://EVENT/07")?.canonical,
        )
        assertNull(BotMemoryEvidence.parse("record://session/gb-main"))
        assertNull(BotMemoryEvidence.parse("record://session/../#1"))
        assertNull(BotMemoryEvidence.parse("record://event/0"))
        assertNull(BotMemoryEvidence.parse("https://example.com/1"))
        val source = JsonObject(
            mapOf(
                "kind" to com.phonedsh.agentcore.JsonString("user-turn"),
                "sessionId" to com.phonedsh.agentcore.JsonString("gb-main"),
                "turnId" to com.phonedsh.agentcore.JsonNumber("1"),
            ),
        )
        assertEquals("1", BotMemorySource.fromJson(source).turnId)
    }
}
