// SPDX-License-Identifier: MIT
// PCLink v1 phone-side end-to-end session (§5). C2 freezes this class for C4:
// one fresh X25519 ephemeral per handshake, pinned-key signatures, separate
// traffic/confirmation keys, strict sequence/replay rules and AEAD AAD.
package com.phonedsh.pclink

import java.time.Instant

/** Injectable soft/hard limits; defaults are the frozen §5.4 values. */
data class PclinkSessionThresholds(
    val softFrames: Long = PclinkLimits.SOFT_FRAME_THRESHOLD,
    val hardFrames: Long = PclinkLimits.HARD_FRAME_THRESHOLD,
    val softBytes: Long = PclinkLimits.SOFT_BYTE_THRESHOLD,
    val hardBytes: Long = PclinkLimits.HARD_BYTE_THRESHOLD,
) {
    companion object {
        val v1 = PclinkSessionThresholds()
    }
}

enum class PclinkSeqDecision { ACCEPT, REPLAY, BAD_FRAME, SESSION_EXPIRED }

object PclinkSeqValidator {
    /**
     * Strictly contiguous per direction; the hard frame/byte caps win before
     * the contiguity check (§5.4). The first frame is always seq 0.
     */
    fun evaluate(
        first: Boolean,
        lastSeq: Long?,
        seq: Long,
        bytes: Long,
        thresholds: PclinkSessionThresholds = PclinkSessionThresholds.v1,
    ): PclinkSeqDecision {
        if (seq < 0 || seq >= thresholds.hardFrames) return PclinkSeqDecision.SESSION_EXPIRED
        if (bytes >= thresholds.hardBytes) return PclinkSeqDecision.SESSION_EXPIRED
        if (first || lastSeq == null) {
            return if (seq == 0L) PclinkSeqDecision.ACCEPT else PclinkSeqDecision.BAD_FRAME
        }
        if (seq <= lastSeq) return PclinkSeqDecision.REPLAY
        if (seq != lastSeq + 1) return PclinkSeqDecision.BAD_FRAME
        return PclinkSeqDecision.ACCEPT
    }
}

data class PclinkDecodedFrame(
    val inner: PclinkJson,
    val seq: Long,
    val outer: PclinkJson,
)

enum class PclinkSessionPhase { AWAITING_RESP, AWAITING_HELLO, ESTABLISHED, CLOSED }

sealed interface PclinkRejectVerification {
    data class Verified(val code: String, val message: String) : PclinkRejectVerification
    data class Unauthenticated(val code: String, val message: String) : PclinkRejectVerification
}

/** Phone-side policy after a `session.reject` (§5.2/§5.5). */
enum class PclinkRejectHandling { PROMPT, KEEP_RECORD }

object PclinkRejectPolicy {
    /**
     * Only a verified, th1-matching signed `unpaired` reject may prompt the
     * user to remove the local record. Every other outcome keeps it.
     */
    fun decide(
        verified: Boolean,
        code: String,
        th1Matches: Boolean,
        hasRecord: Boolean,
    ): PclinkRejectHandling =
        if (verified && th1Matches && code == "unpaired" && hasRecord) {
            PclinkRejectHandling.PROMPT
        } else {
            PclinkRejectHandling.KEEP_RECORD
        }
}

/**
 * The phone side of one E2E session. This is the frozen C4 seam: C4 reads
 * [phase]/[keys]/[sid] and calls [seal]/[open]; it must not derive keys or
 * build a frame on its own. Traffic key material never appears in `toString`.
 */
class PclinkE2eSession private constructor(
    val identity: PclinkIdentity,
    val peer: PclinkPairingRecord,
    val sidBytes: ByteArray,
    private val ephemeral: PclinkCrypto.EphemeralKey,
    val phoneNonce: ByteArray,
    val thresholds: PclinkSessionThresholds,
    private val now: () -> Instant,
) {
    val sid: String = PclinkBase64Url.encode(sidBytes)

    @Volatile
    var phase: PclinkSessionPhase = PclinkSessionPhase.AWAITING_RESP
        private set

    @Volatile
    var keys: PclinkCrypto.SessionKeys? = null
        private set

    @Volatile
    var th2: ByteArray? = null
        private set

    @Volatile
    var th3: ByteArray? = null
        private set

    @Volatile
    var sentFrames: Long = 0
        private set

    @Volatile
    var sentBytes: Long = 0
        private set

    @Volatile
    var receivedFrames: Long = 0
        private set

    @Volatile
    var receivedBytes: Long = 0
        private set

    @Volatile
    var lastReceivedSeq: Long? = null
        private set

    @Volatile
    var peerHelloReceived: Boolean = false
        private set

    @Volatile
    var needsRekey: Boolean = false
        private set

    @Volatile
    var establishedAt: Instant? = null
        private set

    private val initTranscript: ByteArray = PclinkCrypto.sessionInitTranscript(
        phoneMachineId = identity.machineId,
        pcMachineId = peer.peerMachineId,
        sid = sidBytes,
        ephPhone = ephemeral.publicKey,
        noncePhone = phoneNonce,
    )

    val th1: ByteArray = PclinkCrypto.sha256(initTranscript)

    val ephemeralPublicKey: ByteArray get() = ephemeral.publicKey

    @Volatile
    var ephemeralPrivateRetained: Boolean = true
        private set

    init {
        if (sidBytes.size != 16 || ephemeral.privateKey.size != 32 ||
            ephemeral.publicKey.size != 32 || phoneNonce.size != 32
        ) {
            throw PclinkError.BadFrame("session sid/eph/nonce length")
        }
    }

    constructor(
        identity: PclinkIdentity,
        peer: PclinkPairingRecord,
        thresholds: PclinkSessionThresholds = PclinkSessionThresholds.v1,
    ) : this(
        identity = identity,
        peer = peer,
        sidBytes = PclinkRandom.bytes(16),
        ephemeral = PclinkCrypto.generateX25519(),
        phoneNonce = PclinkRandom.bytes(32),
        thresholds = thresholds,
        now = Instant::now,
    )

    /**
     * Deterministic form used by the shared golden vectors and tests. A fresh
     * ephemeral key must still be generated for every production handshake.
     */
    constructor(
        identity: PclinkIdentity,
        peer: PclinkPairingRecord,
        sidBytes: ByteArray,
        ephemeral: PclinkCrypto.EphemeralKey,
        phoneNonce: ByteArray,
        thresholds: PclinkSessionThresholds = PclinkSessionThresholds.v1,
    ) : this(
        identity = identity,
        peer = peer,
        sidBytes = sidBytes,
        ephemeral = ephemeral,
        phoneNonce = phoneNonce,
        thresholds = thresholds,
        now = Instant::now,
    )

    val initBody: PclinkJson
        get() = pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("session.init"),
            "sid" to PclinkJson.Text(sid),
            "suite" to PclinkJson.Text(PclinkCrypto.SUITE),
            "eph" to PclinkJson.Text(PclinkBase64Url.encode(ephemeral.publicKey)),
            "nonce" to PclinkJson.Text(PclinkBase64Url.encode(phoneNonce)),
        )

    val initFrame: PclinkJson get() = handshakeFrame(initBody)

    fun handshakeFrame(body: PclinkJson): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("e2e.handshake"),
        "sid" to PclinkJson.Text(sid),
        "from" to PclinkJson.Text(identity.machineId),
        "to" to PclinkJson.Text(peer.peerMachineId),
        "body" to body,
    )

    /**
     * Verifies the PC's `session.resp`: pinned-key signature, transcript hash,
     * X25519 secret and PC confirmation, then installs the four §5.3 keys.
     */
    fun acceptResp(outer: PclinkJson) {
        if (phase != PclinkSessionPhase.AWAITING_RESP) {
            throw PclinkError.BadFrame("session.resp out of order")
        }
        PclinkWire.validateE2EHandshake(outer)
        val outerSid = outer.requiredString("sid")
        val body = outer["body"] ?: throw PclinkError.BadFrame("missing body")
        val bodySid = body.requiredString("sid")
        PclinkHandshakeSid.requireMatch(this.sid, outerSid, bodySid)
        if (outer.requiredString("from") != peer.peerMachineId ||
            outer.requiredString("to") != identity.machineId
        ) {
            throw PclinkError.BadFrame("session.resp direction mismatch")
        }
        if (body.requiredString("type") != "session.resp") {
            throw PclinkError.BadFrame("not a session.resp")
        }
        val ephPc = PclinkBase64Url.decode(body.requiredString("eph"), 32)
        val noncePc = PclinkBase64Url.decode(body.requiredString("nonce"), 32)
        val signature = PclinkBase64Url.decode(body.requiredString("sig"), 64)
        val confirmPc = PclinkBase64Url.decode(body.requiredString("confirm"), 32)
        if (ephPc.all { it == 0.toByte() }) {
            throw PclinkError.AuthFailed("PC ephemeral key is all zero")
        }
        val respTranscript = PclinkCrypto.sessionRespTranscript(th1, ephPc, noncePc)
        if (!PclinkCrypto.ed25519Verify(peer.peerPublicKey, respTranscript, signature)) {
            throw PclinkError.AuthFailed("session.resp signature is invalid")
        }
        val derivedTh2 = PclinkCrypto.sha256(respTranscript)
        val dh = PclinkCrypto.x25519SharedSecret(ephemeral.privateKey, ephPc)
        val derivedKeys = PclinkCrypto.sessionKeys(dh, derivedTh2)
        val expectedConfirm = PclinkCrypto.confirmation(derivedKeys.confirmPC, derivedTh2)
        if (!PclinkCrypto.constantTimeEquals(expectedConfirm, confirmPc)) {
            throw PclinkError.AuthFailed("PC key confirmation is invalid")
        }
        keys = derivedKeys
        th2 = derivedTh2
        phase = PclinkSessionPhase.AWAITING_HELLO
    }

    fun confirmFrame(): PclinkJson {
        val activeKeys = keys ?: throw PclinkError.BadFrame("keys are not installed")
        val activeTh2 = th2 ?: throw PclinkError.BadFrame("keys are not installed")
        val confirmTranscript = PclinkCrypto.sessionConfirmTranscript(
            th2 = activeTh2,
            phoneMachineId = identity.machineId,
            pcMachineId = peer.peerMachineId,
            sid = sidBytes,
        )
        val signature = identity.sign(confirmTranscript)
        val derivedTh3 = PclinkCrypto.sha256(confirmTranscript)
        val confirm = PclinkCrypto.confirmation(activeKeys.confirmPhone, derivedTh3)
        th3 = derivedTh3
        return handshakeFrame(
            pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("session.confirm"),
                "sid" to PclinkJson.Text(sid),
                "sig" to PclinkJson.Text(PclinkBase64Url.encode(signature)),
                "confirm" to PclinkJson.Text(PclinkBase64Url.encode(confirm)),
            ),
        )
    }

    /** The phone's first AEAD frame; it must be `peer.hello` (§5.5). */
    fun makePeerHelloFrame(hello: PclinkPeerHello): PclinkJson {
        if (phase != PclinkSessionPhase.AWAITING_HELLO || keys == null || peerHelloReceived) {
            throw PclinkError.BadFrame("peer.hello out of order")
        }
        return seal(hello.json)
    }

    /**
     * The PC's first AEAD frame must be `peer.hello`; validates capabilities
     * and exposes the DSH build facts. No capability intersection is
     * `version_unsupported`; an out-of-range DSH version is only a warning.
     */
    fun acceptFirstInner(inner: PclinkJson): PclinkPeerHello {
        if (phase != PclinkSessionPhase.AWAITING_HELLO || peerHelloReceived) {
            throw PclinkError.BadFrame("first inner message is not peer.hello")
        }
        val hello = PclinkPeerHello.parse(inner, expectedRole = "pc")
        if (!hello.supportsPclink) {
            throw PclinkError.VersionUnsupported("no workspace/1 + suite capability intersection")
        }
        peerHelloReceived = true
        phase = PclinkSessionPhase.ESTABLISHED
        establishedAt = now()
        return hello
    }

    /** Seals exactly one inner message and allocates the next outbound `seq`. */
    fun seal(inner: PclinkJson): PclinkJson {
        val activeKeys = keys ?: throw PclinkError.SessionExpired("keys are not installed")
        if (phase == PclinkSessionPhase.CLOSED) {
            throw PclinkError.SessionExpired("session is closed")
        }
        if (sentFrames >= thresholds.hardFrames || sentBytes >= thresholds.hardBytes) {
            throw PclinkError.SessionExpired("hard session cap reached")
        }
        val plaintext = PclinkJsonEncoder.encode(inner)
        val seq = sentFrames
        val nonce = PclinkCrypto.aeadNonce(seq)
        val aad = PclinkCrypto.aad(sid, seq, identity.machineId, peer.peerMachineId)
        val body = PclinkCrypto.aeadSeal(plaintext, activeKeys.phoneToPC, nonce, aad)
        sentFrames += 1
        sentBytes += plaintext.size.toLong()
        if (sentFrames >= thresholds.softFrames || sentBytes >= thresholds.softBytes) {
            needsRekey = true
        }
        return pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("e2e"),
            "sid" to PclinkJson.Text(sid),
            "seq" to PclinkJson.Integer(seq),
            "from" to PclinkJson.Text(identity.machineId),
            "to" to PclinkJson.Text(peer.peerMachineId),
            "body" to PclinkJson.Text(PclinkBase64Url.encode(body)),
        )
    }

    /**
     * Opens one received AEAD frame. The seq decision is made before AEAD so a
     * replay/gap is reported as `replay`/`bad_frame`, never `auth_failed`; a
     * tag failure on an in-order frame is `auth_failed` (§5.4).
     */
    fun open(outer: PclinkJson): PclinkDecodedFrame {
        if (phase == PclinkSessionPhase.CLOSED) {
            throw PclinkError.SessionExpired("session is closed")
        }
        val objectValue = outer.closedObject(setOf("v", "type", "sid", "seq", "from", "to", "body"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "e2e") {
            throw PclinkError.BadFrame("not an e2e frame")
        }
        val outerSid = outer.requiredString("sid")
        if (!PclinkValidation.isSessionId(outerSid)) throw PclinkError.BadFrame("bad sid")
        if (outerSid != sid) throw PclinkError.Replay("frame for an unknown sid")
        val from = outer.requiredString("from")
        val to = outer.requiredString("to")
        if (from != peer.peerMachineId || to != identity.machineId) {
            throw PclinkError.AuthFailed("e2e direction mismatch")
        }
        val seq = objectValue["seq"]?.longValue ?: throw PclinkError.BadFrame("e2e seq")
        if (seq < 0 || seq >= thresholds.hardFrames) {
            throw PclinkError.SessionExpired("seq hard cap")
        }
        val body = PclinkBase64Url.decode(outer.requiredString("body"))
        if (body.size < 16) throw PclinkError.BadFrame("AEAD body too short")
        val plaintextBytes = (body.size - 16).toLong()
        val first = lastReceivedSeq == null
        val decision = PclinkSeqValidator.evaluate(
            first = first,
            lastSeq = lastReceivedSeq,
            seq = seq,
            bytes = receivedBytes + plaintextBytes,
            thresholds = thresholds,
        )
        when (decision) {
            PclinkSeqDecision.ACCEPT -> Unit
            PclinkSeqDecision.REPLAY -> throw PclinkError.Replay("seq did not advance")
            PclinkSeqDecision.BAD_FRAME -> throw PclinkError.BadFrame("seq gap")
            PclinkSeqDecision.SESSION_EXPIRED -> throw PclinkError.SessionExpired("hard session cap reached")
        }
        val activeKeys = keys ?: throw PclinkError.BadFrame("keys are not installed")
        val nonce = PclinkCrypto.aeadNonce(seq)
        val aad = PclinkCrypto.aad(sid, seq, from, to)
        val plaintext = try {
            PclinkCrypto.aeadOpen(body, activeKeys.pcToPhone, nonce, aad)
        } catch (_: PclinkError) {
            throw PclinkError.AuthFailed("AEAD tag verification failed")
        }
        val inner = try {
            PclinkJsonParser.parseObject(plaintext)
        } catch (error: PclinkError) {
            throw PclinkError.BadFrame("inner message is not one JSON object: ${error.message}")
        }
        lastReceivedSeq = seq
        receivedFrames += 1
        receivedBytes += plaintext.size.toLong()
        if (receivedFrames >= thresholds.softFrames || receivedBytes >= thresholds.softBytes) {
            needsRekey = true
        }
        return PclinkDecodedFrame(inner = inner, seq = seq, outer = outer)
    }

    /** Verifies a `session.reject` against the pinned PC key and this th1 (§5.2). */
    fun verifyReject(body: PclinkJson): PclinkRejectVerification {
        val objectValue = try {
            body.closedObject(
                required = setOf("v", "type", "sid", "code"),
                optional = setOf("message", "sig"),
            )
        } catch (_: PclinkError) {
            return PclinkRejectVerification.Unauthenticated("bad_frame", "malformed session.reject")
        }
        if (objectValue["v"]?.longValue != 1L ||
            objectValue["type"]?.stringValue != "session.reject" ||
            objectValue["sid"]?.stringValue != sid
        ) {
            return PclinkRejectVerification.Unauthenticated("bad_frame", "malformed session.reject")
        }
        val code = objectValue["code"]?.stringValue
            ?: return PclinkRejectVerification.Unauthenticated("bad_frame", "malformed session.reject")
        if (code !in PclinkWire.sessionRejectCodes || code.indexOf('\u0000') >= 0) {
            return PclinkRejectVerification.Unauthenticated("bad_frame", "malformed session.reject")
        }
        val message = objectValue["message"]?.stringValue ?: ""
        if (message.indexOf('\u0000') >= 0 ||
            message.toByteArray(Charsets.UTF_8).size > 512
        ) {
            return PclinkRejectVerification.Unauthenticated("bad_frame", "malformed session.reject")
        }
        val signatureText = objectValue["sig"]?.stringValue
            ?: return PclinkRejectVerification.Unauthenticated(code, message)
        val signature = try {
            PclinkBase64Url.decode(signatureText, 64)
        } catch (_: PclinkError) {
            return PclinkRejectVerification.Unauthenticated(code, message)
        }
        val transcript = PclinkCrypto.sessionRejectTranscript(th1, code)
        return if (PclinkCrypto.ed25519Verify(peer.peerPublicKey, transcript, signature)) {
            PclinkRejectVerification.Verified(code, message)
        } else {
            PclinkRejectVerification.Unauthenticated(code, message)
        }
    }

    fun closeFrame(code: String, message: String? = null): PclinkJson {
        val members = LinkedHashMap<String, PclinkJson>()
        members["type"] = PclinkJson.Text("session.close")
        members["code"] = PclinkJson.Text(code)
        message?.let { members["message"] = PclinkJson.Text(it) }
        return seal(PclinkJson.Object(members))
    }

    /** Destroys this session's keys and ephemeral private scalar. */
    fun markClosed() {
        phase = PclinkSessionPhase.CLOSED
        keys = null
        ephemeral.privateKey.fill(0)
        ephemeralPrivateRetained = false
    }

    override fun toString(): String =
        "PclinkE2eSession(sid=$sid, phase=$phase, peer=${peer.peerMachineId})"

    companion object {
        /** Standalone reject signature check used by the shared negative vectors. */
        fun verifyRejectSignature(
            signature: ByteArray,
            code: String,
            th1: ByteArray,
            pcPublicKey: ByteArray,
        ): Boolean = PclinkCrypto.ed25519Verify(
            pcPublicKey,
            PclinkCrypto.sessionRejectTranscript(th1, code),
            signature,
        )
    }
}

/**
 * Sid classification shared by every handshake message (§5.2): an outer/body
 * mismatch is `bad_frame`; a well-formed message for another handshake is
 * `replay`, never a new session.
 */
object PclinkHandshakeSid {
    fun requireMatch(expectedSid: String, outerSid: String, bodySid: String) {
        if (outerSid != bodySid) throw PclinkError.BadFrame("handshake body sid does not match the carrier")
        if (outerSid != expectedSid) throw PclinkError.Replay("handshake sid mismatch")
    }
}
