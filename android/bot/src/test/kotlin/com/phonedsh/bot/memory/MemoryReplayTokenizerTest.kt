// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Replay-feed incrementality, corruption handling and UTF-16/snippet boundaries. */
class MemoryReplayTokenizerTest {
    @Test
    fun replayFeedScansOnceThenReadsOnlyTheDelta() {
        MemoryHarness().use { harness ->
            harness.append(
                type = "memory.document_written",
                eventId = "written-a",
                data = writtenData("agent/a.md", "first", 1, 0),
                time = 1_760_000_000_001,
            )
            harness.store.documents()
            val first = harness.store.replayDiagnostics()
            assertEquals(1, first.fullReplayCount)
            assertEquals(0, first.incrementalReplayCount)
            assertTrue(first.scannedEventCount >= 1)
            assertTrue(first.processedMemoryEventCount >= 1)

            harness.append(
                type = "memory.document_written",
                eventId = "written-b",
                data = writtenData("agent/b.md", "second", 1, 0),
                time = 1_760_000_000_002,
            )
            harness.store.documents()
            val second = harness.store.replayDiagnostics()
            assertEquals(1, second.fullReplayCount)
            assertEquals(1, second.incrementalReplayCount)
            assertTrue(second.scannedEventCount > first.scannedEventCount)
        }
    }

    private fun writtenData(
        path: String,
        content: String,
        version: Int,
        expected: Int,
    ): JsonObject = JsonObject(
        linkedMapOf(
            "path" to JsonString(path),
            "scope" to JsonString("agent"),
            "content" to JsonString(content),
            "version" to JsonNumber(version.toString()),
            "expected_version" to JsonNumber(expected.toString()),
            "updated_at_ms" to JsonNumber("1760000000000"),
            "author" to JsonObject(
                mapOf(
                    "bot_id" to JsonString("bot-a"),
                    "kind" to JsonString("chat"),
                ),
            ),
            "evidence" to JsonArray(emptyList()),
        ),
    )

    @Test
    fun malformedMemoryEventIsSkippedAndReported() {
        MemoryHarness().use { harness ->
            harness.append(
                type = "memory.document_written",
                eventId = "malformed-written",
                data = JsonObject(mapOf("path" to JsonString("agent/a.md"))),
            )
            val reopened = harness.storeFor("bot-a")
            assertTrue(reopened.documents().isEmpty())
            assertTrue(
                reopened.replayDiagnostics().skippedEventIds.contains("malformed-written"),
            )
        }
    }

    @Test
    fun conflictingDuplicateVersionIsRealCorruption() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/a.md", "first", 1)
            harness.append(
                type = "memory.document_written",
                eventId = "conflicting-written",
                data = JsonObject(
                    linkedMapOf(
                        "path" to JsonString("agent/a.md"),
                        "scope" to JsonString("agent"),
                        "content" to JsonString("other"),
                        "version" to JsonNumber("1"),
                        "expected_version" to JsonNumber("0"),
                        "updated_at_ms" to JsonNumber("1760000000000"),
                        "author" to JsonObject(
                            mapOf(
                                "bot_id" to JsonString("bot-a"),
                                "kind" to JsonString("chat"),
                            ),
                        ),
                        "evidence" to JsonArray(emptyList()),
                    ),
                ),
            )
            val reopened = harness.storeFor("bot-a")
            try {
                reopened.documents()
                fail("a conflicting duplicate version must fail closed")
            } catch (error: BotMemoryStoreException) {
                assertEquals("corrupted", error.code)
            }
        }
    }

    @Test
    fun snippetNeverExceedsTheScalarLimitAndNeverSplitsASurrogatePair() {
        val fire = "\uD83D\uDD25"
        val content = fire.repeat(600)
        val snippet = BotMemoryDocumentRecallIndex.snippet(content, "", "")
        assertTrue(snippet.length > 1)
        assertTrue(BotMemoryText.scalarCount(snippet) <= 500)
        assertFalse(hasLoneSurrogate(snippet))
        assertTrue(snippet.endsWith("…"))

        val combining = ("a\u0301").repeat(300)
        val combinedSnippet = BotMemoryDocumentRecallIndex.snippet(combining, "", "")
        assertTrue(BotMemoryText.scalarCount(combinedSnippet) <= 500)
        assertFalse(hasLoneSurrogate(combinedSnippet))

        val short = BotMemoryDocumentRecallIndex.snippet("  hello  ", "", "")
        assertEquals("hello", short)
        assertEquals("（空）", BotMemoryDocumentRecallIndex.snippet("   ", "", ""))
    }

    @Test
    fun graphemeCapDoesNotSplitAFamilyCluster() {
        val family = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"
        val capped = BotMemoryText.cappedAtGrapheme("a$family", 2)
        assertEquals("a", capped)
        assertEquals("a$family", BotMemoryText.cappedAtGrapheme("a$family", 100))
    }

    @Test
    fun indexLimitUsesUnicodeScalarsNotUtf16Units() {
        MemoryHarness().use { harness ->
            val fire = "\uD83D\uDD25"
            val accepted = harness.store.write(
                BotMemoryStoreWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/INDEX.md",
                    content = fire.repeat(1_500),
                    expectedVersion = 0,
                    author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.CHAT),
                    atMs = 1_760_000_000_000,
                ),
            )
            assertTrue(accepted is BotMemoryStoreWriteOutcome.Written)
            val rejected = harness.store.write(
                BotMemoryStoreWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/INDEX.md",
                    content = fire.repeat(1_501),
                    expectedVersion = 1,
                    author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.CHAT),
                    atMs = 1_760_000_000_001,
                ),
            )
            assertTrue(rejected is BotMemoryStoreWriteOutcome.IndexTooLong)
            assertEquals(1_501, (rejected as BotMemoryStoreWriteOutcome.IndexTooLong).actual)
        }
    }

    @Test
    fun replaySkipsAnErasedTombstoneAndKeepsForwardVersionNumbers() {
        MemoryHarness().use { harness ->
            writeDocumentVersion(harness.store, "agent/a.md", "one", 0)
            writeDocumentVersion(harness.store, "agent/a.md", "two", 1)
            // Erasing the payload leaves a header/tombstone with no path or
            // version. The next write may therefore jump forward.
            harness.store.erase(
                path = "agent/a.md",
                author = BotMemoryAuthor("bot-a", null, BotMemoryAuthorKind.UI),
                atMs = 1_760_000_000_000,
            )
            val refreshed = harness.storeFor("bot-a")
            val outcome = refreshed.write(
                BotMemoryStoreWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/a.md",
                    content = "three",
                    expectedVersion = 0,
                    author = BotMemoryAuthor("bot-a", "gb-main", BotMemoryAuthorKind.CHAT),
                    atMs = 1_760_000_000_000,
                ),
            )
            assertTrue(outcome is BotMemoryStoreWriteOutcome.Written)
            assertEquals("three", refreshed.document("agent/a.md")?.content)
            assertNull(refreshed.versions("agent/a.md").firstOrNull { it.version == 2 })
        }
    }

    private fun hasLoneSurrogate(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (Character.isHighSurrogate(char)) {
                if (index + 1 >= value.length || !Character.isLowSurrogate(value[index + 1])) {
                    return true
                }
                index += 2
            } else if (Character.isLowSurrogate(char)) {
                return true
            } else {
                index += 1
            }
        }
        return false
    }
}
