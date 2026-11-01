// D1-c tests — command idempotency, tolerant decoding and command encoding.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HarnessCommandTest {
    @Test
    fun repeatedPromptWithSameRequestIdExecutesOnce() {
        val harness = FakeHarness()
        val prompt = HarnessCommand.Prompt(text = "Summarise the failing test.", requestId = "req-1")

        runSuspendBlocking {
            repeat(3) {
                harness.send(prompt, "sess-1")
            }
        }

        // The host still makes one send call per command; the backend deduplicates.
        assertEquals(3, harness.deliveredCommands().size)
        assertEquals(1, harness.executionsOf("req-1"))
    }

    @Test
    fun distinctRequestIdsExecuteSeparately() {
        val harness = FakeHarness()

        runSuspendBlocking {
            harness.send(HarnessCommand.Prompt(text = "one", requestId = "req-1"), "sess-1")
            harness.send(HarnessCommand.Prompt(text = "two", requestId = "req-2"), "sess-1")
            harness.send(HarnessCommand.Steer(text = "three", requestId = "req-3"), "sess-1")
        }

        assertEquals(1, harness.executionsOf("req-1"))
        assertEquals(1, harness.executionsOf("req-2"))
        assertEquals(1, harness.executionsOf("req-3"))
    }

    @Test
    fun schemaUnkeyedCommandsHaveNoRequestId() {
        assertNull(HarnessCommand.Cancel.requestId)
        assertNull(HarnessCommand.CancelWithCause(AgentCancelCause.User).requestId)
        assertNull(HarnessCommand.Shutdown.requestId)
        assertEquals(HarnessCommand.Kind.CANCEL, HarnessCommand.Cancel.kind)
        assertEquals(7, HarnessCommand.Kind.entries.size)
    }

    @Test
    fun commandJsonWithUnknownMembersStillDecodes() {
        // Mirrors golden/harness-command-prompt-device-origin.json, whose
        // `origin` member is declared with ignore_members: every contract-1
        // decoder must accept it and every encoder must drop it.
        val json = """
            {
              "kind": "prompt",
              "text": "Summarise the failing test in one line.",
              "request_id": "dev:dev-01-000123",
              "attachments": [
                {
                  "name": "screenshot.png",
                  "mime_type": "image/png",
                  "data_base64": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/wFPh4ZAAAAAAElFTkSuQmCC",
                  "future_attachment_member": true
                }
              ],
              "origin": { "kind": "device", "device_id": "esp32-8c4f1a", "seq": 123 },
              "future_top_level_member": [1, 2, 3]
            }
        """.trimIndent()

        val command = HarnessJson.decodeCommand(json)

        assertTrue(command is HarnessCommand.Prompt)
        command as HarnessCommand.Prompt
        assertEquals("dev:dev-01-000123", command.requestId)
        assertEquals("Summarise the failing test in one line.", command.text)
        assertEquals(1, command.attachments.size)
        assertEquals("screenshot.png", command.attachments.single().name)
        assertEquals("image/png", command.attachments.single().mimeType)

        val reencoded = HarnessJson.encodeCommand(command)
        assertFalse("encoder must not emit unknown members", reencoded.contains("origin"))
        assertFalse("encoder must not emit unknown members", reencoded.contains("future_"))
    }

    @Test
    fun allSevenCommandVariantsRoundTrip() {
        val commands = listOf(
            HarnessCommand.Prompt(
                text = "hello",
                requestId = "prompt-1",
                attachments = listOf(
                    HarnessAttachment(name = "a.txt", mimeType = "text/plain", dataBase64 = "aGVsbG8="),
                ),
            ),
            HarnessCommand.Steer(text = "focus", requestId = "steer-1"),
            HarnessCommand.Cancel,
            HarnessCommand.CancelWithCause(AgentCancelCause.Budget("step budget exhausted after 40 steps")),
            HarnessCommand.PermissionResponse(requestId = "perm-1", decision = PermissionDecision.ALLOW_ALWAYS),
            HarnessCommand.QuestionResponse(requestId = "question-1", answer = """{"q1":["b"]}"""),
            HarnessCommand.Shutdown,
        )

        assertEquals(7, commands.size)
        for (command in commands) {
            val encoded = HarnessJson.encodeCommand(command)
            assertEquals("round trip failed for $command ($encoded)", command, HarnessJson.decodeCommand(encoded))
        }
    }

    @Test
    fun commandsWithoutRequestIdEncodeNoRequestId() {
        assertEquals("""{"kind":"cancel"}""", HarnessJson.encodeCommand(HarnessCommand.Cancel))
        assertEquals("""{"kind":"shutdown"}""", HarnessJson.encodeCommand(HarnessCommand.Shutdown))
        assertEquals(
            """{"kind":"cancel_with_cause","cause":{"kind":"user"}}""",
            HarnessJson.encodeCommand(HarnessCommand.CancelWithCause(AgentCancelCause.User)),
        )
    }

    @Test
    fun cancelCausesProjectToTheNestedDshValue() {
        assertEquals(JsonValue.parse("""{"kind":"user"}"""), AgentCancelCause.User.toDshCause())
        assertEquals(
            JsonValue.parse("""{"kind":"hook","reason":{"kind":"hook"}}"""),
            AgentCancelCause.Hook.toDshCause(),
        )
        assertEquals(
            JsonValue.parse("""{"kind":"hook","reason":{"kind":"budget","detail":"b"}}"""),
            AgentCancelCause.Budget("b").toDshCause(),
        )
        assertEquals(
            JsonValue.parse("""{"kind":"hook","reason":{"kind":"timeout","detail":"t"}}"""),
            AgentCancelCause.Timeout("t").toDshCause(),
        )
    }
}
