// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision
import com.phonedsh.ui.state.PendingAnswer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatInteractionActionsTest {
    @Test
    fun absentCallbacksAreExplicitlyUnavailable() {
        val actions = ChatInteractionActions()
        val unavailable = PdshUnavailableReason.NOT_IMPLEMENTED

        assertEquals(unavailable, (actions.approveAvailability as PdshActionAvailability.Unavailable).reason)
        assertEquals(unavailable, (actions.answerAvailability as PdshActionAvailability.Unavailable).reason)
        assertEquals(unavailable, (actions.goalCommandAvailability as PdshActionAvailability.Unavailable).reason)
        assertEquals(unavailable, (actions.selectModelAvailability as PdshActionAvailability.Unavailable).reason)
        assertEquals(unavailable, (actions.executeCommandAvailability as PdshActionAvailability.Unavailable).reason)
        PdshActionKey.values().forEach { key ->
            assertTrue(PdshActionAvailabilities().forAction(key) is PdshActionAvailability.Unavailable)
        }
        try {
            actions.approve(PendingAnswer("ask-1", "request-1", "permission", "Permission", "Allow?"))
            throw AssertionError("missing callback must not behave like a successful action")
        } catch (expected: PdshActionUnavailableException) {
            assertEquals(unavailable, expected.reason)
        }
    }

    @Test
    fun legacyCallableAdapterUsesTheRealCallback() {
        val pending = PendingAnswer("ask-1", "request-1", "permission", "Permission", "Allow?")
        var received: PendingAnswer? = null
        val actions = ChatInteractionActions(approve = { received = it })

        assertTrue(actions.approveAvailability is PdshActionAvailability.Available)
        actions.approve(pending)
        assertEquals(pending, received)
    }

    @Test
    fun dispatchRequiresARealCallbackAndPreservesTheRequest() {
        val expected = PdshUiHostCommand.NewSession(StateRequestId("new-session-2"))
        var received: PdshUiHostCommand? = null
        val unavailable = PdshActionAvailabilities()
        assertFalse(unavailable.dispatch(PdshActionKey.NEW_SESSION, expected))

        val available = PdshActionAvailabilities(
            byAction = mapOf(
                PdshActionKey.NEW_SESSION to PdshActionAvailability.Available { received = it },
            ),
        )
        assertTrue(available.dispatch(PdshActionKey.NEW_SESSION, expected))
        assertEquals(expected, received)
        assertFalse(available.dispatch(PdshActionKey.NEW_SESSION, PdshUiHostCommand.OpenSettings))
    }

    @Test
    fun onlyMatchingNewerHostReceiptConfirmsARequest() {
        val requestId = StateRequestId("provider-save-17")
        val baseline = StateRevision(4)
        val success = PdshActionReceipt(requestId, "session-a", StateRevision(5), PdshActionOutcome.SUCCEEDED)

        assertTrue(success.confirms(requestId, "session-a", baseline))
        assertFalse(success.confirms(StateRequestId("provider-save-16"), "session-a", baseline))
        assertFalse(success.confirms(requestId, "session-b", baseline))
        assertFalse(success.copy(revision = baseline).confirms(requestId, "session-a", baseline))
        assertFalse(success.copy(outcome = PdshActionOutcome.FAILED).confirms(requestId, "session-a", baseline))
        assertFalse(success.copy(revision = null).confirms(requestId, "session-a", baseline))

        val provider = PdshProviderOperationFact(
            operation = PdshProviderOperation.SAVE,
            requestId = requestId,
            profileId = "profile-3",
            receipt = success.copy(sessionId = null),
        )
        assertTrue(provider.confirms(PdshProviderOperation.SAVE, requestId, "profile-3", baseline))
        assertFalse(provider.confirms(PdshProviderOperation.TEST, requestId, "profile-3", baseline))
        assertFalse(provider.confirms(PdshProviderOperation.SAVE, StateRequestId("provider-save-18"), "profile-3", baseline))
        assertFalse(provider.confirms(PdshProviderOperation.SAVE, requestId, "profile-4", baseline))
    }

    @Test
    fun mutatingChatActionPreservesCallerRequestAndSessionIdentity() {
        val requestId = StateRequestId("send-9")
        val action = PdshUiHostCommand.Send("session-42", requestId, "hello")
        var received: PdshUiHostCommand? = null
        val availability = PdshActionAvailabilities(
            mapOf(PdshActionKey.SEND to PdshActionAvailability.Available { received = it }),
        )
        assertTrue(availability.dispatch(PdshActionKey.SEND, action))
        assertEquals(action, received)
        assertEquals(requestId, action.requestId)
        assertEquals("session-42", action.sessionId)
    }
}
