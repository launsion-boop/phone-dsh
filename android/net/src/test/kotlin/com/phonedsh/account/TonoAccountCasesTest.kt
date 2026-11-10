// phone-dsh — :net tests: spec/v1/golden/tono-account/cases.json on Android.
// SPDX-License-Identifier: MIT
//
// The shared cases judge the real Kotlin parser, request builders, outcome
// classifiers, record codec, clock and cloud-response policy, and the shared
// `retry_flows` drive the real GatewaySession with a scripted transport that
// stands in for the cloud origin. Nothing here contacts a tono service.

package com.phonedsh.account

import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.CredentialUnavailableException
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TonoAccountCasesTest {

    private val fixture: JsonValue.Obj by lazy {
        val path = GatewayVectorRunner.findRepositoryRoot().resolve("spec/v1/golden/tono-account/cases.json")
        assertTrue("shared cases must exist at $path", Files.isRegularFile(path))
        GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8)) as JsonValue.Obj
    }

    private fun cases(name: String): List<JsonValue.Obj> =
        requireNotNull(fixture.array(name)) { "$name is missing" }.map { it as JsonValue.Obj }

    private fun str(obj: JsonValue.Obj, name: String): String? = obj.string(name)

    private fun long(obj: JsonValue.Obj, name: String): Long? = (obj.get(name) as? JsonValue.Num)?.literal?.toLongOrNull()

    private fun body(item: JsonValue.Obj): ByteArray {
        item.string("body_text")?.let { return it.toByteArray(StandardCharsets.UTF_8) }
        val body = item.get("body") ?: return ByteArray(0)
        return GatewayJson.canonicalBytes(body)
    }

    private fun answer(item: JsonValue.Obj): TonoAccountAnswer? {
        if (item.bool("transport_error") == true) return null
        return TonoAccountAnswer(item.int("status")!!, item.stringMap("headers") ?: emptyMap(), body(item))
    }

    @Test
    fun constantsMatch() {
        val c = fixture.obj("constants")!!
        assertEquals(TonoAccountProtocol.ACCOUNT_ORIGIN, c.string("account_origin"))
        assertEquals(TonoCloudResponsePolicy.CLOUD_ORIGIN, c.string("cloud_origin"))
        assertEquals(TonoAccountProtocol.CLIENT_ID, c.string("client_id"))
        assertEquals(TonoAccountProtocol.OTP_GRANT_TYPE, c.string("otp_grant_type"))
        assertEquals(TonoAccountProtocol.DEFAULT_ACCESS_LIFETIME_SECONDS, c.int("default_access_lifetime_seconds"))
        assertEquals(TonoAccountProtocol.REFRESH_SKEW_SECONDS, c.int("refresh_skew_seconds"))
        assertEquals(TonoAccountProtocol.REVERIFY_AFTER_SECONDS, long(c, "reverify_after_seconds"))
        assertEquals(TonoCloudResponsePolicy.INSPECT_BODY_LIMIT, c.int("inspect_body_limit_bytes"))
        assertEquals(TonoCloudResponsePolicy.CREDENTIAL_RETRY_MAX, c.int("credential_retry_max"))
        assertEquals(TonoCloudResponsePolicy.IDENTITY_RETRY_MAX, c.int("identity_retry_max"))
        assertEquals(TonoCloudResponsePolicy.IDENTITY_RETRY_DEFAULT_SECONDS, long(c, "identity_retry_default_seconds"))
        assertEquals(TonoCloudResponsePolicy.IDENTITY_RETRY_CAP_SECONDS, long(c, "identity_retry_cap_seconds"))
        assertEquals(TonoAccountProtocol.TOKEN_MAX_LENGTH, c.int("token_max_length"))
        assertEquals(TonoAccountProtocol.RECORD_VERSION, c.int("record_version"))
    }

    @Test
    fun phonesAndCodes() {
        for (item in cases("phones")) {
            assertEquals(item.string("input"), item.string("canonical"), TonoAccountProtocol.canonicalPhone(item.string("input")!!))
        }
        for (item in cases("codes")) {
            assertEquals(item.string("input"), item.string("canonical"), TonoAccountProtocol.canonicalCode(item.string("input")!!))
        }
    }

    @Test
    fun requestEncodings() {
        for (item in cases("requests")) {
            val name = item.string("name")!!
            val input = item.obj("input")!!
            val expect = item.obj("expect")!!
            val request = when (item.string("operation")) {
                "send_code" -> TonoAccountProtocol.sendCodeRequest(input.string("phone")!!)
                "sign_in" -> {
                    val d = input.obj("device_info")!!
                    TonoAccountProtocol.signInRequest(
                        input.string("phone")!!, input.string("challenge_id")!!, input.string("code")!!,
                        TonoDeviceInfo(d.string("platform")!!, d.string("device_name")!!, d.string("app_version")!!, d.string("os_version")!!),
                    )
                }
                "refresh" -> TonoAccountProtocol.refreshRequest(input.string("refresh_token")!!)
                "sign_out" -> TonoAccountProtocol.signOutRequest(input.string("access_token")!!)
                else -> error("unknown operation in $name")
            }
            assertEquals(name, expect.string("method"), request.method)
            assertEquals(name, expect.string("url"), request.url)
            for ((key, value) in expect.stringMap("headers")!!) assertEquals("$name $key", value, request.headers[key])
            for (key in expect.array("absent_headers").orEmpty()) {
                assertFalse("$name ${(key as JsonValue.Str).value}", request.headers.containsKey(key.value))
            }
            expect.string("body")?.let { assertEquals(name, it, String(request.body, StandardCharsets.UTF_8)) }
            expect.get("body_json")?.let {
                assertTrue(name, GatewayJson.structuralEquals(it, GatewayJson.parse(String(request.body, StandardCharsets.UTF_8))))
            }
        }
    }

    @Test
    fun tokenResponses() {
        for (item in cases("token_responses")) {
            val name = item.string("name")!!
            val expect = item.obj("expect")!!
            val grant = TonoAccountProtocol.parseTokenResponse(body(item))
            if (expect.bool("valid") != true) {
                assertNull(name, grant)
                continue
            }
            assertNotNull(name, grant)
            assertEquals(name, expect.string("access_token"), grant!!.accessToken)
            assertEquals(name, expect.string("refresh_token"), grant.refreshToken)
            assertEquals(name, expect.int("expires_in"), grant.expiresIn)
            assertEquals(name, expect.string("user_id"), grant.userId)
            assertEquals(name, expect.string("phone_hint"), grant.phoneHint)
            assertFalse(name, grant.toString().contains(grant.accessToken))
        }
    }

    @Test
    fun outcomeClasses() {
        for (item in cases("otp_outcomes")) {
            val name = item.string("name")!!
            val expect = item.obj("expect")!!
            val expected: TonoOtpOutcome = when (expect.string("outcome")) {
                "challenge" -> TonoOtpOutcome.Challenge(expect.string("challenge_id")!!)
                "protocol_error" -> TonoOtpOutcome.ProtocolError
                "rejected" -> TonoOtpOutcome.Rejected
                "rate_limited" -> TonoOtpOutcome.RateLimited(expect.int("retry_after_seconds"))
                else -> TonoOtpOutcome.Transient
            }
            assertEquals(name, expected, TonoAccountProtocol.classifySendCode(answer(item)))
        }
        for (item in cases("login_outcomes")) {
            val name = item.string("name")!!
            val expect = item.obj("expect")!!
            val actual = TonoAccountProtocol.classifySignIn(answer(item))
            when (expect.string("outcome")) {
                "signed_in" -> assertTrue(name, actual is TonoLoginOutcome.SignedIn)
                "protocol_error" -> assertEquals(name, TonoLoginOutcome.ProtocolError, actual)
                "invalid_code" -> assertEquals(name, TonoLoginOutcome.InvalidCode, actual)
                "rejected" -> assertEquals(name, TonoLoginOutcome.Rejected, actual)
                "rate_limited" -> assertEquals(name, TonoLoginOutcome.RateLimited(expect.int("retry_after_seconds")), actual)
                else -> assertEquals(name, TonoLoginOutcome.Transient, actual)
            }
        }
        for (item in cases("refresh_outcomes")) {
            val name = item.string("name")!!
            val actual = TonoAccountProtocol.classifyRefresh(answer(item))
            when (item.obj("expect")!!.string("outcome")) {
                "rotated" -> assertTrue(name, actual is TonoRefreshOutcome.Rotated)
                "session_ended" -> assertEquals(name, TonoRefreshOutcome.SessionEnded, actual)
                else -> assertEquals(name, TonoRefreshOutcome.Transient, actual)
            }
        }
    }

    @Test
    fun sessionRecords() {
        for (item in cases("session_records")) {
            val name = item.string("name")!!
            val expect = item.obj("expect")!!
            val record = TonoAccountProtocol.decodeRecord(item.string("stored_text")!!.toByteArray(StandardCharsets.UTF_8))
            if (expect.bool("readable") != true) {
                assertNull(name, record)
                continue
            }
            assertEquals(
                name,
                TonoSessionRecord(expect.string("refresh_token")!!, long(expect, "login_at_ms")!!, expect.string("user_id"), expect.string("phone_hint")),
                record,
            )
            assertEquals(name, record, TonoAccountProtocol.decodeRecord(TonoAccountProtocol.encodeRecord(record!!)))
        }
    }

    @Test
    fun clock() {
        for (item in cases("clock")) {
            val actual = TonoAccountProtocol.clockDecision(
                long(item, "issued_at_ms")!!, item.int("expires_in")!!, long(item, "login_at_ms")!!, long(item, "now_ms")!!,
            )
            val expected = when (item.string("expect")) {
                "use" -> TonoClockDecision.USE
                "refresh" -> TonoClockDecision.REFRESH
                else -> TonoClockDecision.REVERIFY_REQUIRED
            }
            assertEquals(item.string("name"), expected, actual)
        }
    }

    @Test
    fun cloudResponses() {
        for (item in cases("cloud_responses")) {
            val name = item.string("name")!!
            var bytes = body(item)
            long(item, "pad_to_bytes")?.let { target ->
                assertTrue(name, bytes.size <= target)
                bytes += ByteArray((target - bytes.size).toInt()) { ' '.code.toByte() }
            }
            val decision = TonoCloudResponsePolicy.PRODUCTION.decide(
                item.string("url")!!, item.int("status")!!, item.stringMap("headers") ?: emptyMap(), bytes,
            )
            val expect = item.obj("expect")!!
            val expected = when (expect.string("action")) {
                "forward" -> TonoCloudResponsePolicy.Decision.Forward
                "refresh_retry" -> TonoCloudResponsePolicy.Decision.RefreshRetry
                else -> TonoCloudResponsePolicy.Decision.RetryAfter(long(expect, "delay_seconds")!!)
            }
            assertEquals(name, expected, decision)
        }
    }

    // ---- retry flows on the real GatewaySession

    private class FlowProvider(private val refresh: String) : GatewayCredentialProvider {
        var invalidations = 0
        private var value = "at_TEST_ACCESS_0001"
        private var unavailable = false

        override fun resolve(scope: CredentialScope): GatewayCredential {
            if (unavailable) throw CredentialUnavailableException("refresh failed")
            return GatewayCredential.Bearer(value)
        }

        override fun invalidate(credential: GatewayCredential, scope: CredentialScope) {
            invalidations++
            when (refresh) {
                "new_value" -> value = "at_TEST_ACCESS_${1 + invalidations}"
                "unavailable" -> unavailable = true
            }
        }
    }

    private object AllowAll : EgressPolicy {
        override fun permits(url: GatewayUrl): Boolean = true
        override fun admitsMcpGrant(url: GatewayUrl): Boolean = false
    }

    @Test
    fun retryFlowsDriveTheRealGateway() {
        val origin = "https://pdsh.tonoai.cn"
        for (flow in cases("retry_flows")) {
            val name = flow.string("name")!!
            val scripted = ArrayDeque(flow.array("responses")!!.map { it as JsonValue.Obj })
            val seen = ArrayList<GatewayTransportRequest>()
            val transport = object : GatewayTransport {
                override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
                    seen += request
                    val next = scripted.removeFirstOrNull() ?: return GatewayTransportResponse(599)
                    val headers = LinkedHashMap<String, String>()
                    headers["content-type"] = "application/json"
                    next.string("retry_after")?.let { headers["retry-after"] = it }
                    val code = next.string("code")
                    val text = if (code != null) """{"error":{"code":"$code"}}""" else """{"ok":true}"""
                    return GatewayTransportResponse(next.int("status")!!, headers, text.toByteArray(StandardCharsets.UTF_8))
                }
            }
            val provider = FlowProvider(flow.string("refresh")!!)
            val sleeps = ArrayList<Long>()
            val session = GatewaySession(
                transport = transport,
                credentialProvider = provider,
                egress = AllowAll,
                cloudPolicy = TonoCloudResponsePolicy.PRODUCTION,
                sleeper = { sleeps += it },
            )
            val body = """{"q":"x"}""".toByteArray(StandardCharsets.UTF_8)
            val outcome = session.exchange(GatewayRequest("POST", "$origin/v1/web/search", mapOf("content-type" to "application/json"), body))
            val expect = flow.obj("expect")!!
            assertEquals(name, expect.int("contacts"), seen.size)
            assertEquals(name, expect.int("contacts"), outcome.upstreamContacts)
            assertEquals(name, expect.int("final_status"), outcome.responseStatus)
            assertEquals(name, expect.int("invalidations"), provider.invalidations)
            assertEquals(name, expect.array("sleeps_seconds")!!.map { (it as JsonValue.Num).literal.toLong() * 1000 }, sleeps)
            for (request in seen) {
                assertArrayEquals(name, body, request.body)
                assertNotEquals(name, null, request.headers["authorization"])
            }
        }
    }
}
