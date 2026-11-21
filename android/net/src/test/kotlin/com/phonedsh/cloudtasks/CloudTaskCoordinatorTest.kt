// SPDX-License-Identifier: MIT
// phone-dsh — :net tests: the pull → admit → ack pass against a local cloud.
//
// Behaviour of cloud-tasks.md §2, §5–§7 on the real client and coordinator:
// ordering (ack only after the journal returned), redelivery and duplicates,
// transient refusals, the off switch, the 404 hold-off, the tono-account §5
// re-send, registration and key handling, terminal acks and single-flight.

package com.phonedsh.cloudtasks

import com.phonedsh.gateway.JsonValue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudTaskCoordinatorTest {
    private val start = 1_794_700_000_000
    private var now = start
    private val cloud = FakeCloud(start)
    private val tokens = FakeTokens("tok-1")
    private val preferences = InMemoryCloudTaskPreferences().apply {
        putString(CloudTaskIdentity.DEVICE_ID_KEY, DEVICE_ID)
        putBoolean(CloudTaskIdentity.ENABLED_KEY, true)
    }
    private val keys = InMemoryCloudTaskKeyStore()
    private val journal = FakeJournal()
    private val terminals = FakeTerminals()
    private var targetExists = true
    private val sleeps = ArrayList<Long>()
    private val target = CloudTaskTarget(CloudTaskTargetKind.DSH_SESSION, "gb-main")

    private fun coordinator(tokenSource: FakeTokens = tokens, fcm: () -> String? = { null }) = CloudTaskCoordinator(
        client = CloudTaskClient(cloud, tokenSource) { sleeps += it },
        preferences = preferences,
        keys = keys,
        targets = { targetExists },
        admitter = journal,
        terminals = terminals,
        appVersion = "1.4.0",
        clock = { now },
        fcmToken = fcm,
    )

    private fun advance(ms: Long) {
        now += ms
        cloud.now += ms
    }

    /** What a submitter does: seal to the device's registered key and leave the task. */
    private fun submit(taskId: String, text: ByteArray = "整理今天的会议纪要".toByteArray(), ttlMs: Long = 3_600_000): FakeCloud.Task {
        val device = cloud.devices.getValue(DEVICE_ID)
        val requestId = "req-$taskId"
        val expiresAtMs = cloud.now + ttlMs
        val sealed = CloudTaskCrypto.seal(
            CloudTaskWire.base64UrlDecode(device.publicKey),
            text,
            CloudTaskCrypto.aad(DEVICE_ID, device.keyId, requestId, target, expiresAtMs),
        )
        return cloud.add(FakeCloud.Task(taskId, requestId, device.keyId, target, expiresAtMs, sealed))
    }

    private fun registered(): CloudTaskCoordinator {
        val coordinator = coordinator()
        assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
        return coordinator
    }

    // ---- registration

    @Test
    fun theFirstPassRegistersAnAndroidDeviceWithNoPushAndASavedKey() {
        val report = coordinator().runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        val device = cloud.devices.getValue(DEVICE_ID)
        assertEquals("android", device.platform)
        assertEquals(JsonValue.Null, device.body.get("push"))
        assertEquals("1.4.0", device.body.string("app_version"))
        assertEquals(setOf(device.keyId), keys.keyIds)
        val record = CloudTaskIdentity.decodeRecord(device.keyId, keys.load(device.keyId)!!)!!
        assertEquals(device.publicKey, CloudTaskWire.base64UrlEncode(record.pair.publicKey))
        assertEquals("cloud-tasks.key.${device.keyId}", CloudTaskKeyStore.storageKey(device.keyId))
        assertEquals(listOf("GET /v1/phone/devices", "PUT /v1/phone/devices/$DEVICE_ID", "GET /v1/phone/tasks/pull"),
            cloud.seen.map { "${it.method} ${it.path}" })
        assertEquals("device_id=$DEVICE_ID&limit=16&lease_s=300&wait_s=0", cloud.seen.last().query)
        assertTrue(cloud.seen.all { it.authorization == "Bearer tok-1" })
    }

    @Test
    fun tokenRefreshRegistersSameDeviceAndKeepsTheSealingKey() {
        var token = "fixture:one"
        val phone = coordinator(fcm = { token })
        assertEquals(CloudTaskPassStatus.COMPLETED, phone.runPass().status)
        val saved = cloud.devices.getValue(DEVICE_ID)
        assertEquals(token, saved.body.obj("push")?.string("token"))
        token = "fixture:two"
        assertEquals(CloudTaskPassStatus.COMPLETED, phone.runPass().status)
        val refreshed = cloud.devices.getValue(DEVICE_ID)
        assertEquals(saved.keyId, refreshed.keyId)
        assertEquals(saved.publicKey, refreshed.publicKey)
        assertEquals(token, refreshed.body.obj("push")?.string("token"))
        assertEquals(2, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID"))
    }

    @Test
    fun olderCloudRejectsFcmOnceThenContinuesWithNullAddress() {
        cloud.allowFcm = false
        val phone = coordinator(fcm = { "fixture:one" })
        assertEquals(CloudTaskPassStatus.COMPLETED, phone.runPass().status)
        assertEquals(JsonValue.Null, cloud.devices.getValue(DEVICE_ID).body.get("push"))
        assertEquals(2, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID"))
        assertEquals(CloudTaskPassStatus.COMPLETED, phone.runPass().status)
        assertEquals(2, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID"))
    }

    @Test
    fun aNewProcessReusesTheRegisteredKey() {
        registered()
        val keyId = cloud.devices.getValue(DEVICE_ID).keyId
        submit("t-1")
        val report = coordinator().runPass()
        assertEquals(keyId, cloud.devices.getValue(DEVICE_ID).keyId)
        assertEquals(1, report.admittedIds.size)
        assertEquals("admitted", cloud.tasks[0].state)
    }

    @Test
    fun aLostKeyRecordIsReplacedAndTheOldRecordGoesOnceThePullIsEmpty() {
        registered()
        val old = cloud.devices.getValue(DEVICE_ID).keyId
        // The cloud holds a public key this phone's record does not match.
        val other = CloudTaskCrypto.generateKeyPair()
        cloud.devices[DEVICE_ID] = FakeCloud.Device(old, CloudTaskWire.base64UrlEncode(other.publicKey), "android", JsonValue.obj())
        cloud.loseRequestOnce += "GET /v1/phone/tasks/pull"
        val coordinator = coordinator()
        assertEquals(CloudTaskPassStatus.UNREACHABLE, coordinator.runPass().status)
        val current = cloud.devices.getValue(DEVICE_ID).keyId
        assertNotEquals(old, current)
        assertEquals("the previous key stays until a pull came back empty", setOf(old, current), keys.keyIds)

        // Next pass: the pull is empty, so no pending task can name the old key.
        assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
        assertEquals(setOf(current), keys.keyIds)
        assertEquals(1, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID") - 1)
    }

    @Test
    fun aKeyMismatchAnswerMakesANewKeyWithANewIdAndRegistersAgainOnce() {
        // The device list is stale: the cloud holds another public key under the id this phone sends.
        val ids = ArrayDeque(listOf("k-same", "k-new", "k-never"))
        val other = CloudTaskCrypto.generateKeyPair()
        var lists = 0
        cloud.onRequest = { seen ->
            if (seen.method == "GET" && seen.path == "/v1/phone/devices" && ++lists == 1) {
                cloud.devices.clear()
            } else if (seen.method == "PUT" && cloud.devices.isEmpty() && cloud.count("PUT", seen.path) == 1) {
                cloud.devices[DEVICE_ID] =
                    FakeCloud.Device("k-same", CloudTaskWire.base64UrlEncode(other.publicKey), "android", JsonValue.obj())
            }
        }
        val coordinator = CloudTaskCoordinator(
            client = CloudTaskClient(cloud, tokens),
            preferences = preferences,
            keys = keys,
            targets = { true },
            admitter = journal,
            appVersion = "1.4.0",
            clock = { now },
            newKeyId = { ids.removeFirst() },
        )
        assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
        assertEquals(2, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID"))
        val device = cloud.devices.getValue(DEVICE_ID)
        assertEquals("k-new", device.keyId)
        val record = CloudTaskIdentity.decodeRecord("k-new", keys.load("k-new")!!)!!
        assertEquals(device.publicKey, CloudTaskWire.base64UrlEncode(record.pair.publicKey))
        assertEquals("the refused key's record goes once the pull came back empty", setOf("k-new"), keys.keyIds)

        // A cloud that keeps answering key_mismatch is asked twice in a pass, not in a loop.
        val stubborn = CloudTaskTransport { request ->
            if (request.method == "GET") {
                CloudTaskHttpAnswer(200, body = """{"schema":"phone-device-list/v1","devices":[],"server_time_ms":1}""".toByteArray())
            } else {
                CloudTaskHttpAnswer(409, body = """{"error":{"code":"key_mismatch","message":"x"},"server_time_ms":1}""".toByteArray())
            }
        }
        var puts = 0
        val counting = CloudTaskTransport { request ->
            if (request.method == "PUT") puts++
            stubborn.send(request)
        }
        val refused = CloudTaskCoordinator(
            client = CloudTaskClient(counting, tokens),
            preferences = preferences,
            keys = InMemoryCloudTaskKeyStore(),
            targets = { true },
            admitter = journal,
            appVersion = "1.4.0",
        ).runPass()
        assertEquals(CloudTaskPassStatus.REFUSED, refused.status)
        assertEquals("key_mismatch", refused.refusedCode)
        assertEquals(2, puts)
    }

    @Test
    fun aLockedKeyStoreNeitherRegistersNorAcks() {
        registered()
        submit("t-1")
        keys.locked = true
        val before = cloud.seen.size
        val report = coordinator().runPass()
        assertEquals(CloudTaskPassStatus.KEY_STORE_UNAVAILABLE, report.status)
        assertEquals(0, cloud.count("POST", "/v1/phone/tasks/ack"))
        assertEquals("only the device list was read", before + 1, cloud.seen.size)
        assertEquals("pending", cloud.tasks[0].state)
    }

    @Test
    fun aKeyStoreThatLocksMidPassLeavesTheTaskForRedelivery() {
        val coordinator = registered()
        submit("t-1")
        keys.locked = true
        val report = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(1, report.deferred)
        assertTrue(cloud.acks().isEmpty())
        assertTrue(journal.requests.isEmpty())
    }

    @Test
    fun anUnknownDeviceAtPullIsRegisteredAgainOnce() {
        val coordinator = registered()
        val keyId = cloud.devices.getValue(DEVICE_ID).keyId
        cloud.devices.clear()
        assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
        assertEquals("the same key is registered again", keyId, cloud.devices.getValue(DEVICE_ID).keyId)
        assertEquals(2, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID"))
    }

    // ---- admit and ack

    @Test
    fun theAckIsSentOnlyAfterTheJournalReturned() {
        val coordinator = registered()
        submit("t-1")
        val order = ArrayList<String>()
        journal.onAdmit = {
            assertEquals("no ack before the journal write returned", 0, cloud.count("POST", "/v1/phone/tasks/ack"))
            order += "admit"
        }
        cloud.onRequest = { if (it.path == "/v1/phone/tasks/ack") order += "ack" }
        val report = coordinator.runPass()
        assertEquals(listOf("admit", "ack"), order)
        val request = journal.requests.single()
        assertEquals(DEVICE_ID, request.deviceId)
        assertEquals("t-1", request.taskId)
        assertEquals(target, request.target)
        assertEquals("整理今天的会议纪要", request.text)
        assertEquals(cloud.tasks[0].expiresAtMs, request.expiresAtMs)
        assertEquals("cloud-task", CloudTaskAdmissionRequest.SOURCE_KIND)
        assertEquals("account:u-1", CloudTaskAdmissionRequest.principal("u-1"))
        assertFalse("the text is never printed", request.toString().contains("会议"))
        assertEquals(listOf(journal.records.getValue("t-1")), report.admittedIds)
        assertEquals(1, report.acksAccepted)
        assertEquals("admitted", cloud.tasks[0].state)
        assertEquals(journal.records.getValue("t-1"), cloud.tasks[0].admissionId)
        // The pass went round again because the pull returned work, and stopped on the empty pull.
        assertEquals(3, cloud.count("GET", "/v1/phone/tasks/pull"))
    }

    @Test
    fun aLostAckIsRepeatedAfterRedeliveryWithTheSameAdmissionId() {
        val coordinator = registered()
        submit("t-1")
        cloud.loseRequestOnce += "POST /v1/phone/tasks/ack"
        val first = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.UNREACHABLE, first.status)
        assertEquals("the journal holds the record although the ack was lost", 1, first.admittedIds.size)
        assertEquals("pending", cloud.tasks[0].state)

        // Inside the lease nothing is redelivered and nothing is sent twice.
        assertEquals(0, coordinator.runPass().pulled)

        advance(301_000)
        val second = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, second.status)
        assertEquals("a duplicate admission is not a new record", emptyList<String>(), second.admittedIds)
        assertEquals(2, journal.requests.size)
        assertEquals(2L, cloud.tasks[0].attempt)
        assertEquals("admitted", cloud.tasks[0].state)
        val acks = cloud.acks()
        assertEquals(2, acks.size)
        assertEquals(acks[0].string("admission_id"), acks[1].string("admission_id"))
        assertEquals(journal.records.getValue("t-1"), cloud.tasks[0].admissionId)
    }

    @Test
    fun repeatingAnAdmittedAckIsAcceptedAsDuplicate() {
        registered()
        submit("t-1")
        val client = CloudTaskClient(cloud, tokens)
        val ack = CloudTaskAck.Admitted("t-1", "ab".repeat(32))
        val first = (client.ack(DEVICE_ID, listOf(ack)) as CloudTaskReply.Ok).value.results.single()
        assertEquals(CloudTaskAckResult("t-1", accepted = true, duplicate = false, state = CloudTaskState.ADMITTED), first)
        val again = (client.ack(DEVICE_ID, listOf(ack, CloudTaskAck.Expired("t-9"))) as CloudTaskReply.Ok).value.results
        assertEquals(CloudTaskAckResult("t-1", accepted = true, duplicate = true, state = CloudTaskState.ADMITTED), again[0])
        assertEquals(CloudTaskAckResult("t-9", accepted = false, duplicate = false, state = CloudTaskState.NOT_FOUND), again[1])
    }

    @Test
    fun aFullJournalSendsNoAckAndTheTaskComesBackAfterTheLease() {
        val coordinator = registered()
        submit("t-1")
        journal.next = CloudTaskAdmissionResult.CAPACITY
        val pulls = cloud.count("GET", "/v1/phone/tasks/pull")
        val report = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(1, report.deferred)
        assertEquals("no further pull after a transient refusal", pulls + 1, cloud.count("GET", "/v1/phone/tasks/pull"))
        assertTrue(cloud.acks().isEmpty())

        journal.next = null
        advance(301_000)
        assertEquals(1, coordinator.runPass().admittedIds.size)
        assertEquals("admitted", cloud.tasks[0].state)
    }

    @Test
    fun aThrowingJournalOrAnAdmissionWithoutAnIdSendsNoAck() {
        val coordinator = registered()
        submit("t-1")
        journal.onAdmit = { error("disk") }
        assertEquals(1, coordinator.runPass().deferred)
        assertTrue(cloud.acks().isEmpty())

        advance(301_000)
        val broken = CloudTaskCoordinator(
            client = CloudTaskClient(cloud, tokens),
            preferences = preferences,
            keys = keys,
            targets = { true },
            admitter = { CloudTaskAdmission(CloudTaskAdmissionResult.ADMITTED, "NOT-HEX") },
            appVersion = "1.4.0",
            clock = { now },
        )
        assertEquals(1, broken.runPass().deferred)
        assertTrue(cloud.acks().isEmpty())
    }

    @Test
    fun aBatchMixesAcksInPullOrderAndBytesThatAreNotUtf8DoNotOpen() {
        val coordinator = registered()
        submit("t-ok")
        submit("t-late", ttlMs = 500)
        submit("t-bytes", text = byteArrayOf(0xC3.toByte(), 0x28))
        val report = coordinator.runPass()
        assertEquals(3, report.pulled)
        assertEquals(
            listOf("t-ok:admitted:null", "t-late:expired:null", "t-bytes:rejected:decrypt_failed"),
            cloud.acks().map { "${it.string("task_id")}:${it.string("state")}:${it.string("reason")}" },
        )
        assertEquals(1, cloud.count("POST", "/v1/phone/tasks/ack"))
        assertEquals(listOf("t-ok"), journal.requests.map { it.taskId })
    }

    @Test
    fun aPulledElementWithATagOnlyCiphertextIsUndecodable() {
        val coordinator = registered()
        val task = submit("t-1")
        cloud.rawPullOnce = listOf(
            JsonValue.obj(
                "task_id" to JsonValue.Str("t-1"),
                "request_id" to JsonValue.Str(task.requestId),
                "key_id" to JsonValue.Str(task.keyId),
                "target" to JsonValue.obj("kind" to JsonValue.Str("dsh-session"), "id" to JsonValue.Str("gb-main")),
                "expires_at_ms" to JsonValue.num(task.expiresAtMs),
                "created_at_ms" to JsonValue.num(start),
                "sealed" to JsonValue.obj(
                    "enc" to JsonValue.Str(CloudTaskWire.base64UrlEncode(task.sealed.enc)),
                    "ct" to JsonValue.Str(CloudTaskWire.base64UrlEncode(ByteArray(16))),
                ),
                "lease" to JsonValue.obj(
                    "lease_id" to JsonValue.Str("l-1"),
                    "attempt" to JsonValue.num(1),
                    "expires_at_ms" to JsonValue.num(start + 300_000),
                ),
            ),
        )
        val report = coordinator.runPass()
        assertEquals(1, report.undecodable)
        assertEquals("rejected:invalid", cloud.acks().first().let { "${it.string("state")}:${it.string("reason")}" })
    }

    @Test
    fun aMissingTargetIsRejectedWithoutTouchingTheJournal() {
        val coordinator = registered()
        submit("t-1")
        targetExists = false
        coordinator.runPass()
        assertEquals("rejected", cloud.tasks[0].state)
        assertEquals("target_missing", cloud.acks().single().string("reason"))
        assertTrue(journal.requests.isEmpty())
    }

    @Test
    fun unknownMembersInAnswersAreIgnored() {
        val coordinator = registered()
        submit("t-1")
        cloud.extraPullMember = "next_cursor" to JsonValue.Str("x")
        val report = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(1, report.admittedIds.size)
        assertEquals("admitted", cloud.tasks[0].state)
    }

    @Test
    fun anAnswerMissingANamedMemberIsAProtocolError() {
        val transport = CloudTaskTransport { request ->
            when {
                request.url.endsWith("/v1/phone/devices") -> CloudTaskHttpAnswer(
                    200, body = """{"schema":"phone-device-list/v1","devices":[],"server_time_ms":1,"more":{}}""".toByteArray(),
                )
                request.method == "PUT" -> CloudTaskHttpAnswer(
                    200,
                    body = """{"schema":"phone-device-ack/v1","device_id":"$DEVICE_ID","key_id":"k-fixed","x":1}"""
                        .toByteArray(),
                )
                else -> CloudTaskHttpAnswer(200, body = """{"schema":"phone-task-pull/v1","tasks":[],"server_time_ms":1}""".toByteArray())
            }
        }
        val coordinator = CloudTaskCoordinator(
            client = CloudTaskClient(transport, tokens),
            preferences = preferences,
            keys = keys,
            targets = { true },
            admitter = journal,
            appVersion = "1.4.0",
            newKeyId = { "k-fixed" },
        )
        assertEquals("server_time_ms is required", CloudTaskPassStatus.PROTOCOL_ERROR, coordinator.runPass().status)
    }

    @Test
    fun onePassIsBounded() {
        val coordinator = registered()
        repeat(200) { submit("t-$it") }
        val pulls = cloud.count("GET", "/v1/phone/tasks/pull")
        val report = coordinator.runPass()
        assertEquals(8, cloud.count("GET", "/v1/phone/tasks/pull") - pulls)
        assertEquals(128, report.pulled)
        assertEquals(128, report.acksAccepted)
        assertTrue(cloud.seen.filter { it.path == "/v1/phone/tasks/ack" }.all { it.body!!.array("acks")!!.size == 16 })
    }

    // ---- terminal acks

    @Test
    fun aTerminalAckIsResentUntilTheCloudAcceptedIt() {
        val coordinator = registered()
        submit("t-1")
        coordinator.runPass()
        val admissionId = journal.records.getValue("t-1")
        terminals.waiting += CloudTaskTerminal("t-1", admissionId, "failed", "turn_cancelled")

        cloud.loseRequestOnce += "POST /v1/phone/tasks/ack"
        assertEquals(CloudTaskPassStatus.UNREACHABLE, coordinator.runPass().status)
        assertTrue(terminals.settled.isEmpty())
        assertEquals("admitted", cloud.tasks[0].state)

        val report = coordinator.runPass()
        assertEquals(1, report.terminalsSettled)
        assertEquals(listOf("t-1" to CloudTaskState.FAILED), terminals.settled)
        assertEquals("failed", cloud.tasks[0].state)
        assertEquals("run_failed", cloud.acks().last().string("reason"))

        val acks = cloud.count("POST", "/v1/phone/tasks/ack")
        coordinator.runPass()
        assertEquals("a settled record is not sent again", acks, cloud.count("POST", "/v1/phone/tasks/ack"))
    }

    @Test
    fun aTerminalAckForATaskTheCloudStillHoldsPendingSendsTheAdmittedAckFirst() {
        val coordinator = registered()
        val task = submit("t-1")
        // The journal admitted it earlier, the `admitted` ack never reached the cloud.
        task.leaseUntilMs = cloud.now + 300_000
        val admissionId = "cd".repeat(32)
        terminals.waiting += CloudTaskTerminal("t-1", admissionId, "completed")
        val report = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(listOf("completed", "admitted", "completed"), cloud.acks().map { it.string("state") })
        assertEquals("completed", task.state)
        assertEquals(admissionId, task.admissionId)
        assertEquals(listOf("t-1" to CloudTaskState.COMPLETED), terminals.settled)
    }

    @Test
    fun aTerminalAckTheCloudWillNeverAcceptIsSettledWithTheCloudsState() {
        val coordinator = registered()
        submit("t-1")
        coordinator.runPass()
        cloud.tasks[0].state = "unknown" // the cloud's 21-day rule won
        terminals.waiting += CloudTaskTerminal("t-1", journal.records.getValue("t-1"), "completed")
        terminals.waiting += CloudTaskTerminal("t-gone", "ef".repeat(32), "unknown", "attribution_timeout")
        terminals.waiting += CloudTaskTerminal("t-live", "ef".repeat(32), "linked")
        coordinator.runPass()
        assertEquals(listOf("t-1" to CloudTaskState.UNKNOWN), terminals.settled)
        assertEquals("unknown", cloud.tasks[0].state)
        // `not_found` is not final: the record is kept and sent again on the next pass.
        assertEquals(listOf("t-gone", "t-live"), terminals.waiting.map { it.taskId })
        val before = cloud.acks().count { it.string("task_id") == "t-gone" }
        coordinator.runPass()
        assertEquals(before + 1, cloud.acks().count { it.string("task_id") == "t-gone" })
    }

    @Test
    fun terminalAcksAnsweredNotFoundWhileUnregisteredAreSentAgainAfterRegistering() {
        val coordinator = registered()
        submit("t-1")
        coordinator.runPass()
        val admissionId = journal.records.getValue("t-1")
        assertTrue(coordinator.disable() is CloudTaskReply.Ok)
        terminals.waiting += CloudTaskTerminal("t-1", admissionId, "completed")

        // While the device is not registered every ack is `not_found`.
        val reply = CloudTaskClient(cloud, tokens).ack(DEVICE_ID, listOf(CloudTaskAck.Completed("t-1")))
        assertEquals(CloudTaskState.NOT_FOUND, (reply as CloudTaskReply.Ok).value.results.single().state)
        assertEquals(CloudTaskPassStatus.DISABLED, coordinator.runPass().status)
        assertEquals(1, terminals.waiting.size)

        coordinator.enable()
        val report = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(listOf("t-1" to CloudTaskState.COMPLETED), terminals.settled)
        assertEquals("completed", cloud.tasks[0].state)
    }

    @Test
    fun nowIsThePullAnswersServerTimeAndTheLocalClockOnlyWithoutIt() {
        val coordinator = registered()
        submit("t-1", ttlMs = 3_600_000)
        // The phone's clock runs two hours ahead; by the cloud's clock the task has an hour left.
        now += 7_200_000
        assertEquals(1, coordinator.runPass().admittedIds.size)
        assertEquals("admitted", cloud.tasks[0].state)

        val bodies = ArrayDeque(listOf(
            """{"schema":"phone-device-list/v1","devices":[],"server_time_ms":1}""",
            """{"schema":"phone-device-ack/v1","device_id":"$DEVICE_ID","key_id":"k-fixed","server_time_ms":1}""",
            """{"schema":"phone-task-pull/v1","tasks":[{"task_id":"t-9","request_id":"r","key_id":"k-none",
               "target":{"kind":"bot","id":"b"},"expires_at_ms":${now + 500},"created_at_ms":1,
               "sealed":{"enc":"${CloudTaskWire.base64UrlEncode(ByteArray(65))}","ct":"${CloudTaskWire.base64UrlEncode(ByteArray(17))}"},
               "lease":{"lease_id":"l","attempt":1,"expires_at_ms":2}}]}""",
        ))
        val sent = ArrayList<String>()
        val transport = CloudTaskTransport { request ->
            request.body?.let { sent += String(it) }
            CloudTaskHttpAnswer(200, body = (bodies.removeFirstOrNull()
                ?: """{"schema":"phone-task-ack-result/v1","results":[{"task_id":"t-9","accepted":true,"duplicate":false,"state":"expired"}],"server_time_ms":1}""")
                .toByteArray())
        }
        val local = CloudTaskCoordinator(
            client = CloudTaskClient(transport, tokens),
            preferences = preferences,
            keys = InMemoryCloudTaskKeyStore(),
            targets = { true },
            admitter = journal,
            appVersion = "1.4.0",
            clock = { now },
            newKeyId = { "k-fixed" },
            maxRounds = 1,
        )
        assertEquals(CloudTaskPassStatus.COMPLETED, local.runPass().status)
        assertTrue("without server_time_ms the local clock judges expiry", sent.last().contains(""""state":"expired""""))
    }

    // ---- off switch, credentials, availability

    @Test
    fun whileOffNothingIsSent() {
        val fresh = InMemoryCloudTaskPreferences()
        val coordinator = CloudTaskCoordinator(
            client = CloudTaskClient(cloud, tokens),
            preferences = fresh,
            keys = keys,
            targets = { true },
            admitter = journal,
            appVersion = "1.4.0",
        )
        assertFalse("absent is off", coordinator.isEnabled)
        assertEquals(CloudTaskPassStatus.DISABLED, coordinator.runPass().status)
        assertTrue(cloud.seen.isEmpty())
        assertNull("no device id is created while off", fresh.string(CloudTaskIdentity.DEVICE_ID_KEY))
        assertTrue(keys.keyIds.isEmpty())

        coordinator.enable()
        assertEquals(true, fresh.boolean("phone-dsh.cloud-tasks.enabled.v1"))
        assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
        val created = fresh.string("phone-dsh.bot.cloud.device-id.v1")!!
        assertTrue(Regex("^dev-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(created))
        assertEquals(setOf(created), cloud.devices.keys)
    }

    @Test
    fun turningItOffDeletesTheRegistrationAndStopsEverything() {
        val coordinator = registered()
        submit("t-1")
        val reply = coordinator.disable()
        assertTrue(reply is CloudTaskReply.Ok)
        assertEquals(false, preferences.boolean(CloudTaskIdentity.ENABLED_KEY))
        assertEquals(1, cloud.count("DELETE", "/v1/phone/devices/$DEVICE_ID"))
        assertTrue(cloud.devices.isEmpty())
        assertEquals("cancelled", cloud.tasks[0].state)

        val before = cloud.seen.size
        assertEquals(CloudTaskPassStatus.DISABLED, coordinator.runPass().status)
        assertEquals(before, cloud.seen.size)
    }

    @Test
    fun aStoredDeviceIdThatIsNotOneIsNeitherUsedNorOverwritten() {
        preferences.putString(CloudTaskIdentity.DEVICE_ID_KEY, "DEV-not-a-uuid")
        assertEquals(CloudTaskPassStatus.NO_DEVICE_ID, coordinator().runPass().status)
        assertEquals("DEV-not-a-uuid", preferences.string(CloudTaskIdentity.DEVICE_ID_KEY))
        assertTrue(cloud.seen.isEmpty())
    }

    @Test
    fun signedOutOrAnApiKeySendsNothing() {
        assertEquals(CloudTaskPassStatus.NO_CREDENTIAL, coordinator(FakeTokens()).runPass().status)
        assertEquals(CloudTaskPassStatus.NO_CREDENTIAL, coordinator(FakeTokens("pdsk_live_key")).runPass().status)
        assertTrue(cloud.seen.isEmpty())
    }

    @Test
    fun aCloudWithoutTheRoutesIsUnavailableAndNotAskedAgainDuringTheHoldOff() {
        cloud.routesPresent = false
        val coordinator = coordinator()
        assertEquals(CloudTaskPassStatus.UNAVAILABLE, coordinator.runPass().status)
        assertEquals(1, cloud.seen.size)
        repeat(5) { assertEquals(CloudTaskPassStatus.UNAVAILABLE, coordinator.runPass().status) }
        assertEquals("no retry storm", 1, cloud.seen.size)
        assertTrue("no key is created for a cloud that cannot take it", keys.keyIds.isEmpty())

        advance(10 * 60 * 1000L)
        cloud.routesPresent = true
        assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
    }

    @Test
    fun anExpiredCredentialIsRefreshedAndTheRequestSentAgainOnce() {
        cloud.acceptedToken = "tok-2"
        val rotating = FakeTokens("tok-1", "tok-2")
        val report = coordinator(rotating).runPass()
        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(listOf("tok-1"), rotating.invalidated)
        assertEquals(listOf("Bearer tok-1", "Bearer tok-2"), cloud.seen.take(2).map { it.authorization })
        assertEquals(2, cloud.count("GET", "/v1/phone/devices"))
        assertEquals(1, cloud.count("PUT", "/v1/phone/devices/$DEVICE_ID"))
    }

    @Test
    fun anExpiredCredentialThatDoesNotChangeOrStaysExpiredIsNotRetriedFurther() {
        cloud.acceptedToken = "tok-9"
        val unchanged = FakeTokens("tok-1")
        val first = coordinator(unchanged).runPass()
        assertEquals(CloudTaskPassStatus.REFUSED, first.status)
        assertEquals(401, first.refusedStatus)
        assertEquals("credential_expired", first.refusedCode)
        assertEquals("an unchanged value is not sent again", 1, cloud.seen.size)

        val stillExpired = FakeTokens("tok-1", "tok-2", "tok-3")
        assertEquals(CloudTaskPassStatus.REFUSED, coordinator(stillExpired).runPass().status)
        assertEquals("exactly one re-send per request", 3, cloud.seen.size)
        assertEquals(listOf("tok-1"), stillExpired.invalidated)
    }

    @Test
    fun identityUnavailableWaitsAndIsSentAgainAtMostTwice() {
        var contacts = 0
        val transport = CloudTaskTransport {
            contacts++
            CloudTaskHttpAnswer(
                503,
                mapOf("retry-after" to "3"),
                """{"error":{"code":"identity_unavailable","message":"x"},"server_time_ms":1}""".toByteArray(),
            )
        }
        val reply = CloudTaskClient(transport, tokens) { sleeps += it }.listDevices()
        assertEquals(CloudTaskReply.Refused(503, "identity_unavailable"), reply)
        assertEquals(3, contacts)
        assertEquals(listOf(3L, 3L), sleeps)
    }

    @Test
    fun aRefusalCarriesTheContractCode() {
        val transport = CloudTaskTransport {
            CloudTaskHttpAnswer(409, body = """{"error":{"code":"device_limit","message":"x"},"server_time_ms":1}""".toByteArray())
        }
        val coordinator = CloudTaskCoordinator(
            client = CloudTaskClient(transport, tokens),
            preferences = preferences,
            keys = keys,
            targets = { true },
            admitter = journal,
            appVersion = "1.4.0",
        )
        val report = coordinator.runPass()
        assertEquals(CloudTaskPassStatus.REFUSED, report.status)
        assertEquals(409, report.refusedStatus)
        assertEquals("device_limit", report.refusedCode)
    }

    // ---- single flight

    @Test
    fun aSecondCallDuringAPassIsBusyAndMakesTheRunningPassGoRoundAgain() {
        val coordinator = registered()
        submit("t-1")
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        journal.onAdmit = {
            entered.countDown()
            assertTrue(release.await(10, TimeUnit.SECONDS))
        }
        val executor = Executors.newSingleThreadExecutor()
        try {
            val running = executor.submit<CloudTaskPassReport> { coordinator.runPass() }
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            val pulls = cloud.count("GET", "/v1/phone/tasks/pull")
            assertEquals(CloudTaskPassStatus.BUSY, coordinator.runPass().status)
            assertEquals(CloudTaskPassStatus.BUSY, coordinator.runPass().status)
            assertEquals("a busy call sends nothing", pulls, cloud.count("GET", "/v1/phone/tasks/pull"))
            journal.onAdmit = {}
            release.countDown()
            val report = running.get(10, TimeUnit.SECONDS)
            assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
            assertEquals(1, journal.requests.size)
            // First run: the pull with work and the empty one; the extra round: one more empty pull.
            assertEquals(pulls + 2, cloud.count("GET", "/v1/phone/tasks/pull"))
            assertEquals(CloudTaskPassStatus.COMPLETED, coordinator.runPass().status)
        } finally {
            release.countDown()
            executor.shutdownNow()
        }
    }
}
