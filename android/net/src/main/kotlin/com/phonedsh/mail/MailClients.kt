// SPDX-License-Identifier: MIT
// Kotlin end of `Sources/PhoneDSHMail` (MailTransport, IMAPClient, SMTPClient,
// MailAccounts, MailService): implicit-TLS IMAP reading (EXAMINE + BODY.PEEK,
// so reading never changes \Seen) and SMTP submission, one connection per
// operation.
package com.phonedsh.mail

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/** A mail failure with a user-facing message and a stable tool status code. */
public class MailException(public val code: String, message: String) : IOException(message) {
    public companion object {
        public fun authentication(detail: String): MailException = MailException(
            "authentication_failed",
            "登录失败：$detail。请确认邮箱地址和客户端授权码，并已在邮箱网页设置里开启 IMAP/SMTP 服务。",
        )
        public fun connection(detail: String): MailException = MailException("connection_failed", "无法连接邮件服务器：$detail")
        public fun server(detail: String): MailException = MailException("server_error", "邮件服务器返回错误：$detail")
        public fun invalid(detail: String): MailException = MailException("invalid_arguments", "参数无效：$detail")
        public val timeout: MailException get() = MailException("timeout", "邮件服务器响应超时。")
        public val closed: MailException get() = MailException("connection_failed", "邮件服务器关闭了连接。")
        public val notFound: MailException get() = MailException("not_found", "找不到这封邮件。")
        public val store: MailException get() = MailException("account_unavailable", "无法读取或保存邮箱账号。")
        public fun tooLarge(size: Int): MailException = MailException("message_too_large", "邮件过大（$size 字节），无法读取。")
    }
}

// MARK: transport

/** Blocking line transport; callers run it on [Dispatchers.IO]. */
public interface MailLineTransport {
    public fun send(data: ByteArray)
    /** One line without its CRLF. */
    public fun readLine(): ByteArray
    public fun read(count: Int): ByteArray
    public fun close()
}

public fun interface MailTransportFactory {
    public fun connect(host: String, port: Int): MailLineTransport
}

/** Implicit TLS (IMAPS 993, SMTPS 465) with hostname verification. */
public class TlsMailTransportFactory(private val timeoutMillis: Int = 30_000) : MailTransportFactory {
    override fun connect(host: String, port: Int): MailLineTransport {
        val socket = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket() as SSLSocket
        try {
            socket.connect(InetSocketAddress(host, port), timeoutMillis)
            socket.soTimeout = timeoutMillis
            val sslParameters = socket.sslParameters
            sslParameters.endpointIdentificationAlgorithm = "HTTPS"
            socket.sslParameters = sslParameters
            socket.startHandshake()
        } catch (failure: SocketTimeoutException) {
            socket.close(); throw MailException.timeout
        } catch (failure: IOException) {
            socket.close(); throw MailException.connection(failure.message ?: failure.javaClass.simpleName)
        }
        return StreamMailTransport(BufferedInputStream(socket.getInputStream()), socket.getOutputStream()) { socket.close() }
    }
}

/** Line reader over streams; also the test seam. */
public class StreamMailTransport(
    private val input: InputStream,
    private val output: OutputStream,
    private val onClose: () -> Unit = {},
) : MailLineTransport {
    override fun send(data: ByteArray) = guard { output.write(data); output.flush() }

    override fun readLine(): ByteArray = guard {
        val line = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) throw MailException.closed
            if (b == '\n'.code) break
            line.write(b)
            if (line.size() > MAX_LINE) throw MailException.server("line too long")
        }
        val bytes = line.toByteArray()
        if (bytes.isNotEmpty() && bytes.last() == '\r'.code.toByte()) bytes.copyOf(bytes.size - 1) else bytes
    }

    override fun read(count: Int): ByteArray = guard {
        val out = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val n = input.read(out, offset, count - offset)
            if (n < 0) throw MailException.closed
            offset += n
        }
        out
    }

    override fun close() { try { onClose() } catch (_: IOException) {} }

    private inline fun <T> guard(block: () -> T): T = try {
        block()
    } catch (failure: MailException) {
        throw failure
    } catch (failure: SocketTimeoutException) {
        throw MailException.timeout
    } catch (failure: IOException) {
        throw MailException.connection(failure.message ?: failure.javaClass.simpleName)
    }

    private companion object { const val MAX_LINE = 1 shl 20 }
}

// MARK: IMAP

public data class MailSummary(
    val uid: Long, val from: String, val to: String, val cc: String, val subject: String,
    val date: String, val messageId: String, val seen: Boolean, val size: Int,
)

public data class MailFolder(val name: String, val flags: List<String>)

internal class ImapLine(val text: String, val literals: List<ByteArray>)

internal class ImapSession(private val transport: MailLineTransport) {
    private var counter = 0

    fun greeting() {
        val line = readResponseLine()
        if (!line.text.startsWith("* OK") && !line.text.startsWith("* PREAUTH")) throw MailException.server(line.text.take(200))
    }

    fun login(user: String, password: String) {
        try {
            command("LOGIN ${quote(user)} ${quote(password)}")
        } catch (failure: MailException) {
            if (failure.code == "server_error") throw MailException.authentication(failure.message ?: "")
            throw failure
        }
    }

    /** RFC 2971 ID: NetEase refuses EXAMINE ("Unsafe Login") until the client identifies itself. */
    fun identify() {
        try { command("ID (\"name\" \"PhoneDSH\" \"version\" \"1.0\" \"vendor\" \"PhoneDSH\")") } catch (_: MailException) {}
    }

    fun listFolders(): List<MailFolder> = command("LIST \"\" \"*\"").mapNotNull { if (it.text.startsWith("* LIST ")) parseList(it) else null }

    fun examine(folder: String): Int {
        for (line in command("EXAMINE ${quote(ModifiedUtf7.encode(folder))}")) {
            val parts = line.text.split(' ')
            if (parts.size >= 3 && parts[0] == "*" && parts[2].equals("EXISTS", true)) return parts[1].toIntOrNull() ?: 0
        }
        return 0
    }

    fun uidSearch(criteria: String): List<Long> = command("UID SEARCH $criteria")
        .filter { it.text.uppercase().startsWith("* SEARCH") }
        .flatMap { line -> line.text.split(' ').drop(2).mapNotNull { it.toLongOrNull() } }
        .sorted()

    fun fetchSummaries(uids: List<Long>): List<MailSummary> {
        if (uids.isEmpty()) return emptyList()
        val lines = command("UID FETCH ${uids.joinToString(",")} (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID)])")
        return lines.mapNotNull { line ->
            if (!line.text.uppercase().contains(" FETCH ")) return@mapNotNull null
            val uid = number("UID", line.text) ?: return@mapNotNull null
            val headers = MimeHeaders(line.literals.firstOrNull() ?: ByteArray(0))
            MailSummary(
                uid = uid, from = headers["from"].orEmpty(), to = headers["to"].orEmpty(), cc = headers["cc"].orEmpty(),
                subject = headers["subject"].orEmpty(), date = headers["date"].orEmpty(),
                messageId = headers.raw("message-id").orEmpty(),
                seen = flags(line.text).any { it.equals("\\Seen", true) },
                size = (number("RFC822.SIZE", line.text) ?: 0L).toInt(),
            )
        }
    }

    fun fetchMessage(uid: Long, maxBytes: Int): ByteArray {
        val summary = fetchSummaries(listOf(uid)).firstOrNull() ?: throw MailException.notFound
        if (summary.size > maxBytes) throw MailException.tooLarge(summary.size)
        return command("UID FETCH $uid (UID BODY.PEEK[])")
            .firstOrNull { it.text.uppercase().contains(" FETCH ") && it.literals.isNotEmpty() }
            ?.literals?.first() ?: throw MailException.notFound
    }

    fun logout() {
        try { command("LOGOUT") } catch (_: MailException) {}
        transport.close()
    }

    fun command(text: String): List<ImapLine> {
        counter++
        val tag = "A%03d".format(counter)
        transport.send("$tag $text\r\n".toByteArray(Charsets.UTF_8))
        val lines = ArrayList<ImapLine>()
        while (true) {
            val line = readResponseLine()
            if (line.text.startsWith("$tag ")) {
                val status = line.text.substring(tag.length + 1)
                if (status.uppercase().startsWith("OK")) return lines
                throw MailException.server(status.take(300))
            }
            if (line.text.startsWith("* BYE") && !text.startsWith("LOGOUT")) throw MailException.closed
            lines.add(line)
        }
    }

    private fun readResponseLine(): ImapLine {
        val text = StringBuilder()
        val literals = ArrayList<ByteArray>()
        while (true) {
            val piece = String(transport.readLine(), Charsets.UTF_8)
            text.append(piece)
            val size = trailingLiteral(piece) ?: return ImapLine(text.toString(), literals)
            if (size > 64 shl 20) throw MailException.tooLarge(size)
            literals.add(transport.read(size))
            text.append(' ')
        }
    }

    companion object {
        fun trailingLiteral(line: String): Int? {
            if (!line.endsWith("}")) return null
            val open = line.lastIndexOf('{')
            return if (open < 0) null else line.substring(open + 1, line.length - 1).toIntOrNull()
        }

        fun number(keyword: String, text: String): Long? =
            Regex(Regex.escape(keyword) + " (\\d+)", RegexOption.IGNORE_CASE).find(text)?.groupValues?.get(1)?.toLongOrNull()

        fun flags(text: String): List<String> =
            Regex("FLAGS \\(([^)]*)\\)", RegexOption.IGNORE_CASE).find(text)?.groupValues?.get(1)?.split(' ')?.filter { it.isNotEmpty() }.orEmpty()

        fun parseList(line: ImapLine): MailFolder? {
            val text = line.text
            val open = text.indexOf('(')
            val close = text.indexOf(')', open + 1)
            if (open < 0 || close < 0) return null
            val flags = text.substring(open + 1, close).split(' ').filter { it.isNotEmpty() }
            var rest = text.substring(close + 1).trim()
            if (rest.startsWith("\"")) {
                val end = rest.indexOf('"', 1)
                if (end > 0) rest = rest.substring(end + 1)
            } else if (rest.uppercase().startsWith("NIL")) {
                rest = rest.substring(3)
            }
            rest = rest.trim()
            val name = when {
                line.literals.isNotEmpty() && (rest.isEmpty() || rest.startsWith("{")) -> String(line.literals.last(), Charsets.UTF_8)
                rest.length >= 2 && rest.startsWith("\"") && rest.endsWith("\"") ->
                    rest.substring(1, rest.length - 1).replace("\\\"", "\"").replace("\\\\", "\\")
                else -> rest
            }
            return if (name.isEmpty()) null else MailFolder(ModifiedUtf7.decode(name), flags)
        }

        fun quote(value: String): String = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

        fun searchDate(date: Date): String = SimpleDateFormat("dd-MMM-yyyy", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }.format(date)
    }
}

/** RFC 3501 §5.1.3 modified UTF-7 for mailbox names (e.g. NetEase "已发送"). */
public object ModifiedUtf7 {
    public fun encode(value: String): String {
        val out = StringBuilder()
        val pending = StringBuilder()
        fun flush() {
            if (pending.isEmpty()) return
            val b64 = Base64.getEncoder().withoutPadding().encodeToString(pending.toString().toByteArray(Charsets.UTF_16BE))
            out.append('&').append(b64.replace('/', ',')).append('-')
            pending.setLength(0)
        }
        for (c in value) {
            if (c.code in 0x20..0x7E) {
                flush()
                if (c == '&') out.append("&-") else out.append(c)
            } else {
                pending.append(c)
            }
        }
        flush()
        return out.toString()
    }

    public fun decode(value: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < value.length) {
            val c = value[i]
            val end = if (c == '&') value.indexOf('-', i) else -1
            if (end < 0) { out.append(c); i++; continue }
            val payload = value.substring(i + 1, end)
            if (payload.isEmpty()) {
                out.append('&')
            } else {
                try {
                    out.append(String(Base64.getDecoder().decode(payload.replace(',', '/')), Charsets.UTF_16BE))
                } catch (_: IllegalArgumentException) {
                    out.append(value, i, end + 1)
                }
            }
            i = end + 1
        }
        return out.toString()
    }
}

// MARK: SMTP

internal class SmtpSession(private val transport: MailLineTransport) {
    fun greeting() { val (code, text) = readReply(); if (code != 220) throw MailException.server("$code $text") }

    fun hello() = expect("EHLO phonedsh.local", 250)

    fun login(user: String, password: String) {
        try {
            expect("AUTH LOGIN", 334)
            expect(Base64.getEncoder().encodeToString(user.toByteArray()), 334, redacted = true)
            expect(Base64.getEncoder().encodeToString(password.toByteArray()), 235, redacted = true)
        } catch (failure: MailException) {
            if (failure.code == "server_error") throw MailException.authentication(failure.message ?: "")
            throw failure
        }
    }

    fun send(from: String, recipients: List<String>, message: ByteArray) {
        expect("MAIL FROM:<$from>", 250)
        for (recipient in recipients) {
            val (code, text) = exchange("RCPT TO:<$recipient>")
            if (code != 250 && code != 251) throw MailException.server("收件人 $recipient 被拒绝：$code $text")
        }
        expect("DATA", 354)
        transport.send(dotStuffed(message) + "\r\n.\r\n".toByteArray())
        val (code, text) = readReply()
        if (code != 250) throw MailException.server("$code $text")
    }

    fun quit() {
        try { exchange("QUIT") } catch (_: MailException) {}
        transport.close()
    }

    private fun expect(line: String, code: Int, redacted: Boolean = false) {
        val (received, text) = exchange(line)
        if (received != code) throw MailException.server("$received $text" + if (redacted) "" else " (${line.take(40)})")
    }

    private fun exchange(line: String): Pair<Int, String> {
        transport.send("$line\r\n".toByteArray(Charsets.UTF_8))
        return readReply()
    }

    private fun readReply(): Pair<Int, String> {
        val lines = ArrayList<String>()
        while (true) {
            val line = String(transport.readLine(), Charsets.UTF_8)
            val code = line.take(3).toIntOrNull()
            if (line.length < 3 || code == null) throw MailException.server(line.take(200))
            lines.add(line.drop(4))
            if (line.length == 3 || line[3] == ' ') return code to lines.joinToString(" ")
        }
    }

    companion object {
        /** RFC 5321 §4.5.2: a line starting with "." gets one more ".". */
        fun dotStuffed(message: ByteArray): ByteArray {
            var text = String(message, Charsets.ISO_8859_1)
            if (text.startsWith(".")) text = ".$text"
            text = text.replace("\r\n.", "\r\n..").removeSuffix("\r\n")
            return text.toByteArray(Charsets.ISO_8859_1)
        }
    }
}

// MARK: accounts

public data class MailServer(val host: String, val port: Int)

public enum class MailProvider(public val id: String, public val displayName: String, public val domains: List<String>, public val secretName: String) {
    QQ("qq", "QQ 邮箱", listOf("qq.com", "foxmail.com", "vip.qq.com"), "客户端授权码"),
    NETEASE("netease", "网易邮箱", listOf("163.com", "126.com", "yeah.net"), "客户端授权码"),
    GMAIL("gmail", "Gmail", listOf("gmail.com", "googlemail.com"), "应用专用密码"),
    ;

    public fun servers(address: String): Pair<MailServer, MailServer>? {
        val domain = domainOf(address) ?: return null
        if (domain !in domains) return null
        return when (this) {
            QQ -> MailServer("imap.qq.com", 993) to MailServer("smtp.qq.com", 465)
            NETEASE -> MailServer("imap.$domain", 993) to MailServer("smtp.$domain", 465)
            GMAIL -> MailServer("imap.gmail.com", 993) to MailServer("smtp.gmail.com", 465)
        }
    }

    public companion object {
        public fun fromId(id: String): MailProvider? = entries.firstOrNull { it.id == id }
        public fun forAddress(address: String): MailProvider? = domainOf(address)?.let { d -> entries.firstOrNull { d in it.domains } }
        internal fun domainOf(address: String): String? {
            val parts = address.lowercase().split('@')
            return if (parts.size == 2 && parts[0].isNotEmpty() && parts[1].contains('.')) parts[1] else null
        }
    }
}

public data class MailAccount(val address: String, val provider: MailProvider) {
    public companion object {
        public fun of(address: String, provider: MailProvider): MailAccount = MailAccount(address.trim().lowercase(), provider)
    }
}

/** Where the app keeps the code (Android Keystore-backed) and the non-secret list. */
public interface MailAccountStore {
    public fun accounts(): List<MailAccount>
    public fun secret(account: MailAccount): String
    public fun save(account: MailAccount, secret: String)
    public fun remove(address: String)
    public fun account(address: String): MailAccount? = accounts().firstOrNull { it.address == address.trim().lowercase() }
}

// MARK: service

public data class MailSearch(
    val folder: String = "INBOX",
    val query: String? = null,
    val unreadOnly: Boolean = false,
    val sinceDays: Int? = null,
    val limit: Int = 20,
)

public data class MailDraft(
    val to: List<String>,
    val cc: List<String> = emptyList(),
    val bcc: List<String> = emptyList(),
    val subject: String,
    val body: String,
    val inReplyTo: String? = null,
)

public class MailService(
    private val factory: MailTransportFactory = TlsMailTransportFactory(),
    private val now: () -> Date = { Date() },
) {
    public suspend fun verify(account: MailAccount, secret: String) {
        withImap(account, secret) { }
        withSmtp(account, secret) { }
    }

    public suspend fun folders(account: MailAccount, secret: String): List<MailFolder> = withImap(account, secret) { it.listFolders() }

    public suspend fun search(account: MailAccount, secret: String, search: MailSearch): List<MailSummary> = withImap(account, secret) { session ->
        session.examine(search.folder)
        val criteria = ArrayList<String>()
        search.sinceDays?.takeIf { it > 0 }?.let {
            criteria.add("SINCE ${ImapSession.searchDate(Date(now().time - it * 86_400_000L))}")
        }
        if (search.unreadOnly) criteria.add("UNSEEN")
        val uids = session.uidSearch(if (criteria.isEmpty()) "ALL" else criteria.joinToString(" "))
        val window = uids.takeLast(SCAN_WINDOW)
        val summaries = window.chunked(100).flatMap { session.fetchSummaries(it) }
        val needle = search.query?.trim()?.lowercase().orEmpty()
        val matching = if (needle.isEmpty()) summaries else summaries.filter { s ->
            listOf(s.subject, s.from, s.to, s.cc).any { it.lowercase().contains(needle) }
        }
        matching.sortedByDescending { it.uid }.take(maxOf(1, search.limit))
    }

    public suspend fun read(account: MailAccount, secret: String, folder: String, uid: Long): MimeMessage {
        val raw = withImap(account, secret) { session ->
            session.examine(folder)
            session.fetchMessage(uid, MAX_MESSAGE_BYTES)
        }
        return Mime.parse(raw)
    }

    /** Returns the Message-ID that was sent. */
    public suspend fun send(account: MailAccount, secret: String, draft: MailDraft): String {
        val domain = account.address.substringAfterLast('@', "localhost")
        val messageId = "<${UUID.randomUUID()}@$domain>"
        val message = Mime.compose(account.address, draft.to, draft.cc, draft.subject, draft.body, draft.inReplyTo, now(), messageId)
        withSmtp(account, secret) { it.send(account.address, draft.to + draft.cc + draft.bcc, message) }
        return messageId
    }

    private suspend fun <T> withImap(account: MailAccount, secret: String, body: (ImapSession) -> T): T = withContext(Dispatchers.IO) {
        val (imap, _) = account.provider.servers(account.address) ?: throw MailException.invalid("不支持的邮箱地址 ${account.address}")
        val session = ImapSession(factory.connect(imap.host, imap.port))
        try {
            session.greeting()
            session.login(account.address, secret)
            session.identify()
            body(session)
        } finally {
            session.logout()
        }
    }

    private suspend fun <T> withSmtp(account: MailAccount, secret: String, body: (SmtpSession) -> T): T = withContext(Dispatchers.IO) {
        val (_, smtp) = account.provider.servers(account.address) ?: throw MailException.invalid("不支持的邮箱地址 ${account.address}")
        val session = SmtpSession(factory.connect(smtp.host, smtp.port))
        try {
            session.greeting()
            session.hello()
            session.login(account.address, secret)
            body(session)
        } finally {
            session.quit()
        }
    }

    public companion object {
        /** Newest messages a search looks at before filtering locally (avoids server CHARSET support). */
        public const val SCAN_WINDOW: Int = 300
        public const val MAX_MESSAGE_BYTES: Int = 8 shl 20
    }
}
