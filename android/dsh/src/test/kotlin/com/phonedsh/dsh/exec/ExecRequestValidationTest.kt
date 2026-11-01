// phone-dsh — :dsh unit test: EXEC_REQ field validation (channel.md §4.2).
// SPDX-License-Identifier: MIT
//
// Every required member, every malformed shape, the D10 idem_key and the
// grace_ms 1..60000 range are refused with a stable code/field/reason. The last
// test parses the normative `exec-req-1.json` and re-emits its canonical payload,
// so the accepted field set is pinned to the spec vector rather than to this
// test's idea of it.

package com.phonedsh.dsh.exec

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecRequestValidationTest {
    private fun rejected(json: JSONObject): ExecRequestException =
        assertThrows(ExecRequestException::class.java) { ExecRequest.parse(json.toString()) }

    private fun rejectedText(text: String): ExecRequestException =
        assertThrows(ExecRequestException::class.java) { ExecRequest.parse(text) }

    @Test
    fun eachRequiredMemberIsRejectedWhenMissing() {
        for (field in listOf("exec_id", "argv", "cwd", "requires_mseq", "idem_key")) {
            val json = ExecFixtures.baseRequest()
            json.remove(field)

            val error = rejected(json)

            assertEquals("BAD_PAYLOAD", error.code)
            assertEquals("missing $field", ExecRequestException.Reason.MISSING, error.reason)
            assertEquals(field, error.field)
        }
    }

    @Test
    fun idemKeyMustBeExactlySixtyFourLowercaseHex() {
        val malformed = listOf(
            "A".repeat(64), // uppercase
            "a".repeat(63), // short
            "a".repeat(65), // long
            "g".repeat(64), // not hex
            "",
            "0x" + "a".repeat(62),
        )
        for (bad in malformed) {
            val error = rejected(ExecFixtures.baseRequest(idemKey = bad))

            assertEquals("BAD_PAYLOAD", error.code)
            assertEquals(ExecRequestException.Reason.BAD_IDEM_KEY, error.reason)
            assertEquals("idem_key", error.field)
        }
        // Direct construction goes through the same invariant, not just parse().
        assertThrows(ExecRequestException::class.java) {
            ExecRequest(
                execId = ExecFixtures.EXEC_ID,
                argv = listOf("rg"),
                cwd = "/dsh/workspace",
                requiresMseq = 0L,
                idemKey = "A".repeat(64),
            )
        }
    }

    @Test
    fun graceMsIsOneToSixtyThousandAndAbsentMeansThreeThousand() {
        for (bad in listOf(0L, -1L, 60_001L, Long.MAX_VALUE)) {
            val error = rejected(ExecFixtures.baseRequest().put("grace_ms", bad))

            assertEquals("BAD_PAYLOAD", error.code)
            assertEquals(ExecRequestException.Reason.OUT_OF_RANGE, error.reason)
            assertEquals("grace_ms", error.field)
        }
        assertEquals(1L, ExecFixtures.request(graceMs = 1L).graceMs)
        assertEquals(60_000L, ExecFixtures.request(graceMs = 60_000L).graceMs)
        assertEquals(
            ExecRequest.DEFAULT_GRACE_MS,
            ExecRequest.parse(ExecFixtures.baseRequest().toString()).graceMs,
        )
    }

    @Test
    fun wrongTypesInNestedShapesAreRejected() {
        assertEquals(
            ExecRequestException.Reason.WRONG_TYPE,
            rejected(ExecFixtures.baseRequest().put("argv", "rg")).reason,
        )
        assertEquals(
            "cwd",
            rejected(ExecFixtures.baseRequest().put("cwd", 7)).field,
        )
        assertEquals(
            "requires_mseq",
            rejected(ExecFixtures.baseRequest().put("requires_mseq", "0")).field,
        )
        assertEquals(
            "env",
            rejected(ExecFixtures.baseRequest().put("env", JSONArray())).field,
        )
        assertEquals(
            "env",
            rejected(ExecFixtures.baseRequest().put("env", JSONObject().put("TERM", 7))).field,
        )
        assertEquals(
            "stdin",
            rejected(ExecFixtures.baseRequest().put("stdin", "ignore")).field,
        )
        assertEquals(
            "stdin.mode",
            rejected(ExecFixtures.baseRequest().put("stdin", JSONObject().put("mode", 7))).field,
        )
        assertEquals(
            ExecRequestException.Reason.MISSING,
            rejected(ExecFixtures.baseRequest().put("stdin", JSONObject().put("mode", "data"))).reason,
        )
        assertEquals(
            ExecRequestException.Reason.UNKNOWN_MEMBER,
            rejected(
                ExecFixtures.baseRequest().put(
                    "stdin",
                    JSONObject().put("mode", "ignore").put("data", "aGVsbG8K"),
                ),
            ).reason,
        )
        assertEquals(
            ExecRequestException.Reason.BAD_VALUE,
            rejected(
                ExecFixtures.baseRequest().put(
                    "stdin",
                    JSONObject().put("mode", "data").put("data", "not base64!"),
                ),
            ).reason,
        )
        assertEquals(
            "tier",
            rejected(ExecFixtures.baseRequest().put("tier", "fast")).field,
        )
        assertEquals(
            ExecRequestException.Reason.MISSING,
            rejected(
                ExecFixtures.baseRequest().put("confine", JSONObject().put("mode", "read-only")),
            ).reason,
        )
        assertEquals(
            "confine.mode",
            rejected(
                ExecFixtures.baseRequest().put(
                    "confine",
                    JSONObject().put("mode", "root").put("workspace_root", "/dsh/workspace"),
                ),
            ).field,
        )
        assertEquals(
            ExecRequestException.Reason.UNKNOWN_MEMBER,
            rejected(
                ExecFixtures.baseRequest().put(
                    "confine",
                    JSONObject()
                        .put("mode", "read-only")
                        .put("workspace_root", "/dsh/workspace")
                        .put("uid", 7),
                ),
            ).reason,
        )
        assertEquals(
            "exec_id",
            rejected(ExecFixtures.baseRequest(execId = "../evil")).field,
        )
        assertEquals(
            "cwd",
            rejected(ExecFixtures.baseRequest(cwd = "relative/path")).field,
        )
        assertEquals(
            ExecRequestException.Reason.OUT_OF_RANGE,
            rejected(ExecFixtures.baseRequest().put("argv", JSONArray())).reason,
        )
        assertEquals(
            ExecRequestException.Reason.BAD_VALUE,
            rejected(ExecFixtures.baseRequest(argv = listOf("rg", ""))).reason,
        )
        assertEquals(
            "deadline",
            rejected(ExecFixtures.baseRequest().put("deadline", -1)).field,
        )
        assertEquals(
            "requires_mseq",
            rejected(ExecFixtures.baseRequest().put("requires_mseq", -1)).field,
        )
        assertEquals(
            ExecRequestException.Reason.WRONG_TYPE,
            rejected(ExecFixtures.baseRequest().put("exec_id", JSONObject.NULL)).reason,
        )
    }

    @Test
    fun malformedJsonAndUnknownMembersAreRejected() {
        assertEquals(
            ExecRequestException.Reason.MALFORMED_JSON,
            rejectedText("{not json").reason,
        )
        assertEquals(
            ExecRequestException.Reason.MALFORMED_JSON,
            rejectedText("[]").reason,
        )
        assertEquals(
            ExecRequestException.Reason.MALFORMED_JSON,
            rejectedText(
                "{\"exec_id\":\"a\",\"exec_id\":\"b\",\"argv\":[\"rg\"]," +
                    "\"cwd\":\"/dsh/workspace\",\"requires_mseq\":0," +
                    "\"idem_key\":\"${ExecFixtures.IDEM_A}\"}",
            ).reason,
        )
        assertEquals(
            ExecRequestException.Reason.MALFORMED_JSON,
            rejected(ExecFixtures.baseRequest().put("grace_ms", 1.5)).reason,
        )
        assertEquals(
            ExecRequestException.Reason.UNKNOWN_MEMBER,
            rejected(ExecFixtures.baseRequest().put("shell", true)).reason,
        )
    }

    @Test
    fun optionalMembersTakeTheirDocumentedDefaults() {
        val json = JSONObject()
            .put("exec_id", ExecFixtures.EXEC_ID)
            .put("argv", JSONArray(listOf("rg")))
            .put("cwd", "/dsh/workspace")
            .put("requires_mseq", 0)
            .put("idem_key", ExecFixtures.IDEM_A)

        val request = ExecRequest.parse(json.toString())

        assertEquals(ExecRequest.DEFAULT_GRACE_MS, request.graceMs)
        assertTrue(request.env.isEmpty())
        assertEquals(StdinSpec.Ignore, request.stdin)
        assertNull(request.deadline)
        assertNull(request.tier)
        assertNull(request.confine)
        // Defaults are materialized in the canonical form a tool receives.
        val canonical = JSONObject(request.toJson())
        assertEquals(3000L, canonical.getLong("grace_ms"))
        assertEquals("ignore", canonical.getJSONObject("stdin").getString("mode"))
    }

    @Test
    fun theGoldenExecRequestIsAcceptedAndRoundTripsCanonically() {
        val golden = ExecSpec.golden("exec-req-1.json")
        val fields = golden.getJSONObject("fields").toString()

        val request = ExecRequest.parse(fields)

        assertEquals("xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0-0", request.execId)
        assertEquals(listOf("rg", "--json", "needle"), request.argv)
        assertEquals("/dsh/workspace", request.cwd)
        assertEquals(
            mapOf(
                "TERM" to "dumb",
                "XL_IDEMPOTENCY_KEY" to "xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0",
            ),
            request.env,
        )
        assertEquals(1_792_800_000_000L, request.deadline)
        assertEquals(3000L, request.graceMs)
        assertEquals(StdinSpec.Ignore, request.stdin)
        assertEquals(ExecTier.INTERACTIVE, request.tier)
        assertEquals(Confine(ConfineMode.WORKSPACE_WRITE, "/dsh/workspace"), request.confine)
        assertEquals(47L, request.requiresMseq)
        assertEquals(
            "2d3562b36e18c2441bd7bb4ed95c67bd72a86983387bd7f04f6d1ef1668cc81a",
            request.idemKey,
        )

        val payload = String(ExecSpec.hexBytes(golden.getString("payload_hex")), Charsets.UTF_8)
        assertEquals(payload, request.toJson())
    }
}
