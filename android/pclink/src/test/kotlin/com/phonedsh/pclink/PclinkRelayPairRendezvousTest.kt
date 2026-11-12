// SPDX-License-Identifier: MIT
// Regression: the relay-pair validator must accept the real §4.3 rendezvous
// values from the shared golden (22-char b64url text prefixes, which are not
// canonical 16-byte encodings) and keep rejecting malformed ones.
package com.phonedsh.pclink

import org.junit.Assert.assertThrows
import org.junit.Test

class PclinkRelayPairRendezvousTest {
    private fun frame(type: String, rendezvous: String, extra: String = ""): PclinkJson =
        PclinkJsonParser.parse("""{"v":1,"type":"$type","rendezvous":"$rendezvous"$extra}""")

    private fun goldenRendezvous(): List<String> {
        val pairing = TestSupport.at(TestSupport.vectors(), "pairing") ?: throw AssertionError("missing pairing")
        return listOf(
            TestSupport.requireString(TestSupport.at(pairing, "manual") ?: throw AssertionError("manual"), "rendezvous"),
            TestSupport.requireString(pairing, "rendezvous_s"),
            TestSupport.requireString(pairing, "rendezvous_s_other_origin"),
        )
    }

    @Test
    fun goldenRendezvousValuesPassEveryRelayPairFrame() {
        for (r in goldenRendezvous()) {
            PclinkWire.validateRelayPair(frame("relay.pair.open", r))
            PclinkWire.validateRelayPair(frame("relay.pair.join", r))
            PclinkWire.validateRelayPair(frame("relay.pair.message", r, ""","payload":{}"""))
        }
    }

    @Test
    fun malformedRendezvousIsBadFrame() {
        for (bad in listOf("", "AAAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAAAAAAAAA=", "AAAAAAAAAAAAAAAAAAAAA+")) {
            assertThrows(PclinkError.BadFrame::class.java) {
                PclinkWire.validateRelayPair(frame("relay.pair.join", bad))
            }
        }
    }
}
