// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** The version premise is checked inside the P25 write transaction. */
class MemoryConcurrencyTest {
    @Test
    fun onlyOneOfTwoRacingWritersCommitsTheSameVersion() {
        MemoryHarness().use { harness ->
            seedDocument(harness.store, "agent/race.md", "base", 1)
            val first = harness.storeFor("bot-a")
            val second = harness.storeFor("bot-a")
            assertEquals(1, first.document("agent/race.md")!!.version)
            assertEquals(1, second.document("agent/race.md")!!.version)

            val start = CountDownLatch(1)
            val finished = CountDownLatch(2)
            val executor = Executors.newFixedThreadPool(2)
            val outcomes = java.util.Collections.synchronizedList(
                ArrayList<BotMemoryStoreWriteOutcome>(),
            )
            fun writer(store: BotSqlMemoryDocumentStore, content: String) {
                executor.submit {
                    start.await()
                    runCatching {
                        outcomes += store.write(
                            BotMemoryStoreWriteRequest(
                                action = BotMemoryAction.WRITE,
                                path = "agent/race.md",
                                content = content,
                                expectedVersion = 1,
                                author = BotMemoryAuthor(
                                    "bot-a", "gb-main", BotMemoryAuthorKind.CHAT,
                                ),
                                atMs = 1_760_000_000_000,
                            ),
                        )
                    }.onFailure {
                        outcomes += BotMemoryStoreWriteOutcome.NotFound(it.toString())
                    }
                    finished.countDown()
                }
            }
            writer(first, "first")
            writer(second, "second")
            start.countDown()
            assertTrue("writers must finish", finished.await(15, TimeUnit.SECONDS))
            executor.shutdownNow()

            assertEquals(2, outcomes.size)
            assertEquals(1, outcomes.count { it is BotMemoryStoreWriteOutcome.Written })
            val conflict = outcomes.filterIsInstance<BotMemoryStoreWriteOutcome.Conflict>().single()
            assertEquals(2, conflict.currentVersion)
            val live = first.document("agent/race.md")!!
            assertEquals(2, live.version)
            assertTrue(live.content == "first" || live.content == "second")
            assertEquals(2, harness.domain.headCommitSeq())
        }
    }
}
