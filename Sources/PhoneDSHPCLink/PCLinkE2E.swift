// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: PCLink v1 end-to-end session (phone initiator), AEAD frame
// rules, capability/version negotiation and chunk reassembly (§5, §6).

import Foundation

// MARK: - Limits / sequence rules

public struct PCLinkSessionThresholds: Equatable, Sendable {
    public var softFrames: Int64
    public var hardFrames: Int64
    public var softBytes: Int64
    public var hardBytes: Int64

    public init(softFrames: Int64 = Int64(PCLinkLimits.softFrameThreshold),
                hardFrames: Int64 = Int64(PCLinkLimits.hardFrameThreshold),
                softBytes: Int64 = Int64(PCLinkLimits.softByteThreshold),
                hardBytes: Int64 = Int64(PCLinkLimits.hardByteThreshold)) {
        self.softFrames = softFrames
        self.hardFrames = hardFrames
        self.softBytes = softBytes
        self.hardBytes = hardBytes
    }

    public static let v1 = PCLinkSessionThresholds()
}

public enum PCLinkSeqDecision: Equatable, Sendable {
    case accept
    case replay
    case badFrame
    case sessionExpired
}

public enum PCLinkSeqValidator {
    /// Strictly contiguous per direction; the hard frame/byte caps win before
    /// the contiguity check (§5.4).
    public static func evaluate(first: Bool, lastSeq: Int64?, seq: Int64, bytes: Int64,
                                thresholds: PCLinkSessionThresholds = .v1) -> PCLinkSeqDecision {
        if seq < 0 || seq >= thresholds.hardFrames { return .sessionExpired }
        if bytes >= thresholds.hardBytes { return .sessionExpired }
        if first {
            return seq == 0 ? .accept : .badFrame
        }
        guard let lastSeq else { return seq == 0 ? .accept : .badFrame }
        if seq <= lastSeq { return .replay }
        if seq != lastSeq + 1 { return .badFrame }
        return .accept
    }
}

// MARK: - Chunking

public struct PCLinkChunk: Equatable, Sendable {
    public var part: Int
    public var last: Bool
    public var data: Data

    public init(part: Int, last: Bool, data: Data) {
        self.part = part
        self.last = last
        self.data = data
    }

    public var base64URL: String { PCLinkBase64URL.encode(data) }
}

public enum PCLinkChunking {
    /// Splits a JSON encoding into `chunkBytes` raw byte ranges. A value up to
    /// 1 MiB is sent as one item by the caller; this helper is used whenever a
    /// chunked sequence is needed and by the shared-fixture tests.
    public static func split(_ data: Data, chunkBytes: Int) -> [PCLinkChunk] {
        let size = max(1, chunkBytes)
        guard !data.isEmpty else { return [PCLinkChunk(part: 0, last: true, data: Data())] }
        var chunks: [PCLinkChunk] = []
        var offset = 0
        var part = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            chunks.append(PCLinkChunk(part: part, last: end == data.count,
                                      data: data.subdata(in: offset..<end)))
            offset = end
            part += 1
        }
        return chunks
    }
}

public struct PCLinkChunkReassembler: Sendable {
    private struct Buffer {
        var expectedPart: Int
        var bytes: Data
        var startedAt: Date
    }

    private var buffers: [String: Buffer] = [:]

    public init() {}

    public mutating func discard(key: String) {
        buffers.removeValue(forKey: key)
    }

    public mutating func discardAll() {
        buffers.removeAll()
    }

    /// Asserts that no partial value is left unfinished. Used by the shared
    /// fixture model row where a set of interleaved chunks never carries the
    /// final `last` for one stream.
    public mutating func finish() throws {
        guard buffers.isEmpty else {
            buffers.removeAll()
            throw PCLinkError.badFrame("chunk sequence is missing its last part")
        }
    }

    public var pendingKeys: Set<String> { Set(buffers.keys) }

    /// Accepts one chunk frame for `key`. Returns the reassembled bytes when
    /// `last` completes the sequence. A malformed sequence, an over-limit
    /// value or a 30 s timeout throws and discards the partial value.
    public mutating func accept(key: String, part: Int, last: Bool, dataBase64: String,
                                now: Date = Date(),
                                timeout: TimeInterval = PCLinkLimits.chunkReassemblyTimeout)
        throws -> Data? {
        do {
            guard part >= 0, part <= 65_535 else {
                throw PCLinkError.badFrame("chunk part out of range")
            }
            guard dataBase64.utf8.count <= PCLinkLimits.maxChunkCharacters else {
                throw PCLinkError.frameTooLarge("chunk data exceeds 1,500,000 characters")
            }
            let data = try PCLinkBase64URL.decode(dataBase64)
            var buffer: Buffer
            if let existing = buffers[key] {
                guard now.timeIntervalSince(existing.startedAt) <= timeout else {
                    throw PCLinkError.badFrame("chunk sequence timed out")
                }
                guard part == existing.expectedPart else {
                    throw PCLinkError.badFrame("chunk part order violation")
                }
                buffer = existing
            } else {
                guard part == 0 else {
                    throw PCLinkError.badFrame("chunk sequence did not start at part 0")
                }
                buffer = Buffer(expectedPart: 0, bytes: Data(), startedAt: now)
            }
            guard buffer.bytes.count + data.count <= PCLinkLimits.maxValueBytes else {
                throw PCLinkError.frameTooLarge("reassembled value exceeds 8 MiB")
            }
            buffer.bytes.append(data)
            buffer.expectedPart += 1
            if last {
                buffers.removeValue(forKey: key)
                guard String(data: buffer.bytes, encoding: .utf8) != nil else {
                    throw PCLinkError.badFrame("reassembled value is not UTF-8")
                }
                do {
                    _ = try PCLinkJSONParser.parse(buffer.bytes)
                } catch {
                    throw PCLinkError.badFrame("reassembled value is not one JSON value")
                }
                return buffer.bytes
            }
            buffers[key] = buffer
            return nil
        } catch {
            buffers.removeValue(forKey: key)
            throw error
        }
    }
}

// MARK: - peer.hello

public struct PCLinkPeerHello: Equatable, Sendable {
    public var role: String
    public var caps: [String]
    public var dshVersionText: String
    public var dshVersion: PCLinkValidation.SemVer
    public var dshCommit: String?
    public var appName: String
    public var appVersion: String
    public var name: String

    public static let requiredCapabilities: Set<String> = [
        "workspace/1",
        PCLinkCrypto.suite,
    ]

    public var supportsPCLink: Bool {
        Self.requiredCapabilities.isSubset(of: Set(caps))
    }

    /// Out-of-range DSH versions only produce a UI warning, never a failed
    /// connection (§5.6).
    public var versionWarning: Bool {
        !PCLinkValidation.dshVersionInTestedRange(dshVersion)
    }

    public init(json value: PCLinkJSON, expectedRole: String) throws {
        let object = try value.closedObject(required: ["v", "type", "role", "caps", "dsh", "app", "name"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "peer.hello" else {
            throw PCLinkError.badFrame("peer.hello header")
        }
        let role = try value.requiredString("role")
        guard role == expectedRole else {
            throw PCLinkError.badFrame("peer.hello role is \(role), expected \(expectedRole)")
        }
        guard let capValues = object["caps"]?.arrayValue else {
            throw PCLinkError.badFrame("peer.hello caps must be an array")
        }
        guard (1...16).contains(capValues.count) else {
            throw PCLinkError.badFrame("peer.hello caps count")
        }
        var caps: [String] = []
        var seen = Set<String>()
        for capValue in capValues {
            guard let cap = capValue.stringValue,
                  cap.utf8.count <= 64,
                  cap.range(of: #"^[A-Za-z0-9._/-]{1,64}$"#, options: .regularExpression) != nil else {
                throw PCLinkError.badFrame("peer.hello capability is malformed")
            }
            guard seen.insert(cap).inserted else {
                throw PCLinkError.badFrame("peer.hello capability is duplicated")
            }
            caps.append(cap)
        }
        guard let dshValue = object["dsh"] else { throw PCLinkError.badFrame("missing dsh") }
        let dsh = try dshValue.closedObject(required: ["version"], optional: ["commit"])
        let versionText = try dshValue.requiredString("version")
        guard let version = PCLinkValidation.SemVer.parse(versionText) else {
            throw PCLinkError.badFrame("dsh.version is not SemVer")
        }
        var commit: String?
        if let commitValue = dsh["commit"] {
            guard let text = commitValue.stringValue,
                  (7...64).contains(text.utf8.count),
                  text.unicodeScalars.allSatisfy({ ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x61 && $0.value <= 0x66) }) else {
                throw PCLinkError.badFrame("dsh.commit must be 7-64 lowercase hex")
            }
            commit = text
        }
        guard let appValue = object["app"] else { throw PCLinkError.badFrame("missing app") }
        let app = try appValue.closedObject(required: ["name", "version"])
        let appName = try appValue.requiredString("name")
        try PCLinkValidation.name(appName)
        let appVersion = try appValue.requiredString("version")
        guard appVersion.range(of: #"^[0-9A-Za-z.+-]{1,32}$"#, options: .regularExpression) != nil else {
            throw PCLinkError.badFrame("app.version is malformed")
        }
        let name = try value.requiredString("name")
        try PCLinkValidation.name(name)
        self.role = role
        self.caps = caps
        self.dshVersionText = versionText
        self.dshVersion = version
        self.dshCommit = commit
        self.appName = appName
        self.appVersion = appVersion
        self.name = name
    }

    public static func make(role: String, caps: [String], dshVersion: String, dshCommit: String?,
                            appName: String, appVersion: String, name: String) throws -> PCLinkPeerHello {
        var dsh: PCLinkJSONObject = ["version": .string(dshVersion)]
        if let dshCommit { dsh["commit"] = .string(dshCommit) }
        let json: PCLinkJSON = .object([
            "v": .int(1),
            "type": .string("peer.hello"),
            "role": .string(role),
            "caps": .array(caps.map(PCLinkJSON.string)),
            "dsh": .object(dsh),
            "app": .object(["name": .string(appName), "version": .string(appVersion)]),
            "name": .string(name),
        ])
        return try PCLinkPeerHello(json: json, expectedRole: role)
    }

    public var json: PCLinkJSON {
        var dsh: PCLinkJSONObject = ["version": .string(dshVersionText)]
        if let dshCommit { dsh["commit"] = .string(dshCommit) }
        return .object([
            "v": .int(1),
            "type": .string("peer.hello"),
            "role": .string(role),
            "caps": .array(caps.map(PCLinkJSON.string)),
            "dsh": .object(dsh),
            "app": .object(["name": .string(appName), "version": .string(appVersion)]),
            "name": .string(name),
        ])
    }
}

// MARK: - Session

public enum PCLinkRejectVerification: Equatable, Sendable {
    /// Signature verified with the pinned PC key over this handshake's th1 and
    /// the exact code. Only `unpaired` may prompt the user to delete a record.
    case verified(code: String, message: String)
    /// Missing/invalid signature or a mismatched transcript: the reject is just
    /// a failed handshake and never authoritative for the pairing record.
    case unauthenticated(code: String, message: String)
}

public struct PCLinkDecodedFrame: Equatable, Sendable {
    public var inner: PCLinkJSON
    public var seq: UInt64
    public var outer: PCLinkJSON
}

public enum PCLinkSessionPhase: Equatable, Sendable {
    case awaitingResp
    case awaitingHello
    case established
    case closed
}

/// The phone side of one E2E session. It is a reference type used only inside
/// the `PCLinkClient` actor (and the tests); it is not `Sendable`.
public final class PCLinkE2ESession {
    public let identity: PCLinkIdentity
    public let peer: PCLinkPairingRecord
    public let thresholds: PCLinkSessionThresholds

    public let sidBytes: Data
    public let sid: String
    public private(set) var ephemeralPublicKey: Data
    private var ephemeralPrivateKey: Data
    public let phoneNonce: Data
    public let th1: Data
    public let initTranscript: Data

    public private(set) var phase: PCLinkSessionPhase = .awaitingResp
    public private(set) var keys: PCLinkCrypto.SessionKeys?
    public private(set) var th2: Data?
    public private(set) var th3: Data?
    public private(set) var sentFrames: Int64 = 0
    public private(set) var sentBytes: Int64 = 0
    public private(set) var receivedFrames: Int64 = 0
    public private(set) var receivedBytes: Int64 = 0
    public private(set) var lastReceivedSeq: Int64?
    public private(set) var peerHelloReceived = false
    public private(set) var needsRekey = false
    public private(set) var establishedAt: Date?

    public convenience init(identity: PCLinkIdentity, peer: PCLinkPairingRecord,
                            thresholds: PCLinkSessionThresholds = .v1) throws {
        let sidBytes = try PCLinkRandom.bytes(16)
        let ephemeral = try PCLinkCrypto.generateX25519()
        let nonce = try PCLinkRandom.bytes(32)
        try self.init(identity: identity, peer: peer,
                      sidBytes: sidBytes, ephemeral: ephemeral, phoneNonce: nonce,
                      thresholds: thresholds)
    }

    /// Deterministic form used by the shared golden vectors and tests.
    init(identity: PCLinkIdentity, peer: PCLinkPairingRecord,
         sidBytes: Data, ephemeral: PCLinkCrypto.EphemeralKey,
         phoneNonce: Data, thresholds: PCLinkSessionThresholds = .v1) throws {
        guard sidBytes.count == 16, ephemeral.privateKey.count == 32,
              ephemeral.publicKey.count == 32, phoneNonce.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 16, actual: sidBytes.count)
        }
        self.identity = identity
        self.peer = peer
        self.thresholds = thresholds
        self.sidBytes = sidBytes
        self.sid = PCLinkBase64URL.encode(sidBytes)
        self.ephemeralPublicKey = ephemeral.publicKey
        self.ephemeralPrivateKey = ephemeral.privateKey
        self.phoneNonce = phoneNonce
        let transcript = PCLinkCrypto.sessionInitTranscript(
            phoneMachineId: identity.machineId,
            pcMachineId: peer.peerMachineId,
            sid: sidBytes,
            ephPhone: ephemeral.publicKey,
            noncePhone: phoneNonce)
        self.initTranscript = transcript
        self.th1 = PCLinkCrypto.sha256(transcript)
    }

    public var initBody: PCLinkJSON {
        .object([
            "v": .int(1),
            "type": .string("session.init"),
            "sid": .string(sid),
            "suite": .string(PCLinkCrypto.suite),
            "eph": .string(PCLinkBase64URL.encode(ephemeralPublicKey)),
            "nonce": .string(PCLinkBase64URL.encode(phoneNonce)),
        ])
    }

    public var initFrame: PCLinkJSON {
        handshakeFrame(body: initBody)
    }

    public func handshakeFrame(body: PCLinkJSON) -> PCLinkJSON {
        .object([
            "v": .int(1),
            "type": .string("e2e.handshake"),
            "sid": .string(sid),
            "from": .string(identity.machineId),
            "to": .string(peer.peerMachineId),
            "body": body,
        ])
    }

    /// Verifies the PC's `session.resp`: pinned-key signature, transcript hash
    /// and PC confirmation, then derives the traffic/confirmation keys.
    public func acceptResp(outer: PCLinkJSON) throws {
        guard phase == .awaitingResp else { throw PCLinkError.badFrame("session.resp out of order") }
        let outerObject = try outer.closedObject(required: ["v", "type", "sid", "from", "to", "body"])
        guard outerObject["v"]?.intValue == 1,
              outerObject["type"]?.stringValue == "e2e.handshake" else {
            throw PCLinkError.badFrame("session.resp carrier")
        }
        guard try outer.requiredString("sid") == sid else {
            throw PCLinkError.replay("handshake sid mismatch")
        }
        guard try outer.requiredString("from") == peer.peerMachineId,
              try outer.requiredString("to") == identity.machineId else {
            throw PCLinkError.badFrame("session.resp direction mismatch")
        }
        guard let body = outerObject["body"] else { throw PCLinkError.badFrame("missing body") }
        let bodyObject = try body.closedObject(required: ["v", "type", "sid", "eph", "nonce", "sig", "confirm"])
        guard bodyObject["v"]?.intValue == 1,
              bodyObject["type"]?.stringValue == "session.resp" else {
            throw PCLinkError.badFrame("not a session.resp")
        }
        guard try body.requiredString("sid") == sid else {
            throw PCLinkError.replay("session.resp body sid mismatch")
        }
        let ephPC = try PCLinkBase64URL.decode(body.requiredString("eph"), expectedBytes: 32)
        let noncePC = try PCLinkBase64URL.decode(body.requiredString("nonce"), expectedBytes: 32)
        let signature = try PCLinkBase64URL.decode(body.requiredString("sig"), expectedBytes: 64)
        let confirmText = try body.requiredString("confirm")
        let confirmPC = try PCLinkBase64URL.decode(confirmText, expectedBytes: 32)
        guard ephPC.contains(where: { $0 != 0 }) else {
            throw PCLinkError.authFailed("PC ephemeral key is all zero")
        }
        let respTranscript = PCLinkCrypto.sessionRespTranscript(th1: th1, ephPc: ephPC, noncePc: noncePC)
        guard PCLinkCrypto.ed25519Verify(publicKey: peer.peerPublicKey,
                                         message: respTranscript,
                                         signature: signature) else {
            throw PCLinkError.authFailed("session.resp signature is invalid")
        }
        let th2 = PCLinkCrypto.sha256(respTranscript)
        let dh = try PCLinkCrypto.x25519SharedSecret(privateKey: ephemeralPrivateKey, publicKey: ephPC)
        let keys = PCLinkCrypto.sessionKeys(dh: dh, th2: th2)
        let expectedConfirm = PCLinkCrypto.confirmation(key: keys.confirmPC, th: th2)
        guard PCLinkCrypto.constantTimeEquals(expectedConfirm, confirmPC) else {
            throw PCLinkError.authFailed("PC key confirmation is invalid")
        }
        self.keys = keys
        self.th2 = th2
        phase = .awaitingHello
    }

    public func confirmFrame() throws -> PCLinkJSON {
        guard let keys, let th2 else { throw PCLinkError.badFrame("keys are not installed") }
        let confirmTranscript = PCLinkCrypto.sessionConfirmTranscript(
            th2: th2, phoneMachineId: identity.machineId,
            pcMachineId: peer.peerMachineId, sid: sidBytes)
        let signature = try identity.sign(confirmTranscript)
        let th3 = PCLinkCrypto.sha256(confirmTranscript)
        let confirm = PCLinkCrypto.confirmation(key: keys.confirmPhone, th: th3)
        self.th3 = th3
        return handshakeFrame(body: .object([
            "v": .int(1),
            "type": .string("session.confirm"),
            "sid": .string(sid),
            "sig": .string(PCLinkBase64URL.encode(signature)),
            "confirm": .string(PCLinkBase64URL.encode(confirm)),
        ]))
    }

    /// The first AEAD frame in the phone→PC direction.
    public func makePeerHelloFrame(hello: PCLinkPeerHello) throws -> PCLinkJSON {
        guard phase == .awaitingHello, keys != nil, !peerHelloReceived else {
            throw PCLinkError.badFrame("peer.hello out of order")
        }
        return try seal(hello.json)
    }

    /// The PC's first AEAD frame must be `peer.hello`; validates capabilities
    /// and the DSH version range. No cap intersection is
    /// `version_unsupported`; an out-of-range DSH version is only a warning.
    @discardableResult
    public func acceptFirstInner(_ inner: PCLinkJSON) throws -> PCLinkPeerHello {
        guard phase == .awaitingHello, !peerHelloReceived else {
            throw PCLinkError.badFrame("first inner message is not peer.hello")
        }
        let hello = try PCLinkPeerHello(json: inner, expectedRole: "pc")
        guard hello.supportsPCLink else {
            throw PCLinkError.versionUnsupported("no workspace/1 + suite capability intersection")
        }
        peerHelloReceived = true
        phase = .established
        establishedAt = Date()
        return hello
    }

    // MARK: Sealing / opening

    public func seal(_ inner: PCLinkJSON) throws -> PCLinkJSON {
        guard keys != nil, phase != .closed else { throw PCLinkError.sessionExpired("session is closed") }
        guard sentFrames < thresholds.hardFrames,
              sentBytes < thresholds.hardBytes else {
            throw PCLinkError.sessionExpired("hard session cap reached")
        }
        let plaintext = try PCLinkJSONEncoder.encode(inner)
        let seq = UInt64(sentFrames)
        let nonce = PCLinkCrypto.aeadNonce(seq: seq)
        let aad = PCLinkCrypto.aad(sid: sid, seq: seq, from: identity.machineId, to: peer.peerMachineId)
        guard let keys else { throw PCLinkError.sessionExpired("session is closed") }
        let body = try PCLinkCrypto.aeadSeal(plaintext: plaintext, key: keys.phoneToPC,
                                             nonce: nonce, aad: aad)
        sentFrames += 1
        sentBytes += Int64(plaintext.count)
        if sentFrames >= thresholds.softFrames || sentBytes >= thresholds.softBytes {
            needsRekey = true
        }
        return .object([
            "v": .int(1),
            "type": .string("e2e"),
            "sid": .string(sid),
            "seq": .int(Int64(seq)),
            "from": .string(identity.machineId),
            "to": .string(peer.peerMachineId),
            "body": .string(PCLinkBase64URL.encode(body)),
        ])
    }

    public func open(_ outer: PCLinkJSON) throws -> PCLinkDecodedFrame {
        guard phase != .closed else { throw PCLinkError.sessionExpired("session is closed") }
        let object = try outer.closedObject(required: ["v", "type", "sid", "seq", "from", "to", "body"])
        guard object["v"]?.intValue == 1, object["type"]?.stringValue == "e2e" else {
            throw PCLinkError.badFrame("not an e2e frame")
        }
        let outerSid = try outer.requiredString("sid")
        guard PCLinkValidation.sessionId(outerSid) else { throw PCLinkError.badFrame("bad sid") }
        guard outerSid == sid else { throw PCLinkError.replay("frame for an unknown sid") }
        let from = try outer.requiredString("from")
        let to = try outer.requiredString("to")
        guard from == peer.peerMachineId, to == identity.machineId else {
            throw PCLinkError.authFailed("e2e direction mismatch")
        }
        let seq64 = try outer.requiredInt("seq")
        guard seq64 >= 0, seq64 < thresholds.hardFrames else {
            throw PCLinkError.sessionExpired("seq hard cap")
        }
        let body = try PCLinkBase64URL.decode(try outer.requiredString("body"))
        guard body.count >= 16 else { throw PCLinkError.badFrame("AEAD body too short") }
        let first = lastReceivedSeq == nil
        let plaintextBytes = Int64(body.count - 16)
        let decision = PCLinkSeqValidator.evaluate(first: first, lastSeq: lastReceivedSeq,
                                                   seq: seq64,
                                                   bytes: receivedBytes + plaintextBytes,
                                                   thresholds: thresholds)
        switch decision {
        case .accept: break
        case .replay: throw PCLinkError.replay("seq did not advance")
        case .badFrame: throw PCLinkError.badFrame("seq gap")
        case .sessionExpired: throw PCLinkError.sessionExpired("hard session cap reached")
        }
        guard let keys else { throw PCLinkError.badFrame("keys are not installed") }
        let nonce = PCLinkCrypto.aeadNonce(seq: UInt64(seq64))
        let aad = PCLinkCrypto.aad(sid: sid, seq: UInt64(seq64), from: from, to: to)
        let plaintext = try PCLinkCrypto.aeadOpen(ciphertext: body, key: keys.pcToPhone,
                                                  nonce: nonce, aad: aad)
        let inner = try PCLinkJSONParser.parseObject(plaintext)
        lastReceivedSeq = seq64
        receivedFrames += 1
        receivedBytes += Int64(plaintext.count)
        if receivedFrames >= thresholds.softFrames || receivedBytes >= thresholds.softBytes {
            needsRekey = true
        }
        return PCLinkDecodedFrame(inner: inner, seq: UInt64(seq64), outer: outer)
    }

    // MARK: Reject / close

    /// Verifies a `session.reject` with the pinned PC key and this handshake's
    /// own th1. A missing/invalid signature is unauthenticated and never
    /// authoritative for the pairing record.
    public func verifyReject(_ body: PCLinkJSON) -> PCLinkRejectVerification {
        guard let object = try? body.closedObject(required: ["v", "type", "sid", "code"],
                                                  optional: ["message", "sig"]),
              object["v"]?.intValue == 1,
              object["type"]?.stringValue == "session.reject",
              let sidText = object["sid"]?.stringValue, sidText == sid,
              let code = object["code"]?.stringValue else {
            return .unauthenticated(code: "bad_frame", message: "malformed session.reject")
        }
        let message = object["message"]?.stringValue ?? ""
        // `code`/`message` are PCLink-owned fields (§2.3); a decoded U+0000 is
        // not a DSH passthrough value and makes the reject malformed.
        if code.unicodeScalars.contains(where: { $0.value == 0 })
            || message.unicodeScalars.contains(where: { $0.value == 0 }) {
            return .unauthenticated(code: "bad_frame", message: "malformed session.reject")
        }
        guard let sigText = object["sig"]?.stringValue,
              let signature = try? PCLinkBase64URL.decode(sigText, expectedBytes: 64) else {
            return .unauthenticated(code: code, message: message)
        }
        let transcript = PCLinkCrypto.sessionRejectTranscript(th1: th1, code: code)
        guard PCLinkCrypto.ed25519Verify(publicKey: peer.peerPublicKey,
                                         message: transcript,
                                         signature: signature) else {
            return .unauthenticated(code: code, message: message)
        }
        return .verified(code: code, message: message)
    }

    /// Standalone form used by the shared negative vectors: a signature valid
    /// for init A must fail against init B's th1 or a code-swapped transcript.
    public static func verifyRejectSignature(signature: Data, code: String, th1: Data,
                                             pcPublicKey: Data) -> Bool {
        PCLinkCrypto.ed25519Verify(publicKey: pcPublicKey,
                                   message: PCLinkCrypto.sessionRejectTranscript(th1: th1, code: code),
                                   signature: signature)
    }

    public func closeFrame(code: String, message: String? = nil) throws -> PCLinkJSON {
        var object: PCLinkJSONObject = ["type": .string("session.close"), "code": .string(code)]
        if let message { object["message"] = .string(message) }
        return try seal(.object(object))
    }

    public func markClosed() {
        phase = .closed
        keys = nil
        invalidateEphemeral()
    }

    private func invalidateEphemeral() {
        // Drop the private scalar when the handshake fails or the session
        // closes (§5.2). `Data` is copied on use, so this removes the only
        // reference this object holds.
        ephemeralPrivateKey = Data()
        ephemeralPrivateRetained = false
    }

    public private(set) var ephemeralPrivateRetained = true
}
