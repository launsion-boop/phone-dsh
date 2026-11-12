// SPDX-License-Identifier: MIT
// In-memory PC endpoint used by the C2 pairing/E2E tests. It speaks the real
// PclinkCrypto bytes in both directions (the phone still runs the production
// PclinkE2eSession), so the tests are not comparing two hand-written copies.
package com.phonedsh.pclink

import java.util.concurrent.CopyOnWriteArrayList

class FakePc(
    val pcIdentity: PclinkIdentity,
    val origin: String,
    val pcName: String = "My PC",
    val phoneMachineId: String? = null,
    phonePublicKey: ByteArray? = null,
    val pairingOffer: PclinkPairingOffer? = null,
    val autoConfirmPairing: Boolean = true,
    val pairingRejectReason: String? = null,
    val handshakeRejectCode: String? = null,
    var dshVersion: String = "0.2.2-rc.1",
    var caps: List<String> = listOf("workspace/1", PclinkCrypto.SUITE),
) : FakePcServer {
    @Volatile
    var learnedPhonePublicKey: ByteArray? = phonePublicKey?.copyOf()

    @Volatile
    var learnedPhoneMachineId: String? = phoneMachineId

    @Volatile
    var pairingAuthReceived: Boolean = false

    @Volatile
    var pairingFinalReceived: Boolean = false

    @Volatile
    var pairingCompleted: Boolean = false

    @Volatile
    var pairCloseReason: String? = null

    @Volatile
    var handshakeCount: Int = 0

    @Volatile
    var established: Boolean = false

    @Volatile
    var phoneHelloReceived: Boolean = false

    val receivedInner = CopyOnWriteArrayList<PclinkJson>()
    val receivedSeq = CopyOnWriteArrayList<Long>()
    val receivedCloseCodes = CopyOnWriteArrayList<String>()
    val delivered = CopyOnWriteArrayList<PclinkJson>()

    /** Every `rpc.call` the phone sent, in order (C4 tests). */
    val rpcCalls = CopyOnWriteArrayList<PclinkJson>()

    /** Every `rpc.stream.open` the phone sent, in order (C4 tests). */
    val streamOpens = CopyOnWriteArrayList<PclinkJson>()

    /** Every `rpc.stream.cancel` the phone sent, in order (C4 tests). */
    val streamCancels = CopyOnWriteArrayList<PclinkJson>()

    /**
     * C4 seam: answers one `rpc.call`. Return `true` when the handler sent a
     * response; the default `{items:[]}` result is used otherwise. The handler
     * may suspend and call [sendInner] any number of times (chunks, delay).
     */
    @Volatile
    var rpcCallHandler: (suspend (FakeRelayLink, PclinkJson) -> Boolean)? = null

    /** C4 seam: observes one `rpc.stream.open`; return `true` when handled. */
    @Volatile
    var streamOpenHandler: (suspend (FakeRelayLink, PclinkJson) -> Boolean)? = null

    @Volatile
    var sawOutOfOrderSeq: Boolean = false

    private var pairHelloNonce: ByteArray? = null
    private var pairKey: ByteArray? = null

    private var sid: String? = null
    private var sidBytes: ByteArray? = null
    private var th1: ByteArray? = null
    private var th2: ByteArray? = null
    private var keys: PclinkCrypto.SessionKeys? = null
    private var pcEphemeral: PclinkCrypto.EphemeralKey? = null
    private var pcNonce: ByteArray? = null
    private var sendSeq: Long = 0
    private var lastRecvSeq: Long? = null

    private val pairingActive: Boolean
        get() = pairingOffer != null && !pairingCompleted

    override suspend fun onConnect(link: FakeRelayLink) {
        // The relay challenge/auth is C3; C2 receives an already authenticated link.
    }

    override suspend fun onFrame(link: FakeRelayLink, frame: PclinkJson) {
        when (frame["type"]?.stringValue) {
            "relay.pair.join" -> if (pairingActive) handlePairJoin(link, frame)
            "relay.pair.message" -> if (pairingActive) handlePairMessage(link, frame)
            "relay.pair.close" -> if (pairingActive) {
                pairCloseReason = frame["reason"]?.stringValue
            }
            "e2e.handshake" -> if (!pairingActive) handleHandshake(link, frame)
            "e2e" -> if (!pairingActive) handleE2e(link, frame)
        }
    }

    private suspend fun handlePairJoin(link: FakeRelayLink, frame: PclinkJson) {
        val rendezvous = frame["rendezvous"]?.stringValue ?: return
        link.deliver(
            pclinkObject(
                "v" to PclinkJson.Integer(1),
                "type" to PclinkJson.Text("relay.pair.joined"),
                "rendezvous" to PclinkJson.Text(rendezvous),
                "role" to PclinkJson.Text("phone"),
                "peerMachineId" to PclinkJson.Text(pcIdentity.machineId),
            ),
        )
        val offer = pairingOffer ?: return
        pairKey = offer.pairKey
        val nonce = PclinkRandom.bytes(32)
        pairHelloNonce = nonce
        val hello = PclinkPairingMessage.makeHello(
            machineId = pcIdentity.machineId,
            publicKey = pcIdentity.publicKey,
            name = pcName,
            relayOrigin = origin,
            nonce = nonce,
            pairKey = offer.pairKey,
        )
        link.deliver(pairMessageFrame(rendezvous, hello.raw))
    }

    private suspend fun handlePairMessage(link: FakeRelayLink, frame: PclinkJson) {
        val rendezvous = frame["rendezvous"]?.stringValue ?: return
        val payload = frame["payload"] ?: return
        val offer = pairingOffer ?: return
        val key = pairKey ?: return
        when (val message = PclinkPairingMessage.decode(payload)) {
            is PclinkPairingMessage.Auth -> {
                message.verifyMac(key)
                if (message.relay != origin) throw PclinkError.AuthFailed("relay origin mismatch")
                if (PclinkBase32.machineId(message.publicKey) != message.machineId) {
                    throw PclinkError.AuthFailed("phone machineId mismatch")
                }
                if (!message.peerNonce.contentEquals(pairHelloNonce)) {
                    throw PclinkError.AuthFailed("pair.auth peerNonce mismatch")
                }
                pairingAuthReceived = true
                learnedPhonePublicKey = message.publicKey
                learnedPhoneMachineId = message.machineId
                pairingRejectReason?.let { reason ->
                    link.deliver(pairCloseFrame(rendezvous, reason))
                    return
                }
                if (!autoConfirmPairing) return // pre-v1.6 PC waits for an operator forever.
                val hello = PclinkPairingMessage.Hello(
                    pclinkObject(
                        "v" to PclinkJson.Integer(1),
                        "type" to PclinkJson.Text("pair.hello"),
                        "role" to PclinkJson.Text("pc"),
                        "machineId" to PclinkJson.Text(pcIdentity.machineId),
                        "publicKey" to PclinkJson.Text(PclinkBase64Url.encode(pcIdentity.publicKey)),
                        "name" to PclinkJson.Text(pcName),
                        "relay" to PclinkJson.Text(origin),
                        "nonce" to PclinkJson.Text(PclinkBase64Url.encode(pairHelloNonce!!)),
                        "mac" to PclinkJson.Text(PclinkBase64Url.encode(ByteArray(32))),
                    ),
                )
                val transcript = PclinkCrypto.pairTranscriptHash(
                    hello.canonicalWithoutMac(),
                    message.canonicalWithoutMac(),
                )
                val confirm = PclinkPairingMessage.makeConfirm(
                    helloNonce = pairHelloNonce!!,
                    authNonce = message.nonce,
                    transcriptHash = transcript,
                    pairKey = key,
                )
                link.deliver(pairMessageFrame(rendezvous, confirm.raw))
            }
            is PclinkPairingMessage.Final -> {
                message.verifyMac(key)
                pairingFinalReceived = true
                pairingCompleted = true
                link.deliver(pairCloseFrame(rendezvous, "paired"))
            }
            else -> Unit
        }
    }

    private fun pairMessageFrame(rendezvous: String, payload: PclinkJson): PclinkJson =
        pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("relay.pair.message"),
            "rendezvous" to PclinkJson.Text(rendezvous),
            "payload" to payload,
        )

    private fun pairCloseFrame(rendezvous: String, reason: String): PclinkJson =
        pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("relay.pair.close"),
            "rendezvous" to PclinkJson.Text(rendezvous),
            "reason" to PclinkJson.Text(reason),
        )

    private suspend fun handleHandshake(link: FakeRelayLink, frame: PclinkJson) {
        val body = frame["body"] ?: return
        when (body["type"]?.stringValue) {
            "session.init" -> {
                sendSeq = 0
                lastRecvSeq = null
                phoneHelloReceived = false
                established = false
                val sidText = frame["sid"]?.stringValue ?: return
                val sidRaw = PclinkBase64Url.decode(sidText, 16)
                val eph = PclinkBase64Url.decode(body.requiredString("eph"), 32)
                val nonce = PclinkBase64Url.decode(body.requiredString("nonce"), 32)
                val from = frame.requiredString("from")
                val to = frame.requiredString("to")
                if (to != pcIdentity.machineId) return
                val initTranscript = PclinkCrypto.sessionInitTranscript(
                    phoneMachineId = from,
                    pcMachineId = to,
                    sid = sidRaw,
                    ephPhone = eph,
                    noncePhone = nonce,
                )
                val initTh1 = PclinkCrypto.sha256(initTranscript)
                handshakeRejectCode?.let { code ->
                    val signature = pcIdentity.sign(PclinkCrypto.sessionRejectTranscript(initTh1, code))
                    link.deliver(
                        pclinkObject(
                            "v" to PclinkJson.Integer(1),
                            "type" to PclinkJson.Text("e2e.handshake"),
                            "sid" to PclinkJson.Text(sidText),
                            "from" to PclinkJson.Text(pcIdentity.machineId),
                            "to" to PclinkJson.Text(from),
                            "body" to pclinkObject(
                                "v" to PclinkJson.Integer(1),
                                "type" to PclinkJson.Text("session.reject"),
                                "sid" to PclinkJson.Text(sidText),
                                "code" to PclinkJson.Text(code),
                                "message" to PclinkJson.Text("no pairing record"),
                                "sig" to PclinkJson.Text(PclinkBase64Url.encode(signature)),
                            ),
                        ),
                    )
                    return
                }
                val ephemeral = PclinkCrypto.generateX25519()
                val pcNonceValue = PclinkRandom.bytes(32)
                val respTranscript = PclinkCrypto.sessionRespTranscript(initTh1, ephemeral.publicKey, pcNonceValue)
                val derivedTh2 = PclinkCrypto.sha256(respTranscript)
                val dh = PclinkCrypto.x25519SharedSecret(ephemeral.privateKey, eph)
                val derivedKeys = PclinkCrypto.sessionKeys(dh, derivedTh2)
                val signature = pcIdentity.sign(respTranscript)
                val confirm = PclinkCrypto.confirmation(derivedKeys.confirmPC, derivedTh2)
                sid = sidText
                sidBytes = sidRaw
                th1 = initTh1
                th2 = derivedTh2
                pcEphemeral = ephemeral
                pcNonce = pcNonceValue
                keys = derivedKeys
                handshakeCount += 1
                link.deliver(
                    pclinkObject(
                        "v" to PclinkJson.Integer(1),
                        "type" to PclinkJson.Text("e2e.handshake"),
                        "sid" to PclinkJson.Text(sidText),
                        "from" to PclinkJson.Text(pcIdentity.machineId),
                        "to" to PclinkJson.Text(from),
                        "body" to pclinkObject(
                            "v" to PclinkJson.Integer(1),
                            "type" to PclinkJson.Text("session.resp"),
                            "sid" to PclinkJson.Text(sidText),
                            "eph" to PclinkJson.Text(PclinkBase64Url.encode(ephemeral.publicKey)),
                            "nonce" to PclinkJson.Text(PclinkBase64Url.encode(pcNonceValue)),
                            "sig" to PclinkJson.Text(PclinkBase64Url.encode(signature)),
                            "confirm" to PclinkJson.Text(PclinkBase64Url.encode(confirm)),
                        ),
                    ),
                )
            }
            "session.confirm" -> {
                val activeSid = sid ?: return
                val activeSidBytes = sidBytes ?: return
                val activeTh2 = th2 ?: return
                val activeKeys = keys ?: return
                if (body["sid"]?.stringValue != activeSid) return
                val signature = PclinkBase64Url.decode(body.requiredString("sig"), 64)
                val confirm = PclinkBase64Url.decode(body.requiredString("confirm"), 32)
                val phone = learnedPhoneMachineId ?: return
                val phoneKey = learnedPhonePublicKey ?: return
                val transcript = PclinkCrypto.sessionConfirmTranscript(
                    th2 = activeTh2,
                    phoneMachineId = phone,
                    pcMachineId = pcIdentity.machineId,
                    sid = activeSidBytes,
                )
                val th3 = PclinkCrypto.sha256(transcript)
                if (!PclinkCrypto.ed25519Verify(phoneKey, transcript, signature)) return
                if (!PclinkCrypto.constantTimeEquals(
                        confirm,
                        PclinkCrypto.confirmation(activeKeys.confirmPhone, th3),
                    )
                ) {
                    return
                }
                established = true
                val hello = PclinkPeerHello.make(
                    role = "pc",
                    caps = caps,
                    dshVersion = dshVersion,
                    dshCommit = "66491b05",
                    appName = "dsh-pclink",
                    appVersion = "0.1.0",
                    name = pcName,
                )
                sendInner(link, hello.json)
            }
        }
    }

    private suspend fun handleE2e(link: FakeRelayLink, frame: PclinkJson) {
        val activeKeys = keys ?: return
        val activeSid = sid ?: return
        if (frame["sid"]?.stringValue != activeSid) return
        val seq = frame["seq"]?.longValue ?: return
        receivedSeq.add(seq)
        if (lastRecvSeq == null) {
            if (seq != 0L) sawOutOfOrderSeq = true
        } else if (seq != lastRecvSeq!! + 1) {
            sawOutOfOrderSeq = true
        }
        lastRecvSeq = seq
        val body = PclinkBase64Url.decode(frame.requiredString("body"))
        val aad = PclinkCrypto.aad(
            sid = activeSid,
            seq = seq,
            from = learnedPhoneMachineId ?: return,
            to = pcIdentity.machineId,
        )
        val plaintext = PclinkCrypto.aeadOpen(
            body,
            activeKeys.phoneToPC,
            PclinkCrypto.aeadNonce(seq),
            aad,
        )
        val inner = PclinkJsonParser.parseObject(plaintext)
        if (!phoneHelloReceived) {
            if (inner["type"]?.stringValue != "peer.hello") return
            phoneHelloReceived = true
            receivedInner.add(inner)
            return
        }
        if (inner["type"]?.stringValue == "session.close") {
            inner["code"]?.stringValue?.let { receivedCloseCodes.add(it) }
            return
        }
        receivedInner.add(inner)
        when (inner["type"]?.stringValue) {
            "rpc.call" -> {
                rpcCalls.add(inner)
                val handler = rpcCallHandler
                if (handler == null || !handler.invoke(link, inner)) {
                    val id = inner["id"]?.stringValue ?: return
                    sendInner(
                        link,
                        pclinkObject(
                            "type" to PclinkJson.Text("rpc.result"),
                            "id" to PclinkJson.Text(id),
                            "ok" to PclinkJson.Bool(true),
                            "result" to pclinkObject("items" to PclinkJson.Array(emptyList())),
                        ),
                    )
                }
            }
            "rpc.stream.open" -> {
                streamOpens.add(inner)
                streamOpenHandler?.invoke(link, inner)
            }
            "rpc.stream.cancel" -> streamCancels.add(inner)
        }
    }

    suspend fun sendInner(link: FakeRelayLink, inner: PclinkJson) {
        val activeKeys = keys ?: throw PclinkError.SessionExpired("no keys")
        val activeSid = sid ?: throw PclinkError.SessionExpired("no sid")
        val from = pcIdentity.machineId
        val to = learnedPhoneMachineId ?: throw PclinkError.NoIdentity()
        val plaintext = PclinkJsonEncoder.encode(inner)
        val aad = PclinkCrypto.aad(activeSid, sendSeq, from, to)
        val body = PclinkCrypto.aeadSeal(
            plaintext,
            activeKeys.pcToPhone,
            PclinkCrypto.aeadNonce(sendSeq),
            aad,
        )
        val frame = pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("e2e"),
            "sid" to PclinkJson.Text(activeSid),
            "seq" to PclinkJson.Integer(sendSeq),
            "from" to PclinkJson.Text(from),
            "to" to PclinkJson.Text(to),
            "body" to PclinkJson.Text(PclinkBase64Url.encode(body)),
        )
        sendSeq += 1
        delivered.add(frame)
        link.deliver(frame)
    }

    suspend fun sendNotice(link: FakeRelayLink) {
        sendInner(
            link,
            pclinkObject(
                "type" to PclinkJson.Text("pclink.notice"),
                "kind" to PclinkJson.Text("paired"),
                "name" to PclinkJson.Text("Other iPhone"),
                "fingerprint" to PclinkJson.Text("gewr-a3lz-quax"),
                "at" to PclinkJson.Text("2026-11-09T00:00:05Z"),
            ),
        )
    }

    suspend fun sendClose(link: FakeRelayLink, code: String, message: String? = null) {
        val members = LinkedHashMap<String, PclinkJson>()
        members["type"] = PclinkJson.Text("session.close")
        members["code"] = PclinkJson.Text(code)
        message?.let { members["message"] = PclinkJson.Text(it) }
        sendInner(link, PclinkJson.Object(members))
    }
}

/** Deterministic golden handshake helpers shared by the C2 test classes. */
object C2TestSupport {
    fun phoneIdentity(): PclinkIdentity = TestSupport.identity("pclink-v1/test/identity/phone")

    fun pcIdentity(): PclinkIdentity = TestSupport.identity("pclink-v1/test/identity/pc")

    fun peerRecord(): PclinkPairingRecord =
        PclinkPairingRecord.fromJson(
            TestSupport.at(TestSupport.vectors(), "pairing", "records", "phone")
                ?: throw AssertionError("missing pairing.records.phone"),
        )

    fun goldenRespOuter(): PclinkJson {
        val vectors = TestSupport.vectors()
        val handshake = TestSupport.at(vectors, "handshake") ?: throw AssertionError("missing handshake")
        val init = TestSupport.at(handshake, "init") ?: throw AssertionError("missing init")
        val sid = TestSupport.requireString(init, "sid")
        return pclinkObject(
            "v" to PclinkJson.Integer(1),
            "type" to PclinkJson.Text("e2e.handshake"),
            "sid" to PclinkJson.Text(sid),
            "from" to PclinkJson.Text(TestSupport.requireString(handshake, "to")),
            "to" to PclinkJson.Text(TestSupport.requireString(handshake, "from")),
            "body" to (TestSupport.at(handshake, "resp") ?: throw AssertionError("missing resp")),
        )
    }

    /** A session whose PC response was verified, so keys are installed. */
    fun goldenSession(thresholds: PclinkSessionThresholds = PclinkSessionThresholds.v1): PclinkE2eSession {
        val handshake = TestSupport.at(TestSupport.vectors(), "handshake")
            ?: throw AssertionError("missing handshake")
        val sid = TestSupport.b64(handshake, "sid") ?: throw AssertionError("missing sid")
        val phoneEphSeed = TestSupport.seed(
            TestSupport.requireString(handshake, "phone_eph", "seed_label"),
        )
        val phoneNonce = TestSupport.b64(handshake, "phone_nonce")
            ?: throw AssertionError("missing phone nonce")
        val session = PclinkE2eSession(
            identity = phoneIdentity(),
            peer = peerRecord(),
            sidBytes = sid,
            ephemeral = PclinkCrypto.EphemeralKey(phoneEphSeed, PclinkCrypto.x25519PublicKey(phoneEphSeed)),
            phoneNonce = phoneNonce,
            thresholds = thresholds,
        )
        session.acceptResp(goldenRespOuter())
        return session
    }

    fun outerFrame(frame: PclinkJson): PclinkJson = pclinkObject(
        "v" to PclinkJson.Integer(1),
        "type" to PclinkJson.Text("e2e"),
        "sid" to PclinkJson.Text(TestSupport.requireString(frame, "sid")),
        "seq" to PclinkJson.Integer(TestSupport.requireInt(frame, "seq")),
        "from" to PclinkJson.Text(TestSupport.requireString(frame, "from")),
        "to" to PclinkJson.Text(TestSupport.requireString(frame, "to")),
        "body" to PclinkJson.Text(TestSupport.requireString(frame, "body")),
    )

    fun frameCase(name: String): PclinkJson =
        TestSupport.objects(TestSupport.vectors(), "frames").single {
            TestSupport.string(it, "case") == name
        }

    fun goldenKeys(): PclinkCrypto.SessionKeys {
        val handshake = TestSupport.at(TestSupport.vectors(), "handshake")
            ?: throw AssertionError("missing handshake")
        return PclinkCrypto.SessionKeys(
            phoneToPC = TestSupport.b64(handshake, "keys", "phone_to_pc")!!,
            pcToPhone = TestSupport.b64(handshake, "keys", "pc_to_phone")!!,
            confirmPhone = TestSupport.b64(handshake, "keys", "confirm_phone")!!,
            confirmPC = TestSupport.b64(handshake, "keys", "confirm_pc")!!,
        )
    }
}
