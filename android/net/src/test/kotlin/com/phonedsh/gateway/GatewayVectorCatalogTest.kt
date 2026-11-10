// phone-dsh — :net tests: the vector catalog is complete and fully green.
// SPDX-License-Identifier: MIT
//
// One aggregate test is the acceptance statement (31/31), the rest stop the
// suite from shrinking quietly: a missing file, a renamed id, a rule class with
// no vector, or a vector that never ran all fail here instead of passing by
// omission.

package com.phonedsh.gateway

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayVectorCatalogTest {

    @Test
    fun catalogIsExactlyTheGoldenVectors() {
        val vectors = GatewayVectorRunner.loadVectors()
        val ids = vectors.map { it.id }
        assertEquals(
            "the runner loaded $ids",
            GatewayVectorRunner.EXPECTED_VECTOR_COUNT,
            vectors.size,
        )
        assertEquals(
            "vector ids drifted from the committed catalog",
            GatewayVectorRunner.EXPECTED_VECTOR_IDS,
            ids.toSet(),
        )
        assertEquals("a vector id is duplicated", vectors.size, ids.toSet().size)
    }

    @Test
    fun everyRuleClassHasAtLeastOneVector() {
        val rules = GatewayVectorRunner.loadVectors().map { it.rule }.toSet()
        for (rule in GatewayVectorRunner.RULE_CLASSES) {
            assertTrue("no vector covers '$rule'", rule in rules)
        }
    }

    @Test
    fun everyGoldenVectorPasses() {
        val results = GatewayVectorRunner.runAll()
        assertEquals(
            "ran ${results.size} of ${GatewayVectorRunner.EXPECTED_VECTOR_COUNT} vectors",
            GatewayVectorRunner.EXPECTED_VECTOR_COUNT,
            results.size,
        )
        val failures = results.filter { !it.passed }
        assertTrue(
            "golden vector failures: ${failures.joinToString("; ")}",
            failures.isEmpty(),
        )
    }

    @Test
    fun everyVectorRunsTheRealImplementation() {
        // A vector that never reached the transport would pass a deny assertion
        // for the wrong reason; every non-pre-flight vector must show contact.
        for (vector in GatewayVectorRunner.loadVectors()) {
            val harness = GatewayVectorRunner.harness(vector)
            val outcome = harness.outcome
            if (outcome.outboundUrl.isEmpty()) {
                assertTrue(
                    "${vector.id}: a pre-flight deny must not touch the transport",
                    harness.transport.requests.isEmpty(),
                )
            } else {
                assertTrue(
                    "${vector.id}: no request reached the scripted transport",
                    harness.transport.requests.isNotEmpty(),
                )
                assertEquals(
                    "${vector.id}: credential lookups",
                    1,
                    harness.credentials.scopes.size,
                )
            }
        }
    }
}
