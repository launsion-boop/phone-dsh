// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BleScanSourcePrivacyTest {
    private val first = BleScanCandidate(
        id = "opaque-test-id-first-73129",
        name = "测试设备-私人广告名-first",
        rssi = -73,
    )
    private val second = BleScanCandidate(
        id = "opaque-test-id-second-84153",
        name = "测试设备-私人广告名-second",
        rssi = -84,
    )

    private fun assertCandidateValuesRedacted(output: String, candidate: BleScanCandidate) {
        assertFalse("candidate id leaked", output.contains(candidate.id))
        assertFalse("advertisement name leaked", output.contains(candidate.name))
        assertFalse("candidate RSSI leaked", output.contains(candidate.rssi.toString()))
    }

    @Test
    fun candidateAndSnapshotStringsDoNotExposeCandidates() {
        val snapshot = BleScanSnapshot(
            phase = BleScanPhase.CLEANUP_REQUIRED,
            candidates = listOf(first, second),
            failure = BleScanFailure.STOP_FAILED,
        )
        assertCandidateValuesRedacted(first.toString(), first)
        assertCandidateValuesRedacted(second.toString(), second)
        for (candidate in snapshot.candidates) {
            assertCandidateValuesRedacted(snapshot.toString(), candidate)
        }
        assertTrue(snapshot.toString().contains("CLEANUP_REQUIRED"))
        assertTrue(snapshot.toString().contains("STOP_FAILED"))
    }

    @Test
    fun candidateEqualityHashAndCopyStillUseEveryField() {
        val same = first.copy()
        assertEquals(first, same)
        assertEquals(first.hashCode(), same.hashCode())
        assertNotEquals(first, first.copy(id = second.id))
        assertNotEquals(first, first.copy(name = second.name))
        assertNotEquals(first, first.copy(rssi = second.rssi))
        assertEquals(second, first.copy(id = second.id, name = second.name, rssi = second.rssi))
    }

    @Test
    fun snapshotEqualityHashAndCopyStillUseEveryField() {
        val snapshot = BleScanSnapshot(BleScanPhase.SCANNING, listOf(first), null)
        val same = snapshot.copy(candidates = listOf(first.copy()))
        assertEquals(snapshot, same)
        assertEquals(snapshot.hashCode(), same.hashCode())
        assertNotEquals(snapshot, snapshot.copy(phase = BleScanPhase.STOPPED))
        assertNotEquals(snapshot, snapshot.copy(candidates = listOf(second)))
        assertNotEquals(snapshot, snapshot.copy(failure = BleScanFailure.SCAN_FAILED))
        val modified = snapshot.copy(
            phase = BleScanPhase.CLEANUP_REQUIRED,
            candidates = listOf(second),
            failure = BleScanFailure.STOP_FAILED,
        )
        assertEquals(BleScanSnapshot(BleScanPhase.CLEANUP_REQUIRED, listOf(second), BleScanFailure.STOP_FAILED), modified)
        assertCandidateValuesRedacted(modified.toString(), second)
    }
}
