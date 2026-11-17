// SPDX-License-Identifier: MIT
// phone-dsh — :app tests: a local stand-in for the phone task queue.
//
// A `CloudTaskTransport` that behaves like the cloud of spec/v1/cloud-tasks.md
// for the phone-side routes (register, list, delete, pull with leases, ack by
// the §6 state table), the same shape as the `:net` suite's stand-in. Request
// bodies go through the real `CloudTaskWire` validator; tasks are sealed with
// the real `CloudTaskCrypto` to the key the phone registered. No network.
package com.phonedsh.probe.cloudtasks

import com.phonedsh.account.TonoAccessTokenSource
import com.phonedsh.cloudtasks.CloudTaskCrypto
import com.phonedsh.cloudtasks.CloudTaskHttpAnswer
import com.phonedsh.cloudtasks.CloudTaskHttpRequest
import com.phonedsh.cloudtasks.CloudTaskSealed
import com.phonedsh.cloudtasks.CloudTaskTarget
import com.phonedsh.cloudtasks.CloudTaskTargetKind
import com.phonedsh.cloudtasks.CloudTaskTransport
import com.phonedsh.cloudtasks.CloudTaskWire
import com.phonedsh.cloudtasks.CloudTaskWireException
import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.IOException
import java.net.URI
import java.util.Collections

internal const val TEST_DEVICE_ID = "dev-6f1c2a9e-0b7d-4c1e-9a55-2f3e4d5c6b7a"

/** The session's token source: a token while "signed in", none after. */
internal class TestTokens(@Volatile var token: String? = "tok-1") : TonoAccessTokenSource {
    override fun accessToken(): String? = token

    override fun invalidate(token: String) = Unit

    override val hasSession: Boolean get() = token != null
}

internal class TestCloud(var now: Long) : CloudTaskTransport {
    class Device(val keyId: String, val publicKey: String, val body: JsonValue.Obj)

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
        var reason: String? = null
        var leaseUntilMs = Long.MIN_VALUE
        var attempt = 0L
    }

    class Seen(val method: String, val path: String, val authorization: String?, val body: JsonValue.Obj?)

    val devices = LinkedHashMap<String, Device>()
    val tasks = ArrayList<Task>()
    val seen: MutableList<Seen> = Collections.synchronizedList(ArrayList())
    var acceptedToken = "tok-1"

    /** False: an older cloud without the routes (a plain 404). */
    var routesPresent = true

    /** When set, every device registration is refused with this code (409). */
    var refuseRegistration: String? = null

    /** Requests (by "METHOD path") that are lost before the cloud handles them, once each. */
    val loseRequestOnce = ArrayList<String>()

    fun count(method: String, path: String): Int = seen.count { it.method == method && it.path == path }

    /** Every ack object the phone sent, in order. */
    fun acks(): List<JsonValue.Obj> = seen.filter { it.method == "POST" && it.path == "/v1/phone/tasks/ack" }
        .flatMap { it.body!!.array("acks")!! }.map { it as JsonValue.Obj }

    fun task(taskId: String): Task = tasks.first { it.taskId == taskId }

    /** What a submitter does: seal to the device's registered key and leave the task. */
    fun submit(
        taskId: String,
        target: CloudTaskTarget = CloudTaskTarget(CloudTaskTargetKind.DSH_SESSION, "gb-main"),
        text: String = "整理今天的会议纪要",
        ttlMs: Long = 3_600_000,
    ): Task {
        val device = devices.getValue(TEST_DEVICE_ID)
        val requestId = "req-$taskId"
        val expiresAtMs = now + ttlMs
        val sealed = CloudTaskCrypto.seal(
            CloudTaskWire.base64UrlDecode(device.publicKey),
            text.toByteArray(Charsets.UTF_8),
            CloudTaskCrypto.aad(TEST_DEVICE_ID, device.keyId, requestId, target, expiresAtMs),
        )
        return Task(taskId, requestId, device.keyId, target, expiresAtMs, sealed).also { tasks += it }
    }

    @Synchronized
    override fun send(request: CloudTaskHttpRequest): CloudTaskHttpAnswer {
        val uri = URI(request.url)
        check(uri.scheme == "https" && uri.host == "pdsh.tonoai.cn" && uri.port == -1) { "wrong origin ${request.url}" }
        val body = request.body?.let { GatewayJson.parseOrNull(it) as? JsonValue.Obj }
        val record = Seen(request.method, uri.path, request.headers["authorization"], body)
        seen += record
        if (loseRequestOnce.remove("${request.method} ${uri.path}")) throw IOException("connection reset")
        if (!routesPresent) return CloudTaskHttpAnswer(404, body = """{"detail":"Not Found"}""".toByteArray())
        val authorization = record.authorization ?: return error(401, "credential_missing")
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
            GatewayJson.canonicalBytes(JsonValue.obj(*members, "server_time_ms" to JsonValue.num(now))),
        )

    private fun error(status: Int, code: String): CloudTaskHttpAnswer = json(
        status,
        "error" to JsonValue.obj("code" to JsonValue.Str(code), "message" to JsonValue.Str(code)),
    )

    private fun valid(body: JsonValue.Obj?): Boolean = try {
        CloudTaskWire.validateRequest(body ?: JsonValue.Null)
        true
    } catch (_: CloudTaskWireException) {
        false
    }

    private fun register(deviceId: String, body: JsonValue.Obj?): CloudTaskHttpAnswer {
        if (!valid(body) || body!!.string("schema") != CloudTaskWire.SCHEMA_DEVICE) return error(400, "invalid_request")
        refuseRegistration?.let { return error(409, it) }
        val key = body.obj("key")!!
        val keyId = key.string("key_id")!!
        val previous = devices[deviceId]
        if (previous != null && previous.keyId == keyId && previous.publicKey != key.string("public_key")) {
            return error(409, "key_mismatch")
        }
        if (previous != null && previous.keyId != keyId) {
            tasks.filter { it.state == "pending" && it.keyId == previous.keyId }.forEach { it.state = "rejected" }
        }
        devices[deviceId] = Device(keyId, key.string("public_key")!!, body)
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
                "platform" to JsonValue.Str("android"),
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
        return json(200, "schema" to JsonValue.Str("phone-task-pull/v1"), "tasks" to JsonValue.Arr(items))
    }

    private fun ack(body: JsonValue.Obj?): CloudTaskHttpAnswer {
        if (!valid(body)) return error(400, "invalid_request")
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

    /** `apply_ack` of the reference reader (§6: first wins). */
    private fun apply(task: Task, ack: JsonValue.Obj): Pair<Boolean, Boolean> {
        val want = ack.string("state")!!
        return when (task.state) {
            "pending" -> if (want in setOf("admitted", "rejected", "expired")) {
                task.state = want
                task.admissionId = ack.string("admission_id")
                task.reason = ack.string("reason")
                true to false
            } else {
                false to false
            }
            "admitted" -> when (want) {
                "admitted" -> (ack.string("admission_id") == task.admissionId).let { it to it }
                "completed", "failed", "unknown" -> {
                    task.state = want
                    task.reason = ack.string("reason")
                    true to false
                }
                else -> false to false
            }
            else -> (want == task.state).let { it to it }
        }
    }
}
