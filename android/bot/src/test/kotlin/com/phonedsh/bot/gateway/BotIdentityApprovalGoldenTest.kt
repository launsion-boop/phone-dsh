// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotApprovalDecision
import com.phonedsh.bot.authz.BotApprovalDurableStatus
import com.phonedsh.bot.authz.BotApprovalOutcome
import com.phonedsh.bot.authz.BotApprovalResolution
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.authz.InMemoryAuthzEventLog
import com.phonedsh.bot.authz.ManualApprovalScheduler
import com.phonedsh.bot.authz.MutableClock
import com.phonedsh.bot.authz.assertJsonEquals
import com.phonedsh.bot.authz.jsonObject
import com.phonedsh.bot.session.BotSessionKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Drives every `identity-approval-cases.phone` case through the real identity
 * service, token registry, attribution registry, grant store and approval
 * coordinator. Clock and timers are injected; the fixture supplies all bodies
 * and expected strings.
 */
class BotIdentityApprovalGoldenTest {
    private val t0 = 1_760_000_000_000L

    @Test
    fun validCasesMatchTheFixture() {
        val fixture = GoldenFixture.rawObject("identity-approval-cases.phone")
        val cases = GoldenFixture.objects(fixture, "valid")
        assertTrue(cases.isNotEmpty())
        for (case in cases) runCase(case as JsonObject)
    }

    @Test
    fun invalidCasesMatchTheFixture() {
        val fixture = GoldenFixture.rawObject("identity-approval-cases.phone")
        val cases = GoldenFixture.objects(fixture, "invalid")
        assertTrue(cases.isNotEmpty())
        for (case in cases) runCase(case as JsonObject)
    }

    private fun runCase(case: JsonObject) {
        val label = GoldenFixture.requireString(case, "name")
        val clock = MutableClock(t0)
        val scheduler = ManualApprovalScheduler(clock)
        val log = InMemoryAuthzEventLog()
        val grants = BotGrantStore(log, { clock.value })
        val timeout = GoldenFixture.long(case, "approvalTimeoutMs")
            ?: BotApprovalCoordinator.DEFAULT_TIMEOUT_MILLISECONDS
        val expiry = GoldenFixture.long(case, "approvalExpiryMs")
            ?: BotApprovalCoordinator.DEFAULT_DURABLE_EXPIRY_MILLISECONDS
        val approvals = BotApprovalCoordinator(
            grants = grants,
            eventLog = log,
            now = { clock.value },
            approvalTimeoutMs = timeout,
            durableExpiryMs = expiry,
            scheduler = scheduler,
        )
        val tokens = BotTokenRegistry(now = { clock.value })
        val attributions = BotAttributionRegistry(now = { clock.value })
        val identity = BotIdentityRegistrationService(
            tokens = tokens,
            attributions = attributions,
            approvals = approvals,
            now = { clock.value },
        )
        val setup = GoldenFixture.objectValue(case, "setup")
        val session = GoldenFixture.requireString(setup, "sessionId")
        val botId = GoldenFixture.requireString(setup, "botId")
        val kind = BotSessionKind.fromWire(GoldenFixture.requireString(setup, "kind"))
        val capabilities = (GoldenFixture.at(setup, "capabilities") as? JsonArray)?.values
            ?.map { (it as JsonString).value } ?: emptyList()
        val issued = tokens.issueSession(botId, session, kind, capabilities)

        when (GoldenFixture.requireString(case, "kind")) {
            "register" -> runRegister(case, label, identity, tokens, issued)
            "cancel" -> runCancel(case, label, identity, issued)
            "approval" -> runApproval(case, label, identity, approvals, scheduler, clock, issued)
            else -> error("$label: unsupported kind")
        }
    }

    private fun runRegister(
        case: JsonObject,
        label: String,
        identity: BotIdentityRegistrationService,
        tokens: BotTokenRegistry,
        issued: BotIssuedToken,
    ) {
        val registration = GoldenFixture.objectValue(case, "registration")
        val args = GoldenFixture.at(registration, "arguments") ?: JsonObject(emptyMap())
        val bodyOverrides = (GoldenFixture.at(case, "body") as? JsonObject)?.members ?: emptyMap()
        val tokenMode = GoldenFixture.string(case, "token") ?: "current"
        val suppliedToken = when (tokenMode) {
            "current" -> issued.token
            "none" -> null
            "wrong" -> "dshg_" + "A".repeat(43)
            "revoked" -> {
                tokens.revoke(issued.token)
                issued.token
            }
            "foreign" -> {
                val foreignSession = (bodyOverrides["tokenSession"] as? JsonString)?.value ?: "gb-foreign"
                tokens.issueSession("main", foreignSession, BotSessionKind.CHAT).token
            }
            else -> error("$label: unknown token mode $tokenMode")
        }
        val digestMode = GoldenFixture.string(case, "argsDigest") ?: "computed"
        val digest = when (digestMode) {
            "computed" -> BotArgumentsDigest.string(args)
            "mismatch" -> "0".repeat(64)
            else -> error("$label: unknown digest mode")
        }
        val omitName = bodyOverrides["omitName"] == com.phonedsh.agentcore.JsonBool(true)
        val name = if (omitName) "" else GoldenFixture.requireString(registration, "tool")
        val result = identity.register(
            BotIdentityRegistrationRequest(
                runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                sessionId = GoldenFixture.requireString(case, "setup", "sessionId"),
                callId = GoldenFixture.requireString(registration, "callId"),
                name = name,
                arguments = args,
                argsDigest = digest,
                sessionToken = suppliedToken,
                nameProvided = !omitName,
            ),
        )
        val expect = GoldenFixture.objectValue(case, "expect")
        assertSubset(result.toJson(), expect, label)
        if (expect.members["ok"] == com.phonedsh.agentcore.JsonBool(true)) {
            val id = result.id ?: error("$label: success needs an id")
            assertEquals("$label id", 32, id.length)
            val live = identity.resolve(
                BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                GoldenFixture.requireString(case, "setup", "sessionId"),
                GoldenFixture.requireString(registration, "callId"),
            )
            assertNotNull("$label registration must be claimable", live)
            val expectedBare = GoldenFixture.string(case, "flags", "registeredBareName")
            if (expectedBare != null) assertEquals("$label bare name", expectedBare, live?.attribution?.name)
        }
    }

    private fun runCancel(
        case: JsonObject,
        label: String,
        identity: BotIdentityRegistrationService,
        issued: BotIssuedToken,
    ) {
        val expect = GoldenFixture.objectValue(case, "expect")
        val explicitBody = GoldenFixture.at(case, "body") as? JsonObject
        if (explicitBody != null) {
            val id = (explicitBody.members["id"] as? JsonString)?.value ?: ""
            assertEquals("$label ok", expect.members["ok"], com.phonedsh.agentcore.JsonBool(identity.cancel(id)))
            return
        }
        val registration = GoldenFixture.objectValue(case, "registration")
        val args = GoldenFixture.at(registration, "arguments") ?: JsonObject(emptyMap())
        val registered = identity.register(
            BotIdentityRegistrationRequest(
                runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                sessionId = GoldenFixture.requireString(case, "setup", "sessionId"),
                callId = GoldenFixture.requireString(registration, "callId"),
                name = GoldenFixture.requireString(registration, "tool"),
                arguments = args,
                argsDigest = BotArgumentsDigest.string(args),
                sessionToken = issued.token,
            ),
        )
        val id = registered.id ?: error("$label: registration failed")
        val firstExpected = GoldenFixture.bool(expect, "first")
            ?: GoldenFixture.bool(expect, "ok")
            ?: false
        assertEquals("$label first cancel", firstExpected, identity.cancel(id))
        if (GoldenFixture.bool(case, "twice") == true) {
            assertEquals("$label second cancel", GoldenFixture.bool(expect, "second"), identity.cancel(id))
        }
        assertNull(
            "$label cancelled registration must not be claimable",
            identity.resolve(
                BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                GoldenFixture.requireString(case, "setup", "sessionId"),
                GoldenFixture.requireString(registration, "callId"),
            ),
        )
    }

    private fun runApproval(
        case: JsonObject,
        label: String,
        identity: BotIdentityRegistrationService,
        approvals: BotApprovalCoordinator,
        scheduler: ManualApprovalScheduler,
        clock: MutableClock,
        issued: BotIssuedToken,
    ) {
        val registration = GoldenFixture.objectValue(case, "registration")
        val args = GoldenFixture.at(registration, "arguments") ?: JsonObject(emptyMap())
        val computedDigest = BotArgumentsDigest.string(args)
        val declared = GoldenFixture.string(case, "argsDigest")
        if (declared != null && declared != "0".repeat(64)) {
            assertEquals("$label fixture digest must match canonical JSON", declared, computedDigest)
        }
        val registered = identity.register(
            BotIdentityRegistrationRequest(
                runtimeId = BotIdentityRegistrationService.DEFAULT_RUNTIME_ID,
                sessionId = GoldenFixture.requireString(case, "setup", "sessionId"),
                callId = GoldenFixture.requireString(registration, "callId"),
                name = GoldenFixture.requireString(registration, "tool"),
                arguments = args,
                argsDigest = computedDigest,
                sessionToken = issued.token,
            ),
        )
        val registrationId = registered.id ?: error("$label: registration failed")
        val approval = GoldenFixture.objectValue(case, "approval")
        val body = linkedMapOf<String, JsonValue>(
            "sessionId" to JsonString(GoldenFixture.requireString(case, "setup", "sessionId")),
            "callId" to JsonString(
                GoldenFixture.string(approval, "callId")
                    ?: GoldenFixture.requireString(registration, "callId"),
            ),
            "tool" to JsonString(GoldenFixture.requireString(registration, "tool")),
            "argsDigest" to JsonString(declared ?: computedDigest),
            "alwaysScope" to JsonString(GoldenFixture.string(approval, "alwaysScope") ?: "until"),
        )
        if (GoldenFixture.bool(approval, "omitAlwaysScope") == true) body.remove("alwaysScope")
        for (key in listOf("action", "detail", "command", "effects", "askAction")) {
            approval.members[key]?.let { body[key] = it }
        }
        val bodyObject = JsonObject(body)
        val expect = GoldenFixture.objectValue(case, "expect")
        val post = (GoldenFixture.at(case, "post") as? JsonObject)?.members ?: emptyMap()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val future = executor.submit<BotApprovalOutcome> {
                approvals.approve(bodyObject, BotIdentityRegistrationService.DEFAULT_RUNTIME_ID, identity)
            }
            var approvalId: String? = null
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (System.nanoTime() < deadline) {
                if (future.isDone) break
                val pending = approvals.pendingIDs()
                if (pending.isNotEmpty()) {
                    approvalId = pending.first()
                    break
                }
                Thread.sleep(1)
            }
            val decision = GoldenFixture.string(case, "decision")
            if (approvalId != null) {
                Thread.sleep(2)
                if (post["cancelRegistration"] == com.phonedsh.agentcore.JsonBool(true)) {
                    identity.cancel(registrationId)
                } else if (decision != null) {
                    val resolved = approvals.resolve(
                        approvalId,
                        BotApprovalDecision.fromWire(decision) ?: BotApprovalDecision.DENY,
                        computedDigest,
                    )
                    assertEquals("$label resolve", BotApprovalResolution.Resolved, resolved)
                }
            } else if (expect.members["message"] == JsonString("approval timed out")) {
                // The card is already pending; the loop above should have seen it.
                error("$label: timed-out approval never became pending")
            }
            if (expect.members["message"] == JsonString("approval timed out")) {
                clock.value += 50
                scheduler.runDue()
            }
            val outcome = future.get(5, TimeUnit.SECONDS)
            assertSubset(outcome.toJson(), expect, label)

            if (expect.members["pending"] == com.phonedsh.agentcore.JsonBool(true)) {
                val expiresAt = outcome.expiresAt
                assertNotNull("$label pending needs expiresAt", expiresAt)
                if (GoldenFixture.bool(case, "flags", "expiresAtPositive") == true) {
                    assertTrue("$label expiresAt must be positive", (expiresAt ?: 0) > 0)
                }
                val liveId = approvals.pendingIDs().firstOrNull() ?: approvalId
                    ?: error("$label: durable id missing")
                val expireAfter = GoldenFixture.long(case, "expireAfterMs")
                if (expireAfter != null) {
                    clock.value += expireAfter
                    scheduler.runDue()
                }
                val expectedStatus = (post["durableStatus"] as? JsonString)?.value
                if (expectedStatus != null) {
                    assertEquals(
                        "$label durable status",
                        BotApprovalDurableStatus.entries.first { it.wire == expectedStatus },
                        approvals.durableStatus(liveId),
                    )
                }
                val resolve = (post["resolve"] as? JsonString)?.value
                if (resolve != null) {
                    val resolution = approvals.resolve(
                        liveId,
                        BotApprovalDecision.fromWire(resolve) ?: BotApprovalDecision.ALLOW_ONCE,
                        computedDigest,
                    )
                    if (expectedStatus != null) {
                        assertEquals(
                            "$label expired resolve",
                            BotApprovalResolution.Stale(expectedStatus),
                            resolution,
                        )
                    } else {
                        assertEquals("$label durable resolve", BotApprovalResolution.Resolved, resolution)
                    }
                }
            }
        } finally {
            executor.shutdownNow()
        }
    }

    private fun assertSubset(actual: JsonObject, expected: JsonObject, label: String) {
        for ((key, value) in expected.members) {
            val actualValue = actual.members[key]
            assertNotNull("$label: missing $key", actualValue)
            assertJsonEquals("$label: $key", value, actualValue!!)
        }
    }
}
