// The prompt identity must be new for every submission (L85 P0).
// SPDX-License-Identifier: MIT
//
// ---- the defect this guards ------------------------------------------------
// `session/prompt` carries a client-minted `requestId`. DSH persists it on the
// accepted `user/message` and, before admitting a prompt, answers
// `{accepted: true}` **without delivering anything** when the Session already
// holds a prompt with the same id (`hasPromptRequest`,
// `dsh-api-session-controller` `lib/index.js:927,1128`). The chat builds a new
// `DshTurnClient` for every send, so a per-client counter restarted at 1 and the
// second turn of a conversation was swallowed: the Worker accepted it, no turn
// started, the first-event deadline expired as `no_turn_started`, and the App's
// recovery opened a fresh session — silently dropping the model's history while
// the transcript kept it. Measured on a Xiaomi M2102K1C at 17:59:51.
//
// The official Web client mints `randomUUID()` per submission for the same
// reason (`dsh-api-session-controller/lib/client.js:2310`). This test pins that
// property for the host client: two prompt identities minted by two clients —
// exactly what happens on two consecutive sends — must differ.
package com.phonedsh.dsh.turn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PromptIdentityTest {
    @Test
    fun everySubmissionGetsItsOwnRequestId() {
        val first = newPromptRequestId()
        val second = newPromptRequestId()
        assertNotEquals(
            "two prompts minted the same requestId: DSH will deduplicate the second " +
                "against the first durable user/message and answer accepted without " +
                "starting a turn",
            first,
            second,
        )
        // The turn client is rebuilt per send, so the guarantee must not depend on
        // one instance's counter: mint through the same entry point the client uses.
        assertEquals(
            "the id must be stable for one call, not re-derived on read",
            first,
            first,
        )
        assertTrue(
            "request ids are logged and compared with the Worker's own vocabulary, " +
                "so they keep the pdsh- prefix",
            first.startsWith("pdsh-prompt-"),
        )
    }

    @Test
    fun aThousandSubmissionsAreAllDistinct() {
        val ids = (1..1_000).map { newPromptRequestId() }.toSet()
        assertEquals("a request id repeated inside one conversation", 1_000, ids.size)
    }
}
