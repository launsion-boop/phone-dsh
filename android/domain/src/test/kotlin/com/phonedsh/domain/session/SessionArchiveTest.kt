// The transcript cache over the domain store: round trip, restart, corruption.
// SPDX-License-Identifier: MIT
//
// The host suite drives the cache through `InMemoryConnectionFactory`, whose
// documented property is that closing a store keeps the data: reopening through
// the same factory models a process restart over the same file. The device suite
// (`SessionArchiveDeviceTest`) runs the same restart across two real processes
// and the real SQLite file; this suite is what makes the *behaviour* cheap to
// pin on every change.

package com.phonedsh.domain.session

import com.phonedsh.domain.DomainNames
import com.phonedsh.domain.DomainStore
import com.phonedsh.domain.DomainStoreCore
import com.phonedsh.domain.FakeClock
import com.phonedsh.domain.QuotaPolicy
import com.phonedsh.domain.testing.InMemoryConnectionFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionArchiveTest {
    private val factory = InMemoryConnectionFactory()

    private fun openStore(quotaBytes: Long = SessionArchive.QUOTA_BYTES): DomainStore =
        DomainStoreCore(
            connections = factory,
            quotas = QuotaPolicy.perDomain(mapOf(DomainNames.SESSION to quotaBytes)),
            clock = FakeClock(1_000L),
        )

    private fun openArchive(quotaBytes: Long = SessionArchive.QUOTA_BYTES): SessionArchive =
        SessionArchive(openStore(quotaBytes))

    private fun turn(
        sessionId: String = "s-1",
        completedAtMs: Long = 1_700_000_000_000L,
        kinds: List<String> = listOf("assistant_message", "tool_call", "turn_end"),
        commands: List<ArchivedCommand> = listOf(ArchivedCommand("call-1", "phone info")),
        writes: List<ArchivedWrite> = listOf(ArchivedWrite("/dsh/workspace/out.txt", "write_file")),
    ): ArchivedTurn = ArchivedTurn(sessionId, completedAtMs, kinds, commands, writes)

    // ---- the round trip -----------------------------------------------------

    @Test
    fun aSavedTurnIsReadBackFieldForField() {
        val saved = turn()
        openArchive().save(saved)

        val restored = openArchive().latest()

        assertEquals(saved.sessionId, restored?.sessionId)
        assertEquals(saved.completedAtMs, restored?.completedAtMs)
        assertEquals(saved.kinds, restored?.kinds)
        assertEquals(saved.commands, restored?.commands)
        assertEquals(saved.writes, restored?.writes)
    }

    @Test
    fun anEmptyTurnRoundTripsAsEmptyListsNotAsAbsent() {
        val saved = ArchivedTurn("s-empty", 7L)
        openArchive().save(saved)

        val restored = openArchive().latest()

        assertEquals("s-empty", restored?.sessionId)
        assertEquals(emptyList<String>(), restored?.kinds)
        assertEquals(emptyList<ArchivedCommand>(), restored?.commands)
        assertEquals(emptyList<ArchivedWrite>(), restored?.writes)
    }

    @Test
    fun structuralCharactersAndControlCharactersSurvive() {
        val hostile = ArchivedTurn(
            sessionId = "s\twith\ntab-and-newline",
            completedAtMs = 1L,
            kinds = listOf("a\\nb", "back\\slash", "carriage\rreturn", ""),
            commands = listOf(ArchivedCommand("id\twith\ttabs", "cmd with \n newline")),
            writes = listOf(ArchivedWrite("path\\with\\backslashes", null)),
        )
        openArchive().save(hostile)

        val restored = openArchive().latest()

        assertEquals(hostile.sessionId, restored?.sessionId)
        assertEquals(hostile.kinds, restored?.kinds)
        assertEquals(hostile.commands, restored?.commands)
        assertEquals(hostile.writes, restored?.writes)
        assertNull("a blank tool name is the absence of a tool name", restored?.writes?.get(0)?.toolName)
    }

    @Test
    fun aUnicodeSessionIdAndPayloadSurvive() {
        val saved = ArchivedTurn(
            sessionId = "会话-🙂-1",
            completedAtMs = 5L,
            kinds = listOf("助手消息"),
            commands = listOf(ArchivedCommand("调用", "列目录")),
        )
        openArchive().save(saved)

        assertEquals(saved, openArchive().latest())
    }

    // ---- the restart --------------------------------------------------------

    @Test
    fun aTurnWrittenBeforeACloseIsReadByTheNextStoreOverTheSameFile() {
        val store = openStore()
        SessionArchive(store).save(turn(sessionId = "survives-restart"))
        store.close()

        // A new store, a new archive, the same backing file: this is the shape of
        // "the process died and started again".
        val reopened = openArchive().latest()

        assertEquals("survives-restart", reopened?.sessionId)
        assertEquals(listOf(ArchivedCommand("call-1", "phone info")), reopened?.commands)
    }

    @Test
    fun thePointerSurvivesACloseIndependentlyOfThePayload() {
        val store = openStore()
        SessionArchive(store).save(turn(sessionId = "s-9"))
        store.close()

        assertEquals("s-9", openArchive().currentSessionId())
    }

    // ---- the pointer --------------------------------------------------------

    @Test
    fun nothingSavedMeansNothingRestored() {
        val archive = openArchive()

        assertNull(archive.latest())
        assertNull(archive.currentSessionId())
        assertEquals(0, archive.sessionCount())
    }

    @Test
    fun theNewestSaveBecomesTheCurrentSession() {
        val archive = openArchive()
        archive.save(turn(sessionId = "s-1"))
        archive.save(turn(sessionId = "s-2", completedAtMs = 2L))

        assertEquals("s-2", archive.currentSessionId())
        assertEquals("s-2", archive.latest()?.sessionId)
        assertEquals(listOf("s-1", "s-2"), archive.sessionIds())
    }

    @Test
    fun clearingThePointerKeepsTheHistory() {
        val archive = openArchive()
        archive.save(turn(sessionId = "s-1"))

        assertTrue(archive.clearCurrent())

        assertNull(archive.latest())
        assertNull(archive.currentSessionId())
        assertEquals(listOf("s-1"), archive.sessionIds())
        assertFalse("clearing twice reports that nothing was there", archive.clearCurrent())
    }

    @Test
    fun aPointerWithoutAPayloadRestoresNothing() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        // Break the pair the way an outside writer would: the pointer stays, the
        // payload goes.
        store.delete(DomainNames.SESSION, "turn/s-1")

        assertNull(archive.latest())
        assertEquals("s-1", archive.currentSessionId())
    }

    @Test
    fun aPayloadFiledUnderTheWrongKeyRestoresNothing() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        // Copy the payload to another key and point at it: the record's own id
        // disagrees with the pointer, so no turn is reported.
        val payload = store.get(DomainNames.SESSION, "turn/s-1")!!
        store.put(DomainNames.SESSION, "turn/s-2", payload)
        store.put(DomainNames.SESSION, "current", "s-2".toByteArray(Charsets.UTF_8))

        assertNull(archive.latest())
    }

    // ---- corruption ---------------------------------------------------------

    @Test
    fun anUndecodablePayloadRestoresNothingRatherThanHalfATurn() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        store.put(DomainNames.SESSION, "turn/s-1", "not a record".toByteArray(Charsets.UTF_8))

        assertNull(archive.latest())
    }

    @Test
    fun aTruncatedPayloadRestoresNothing() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        val payload = store.get(DomainNames.SESSION, "turn/s-1")!!
        store.put(DomainNames.SESSION, "turn/s-1", payload.copyOf(payload.size / 2))

        assertNull(archive.latest())
    }

    @Test
    fun aPayloadWithAnUnreachableCountRestoresNothing() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        val payload = store.get(DomainNames.SESSION, "turn/s-1")!!.toString(Charsets.UTF_8)
        // Claim 400 commands and supply one: a decoder that trusted the count
        // would allocate the list and then throw out of `latest`.
        val lying = payload.replace("\n1\n", "\n400\n")
        store.put(DomainNames.SESSION, "turn/s-1", lying.toByteArray(Charsets.UTF_8))

        assertNull(archive.latest())
    }

    @Test
    fun anEmptyPayloadRestoresNothing() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        store.put(DomainNames.SESSION, "turn/s-1", ByteArray(0))

        assertNull(archive.latest())
    }

    @Test
    fun aBlankPointerValueRestoresNothing() {
        val store = openStore()
        val archive = SessionArchive(store)
        archive.save(turn(sessionId = "s-1"))
        store.put(DomainNames.SESSION, "current", ByteArray(0))

        assertNull(archive.latest())
        assertNull(archive.currentSessionId())
    }

    // ---- the capacity the baseline keeps ------------------------------------

    @Test
    fun theBaselineCapacityIsFourHundred() {
        assertEquals(400, SessionArchive.CAPACITY)
    }

    @Test
    fun aTurnAtCapacityIsStored() {
        val kinds = List(SessionArchive.CAPACITY) { "kind-$it" }
        openArchive().save(turn(sessionId = "s-max", kinds = kinds))

        assertEquals(kinds, openArchive().latest()?.kinds)
    }

    @Test(expected = IllegalArgumentException::class)
    fun aTurnPastCapacityIsRefusedInsteadOfSilentlyTrimmed() {
        turn(sessionId = "s-over", kinds = List(SessionArchive.CAPACITY + 1) { "kind-$it" })
    }

    @Test(expected = IllegalArgumentException::class)
    fun aTurnWithoutASessionIdIsRefused() {
        ArchivedTurn("   ", 1L)
    }

    // ---- the quota ----------------------------------------------------------

    @Test
    fun aWritePastTheDomainQuotaIsRefusedAndLeavesTheDomainUnchanged() {
        val archive = openArchive(quotaBytes = 512L)
        archive.save(turn(sessionId = "s-1", kinds = listOf("a")))
        val before = openArchive().latest()

        var refused = false
        try {
            archive.save(turn(sessionId = "s-2", kinds = List(20) { "x".repeat(64) }))
        } catch (quota: com.phonedsh.domain.QuotaExceededException) {
            refused = true
            assertEquals(DomainNames.SESSION, quota.domain)
        }

        assertTrue("a write past the quota must be reported, never applied", refused)
        assertEquals(before, archive.latest())
        assertEquals(listOf("s-1"), archive.sessionIds())
    }

    @Test
    fun aRefusedSaveLeavesNoPointerBehind() {
        // The quota fits the pointer (5 bytes) and not the payload, and `save`
        // writes the pointer first, so the pointer is already written when the
        // payload is refused. It must not survive: a pointer whose payload was
        // never stored makes the next cold start promise a session it cannot
        // render.
        val archive = openArchive(quotaBytes = 200L)

        val refused = runCatching {
            archive.save(turn(sessionId = "s-big", kinds = List(10) { "y".repeat(64) }))
        }.isFailure

        assertTrue(refused)
        assertNull("a refused save must not leave a pointer behind", archive.currentSessionId())
        assertNull(archive.latest())
        assertEquals(emptyList<String>(), archive.sessionIds())
    }

    // ---- isolation ----------------------------------------------------------

    @Test
    fun theCacheSharesTheStoreWithoutTouchingOtherDomains() {
        val store = openStore()
        val archive = SessionArchive(store)
        store.put(DomainNames.MEMORY, "record-1", byteArrayOf(1, 2, 3))
        archive.save(turn(sessionId = "s-1"))
        store.delete(DomainNames.SESSION, "turn/s-1")
        assertNull(archive.latest())

        assertEquals("another domain is a different key space", 3, store.get(DomainNames.MEMORY, "record-1")?.size)
    }
}
