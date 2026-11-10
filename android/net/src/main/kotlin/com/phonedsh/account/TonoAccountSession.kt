// phone-dsh — :net / com.phonedsh.account: the tono-account session.
// SPDX-License-Identifier: MIT
//
// The Kotlin end of spec/v1/tono-account.md §2–§4, ported from
// `Sources/PhoneDSH/TonoAccount/TonoAccountSession.swift`. One object owns the
// session: the refresh token lives in one secret item and in memory, the
// access token only in memory. A refresh is single-flight (one in-flight
// future that every caller waits on); a rotated refresh token is written in
// one store write before the new access token is published; sign-in and
// sign-out start a new generation so a late refresh can neither write the
// store nor publish a token. The API is blocking because the gateway's key
// seam (`ModelKeySource.readKey`) is: callers are already on an IO thread.

package com.phonedsh.account

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.CompletableFuture
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** One exchange with the account service; throwing means "no answer". */
fun interface TonoAccountTransport {
    @Throws(IOException::class)
    fun send(request: TonoAccountRequest): TonoAccountAnswer
}

/** `HttpURLConnection` transport: no redirects, no caches, bounded body. */
class HttpUrlConnectionTonoAccountTransport(
    private val connectTimeoutMillis: Int = 10_000,
    private val readTimeoutMillis: Int = 20_000,
) : TonoAccountTransport {
    override fun send(request: TonoAccountRequest): TonoAccountAnswer {
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.requestMethod = request.method
            for ((name, value) in request.headers) connection.setRequestProperty(name, value)
            connection.doOutput = true
            // Buffered on purpose: the JDK connection drops a 401 body in
            // streaming mode, and these bodies are small.
            connection.outputStream.use { it.write(request.body) }
            val status = connection.responseCode
            val headers = LinkedHashMap<String, String>()
            for ((name, values) in connection.headerFields) {
                if (name != null) headers[name.lowercase()] = values.filterNotNull().joinToString(", ")
            }
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val body = stream?.use { input ->
                val bytes = input.readNBytes(MAX_BODY_BYTES + 1)
                if (bytes.size > MAX_BODY_BYTES) throw IOException("account answer too large")
                bytes
            } ?: ByteArray(0)
            return TonoAccountAnswer(status, headers, body)
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        const val MAX_BODY_BYTES: Int = 64 * 1024
    }
}

/** The four account-service operations, classified per §2. */
class TonoAccountClient(
    private val transport: TonoAccountTransport,
    val origin: String = TonoAccountProtocol.ACCOUNT_ORIGIN,
) {
    fun sendCode(phone: String): TonoOtpOutcome =
        TonoAccountProtocol.classifySendCode(exchange(TonoAccountProtocol.sendCodeRequest(phone, origin)))

    fun signIn(phone: String, challengeId: String, code: String, device: TonoDeviceInfo): TonoLoginOutcome =
        TonoAccountProtocol.classifySignIn(
            exchange(TonoAccountProtocol.signInRequest(phone, challengeId, code, device, origin)),
        )

    fun refresh(refreshToken: String): TonoRefreshOutcome =
        TonoAccountProtocol.classifyRefresh(exchange(TonoAccountProtocol.refreshRequest(refreshToken, origin)))

    /** Best effort; the answer is ignored by design. */
    fun signOut(accessToken: String) {
        exchange(TonoAccountProtocol.signOutRequest(accessToken, origin))
    }

    private fun exchange(request: TonoAccountRequest): TonoAccountAnswer? = try {
        transport.send(request)
    } catch (_: Exception) {
        null
    }
}

/** The one secret item holding the session record (§3); `save` replaces it in one write. */
interface TonoAccountStore {
    /** The stored bytes, `null` when absent. Throws when the store cannot be read. */
    @Throws(IOException::class)
    fun load(): ByteArray?

    @Throws(IOException::class)
    fun save(bytes: ByteArray)

    @Throws(IOException::class)
    fun delete()
}

/** The seam the model/search key sources use (spec §4). */
interface TonoAccessTokenSource {
    /**
     * A currently valid access token, refreshing when needed; `null` means
     * signed out (use the API-key path).
     *
     * @throws TonoAccountException while signed in when no token can be had.
     */
    @Throws(TonoAccountException::class)
    fun accessToken(): String?

    /** The service rejected [token]; the next call refreshes. */
    fun invalidate(token: String)

    /** Synchronous hint for launch decisions: a session record is present. */
    val hasSession: Boolean
}

enum class TonoAccountNotice { SESSION_ENDED, REVERIFY_REQUIRED }

/** What the page may show: no token and no full phone number. */
sealed interface TonoAccountState {
    data class SignedOut(val notice: TonoAccountNotice?) : TonoAccountState
    data class SignedIn(val phoneHint: String?, val signedInAtMs: Long, val reverifyAtMs: Long) : TonoAccountState
}

enum class TonoAccountFailure(val message: String) {
    INVALID_PHONE("请输入 11 位中国大陆手机号。"),
    INVALID_CODE("请输入短信里的数字验证码。"),
    WRONG_CODE("验证码错误或已过期，请重新获取。"),
    REJECTED("账号服务拒绝了这次请求。"),
    RATE_LIMITED("操作太频繁，请稍后再试。"),
    PROTOCOL_ERROR("账号服务返回了无法识别的结果，请稍后再试。"),
    TEMPORARILY_UNAVAILABLE("暂时连不上账号服务，请稍后再试。"),
    SESSION_ENDED("登录已失效，请重新登录。"),
    REVERIFY_REQUIRED("登录已满 180 天，请重新验证手机号。"),
}

/** A failure with a fixed, secret-free message. */
class TonoAccountException(val failure: TonoAccountFailure, val retryAfterSeconds: Int? = null) :
    Exception(
        if (failure == TonoAccountFailure.RATE_LIMITED && retryAfterSeconds != null) {
            "操作太频繁，请 $retryAfterSeconds 秒后再试。"
        } else {
            failure.message
        },
    )

/** A sent code waiting for the person to type it. `toString` hides the number. */
class TonoAccountChallenge internal constructor(val phone: String, val challengeId: String) {
    val phoneHint: String? get() = TonoAccountProtocol.phoneHint(phone)
    override fun toString(): String = "TonoAccountChallenge(phoneHint=$phoneHint)"
}

class TonoAccountSession(
    private val client: TonoAccountClient,
    private val store: TonoAccountStore,
    private val device: TonoDeviceInfo,
    private val clock: () -> Long = System::currentTimeMillis,
) : TonoAccessTokenSource {

    private class Access(val token: String, val issuedAtMs: Long, val expiresIn: Int)

    private sealed interface RefreshResult {
        data class Token(val token: String) : RefreshResult
        data class Failed(val failure: TonoAccountFailure) : RefreshResult
        data object Stale : RefreshResult
    }

    private val lock = Any()
    private var loaded = false
    private var record: TonoSessionRecord? = null
    private var access: Access? = null
    private var generation = 0L
    private var inFlight: Pair<Long, CompletableFuture<RefreshResult>>? = null
    private var persistPending = false
    private var notice: TonoAccountNotice? = null

    @Volatile
    private var sessionHint: Boolean? = null

    private val states = MutableStateFlow<TonoAccountState>(TonoAccountState.SignedOut(null))

    /** Every state change; read [state] once for the current value. */
    val stateFlow: StateFlow<TonoAccountState> get() {
        synchronized(lock) { loadIfNeededLocked(); publishLocked() }
        return states.asStateFlow()
    }

    val state: TonoAccountState get() = synchronized(lock) { loadIfNeededLocked(); currentStateLocked() }

    override val hasSession: Boolean get() {
        sessionHint?.let { return it }
        val present = try {
            store.load()?.let { TonoAccountProtocol.decodeRecord(it) } != null
        } catch (_: Exception) {
            false
        }
        if (sessionHint == null) sessionHint = present
        return present
    }

    fun clearNotice() = synchronized(lock) {
        if (notice != null) {
            notice = null
            publishLocked()
        }
    }

    // ---- sign in / out

    @Throws(TonoAccountException::class)
    fun requestCode(rawPhone: String): TonoAccountChallenge {
        val phone = TonoAccountProtocol.canonicalPhone(rawPhone)
            ?: throw TonoAccountException(TonoAccountFailure.INVALID_PHONE)
        return when (val outcome = client.sendCode(phone)) {
            is TonoOtpOutcome.Challenge -> TonoAccountChallenge(phone, outcome.challengeId)
            TonoOtpOutcome.ProtocolError -> throw TonoAccountException(TonoAccountFailure.PROTOCOL_ERROR)
            TonoOtpOutcome.Rejected -> throw TonoAccountException(TonoAccountFailure.REJECTED)
            is TonoOtpOutcome.RateLimited ->
                throw TonoAccountException(TonoAccountFailure.RATE_LIMITED, outcome.retryAfterSeconds)
            TonoOtpOutcome.Transient -> throw TonoAccountException(TonoAccountFailure.TEMPORARILY_UNAVAILABLE)
        }
    }

    @Throws(TonoAccountException::class)
    fun signIn(challenge: TonoAccountChallenge, rawCode: String) {
        val code = TonoAccountProtocol.canonicalCode(rawCode)
            ?: throw TonoAccountException(TonoAccountFailure.INVALID_CODE)
        when (val outcome = client.signIn(challenge.phone, challenge.challengeId, code, device)) {
            is TonoLoginOutcome.SignedIn -> synchronized(lock) {
                loadIfNeededLocked()
                val nowMs = clock()
                generation++
                inFlight = null
                val grant = outcome.grant
                val fresh = TonoSessionRecord(grant.refreshToken, nowMs, grant.userId, grant.phoneHint ?: challenge.phoneHint)
                record = fresh
                persistLocked(fresh)
                access = Access(grant.accessToken, nowMs, grant.expiresIn)
                notice = null
                publishLocked()
            }
            TonoLoginOutcome.ProtocolError -> throw TonoAccountException(TonoAccountFailure.PROTOCOL_ERROR)
            TonoLoginOutcome.InvalidCode -> throw TonoAccountException(TonoAccountFailure.WRONG_CODE)
            TonoLoginOutcome.Rejected -> throw TonoAccountException(TonoAccountFailure.REJECTED)
            is TonoLoginOutcome.RateLimited ->
                throw TonoAccountException(TonoAccountFailure.RATE_LIMITED, outcome.retryAfterSeconds)
            TonoLoginOutcome.Transient -> throw TonoAccountException(TonoAccountFailure.TEMPORARILY_UNAVAILABLE)
        }
    }

    /** §3 sign-out: local state is cleared first and unconditionally; the server call is best effort. */
    fun signOut() {
        val token = synchronized(lock) {
            loadIfNeededLocked()
            val current = access
            val held = record
            val usable = current != null && held != null &&
                TonoAccountProtocol.clockDecision(current.issuedAtMs, current.expiresIn, held.loginAtMs, clock()) ==
                TonoClockDecision.USE
            endLocally(null)
            if (usable) current?.token else null
        }
        if (token != null) client.signOut(token)
    }

    // ---- TonoAccessTokenSource

    override fun accessToken(): String? {
        while (true) {
            val future: CompletableFuture<RefreshResult>
            var owner: Pair<Long, String>? = null
            synchronized(lock) {
                loadIfNeededLocked()
                val held = record ?: return null
                val nowMs = clock()
                val current = access
                if (current != null) {
                    when (TonoAccountProtocol.clockDecision(current.issuedAtMs, current.expiresIn, held.loginAtMs, nowMs)) {
                        TonoClockDecision.USE -> return current.token
                        TonoClockDecision.REVERIFY_REQUIRED -> {
                            endLocally(TonoAccountNotice.REVERIFY_REQUIRED)
                            throw TonoAccountException(TonoAccountFailure.REVERIFY_REQUIRED)
                        }
                        TonoClockDecision.REFRESH -> Unit
                    }
                } else if (nowMs - held.loginAtMs >= TonoAccountProtocol.REVERIFY_AFTER_SECONDS * 1000) {
                    endLocally(TonoAccountNotice.REVERIFY_REQUIRED)
                    throw TonoAccountException(TonoAccountFailure.REVERIFY_REQUIRED)
                }
                val running = inFlight
                if (running != null && running.first == generation) {
                    future = running.second
                } else {
                    future = CompletableFuture()
                    inFlight = generation to future
                    owner = generation to held.refreshToken
                    if (persistPending) persistLocked(held)
                }
            }
            owner?.let { (gen, refreshToken) -> future.complete(performRefresh(gen, refreshToken)) }
            when (val result = future.join()) {
                is RefreshResult.Token -> return result.token
                is RefreshResult.Failed -> throw TonoAccountException(result.failure)
                RefreshResult.Stale -> continue
            }
        }
    }

    override fun invalidate(token: String) = synchronized(lock) {
        if (access?.token == token) access = null
    }

    private fun performRefresh(gen: Long, refreshToken: String): RefreshResult {
        val outcome = client.refresh(refreshToken)
        synchronized(lock) {
            if (inFlight?.first == gen) inFlight = null
            val current = record
            if (gen != generation || current == null) return RefreshResult.Stale
            return when (outcome) {
                is TonoRefreshOutcome.Rotated -> {
                    val grant = outcome.grant
                    val rotated = TonoSessionRecord(
                        grant.refreshToken, current.loginAtMs,
                        grant.userId ?: current.userId, grant.phoneHint ?: current.phoneHint,
                    )
                    // The old refresh token is already invalid on the server.
                    record = rotated
                    persistLocked(rotated)
                    access = Access(grant.accessToken, clock(), grant.expiresIn)
                    RefreshResult.Token(grant.accessToken)
                }
                TonoRefreshOutcome.SessionEnded -> {
                    endLocally(TonoAccountNotice.SESSION_ENDED)
                    RefreshResult.Failed(TonoAccountFailure.SESSION_ENDED)
                }
                TonoRefreshOutcome.Transient -> RefreshResult.Failed(TonoAccountFailure.TEMPORARILY_UNAVAILABLE)
            }
        }
    }

    // ---- state (all under lock)

    private fun currentStateLocked(): TonoAccountState {
        val held = record ?: return TonoAccountState.SignedOut(notice)
        return TonoAccountState.SignedIn(
            phoneHint = held.phoneHint,
            signedInAtMs = held.loginAtMs,
            reverifyAtMs = held.loginAtMs + TonoAccountProtocol.REVERIFY_AFTER_SECONDS * 1000,
        )
    }

    private fun loadIfNeededLocked() {
        if (loaded) return
        val bytes = try {
            store.load()
        } catch (_: Exception) {
            // Locked or unreadable store: stay unloaded and read again later.
            return
        }
        loaded = true
        // An unreadable record is signed out and kept until sign-in or sign-out.
        record = bytes?.let { TonoAccountProtocol.decodeRecord(it) }
        sessionHint = record != null
    }

    private fun persistLocked(value: TonoSessionRecord) {
        persistPending = try {
            store.save(TonoAccountProtocol.encodeRecord(value))
            false
        } catch (_: Exception) {
            true
        }
        sessionHint = true
    }

    private fun endLocally(reason: TonoAccountNotice?) {
        generation++
        inFlight = null
        record = null
        access = null
        persistPending = false
        loaded = true
        runCatching { store.delete() }
        sessionHint = false
        notice = reason
        publishLocked()
    }

    private fun publishLocked() {
        states.value = currentStateLocked()
    }
}
