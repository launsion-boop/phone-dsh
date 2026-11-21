// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.cloudtasks: phone task queue wire rules.
//
// The pure half of spec/v1/cloud-tasks.md (revision cloud-tasks-v1.6) on the
// phone side: the closed request bodies the phone sends (phone-device/v1,
// phone-task-ack/v1), the open answers it reads (device ack, device list,
// pull, ack result, error body), the terminal-stage mapping of §7 and the
// shared id/limit rules. No I/O and no logging. The shared cases
// (spec/v1/golden/cloud-tasks/cases.json, sections `messages`, `aad`,
// `pull_elements`, `terminal`, `phone`) drive exactly these functions; the
// reference reader is spec/v1/tools/test_cloud_tasks.py.
//
// Request bodies are closed: an unknown member is refused. Answers are open
// (§1): unknown members are ignored at every level, and every named member is
// still required with its stated type — a missing one, a wrong type or an
// out-of-range value is a [CloudTaskWireException], never a default.

package com.phonedsh.cloudtasks

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.util.Base64

/** A body that is not a message of this contract. The text never holds task content. */
class CloudTaskWireException(message: String) : Exception(message)

enum class CloudTaskTargetKind(val wire: String) {
    DSH_SESSION("dsh-session"),
    BOT("bot"),
    ;

    companion object {
        fun of(wire: String): CloudTaskTargetKind? = entries.firstOrNull { it.wire == wire }
    }
}

data class CloudTaskTarget(val kind: CloudTaskTargetKind, val id: String)

/** §3 sealed value: the 65-byte encapsulated key and ciphertext ‖ tag. */
class CloudTaskSealed(val enc: ByteArray, val ct: ByteArray) {
    override fun toString(): String = "CloudTaskSealed(${ct.size} bytes)"
}

/** The public half of a registered key (§2). */
class CloudTaskPublicKey(val keyId: String, val publicKey: ByteArray) {
    override fun toString(): String = "CloudTaskPublicKey($keyId)"
}

class CloudTaskLease(val leaseId: String, val attempt: Long, val expiresAtMs: Long)

/** One pulled task (§5). `toString` prints no ciphertext. */
class CloudTaskPulled(
    val taskId: String,
    val requestId: String,
    val keyId: String,
    val target: CloudTaskTarget,
    val expiresAtMs: Long,
    val createdAtMs: Long,
    val sealed: CloudTaskSealed,
    val lease: CloudTaskLease,
) {
    override fun toString(): String = "CloudTaskPulled($taskId)"
}

/** One element of a pull answer's `tasks` (§5). */
sealed interface CloudTaskPullElement {
    class Task(val task: CloudTaskPulled) : CloudTaskPullElement

    /**
     * An element the phone cannot decode. [taskId] is its `task_id` when that is
     * a valid id (the phone acks it `rejected` / `invalid`), else `null` (skipped).
     */
    class Undecodable(val taskId: String?) : CloudTaskPullElement
}

class CloudTaskPullResponse(
    val elements: List<CloudTaskPullElement>,
    /** The cloud's clock for this answer: "now" of the §7 expiry check. `null` when the answer has none. */
    val serverTimeMs: Long?,
) {
    val tasks: List<CloudTaskPulled> get() = elements.mapNotNull { (it as? CloudTaskPullElement.Task)?.task }
}

class CloudTaskDeviceAck(val deviceId: String, val keyId: String, val serverTimeMs: Long)

class CloudTaskDeviceEntry(
    val deviceId: String,
    val platform: String,
    val key: CloudTaskPublicKey,
    val updatedAtMs: Long,
)

class CloudTaskDeviceList(val devices: List<CloudTaskDeviceEntry>, val serverTimeMs: Long)

/** §6 `rejected` reasons. */
enum class CloudTaskRejectReason(val wire: String) {
    INVALID("invalid"),
    CONFLICT("conflict"),
    TARGET_MISSING("target_missing"),
    DECRYPT_FAILED("decrypt_failed"),
    KEY_UNKNOWN("key_unknown"),
}

/** §6 `failed` reasons. */
enum class CloudTaskFailReason(val wire: String) {
    TARGET_MISSING("target_missing"),
    NOT_AUTHORIZED("not_authorized"),
    RETRY_EXHAUSTED("retry_exhausted"),
    RUN_FAILED("run_failed"),
    EXPIRED("expired"),
    CANCELLED("cancelled"),
}

/** One ack of §6; each case carries exactly the members the table lists. */
sealed interface CloudTaskAck {
    val taskId: String

    data class Admitted(override val taskId: String, val admissionId: String) : CloudTaskAck

    data class Rejected(override val taskId: String, val reason: CloudTaskRejectReason) : CloudTaskAck

    data class Expired(override val taskId: String) : CloudTaskAck

    data class Completed(override val taskId: String) : CloudTaskAck

    data class Failed(override val taskId: String, val reason: CloudTaskFailReason) : CloudTaskAck

    data class Unknown(override val taskId: String) : CloudTaskAck
}

/** The state a task has after an ack call, as the cloud reports it. */
enum class CloudTaskState(val wire: String) {
    PENDING("pending"),
    ADMITTED("admitted"),
    COMPLETED("completed"),
    FAILED("failed"),
    UNKNOWN("unknown"),
    REJECTED("rejected"),
    EXPIRED("expired"),
    CANCELLED("cancelled"),
    NOT_FOUND("not_found"),
    ;

    companion object {
        fun of(wire: String): CloudTaskState? = entries.firstOrNull { it.wire == wire }
    }
}

data class CloudTaskAckResult(
    val taskId: String,
    val accepted: Boolean,
    val duplicate: Boolean,
    val state: CloudTaskState,
)

class CloudTaskAckResponse(val results: List<CloudTaskAckResult>, val serverTimeMs: Long)

/** §1 error body; the phone acts on [code] and the HTTP status only. */
class CloudTaskErrorBody(val code: String, val message: String, val serverTimeMs: Long)

object CloudTaskWire {
    // v1.6 changes only the phone's behaviour after a push (host §10.2 wake lease); payload,
    // routes, ack and limits are byte-identical to v1.5. Not sent on the wire.
    const val REVISION: String = "cloud-tasks-v1.6"
    const val SUITE: String = "hpke-p256-sha256-aes128gcm"
    const val INFO: String = "pdsh-phone-task/v1"

    const val SCHEMA_DEVICE: String = "phone-device/v1"
    const val SCHEMA_DEVICE_ACK: String = "phone-device-ack/v1"
    const val SCHEMA_DEVICE_LIST: String = "phone-device-list/v1"
    const val SCHEMA_SUBMIT: String = "phone-task-submit/v1"
    const val SCHEMA_PULL: String = "phone-task-pull/v1"
    const val SCHEMA_ACK: String = "phone-task-ack/v1"
    const val SCHEMA_ACK_RESULT: String = "phone-task-ack-result/v1"

    const val PLATFORM_ANDROID: String = "android"
    const val MAX_TEXT_BYTES: Int = 16_384
    const val TAG_BYTES: Int = 16
    const val ENC_BYTES: Int = 65
    const val MAX_ACKS: Int = 16
    const val MAX_PULL: Int = 16
    const val MAX_DEVICES: Int = 8
    const val MIN_REMAINING_MS: Long = 1_000
    const val MAX_SAFE_INTEGER: Long = 9_007_199_254_740_991

    private val ID = Regex("^[A-Za-z0-9._:-]{1,128}$")
    private val DEVICE_ID = Regex("^dev-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private val HEX64 = Regex("^[0-9a-f]{64}$")
    private val PUSH_TOKEN = Regex("^[0-9a-f]{64,200}$")
    private val PUSH_TOPIC = Regex("^[A-Za-z0-9.-]{1,155}$")
    private val B64URL = Regex("^[A-Za-z0-9_-]+$")

    fun isOpaqueId(value: String): Boolean = ID.matches(value)

    fun isDeviceId(value: String): Boolean = DEVICE_ID.matches(value)

    fun isAdmissionId(value: String): Boolean = HEX64.matches(value)

    // ---- base64url without padding

    fun base64UrlEncode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    @Throws(CloudTaskWireException::class)
    fun base64UrlDecode(text: String): ByteArray {
        if (!B64URL.matches(text)) throw CloudTaskWireException("not base64url")
        return try {
            Base64.getUrlDecoder().decode(text)
        } catch (_: IllegalArgumentException) {
            throw CloudTaskWireException("not base64url")
        }
    }

    // ---- request bodies the phone sends

    /** §2 registration body for this platform: `platform: "android"`, `push: null`. */
    @Throws(CloudTaskWireException::class)
    fun deviceBody(appVersion: String, key: CloudTaskPublicKey): ByteArray {
        val body = JsonValue.obj(
            "schema" to JsonValue.Str(SCHEMA_DEVICE),
            "platform" to JsonValue.Str(PLATFORM_ANDROID),
            "app_version" to JsonValue.Str(appVersion),
            "key" to JsonValue.obj(
                "key_id" to JsonValue.Str(key.keyId),
                "suite" to JsonValue.Str(SUITE),
                "public_key" to JsonValue.Str(base64UrlEncode(key.publicKey)),
            ),
            "push" to JsonValue.Null,
        )
        validateRequest(body)
        return GatewayJson.canonicalBytes(body)
    }

    /** §5 ack body. Throws when the device id or an ack is not a value of the contract. */
    @Throws(CloudTaskWireException::class)
    fun ackBody(deviceId: String, acks: List<CloudTaskAck>): ByteArray {
        val body = JsonValue.obj(
            "schema" to JsonValue.Str(SCHEMA_ACK),
            "device_id" to JsonValue.Str(deviceId),
            "acks" to JsonValue.Arr(acks.map(::ackValue)),
        )
        validateRequest(body)
        return GatewayJson.canonicalBytes(body)
    }

    fun ackValue(ack: CloudTaskAck): JsonValue.Obj = when (ack) {
        is CloudTaskAck.Admitted -> JsonValue.obj(
            "task_id" to JsonValue.Str(ack.taskId),
            "state" to JsonValue.Str("admitted"),
            "admission_id" to JsonValue.Str(ack.admissionId),
        )
        is CloudTaskAck.Rejected -> JsonValue.obj(
            "task_id" to JsonValue.Str(ack.taskId),
            "state" to JsonValue.Str("rejected"),
            "reason" to JsonValue.Str(ack.reason.wire),
        )
        is CloudTaskAck.Failed -> JsonValue.obj(
            "task_id" to JsonValue.Str(ack.taskId),
            "state" to JsonValue.Str("failed"),
            "reason" to JsonValue.Str(ack.reason.wire),
        )
        is CloudTaskAck.Expired -> stateOnly(ack.taskId, "expired")
        is CloudTaskAck.Completed -> stateOnly(ack.taskId, "completed")
        is CloudTaskAck.Unknown -> stateOnly(ack.taskId, "unknown")
    }

    private fun stateOnly(taskId: String, state: String): JsonValue.Obj =
        JsonValue.obj("task_id" to JsonValue.Str(taskId), "state" to JsonValue.Str(state))

    /**
     * The contract's request-body check (the `messages` cases): throws unless
     * [message] is a valid `phone-device/v1`, `phone-task-submit/v1` or
     * `phone-task-ack/v1` body. The phone never sends a submit body; its rules
     * are here because the pull decoder shares them.
     */
    @Throws(CloudTaskWireException::class)
    fun validateRequest(message: JsonValue) {
        val root = message as? JsonValue.Obj ?: throw CloudTaskWireException("not an object")
        when ((root.get("schema") as? JsonValue.Str)?.value) {
            SCHEMA_DEVICE -> {
                closed(root, listOf("schema", "platform", "app_version", "key", "push"))
                val platform = string(root, "platform")
                if (platform != "ios" && platform != PLATFORM_ANDROID) throw CloudTaskWireException("platform")
                val version = string(root, "app_version")
                if (version.codePointCount(0, version.length) !in 1..32) throw CloudTaskWireException("app_version")
                publicKey(root.get("key"), open = false)
                val push = root.get("push")
                if (push != JsonValue.Null) {
                    val value = push as? JsonValue.Obj ?: throw CloudTaskWireException("push")
                    closed(value, listOf("provider", "environment", "topic", "token"))
                    if (string(value, "provider") != "apns" || platform != "ios") {
                        throw CloudTaskWireException("push provider")
                    }
                    val environment = string(value, "environment")
                    if (environment != "development" && environment != "production") {
                        throw CloudTaskWireException("push environment")
                    }
                    if (!PUSH_TOPIC.matches(string(value, "topic"))) throw CloudTaskWireException("push topic")
                    if (!PUSH_TOKEN.matches(string(value, "token"))) throw CloudTaskWireException("push token")
                }
            }
            SCHEMA_SUBMIT -> {
                closed(root, listOf("schema", "device_id", "request_id", "key_id", "target", "expires_at_ms", "sealed"))
                if (!isDeviceId(string(root, "device_id"))) throw CloudTaskWireException("device_id")
                id(root, "request_id")
                id(root, "key_id")
                target(root.get("target"), open = false)
                integer(root, "expires_at_ms")
                sealed(root.get("sealed"), open = false)
            }
            SCHEMA_ACK -> {
                closed(root, listOf("schema", "device_id", "acks"))
                if (!isDeviceId(string(root, "device_id"))) throw CloudTaskWireException("device_id")
                val acks = (root.get("acks") as? JsonValue.Arr)?.items ?: throw CloudTaskWireException("acks")
                if (acks.size !in 1..MAX_ACKS) throw CloudTaskWireException("acks")
                for (item in acks) decodeAck(item)
            }
            else -> throw CloudTaskWireException("unknown schema")
        }
    }

    /** One ack object of §6, closed per state. */
    @Throws(CloudTaskWireException::class)
    fun decodeAck(value: JsonValue): CloudTaskAck {
        val ack = value as? JsonValue.Obj ?: throw CloudTaskWireException("ack")
        return when ((ack.get("state") as? JsonValue.Str)?.value) {
            "admitted" -> {
                closed(ack, listOf("task_id", "state", "admission_id"))
                val admissionId = string(ack, "admission_id")
                if (!isAdmissionId(admissionId)) throw CloudTaskWireException("admission_id")
                CloudTaskAck.Admitted(id(ack, "task_id"), admissionId)
            }
            "rejected" -> {
                closed(ack, listOf("task_id", "state", "reason"))
                val wire = (ack.get("reason") as? JsonValue.Str)?.value
                val reason = CloudTaskRejectReason.entries.firstOrNull { it.wire == wire }
                    ?: throw CloudTaskWireException("reason")
                CloudTaskAck.Rejected(id(ack, "task_id"), reason)
            }
            "failed" -> {
                closed(ack, listOf("task_id", "state", "reason"))
                val wire = (ack.get("reason") as? JsonValue.Str)?.value
                val reason = CloudTaskFailReason.entries.firstOrNull { it.wire == wire }
                    ?: throw CloudTaskWireException("reason")
                CloudTaskAck.Failed(id(ack, "task_id"), reason)
            }
            "expired" -> {
                closed(ack, listOf("task_id", "state"))
                CloudTaskAck.Expired(id(ack, "task_id"))
            }
            "completed" -> {
                closed(ack, listOf("task_id", "state"))
                CloudTaskAck.Completed(id(ack, "task_id"))
            }
            "unknown" -> {
                closed(ack, listOf("task_id", "state"))
                CloudTaskAck.Unknown(id(ack, "task_id"))
            }
            else -> throw CloudTaskWireException("ack state")
        }
    }

    // ---- answers the phone reads

    @Throws(CloudTaskWireException::class)
    fun decodeDeviceAck(body: ByteArray): CloudTaskDeviceAck {
        val root = parse(body)
        schema(root, SCHEMA_DEVICE_ACK)
        val deviceId = string(root, "device_id")
        if (!isDeviceId(deviceId)) throw CloudTaskWireException("device_id")
        return CloudTaskDeviceAck(deviceId, id(root, "key_id"), integer(root, "server_time_ms"))
    }

    @Throws(CloudTaskWireException::class)
    fun decodeDeviceList(body: ByteArray): CloudTaskDeviceList {
        val root = parse(body)
        schema(root, SCHEMA_DEVICE_LIST)
        val items = (root.get("devices") as? JsonValue.Arr)?.items ?: throw CloudTaskWireException("devices")
        val devices = items.map { item ->
            val device = item as? JsonValue.Obj ?: throw CloudTaskWireException("device")
            CloudTaskDeviceEntry(
                id(device, "device_id"),
                string(device, "platform"),
                publicKey(device.get("key"), open = true),
                integer(device, "updated_at_ms"),
            )
        }
        return CloudTaskDeviceList(devices, integer(root, "server_time_ms"))
    }

    /**
     * §5 pull answer. One element that does not decode does not fail the
     * answer: it becomes [CloudTaskPullElement.Undecodable]. A repeated
     * `task_id` keeps its first element.
     */
    @Throws(CloudTaskWireException::class)
    fun decodePull(body: ByteArray): CloudTaskPullResponse {
        val root = parse(body)
        schema(root, SCHEMA_PULL)
        val items = (root.get("tasks") as? JsonValue.Arr)?.items ?: throw CloudTaskWireException("tasks")
        val seen = HashSet<String>()
        val elements = ArrayList<CloudTaskPullElement>()
        for (item in items) {
            val element = decodePullElement(item)
            val taskId = when (element) {
                is CloudTaskPullElement.Task -> element.task.taskId
                is CloudTaskPullElement.Undecodable -> element.taskId
            }
            if (taskId == null || seen.add(taskId)) elements += element
        }
        // Absent: the phone falls back to its own clock for the §7 check. Present: it must be an integer.
        val serverTimeMs = if (root.get("server_time_ms") == null) null else integer(root, "server_time_ms")
        return CloudTaskPullResponse(elements, serverTimeMs)
    }

    /** One `tasks` element (the `pull_elements` cases). Never throws. */
    fun decodePullElement(item: JsonValue): CloudTaskPullElement = try {
        val task = item as? JsonValue.Obj ?: throw CloudTaskWireException("task")
        val lease = task.get("lease") as? JsonValue.Obj ?: throw CloudTaskWireException("lease")
        CloudTaskPullElement.Task(
            CloudTaskPulled(
                taskId = id(task, "task_id"),
                requestId = id(task, "request_id"),
                keyId = id(task, "key_id"),
                target = target(task.get("target"), open = true),
                expiresAtMs = integer(task, "expires_at_ms"),
                createdAtMs = integer(task, "created_at_ms"),
                sealed = sealed(task.get("sealed"), open = true),
                lease = CloudTaskLease(
                    id(lease, "lease_id"),
                    integer(lease, "attempt", low = 1),
                    integer(lease, "expires_at_ms"),
                ),
            ),
        )
    } catch (_: CloudTaskWireException) {
        val taskId = ((item as? JsonValue.Obj)?.get("task_id") as? JsonValue.Str)?.value
        CloudTaskPullElement.Undecodable(taskId?.takeIf(::isOpaqueId))
    }

    /**
     * §7 terminal mapping, total over the terminal stages of an admission
     * record: `completed` → `completed`; `unknown` → `unknown`; `expired` →
     * `failed/expired`; `cancelled` → `failed/cancelled`; `failed` → `failed`
     * with [reason] when it is `target_missing`, `not_authorized` or
     * `retry_exhausted`, else `run_failed`. `null` for a stage that is not
     * terminal (nothing to report yet).
     */
    fun terminalAck(taskId: String, stage: String, reason: String?): CloudTaskAck? = when (stage) {
        "completed" -> CloudTaskAck.Completed(taskId)
        "unknown" -> CloudTaskAck.Unknown(taskId)
        "expired" -> CloudTaskAck.Failed(taskId, CloudTaskFailReason.EXPIRED)
        "cancelled" -> CloudTaskAck.Failed(taskId, CloudTaskFailReason.CANCELLED)
        "failed" -> CloudTaskAck.Failed(
            taskId,
            when (reason) {
                "target_missing" -> CloudTaskFailReason.TARGET_MISSING
                "not_authorized" -> CloudTaskFailReason.NOT_AUTHORIZED
                "retry_exhausted" -> CloudTaskFailReason.RETRY_EXHAUSTED
                else -> CloudTaskFailReason.RUN_FAILED
            },
        )
        else -> null
    }

    /** §5 ack answer; [sent] is the request's task ids, which the results must repeat in order. */
    @Throws(CloudTaskWireException::class)
    fun decodeAckResponse(body: ByteArray, sent: List<String>): CloudTaskAckResponse {
        val root = parse(body)
        schema(root, SCHEMA_ACK_RESULT)
        val items = (root.get("results") as? JsonValue.Arr)?.items ?: throw CloudTaskWireException("results")
        if (items.size != sent.size) throw CloudTaskWireException("results")
        val results = items.mapIndexed { index, item ->
            val result = item as? JsonValue.Obj ?: throw CloudTaskWireException("result")
            val taskId = id(result, "task_id")
            if (taskId != sent[index]) throw CloudTaskWireException("result order")
            val state = CloudTaskState.of(string(result, "state")) ?: throw CloudTaskWireException("state")
            CloudTaskAckResult(taskId, bool(result, "accepted"), bool(result, "duplicate"), state)
        }
        return CloudTaskAckResponse(results, integer(root, "server_time_ms"))
    }

    /** §1 error body, or null when [body] is not one (for example another server's 404 page). */
    fun decodeError(body: ByteArray): CloudTaskErrorBody? = try {
        val root = parse(body)
        val error = root.get("error") as? JsonValue.Obj ?: throw CloudTaskWireException("error")
        val code = string(error, "code")
        if (code.isEmpty()) throw CloudTaskWireException("code")
        CloudTaskErrorBody(code, string(error, "message"), integer(root, "server_time_ms"))
    } catch (_: CloudTaskWireException) {
        null
    }

    // ---- shared member rules

    private fun parse(body: ByteArray): JsonValue.Obj =
        GatewayJson.parseOrNull(body) as? JsonValue.Obj ?: throw CloudTaskWireException("not a JSON object")

    private fun schema(root: JsonValue.Obj, expected: String) {
        if (string(root, "schema") != expected) throw CloudTaskWireException("schema")
    }

    private fun closed(value: JsonValue.Obj, required: List<String>) {
        val names = value.members.map { it.name }
        if (names.size != required.size || names.toSet() != required.toSet()) {
            throw CloudTaskWireException("members")
        }
    }

    private fun string(value: JsonValue.Obj, name: String): String =
        (value.get(name) as? JsonValue.Str)?.value ?: throw CloudTaskWireException(name)

    private fun bool(value: JsonValue.Obj, name: String): Boolean =
        (value.get(name) as? JsonValue.Bool)?.value ?: throw CloudTaskWireException(name)

    private fun id(value: JsonValue.Obj, name: String): String {
        val text = string(value, name)
        if (!isOpaqueId(text)) throw CloudTaskWireException(name)
        return text
    }

    /** A JSON integer literal (no fraction, no exponent) in `low … 2^53 − 1`. */
    private fun integer(value: JsonValue.Obj, name: String, low: Long = 0): Long {
        val literal = (value.get(name) as? JsonValue.Num)?.literal ?: throw CloudTaskWireException(name)
        if (literal.any { it == '.' || it == 'e' || it == 'E' }) throw CloudTaskWireException(name)
        val number = literal.toLongOrNull() ?: throw CloudTaskWireException(name)
        if (number < low || number > MAX_SAFE_INTEGER) throw CloudTaskWireException(name)
        return number
    }

    private fun target(value: JsonValue?, open: Boolean): CloudTaskTarget {
        val target = value as? JsonValue.Obj ?: throw CloudTaskWireException("target")
        if (!open) closed(target, listOf("kind", "id"))
        val kind = CloudTaskTargetKind.of(string(target, "kind")) ?: throw CloudTaskWireException("target kind")
        return CloudTaskTarget(kind, id(target, "id"))
    }

    private fun sealed(value: JsonValue?, open: Boolean): CloudTaskSealed {
        val sealed = value as? JsonValue.Obj ?: throw CloudTaskWireException("sealed")
        if (!open) closed(sealed, listOf("enc", "ct"))
        val enc = base64UrlDecode(string(sealed, "enc"))
        if (enc.size != ENC_BYTES) throw CloudTaskWireException("enc")
        val ct = base64UrlDecode(string(sealed, "ct"))
        if (ct.size !in (TAG_BYTES + 1)..(MAX_TEXT_BYTES + TAG_BYTES)) throw CloudTaskWireException("ct")
        return CloudTaskSealed(enc, ct)
    }

    /** Closed with the suite and point form checked for a request; an answer only needs the members. */
    private fun publicKey(value: JsonValue?, open: Boolean): CloudTaskPublicKey {
        val key = value as? JsonValue.Obj ?: throw CloudTaskWireException("key")
        if (!open) closed(key, listOf("key_id", "suite", "public_key"))
        val keyId = id(key, "key_id")
        val suite = string(key, "suite")
        val point = base64UrlDecode(string(key, "public_key"))
        if (!open) {
            if (suite != SUITE) throw CloudTaskWireException("suite")
            if (point.size != ENC_BYTES || point[0] != 4.toByte()) throw CloudTaskWireException("public key")
        }
        return CloudTaskPublicKey(keyId, point)
    }
}
