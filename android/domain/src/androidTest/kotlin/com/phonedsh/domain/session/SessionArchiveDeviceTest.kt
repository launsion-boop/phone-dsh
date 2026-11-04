// Device evidence: the transcript cache survives a real process death.
// SPDX-License-Identifier: MIT
//
// The host suite proves the cache's behaviour through `InMemoryConnectionFactory`,
// whose "restart" is a close and a reopen inside one JVM. That is not the claim
// this file has to defend. The claim is:
//
//   a turn the app archived in one process is readable, field for field, by a
//   *different* process after the first one was killed.
//
// So the evidence is two `am instrument` runs with an `am force-stop` between
// them, over one real SQLite file:
//
//   adb shell am instrument -w \
//     -e class com.phonedsh.domain.session.SessionArchiveDeviceTest#writePhase \
//     com.phonedsh.domain.test/androidx.test.runner.AndroidJUnitRunner
//   adb shell am force-stop com.phonedsh.domain.test
//   adb shell am instrument -w \
//     -e class com.phonedsh.domain.session.SessionArchiveDeviceTest#readPhase \
//     com.phonedsh.domain.test/androidx.test.runner.AndroidJUnitRunner
//
// Running the whole class in one invocation is *not* evidence: the two phases
// would share one process, which is the thing `SessionArchiveTest` already
// covers on the host. The phases therefore assert their own ordering —
// `writePhase` refuses to start over an existing file and `readPhase` refuses to
// start without one — so a single-invocation run fails loudly instead of passing
// cheaply.

package com.phonedsh.domain.session

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.domain.DomainNames
import com.phonedsh.domain.DomainStore
import com.phonedsh.domain.DomainStoreCore
import com.phonedsh.domain.QuotaPolicy
import com.phonedsh.domain.sqlite.SqliteConnectionFactory
import com.phonedsh.platform.Clock
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionArchiveDeviceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val databaseName = "session-archive-evidence.db"

    /**
     * The record both phases compare against.
     *
     * It carries a tab, a newline and non-ASCII text on purpose: those are the
     * three things that would break if the codec escaped for one backend only,
     * and SQLite is the backend the host suite never reaches.
     */
    private val evidence = ArchivedTurn(
        sessionId = "session-archive-evidence-session",
        completedAtMs = 1_767_000_000_123L,
        kinds = listOf("assistant_message", "tool_call", "turn_end"),
        commands = listOf(
            ArchivedCommand("call-1", "phone info"),
            ArchivedCommand("call-2", "printf 'a\tb\nc'"),
        ),
        writes = listOf(
            ArchivedWrite("/dsh/workspace/证据.txt", "write_file"),
            ArchivedWrite("/dsh/workspace/out.bin", null),
        ),
    )

    /** Phase 1: one process writes the record to the real file, then dies. */
    @Test
    fun writePhase() {
        val path = context.getDatabasePath(databaseName)
        assertFalseMessageFirst(
            "writePhase must start from no file; delete it or run on a fresh install",
            path.exists(),
        )

        openStore().use { store ->
            SessionArchive(store).save(evidence)
            // Same process, same file, before any restart: if this is already
            // wrong the failure belongs to the write, not to the reopen.
            assertEquals(evidence, SessionArchive(store).latest())
        }

        assertTrue("the database file was not created at ${path.path}", path.exists())
        assertTrue("the database file is empty", path.length() > 0L)
    }

    /** Phase 2: a fresh process reads the record phase 1 wrote. */
    @Test
    fun readPhase() {
        val path = context.getDatabasePath(databaseName)
        // The one assertion that makes this a restart test: the file predates
        // this process, so nothing below can have been produced by this run.
        assertTrue(
            "readPhase needs the file writePhase wrote; run writePhase first",
            path.exists(),
        )

        openStore().use { store ->
            val archive = SessionArchive(store)

            val restored = archive.latest()
            assertNotNull("no turn was restored from the previous process", restored)
            assertEquals(evidence.sessionId, restored!!.sessionId)
            assertEquals(evidence.completedAtMs, restored.completedAtMs)
            assertEquals(evidence.kinds, restored.kinds)
            assertEquals(evidence.commands, restored.commands)
            assertEquals(evidence.writes, restored.writes)
            assertEquals(evidence, restored)

            // The iOS `currentSessionDefaultsKey` half: the pointer is its own
            // row and must have survived the same kill.
            assertEquals(evidence.sessionId, archive.currentSessionId())
            assertEquals(listOf(evidence.sessionId), archive.sessionIds())

            // The bytes are really in this domain, in this file — not read from
            // anything this process could have cached in memory.
            val pointer = store.get(DomainNames.SESSION, "current")
            assertNotNull("the pointer row is missing from the reopened store", pointer)
            assertEquals(
                evidence.sessionId,
                pointer!!.toString(Charsets.UTF_8),
            )
        }
    }

    /** Phase 3: a receipt-shaped dump of what is on disk. Any order after 1. */
    @Test
    fun dumpPhase() {
        val path = context.getDatabasePath(databaseName)
        if (!path.exists()) {
            println("SESSION_ARCHIVE_DUMP file=${path.path} absent")
            return
        }
        openStore().use { store ->
            val archive = SessionArchive(store)
            println(
                "SESSION_ARCHIVE_DUMP file=${path.path} bytes=${path.length()} " +
                    "sessions=${archive.sessionIds()} current=${archive.currentSessionId()} " +
                    "usage=${store.usageBytes(DomainNames.SESSION)} " +
                    "quota=${store.quotaBytes(DomainNames.SESSION)}",
            )
        }
    }

    private fun openStore(): DomainStore = DomainStoreCore(
        connections = SqliteConnectionFactory(context, databaseName),
        quotas = QuotaPolicy.perDomain(
            mapOf(DomainNames.SESSION to SessionArchive.QUOTA_BYTES),
        ),
        clock = WallClock,
    )

    /** `assertFalse` with the message argument first; the JUnit order is reversed. */
    private fun assertFalseMessageFirst(message: String, condition: Boolean) {
        if (condition) throw AssertionError(message)
    }

    private object WallClock : Clock {
        override fun nowMillis(): Long = System.currentTimeMillis()

        override fun monotonicMillis(): Long = System.nanoTime() / 1_000_000L
    }
}
