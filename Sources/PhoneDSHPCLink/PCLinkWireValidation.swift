// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: closed-shape validators for the frozen wire schemas.
//
// These are used by the schema-sample tests and by the App when it wants to
// validate a frame before display. Production receive paths validate the same
// shapes with the typed decoders in the relay client and E2E session.

import Foundation

public enum PCLinkWire {
    public static let relayErrorCodes: Set<String> = [
        "unavailable", "unpaired", "auth_failed", "replaced", "session_expired",
        "replay", "bad_frame", "frame_too_large", "rate_limited",
        "version_unsupported", "rendezvous_expired", "rendezvous_exhausted",
    ]

    public static let sessionRejectCodes: Set<String> = [
        "unpaired", "auth_failed", "version_unsupported", "rate_limited",
        "bad_frame", "replay", "frame_too_large", "unavailable", "session_expired",
    ]

    public static let sessionCloseCodes: Set<String> = [
        "unavailable", "unpaired", "auth_failed", "replaced", "session_expired",
        "replay", "bad_frame", "frame_too_large", "rate_limited",
        "version_unsupported", "rekey",
    ]

    public static let pairCloseReasons: Set<String> = [
        "paired", "cancelled", "rejected", "peer_offline", "rendezvous_expired",
        "rendezvous_exhausted", "auth_failed", "storage", "timeout",
    ]

    // MARK: Relay plane

    /// Returns the validated relay-plane type.
    @discardableResult
    public static func validateRelayFrame(_ value: PCLinkJSON) throws -> String {
        guard let type = value["type"]?.stringValue else {
            throw PCLinkError.badFrame("relay frame has no type")
        }
        switch type {
        case "relay.challenge": try validateRelayChallenge(value)
        case "peer.auth": try validateRelayAuth(value)
        case "relay.ready": try validateRelayReady(value)
        case "relay.allow": try validateRelayAllow(value)
        case "relay.offline": try validateRelayOffline(value)
        case "relay.error": try validateRelayError(value)
        case "relay.ping", "relay.pong": try validateRelayHeartbeat(value)
        case "relay.redirect": try validateRelayRedirect(value)
        case "relay.pair.open", "relay.pair.join", "relay.pair.joined",
             "relay.pair.message", "relay.pair.close": try validateRelayPair(value)
        case "e2e": try validateE2EFrame(value)
        case "e2e.handshake": try validateE2EHandshake(value)
        default: throw PCLinkError.badFrame("unknown relay type \(type)")
        }
        return type
    }

    public static func validateRelayChallenge(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "nonce", "relay"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "relay.challenge" else {
            throw PCLinkError.badFrame("relay.challenge header")
        }
        _ = try PCLinkBase64URL.decode(try value.requiredString("nonce"), expectedBytes: 32)
        try PCLinkValidation.origin(try value.requiredString("relay"))
    }

    public static func validateRelayAuth(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "machineId", "publicKey", "role", "sig"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "peer.auth" else {
            throw PCLinkError.badFrame("peer.auth header")
        }
        try PCLinkValidation.requireMachineId(try value.requiredString("machineId"))
        _ = try PCLinkBase64URL.decode(try value.requiredString("publicKey"), expectedBytes: 32)
        guard ["phone", "pc"].contains(try value.requiredString("role")) else {
            throw PCLinkError.badFrame("peer.auth role")
        }
        _ = try PCLinkBase64URL.decode(try value.requiredString("sig"), expectedBytes: 64)
    }

    public static func validateRelayReady(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "machineId", "role"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "relay.ready" else {
            throw PCLinkError.badFrame("relay.ready header")
        }
        try PCLinkValidation.requireMachineId(try value.requiredString("machineId"))
        guard ["phone", "pc"].contains(try value.requiredString("role")) else {
            throw PCLinkError.badFrame("relay.ready role")
        }
    }

    public static func validateRelayAllow(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "peers"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "relay.allow" else {
            throw PCLinkError.badFrame("relay.allow header")
        }
        guard let peers = object["peers"]?.arrayValue, peers.count <= 1024 else {
            throw PCLinkError.badFrame("relay.allow peers")
        }
        var seen = Set<String>()
        for peer in peers {
            guard let text = peer.stringValue, PCLinkValidation.machineId(text),
                  seen.insert(text).inserted else {
                throw PCLinkError.badFrame("relay.allow peer")
            }
        }
    }

    public static func validateRelayOffline(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "to"],
                                            optional: ["id", "streamId", "sid"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "relay.offline" else {
            throw PCLinkError.badFrame("relay.offline header")
        }
        try PCLinkValidation.requireMachineId(try value.requiredString("to"))
        if let id = object["id"] {
            guard let text = id.stringValue, PCLinkValidation.correlationId(text) else {
                throw PCLinkError.badFrame("relay.offline id")
            }
        }
        if let streamId = object["streamId"] {
            guard let text = streamId.stringValue, PCLinkValidation.correlationId(text) else {
                throw PCLinkError.badFrame("relay.offline streamId")
            }
        }
        if let sid = object["sid"] {
            guard let text = sid.stringValue, PCLinkValidation.sessionId(text) else {
                throw PCLinkError.badFrame("relay.offline sid")
            }
        }
    }

    public static func validateRelayError(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "code"],
                                            optional: ["message", "id", "streamId", "sid", "retryAfterMs"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "relay.error" else {
            throw PCLinkError.badFrame("relay.error header")
        }
        guard let code = object["code"]?.stringValue, relayErrorCodes.contains(code) else {
            throw PCLinkError.badFrame("relay.error code")
        }
        if let message = object["message"] {
            guard let text = message.stringValue, text.utf8.count <= 2048 else {
                throw PCLinkError.badFrame("relay.error message")
            }
        }
        if let retry = object["retryAfterMs"] {
            guard let number = retry.intValue, (0...86_400_000).contains(number) else {
                throw PCLinkError.badFrame("relay.error retryAfterMs")
            }
        }
    }

    public static func validateRelayHeartbeat(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "nonce"])
        guard object["v"]?.intValue == 1,
              ["relay.ping", "relay.pong"].contains(try value.requiredString("type")) else {
            throw PCLinkError.badFrame("relay heartbeat header")
        }
        _ = try PCLinkBase64URL.decode(try value.requiredString("nonce"), expectedBytes: 16)
    }

    public static func validateRelayRedirect(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "url"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "relay.redirect" else {
            throw PCLinkError.badFrame("relay.redirect header")
        }
        try PCLinkValidation.origin(try value.requiredString("url"))
    }

    public static func validateRelayPair(_ value: PCLinkJSON) throws {
        guard let type = value["type"]?.stringValue else { throw PCLinkError.badFrame("missing type") }
        switch type {
        case "relay.pair.open", "relay.pair.join":
            let object = try value.closedObject(required: ["v", "type", "rendezvous"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("pair v") }
            _ = try PCLinkBase64URL.decode(try value.requiredString("rendezvous"), expectedBytes: 16)
        case "relay.pair.joined":
            let object = try value.closedObject(required: ["v", "type", "rendezvous", "role", "peerMachineId"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("pair v") }
            _ = try PCLinkBase64URL.decode(try value.requiredString("rendezvous"), expectedBytes: 16)
            guard ["pc", "phone"].contains(try value.requiredString("role")) else {
                throw PCLinkError.badFrame("pair role")
            }
            try PCLinkValidation.requireMachineId(try value.requiredString("peerMachineId"))
        case "relay.pair.message":
            let object = try value.closedObject(required: ["v", "type", "rendezvous", "payload"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("pair v") }
            _ = try PCLinkBase64URL.decode(try value.requiredString("rendezvous"), expectedBytes: 16)
            guard object["payload"]?.objectValue != nil else {
                throw PCLinkError.badFrame("pair payload")
            }
        case "relay.pair.close":
            let object = try value.closedObject(required: ["v", "type", "rendezvous", "reason"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("pair v") }
            _ = try PCLinkBase64URL.decode(try value.requiredString("rendezvous"), expectedBytes: 16)
            guard let reason = object["reason"]?.stringValue, pairCloseReasons.contains(reason) else {
                throw PCLinkError.badFrame("pair close reason")
            }
        default:
            throw PCLinkError.badFrame("unknown pairing relay type")
        }
    }

    // MARK: E2E plane

    public static func validateE2EFrame(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "sid", "seq", "from", "to", "body"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "e2e" else {
            throw PCLinkError.badFrame("e2e header")
        }
        guard PCLinkValidation.sessionId(try value.requiredString("sid")) else {
            throw PCLinkError.badFrame("e2e sid")
        }
        guard let seq = object["seq"]?.intValue, seq >= 0, seq < Int64(PCLinkLimits.hardFrameThreshold) else {
            throw PCLinkError.badFrame("e2e seq")
        }
        try PCLinkValidation.requireMachineId(try value.requiredString("from"), field: "from")
        try PCLinkValidation.requireMachineId(try value.requiredString("to"), field: "to")
        let body = try value.requiredString("body")
        guard body.utf8.count <= 22_000_000 else { throw PCLinkError.badFrame("e2e body length") }
        _ = try PCLinkBase64URL.decode(body)
    }

    public static func validateE2EHandshake(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "type", "sid", "from", "to", "body"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "e2e.handshake" else {
            throw PCLinkError.badFrame("e2e.handshake header")
        }
        let sid = try value.requiredString("sid")
        guard PCLinkValidation.sessionId(sid) else { throw PCLinkError.badFrame("handshake sid") }
        try PCLinkValidation.requireMachineId(try value.requiredString("from"), field: "from")
        try PCLinkValidation.requireMachineId(try value.requiredString("to"), field: "to")
        guard let body = object["body"] else { throw PCLinkError.badFrame("missing handshake body") }
        guard let type = body["type"]?.stringValue else {
            throw PCLinkError.badFrame("missing handshake body type")
        }
        switch type {
        case "session.init":
            let bodyObject = try body.closedObject(required: ["v", "type", "sid", "suite", "eph", "nonce"])
            guard bodyObject["v"]?.intValue == 1,
                  bodyObject["suite"]?.stringValue == PCLinkCrypto.suite else {
                throw PCLinkError.badFrame("session.init suite/version")
            }
            guard bodyObject["sid"]?.stringValue == sid else {
                throw PCLinkError.badFrame("session.init sid")
            }
            _ = try PCLinkBase64URL.decode(body.requiredString("eph"), expectedBytes: 32)
            _ = try PCLinkBase64URL.decode(body.requiredString("nonce"), expectedBytes: 32)
        case "session.resp":
            let bodyObject = try body.closedObject(required: ["v", "type", "sid", "eph", "nonce", "sig", "confirm"])
            guard bodyObject["v"]?.intValue == 1, bodyObject["type"]?.stringValue == "session.resp" else {
                throw PCLinkError.badFrame("session.resp header")
            }
            guard bodyObject["sid"]?.stringValue == sid else {
                throw PCLinkError.badFrame("session.resp sid")
            }
            _ = try PCLinkBase64URL.decode(body.requiredString("eph"), expectedBytes: 32)
            _ = try PCLinkBase64URL.decode(body.requiredString("nonce"), expectedBytes: 32)
            _ = try PCLinkBase64URL.decode(body.requiredString("sig"), expectedBytes: 64)
            _ = try PCLinkBase64URL.decode(body.requiredString("confirm"), expectedBytes: 32)
        case "session.confirm":
            let bodyObject = try body.closedObject(required: ["v", "type", "sid", "sig", "confirm"])
            guard bodyObject["v"]?.intValue == 1, bodyObject["type"]?.stringValue == "session.confirm" else {
                throw PCLinkError.badFrame("session.confirm header")
            }
            guard bodyObject["sid"]?.stringValue == sid else {
                throw PCLinkError.badFrame("session.confirm sid")
            }
            _ = try PCLinkBase64URL.decode(body.requiredString("sig"), expectedBytes: 64)
            _ = try PCLinkBase64URL.decode(body.requiredString("confirm"), expectedBytes: 32)
        case "session.reject":
            let bodyObject = try body.closedObject(required: ["v", "type", "sid", "code"],
                                                   optional: ["message", "sig"])
            guard bodyObject["v"]?.intValue == 1, bodyObject["type"]?.stringValue == "session.reject",
                  bodyObject["sid"]?.stringValue == sid else {
                throw PCLinkError.badFrame("session.reject header")
            }
            guard let code = bodyObject["code"]?.stringValue,
                  sessionRejectCodes.contains(code) else {
                throw PCLinkError.badFrame("session.reject code")
            }
            if let message = bodyObject["message"] {
                guard let text = message.stringValue, text.utf8.count <= 512 else {
                    throw PCLinkError.badFrame("session.reject message")
                }
            }
            if let sig = bodyObject["sig"] {
                guard let text = sig.stringValue else { throw PCLinkError.badFrame("session.reject sig") }
                _ = try PCLinkBase64URL.decode(text, expectedBytes: 64)
            }
        default:
            throw PCLinkError.badFrame("unknown handshake body type")
        }
    }

    // MARK: Inner messages

    public static func validateInnerMessage(_ value: PCLinkJSON) throws {
        guard let type = value["type"]?.stringValue else {
            throw PCLinkError.badFrame("inner message has no type")
        }
        switch type {
        case "peer.hello":
            guard let role = value["role"]?.stringValue else {
                throw PCLinkError.badFrame("peer.hello role")
            }
            _ = try PCLinkPeerHello(json: value, expectedRole: role)
        case "rpc.call":
            let object = try value.closedObject(required: ["type", "id", "endpoint", "args"])
            guard let id = object["id"]?.stringValue, PCLinkValidation.correlationId(id) else {
                throw PCLinkError.badFrame("rpc.call id")
            }
            guard let endpoint = object["endpoint"]?.stringValue,
                  PCLinkValidation.endpoint(endpoint) else {
                throw PCLinkError.badFrame("rpc.call endpoint")
            }
            guard object["args"]?.objectValue != nil else {
                throw PCLinkError.badFrame("rpc.call args")
            }
        case "rpc.result":
            let header = try value.closedObject(required: ["type", "id", "ok"],
                                                optional: ["result", "error"])
            guard let id = header["id"]?.stringValue, PCLinkValidation.correlationId(id) else {
                throw PCLinkError.badFrame("rpc.result id")
            }
            guard let ok = header["ok"]?.boolValue else {
                throw PCLinkError.badFrame("rpc.result ok")
            }
            if ok {
                guard header["result"] != nil, header["error"] == nil else {
                    throw PCLinkError.badFrame("rpc.result ok shape")
                }
            } else {
                guard header["result"] == nil, let error = header["error"] else {
                    throw PCLinkError.badFrame("rpc.result error shape")
                }
                try validateRPCError(error)
            }
        case "rpc.result.chunk":
            let object = try value.closedObject(required: ["type", "id", "part", "last", "data"])
            guard let id = object["id"]?.stringValue, PCLinkValidation.correlationId(id) else {
                throw PCLinkError.badFrame("chunk id")
            }
            try validateChunkFields(object)
        case "rpc.stream.open":
            let object = try value.closedObject(required: ["type", "streamId", "endpoint", "payload"])
            guard let streamId = object["streamId"]?.stringValue,
                  PCLinkValidation.correlationId(streamId) else {
                throw PCLinkError.badFrame("streamId")
            }
            guard let endpoint = object["endpoint"]?.stringValue,
                  PCLinkValidation.endpoint(endpoint) else {
                throw PCLinkError.badFrame("stream endpoint")
            }
            guard let payload = object["payload"],
                  let payloadObject = try? payload.closedObject(required: ["args"]),
                  payloadObject["args"]?.objectValue != nil else {
                throw PCLinkError.badFrame("stream payload")
            }
        case "rpc.stream.item":
            let object = try value.closedObject(required: ["type", "streamId", "value"])
            guard let streamId = object["streamId"]?.stringValue,
                  PCLinkValidation.correlationId(streamId) else {
                throw PCLinkError.badFrame("streamId")
            }
            guard object["value"] != nil else { throw PCLinkError.badFrame("missing value") }
        case "rpc.stream.chunk":
            let object = try value.closedObject(required: ["type", "streamId", "part", "last", "data"])
            guard let streamId = object["streamId"]?.stringValue,
                  PCLinkValidation.correlationId(streamId) else {
                throw PCLinkError.badFrame("streamId")
            }
            try validateChunkFields(object)
        case "rpc.stream.end", "rpc.stream.cancel":
            let object = try value.closedObject(required: ["type", "streamId"])
            guard let streamId = object["streamId"]?.stringValue,
                  PCLinkValidation.correlationId(streamId) else {
                throw PCLinkError.badFrame("streamId")
            }
        case "rpc.stream.error":
            let object = try value.closedObject(required: ["type", "streamId", "error"])
            guard let streamId = object["streamId"]?.stringValue,
                  PCLinkValidation.correlationId(streamId) else {
                throw PCLinkError.badFrame("streamId")
            }
            try validateRPCError(object["error"]!)
        case "session.close":
            let object = try value.closedObject(required: ["type", "code"], optional: ["message"])
            guard let code = object["code"]?.stringValue, sessionCloseCodes.contains(code) else {
                throw PCLinkError.badFrame("session.close code")
            }
            if let message = object["message"] {
                guard let text = message.stringValue, text.utf8.count <= 512 else {
                    throw PCLinkError.badFrame("session.close message")
                }
            }
        case "pclink.notice":
            let object = try value.closedObject(required: ["type", "kind", "name", "fingerprint", "at"])
            guard object["kind"]?.stringValue == "paired" else {
                throw PCLinkError.badFrame("notice kind")
            }
            try PCLinkValidation.name(try value.requiredString("name"))
            guard try value.requiredString("fingerprint").range(
                of: #"^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$"#,
                options: .regularExpression) != nil else {
                throw PCLinkError.badFrame("notice fingerprint")
            }
            guard PCLinkValidation.timestamp(try value.requiredString("at")) else {
                throw PCLinkError.badFrame("notice at")
            }
        default:
            if type.range(of: #"^(?:task|call)\.[A-Za-z][A-Za-z0-9._-]{0,63}\.error$"#,
                          options: .regularExpression) != nil {
                let object = try value.closedObject(required: ["type", "code"], optional: ["id", "message"])
                guard object["code"]?.stringValue == "unavailable" else {
                    throw PCLinkError.badFrame("reserved error code")
                }
                if let id = object["id"] {
                    guard let text = id.stringValue, PCLinkValidation.correlationId(text) else {
                        throw PCLinkError.badFrame("reserved id")
                    }
                }
                if let message = object["message"] {
                    guard let text = message.stringValue, text.utf8.count <= 512 else {
                        throw PCLinkError.badFrame("reserved message")
                    }
                }
            } else {
                throw PCLinkError.badFrame("unknown inner type")
            }
        }
    }

    private static func validateRPCError(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["code", "message"], optional: ["details"])
        guard let code = object["code"]?.stringValue,
              code.range(of: #"^[A-Za-z0-9_$][A-Za-z0-9_$./:-]{0,127}$"#,
                         options: .regularExpression) != nil else {
            throw PCLinkError.badFrame("rpc error code")
        }
        guard let message = object["message"]?.stringValue,
              (1...2048).contains(message.utf8.count) else {
            throw PCLinkError.badFrame("rpc error message")
        }
        if let details = object["details"], details.objectValue == nil {
            throw PCLinkError.badFrame("rpc error details")
        }
    }

    private static func validateChunkFields(_ object: [String: PCLinkJSON]) throws {
        guard let part = object["part"]?.intValue, (0...65_535).contains(part) else {
            throw PCLinkError.badFrame("chunk part")
        }
        guard object["last"]?.boolValue != nil else {
            throw PCLinkError.badFrame("chunk last")
        }
        guard let data = object["data"]?.stringValue,
              (1...1_500_000).contains(data.utf8.count) else {
            throw PCLinkError.badFrame("chunk data length")
        }
        _ = try PCLinkBase64URL.decode(data)
    }

    // MARK: Pairing records (schema shape; key re-derivation is separate)

    /// Validates the closed record shape. This intentionally does not check
    /// that the machineId was re-derived from the public key: the schema
    /// samples use placeholder keys, while a real store loader (which does
    /// re-derive) is `PCLinkPairingRecord.init(json:)`.
    public static func validatePairingRecordShape(_ value: PCLinkJSON, phoneRecord: Bool) throws {
        var required: Set<String> = ["peerMachineId", "peerPublicKey", "peerName",
                                     "pairedAt", "relayOrigin", "connection"]
        if !phoneRecord { required.formUnion(["approvedAt", "approvedVia"]) }
        let object = try value.closedObject(required: required)
        try PCLinkValidation.requireMachineId(try value.requiredString("peerMachineId"))
        _ = try PCLinkBase64URL.decode(try value.requiredString("peerPublicKey"), expectedBytes: 32)
        try PCLinkValidation.name(try value.requiredString("peerName"))
        guard PCLinkValidation.timestamp(try value.requiredString("pairedAt")) else {
            throw PCLinkError.badFrame("pairedAt")
        }
        try PCLinkValidation.origin(try value.requiredString("relayOrigin"))
        guard let connection = object["connection"] else { throw PCLinkError.badFrame("connection") }
        let connectionObject = try connection.closedObject(required: ["mode"])
        guard connectionObject["mode"]?.stringValue == "relay" else {
            // `direct` is reserved and unsupported in v1 (§4.6).
            throw PCLinkError.versionUnsupported("unsupported connection mode")
        }
        if phoneRecord {
            guard object["approvedAt"] == nil, object["approvedVia"] == nil else {
                throw PCLinkError.badFrame("phone records must not carry approval fields")
            }
        } else {
            guard PCLinkValidation.timestamp(try value.requiredString("approvedAt")) else {
                throw PCLinkError.badFrame("approvedAt")
            }
            guard let via = object["approvedVia"]?.stringValue,
                  ["cli", "webui"].contains(via) else {
                throw PCLinkError.badFrame("approvedVia")
            }
        }
    }

    // MARK: Endpoint inventory

    public static func validateEndpointsInventory(_ value: PCLinkJSON) throws {
        let object = try value.closedObject(required: ["v", "suite", "dshTestedRange", "defaultRetry", "endpoints"])
        guard object["v"]?.intValue == 1,
              object["suite"]?.stringValue == PCLinkEndpoints.suite,
              object["dshTestedRange"]?.stringValue == PCLinkEndpoints.dshTestedRange,
              object["defaultRetry"]?.stringValue == "unsafe",
              let endpoints = object["endpoints"]?.arrayValue,
              (1...256).contains(endpoints.count) else {
            throw PCLinkError.badFrame("endpoint inventory header")
        }
        var names = Set<String>()
        for entry in endpoints {
            let fields = try entry.closedObject(required: ["name", "kind", "retry", "phoneOnly"],
                                                optional: ["notes", "sources"])
            guard let name = fields["name"]?.stringValue, PCLinkValidation.endpoint(name),
                  names.insert(name).inserted else {
                throw PCLinkError.badFrame("endpoint name")
            }
            guard let kind = fields["kind"]?.stringValue, ["unary", "stream"].contains(kind) else {
                throw PCLinkError.badFrame("endpoint kind")
            }
            guard let retry = fields["retry"]?.stringValue,
                  ["read", "idempotent", "unsafe"].contains(retry) else {
                throw PCLinkError.badFrame("endpoint retry")
            }
            guard fields["phoneOnly"]?.boolValue != nil else {
                throw PCLinkError.badFrame("endpoint phoneOnly")
            }
            if let notes = fields["notes"], let text = notes.stringValue {
                guard text.utf8.count <= 512 else { throw PCLinkError.badFrame("endpoint notes") }
            } else if fields["notes"] != nil {
                throw PCLinkError.badFrame("endpoint notes")
            }
            if let sources = fields["sources"] {
                guard let array = sources.arrayValue, (1...32).contains(array.count) else {
                    throw PCLinkError.badFrame("endpoint sources")
                }
                for source in array {
                    guard let text = source.stringValue,
                          text.range(of: #"^[A-Za-z0-9._/-]+:[0-9]+$"#,
                                     options: .regularExpression) != nil else {
                        throw PCLinkError.badFrame("endpoint source")
                    }
                }
            }
        }
    }
}
