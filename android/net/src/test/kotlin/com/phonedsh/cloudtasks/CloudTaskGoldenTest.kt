// SPDX-License-Identifier: MIT
// phone-dsh — :net tests: spec/v1/golden/cloud-tasks/cases.json on Android.
//
// The phone-side sections of the shared cases run through the real Kotlin
// code: `messages` through `CloudTaskWire.validateRequest` (the device and ack
// bodies the phone sends, and the submit bodies whose member rules the pull
// decoder shares), `aad` and `sealing` through `CloudTaskCrypto`, and `phone`
// through `CloudTaskCoordinator` with a local cloud; `pull_elements` through
// the pull decoder and the coordinator, `terminal` through the terminal-ack
// builder and the coordinator (revision cloud-tasks-v1.1). The `submit`, `acks`
// (state machine) and `pull` (clamping) sections judge the cloud and are not
// claimed here beyond the ack shapes.

package com.phonedsh.cloudtasks

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CloudTaskGoldenTest {
    private val cases: JsonValue.Obj by lazy { cloudTaskCases() }

    private fun rows(value: JsonValue.Obj, name: String): List<JsonValue.Obj> =
        requireNotNull(value.array(name)) { "$name is missing" }.map { it as JsonValue.Obj }

    @Test
    fun revisionAndConstants() {
        assertEquals(CloudTaskWire.REVISION, cases.string("revision"))
        val constants = cases.obj("constants")!!
        assertEquals(CloudTaskWire.SUITE, constants.string("suite"))
        assertEquals(CloudTaskWire.INFO, constants.string("info"))
        assertEquals(CloudTaskWire.MAX_TEXT_BYTES, constants.int("maxTextBytes"))
        assertEquals(CloudTaskWire.MAX_DEVICES, constants.int("maxDevices"))
    }

    @Test
    fun everyValidMessagePasses() {
        val schemas = HashSet<String>()
        for (row in rows(cases.obj("messages")!!, "valid")) {
            val message = row.get("message")!!
            try {
                CloudTaskWire.validateRequest(message)
            } catch (failure: CloudTaskWireException) {
                fail("${row.string("id")}: ${failure.message}")
            }
            schemas += (message as JsonValue.Obj).string("schema")!!
        }
        assertEquals(setOf("phone-device/v1", "phone-task-submit/v1", "phone-task-ack/v1"), schemas)
    }

    @Test
    fun everyInvalidMessageIsRefused() {
        val invalid = rows(cases.obj("messages")!!, "invalid")
        assertTrue("the golden's invalid messages", invalid.size >= 20)
        for (row in invalid) {
            try {
                CloudTaskWire.validateRequest(row.get("message")!!)
                fail("${row.string("id")} must be refused")
            } catch (_: CloudTaskWireException) {
                // expected
            }
        }
    }

    @Test
    fun theAndroidRegistrationBodyIsTheGoldenObject() {
        val golden = rows(cases.obj("messages")!!, "valid").first { it.string("id") == "device-android" }.obj("message")!!
        val key = golden.obj("key")!!
        val built = CloudTaskWire.deviceBody(
            golden.string("app_version")!!,
            CloudTaskPublicKey(key.string("key_id")!!, CloudTaskWire.base64UrlDecode(key.string("public_key")!!)),
        )
        assertArrayEquals(GatewayJson.canonicalBytes(golden), built)
        assertEquals(JsonValue.Null, (GatewayJson.parseOrNull(built) as JsonValue.Obj).get("push"))
    }

    @Test
    fun fcmRegistrationAndHintMatchTheSharedContract() {
        val golden = rows(cases.obj("messages")!!, "valid")
            .first { it.string("id") == "device-android-fcm" }.obj("message")!!
        val key = golden.obj("key")!!
        val token = golden.obj("push")!!.string("token")!!
        val built = CloudTaskWire.deviceBody(
            golden.string("app_version")!!,
            CloudTaskPublicKey(key.string("key_id")!!, CloudTaskWire.base64UrlDecode(key.string("public_key")!!)),
            token,
        )
        assertArrayEquals(GatewayJson.canonicalBytes(golden), built)
        val hint = cases.obj("constants")!!.obj("fcmData")!!
        val data = mapOf("pdsh_v" to hint.string("pdsh_v")!!, "pdsh_kind" to hint.string("pdsh_kind")!!)
        assertTrue(CloudTaskWire.isTaskPush(data))
        assertFalse(CloudTaskWire.isTaskPush(data + ("pdsh_v" to "2")))
        assertFalse(CloudTaskWire.isTaskPush(data + ("task_id" to "must-not-be-in-push")))
    }

    @Test
    fun theAckBodyEncoderReproducesTheGoldenObject() {
        val golden = rows(cases.obj("messages")!!, "valid").first { it.string("id") == "ack-all-states" }.obj("message")!!
        val acks = golden.array("acks")!!.map(CloudTaskWire::decodeAck)
        assertEquals(6, acks.map { it::class }.toSet().size)
        assertArrayEquals(
            GatewayJson.canonicalBytes(golden),
            CloudTaskWire.ackBody(golden.string("device_id")!!, acks),
        )
    }

    @Test
    fun everyStateMachineAckIsAnAckOfTheContract() {
        for (row in rows(cases, "acks")) {
            val ack = CloudTaskWire.decodeAck(row.get("ack")!!)
            assertTrue(
                row.string("id"),
                GatewayJson.structuralEquals(row.get("ack")!!, CloudTaskWire.ackValue(ack)),
            )
        }
    }

    @Test
    fun everyAadRow() {
        val aad = rows(cases, "aad")
        assertEquals(3, aad.size)
        for (row in aad) {
            val target = row.obj("target")!!
            val built = CloudTaskCrypto.aad(
                row.string("device_id")!!,
                row.string("key_id")!!,
                row.string("request_id")!!,
                CloudTaskTarget(CloudTaskTargetKind.of(target.string("kind")!!)!!, target.string("id")!!),
                long(row, "expires_at_ms"),
            )
            assertEquals(row.string("aad"), String(built, StandardCharsets.UTF_8))
        }
    }

    @Test
    fun everySealingVectorIsReproducedAndOpened() {
        val vectors = rows(cases.obj("sealing")!!, "valid")
        assertTrue(vectors.size >= 3)
        for (row in vectors) {
            val id = row.string("id")
            val recipient = CloudTaskCrypto.keyPairFromScalar(hex(row.string("recipient_private_scalar")!!))
            assertEquals(id, row.string("recipient_public_key"), CloudTaskWire.base64UrlEncode(recipient.publicKey))
            val plaintext = row.string("plaintext")!!.toByteArray(StandardCharsets.UTF_8)
            val aad = row.string("aad")!!.toByteArray(StandardCharsets.UTF_8)
            val golden = row.obj("sealed")!!

            val sealed = CloudTaskCrypto.seal(
                recipient.publicKey,
                plaintext,
                aad,
                CloudTaskCrypto.keyPairFromScalar(hex(row.string("ephemeral_private_scalar")!!)),
            )
            assertEquals(id, golden.string("enc"), CloudTaskWire.base64UrlEncode(sealed.enc))
            assertEquals(id, golden.string("ct"), CloudTaskWire.base64UrlEncode(sealed.ct))

            val opened = CloudTaskCrypto.open(
                recipient,
                CloudTaskSealed(
                    CloudTaskWire.base64UrlDecode(golden.string("enc")!!),
                    CloudTaskWire.base64UrlDecode(golden.string("ct")!!),
                ),
                aad,
            )
            assertArrayEquals(id, plaintext, opened)
        }
    }

    @Test
    fun everyInvalidSealingVectorIsRejected() {
        val vectors = rows(cases.obj("sealing")!!, "invalid")
        assertTrue(vectors.size >= 4)
        for (row in vectors) {
            val sealed = row.obj("sealed")!!
            try {
                CloudTaskCrypto.open(
                    CloudTaskCrypto.keyPairFromScalar(hex(row.string("recipient_private_scalar")!!)),
                    CloudTaskSealed(
                        CloudTaskWire.base64UrlDecode(sealed.string("enc")!!),
                        CloudTaskWire.base64UrlDecode(sealed.string("ct")!!),
                    ),
                    row.string("aad")!!.toByteArray(StandardCharsets.UTF_8),
                )
                fail("${row.string("id")} must not open")
            } catch (_: CloudTaskOpenException) {
                // expected
            }
        }
    }

    @Test
    fun aFreshKeyPairSealsAndOpens() {
        val recipient = CloudTaskCrypto.generateKeyPair()
        assertEquals(65, recipient.publicKey.size)
        assertEquals(32, recipient.privateScalar.size)
        assertArrayEquals(recipient.publicKey, CloudTaskCrypto.keyPairFromScalar(recipient.privateScalar).publicKey)
        val aad = "aad".toByteArray()
        val sealed = CloudTaskCrypto.seal(recipient.publicKey, "任务".toByteArray(), aad)
        assertEquals("任务", String(CloudTaskCrypto.open(recipient, sealed, aad), StandardCharsets.UTF_8))
        val record = CloudTaskKeyRecord("k-1", recipient, 7)
        val decoded = CloudTaskIdentity.decodeRecord("k-1", CloudTaskIdentity.encodeRecord(record))
        assertNotNull(decoded)
        assertArrayEquals(recipient.privateScalar, decoded!!.pair.privateScalar)
        assertEquals(null, CloudTaskIdentity.decodeRecord("k-2", CloudTaskIdentity.encodeRecord(record)))
    }

    private fun enabledCoordinator(cloud: FakeCloud, now: Long, terminals: CloudTaskTerminalSource): CloudTaskCoordinator {
        val preferences = InMemoryCloudTaskPreferences()
        preferences.putString(CloudTaskIdentity.DEVICE_ID_KEY, DEVICE_ID)
        preferences.putBoolean(CloudTaskIdentity.ENABLED_KEY, true)
        return CloudTaskCoordinator(
            client = CloudTaskClient(cloud, FakeTokens("tok-1")),
            preferences = preferences,
            keys = InMemoryCloudTaskKeyStore(),
            targets = { true },
            admitter = { error("no element of these cases reaches the journal") },
            terminals = terminals,
            appVersion = "1.4.0",
            clock = { now },
        )
    }

    /** Every `pull_elements` row through the real decoder, then through a pass that pulls it. */
    @Test
    fun everyPullElementCase() {
        val elements = rows(cases, "pull_elements")
        assertTrue(elements.size >= 13)
        val outcomes = HashSet<String>()
        for (row in elements) {
            val id = row.string("id")
            val element = row.get("element")!!
            val decoded = CloudTaskWire.decodePullElement(element)
            assertEquals(id, row.bool("decodes"), decoded is CloudTaskPullElement.Task)
            val expected = row.get("ack")

            val now = 1_794_700_000_000
            val cloud = FakeCloud(now)
            // A well-formed element sits next to it: one bad element must not fail the pull.
            val wellFormed = elements.first { it.string("id") == "well-formed" }.get("element") as JsonValue.Obj
            val neighbour = JsonValue.Obj(
                wellFormed.members.filter { it.name != "task_id" } + JsonValue.Member("task_id", JsonValue.Str("t-neighbour")),
            )
            cloud.rawPullOnce = listOf(element, neighbour)
            val report = enabledCoordinator(cloud, now, CloudTaskTerminalSource.None).runPass()
            assertEquals(id, CloudTaskPassStatus.COMPLETED, report.status)
            assertEquals(id, 2, report.pulled)
            val sent = cloud.acks().map { GatewayJson.canonicalText(it) }
            // This phone holds no key `k-1`, so a decoded element is answered `key_unknown` by §7.
            val neighbourAck = """{"reason":"key_unknown","state":"rejected","task_id":"t-neighbour"}"""
            when {
                row.bool("decodes") == true -> {
                    assertEquals(id, JsonValue.Null, expected)
                    assertEquals(id, listOf(neighbourAck.replace("t-neighbour", "t-1"), neighbourAck), sent)
                    assertEquals(id, 0, report.undecodable)
                    outcomes += "decodes"
                }
                expected == JsonValue.Null -> {
                    assertEquals("$id: skipped without an ack", listOf(neighbourAck), sent)
                    assertEquals(id, 1, report.undecodable)
                    outcomes += "skipped"
                }
                else -> {
                    expected as JsonValue.Obj
                    val taskId = (element as JsonValue.Obj).string("task_id")!!
                    val withTask = JsonValue.Obj(expected.members + JsonValue.Member("task_id", JsonValue.Str(taskId)))
                    assertEquals(id, listOf(GatewayJson.canonicalText(withTask), neighbourAck), sent)
                    assertEquals(id, 1, report.undecodable)
                    outcomes += "invalid"
                }
            }
        }
        assertEquals(setOf("decodes", "skipped", "invalid"), outcomes)
    }

    /** Every `terminal` row through the real builder, and as the ack a pass sends for such a record. */
    @Test
    fun everyTerminalCase() {
        val terminal = rows(cases, "terminal")
        assertTrue(terminal.size >= 12)
        val now = 1_794_700_000_000
        for ((index, row) in terminal.withIndex()) {
            val label = "${row.string("stage")}/${row.string("reason")}"
            val taskId = "t-$index"
            val expected = row.obj("ack")!!
            val withTask = JsonValue.Obj(expected.members + JsonValue.Member("task_id", JsonValue.Str(taskId)))
            val built = CloudTaskWire.terminalAck(taskId, row.string("stage")!!, row.string("reason"))
            assertNotNull(label, built)
            assertEquals(label, GatewayJson.canonicalText(withTask), GatewayJson.canonicalText(CloudTaskWire.ackValue(built!!)))

            val cloud = FakeCloud(now)
            val admissionId = "5f".repeat(32)
            val task = cloud.add(
                FakeCloud.Task(taskId, "req", "k-1", CloudTaskTarget(CloudTaskTargetKind.BOT, "b"), now + 60_000, CloudTaskSealed(ByteArray(65), ByteArray(17))),
            )
            task.state = "admitted"
            task.admissionId = admissionId
            val source = FakeTerminals()
            source.waiting += CloudTaskTerminal(taskId, admissionId, row.string("stage")!!, row.string("reason"))
            val report = enabledCoordinator(cloud, now, source).runPass()
            assertEquals(label, CloudTaskPassStatus.COMPLETED, report.status)
            assertEquals(label, listOf(GatewayJson.canonicalText(withTask)), cloud.acks().map { GatewayJson.canonicalText(it) })
            assertEquals(label, expected.string("state"), task.state)
            assertEquals("$label: no terminal record is left un-acked", 1, source.settled.size)
        }
        for (stage in listOf("admitted", "dispatching", "linked")) {
            assertEquals("a pending stage is not reported", null, CloudTaskWire.terminalAck("t", stage, null))
        }
    }

    /**
     * `sealing.not_text`: bytes that open (valid tag) but are not a task text.
     * The real `open` returns the listed bytes, the real `openText` refuses
     * them, and a pass that pulls such a task sends the listed ack.
     */
    @Test
    fun everyNotTextCase() {
        val notText = rows(cases.obj("sealing")!!, "not_text")
        assertTrue(notText.size >= 2)
        for (row in notText) {
            val id = row.string("id")
            val recipient = CloudTaskCrypto.keyPairFromScalar(hex(row.string("recipient_private_scalar")!!))
            val goldenSealed = row.obj("sealed")!!
            val sealed = CloudTaskSealed(
                CloudTaskWire.base64UrlDecode(goldenSealed.string("enc")!!),
                CloudTaskWire.base64UrlDecode(goldenSealed.string("ct")!!),
            )
            val aadText = row.string("aad")!!
            val aad = aadText.toByteArray(StandardCharsets.UTF_8)
            val expected = row.obj("ack")!!

            assertArrayEquals(id, hex(row.string("plaintext_hex")!!), CloudTaskCrypto.open(recipient, sealed, aad))
            try {
                CloudTaskCrypto.openText(recipient, sealed, aad)
                fail("$id is not a task text")
            } catch (_: CloudTaskOpenException) {
                assertEquals(id, """{"reason":"decrypt_failed","state":"rejected"}""", GatewayJson.canonicalText(expected))
            }

            // The task these bytes were sealed for, read back from the AAD lines.
            val lines = aadText.split("\n")
            assertEquals(7, lines.size)
            val deviceId = lines[1]
            val keyId = lines[2]
            val requestId = lines[3]
            val kind = lines[4]
            val targetId = lines[5]
            val expires = lines[6]
            val now = expires.toLong() - 3_600_000
            val cloud = FakeCloud(now)
            cloud.rawPullOnce = listOf(
                JsonValue.obj(
                    "task_id" to JsonValue.Str("t-1"),
                    "request_id" to JsonValue.Str(requestId),
                    "key_id" to JsonValue.Str(keyId),
                    "target" to JsonValue.obj("kind" to JsonValue.Str(kind), "id" to JsonValue.Str(targetId)),
                    "expires_at_ms" to JsonValue.num(expires.toLong()),
                    "created_at_ms" to JsonValue.num(now),
                    "sealed" to goldenSealed,
                    "lease" to JsonValue.obj(
                        "lease_id" to JsonValue.Str("l-1"),
                        "attempt" to JsonValue.num(1),
                        "expires_at_ms" to JsonValue.num(now + 300_000),
                    ),
                ),
            )
            val preferences = InMemoryCloudTaskPreferences()
            preferences.putString(CloudTaskIdentity.DEVICE_ID_KEY, deviceId)
            preferences.putBoolean(CloudTaskIdentity.ENABLED_KEY, true)
            val keys = InMemoryCloudTaskKeyStore()
            keys.save(keyId, CloudTaskIdentity.encodeRecord(CloudTaskKeyRecord(keyId, recipient, now)))
            val coordinator = CloudTaskCoordinator(
                client = CloudTaskClient(cloud, FakeTokens("tok-1")),
                preferences = preferences,
                keys = keys,
                targets = { true },
                admitter = { error("bytes that are not a task text never reach the journal") },
                appVersion = "1.4.0",
                clock = { now },
            )
            val report = coordinator.runPass()
            assertEquals(id, CloudTaskPassStatus.COMPLETED, report.status)
            val sent = cloud.acks().map { GatewayJson.canonicalText(it) }
            val withTask = JsonValue.Obj(expected.members + JsonValue.Member("task_id", JsonValue.Str("t-1")))
            assertEquals(id, listOf(GatewayJson.canonicalText(withTask)), sent)
            assertEquals(id, 0, report.undecodable)
        }
    }

    /** Every `phone` row: the real coordinator sends exactly the listed ack, or none. */
    @Test
    fun everyPhoneCaseYieldsTheListedAck() {
        val seenOutcomes = HashSet<String?>()
        val phone = rows(cases, "phone")
        assertEquals(12, phone.size)
        for (row in phone) {
            val id = row.string("id")
            val now = long(row, "now")
            val task = row.obj("task")!!
            val targetObject = task.obj("target")!!
            val target = CloudTaskTarget(CloudTaskTargetKind.of(targetObject.string("kind")!!)!!, targetObject.string("id")!!)
            val taskId = task.string("task_id")!!
            val keyId = task.string("key_id")!!
            val requestId = task.string("request_id")!!
            val expiresAtMs = long(task, "expires_at_ms")

            val keys = InMemoryCloudTaskKeyStore()
            val registered = CloudTaskKeyRecord("k-registered", CloudTaskCrypto.generateKeyPair(), now)
            keys.save(registered.keyId, CloudTaskIdentity.encodeRecord(registered))
            val taskKey = CloudTaskCrypto.generateKeyPair()
            if (row.bool("has_key") == true) {
                keys.save(keyId, CloudTaskIdentity.encodeRecord(CloudTaskKeyRecord(keyId, taskKey, now)))
            }
            // "opens": sealed with the §3 AAD of this very task; otherwise with another request id.
            val sealedFor = if (row.bool("opens") == true) requestId else "$requestId-other"
            val sealed = CloudTaskCrypto.seal(
                taskKey.publicKey,
                "golden task text".toByteArray(),
                CloudTaskCrypto.aad(DEVICE_ID, keyId, sealedFor, target, expiresAtMs),
            )

            // The cloud's task filter runs an hour early so it still hands out a task that is
            // expired at `now`; the answer's `server_time_ms` is the case's `now`.
            val cloud = FakeCloud(now = now - 3_600_000)
            cloud.reportedTime = now
            cloud.devices[DEVICE_ID] = FakeCloud.Device(
                registered.keyId, CloudTaskWire.base64UrlEncode(registered.pair.publicKey), "android", JsonValue.obj(),
            )
            cloud.add(FakeCloud.Task(taskId, requestId, keyId, target, expiresAtMs, sealed))

            val preferences = InMemoryCloudTaskPreferences()
            preferences.putString(CloudTaskIdentity.DEVICE_ID_KEY, DEVICE_ID)
            preferences.putBoolean(CloudTaskIdentity.ENABLED_KEY, true)
            val result = CloudTaskAdmissionResult.valueOf(row.string("admission")!!.uppercase())
            val admissionId = row.string("admission_id")!!
            val coordinator = CloudTaskCoordinator(
                client = CloudTaskClient(cloud, FakeTokens("tok-1")),
                preferences = preferences,
                keys = keys,
                targets = { row.bool("target_exists") == true },
                admitter = { CloudTaskAdmission(result, admissionId) },
                appVersion = "1.4.0",
                // The phone's own clock is a day off: "now" is the pull answer's server_time_ms.
                clock = { now + 86_400_000 },
            )
            val report = coordinator.runPass()
            assertEquals(id, CloudTaskPassStatus.COMPLETED, report.status)
            assertEquals(id, 1, report.pulled)

            val expected = row.get("ack")
            val sent = cloud.acks()
            if (expected == JsonValue.Null) {
                assertTrue("$id: no ack may be sent", sent.isEmpty())
                assertEquals(id, 1, report.deferred)
                seenOutcomes += null
            } else {
                expected as JsonValue.Obj
                val withTask = JsonValue.Obj(expected.members + JsonValue.Member("task_id", JsonValue.Str(taskId)))
                assertEquals("$id: exactly one ack", 1, sent.size)
                assertEquals(id, GatewayJson.canonicalText(withTask), GatewayJson.canonicalText(sent[0]))
                seenOutcomes += expected.string("reason") ?: expected.string("state")
            }
        }
        assertEquals(
            setOf(null, "admitted", "expired", "key_unknown", "decrypt_failed", "target_missing", "invalid", "conflict"),
            seenOutcomes,
        )
    }
}
