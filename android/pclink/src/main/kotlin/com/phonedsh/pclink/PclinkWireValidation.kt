// SPDX-License-Identifier: MIT
// Closed-shape validators for the frozen PCLink wire schemas (§2.3, §3, §4, §5,
// §6). These are used by the golden-schema-sample test and by the C2/C3/C4
// receive paths; they carry no state.
package com.phonedsh.pclink

object PclinkWire {
    val relayErrorCodes: Set<String> = setOf(
        "unavailable", "unpaired", "auth_failed", "replaced", "session_expired",
        "replay", "bad_frame", "frame_too_large", "rate_limited",
        "version_unsupported", "rendezvous_expired", "rendezvous_exhausted",
    )

    val sessionRejectCodes: Set<String> = setOf(
        "unpaired", "auth_failed", "version_unsupported", "rate_limited",
        "bad_frame", "replay", "frame_too_large", "unavailable", "session_expired",
    )

    val sessionCloseCodes: Set<String> = setOf(
        "unavailable", "unpaired", "auth_failed", "replaced", "session_expired",
        "replay", "bad_frame", "frame_too_large", "rate_limited",
        "version_unsupported", "rekey",
    )

    val pairCloseReasons: Set<String> = setOf(
        "paired", "cancelled", "rejected", "peer_offline", "rendezvous_expired",
        "rendezvous_exhausted", "auth_failed", "storage", "timeout",
    )

    /** `peer.hello` must carry both names in `caps` (§5.6). */
    val requiredPeerHelloCaps: Set<String> = setOf(PclinkEndpoints.SUITE, PclinkCrypto.SUITE)

    fun supportsPclink(caps: Collection<String>): Boolean =
        caps.containsAll(requiredPeerHelloCaps)

    /** A suite other than the frozen v1 suite is `version_unsupported` (§5.2). */
    fun requireSupportedSuite(suite: String) {
        if (suite != PclinkCrypto.SUITE) {
            throw PclinkError.VersionUnsupported("unsupported suite $suite")
        }
    }

    /** No intersection with `workspace/1` + the suite closes with `version_unsupported` (§5.6). */
    fun requirePeerHelloCaps(caps: Collection<String>) {
        if (!supportsPclink(caps)) {
            throw PclinkError.VersionUnsupported(
                "caps must contain ${requiredPeerHelloCaps.joinToString(", ")}",
            )
        }
    }

    // ---- Relay plane -----------------------------------------------------

    /** Validates a relay-plane frame and returns its `type`. */
    fun validateRelayFrame(value: PclinkJson): String {
        val type = value["type"]?.stringValue ?: throw badFrame("relay frame has no type")
        when (type) {
            "relay.challenge" -> validateRelayChallenge(value)
            "peer.auth" -> validateRelayAuth(value)
            "relay.ready" -> validateRelayReady(value)
            "relay.allow" -> validateRelayAllow(value)
            "relay.offline" -> validateRelayOffline(value)
            "relay.error" -> validateRelayError(value)
            "relay.ping", "relay.pong" -> validateRelayHeartbeat(value)
            "relay.redirect" -> validateRelayRedirect(value)
            "relay.pair.open", "relay.pair.join", "relay.pair.joined",
            "relay.pair.message", "relay.pair.close",
            -> validateRelayPair(value)
            "e2e" -> validateE2EFrame(value)
            "e2e.handshake" -> validateE2EHandshake(value)
            else -> throw badFrame("unknown relay type $type")
        }
        return type
    }

    fun validateRelayChallenge(value: PclinkJson) {
        val objectValue = value.closedObject(setOf("v", "type", "nonce", "relay"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "relay.challenge") {
            throw badFrame("relay.challenge header")
        }
        PclinkBase64Url.decode(value.requiredString("nonce"), expectedLength = 32)
        PclinkValidation.origin(value.requiredString("relay"))
    }

    fun validateRelayAuth(value: PclinkJson) {
        val objectValue =
            value.closedObject(setOf("v", "type", "machineId", "publicKey", "role", "sig"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "peer.auth") {
            throw badFrame("peer.auth header")
        }
        PclinkValidation.requireMachineId(value.requiredString("machineId"))
        PclinkBase64Url.decode(value.requiredString("publicKey"), expectedLength = 32)
        if (value.requiredString("role") !in setOf("phone", "pc")) {
            throw badFrame("peer.auth role")
        }
        PclinkBase64Url.decode(value.requiredString("sig"), expectedLength = 64)
    }

    fun validateRelayReady(value: PclinkJson) {
        val objectValue = value.closedObject(setOf("v", "type", "machineId", "role"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "relay.ready") {
            throw badFrame("relay.ready header")
        }
        PclinkValidation.requireMachineId(value.requiredString("machineId"))
        if (value.requiredString("role") !in setOf("phone", "pc")) {
            throw badFrame("relay.ready role")
        }
    }

    fun validateRelayAllow(value: PclinkJson) {
        val objectValue = value.closedObject(setOf("v", "type", "peers"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "relay.allow") {
            throw badFrame("relay.allow header")
        }
        val peers = objectValue["peers"]?.arrayValue
        if (peers == null || peers.size > 1024) throw badFrame("relay.allow peers")
        val seen = HashSet<String>()
        for (peer in peers) {
            val text = peer.stringValue ?: throw badFrame("relay.allow peer")
            if (!PclinkValidation.isMachineId(text) || !seen.add(text)) {
                throw badFrame("relay.allow peer")
            }
        }
    }

    fun validateRelayOffline(value: PclinkJson) {
        val objectValue = value.closedObject(
            required = setOf("v", "type", "to"),
            optional = setOf("id", "streamId", "sid"),
        )
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "relay.offline") {
            throw badFrame("relay.offline header")
        }
        PclinkValidation.requireMachineId(value.requiredString("to"), field = "to")
        objectValue["id"]?.let { optionalCorrelationId(it, "relay.offline id") }
        objectValue["streamId"]?.let { optionalCorrelationId(it, "relay.offline streamId") }
        objectValue["sid"]?.let { optionalSessionId(it, "relay.offline sid") }
    }

    fun validateRelayError(value: PclinkJson) {
        val objectValue = value.closedObject(
            required = setOf("v", "type", "code"),
            optional = setOf("message", "id", "streamId", "sid", "retryAfterMs"),
        )
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "relay.error") {
            throw badFrame("relay.error header")
        }
        val code = objectValue["code"]?.stringValue
        if (code == null || code !in relayErrorCodes) throw badFrame("relay.error code")
        objectValue["message"]?.let { message ->
            val text = message.stringValue ?: throw badFrame("relay.error message")
            PclinkValidation.displayText(text, "relay.error message", maximumBytes = 2048)
        }
        objectValue["retryAfterMs"]?.let { retry ->
            val number = retry.longValue ?: throw badFrame("relay.error retryAfterMs")
            if (number !in 0L..86_400_000L) throw badFrame("relay.error retryAfterMs")
        }
        objectValue["id"]?.let { optionalCorrelationId(it, "relay.error id") }
        objectValue["streamId"]?.let { optionalCorrelationId(it, "relay.error streamId") }
        objectValue["sid"]?.let { optionalSessionId(it, "relay.error sid") }
    }

    fun validateRelayHeartbeat(value: PclinkJson) {
        val objectValue = value.closedObject(setOf("v", "type", "nonce"))
        val type = objectValue["type"]?.stringValue
        if (objectValue["v"]?.longValue != 1L || type !in setOf("relay.ping", "relay.pong")) {
            throw badFrame("relay heartbeat header")
        }
        PclinkBase64Url.decode(value.requiredString("nonce"), expectedLength = 16)
    }

    fun validateRelayRedirect(value: PclinkJson) {
        val objectValue = value.closedObject(setOf("v", "type", "url"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "relay.redirect") {
            throw badFrame("relay.redirect header")
        }
        PclinkValidation.origin(value.requiredString("url"))
    }

    fun validateRelayPair(value: PclinkJson) {
        val type = value["type"]?.stringValue ?: throw badFrame("missing type")
        when (type) {
            "relay.pair.open", "relay.pair.join" -> {
                val objectValue = value.closedObject(setOf("v", "type", "rendezvous"))
                if (objectValue["v"]?.longValue != 1L) throw badFrame("pair v")
                requireRendezvous(value.requiredString("rendezvous"))
            }
            "relay.pair.joined" -> {
                val objectValue = value.closedObject(
                    setOf("v", "type", "rendezvous", "role", "peerMachineId"),
                )
                if (objectValue["v"]?.longValue != 1L) throw badFrame("pair v")
                requireRendezvous(value.requiredString("rendezvous"))
                if (value.requiredString("role") !in setOf("pc", "phone")) {
                    throw badFrame("pair role")
                }
                PclinkValidation.requireMachineId(value.requiredString("peerMachineId"))
            }
            "relay.pair.message" -> {
                val objectValue = value.closedObject(setOf("v", "type", "rendezvous", "payload"))
                if (objectValue["v"]?.longValue != 1L) throw badFrame("pair v")
                requireRendezvous(value.requiredString("rendezvous"))
                if (objectValue["payload"]?.objectValue == null) throw badFrame("pair payload")
            }
            "relay.pair.close" -> {
                val objectValue = value.closedObject(setOf("v", "type", "rendezvous", "reason"))
                if (objectValue["v"]?.longValue != 1L) throw badFrame("pair v")
                requireRendezvous(value.requiredString("rendezvous"))
                val reason = objectValue["reason"]?.stringValue
                if (reason == null || reason !in pairCloseReasons) {
                    throw badFrame("pair close reason")
                }
            }
            else -> throw badFrame("unknown pairing relay type")
        }
    }

    // ---- E2E plane -------------------------------------------------------

    fun validateE2EFrame(value: PclinkJson) {
        val objectValue =
            value.closedObject(setOf("v", "type", "sid", "seq", "from", "to", "body"))
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "e2e") {
            throw badFrame("e2e header")
        }
        if (!PclinkValidation.isSessionId(value.requiredString("sid"))) {
            throw badFrame("e2e sid")
        }
        val seq = objectValue["seq"]?.longValue ?: throw badFrame("e2e seq")
        if (seq < 0 || seq >= PclinkLimits.HARD_FRAME_THRESHOLD) throw badFrame("e2e seq")
        PclinkValidation.requireMachineId(value.requiredString("from"), field = "from")
        PclinkValidation.requireMachineId(value.requiredString("to"), field = "to")
        val body = value.requiredString("body")
        if (body.length > 22_000_000) throw badFrame("e2e body length")
        PclinkBase64Url.decode(body)
    }

    fun validateE2EHandshake(value: PclinkJson) {
        val objectValue = value.closedObject(setOf("v", "type", "sid", "from", "to", "body"))
        if (objectValue["v"]?.longValue != 1L ||
            objectValue["type"]?.stringValue != "e2e.handshake"
        ) {
            throw badFrame("e2e.handshake header")
        }
        val sid = value.requiredString("sid")
        if (!PclinkValidation.isSessionId(sid)) throw badFrame("handshake sid")
        PclinkValidation.requireMachineId(value.requiredString("from"), field = "from")
        PclinkValidation.requireMachineId(value.requiredString("to"), field = "to")
        val body = objectValue["body"] ?: throw badFrame("missing handshake body")
        val type = body["type"]?.stringValue ?: throw badFrame("missing handshake body type")
        when (type) {
            "session.init" -> {
                val bodyValue =
                    body.closedObject(setOf("v", "type", "sid", "suite", "eph", "nonce"))
                if (bodyValue["v"]?.longValue != 1L ||
                    bodyValue["suite"]?.stringValue != PclinkCrypto.SUITE
                ) {
                    throw badFrame("session.init suite/version")
                }
                if (bodyValue["sid"]?.stringValue != sid) throw badFrame("session.init sid")
                PclinkBase64Url.decode(body.requiredString("eph"), expectedLength = 32)
                PclinkBase64Url.decode(body.requiredString("nonce"), expectedLength = 32)
            }
            "session.resp" -> {
                val bodyValue = body.closedObject(
                    setOf("v", "type", "sid", "eph", "nonce", "sig", "confirm"),
                )
                if (bodyValue["v"]?.longValue != 1L ||
                    bodyValue["type"]?.stringValue != "session.resp"
                ) {
                    throw badFrame("session.resp header")
                }
                if (bodyValue["sid"]?.stringValue != sid) throw badFrame("session.resp sid")
                PclinkBase64Url.decode(body.requiredString("eph"), expectedLength = 32)
                PclinkBase64Url.decode(body.requiredString("nonce"), expectedLength = 32)
                PclinkBase64Url.decode(body.requiredString("sig"), expectedLength = 64)
                PclinkBase64Url.decode(body.requiredString("confirm"), expectedLength = 32)
            }
            "session.confirm" -> {
                val bodyValue =
                    body.closedObject(setOf("v", "type", "sid", "sig", "confirm"))
                if (bodyValue["v"]?.longValue != 1L ||
                    bodyValue["type"]?.stringValue != "session.confirm"
                ) {
                    throw badFrame("session.confirm header")
                }
                if (bodyValue["sid"]?.stringValue != sid) throw badFrame("session.confirm sid")
                PclinkBase64Url.decode(body.requiredString("sig"), expectedLength = 64)
                PclinkBase64Url.decode(body.requiredString("confirm"), expectedLength = 32)
            }
            "session.reject" -> {
                val bodyValue = body.closedObject(
                    required = setOf("v", "type", "sid", "code"),
                    optional = setOf("message", "sig"),
                )
                if (bodyValue["v"]?.longValue != 1L ||
                    bodyValue["type"]?.stringValue != "session.reject" ||
                    bodyValue["sid"]?.stringValue != sid
                ) {
                    throw badFrame("session.reject header")
                }
                val code = bodyValue["code"]?.stringValue
                if (code == null || code !in sessionRejectCodes) {
                    throw badFrame("session.reject code")
                }
                bodyValue["message"]?.let { message ->
                    val text = message.stringValue ?: throw badFrame("session.reject message")
                    PclinkValidation.displayText(text, "session.reject message", maximumBytes = 512)
                }
                bodyValue["sig"]?.let { sig ->
                    val text = sig.stringValue ?: throw badFrame("session.reject sig")
                    PclinkBase64Url.decode(text, expectedLength = 64)
                }
            }
            else -> throw badFrame("unknown handshake body type")
        }
    }

    // ---- Inner messages --------------------------------------------------

    fun validateInnerMessage(value: PclinkJson) {
        val type = value["type"]?.stringValue ?: throw badFrame("inner message has no type")
        when (type) {
            "peer.hello" -> {
                val role = value["role"]?.stringValue ?: throw badFrame("peer.hello role")
                validatePeerHello(value, expectedRole = role)
            }
            "rpc.call" -> {
                val objectValue = value.closedObject(setOf("type", "id", "endpoint", "args"))
                if (objectValue["id"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("rpc.call id")
                }
                if (objectValue["endpoint"]?.stringValue?.let(PclinkValidation::isEndpoint) != true) {
                    throw badFrame("rpc.call endpoint")
                }
                if (objectValue["args"]?.objectValue == null) throw badFrame("rpc.call args")
            }
            "rpc.result" -> {
                val header = value.closedObject(
                    required = setOf("type", "id", "ok"),
                    optional = setOf("result", "error"),
                )
                if (header["id"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("rpc.result id")
                }
                val ok = header["ok"]?.boolValue ?: throw badFrame("rpc.result ok")
                if (ok) {
                    if (header["result"] == null || header["error"] != null) {
                        throw badFrame("rpc.result ok shape")
                    }
                } else {
                    val error = header["error"]
                    if (header["result"] != null || error == null) {
                        throw badFrame("rpc.result error shape")
                    }
                    validateRpcError(error)
                }
            }
            "rpc.result.chunk" -> {
                val objectValue =
                    value.closedObject(setOf("type", "id", "part", "last", "data"))
                if (objectValue["id"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("chunk id")
                }
                validateChunkFields(objectValue)
            }
            "rpc.stream.open" -> {
                val objectValue =
                    value.closedObject(setOf("type", "streamId", "endpoint", "payload"))
                if (objectValue["streamId"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("streamId")
                }
                if (objectValue["endpoint"]?.stringValue?.let(PclinkValidation::isEndpoint) != true) {
                    throw badFrame("stream endpoint")
                }
                val payload = objectValue["payload"] ?: throw badFrame("stream payload")
                val payloadObject = payload.closedObject(setOf("args"))
                if (payloadObject["args"]?.objectValue == null) throw badFrame("stream payload")
            }
            "rpc.stream.item" -> {
                val objectValue = value.closedObject(setOf("type", "streamId", "value"))
                if (objectValue["streamId"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("streamId")
                }
                if (objectValue["value"] == null) throw badFrame("missing value")
            }
            "rpc.stream.chunk" -> {
                val objectValue =
                    value.closedObject(setOf("type", "streamId", "part", "last", "data"))
                if (objectValue["streamId"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("streamId")
                }
                validateChunkFields(objectValue)
            }
            "rpc.stream.end", "rpc.stream.cancel" -> {
                val objectValue = value.closedObject(setOf("type", "streamId"))
                if (objectValue["streamId"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("streamId")
                }
            }
            "rpc.stream.error" -> {
                val objectValue = value.closedObject(setOf("type", "streamId", "error"))
                if (objectValue["streamId"]?.stringValue?.let(PclinkValidation::isCorrelationId) != true) {
                    throw badFrame("streamId")
                }
                validateRpcError(objectValue.getValue("error"))
            }
            "session.close" -> {
                val objectValue =
                    value.closedObject(required = setOf("type", "code"), optional = setOf("message"))
                val code = objectValue["code"]?.stringValue
                if (code == null || code !in sessionCloseCodes) {
                    throw badFrame("session.close code")
                }
                objectValue["message"]?.let { message ->
                    val text = message.stringValue ?: throw badFrame("session.close message")
                    PclinkValidation.displayText(text, "session.close message", maximumBytes = 512)
                }
            }
            "pclink.notice" -> {
                val objectValue =
                    value.closedObject(setOf("type", "kind", "name", "fingerprint", "at"))
                if (objectValue["kind"]?.stringValue != "paired") throw badFrame("notice kind")
                PclinkValidation.name(value.requiredString("name"))
                if (!FINGERPRINT_PATTERN.matches(value.requiredString("fingerprint"))) {
                    throw badFrame("notice fingerprint")
                }
                if (!PclinkValidation.isTimestamp(value.requiredString("at"))) {
                    throw badFrame("notice at")
                }
            }
            else -> {
                if (!RESERVED_ERROR_PATTERN.matches(type)) throw badFrame("unknown inner type")
                val objectValue = value.closedObject(
                    required = setOf("type", "code"),
                    optional = setOf("id", "message"),
                )
                if (objectValue["code"]?.stringValue != "unavailable") {
                    throw badFrame("reserved error code")
                }
                objectValue["id"]?.let { id ->
                    val text = id.stringValue ?: throw badFrame("reserved id")
                    if (!PclinkValidation.isCorrelationId(text)) throw badFrame("reserved id")
                }
                objectValue["message"]?.let { message ->
                    val text = message.stringValue ?: throw badFrame("reserved message")
                    PclinkValidation.displayText(text, "reserved message", maximumBytes = 512)
                }
            }
        }
    }

    /**
     * `peer.hello` closed shape (§5.6). [expectedRole] is the role the receive
     * path requires; the helper also rejects a role outside `phone`/`pc` so a
     * shape-only caller cannot accept an unknown role.
     */
    fun validatePeerHello(value: PclinkJson, expectedRole: String) {
        val objectValue = value.closedObject(
            setOf("v", "type", "role", "caps", "dsh", "app", "name"),
        )
        if (objectValue["v"]?.longValue != 1L || objectValue["type"]?.stringValue != "peer.hello") {
            throw badFrame("peer.hello header")
        }
        if (expectedRole !in setOf("phone", "pc")) throw badFrame("peer.hello role")
        if (value.requiredString("role") != expectedRole) {
            throw badFrame("peer.hello role is ${value.requiredString("role")}, expected $expectedRole")
        }
        val capValues = objectValue["caps"]?.arrayValue ?: throw badFrame("peer.hello caps")
        if (capValues.size !in 1..16) throw badFrame("peer.hello caps count")
        val seen = HashSet<String>()
        for (capValue in capValues) {
            val cap = capValue.stringValue ?: throw badFrame("peer.hello capability")
            if (!CAPABILITY_PATTERN.matches(cap)) throw badFrame("peer.hello capability")
            if (!seen.add(cap)) throw badFrame("peer.hello capability is duplicated")
        }
        val dshValue = objectValue["dsh"] ?: throw badFrame("missing dsh")
        val dsh = dshValue.closedObject(required = setOf("version"), optional = setOf("commit"))
        val versionText = dshValue.requiredString("version")
        if (PclinkValidation.SemVer.parse(versionText) == null) {
            throw badFrame("dsh.version is not SemVer")
        }
        dsh["commit"]?.let { commitValue ->
            val text = commitValue.stringValue ?: throw badFrame("dsh.commit")
            if (text.length !in 7..64 || !text.all { it in '0'..'9' || it in 'a'..'f' }) {
                throw badFrame("dsh.commit must be 7-64 lowercase hex")
            }
        }
        val appValue = objectValue["app"] ?: throw badFrame("missing app")
        appValue.closedObject(setOf("name", "version"))
        PclinkValidation.name(appValue.requiredString("name"))
        if (!APP_VERSION_PATTERN.matches(appValue.requiredString("version"))) {
            throw badFrame("app.version is malformed")
        }
        PclinkValidation.name(value.requiredString("name"))
    }

    private fun validateRpcError(value: PclinkJson) {
        val objectValue = value.closedObject(
            required = setOf("code", "message"),
            optional = setOf("details"),
        )
        if (!RPC_ERROR_CODE_PATTERN.matches(objectValue["code"]?.stringValue ?: "")) {
            throw badFrame("rpc error code")
        }
        val message = objectValue["message"]?.stringValue ?: throw badFrame("rpc error message")
        PclinkValidation.displayText(
            message,
            "rpc error message",
            maximumBytes = 2048,
            minimumBytes = 1,
        )
        objectValue["details"]?.let { details ->
            if (details.objectValue == null) throw badFrame("rpc error details")
        }
    }

    private fun validateChunkFields(objectValue: Map<String, PclinkJson>) {
        val part = objectValue["part"]?.longValue ?: throw badFrame("chunk part")
        if (part !in 0L..65_535L) throw badFrame("chunk part")
        if (objectValue["last"]?.boolValue == null) throw badFrame("chunk last")
        val data = objectValue["data"]?.stringValue ?: throw badFrame("chunk data length")
        if (data.length !in 1..PclinkLimits.MAX_CHUNK_CHARACTERS) {
            throw badFrame("chunk data length")
        }
        PclinkBase64Url.decode(data)
    }

    // ---- Pairing messages and records -----------------------------------

    /**
     * Closed shape of one `pair.hello`/`pair.auth`/`pair.confirm`/`pair.final`
     * payload (§4.4). MAC verification and machineId re-derivation are the
     * pairing state machine's job; this validator only checks the shape, so a
     * schema sample with a placeholder key is still a shape-valid sample.
     */
    fun validatePairingMessage(value: PclinkJson) {
        val type = value["type"]?.stringValue ?: throw badFrame("pairing message has no type")
        when (type) {
            "pair.hello" -> {
                val objectValue = value.closedObject(
                    setOf("v", "type", "role", "machineId", "publicKey", "name", "relay", "nonce", "mac"),
                )
                if (objectValue["v"]?.longValue != 1L || value.requiredString("role") != "pc") {
                    throw badFrame("pair.hello header")
                }
                validatePairingCommon(value)
            }
            "pair.auth" -> {
                val objectValue = value.closedObject(
                    setOf(
                        "v", "type", "role", "machineId", "publicKey", "name", "relay",
                        "nonce", "peerNonce", "mac",
                    ),
                )
                if (objectValue["v"]?.longValue != 1L || value.requiredString("role") != "phone") {
                    throw badFrame("pair.auth header")
                }
                validatePairingCommon(value)
                PclinkBase64Url.decode(value.requiredString("peerNonce"), expectedLength = 32)
            }
            "pair.confirm" -> {
                val objectValue = value.closedObject(
                    setOf("v", "type", "role", "nonce", "peerNonce", "transcriptHash", "mac"),
                )
                if (objectValue["v"]?.longValue != 1L || value.requiredString("role") != "pc") {
                    throw badFrame("pair.confirm header")
                }
                validatePairingNonces(value)
            }
            "pair.final" -> {
                val objectValue = value.closedObject(
                    setOf("v", "type", "role", "nonce", "peerNonce", "transcriptHash", "mac"),
                )
                if (objectValue["v"]?.longValue != 1L || value.requiredString("role") != "phone") {
                    throw badFrame("pair.final header")
                }
                validatePairingNonces(value)
            }
            else -> throw badFrame("unknown pairing message type $type")
        }
    }

    private fun validatePairingCommon(value: PclinkJson) {
        PclinkValidation.requireMachineId(value.requiredString("machineId"))
        PclinkBase64Url.decode(value.requiredString("publicKey"), expectedLength = 32)
        PclinkValidation.name(value.requiredString("name"))
        PclinkValidation.origin(value.requiredString("relay"))
        PclinkBase64Url.decode(value.requiredString("nonce"), expectedLength = 32)
        PclinkBase64Url.decode(value.requiredString("mac"), expectedLength = 32)
    }

    private fun validatePairingNonces(value: PclinkJson) {
        PclinkBase64Url.decode(value.requiredString("nonce"), expectedLength = 32)
        PclinkBase64Url.decode(value.requiredString("peerNonce"), expectedLength = 32)
        PclinkBase64Url.decode(value.requiredString("transcriptHash"), expectedLength = 32)
        PclinkBase64Url.decode(value.requiredString("mac"), expectedLength = 32)
    }

    /**
     * Validates the closed pairing-record shape. This intentionally does not
     * check that `peerMachineId` was re-derived from `peerPublicKey`: the schema
     * samples use placeholder keys, while a real store loader re-derives.
     */
    fun validatePairingRecordShape(value: PclinkJson, phoneRecord: Boolean) {
        val required = setOf(
            "peerMachineId", "peerPublicKey", "peerName", "pairedAt", "relayOrigin", "connection",
        )
        val objectValue = if (phoneRecord) {
            value.closedObject(required, optional = setOf("pairingMode"))
        } else {
            value.closedObject(required + setOf("approvedAt", "approvedVia"))
        }
        PclinkValidation.requireMachineId(value.requiredString("peerMachineId"))
        PclinkBase64Url.decode(value.requiredString("peerPublicKey"), expectedLength = 32)
        PclinkValidation.name(value.requiredString("peerName"))
        if (!PclinkValidation.isTimestamp(value.requiredString("pairedAt"))) {
            throw badFrame("pairedAt")
        }
        PclinkValidation.origin(value.requiredString("relayOrigin"))
        val connection = objectValue["connection"] ?: throw badFrame("connection")
        val connectionObject = connection.closedObject(setOf("mode"))
        if (connectionObject["mode"]?.stringValue != "relay") {
            // `direct` is reserved and unsupported in v1 (§4.6).
            throw PclinkError.VersionUnsupported("unsupported connection mode")
        }
        if (phoneRecord) {
            objectValue["pairingMode"]?.let { mode ->
                if (mode.stringValue !in setOf("qr", "manual")) {
                    throw badFrame("phone pairingMode")
                }
            }
        } else {
            if (!PclinkValidation.isTimestamp(value.requiredString("approvedAt"))) {
                throw badFrame("approvedAt")
            }
            val approvedVia = objectValue["approvedVia"]?.stringValue
            if (approvedVia == null || approvedVia !in setOf("qr", "manual", "cli", "webui")) {
                throw badFrame("approvedVia")
            }
        }
    }

    // ---- Endpoint inventory ---------------------------------------------

    fun validateEndpointsInventory(value: PclinkJson) {
        val objectValue = value.closedObject(
            setOf("v", "suite", "dshTestedRange", "defaultRetry", "endpoints"),
        )
        if (objectValue["v"]?.longValue != 1L ||
            objectValue["suite"]?.stringValue != PclinkEndpoints.SUITE ||
            objectValue["dshTestedRange"]?.stringValue != PclinkEndpoints.DSH_TESTED_RANGE ||
            objectValue["defaultRetry"]?.stringValue != "unsafe"
        ) {
            throw badFrame("endpoint inventory header")
        }
        val endpoints = objectValue["endpoints"]?.arrayValue
        if (endpoints == null || endpoints.size !in 1..256) {
            throw badFrame("endpoint inventory endpoints")
        }
        val names = HashSet<String>()
        for (entry in endpoints) {
            val fields = entry.closedObject(
                required = setOf("name", "kind", "retry", "phoneOnly"),
                optional = setOf("notes", "sources"),
            )
            val name = fields["name"]?.stringValue ?: throw badFrame("endpoint name")
            if (!PclinkValidation.isEndpoint(name) || !names.add(name)) {
                throw badFrame("endpoint name")
            }
            val kind = fields["kind"]?.stringValue
            if (kind == null || kind !in setOf("unary", "stream")) {
                throw badFrame("endpoint kind")
            }
            val retry = fields["retry"]?.stringValue
            if (retry == null || retry !in setOf("read", "idempotent", "unsafe")) {
                throw badFrame("endpoint retry")
            }
            if (fields["phoneOnly"]?.boolValue == null) throw badFrame("endpoint phoneOnly")
            fields["notes"]?.let { notes ->
                val text = notes.stringValue ?: throw badFrame("endpoint notes")
                if (text.toByteArray(Charsets.UTF_8).size > 512) throw badFrame("endpoint notes")
            }
            fields["sources"]?.let { sources ->
                val array = sources.arrayValue ?: throw badFrame("endpoint sources")
                if (array.size !in 1..32) throw badFrame("endpoint sources")
                for (source in array) {
                    val text = source.stringValue ?: throw badFrame("endpoint source")
                    if (!SOURCE_PATTERN.matches(text)) throw badFrame("endpoint source")
                }
            }
        }
    }

    // ---- Helpers ---------------------------------------------------------

    private fun optionalCorrelationId(value: PclinkJson, field: String) {
        val text = value.stringValue ?: throw badFrame(field)
        if (!PclinkValidation.isCorrelationId(text)) throw badFrame(field)
    }

    private fun optionalSessionId(value: PclinkJson, field: String) {
        val text = value.stringValue ?: throw badFrame(field)
        if (!PclinkValidation.isSessionId(text)) throw badFrame(field)
    }

    private fun badFrame(message: String): PclinkError = PclinkError.BadFrame(message)

    // §4.3: the rendezvous is the first 22 characters of the b64url *text* of a
    // hash, not a canonical 16-byte encoding, so it is matched as text
    // (relay-pair.schema.json pattern), never decoded.
    private val RENDEZVOUS_PATTERN = Regex("^[A-Za-z0-9_-]{22}$")

    private fun requireRendezvous(value: String) {
        if (!RENDEZVOUS_PATTERN.matches(value)) throw badFrame("pair rendezvous")
    }

    private val FINGERPRINT_PATTERN = Regex("^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$")
    private val CAPABILITY_PATTERN = Regex("^[A-Za-z0-9._/-]{1,64}$")
    private val APP_VERSION_PATTERN = Regex("^[0-9A-Za-z.+-]{1,32}$")
    private val RPC_ERROR_CODE_PATTERN = Regex("^[A-Za-z0-9_$][A-Za-z0-9_$./:-]{0,127}$")
    private val SOURCE_PATTERN = Regex("^[A-Za-z0-9._/-]+:[0-9]+$")
    private val RESERVED_ERROR_PATTERN = Regex("^(?:task|call)\\.[A-Za-z][A-Za-z0-9._-]{0,63}\\.error$")
}
