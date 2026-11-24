// SPDX-License-Identifier: MIT
// Kotlin end of `Sources/PhoneDSHMail/MailMCPServer.swift`: the mail_* tools on
// `/mcp/native`, chained in front of the app's other native tools. Reading is
// free; every send is approved by the user in the foreground app first, and a
// journal-keyed receipt guarantees a retried or replayed call never sends twice.
package com.phonedsh.mail

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpResponse
import com.phonedsh.loopback.NativeMcpServing
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

/** Shows the user exactly what will be sent and returns their decision. */
public fun interface MailSendApproving {
    public suspend fun approve(account: MailAccount, draft: MailDraft): Boolean
}

public class MailMcpServer(
    private val fallback: NativeMcpServing,
    private val store: MailAccountStore,
    private val approver: MailSendApproving,
    private val receiptDirectory: Path,
    private val service: MailService = MailService(),
) : NativeMcpServing {
    private val sendLock = Mutex()

    override suspend fun cancelPendingOperations() {
        fallback.cancelPendingOperations()
    }

    override suspend fun handle(request: NativeMcpRequest): NativeMcpResponse {
        if (!request.method.equals("POST", true) || request.body.size > MAX_BODY) return fallback.handle(request)
        val root = try { JsonValue.parse(String(request.body, Charsets.UTF_8)) as? JsonObject } catch (_: Exception) { null }
            ?: return fallback.handle(request)
        if (root["jsonrpc"] != JsonString("2.0")) return fallback.handle(request)
        val method = (root["method"] as? JsonString)?.value ?: return fallback.handle(request)
        val hasAccounts = store.accounts().isNotEmpty()
        if (method == "initialize" || method == "tools/list") {
            val response = fallback.handle(request)
            if (!hasAccounts) return response
            val body = try { JsonValue.parse(String(response.body, Charsets.UTF_8)) as? JsonObject } catch (_: Exception) { null }
                ?: return response
            val result = body["result"] as? JsonObject ?: return response
            val members = LinkedHashMap(result.members)
            if (method == "tools/list") {
                val tools = (result["tools"] as? JsonArray)?.values ?: return response
                members["tools"] = JsonArray(tools + DESCRIPTORS)
            } else {
                val existing = (result["instructions"] as? JsonString)?.value?.let { "$it " }.orEmpty()
                members["instructions"] = JsonString(existing + INSTRUCTIONS)
            }
            val next = LinkedHashMap(body.members).apply { put("result", JsonObject(members)) }
            return NativeMcpResponse(response.status, JsonObject(next).toJsonString().toByteArray(Charsets.UTF_8))
        }
        val params = root["params"] as? JsonObject
        val name = (params?.get("name") as? JsonString)?.value
        if (method != "tools/call" || name == null || name !in TOOL_NAMES) return fallback.handle(request)
        val id = root["id"] ?: return NativeMcpResponse(202)
        val args = (params["arguments"] as? JsonObject)?.members.orEmpty()
        val result = try {
            run(name, args, request.header("x-pdsh-idempotency-key"))
        } catch (failure: MailException) {
            failureResult(failure.code, failure.message ?: "mail error")
        } catch (failure: Exception) {
            failureResult("mail_failed", failure.message ?: failure.javaClass.simpleName)
        }
        val envelope = JsonObject(linkedMapOf("jsonrpc" to JsonString("2.0"), "id" to id, "result" to result))
        return NativeMcpResponse(200, envelope.toJsonString().toByteArray(Charsets.UTF_8))
    }

    private suspend fun run(name: String, args: Map<String, JsonValue>, key: String?): JsonValue = when (name) {
        "mail_accounts" -> success(obj("accounts" to JsonArray(store.accounts().map {
            obj("address" to JsonString(it.address), "provider" to JsonString(it.provider.id))
        })))
        "mail_folders" -> {
            val account = resolveAccount(args)
            val folders = service.folders(account, store.secret(account))
            success(obj("account" to JsonString(account.address), "folders" to JsonArray(folders.map {
                obj("name" to JsonString(it.name), "flags" to JsonArray(it.flags.map(::JsonString)))
            })))
        }
        "mail_search" -> {
            val account = resolveAccount(args)
            val search = MailSearch(
                folder = string(args["folder"]) ?: "INBOX",
                query = string(args["query"]),
                unreadOnly = (args["unread_only"] as? JsonBool)?.value ?: false,
                sinceDays = int(args["since_days"])?.coerceIn(1, 3650),
                limit = (int(args["limit"]) ?: 20).coerceIn(1, 50),
            )
            val items = service.search(account, store.secret(account), search)
            success(obj(
                "account" to JsonString(account.address),
                "folder" to JsonString(search.folder),
                "scanned_newest" to JsonNumber(MailService.SCAN_WINDOW.toString()),
                "messages" to JsonArray(items.map(::summary)),
            ))
        }
        "mail_read" -> {
            val account = resolveAccount(args)
            val uid = int(args["uid"])?.toLong()?.takeIf { it in 1..0xFFFF_FFFFL }
                ?: throw MailException.invalid("uid 必须是 mail_search 返回的正整数")
            val folder = string(args["folder"]) ?: "INBOX"
            val message = service.read(account, store.secret(account), folder, uid)
            success(obj(
                "account" to JsonString(account.address), "folder" to JsonString(folder),
                "uid" to JsonNumber(uid.toString()),
                "from" to JsonString(message.headers["from"].orEmpty()), "to" to JsonString(message.headers["to"].orEmpty()),
                "cc" to JsonString(message.headers["cc"].orEmpty()), "subject" to JsonString(message.headers["subject"].orEmpty()),
                "date" to JsonString(message.headers["date"].orEmpty()),
                "message_id" to JsonString(message.headers.raw("message-id").orEmpty()),
                "text" to JsonString(message.text.take(MAX_READ_CHARS)),
                "text_truncated" to JsonBool(message.text.length > MAX_READ_CHARS),
                "from_html" to JsonBool(message.isHtmlFallback),
                "attachments" to JsonArray(message.attachments.map {
                    obj("filename" to JsonString(it.filename), "content_type" to JsonString(it.contentType),
                        "size" to JsonNumber(it.size.toString()))
                }),
            ))
        }
        "mail_send" -> sendLock.withLock { send(args, key) }
        else -> throw MailException.invalid("unknown tool")
    }

    private suspend fun send(args: Map<String, JsonValue>, key: String?): JsonValue {
        val account = resolveAccount(args)
        val draft = MailDraft(
            to = addresses(args["to"], "to", required = true),
            cc = addresses(args["cc"], "cc", required = false),
            bcc = addresses(args["bcc"], "bcc", required = false),
            subject = string(args["subject"]).orEmpty(),
            body = string(args["body"]).orEmpty(),
            inReplyTo = string(args["in_reply_to"]),
        )
        if (draft.subject.isEmpty() && draft.body.isEmpty()) throw MailException.invalid("subject 和 body 不能都为空")
        if (draft.to.size + draft.cc.size + draft.bcc.size > 50) throw MailException.invalid("收件人最多 50 个")
        if (key.isNullOrEmpty() || key.toByteArray().size > 256) return failureResult("journal_key_required", "发送需要工具调用的幂等键")
        val fingerprint = fingerprint(account, draft)
        val file = receiptDirectory.resolve(sha256(key) + ".json")
        if (Files.exists(file)) {
            val receipt = JsonValue.parse(String(Files.readAllBytes(file), Charsets.UTF_8)) as? JsonObject
            if (string(receipt?.get("fingerprint")) != fingerprint) {
                return failureResult("idempotency_conflict", "同一个调用键对应了不同的邮件")
            }
            // A finished call returns its result; an interrupted one may or may not
            // have reached the server, so it is never re-sent automatically.
            return receipt?.get("result")?.takeIf { it != JsonNull }
                ?: failureResult("outcome_unknown", "上一次发送被中断，无法确定是否已发出。请到已发送文件夹确认，不要自动重发。")
        }
        if (!approver.approve(account, draft)) return failureResult("declined", "用户没有同意发送这封邮件。")
        Files.createDirectories(receiptDirectory)
        writeReceipt(file, fingerprint, JsonNull)
        val result = try {
            val messageId = service.send(account, store.secret(account), draft)
            success(obj(
                "status" to JsonString("sent"), "account" to JsonString(account.address),
                "message_id" to JsonString(messageId),
                "recipients" to JsonNumber((draft.to.size + draft.cc.size + draft.bcc.size).toString()),
            ))
        } catch (failure: MailException) {
            when (failure.code) {
                // The connection may have dropped after the server accepted the message.
                "timeout", "connection_failed" -> failureResult(
                    "outcome_unknown",
                    "发送过程中连接中断，无法确定邮件是否已发出。请到已发送文件夹确认，不要自动重发。",
                )
                // The server refused (auth, recipient, policy): nothing was accepted.
                else -> failureResult(failure.code, failure.message ?: "send failed")
            }
        }
        try { writeReceipt(file, fingerprint, result) } catch (_: Exception) {}
        return result
    }

    private fun resolveAccount(args: Map<String, JsonValue>): MailAccount {
        val accounts = store.accounts()
        val address = string(args["account"])
        if (!address.isNullOrEmpty()) {
            return store.account(address)
                ?: throw MailException.invalid("没有连接邮箱 $address。可用账号：${accounts.joinToString(", ") { it.address }}")
        }
        if (accounts.size == 1) return accounts.first()
        throw MailException.invalid(
            if (accounts.isEmpty()) "还没有连接邮箱" else "连接了多个邮箱，请用 account 指定：${accounts.joinToString(", ") { it.address }}",
        )
    }

    private fun writeReceipt(file: Path, fingerprint: String, result: JsonValue) {
        val temp = file.resolveSibling(file.fileName.toString() + ".tmp")
        Files.write(temp, obj("fingerprint" to JsonString(fingerprint), "result" to result).toJsonString().toByteArray(Charsets.UTF_8))
        Files.move(temp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    public companion object {
        public val TOOL_NAMES: Set<String> = setOf("mail_accounts", "mail_folders", "mail_search", "mail_read", "mail_send")
        private const val MAX_BODY = 256 shl 10
        private const val MAX_READ_CHARS = 20_000

        internal fun obj(vararg pairs: Pair<String, JsonValue>): JsonObject = JsonObject(linkedMapOf(*pairs))

        internal fun success(value: JsonValue): JsonValue = obj(
            "content" to JsonArray(listOf(obj("type" to JsonString("text"), "text" to JsonString(value.toJsonString())))),
            "isError" to JsonBool(false),
        )

        internal fun failureResult(code: String, message: String): JsonValue {
            val value = obj("status" to JsonString(code), "message" to JsonString(message.take(600)), "automatic_retry" to JsonBool(false))
            return obj(
                "content" to JsonArray(listOf(obj("type" to JsonString("text"), "text" to JsonString(value.toJsonString())))),
                "isError" to JsonBool(true),
            )
        }

        private fun summary(item: MailSummary): JsonValue = obj(
            "uid" to JsonNumber(item.uid.toString()), "from" to JsonString(item.from), "to" to JsonString(item.to),
            "subject" to JsonString(item.subject), "date" to JsonString(item.date), "seen" to JsonBool(item.seen),
            "size" to JsonNumber(item.size.toString()), "message_id" to JsonString(item.messageId),
        )

        internal fun string(value: JsonValue?): String? = (value as? JsonString)?.value

        internal fun int(value: JsonValue?): Int? = when (value) {
            is JsonNumber -> value.asLongOrNull()?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
            is JsonString -> value.value.toIntOrNull()
            else -> null
        }

        internal fun addresses(value: JsonValue?, field: String, required: Boolean): List<String> {
            val raw = when (value) {
                is JsonArray -> value.values.mapNotNull { string(it) }
                is JsonString -> listOf(value.value)
                null, JsonNull -> emptyList()
                else -> throw MailException.invalid("$field 必须是邮箱地址数组")
            }
            if (raw.any { Mime.addresses(it).isEmpty() }) throw MailException.invalid("$field 里有无效的邮箱地址")
            val parsed = raw.flatMap(Mime::addresses)
            if (required && parsed.isEmpty()) throw MailException.invalid("$field 至少需要一个邮箱地址")
            return parsed
        }

        internal fun fingerprint(account: MailAccount, draft: MailDraft): String = sha256(listOf(
            account.address, draft.to.joinToString(","), draft.cc.joinToString(","), draft.bcc.joinToString(","),
            draft.subject, draft.body, draft.inReplyTo.orEmpty(),
        ).joinToString("\u001F"))

        private fun sha256(text: String): String =
            MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

        // Same wording and schemas as the iOS server.
        internal const val INSTRUCTIONS: String = "Mail tools read and send mail for the mailboxes the user connected on this phone (QQ Mail, NetEase, Gmail). Use mail_search to find messages (it matches subject and addresses in the newest messages, not body text), then mail_read with the returned uid. mail_send asks the user to confirm on the phone before sending; if the result is declined, do not retry. If a send result is outcome_unknown, tell the user to check the Sent folder and never resend automatically. Do not send mail the user did not ask for."

        private val ACCOUNT = obj("type" to JsonString("string"),
            "description" to JsonString("Mailbox address from mail_accounts; optional when only one is connected."))
        private val ADDRESS_LIST = obj("type" to JsonString("array"), "items" to obj("type" to JsonString("string")),
            "maxItems" to JsonNumber("50"))

        private fun tool(name: String, description: String, properties: Map<String, JsonValue>, required: List<String>, readOnly: Boolean) = obj(
            "name" to JsonString(name), "description" to JsonString(description),
            "inputSchema" to obj("type" to JsonString("object"), "properties" to JsonObject(properties),
                "required" to JsonArray(required.map(::JsonString)), "additionalProperties" to JsonBool(false)),
            "annotations" to obj("readOnlyHint" to JsonBool(readOnly), "idempotentHint" to JsonBool(readOnly)),
        )

        internal val DESCRIPTORS: List<JsonValue> = listOf(
            tool("mail_accounts", "List the connected mailboxes.", emptyMap(), emptyList(), true),
            tool("mail_folders", "List the folders of one mailbox (inbox, sent, drafts…).", mapOf("account" to ACCOUNT), emptyList(), true),
            tool("mail_search", "Find recent messages in a folder. Matches subject, from, to and cc among the newest ${MailService.SCAN_WINDOW} messages.",
                linkedMapOf(
                    "account" to ACCOUNT,
                    "folder" to obj("type" to JsonString("string"), "description" to JsonString("Folder name from mail_folders; default INBOX.")),
                    "query" to obj("type" to JsonString("string"), "description" to JsonString("Text to match in subject or addresses.")),
                    "unread_only" to obj("type" to JsonString("boolean")),
                    "since_days" to obj("type" to JsonString("integer"), "minimum" to JsonNumber("1"), "maximum" to JsonNumber("3650")),
                    "limit" to obj("type" to JsonString("integer"), "minimum" to JsonNumber("1"), "maximum" to JsonNumber("50")),
                ), emptyList(), true),
            tool("mail_read", "Read one message as text, with its attachment list. Does not mark it read.",
                linkedMapOf(
                    "account" to ACCOUNT,
                    "folder" to obj("type" to JsonString("string"), "description" to JsonString("Same folder as the search; default INBOX.")),
                    "uid" to obj("type" to JsonString("integer"), "minimum" to JsonNumber("1")),
                ), listOf("uid"), true),
            tool("mail_send", "Send a plain-text email. The user confirms on the phone before it is sent. To reply, pass the original message_id as in_reply_to and a subject starting with Re:.",
                linkedMapOf(
                    "account" to ACCOUNT, "to" to ADDRESS_LIST, "cc" to ADDRESS_LIST, "bcc" to ADDRESS_LIST,
                    "subject" to obj("type" to JsonString("string"), "maxLength" to JsonNumber("998")),
                    "body" to obj("type" to JsonString("string"), "maxLength" to JsonNumber("100000")),
                    "in_reply_to" to obj("type" to JsonString("string")),
                ), listOf("to", "subject", "body"), false),
        )
    }
}
