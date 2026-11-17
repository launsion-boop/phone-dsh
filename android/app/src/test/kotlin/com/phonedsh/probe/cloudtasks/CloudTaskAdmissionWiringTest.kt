// SPDX-License-Identifier: MIT
// phone-dsh — :app tests: phone task queue ↔ external admission journal.
//
// spec/v1/cloud-tasks.md §7 on the app side, with the REAL `ExternalAdmissionJournal`
// (real files under a temporary root), the REAL `CloudTaskCoordinator` and client,
// the real `OutboxAdmissionDispatcher` and send outbox, and a local cloud that
// seals each task to the key this phone registered. What is checked is what the
// cloud was told and what the journal durably holds — never a stand-in journal.
package com.phonedsh.probe.cloudtasks

import com.phonedsh.cloudtasks.CloudTaskIdentity
import com.phonedsh.cloudtasks.CloudTaskPassStatus
import com.phonedsh.cloudtasks.CloudTaskTarget
import com.phonedsh.cloudtasks.CloudTaskTargetKind
import com.phonedsh.cloudtasks.InMemoryCloudTaskKeyStore
import com.phonedsh.cloudtasks.InMemoryCloudTaskPreferences
import com.phonedsh.gateway.JsonValue
import com.phonedsh.probe.admission.AdmissionPolicy
import com.phonedsh.probe.admission.AdmissionSource
import com.phonedsh.probe.admission.AdmissionSourceKind
import com.phonedsh.probe.admission.AdmissionSpec
import com.phonedsh.probe.admission.AdmissionStage
import com.phonedsh.probe.admission.AdmissionTarget
import com.phonedsh.probe.admission.ExternalAdmissionJournal
import com.phonedsh.probe.admission.OutboxAdmissionDispatcher
import com.phonedsh.probe.admission.TestClock
import com.phonedsh.probe.outbox.SendOutbox
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CloudTaskAdmissionWiringTest {
    private val clock = TestClock()
    private val cloud = TestCloud(clock.now)
    private val tokens = TestTokens()
    private val preferences = InMemoryCloudTaskPreferences().apply {
        putString(CloudTaskIdentity.DEVICE_ID_KEY, TEST_DEVICE_ID)
        putBoolean(CloudTaskIdentity.ENABLED_KEY, true)
    }
    private val keys = InMemoryCloudTaskKeyStore()
    private lateinit var root: File
    private var journal: ExternalAdmissionJournal? = null
    private var account: CloudTaskAccount = CloudTaskAccount.SignedIn("u-1")
    private val presence = HashMap<AdmissionTarget, CloudTaskTargetPresence>()
    private var admittedSignals = 0

    private val session = AdmissionTarget.DshSession("gb-main")
    private val source = AdmissionSource(AdmissionSourceKind.CLOUD_TASK, TEST_DEVICE_ID)
    private val uuidV4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")

    @Before
    fun setUp() {
        root = Files.createTempDirectory("cloud-task-wiring").toFile()
        journal = ExternalAdmissionJournal(root, nowMs = clock)
        presence[session] = CloudTaskTargetPresence.PRESENT
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    /** A new service is a new process: nothing in memory, the same stores, journal and cloud. */
    private fun service() = CloudTaskService(
        transport = cloud,
        tokens = tokens,
        preferences = preferences,
        keys = keys,
        journal = { journal },
        account = { account },
        presence = { presence[it] ?: CloudTaskTargetPresence.UNKNOWN },
        onAdmitted = { admittedSignals++ },
        appVersion = "1.4.0",
        clock = clock,
        sleepSeconds = {},
    )

    private fun registered(): CloudTaskService = service().also {
        assertEquals(CloudTaskPassStatus.COMPLETED, it.runPass().status)
    }

    private fun advance(ms: Long) {
        clock.now += ms
        cloud.now += ms
    }

    private fun admissionId(taskId: String, userId: String = "u-1") =
        AdmissionPolicy.admissionId("account:$userId", source, taskId)

    private fun records() = journal!!.records()

    // ---- pull → admit → ack

    @Test
    fun aPulledTaskIsAdmittedWithTheContractsIdentityAndAckedWithTheJournalsAdmissionId() {
        val service = registered()
        val task = cloud.submit("t-1", text = "整理今天的会议纪要")

        val report = service.runPass()

        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        val record = records().single()
        assertEquals("account:u-1", record.principal)
        assertEquals(source, record.source)
        assertEquals("t-1", record.sourceRequestId)
        assertEquals(session, record.target)
        assertEquals("整理今天的会议纪要", record.text)
        assertEquals(task.expiresAtMs, record.expiresAtMs)
        assertEquals(AdmissionStage.ADMITTED, record.stage)
        assertTrue("downstreamId is a lowercase UUIDv4", uuidV4.matches(record.downstreamId))
        assertEquals(admissionId("t-1"), record.admissionId)

        assertEquals("admitted", task.state)
        assertEquals("the ack carries the journal's admission id", record.admissionId, task.admissionId)
        assertEquals(listOf(record.admissionId), report.admittedIds)
        assertEquals("the dispatch entry is nudged once", 1, admittedSignals)
        assertEquals(CloudTaskStatusText.ON, service.facts.value.status)
    }

    @Test
    fun theRegistrationIsAndroidWithNoPush() {
        registered()
        val body = cloud.devices.getValue(TEST_DEVICE_ID).body
        assertEquals("android", body.string("platform"))
        assertEquals(JsonValue.Null, body.get("push"))
    }

    @Test
    fun aRedeliveryIsADuplicateAndAcksTheSameAdmissionId() {
        val service = registered()
        val task = cloud.submit("t-1")
        // The journal write lands, the ack is lost: the cloud still holds the task `pending`.
        cloud.loseRequestOnce += "POST /v1/phone/tasks/ack"
        assertEquals(CloudTaskPassStatus.UNREACHABLE, service.runPass().status)
        assertEquals("pending", task.state)
        val first = records().single()
        assertEquals(1, admittedSignals)

        advance(301_000)
        val report = service.runPass()

        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals("nothing new was admitted", emptyList<String>(), report.admittedIds)
        assertEquals(1, admittedSignals)
        val again = records().single()
        assertEquals(first.admissionId, again.admissionId)
        assertEquals("a duplicate keeps the record's own downstreamId", first.downstreamId, again.downstreamId)
        assertEquals("admitted", task.state)
        assertEquals(first.admissionId, task.admissionId)
    }

    @Test
    fun aFullJournalAdmitsNothingAndSendsNoAck() {
        val service = registered()
        repeat(AdmissionPolicy.MAX_PENDING) { index ->
            journal!!.admit(AdmissionSpec.request(requestId = "fill-$index", downstreamId = AdmissionSpec.uuid(index)))
        }
        val task = cloud.submit("t-1")

        val report = service.runPass()

        assertEquals(1, report.deferred)
        assertEquals(emptyList<JsonValue.Obj>(), cloud.acks())
        assertEquals("pending", task.state)
        assertNull(journal!!.record(admissionId("t-1")))
        assertEquals(0, admittedSignals)

        // The lease expires and the cloud redelivers; with room the task is admitted.
        records().take(1).forEach { journal!!.cancel(it.admissionId) }
        advance(301_000)
        service.runPass()
        assertEquals("admitted", task.state)
    }

    @Test
    fun anUnopenableJournalAdmitsNothingAndSendsNoAck() {
        val service = registered()
        val task = cloud.submit("t-1")
        val held = journal
        journal = null

        assertEquals(1, service.runPass().deferred)
        assertEquals(emptyList<JsonValue.Obj>(), cloud.acks())
        assertEquals("pending", task.state)
        assertEquals(0, held!!.records().size)
    }

    // ---- target presence

    @Test
    fun anUnknownTargetIsNeitherAdmittedNorAckedAndIsRedelivered() {
        val service = registered()
        val target = CloudTaskTarget(CloudTaskTargetKind.DSH_SESSION, "not-loaded-yet")
        val task = cloud.submit("t-1", target = target)

        val report = service.runPass()

        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertEquals(1, report.deferred)
        assertEquals("no ack of any kind", emptyList<JsonValue.Obj>(), cloud.acks())
        assertEquals("pending", task.state)
        assertEquals(0, records().size)

        // Once the app can tell, the redelivered task is admitted.
        presence[AdmissionTarget.DshSession("not-loaded-yet")] = CloudTaskTargetPresence.PRESENT
        advance(301_000)
        service.runPass()
        assertEquals("admitted", task.state)
        assertEquals(AdmissionTarget.DshSession("not-loaded-yet"), records().single().target)
    }

    @Test
    fun anAbsentTargetIsRejectedTargetMissing() {
        val service = registered()
        presence[AdmissionTarget.Bot("bot-gone")] = CloudTaskTargetPresence.ABSENT
        val task = cloud.submit("t-1", target = CloudTaskTarget(CloudTaskTargetKind.BOT, "bot-gone"))

        service.runPass()

        assertEquals("rejected", task.state)
        assertEquals("target_missing", task.reason)
        assertEquals(0, records().size)
        assertEquals(0, admittedSignals)
    }

    @Test
    fun aBotTargetMapsToTheBotId() {
        val service = registered()
        presence[AdmissionTarget.Bot("bot-1")] = CloudTaskTargetPresence.PRESENT
        cloud.submit("t-1", target = CloudTaskTarget(CloudTaskTargetKind.BOT, "bot-1"))

        service.runPass()

        assertEquals(AdmissionTarget.Bot("bot-1"), records().single().target)
    }

    @Test
    fun theSessionRuleOnlyCallsAnAuthoritativeMissAbsent() {
        assertEquals(CloudTaskTargetPresence.PRESENT, CloudTaskPresenceRule.session(known = true, listed = null))
        assertEquals(CloudTaskTargetPresence.PRESENT, CloudTaskPresenceRule.session(known = true, listed = true))
        assertEquals(CloudTaskTargetPresence.UNKNOWN, CloudTaskPresenceRule.session(known = false, listed = null))
        assertEquals(CloudTaskTargetPresence.UNKNOWN, CloudTaskPresenceRule.session(known = false, listed = true))
        assertEquals(CloudTaskTargetPresence.ABSENT, CloudTaskPresenceRule.session(known = false, listed = false))
        assertEquals(CloudTaskTargetPresence.ABSENT, CloudTaskPresenceRule.session(known = true, listed = false))
    }

    // ---- terminal acks

    private fun admitted(service: CloudTaskService, taskId: String): String {
        cloud.submit(taskId)
        service.runPass()
        assertEquals("admitted", cloud.task(taskId).state)
        return admissionId(taskId)
    }

    private fun link(admissionId: String) {
        journal!!.markDispatching(admissionId)
        journal!!.markLinked(admissionId)
    }

    @Test
    fun aCompletedRecordIsReportedCompletedOnceAndOfferedOnceMoreByANewProcess() {
        val service = registered()
        val id = admitted(service, "t-1")
        link(id)
        val beforeLinked = cloud.acks().size
        service.runPass()
        assertEquals("a linked record is not reported", beforeLinked, cloud.acks().size)
        journal!!.complete(id)

        val report = service.runPass()

        assertEquals(1, report.terminalsSettled)
        assertEquals("completed", cloud.task("t-1").state)
        val sent = cloud.acks().size
        service.runPass()
        assertEquals("settled in this process: not sent again", sent, cloud.acks().size)

        // Nothing was persisted about "settled": a new process offers the record once more.
        val next = service()
        next.runPass()
        assertEquals(sent + 1, cloud.acks().size)
        assertEquals("completed", cloud.acks().last().string("state"))
        assertEquals("completed", cloud.task("t-1").state)
        next.runPass()
        assertEquals(sent + 1, cloud.acks().size)
    }

    @Test
    fun aFailedRecordIsReportedWithTheMappedReasonAndAnExpiredOneAsFailedExpired() {
        val service = registered()
        val failed = admitted(service, "t-1")
        admitted(service, "t-2")
        link(failed)
        journal!!.fail(failed, "turn_failed")
        // t-2 is never dispatched: the journal's own sweep expires it.
        advance(3_600_001)

        service.runPass()

        assertEquals("failed", cloud.task("t-1").state)
        assertEquals("run_failed", cloud.task("t-1").reason)
        assertEquals("failed", cloud.task("t-2").state)
        assertEquals("expired", cloud.task("t-2").reason)
    }

    @Test
    fun anotherAccountsTerminalRecordsAreNotOfferedToThisAccountsSession() {
        val service = registered()
        val id = admitted(service, "t-1")
        link(id)
        journal!!.complete(id)
        account = CloudTaskAccount.SignedIn("u-2")
        val sent = cloud.acks().size

        service.runPass()

        assertEquals(sent, cloud.acks().size)
        assertEquals("admitted", cloud.task("t-1").state)
    }

    // ---- the account

    @Test
    fun signedOutNothingIsSentAndNothingIsAdmitted() {
        val service = registered()
        cloud.submit("t-1")
        account = CloudTaskAccount.SignedOut
        tokens.token = null
        val requests = cloud.seen.size

        val report = service.runPass()

        assertEquals(CloudTaskPassStatus.NO_CREDENTIAL, report.status)
        assertEquals(requests, cloud.seen.size)
        assertEquals(0, records().size)
        assertEquals(CloudTaskStatusText.SIGNED_OUT, service.facts.value.status)
        assertNull(service.signedInAccountId())
    }

    @Test
    fun withoutAReadableUserIdATaskIsNeitherAdmittedNorAcked() {
        val service = registered()
        val task = cloud.submit("t-1")
        // The token works but the session record cannot be read now.
        account = CloudTaskAccount.Unknown

        val report = service.runPass()

        assertEquals(1, report.deferred)
        assertEquals(emptyList<JsonValue.Obj>(), cloud.acks())
        assertEquals("pending", task.state)
        assertEquals(0, records().size)
    }

    @Test
    fun aUserIdThatCannotBeAPrincipalAdmitsNothingAndRejectsNothing() {
        val service = registered()
        val task = cloud.submit("t-1")
        account = CloudTaskAccount.SignedIn("user id with spaces")

        service.runPass()

        assertEquals(emptyList<JsonValue.Obj>(), cloud.acks())
        assertEquals("pending", task.state)
        assertEquals(0, records().size)
    }

    @Test
    fun signOutDeletesTheRegistrationWhileTheTokenWorksThenCancelsThatAccountsAdmittedRecords() {
        val service = registered()
        val waiting = admitted(service, "t-1")
        val linked = admitted(service, "t-2")
        link(linked)
        val pending = cloud.submit("t-3")

        // Before the session is cleared.
        service.accountWillSignOut()
        val delete = cloud.seen.last()
        assertEquals("DELETE", delete.method)
        assertEquals("/v1/phone/devices/$TEST_DEVICE_ID", delete.path)
        assertEquals("the still-valid token carried it", "Bearer tok-1", delete.authorization)
        assertFalse(cloud.devices.containsKey(TEST_DEVICE_ID))
        assertEquals("the cloud cancels what was still pending", "cancelled", pending.state)
        assertEquals("nothing is cancelled locally before the session is cleared",
            AdmissionStage.ADMITTED, journal!!.record(waiting)!!.stage)

        // The session is cleared.
        tokens.token = null
        account = CloudTaskAccount.SignedOut
        val cancelled = service.accountDidSignOut()

        assertEquals(listOf(waiting), cancelled.map { it.admissionId })
        val record = journal!!.record(waiting)!!
        assertEquals(AdmissionStage.CANCELLED, record.stage)
        assertEquals("account_signed_out", record.reason)
        assertNull("the text leaves with the pending stage", record.text)
        assertEquals("a record past `admitted` keeps its stage", AdmissionStage.LINKED, journal!!.record(linked)!!.stage)
        assertEquals(CloudTaskStatusText.SIGNED_OUT, service.facts.value.status)
    }

    @Test
    fun aRecordCancelledBySignOutIsReportedFailedCancelledWhenTheSameAccountSignsInAgain() {
        val service = registered()
        admitted(service, "t-1")
        service.accountWillSignOut()
        tokens.token = null
        account = CloudTaskAccount.SignedOut
        service.accountDidSignOut()

        tokens.token = "tok-1"
        account = CloudTaskAccount.SignedIn("u-1")
        val report = service.accountDidSignIn()

        assertEquals(CloudTaskPassStatus.COMPLETED, report.status)
        assertTrue("registered again", cloud.devices.containsKey(TEST_DEVICE_ID))
        assertEquals("failed", cloud.task("t-1").state)
        assertEquals("cancelled", cloud.task("t-1").reason)
    }

    @Test
    fun aSignInOfAnotherAccountCancelsThePreviousAccountsAdmittedRecords() {
        val service = registered()
        val id = admitted(service, "t-1")
        account = CloudTaskAccount.SignedIn("u-2")

        service.accountDidSignIn()

        assertEquals(AdmissionStage.CANCELLED, journal!!.record(id)!!.stage)
    }

    @Test
    fun whileTheAccountCannotBeReadNothingIsCancelled() {
        val service = registered()
        val id = admitted(service, "t-1")
        account = CloudTaskAccount.Unknown

        assertEquals(0, service.accountDidSignOut().size)
        service.reconcileAccount()

        assertEquals(AdmissionStage.ADMITTED, journal!!.record(id)!!.stage)
    }

    // ---- dispatch: an admitted task is an ordinary request in the send outbox

    @Test
    fun theDispatcherHandsAnAdmittedTaskToTheOutboxOnlyForTheSignedInAccount() {
        val service = registered()
        val id = admitted(service, "t-1")
        val outbox = SendOutbox(root, nowMs = clock)
        val dispatcher = OutboxAdmissionDispatcher(outbox, { it == "gb-main" }, service::signedInAccountId)

        // Signed out (or unreadable): the record only waits; nothing changes.
        account = CloudTaskAccount.Unknown
        assertEquals(listOf(id), journal!!.runDispatchPass(dispatcher).waiting)
        assertEquals(AdmissionStage.ADMITTED, journal!!.record(id)!!.stage)

        account = CloudTaskAccount.SignedIn("u-1")
        val report = journal!!.runDispatchPass(dispatcher)

        assertEquals(listOf(id), report.linked)
        val record = journal!!.record(id)!!
        val entry = outbox.entry(record.downstreamId)!!
        assertEquals("gb-main", entry.sessionId)
        assertEquals("整理今天的会议纪要", entry.text)
        // `linked` is never reported to the cloud (§6).
        val sent = cloud.acks().size
        service.runPass()
        assertEquals(sent, cloud.acks().size)
    }

    @Test
    fun theDispatcherCancelsARecordOfAnAccountThatIsNoLongerTheSignedInOne() {
        val service = registered()
        val id = admitted(service, "t-1")
        account = CloudTaskAccount.SignedIn("u-2")
        val dispatcher = OutboxAdmissionDispatcher(SendOutbox(root, nowMs = clock), { true }, service::signedInAccountId)

        assertEquals(listOf(id), journal!!.runDispatchPass(dispatcher).cancelled)
    }

    // ---- the switch and its status line

    @Test
    fun theFeatureIsOffByDefaultAndSendsNothing() {
        val fresh = InMemoryCloudTaskPreferences()
        val service = CloudTaskService(cloud, tokens, fresh, keys, { journal }, { account }, { CloudTaskTargetPresence.UNKNOWN },
            {}, "1.4.0", clock, {})

        assertEquals(CloudTaskUiFacts(enabled = false, status = CloudTaskStatusText.OFF), service.facts.value)
        assertEquals(CloudTaskPassStatus.DISABLED, service.runPass().status)
        assertEquals(0, cloud.seen.size)
        assertNull("no device id is minted while off", fresh.string(CloudTaskIdentity.DEVICE_ID_KEY))
        service.accountWillSignOut()
        assertEquals("nothing is sent at sign-out while off", 0, cloud.seen.size)
    }

    @Test
    fun turningTheSwitchOnRegistersAndPullsAndTurningItOffDeletesTheRegistration() {
        val fresh = InMemoryCloudTaskPreferences()
        val service = CloudTaskService(cloud, tokens, fresh, keys, { journal }, { account }, { CloudTaskTargetPresence.UNKNOWN },
            {}, "1.4.0", clock, {})

        service.setEnabled(true)

        assertEquals(true, fresh.boolean(CloudTaskIdentity.ENABLED_KEY))
        val deviceId = fresh.string(CloudTaskIdentity.DEVICE_ID_KEY)!!
        assertTrue(cloud.devices.containsKey(deviceId))
        assertEquals(1, cloud.count("GET", "/v1/phone/tasks/pull"))
        assertEquals(CloudTaskUiFacts(enabled = true, status = CloudTaskStatusText.ON), service.facts.value)

        service.setEnabled(false)

        assertEquals(false, fresh.boolean(CloudTaskIdentity.ENABLED_KEY))
        assertFalse(cloud.devices.containsKey(deviceId))
        assertEquals(CloudTaskUiFacts(enabled = false, status = CloudTaskStatusText.OFF), service.facts.value)
        val requests = cloud.seen.size
        assertEquals(CloudTaskPassStatus.DISABLED, service.runPass().status)
        assertEquals(requests, cloud.seen.size)
    }

    @Test
    fun aSwitchOffWhoseDeleteDidNotLandSaysSoAndRepeatsTheDeleteOnTheNextTrigger() {
        val service = registered()
        cloud.loseRequestOnce += "DELETE /v1/phone/devices/$TEST_DEVICE_ID"

        service.setEnabled(false)

        assertEquals(CloudTaskStatusText.TURNED_OFF_PENDING, service.facts.value.status)
        assertTrue(cloud.devices.containsKey(TEST_DEVICE_ID))

        assertEquals(CloudTaskPassStatus.DISABLED, service.runPass().status)

        assertFalse(cloud.devices.containsKey(TEST_DEVICE_ID))
        assertEquals(CloudTaskStatusText.OFF, service.facts.value.status)
        assertEquals("only the DELETE was repeated", "DELETE", cloud.seen.last().method)
    }

    @Test
    fun theStatusLineNamesWhyNothingIsReceived() {
        cloud.routesPresent = false
        val service = service()
        assertEquals(CloudTaskStatusText.ON_NOT_CHECKED, service.facts.value.status)
        service.runPass()
        assertEquals(CloudTaskStatusText.UNAVAILABLE, service.facts.value.status)

        cloud.routesPresent = true
        cloud.refuseRegistration = "device_limit"
        service().also { it.runPass() }.let { assertEquals(CloudTaskStatusText.DEVICE_LIMIT, it.facts.value.status) }

        cloud.refuseRegistration = null
        keys.locked = true
        service().also { it.runPass() }.let { assertEquals(CloudTaskStatusText.STORE_UNAVAILABLE, it.facts.value.status) }

        keys.locked = false
        cloud.loseRequestOnce += "GET /v1/phone/devices"
        service().also { it.runPass() }.let { assertEquals(CloudTaskStatusText.FAILED, it.facts.value.status) }
        assertNotEquals(CloudTaskStatusText.ON, CloudTaskStatusText.FAILED)
    }

    @Test
    fun aLockedKeyStoreLeavesAPulledTaskWithoutAnAck() {
        val service = registered()
        val task = cloud.submit("t-1")
        keys.locked = true

        val report = service.runPass()

        assertEquals(1, report.deferred)
        assertEquals(emptyList<JsonValue.Obj>(), cloud.acks())
        assertEquals("pending", task.state)
    }
}
