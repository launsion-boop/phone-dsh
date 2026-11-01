// phone-dsh — :net tests: the golden gateway vectors, one case per vector id.
// SPDX-License-Identifier: MIT
//
// `spec/v1/golden/gateway` is the judge. Every vector becomes its own
// parameterized case named after the vector id, so a regression names the rule
// it broke instead of failing an aggregate.

package com.phonedsh.gateway

import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

@RunWith(Parameterized::class)
class GatewayVectorConformanceTest(private val vectorId: String) {

    @Test
    fun vectorPasses() {
        val vector = GatewayVectorRunner.vectorById(vectorId)
        val result = GatewayVectorRunner.run(vector)
        assertTrue(result.toString(), result.passed)
    }

    @Test
    fun vectorStillDeclaresTheRuleItIsNamedFor() {
        val vector = GatewayVectorRunner.vectorById(vectorId)
        assertTrue(
            "$vectorId: rule '${vector.rule}' is not one of ${GatewayVectorRunner.RULE_CLASSES}",
            vector.rule in GatewayVectorRunner.RULE_CLASSES,
        )
        assertTrue(
            "$vectorId: kind '${vector.kind}' is not one of request/response/redirect-chain",
            vector.kind in setOf(
                GatewayVectorRunner.KIND_REQUEST,
                GatewayVectorRunner.KIND_RESPONSE,
                GatewayVectorRunner.KIND_REDIRECT_CHAIN,
            ),
        )
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun vectorIds(): List<String> = GatewayVectorRunner.loadVectors().map { it.id }
    }
}
