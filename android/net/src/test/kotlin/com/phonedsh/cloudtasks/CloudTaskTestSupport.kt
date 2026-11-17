// SPDX-License-Identifier: MIT
// phone-dsh — :net tests: a local stand-in for the phone task queue.
//
// [FakeCloud] is a `CloudTaskTransport` that behaves like the cloud of
// spec/v1/cloud-tasks.md for the phone-side routes: registration replaces the
// device (and rejects tasks sealed to a replaced key), pull leases pending
// tasks, ack follows the state table of §6 (the reference reader's
// `apply_ack`). Request bodies go through the real `CloudTaskWire` validator.
// Nothing here contacts a network.

package com.phonedsh.cloudtasks

import com.phonedsh.account.TonoAccessTokenSource
import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.IOException
import java.net.URI
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.Collections

internal const val DEVICE_ID = "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a"

internal fun cloudTaskCases(): JsonValue.Obj {
    val path = Path.of(
        System.getProperty("pdsh.repo.root") ?: error("pdsh.repo.root is not set; the :net test task supplies it"),
    ).resolve("spec/v1/golden/cloud-tasks/cases.json")
    check(Files.isRegularFile(path)) { "shared cases must exist at $path" }
    return GatewayJson.parse(Files.readString(path, StandardCharsets.UTF_8)) as JsonValue.Obj
}

internal fun hex(text: String): ByteArray = ByteArray(text.length / 2) { index ->
    text.substring(index * 2, index * 2 + 2).toInt(16).toByte()
}

internal fun long(value: JsonValue.Obj, name: String): Long =
    (value.get(name) as JsonValue.Num).literal.toLong()

internal class FakeTokens(vararg tokens: String) : TonoAccessTokenSource {
    private val queue = ArrayDeque(tokens.toList())
    val invalidated: MutableList<String> = Collections.synchronizedList(ArrayList())

    @Synchronized
    override fun accessToken(): String? = queue.firstOrNull()

    /** Like the session: the next read "refreshes" to the following token, when there is one. */
    @Synchronized
    override fun invalidate(token: String) {
        invalidated += token
        if (queue.size > 1 && queue.first() == token) queue.removeFirst()
    }

    override val hasSession: Boolean get() = accessToken() != null
}

internal class FakeCloud(var now: Long = 1_794_700_000_000) : CloudTaskTransport {
    class Device(val keyId: String, val publicKey: String, val platform: String, val body: JsonValue.Obj)

    class Task(
        val taskId: String,
        val requestId: String,
        val keyId: String,
        val target: CloudTaskTarget,
        val expiresAtMs: Long,
        val sealed: CloudTaskSealed,
    ) {
        var state = "pending"
        var admissionId: String? = null
        var leaseUntilMs = Long.MIN_VALUE
        var attempt = 0L
    }

    class Seen(val method: String, val path: String, val query: String?, val authorization: String?, val body: JsonValue.Obj?)

    val devices = LinkedHashMap<String, Device>()
    val tasks = ArrayList<Task>()
    val seen: MutableList<Seen> = Collections.synchronizedList(ArrayList())

    /** The token this cloud accepts; any other bearer is `401 credential_expired`. */
    var acceptedToken = "tok-1"

    /** False: an older cloud without the routes (a plain 404). */
    var routesPresent = true

    /** Requests (by "METHOD path") that are lost before the cloud handles them, once each. */
    val loseRequestOnce = ArrayList<String>()

    /** Members added to every pull answer, to exercise closed decoding. */
    var extraPullMember: Pair<String, JsonValue>? = null

    /** Served verbatim as the `tasks` of the next pull, once. */
    var rawPullOnce: List<JsonValue>? = null

    /** When set, the `server_time_ms` of every answer (the task filter still uses [now]). */
    var reportedTime: Long? = null

    /** Called with each request before it is handled. */
    var onRequest: (Seen) -> Unit = {}

    fun count(method: String, path: String): Int = seen.count { it.method == method && it.path == path }

    fun acks(): List<JsonValue.Obj> = seen.filter { it.method == "POST" && it.path == "/v1/phone/tasks/ack" }
        .flatMap { it.body!!.array("acks")!! }.map { it as JsonValue.Obj }

    fun add(task: Task): Task {
        tasks += task
        return task
    }

    @Synchronized
    override fun send(request: CloudTaskHttpRequest): CloudTaskHttpAnswer {
        val uri = URI(request.url)
        check(uri.scheme == "https" && uri.host == "pdsh.tonoai.cn" && uri.port == -1) { "wrong origin ${request.url}" }
        val body = request.body?.let { GatewayJson.parseOrNull(it) as? JsonValue.Obj }
        val record = Seen(request.method, uri.path, uri.query, request.headers["authorization"], body)
        seen += record
        onRequest(record)
        val name = "${request.method} ${uri.path}"
        if (loseRequestOnce.remove(name)) throw IOException("connection reset")
        if (!routesPresent) return CloudTaskHttpAnswer(404, body = """{"detail":"Not Found"}""".toByteArray())
        val authorization = record.authorization ?: return error(401, "credential_missing")
        if (authorization.startsWith("Bearer pdsk_")) return error(403, "credential_not_allowed")
        if (authorization != "Bearer $acceptedToken") return error(401, "credential_expired")

        val devicePath = Regex("^/v1/phone/devices/([^/]+)$").matchEntire(uri.path)
        return when {
            request.method == "GET" && uri.path == "/v1/phone/devices" -> listDevices()
            request.method == "PUT" && devicePath != null -> register(devicePath.groupValues[1], body)
            request.method == "DELETE" && devicePath != null -> delete(devicePath.groupValues[1])
            request.method == "GET" && uri.path == "/v1/phone/tasks/pull" -> pull(uri.query.orEmpty())
            request.method == "POST" && uri.path == "/v1/phone/tasks/ack" -> ack(body)
            else -> CloudTaskHttpAnswer(404, body = """{"detail":"Not Found"}""".toByteArray())
        }
    }

    private fun json(status: Int, vararg members: Pair<String, JsonValue>): CloudTaskHttpAnswer =
        CloudTaskHttpAnswer(
            status,
            mapOf("content-type" to "application/json"),
            GatewayJson.canonicalBytes(JsonValue.obj(*members, "server_time_ms" to JsonValue.num(reportedTime ?: now))),
        )

    private fun error(status: Int, code: String): CloudTaskHttpAnswer = json(
        status,
        "error" to JsonValue.obj("code" to JsonValue.Str(code), "message" to JsonValue.Str(code)),
    )

    private fun register(deviceId: String, body: JsonValue.Obj?): CloudTaskHttpAnswer {
        try {
            CloudTaskWire.validateRequest(body ?: JsonValue.Null)
        } catch (_: CloudTaskWireException) {
            return error(400, "invalid_request")
        }
        if (body!!.string("schema") != CloudTaskWire.SCHEMA_DEVICE) return error(400, "invalid_request")
        val key = body.obj("key")!!
        val keyId = key.string("key_id")!!
        val previous = devices[deviceId]
        if (previous != null && previous.keyId == keyId && previous.publicKey != key.string("public_key")) {
            return error(409, "key_mismatch")
        }
        if (previous != null && previous.keyId != keyId) {
            tasks.filter { it.state == "pending" && it.keyId == previous.keyId }.forEach { it.state = "rejected" }
        }
        devices[deviceId] = Device(keyId, key.string("public_key")!!, body.string("platform")!!, body)
        return json(
            200,
            "schema" to JsonValue.Str("phone-device-ack/v1"),
            "device_id" to JsonValue.Str(deviceId),
            "key_id" to JsonValue.Str(keyId),
        )
    }

    private fun listDevices(): CloudTaskHttpAnswer = json(
        200,
        "schema" to JsonValue.Str("phone-device-list/v1"),
        "devices" to JsonValue.Arr(devices.map { (deviceId, device) ->
            JsonValue.obj(
                "device_id" to JsonValue.Str(deviceId),
                "platform" to JsonValue.Str(device.platform),
                "key" to JsonValue.obj(
                    "key_id" to JsonValue.Str(device.keyId),
                    "suite" to JsonValue.Str(CloudTaskWire.SUITE),
                    "public_key" to JsonValue.Str(device.publicKey),
                ),
                "updated_at_ms" to JsonValue.num(now),
            )
        }),
    )

    private fun delete(deviceId: String): CloudTaskHttpAnswer {
        if (devices.remove(deviceId) != null) tasks.filter { it.state == "pending" }.forEach { it.state = "cancelled" }
        return CloudTaskHttpAnswer(204)
    }

    private fun pull(query: String): CloudTaskHttpAnswer {
        val parameters = query.split('&').associate { it.substringBefore('=') to it.substringAfter('=') }
        if (devices[parameters["device_id"]] == null) return error(404, "not_found")
        val limit = parameters.getValue("limit").toInt()
        val lease = parameters.getValue("lease_s").toLong()
        val due = tasks.filter { it.state == "pending" && it.expiresAtMs > now && it.leaseUntilMs <= now }.take(limit)
        val items = due.map { task ->
            task.attempt++
            task.leaseUntilMs = now + lease * 1000
            JsonValue.obj(
                "task_id" to JsonValue.Str(task.taskId),
                "request_id" to JsonValue.Str(task.requestId),
                "key_id" to JsonValue.Str(task.keyId),
                "target" to JsonValue.obj(
                    "kind" to JsonValue.Str(task.target.kind.wire),
                    "id" to JsonValue.Str(task.target.id),
                ),
                "expires_at_ms" to JsonValue.num(task.expiresAtMs),
                "created_at_ms" to JsonValue.num(now),
                "sealed" to JsonValue.obj(
                    "enc" to JsonValue.Str(CloudTaskWire.base64UrlEncode(task.sealed.enc)),
                    "ct" to JsonValue.Str(CloudTaskWire.base64UrlEncode(task.sealed.ct)),
                ),
                "lease" to JsonValue.obj(
                    "lease_id" to JsonValue.Str("l-${task.taskId}-${task.attempt}"),
                    "attempt" to JsonValue.num(task.attempt),
                    "expires_at_ms" to JsonValue.num(task.leaseUntilMs),
                ),
            )
        }
        val raw = rawPullOnce
        rawPullOnce = null
        val members = arrayListOf<Pair<String, JsonValue>>(
            "schema" to JsonValue.Str("phone-task-pull/v1"),
            "tasks" to JsonValue.Arr(raw ?: items),
        )
        extraPullMember?.let { members += it }
        return json(200, *members.toTypedArray())
    }

    private fun ack(body: JsonValue.Obj?): CloudTaskHttpAnswer {
        try {
            CloudTaskWire.validateRequest(body ?: JsonValue.Null)
        } catch (_: CloudTaskWireException) {
            return error(400, "invalid_request")
        }
        // §5: every ack is `not_found` while the device is not registered to the caller.
        val known = devices.containsKey(body!!.string("device_id"))
        val results = body.array("acks")!!.map { item ->
            val ack = item as JsonValue.Obj
            val taskId = ack.string("task_id")!!
            val task = if (known) tasks.firstOrNull { it.taskId == taskId } else null
            val (accepted, duplicate) = if (task == null) false to false else apply(task, ack)
            JsonValue.obj(
                "task_id" to JsonValue.Str(taskId),
                "accepted" to JsonValue.bool(accepted),
                "duplicate" to JsonValue.bool(duplicate),
                "state" to JsonValue.Str(task?.state ?: "not_found"),
            )
        }
        return json(200, "schema" to JsonValue.Str("phone-task-ack-result/v1"), "results" to JsonValue.Arr(results))
    }

    /** `apply_ack` of the reference reader. */
    private fun apply(task: Task, ack: JsonValue.Obj): Pair<Boolean, Boolean> {
        val want = ack.string("state")!!
        return when (task.state) {
            "pending" -> if (want in setOf("admitted", "rejected", "expired")) {
                task.state = want
                task.admissionId = ack.string("admission_id")
                true to false
            } else {
                false to false
            }
            "admitted" -> when (want) {
                "admitted" -> (ack.string("admission_id") == task.admissionId).let { it to it }
                "completed", "failed", "unknown" -> {
                    task.state = want
                    true to false
                }
                else -> false to false
            }
            else -> (want == task.state).let { it to it }
        }
    }
}

/** A stand-in admission journal: first admit is `ADMITTED`, a repeat is `DUPLICATE` with the same id. */
internal class FakeJournal : CloudTaskAdmitter {
    val records = LinkedHashMap<String, String>()
    val requests = ArrayList<CloudTaskAdmissionRequest>()
    var next: CloudTaskAdmissionResult? = null
    var onAdmit: (CloudTaskAdmissionRequest) -> Unit = {}

    @Synchronized
    override fun admit(request: CloudTaskAdmissionRequest): CloudTaskAdmission {
        onAdmit(request)
        requests += request
        next?.let { return CloudTaskAdmission(it) }
        val existing = records[request.taskId]
        if (existing != null) return CloudTaskAdmission(CloudTaskAdmissionResult.DUPLICATE, existing)
        val admissionId = GatewayJson.sha256Hex("${request.deviceId}\u0000${request.taskId}".toByteArray())
        records[request.taskId] = admissionId
        return CloudTaskAdmission(CloudTaskAdmissionResult.ADMITTED, admissionId)
    }
}

internal class FakeTerminals : CloudTaskTerminalSource {
    val waiting = ArrayList<CloudTaskTerminal>()
    val settled = ArrayList<Pair<String, CloudTaskState>>()

    override fun pending(deviceId: String, limit: Int): List<CloudTaskTerminal> = waiting.take(limit)

    override fun settled(taskId: String, cloudState: CloudTaskState) {
        settled += taskId to cloudState
        waiting.removeAll { it.taskId == taskId }
    }
}
