// SPDX-License-Identifier: MIT
// The queued-delivery preparation matrix (spec/host/v1/README.md section 10.1).
// Port of `examples/probe-app/PhoneDSHSimTests/ChatDeliveryPreparationTests.swift`.
// The iOS "resident audio" input has no Android counterpart; the Android
// residency input is the held turn window (`keepingAlive`), so the residency rows
// are run with that input.
package com.phonedsh.probe.outbox

import com.phonedsh.probe.outbox.ChatDeliveryPreparation.DEFERRED
import com.phonedsh.probe.outbox.ChatDeliveryPreparation.NEEDS_ATTENTION
import com.phonedsh.probe.outbox.ChatDeliveryPreparation.READY
import com.phonedsh.probe.outbox.ChatDeliveryPreparation.RESUME
import com.phonedsh.probe.outbox.ChatDeliveryPreparation.START
import com.phonedsh.probe.outbox.ChatDeliveryPreparation.WAIT
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatDeliveryPreparationTest {
    private fun decision(
        foreground: Boolean = true,
        keepingAlive: Boolean = false,
        host: Boolean = true,
        parked: Boolean = false,
        transition: Boolean = false,
        busy: Boolean = false,
        ready: Boolean = true,
        recovery: Boolean = false,
        paused: Boolean = false,
    ) = ChatDeliveryPreparation.decide(
        foreground = foreground, keepingAlive = keepingAlive, hostPresent = host, parked = parked,
        transitioning = transition, busy = busy, transportReady = ready, requiresRecovery = recovery,
        userPaused = paused,
    )

    @Test
    fun `an existing host is not proof of readiness`() {
        assertEquals(RESUME, decision(parked = true))
        assertEquals(WAIT, decision(ready = false))
        assertEquals(WAIT, decision(transition = true))
        assertEquals(WAIT, decision(busy = true))
        assertEquals(READY, decision())
        assertEquals(START, decision(host = false, ready = false))
    }

    @Test
    fun `background without a held window never starts or resumes`() {
        assertEquals(DEFERRED, decision(foreground = false, host = false))
        assertEquals(DEFERRED, decision(foreground = false, parked = true))
        assertEquals(DEFERRED, decision(foreground = false))
        assertFalse(ChatDeliveryPreparation.executionEligible(foreground = false, keepingAlive = false))
    }

    @Test
    fun `a held turn window makes background delivery direct`() {
        assertEquals(READY, decision(foreground = false, keepingAlive = true))
        assertEquals(RESUME, decision(foreground = false, keepingAlive = true, parked = true))
        assertEquals(START, decision(foreground = false, keepingAlive = true, host = false, ready = false))
        assertTrue(ChatDeliveryPreparation.executionEligible(foreground = false, keepingAlive = true))
        assertTrue(ChatDeliveryPreparation.executionEligible(foreground = true, keepingAlive = false))
        // Residency never overrides manual recovery or an explicit stop.
        assertEquals(
            NEEDS_ATTENTION,
            decision(foreground = false, keepingAlive = true, parked = true, ready = false, recovery = true),
        )
        assertEquals(
            NEEDS_ATTENTION,
            decision(foreground = false, keepingAlive = true, host = false, ready = false, paused = true),
        )
    }

    @Test
    fun `recovery and transitions remain authoritative`() {
        assertEquals(NEEDS_ATTENTION, decision(host = false, ready = false, paused = true))
        assertEquals(NEEDS_ATTENTION, decision(host = false, recovery = true))
        assertEquals(NEEDS_ATTENTION, decision(parked = true, recovery = true))
        assertEquals(WAIT, decision(host = false, transition = true))
        assertEquals(WAIT, decision(parked = true, busy = true))
    }

    @Test
    fun `the facts value decides exactly like the function`() {
        for (bits in 0 until 512) {
            fun bit(index: Int) = bits shr index and 1 == 1
            val facts = ChatDeliveryFacts(bit(0), bit(1), bit(2), bit(3), bit(4), bit(5), bit(6), bit(7))
            assertEquals(
                ChatDeliveryPreparation.decide(bit(0), bit(1), bit(2), bit(3), bit(4), bit(5), bit(6), bit(7), bit(8)),
                facts.decide(userPaused = bit(8)),
            )
            assertEquals(bit(0) || bit(1), facts.executionEligible)
        }
    }

    private fun withOutbox(block: (File) -> Unit) {
        val root = Files.createTempDirectory("delivery-preparation").toFile()
        try {
            block(root)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `eligibility lost before transport can defer without changing identity`() = withOutbox { root ->
        val queue = SendOutbox(root)
        val entry = queue.enqueue("original-session", "defer")
        queue.markSubmitting(entry.rpcId)
        assertEquals(DEFERRED, decision(foreground = false, parked = true))
        // This sender has not invoked transport. Recovered entries do not have this proof.
        queue.markOutcomeUnknown(entry.rpcId, "not submitted")
        queue.requeue(entry.rpcId)
        val saved = SendOutbox(root).entry(entry.rpcId)
        assertEquals(SendOutboxState.QUEUED, saved?.state)
        assertEquals(entry.sessionId, saved?.sessionId)
        assertEquals(entry.rpcId, saved?.rpcId)
    }

    @Test
    fun `deferred delivery survives reopen with its original destination and key`() = withOutbox { root ->
        val entry = SendOutbox(root).enqueue("original-session", "处理设备消息")
        assertEquals(DEFERRED, decision(foreground = false, parked = true))
        val reopened = SendOutbox(root)
        val saved = reopened.entry(entry.rpcId)
        assertEquals("original-session", saved?.sessionId)
        assertEquals(entry.rpcId, saved?.rpcId)
        assertEquals(SendOutboxState.QUEUED, saved?.state)
        // Preparation is not a delivery receipt and cannot mutate the queue.
        assertEquals(RESUME, decision(parked = true))
        assertEquals(saved, reopened.entry(entry.rpcId))
    }
}
