// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** One real write -> read -> recall -> injection flow over a temp SQLite log. */
class MemoryEndToEndTest {
    @Test
    fun writeReadRecallAndInjectionShareTheSameDurableTree() {
        MemoryHarness().use { harness ->
            val memory = harness.memoryFor("bot-a", prepareIndexes = false)
            val userContext = writeContext(
                trust = BotMemoryTrust.USER,
                sourceKind = BotMemorySourceKind.USER_TURN,
                currentUserTurnReference = "record://session/gb-main#3",
            )
            val userIndex = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "user/INDEX.md",
                    content = "# Index\n\n- notes/drinks.md",
                    expectedVersion = 0,
                    evidence = listOf(BotMemoryEvidence.CURRENT_USER_TURN),
                ),
                userContext,
            )
            assertTrue(userIndex.ok)
            assertEquals(1, userIndex.version)

            val drink = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "user/notes/drinks.md",
                    content = "# Drinks\n\n- 我喜欢燕麦拿铁",
                    expectedVersion = 0,
                    evidence = listOf("record://session/gb-main#3"),
                ),
                userContext,
            )
            assertTrue(drink.ok)
            assertEquals("record://session/gb-main#3",
                harness.store.document("user/notes/drinks.md")!!.evidence.single())

            val agentIndex = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/INDEX.md",
                    content = "# Index\n\n- notes/plan.md",
                    expectedVersion = 0,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT),
            )
            assertTrue(agentIndex.ok)
            memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "agent/notes/plan.md",
                    content = "# Plan\n\n- ship it",
                    expectedVersion = 0,
                ),
                writeContext(trust = BotMemoryTrust.ASSISTANT),
            )

            val read = memory.read("user/notes/drinks.md")
            assertTrue(read is BotMemoryReadResult.Document)
            assertEquals("- 我喜欢燕麦拿铁", (read as BotMemoryReadResult.Document).version.content.lines().last())

            val hits = memory.recall("燕麦拿铁", limit = 5, scope = BotMemoryScope.USER)
            assertEquals(listOf("user/notes/drinks.md"), hits.map { it.path })
            assertTrue(hits.single().snippet.contains("燕麦拿铁"))

            val injection = memory.injection()
            assertTrue(injection.text.contains("# Index\n\n- notes/drinks.md"))
            assertTrue(injection.text.contains("# Index\n\n- notes/plan.md"))
            assertTrue(!injection.text.contains("我喜欢燕麦拿铁"))
            assertEquals(1_500, injection.limits.index)

            val forget = memory.forget("user/notes/drinks.md", 1)
            assertTrue(forget.ok)
            assertEquals(2, forget.version)
            assertNull(harness.store.document("user/notes/drinks.md"))
            val history = memory.read("user/notes/drinks.md", 1)
            assertTrue(history is BotMemoryReadResult.Document)
            assertEquals("- 我喜欢燕麦拿铁",
                (history as BotMemoryReadResult.Document).version.content.lines().last())
            assertTrue(memory.recall("燕麦拿铁", scope = BotMemoryScope.USER).isEmpty())
        }
    }

    @Test
    fun markedContradictionAppendsAReviewRequestWithoutChangingTrust() {
        MemoryHarness().use { harness ->
            val memory = harness.memoryFor("bot-a", prepareIndexes = false)
            val result = memory.write(
                BotMemoryWriteRequest(
                    action = BotMemoryAction.WRITE,
                    path = "user/profile.md",
                    content = "# Profile\n\n- 喜欢简短回答",
                    expectedVersion = 0,
                    evidence = listOf("record://session/gb-main#3"),
                    markedContradiction = true,
                ),
                writeContext(
                    trust = BotMemoryTrust.USER,
                    sourceKind = BotMemorySourceKind.USER_TURN,
                ),
            )
            assertTrue(result is BotMemoryWriteResult.Success)
            val review = harness.domain.events(0, 100).single { it.type == "memory.review_requested" }
            val data = review.data as com.phonedsh.agentcore.JsonObject
            assertEquals("user/profile.md",
                (data.members["path"] as com.phonedsh.agentcore.JsonString).value)
            assertEquals("user",
                (data.members["scope"] as com.phonedsh.agentcore.JsonString).value)
            assertEquals("user", harness.store.document("user/profile.md")!!.trust?.wire)
        }
    }
}
