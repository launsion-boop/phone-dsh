// SPDX-License-Identifier: MIT
// Mirrors Tests/PhoneDSHMailTests on the Kotlin side.
package com.phonedsh.mail

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpResponse
import com.phonedsh.loopback.NativeMcpServing
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.util.Base64

class MimeTest {
    @Test fun encodedWordsInUtf8AndGbk() {
        assertEquals("你好世界", Mime.decodeEncodedWords("=?UTF-8?B?5L2g5aW9?= =?UTF-8?B?5LiW55WM?="))
        assertEquals("Re: 测试", Mime.decodeEncodedWords("Re: =?gbk?Q?=B2=E2=CA=D4?="))
    }

    @Test fun multipartPrefersPlainAndListsAttachments() {
        val raw = listOf(
            "From: =?UTF-8?B?5byg5LiJ?= <zhang@qq.com>",
            "Subject: =?UTF-8?B?5ZGo5oql?=",
            "Content-Type: multipart/mixed; boundary=\"b1\"",
            "",
            "--b1",
            "Content-Type: multipart/alternative; boundary=\"b2\"",
            "",
            "--b2",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "=E4=BD=A0=E5=A5=BD",
            "--b2",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>ignored</p>",
            "--b2--",
            "--b1",
            "Content-Type: application/pdf; name=\"=?UTF-8?B?5oql5ZGKLnBkZg==?=\"",
            "Content-Disposition: attachment; filename=\"=?UTF-8?B?5oql5ZGKLnBkZg==?=\"",
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0=",
            "--b1--",
        ).joinToString("\r\n")
        val message = Mime.parse(raw.toByteArray())
        assertEquals("张三 <zhang@qq.com>", message.headers["from"])
        assertEquals("周报", message.headers["subject"])
        assertEquals("你好", message.text)
        assertFalse(message.isHtmlFallback)
        assertEquals(listOf(MimeAttachment("报告.pdf", "application/pdf", 5)), message.attachments)
    }

    @Test fun htmlOnlyBodyBecomesText() {
        val message = Mime.parse("Content-Type: text/html; charset=gb2312\r\n\r\n<html><head><style>x{}</style></head><body>A<br>B &amp; C</body></html>".toByteArray())
        assertTrue(message.isHtmlFallback)
        assertEquals("A\nB & C", message.text)
    }

    @Test fun composeRoundTrips() {
        val data = Mime.compose("me@qq.com", listOf("a@163.com"), emptyList(), "会议纪要", "第一行\n.第二行", "<x@y>", messageId = "<id@qq.com>")
        val message = Mime.parse(data)
        assertEquals("会议纪要", message.headers["subject"])
        assertEquals("<x@y>", message.headers["in-reply-to"])
        assertEquals("第一行\n.第二行", message.text)
    }

    @Test fun modifiedUtf7() {
        assertEquals("&XfJT0ZAB-", ModifiedUtf7.encode("已发送"))
        assertEquals("已发送", ModifiedUtf7.decode("&XfJT0ZAB-"))
        assertEquals("A&-B", ModifiedUtf7.encode("A&B"))
    }

    @Test fun providerServers() {
        assertEquals(MailProvider.NETEASE, MailProvider.forAddress("x@163.com"))
        assertEquals("imap.126.com", MailProvider.NETEASE.servers("x@126.com")?.first?.host)
        assertEquals("smtp.qq.com", MailProvider.QQ.servers("x@foxmail.com")?.second?.host)
        assertNull(MailProvider.QQ.servers("x@163.com"))
    }
}

class MailProtocolTest {
    @Test fun searchIdentifiesExaminesAndFiltersLocally() = runBlocking {
        val imap = FakeImap(listOf(
            Triple(7L, "From: boss@corp.com\r\nSubject: =?UTF-8?B?5ZGo5oql?=\r\nMessage-ID: <7@corp>\r\n", ""),
            Triple(9L, "From: news@shop.com\r\nSubject: Sale\r\n", ""),
        ))
        val results = MailService(FakeFactory(imap = imap)).search(MailAccount.of("me@163.com", MailProvider.NETEASE), "code", MailSearch(query = "周报"))
        assertEquals(listOf(7L), results.map { it.uid })
        assertEquals("<7@corp>", results.first().messageId)
        assertTrue(imap.commands.any { it.startsWith("LOGIN \"me@163.com\" \"code\"") })
        assertTrue("NetEase needs ID before EXAMINE", imap.commands.any { it.startsWith("ID (") })
        assertTrue(imap.commands.contains("EXAMINE \"INBOX\""))
        assertFalse("reading must stay read-only", imap.commands.any { it.startsWith("SELECT") })
    }

    @Test fun readUsesPeek() = runBlocking {
        val imap = FakeImap(listOf(Triple(3L, "From: a@b.com\r\nSubject: hi\r\n", "hello there\r\n")))
        val message = MailService(FakeFactory(imap = imap)).read(MailAccount.of("me@qq.com", MailProvider.QQ), "c", "INBOX", 3)
        assertEquals("hello there\r\n", message.text)
        assertTrue(imap.commands.contains("UID FETCH 3 (UID BODY.PEEK[])"))
    }

    @Test fun rejectedLoginIsAuthenticationFailure() = runBlocking {
        try {
            MailService(FakeFactory(imap = FakeImap(emptyList(), rejectLogin = true)))
                .search(MailAccount.of("me@qq.com", MailProvider.QQ), "bad", MailSearch())
            fail("expected authentication_failed")
        } catch (failure: MailException) {
            assertEquals("authentication_failed", failure.code)
        }
    }

    @Test fun smtpAuthenticatesAndKeepsBccOutOfHeaders() = runBlocking {
        val smtp = FakeSmtp()
        MailService(FakeFactory(smtp = smtp)).send(MailAccount.of("me@qq.com", MailProvider.QQ), "code",
            MailDraft(to = listOf("a@163.com"), bcc = listOf("hidden@x.com"), subject = "Hi", body = ".leading dot"))
        assertTrue(smtp.commands.contains("AUTH LOGIN"))
        assertTrue(smtp.commands.contains("RCPT TO:<hidden@x.com>"))
        assertFalse(smtp.data.contains("hidden@x.com"))
        assertTrue(smtp.data.contains("Subject: Hi"))
    }
}

class MailMcpServerTest {
    private fun store() = MemoryStore().apply { save(MailAccount.of("me@qq.com", MailProvider.QQ), "code") }

    private fun call(server: MailMcpServer, name: String, args: Map<String, JsonValue>, key: String? = "k1"): JsonObject = runBlocking {
        val body = MailMcpServer.obj("jsonrpc" to JsonString("2.0"), "id" to JsonNumber("1"), "method" to JsonString("tools/call"),
            "params" to MailMcpServer.obj("name" to JsonString(name), "arguments" to JsonObject(args))).toJsonString()
        val headers = if (key != null) mapOf("x-pdsh-idempotency-key" to key) else emptyMap()
        val response = server.handle(NativeMcpRequest("POST", headers, body.toByteArray()))
        val result = (JsonValue.parse(String(response.body)) as JsonObject)["result"] as JsonObject
        val text = (((result["content"] as JsonArray).values.first() as JsonObject)["text"] as JsonString).value
        JsonValue.parse(text) as JsonObject
    }

    private val sendArgs: Map<String, JsonValue> = mapOf("to" to JsonArray(listOf(JsonString("a@163.com"))),
        "subject" to JsonString("s"), "body" to JsonString("b"))

    @Test fun toolsAreListedOnlyWithAnAccount() = runBlocking {
        val request = NativeMcpRequest("POST", emptyMap(), """{"jsonrpc":"2.0","id":1,"method":"tools/list"}""".toByteArray())
        val empty = MailMcpServer(EmptyMcp, MemoryStore(), { _, _ -> true }, Files.createTempDirectory("mail"))
        assertFalse(String(empty.handle(request).body).contains("mail_send"))
        val server = MailMcpServer(EmptyMcp, store(), { _, _ -> true }, Files.createTempDirectory("mail"))
        assertTrue(String(server.handle(request).body).contains("mail_send"))
    }

    @Test fun declinedSendNeverConnects() {
        val smtp = FakeSmtp()
        val server = MailMcpServer(EmptyMcp, store(), { _, _ -> false }, Files.createTempDirectory("mail"), MailService(FakeFactory(smtp = smtp)))
        assertEquals(JsonString("declined"), call(server, "mail_send", sendArgs)["status"])
        assertTrue(smtp.commands.isEmpty())
    }

    @Test fun replayedSendReturnsReceiptWithoutSendingAgain() {
        val smtp = FakeSmtp()
        var asked = 0
        val server = MailMcpServer(EmptyMcp, store(), { _, _ -> asked++; true }, Files.createTempDirectory("mail"), MailService(FakeFactory(smtp = smtp)))
        val first = call(server, "mail_send", sendArgs)
        assertEquals(JsonString("sent"), first["status"])
        assertEquals(first, call(server, "mail_send", sendArgs))
        assertEquals(1, asked)
        assertEquals(1, smtp.commands.count { it == "DATA" })
        val conflict = call(server, "mail_send", sendArgs + ("body" to JsonString("different")))
        assertEquals(JsonString("idempotency_conflict"), conflict["status"])
    }

    @Test fun sendWithoutJournalKeyIsRefused() {
        val server = MailMcpServer(EmptyMcp, store(), { _, _ -> true }, Files.createTempDirectory("mail"), MailService(FakeFactory(smtp = FakeSmtp())))
        assertEquals(JsonString("journal_key_required"), call(server, "mail_send", sendArgs, key = null)["status"])
    }
}

// MARK: fakes

private class FakeFactory(val imap: FakeImap? = null, val smtp: FakeSmtp? = null) : MailTransportFactory {
    override fun connect(host: String, port: Int): MailLineTransport = when {
        port == 993 && imap != null -> imap.also { it.reset() }
        port == 465 && smtp != null -> smtp.also { it.reset() }
        else -> throw MailException.connection("no fake for $host:$port")
    }
}

private abstract class Scripted : MailLineTransport {
    private val buffer = java.io.ByteArrayOutputStream()
    private var position = 0
    private var bytes = ByteArray(0)

    fun push(text: String) { buffer.write(text.toByteArray()); bytes = buffer.toByteArray() }

    override fun readLine(): ByteArray {
        val start = position
        while (position < bytes.size && bytes[position] != '\n'.code.toByte()) position++
        if (position >= bytes.size) throw MailException.closed
        var end = position
        position++
        if (end > start && bytes[end - 1] == '\r'.code.toByte()) end--
        return bytes.copyOfRange(start, end)
    }

    override fun read(count: Int): ByteArray {
        if (position + count > bytes.size) throw MailException.closed
        return bytes.copyOfRange(position, position + count).also { position += count }
    }

    override fun close() {}
}

private class FakeImap(val messages: List<Triple<Long, String, String>>, val rejectLogin: Boolean = false) : Scripted() {
    val commands = ArrayList<String>()

    fun reset() = push("* OK ready\r\n")

    override fun send(data: ByteArray) {
        val line = String(data).trimEnd('\r', '\n')
        val tag = line.substringBefore(' ')
        val command = line.substringAfter(' ')
        commands.add(command)
        when {
            command.startsWith("LOGIN") -> push(if (rejectLogin) "$tag NO [AUTHENTICATIONFAILED] bad\r\n" else "$tag OK\r\n")
            command.startsWith("EXAMINE") -> push("* ${messages.size} EXISTS\r\n$tag OK [READ-ONLY]\r\n")
            command.startsWith("UID SEARCH") -> push("* SEARCH ${messages.joinToString(" ") { it.first.toString() }}\r\n$tag OK\r\n")
            command.startsWith("UID FETCH") && command.contains("BODY.PEEK[]") -> {
                val uid = command.split(' ')[2].toLong()
                val m = messages.first { it.first == uid }
                val full = m.second + "\r\n" + m.third
                push("* 1 FETCH (UID $uid BODY[] {${full.toByteArray().size}}\r\n$full)\r\n$tag OK\r\n")
            }
            command.startsWith("UID FETCH") -> {
                val set = command.split(' ')[2].split(',').mapNotNull { it.toLongOrNull() }.toSet()
                val reply = StringBuilder()
                for (m in messages) if (m.first in set) {
                    val header = m.second + "\r\n"
                    val size = (m.second + "\r\n" + m.third).toByteArray().size
                    reply.append("* 1 FETCH (UID ${m.first} FLAGS (\\Seen) RFC822.SIZE $size BODY[HEADER.FIELDS (FROM)] {${header.toByteArray().size}}\r\n$header)\r\n")
                }
                push("$reply$tag OK\r\n")
            }
            command.startsWith("LOGOUT") -> push("* BYE\r\n$tag OK\r\n")
            else -> push("$tag OK\r\n")
        }
    }
}

private class FakeSmtp : Scripted() {
    val commands = ArrayList<String>()
    var data = ""
    private var inData = false

    fun reset() { inData = false; push("220 ready\r\n") }

    override fun send(payload: ByteArray) {
        val text = String(payload)
        if (inData) {
            data += text
            if (text.endsWith("\r\n.\r\n")) { inData = false; push("250 queued\r\n") }
            return
        }
        val line = text.trimEnd('\r', '\n')
        commands.add(line)
        when {
            line.startsWith("EHLO") -> push("250-hello\r\n250 AUTH LOGIN\r\n")
            line == "AUTH LOGIN" -> push("334 VXNlcm5hbWU6\r\n")
            line == Base64.getEncoder().encodeToString("me@qq.com".toByteArray()) -> push("334 UGFzc3dvcmQ6\r\n")
            line == Base64.getEncoder().encodeToString("code".toByteArray()) -> push("235 ok\r\n")
            line == "DATA" -> { inData = true; push("354 go\r\n") }
            line == "QUIT" -> push("221 bye\r\n")
            else -> push("250 ok\r\n")
        }
    }
}

private class MemoryStore : MailAccountStore {
    private val secrets = LinkedHashMap<String, String>()
    private val list = ArrayList<MailAccount>()
    override fun accounts(): List<MailAccount> = list.toList()
    override fun secret(account: MailAccount): String = secrets[account.address] ?: throw MailException.store
    override fun save(account: MailAccount, secret: String) { secrets[account.address] = secret; list.removeAll { it.address == account.address }; list.add(account) }
    override fun remove(address: String) { list.removeAll { it.address == address }; secrets.remove(address) }
}

private object EmptyMcp : NativeMcpServing {
    override suspend fun handle(request: NativeMcpRequest): NativeMcpResponse =
        NativeMcpResponse(200, """{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}""".toByteArray())
}
