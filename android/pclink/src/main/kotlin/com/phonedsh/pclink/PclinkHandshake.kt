// SPDX-License-Identifier: MIT
// Phone-side E2E handshake driver (§5.1-§5.3) and the verified `peer.hello`
// model (§5.6). C2 freezes this seam for C4: `PclinkE2eSession` is the session
// state machine, `PclinkHandshake` only orchestrates one fresh handshake.
package com.phonedsh.pclink

import java.time.Duration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/** Verified `peer.hello` display/build facts; never used for routing or authorization. */
class PclinkPeerHello private constructor(
    val role: String,
    val caps: List<String>,
    val dshVersionText: String,
    val dshVersion: PclinkValidation.SemVer,
    val dshCommit: String?,
    val appName: String,
    val appVersion: String,
    val name: String,
    private val raw: PclinkJson,
) {
    val json: PclinkJson get() = raw

    val supportsPclink: Boolean get() = PclinkWire.supportsPclink(caps)

    /** Out-of-range DSH versions only produce a UI warning, never a failed connection. */
    val versionWarning: Boolean get() = !PclinkValidation.dshVersionInTestedRange(dshVersion)

    companion object {
        fun parse(value: PclinkJson, expectedRole: String): PclinkPeerHello {
            PclinkWire.validatePeerHello(value, expectedRole)
            val dsh = value["dsh"]?.closedObject(required = setOf("version"), optional = setOf("commit"))
                ?: throw PclinkError.BadFrame("missing dsh")
            val versionText = value["dsh"]?.requiredString("version")
                ?: throw PclinkError.BadFrame("dsh.version is missing")
            val version = PclinkValidation.SemVer.parse(versionText)
                ?: throw PclinkError.BadFrame("dsh.version is not SemVer")
            val app = value["app"]?.closedObject(setOf("name", "version"))
                ?: throw PclinkError.BadFrame("missing app")
            return PclinkPeerHello(
                role = value.requiredString("role"),
                caps = value["caps"]?.arrayValue?.map { it.stringValue!! } ?: emptyList(),
                dshVersionText = versionText,
                dshVersion = version,
                dshCommit = dsh["commit"]?.stringValue,
                appName = app["name"]?.stringValue ?: throw PclinkError.BadFrame("app.name"),
                appVersion = app["version"]?.stringValue ?: throw PclinkError.BadFrame("app.version"),
                name = value.requiredString("name"),
                raw = value,
            )
        }

        fun make(
            role: String,
            caps: List<String>,
            dshVersion: String,
            dshCommit: String?,
            appName: String,
            appVersion: String,
            name: String,
        ): PclinkPeerHello {
            val dshMembers = LinkedHashMap<String, PclinkJson>()
            dshMembers["version"] = PclinkJson.Text(dshVersion)
            dshCommit?.let { dshMembers["commit"] = PclinkJson.Text(it) }
            val value = pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("peer.hello"),
                "role" to PclinkJson.Text(role),
                "caps" to PclinkJson.Array(caps.map { PclinkJson.Text(it) }),
                "dsh" to PclinkJson.Object(dshMembers),
                "app" to pclinkObject(
                    "name" to PclinkJson.Text(appName),
                    "version" to PclinkJson.Text(appVersion),
                ),
                "name" to PclinkJson.Text(name),
            )
            return parse(value, role)
        }
    }
}

/**
 * Outcome of one phone-initiated handshake. `Closed` is the allowed pre-hello
 * `session.close` abort; it is not an established session.
 */
sealed interface PclinkHandshakeOutcome {
    data class Established(
        val session: PclinkE2eSession,
        val hello: PclinkPeerHello,
    ) : PclinkHandshakeOutcome

    data class Rejected(
        val verification: PclinkRejectVerification,
        val code: String,
        val message: String,
    ) : PclinkHandshakeOutcome

    data class Closed(val code: String, val message: String) : PclinkHandshakeOutcome

    data class Failed(val error: PclinkError) : PclinkHandshakeOutcome
}

/**
 * Drives exactly one fresh [PclinkE2eSession] from `session.init` to the PC's
 * first AEAD `peer.hello`. The caller owns the relay link and feeds every
 * `e2e.handshake`/`e2e` frame to [handle]; [run] sends `session.init` and waits
 * for the terminal outcome. The ephemeral private key is zeroed on failure by
 * [PclinkE2eSession.markClosed].
 */
class PclinkHandshake(
    val session: PclinkE2eSession,
    private val phoneHello: PclinkPeerHello,
    private val sendFrame: suspend (PclinkJson) -> Unit,
) {
    enum class Phase { AWAITING_RESP, AWAITING_HELLO, ESTABLISHED, FAILED }

    private val outcome = CompletableDeferred<PclinkHandshakeOutcome>()
    private var phase = Phase.AWAITING_RESP

    val sid: String get() = session.sid

    suspend fun run(timeout: Duration): PclinkHandshakeOutcome {
        if (outcome.isCompleted) return outcome.await()
        try {
            sendFrame(session.initFrame)
        } catch (error: PclinkError) {
            return fail(error)
        } catch (error: Exception) {
            return fail(PclinkError.PeerOffline())
        }
        return try {
            withTimeout(timeout.toMillis()) { outcome.await() }
        } catch (_: TimeoutCancellationException) {
            fail(PclinkError.Unavailable("handshake timed out"))
        }
    }

    /**
     * Processes one relay frame for this handshake. Returns false when the
     * frame belongs to another sid (the caller drops it). A malformed frame
     * for this sid fails this handshake and never touches the pairing record.
     */
    suspend fun handle(frame: PclinkJson): Boolean {
        if (outcome.isCompleted) return false
        val outerSid = frame["sid"]?.stringValue ?: return false
        if (outerSid != session.sid) return false
        val type = frame["type"]?.stringValue ?: return false
        try {
            when (phase) {
                Phase.AWAITING_RESP -> when (type) {
                    "e2e.handshake" -> handleHandshakeFrame(frame)
                    else -> fail(PclinkError.BadFrame("expected e2e.handshake"))
                }
                Phase.AWAITING_HELLO -> when (type) {
                    "e2e" -> handleFirstInnerFrame(frame)
                    "e2e.handshake" -> fail(PclinkError.BadFrame("unexpected handshake message"))
                    else -> fail(PclinkError.BadFrame("expected an e2e frame"))
                }
                Phase.ESTABLISHED, Phase.FAILED -> Unit
            }
        } catch (error: PclinkError) {
            fail(error)
        } catch (error: Exception) {
            fail(PclinkError.BadFrame("handshake frame handling failed: ${error.message}"))
        }
        return true
    }

    private suspend fun handleHandshakeFrame(frame: PclinkJson) {
        val body = frame["body"] ?: throw PclinkError.BadFrame("missing handshake body")
        when (body["type"]?.stringValue) {
            "session.resp" -> {
                session.acceptResp(frame)
                val confirm = session.confirmFrame()
                val helloFrame = session.makePeerHelloFrame(phoneHello)
                phase = Phase.AWAITING_HELLO
                sendFrame(confirm)
                sendFrame(helloFrame)
            }
            "session.reject" -> {
                PclinkWire.validateE2EHandshake(frame)
                val result = session.verifyReject(body)
                session.markClosed()
                phase = Phase.FAILED
                val code = body["code"]?.stringValue ?: "bad_frame"
                val message = body["message"]?.stringValue ?: ""
                outcome.complete(PclinkHandshakeOutcome.Rejected(result, code, message))
            }
            else -> fail(PclinkError.BadFrame("unexpected handshake body"))
        }
    }

    private fun handleFirstInnerFrame(frame: PclinkJson) {
        val decoded = session.open(frame)
        if (!session.peerHelloReceived) {
            if (decoded.inner["type"]?.stringValue == "session.close") {
                val close = decoded.inner.closedObject(
                    required = setOf("type", "code"),
                    optional = setOf("message"),
                )
                val code = close["code"]?.stringValue
                    ?: throw PclinkError.BadFrame("session.close code")
                val message = close["message"]?.stringValue ?: ""
                PclinkValidation.displayText(message, "session.close message", 512)
                session.markClosed()
                phase = Phase.FAILED
                outcome.complete(PclinkHandshakeOutcome.Closed(code, message))
                return
            }
            val hello = session.acceptFirstInner(decoded.inner)
            phase = Phase.ESTABLISHED
            outcome.complete(PclinkHandshakeOutcome.Established(session, hello))
            return
        }
        fail(PclinkError.BadFrame("duplicate peer.hello"))
    }

    fun fail(error: PclinkError): PclinkHandshakeOutcome {
        session.markClosed()
        phase = Phase.FAILED
        val failed = PclinkHandshakeOutcome.Failed(error)
        outcome.complete(failed)
        return failed
    }
}
