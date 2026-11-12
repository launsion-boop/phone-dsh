// SPDX-License-Identifier: MIT
// PCLink JSON wire boundary (§2.3): strict wire bytes, carried DSH values with
// an escaped `\u0000`, and PCLink-owned field rules. Drives the real parser and
// the real inner/relay validators with `json_boundary` from the shared vectors.
package com.phonedsh.pclink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkJsonBoundaryTest {
    @Test
    fun goldenAcceptedRows() {
        val boundary = TestSupport.at(TestSupport.vectors(), "json_boundary")
            ?: throw AssertionError("missing json_boundary")
        val accepted = TestSupport.objects(boundary, "accepted")
        assertEquals(6, accepted.size)
        val passthrough = TestSupport.objects(boundary, "passthrough").mapNotNull { it.stringValue }
        assertEquals(6, passthrough.size)

        var seen = 0
        for (row in accepted) {
            val case = TestSupport.requireString(row, "case")
            val wire = TestSupport.requireString(row, "wire")
            val parsed = PclinkJsonParser.parseObject(wire)
            // The same production validator the session uses for the closed shape.
            PclinkWire.validateInnerMessage(parsed)
            for (path in TestSupport.objects(row, "nul_paths")) {
                assertCarriedNul(parsed, path, case)
            }
            for (path in TestSupport.objects(row, "chunk_data_nul_paths")) {
                val data = PclinkBase64Url.decode(TestSupport.requireString(parsed, "data"))
                // The chunk payload is a JSON value carrying the escaped U+0000.
                // Reassembly is C4's `PclinkRpc`; the C1 boundary is that the
                // real base64url decoder and JSON parsers preserve it.
                val decoded = PclinkJsonParser.parse(data)
                assertCarriedNul(decoded, path, case)
                assertTrue(case, TestSupport.requireInt(parsed, "part") >= 0)
                assertTrue(case, TestSupport.requireBool(parsed, "last"))
            }
            seen++
        }
        assertEquals(6, seen)
    }

    @Test
    fun goldenRejectedRows() {
        val boundary = TestSupport.at(TestSupport.vectors(), "json_boundary")
            ?: throw AssertionError("missing json_boundary")
        val rejected = TestSupport.objects(boundary, "rejected")
        assertEquals(8, rejected.size)

        for (row in rejected) {
            val case = TestSupport.requireString(row, "case")
            val failure = TestSupport.requireString(row, "failure")
            val data = TestSupport.string(row, "wire_hex")?.let(TestSupport::hex)
                ?: TestSupport.requireString(row, "wire").toByteArray(Charsets.UTF_8)

            if (failure == "wire") {
                // A literal NUL, BOM, duplicate member at any depth, lone
                // surrogate or a non-object root is `bad_frame`.
                assertPclinkCode("bad_frame", case) { PclinkJsonParser.parseObject(data) }
                continue
            }

            assertEquals("field", failure)
            val parsed = PclinkJsonParser.parseObject(data)
            val type = parsed["type"]?.stringValue
            if (type != null && type.startsWith("relay.")) {
                assertPclinkCode("bad_frame", case) { PclinkWire.validateRelayFrame(parsed) }
            } else {
                assertPclinkCode("bad_frame", case) { PclinkWire.validateInnerMessage(parsed) }
            }
        }
    }

    @Test
    fun duplicateMembersCompareUnicodeScalarSequences() {
        // Same decoded scalar sequence spelled with an escape: duplicate.
        val duplicate = assertPclinkCode("bad_frame") {
            PclinkJsonParser.parseObject("{\"a\":1,\"\\u0061\":2}")
        }
        assertTrue(duplicate.message!!.contains("duplicate"))

        // Distinct scalar sequences that are canonically equivalent are two
        // members; the contract compares decoded scalars, not canonical forms.
        val source = "{\"\u00E9\":1,\"e\u0301\":2}"
        val parsed = PclinkJsonParser.parseObject(source)
        assertEquals(2, parsed.objectValue!!.size)
        assertEquals(1L, parsed["\u00E9"]?.longValue)
        assertEquals(2L, parsed["e\u0301"]?.longValue)
        assertEquals("{\"e\u0301\":2,\"\u00E9\":1}", PclinkJsonEncoder.canonicalString(parsed))
    }

    @Test
    fun rawDelIsLegalJsonButPclinkNameRejectsIt() {
        // U+007F is not a C0 control; a DSH serializer may emit it literally.
        // It stays legal inside a carried value, while the §2.1 name rule
        // rejects the C1 range in PCLink-owned fields.
        val parsed = PclinkJsonParser.parseObject("{\"note\":\"a\u007Fb\"}")
        assertEquals("a\u007Fb", parsed["note"]?.stringValue)
        assertPclinkCode("bad_frame") { PclinkValidation.name("a\u007Fb") }
    }

    @Test
    fun pclinkOwnedMessagesRejectNulWhilePassthroughAndDetailsKeepIt() {
        val nul = "a\u0000b"

        assertPclinkCode("bad_frame") {
            PclinkWire.validateRelayFrame(
                pclinkObject(
                    "v" to PclinkJson.Integer(1),
                    "type" to PclinkJson.Text("relay.error"),
                    "code" to PclinkJson.Text("unavailable"),
                    "message" to PclinkJson.Text(nul),
                ),
            )
        }

        val rejected = rpcError(message = nul)
        assertPclinkCode("bad_frame") { PclinkWire.validateInnerMessage(rejected) }
        assertPclinkCode("bad_frame") {
            PclinkWire.validateInnerMessage(
                pclinkObject(
                    "type" to PclinkJson.Text("rpc.stream.error"),
                    "streamId" to PclinkJson.Text("stream-nul"),
                    "error" to pclinkObject(
                        "code" to PclinkJson.Text("unavailable"),
                        "message" to PclinkJson.Text(nul),
                    ),
                ),
            )
        }
        assertPclinkCode("bad_frame") {
            PclinkWire.validateInnerMessage(
                pclinkObject(
                    "type" to PclinkJson.Text("session.close"),
                    "code" to PclinkJson.Text("unavailable"),
                    "message" to PclinkJson.Text(nul),
                ),
            )
        }
        assertPclinkCode("bad_frame") {
            PclinkWire.validateInnerMessage(
                pclinkObject(
                    "type" to PclinkJson.Text("call.foo.error"),
                    "code" to PclinkJson.Text("unavailable"),
                    "message" to PclinkJson.Text(nul),
                ),
            )
        }

        val sid = "ODU-xxharZz-k1yXN2XWRA"
        val machine = "a".repeat(26)
        assertPclinkCode("bad_frame") {
            PclinkWire.validateE2EHandshake(
                pclinkObject(
                    "v" to PclinkJson.Integer(1),
                    "type" to PclinkJson.Text("e2e.handshake"),
                    "sid" to PclinkJson.Text(sid),
                    "from" to PclinkJson.Text(machine),
                    "to" to PclinkJson.Text(machine),
                    "body" to pclinkObject(
                        "v" to PclinkJson.Integer(1),
                        "type" to PclinkJson.Text("session.reject"),
                        "sid" to PclinkJson.Text(sid),
                        "code" to PclinkJson.Text("unpaired"),
                        "message" to PclinkJson.Text(nul),
                    ),
                ),
            )
        }

        // The DSH passthrough values are carried unchanged.
        PclinkWire.validateInnerMessage(
            pclinkObject(
                "type" to PclinkJson.Text("rpc.call"),
                "id" to PclinkJson.Text("call-nul"),
                "endpoint" to PclinkJson.Text("session/list"),
                "args" to pclinkObject(
                    "_request" to PclinkJson.Object(emptyMap()),
                    "note" to PclinkJson.Text(nul),
                ),
            ),
        )
        PclinkWire.validateInnerMessage(
            pclinkObject(
                "type" to PclinkJson.Text("rpc.result"),
                "id" to PclinkJson.Text("call-nul"),
                "ok" to PclinkJson.Bool(true),
                "result" to pclinkObject(
                    "text" to PclinkJson.Text(nul),
                    "nested" to PclinkJson.Array(listOf(PclinkJson.Text(nul))),
                ),
            ),
        )
        PclinkWire.validateInnerMessage(
            pclinkObject(
                "type" to PclinkJson.Text("rpc.stream.open"),
                "streamId" to PclinkJson.Text("stream-nul"),
                "endpoint" to PclinkJson.Text("session/follow"),
                "payload" to pclinkObject(
                    "args" to pclinkObject(
                        "request" to pclinkObject("note" to PclinkJson.Text(nul)),
                    ),
                ),
            ),
        )
        PclinkWire.validateInnerMessage(
            pclinkObject(
                "type" to PclinkJson.Text("rpc.stream.item"),
                "streamId" to PclinkJson.Text("stream-nul"),
                "value" to pclinkObject("text" to PclinkJson.Text(nul)),
            ),
        )

        // `details` is optional error content and follows the error rule, not a
        // PCLink-owned display string: its nested DSH value is preserved.
        PclinkWire.validateInnerMessage(
            rpcError(message = "failed", details = pclinkObject("text" to PclinkJson.Text(nul))),
        )
    }

    @Test
    fun strictWireParserRejectsNonWireBytes() {
        val cases = listOf(
            "empty" to byteArrayOf(),
            "leading whitespace" to " {\"a\":1}".toByteArray(Charsets.UTF_8),
            "trailing whitespace" to "{\"a\":1} ".toByteArray(Charsets.UTF_8),
            "trailing content" to "{\"a\":1}x".toByteArray(Charsets.UTF_8),
            "bom" to byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte(), '{'.code.toByte()),
            "literal nul in string" to
                byteArrayOf('{'.code.toByte(), '"'.code.toByte(), 0, '"'.code.toByte(), '}'.code.toByte()),
            "invalid utf8" to
                byteArrayOf('{'.code.toByte(), '"'.code.toByte(), 0xFF.toByte(), '"'.code.toByte(), '}'.code.toByte()),
            "non-object root" to "[]".toByteArray(Charsets.UTF_8),
            "trailing comma" to "{\"a\":1,}".toByteArray(Charsets.UTF_8),
            "leading zero" to "01".toByteArray(Charsets.UTF_8),
            "nan" to "NaN".toByteArray(Charsets.UTF_8),
            "lone surrogate escape" to "{\"a\":\"\\ud800\"}".toByteArray(Charsets.UTF_8),
            "unquoted member" to "{a:1}".toByteArray(Charsets.UTF_8),
        )
        for ((label, bytes) in cases) {
            assertPclinkCode("bad_frame", label) { PclinkJsonParser.parseObject(bytes) }
        }
    }

    @Test
    fun strictParserFixesNumbersAndDocumentParsing() {
        // Integers stay Long; `1.0`/`1e3` are decimals and are rejected by the
        // fields that require an integer (seq/part/port).
        assertEquals(1L, PclinkJsonParser.parseObject("{\"v\":1}")["v"]?.longValue)
        assertNull(PclinkJsonParser.parseObject("{\"v\":1.0}")["v"]?.longValue)
        assertNull(PclinkJsonParser.parseObject("{\"v\":1e3}")["v"]?.longValue)
        assertEquals(1.0, PclinkJsonParser.parseObject("{\"v\":1.0}")["v"]?.doubleValue ?: Double.NaN, 0.0)
        // The fixture reader allows insignificant whitespace; the wire parser
        // does not.
        assertEquals(1L, PclinkJsonParser.parseDocumentObject(" \n{\"v\":1}\t ")["v"]?.longValue)
        assertNotNull(PclinkJsonParser.parseDocumentObject("{\"n\":-0}")["n"])
    }

    private fun assertCarriedNul(root: PclinkJson, pathValue: PclinkJson, case: String) {
        val path = pathValue.arrayValue ?: throw AssertionError("$case path is not an array")
        var current = root
        for (component in path) {
            val key = component.stringValue
            if (key != null) {
                current = current[key] ?: throw AssertionError("$case missing $key")
            } else {
                val index = component.longValue
                    ?: throw AssertionError("$case bad path component")
                current = current.arrayValue?.getOrNull(index.toInt())
                    ?: throw AssertionError("$case missing array index $index")
            }
        }
        val text = current.stringValue ?: throw AssertionError("$case path is not a string")
        assertTrue("$case carried U+0000 was filtered", text.contains('\u0000'))
    }

    private fun rpcError(message: String, details: PclinkJson? = null): PclinkJson {
        val error = LinkedHashMap<String, PclinkJson>()
        error["code"] = PclinkJson.Text("unavailable")
        error["message"] = PclinkJson.Text(message)
        if (details != null) error["details"] = details
        return pclinkObject(
            "type" to PclinkJson.Text("rpc.result"),
            "id" to PclinkJson.Text("call-nul"),
            "ok" to PclinkJson.Bool(false),
            "error" to PclinkJson.Object(error),
        )
    }
}
