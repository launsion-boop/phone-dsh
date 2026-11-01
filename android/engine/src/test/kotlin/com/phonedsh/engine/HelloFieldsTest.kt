// phone-dsh — :engine / com.phonedsh.engine: HELLO field reads, JVM.
// SPDX-License-Identifier: MIT
//
// The JSON below is the canonical shape the Rust codec returns (sorted members,
// no whitespace, channel.md §5). This proves the engine's field reads work on the
// platform JSON parser and that a worker HELLO without next_mseq/acked_mseq and a
// host HELLO without last_mseq answer zero instead of throwing.

package com.phonedsh.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HelloFieldsTest {
    private val workerHello =
        """{"boot_id":"00112233445566778899aabbccddeeff","caps":["channel/1","vfs-sink/1","journal/1","api/1"],""" +
            """"fence":{"generation":0,"owner":"phone","wal_seq":0},"last_mseq":41,"proto":1,"role":"worker","session_epoch":1}"""

    private val hostHello =
        """{"acked_mseq":41,"boot_id":"00112233445566778899aabbccddeeff","caps":["channel/1","wal/1","exec/1"],"durable_mseq":41,"fence":{"generation":0,"owner":"phone","wal_seq":0},"next_mseq":42,"proto":1,"role":"host","session_epoch":1}"""

    @Test
    fun readsTheWorkerHello() {
        assertEquals(1, HelloFields.proto(workerHello))
        assertEquals("worker", HelloFields.role(workerHello))
        assertEquals(listOf("channel/1", "vfs-sink/1", "journal/1", "api/1"), HelloFields.caps(workerHello))
        // The worker HELLO carries neither next_mseq nor acked_mseq.
        assertEquals(0L, HelloFields.nextMseq(workerHello))
        assertEquals(0L, HelloFields.ackedMseq(workerHello))
    }

    @Test
    fun readsTheHostHello() {
        assertEquals(1, HelloFields.proto(hostHello))
        assertEquals("host", HelloFields.role(hostHello))
        assertEquals(listOf("channel/1", "wal/1", "exec/1"), HelloFields.caps(hostHello))
        assertEquals(42L, HelloFields.nextMseq(hostHello))
        assertEquals(41L, HelloFields.ackedMseq(hostHello))
    }

    @Test
    fun missingMembersAnswerZeroValues() {
        val empty = "{}"
        assertEquals(0, HelloFields.proto(empty))
        assertNull(HelloFields.role(empty))
        assertEquals(emptyList<String>(), HelloFields.caps(empty))
        assertEquals(0L, HelloFields.nextMseq(empty))
        assertEquals(0L, HelloFields.ackedMseq(empty))
    }
}
