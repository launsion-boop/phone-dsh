// phone-dsh — :net tests: spec/v1/tono-account.md §10–§11 on Android.
// SPDX-License-Identifier: MIT
//
// The shared `wallet_responses`, `claim_responses`, `credit_display`,
// `credits_guidance` and `credits_responses` cases judge the real Kotlin
// classifiers; the real GatewaySession forwards a cloud 402 once and reports
// it; the real wallet client talks to a scripted transport. Nothing here
// contacts a tono service.

package com.phonedsh.account

import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.EgressPolicy
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.GatewayRequest
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.gateway.GatewayTransport
import com.phonedsh.gateway.GatewayTransportRequest
import com.phonedsh.gateway.GatewayTransportResponse
import com.phonedsh.gateway.GatewayUrl
import com.phonedsh.gateway.GatewayVectorRunner
import com.phonedsh.gateway.JsonValue
import com.phonedsh.gateway.TonoCloudResponsePolicy
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TonoCloudWalletCasesTest {

    private val fixture: JsonValue.Obj by lazy {
        val path = GatewayVectorRunner.findRepositoryRoot().resolve("spec/v1/golden/tono-account/cases.json")
        assertTrue("shared cases must exist at $path", Files.isRegularFile(path))
        GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8)) as JsonValue.Obj
    }

    private fun cases(name: String): List<JsonValue.Obj> =
        requireNotNull(fixture.array(name)) { "$name is missing" }.map { it as JsonValue.Obj }

    private fun body(item: JsonValue.Obj): ByteArray {
        var bytes = item.string("body_text")?.toByteArray(StandardCharsets.UTF_8)
            ?: item.get("body")?.let { GatewayJson.canonicalBytes(it) } ?: ByteArray(0)
        item.int("pad_to_bytes")?.let { target ->
            assertTrue(item.string("name"), bytes.size <= target)
            bytes += ByteArray(target - bytes.size) { ' '.code.toByte() }
        }
        return bytes
    }

    private fun answer(item: JsonValue.Obj) = TonoAccountAnswer(item.int("status")!!, emptyMap(), body(item))

    @Test
    fun constantsMatch() {
        val c = fixture.obj("constants")!!
        assertEquals(TonoCloudWalletProtocol.WALLET_PATH, c.string("wallet_path"))
        assertEquals(TonoCloudWalletProtocol.CLAIM_PATH, c.string("claim_path"))
        assertEquals(TonoCloudWalletProtocol.MICRO_CREDITS_PER_CREDIT, c.int("micro_credits_per_credit"))
        assertEquals(TonoCloudWalletProtocol.MICRO_CREDITS_MAX_DIGITS, c.int("micro_credits_max_digits"))
    }

    @Test
    fun walletResponses() {
        val all = cases("wallet_responses")
        assertTrue(all.size >= 20)
        for (item in all) {
            val name = item.string("name")!!
            val expect = item.obj("expect")!!
            when (val outcome = TonoCloudWalletProtocol.classifyRead(answer(item))) {
                is TonoWalletReadOutcome.Wallet -> {
                    assertEquals(name, "wallet", expect.string("outcome"))
                    assertEquals(name, expect.string("available_micro_credits"), outcome.wallet.availableMicroCredits)
                    assertEquals(name, expect.bool("claimable"), outcome.wallet.claimable)
                    assertEquals(name, expect.string("mode"), outcome.wallet.mode)
                }
                TonoWalletReadOutcome.ProtocolError -> assertEquals(name, "protocol_error", expect.string("outcome"))
                TonoWalletReadOutcome.Unauthorized -> assertEquals(name, "unauthorized", expect.string("outcome"))
                TonoWalletReadOutcome.Rejected -> assertEquals(name, "rejected", expect.string("outcome"))
                TonoWalletReadOutcome.Unavailable -> assertEquals(name, "unavailable", expect.string("outcome"))
                TonoWalletReadOutcome.Transient -> assertEquals(name, "transient", expect.string("outcome"))
            }
        }
        assertEquals(TonoWalletReadOutcome.Transient, TonoCloudWalletProtocol.classifyRead(null))
    }

    @Test
    fun claimResponses() {
        for (item in cases("claim_responses")) {
            val name = item.string("name")!!
            val expect = item.obj("expect")!!
            when (val outcome = TonoCloudWalletProtocol.classifyClaim(answer(item))) {
                is TonoWalletClaimOutcome.Claimed -> {
                    assertEquals(name, "claimed", expect.string("outcome"))
                    assertEquals(name, expect.bool("granted_now"), outcome.grantedNow)
                    assertEquals(name, expect.string("available_micro_credits"), outcome.wallet.availableMicroCredits)
                    assertEquals(name, expect.bool("claimable"), outcome.wallet.claimable)
                }
                TonoWalletClaimOutcome.ProtocolError -> assertEquals(name, "protocol_error", expect.string("outcome"))
                TonoWalletClaimOutcome.Unauthorized -> assertEquals(name, "unauthorized", expect.string("outcome"))
                TonoWalletClaimOutcome.Rejected -> assertEquals(name, "rejected", expect.string("outcome"))
                TonoWalletClaimOutcome.Unavailable -> assertEquals(name, "unavailable", expect.string("outcome"))
                TonoWalletClaimOutcome.Transient -> assertEquals(name, "transient", expect.string("outcome"))
            }
        }
    }

    @Test
    fun creditDisplayAndGuidance() {
        for (item in cases("credit_display")) {
            assertEquals(item.string("micro"), item.string("expect"), TonoCloudWalletProtocol.displayCredits(item.string("micro")!!))
        }
        assertNull(TonoCloudWalletProtocol.displayCredits("-1"))
        for (item in cases("credits_guidance")) {
            val condition = TonoCreditsCondition.entries.single { it.wire == item.string("credits") }
            assertEquals(item.toString(), item.string("expect"), TonoCloudWalletProtocol.guidance(condition, item.bool("wallet_claimable")).wire)
        }
    }

    @Test
    fun creditsResponses() {
        val all = cases("credits_responses")
        assertTrue(all.size >= 10)
        for (item in all) {
            val actual = TonoCloudResponsePolicy.PRODUCTION.creditsCondition(item.string("url")!!, item.int("status")!!, body(item))
            assertEquals(item.string("name"), item.obj("expect")!!.string("credits"), actual?.wire)
        }
        // An unread 402 body is still a credits answer.
        assertEquals(TonoCreditsCondition.UNSPECIFIED, TonoCloudResponsePolicy.creditsConditionOf402(null))
    }

    private object AllowAll : EgressPolicy {
        override fun permits(url: GatewayUrl): Boolean = true
        override fun admitsMcpGrant(url: GatewayUrl): Boolean = false
    }

    private object Fixed : GatewayCredentialProvider {
        override fun resolve(scope: CredentialScope): GatewayCredential = GatewayCredential.Bearer("at_TEST_ACCESS_0001")
    }

    /** Every 402 case on the real session: one contact, body unchanged, one report (none off-origin). */
    @Test
    fun gatewayForwardsCreditsAnswersOnce() {
        for (item in cases("credits_responses").filter { it.int("status") == 402 }) {
            val name = item.string("name")!!
            val answerBody = body(item)
            var contacts = 0
            val transport = object : GatewayTransport {
                override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                    contacts++
                    return GatewayTransportResponse(402, mapOf("content-type" to "application/json"), answerBody)
                }
            }
            val reported = ArrayList<TonoCreditsCondition>()
            val session = GatewaySession(
                transport = transport,
                credentialProvider = Fixed,
                egress = AllowAll,
                cloudPolicy = TonoCloudResponsePolicy.PRODUCTION,
                sleeper = { error("a credits answer must not wait or retry") },
                creditsHandler = { reported += it },
            )
            val request = """{"q":"x"}""".toByteArray(StandardCharsets.UTF_8)
            val outcome = session.exchange(GatewayRequest("POST", item.string("url")!!, mapOf("content-type" to "application/json"), request))
            assertEquals(name, 1, contacts)
            assertEquals(name, 402, outcome.responseStatus)
            assertArrayEquals(name, answerBody, outcome.responseBody)
            assertEquals(name, listOfNotNull(item.obj("expect")!!.string("credits")), reported.map { it.wire })
        }
    }

    // ---- client

    private class Tokens(private var value: String?, private val rotateTo: String? = null) : TonoAccessTokenSource {
        var invalidations = 0
        override fun accessToken(): String? = value
        override fun invalidate(token: String) {
            invalidations++
            if (rotateTo != null) value = rotateTo
        }
        override val hasSession: Boolean get() = value != null
    }

    private class Script(vararg answers: TonoAccountAnswer) : TonoAccountTransport {
        private val queue = ArrayDeque(answers.toList())
        val sent = ArrayList<TonoAccountRequest>()
        override fun send(request: TonoAccountRequest): TonoAccountAnswer {
            sent += request
            return queue.removeFirstOrNull() ?: throw java.io.IOException("offline")
        }
    }

    private val walletBody = """{"available_micro_credits":"4000000000","claimable":false,"mode":"live"}""".toByteArray()

    @Test
    fun clientNeverUsesAnApiKeyAndTreatsRepeatClaimAsSuccess() {
        val signedOut = Script()
        val none = TonoCloudWalletClient(signedOut, Tokens(null))
        assertNull(none.read())
        assertNull(none.claim())
        assertTrue(signedOut.sent.isEmpty())

        val claimBody = """{"granted_now":false,"wallet":{"available_micro_credits":"0","claimable":false}}""".toByteArray()
        val script = Script(TonoAccountAnswer(200, emptyMap(), walletBody), TonoAccountAnswer(200, emptyMap(), claimBody))
        val client = TonoCloudWalletClient(script, Tokens("at_TEST_ACCESS_0001"))
        assertEquals(TonoWalletReadOutcome.Wallet(TonoCloudWallet("4000000000", false, "live")), client.read())
        assertEquals(TonoWalletClaimOutcome.Claimed(false, TonoCloudWallet("0", false, null)), client.claim())
        assertEquals(listOf("GET", "POST"), script.sent.map { it.method })
        assertEquals(listOf("https://pdsh.tonoai.cn/v1/wallet", "https://pdsh.tonoai.cn/v1/wallet/claim"), script.sent.map { it.url })
        for (request in script.sent) {
            assertEquals("Bearer at_TEST_ACCESS_0001", request.headers["Authorization"])
            assertNull(request.headers["x-api-key"])
            assertEquals(0, request.body.size)
        }
    }

    @Test
    fun clientRefreshesOnceOnExpiredToken() {
        val expired = TonoAccountAnswer(401, emptyMap(), """{"error":{"code":"credential_expired"}}""".toByteArray())
        val script = Script(expired, TonoAccountAnswer(200, emptyMap(), walletBody))
        val tokens = Tokens("at_TEST_ACCESS_0001", rotateTo = "at_TEST_ACCESS_0002")
        assertEquals(TonoWalletReadOutcome.Wallet(TonoCloudWallet("4000000000", false, "live")), TonoCloudWalletClient(script, tokens).read())
        assertEquals(1, tokens.invalidations)
        assertEquals("Bearer at_TEST_ACCESS_0002", script.sent.last().headers["Authorization"])

        val again = Script(expired)
        assertEquals(TonoWalletReadOutcome.Unauthorized, TonoCloudWalletClient(again, Tokens("at_TEST_ACCESS_0001")).read())
        assertEquals(1, again.sent.size)
    }
}
