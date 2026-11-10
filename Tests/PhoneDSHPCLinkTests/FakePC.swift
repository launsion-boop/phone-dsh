// SPDX-License-Identifier: MIT
// In-memory relay + PC used by the RelayDSHTransport tests. The fake PC speaks
// the real PCLink v1 handshake/AEAD using the module's crypto primitives, so the
// test exercises the real Swift state machines on both directions.

import Foundation
import XCTest
@testable import PhoneDSHPCLink

// MARK: - In-memory WebSocket

actor FakeInbox {
    private var messages: [PCLinkWebSocketMessage] = []
    private var waiter: CheckedContinuation<PCLinkWebSocketMessage?, Never>?
    private(set) var closed = false

    func push(_ message: PCLinkWebSocketMessage) -> Bool {
        guard !closed else { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            messages.append(message)
        }
        return true
    }

    func pop() async -> PCLinkWebSocketMessage? {
        if !messages.isEmpty { return messages.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

final class FakeWebSocket: PCLinkWebSocket, @unchecked Sendable {
    let inbox: FakeInbox
    let peer: FakeInbox
    /// Test-only hook used by the send-order pressure test.
    let sendHook: (@Sendable (String) async -> Void)?
    private(set) var closedCode: UInt16?

    init(inbox: FakeInbox, peer: FakeInbox,
         sendHook: (@Sendable (String) async -> Void)? = nil) {
        self.inbox = inbox
        self.peer = peer
        self.sendHook = sendHook
    }

    func send(text: String) async throws {
        if let sendHook { await sendHook(text) }
        let delivered = await peer.push(.text(text))
        guard delivered else { throw PCLinkError.peerOffline }
    }

    func receive() async throws -> PCLinkWebSocketMessage? {
        await inbox.pop()
    }

    func close(code: UInt16, reason: String) async {
        closedCode = code
        await inbox.close()
        await peer.close()
    }
}

enum FakeDuplex {
    static func make(clientSendHook: (@Sendable (String) async -> Void)? = nil)
        -> (client: FakeWebSocket, server: FakeWebSocket) {
        let clientInbox = FakeInbox()
        let serverInbox = FakeInbox()
        return (FakeWebSocket(inbox: clientInbox, peer: serverInbox, sendHook: clientSendHook),
                FakeWebSocket(inbox: serverInbox, peer: clientInbox))
    }
}

// MARK: - Fake PC server contract

enum FakeCallPolicy: Sendable {
    case normal
    case chunkedResult
    case partialResultFirst
    case dropFirst
    case relayOfflineFirst
    case relayOfflineWithIDFirst
    case rateLimitedFirst(retryAfterMs: Int)
    case unknownResultMember
    case corruptAEAD
    case ignore
}

enum FakeStreamPolicy: Sendable {
    case snapshotThenEnd
    case chunkedThenEnd
    case awaitCancelThenEnd
    case oversizeChunkThenEnd
    case partialChunkThenAwaitCancel
}

struct FakeCallRecord: Sendable {
    var sid: String
    var id: String
    var endpoint: String
    var args: PCLinkJSON
}

struct FakeOpenRecord: Sendable {
    var sid: String
    var streamId: String
    var endpoint: String
    var payload: PCLinkJSON
}

actor FakePCServer {
    let pcIdentity: PCLinkIdentity
    let phoneMachineId: String
    let phonePublicKey: Data
    let relayOrigin: String

    private(set) var connections = 0
    private(set) var calls: [FakeCallRecord] = []
    private(set) var opens: [FakeOpenRecord] = []
    private(set) var cancels: [String] = []
    private(set) var sessionIDs: [String] = []
    private(set) var handshakes = 0
    private(set) var receivedCloseCodes: [String] = []
    private(set) var reusedStreamIDs: [String] = []
    private(set) var receivedSeqs: [Int64] = []
    private(set) var sawOutOfOrderSeq = false
    private var lastReceivedSeq: Int64?
    private var usedStreamIDs = Set<String>()
    private var droppedEndpoints = Set<String>()
    private var policies: [String: FakeCallPolicy] = [:]
    private var streamPolicies: [String: FakeStreamPolicy] = [:]
    var result: PCLinkJSON = .object(["items": .array([])])
    var dshVersion = "0.2.2-rc.1"
    var caps = ["workspace/1", PCLinkCrypto.suite]
    var rejectUnpaired = false
    var extraResultMember = false
    private var pendingNotice = false

    init(pcIdentity: PCLinkIdentity, phoneMachineId: String, phonePublicKey: Data,
         relayOrigin: String) {
        self.pcIdentity = pcIdentity
        self.phoneMachineId = phoneMachineId
        self.phonePublicKey = phonePublicKey
        self.relayOrigin = relayOrigin
    }

    func registerConnection() -> Int {
        connections += 1
        return connections
    }

    func registerHandshake(_ sid: String) {
        handshakes += 1
        sessionIDs.append(sid)
    }

    func setPolicy(_ policy: FakeCallPolicy, for endpoint: String) {
        policies[endpoint] = policy
    }

    func setStreamPolicy(_ policy: FakeStreamPolicy, for endpoint: String) {
        streamPolicies[endpoint] = policy
    }

    func setResult(_ value: PCLinkJSON) {
        result = value
    }

    func setDSHVersion(_ version: String) {
        dshVersion = version
    }

    func setCaps(_ value: [String]) {
        caps = value
    }

    func recordCloseCode(_ code: String) {
        receivedCloseCodes.append(code)
    }

    /// Enforces §6.2 uniqueness on the real receive path: a second open with a
    /// previously used wire streamId is a protocol violation, not accepted.
    func registerOpenStreamID(_ streamID: String) -> Bool {
        guard usedStreamIDs.insert(streamID).inserted else {
            reusedStreamIDs.append(streamID)
            return false
        }
        return true
    }

    func noteReceivedSeq(_ seq: Int64) {
        receivedSeqs.append(seq)
        if let lastReceivedSeq {
            if seq != lastReceivedSeq + 1 { sawOutOfOrderSeq = true }
        } else if seq != 0 {
            sawOutOfOrderSeq = true
        }
        lastReceivedSeq = seq
    }

    func setRejectUnpaired(_ reject: Bool) {
        rejectUnpaired = reject
    }

    func queueNotice() {
        pendingNotice = true
    }

    func consumeNotice() -> Bool {
        defer { pendingNotice = false }
        return pendingNotice
    }

    var dshVersionValue: String { dshVersion }
    var rejectUnpairedValue: Bool { rejectUnpaired }
    var capsValue: [String] { caps }

    func handleCall(_ call: FakeCallRecord) -> FakeCallOutcome {
        calls.append(call)
        let policy = policies[call.endpoint] ?? .normal
        switch policy {
        case .normal:
            return .result(result)
        case .chunkedResult:
            return .chunkedResult(result)
        case .partialResultFirst:
            if !droppedEndpoints.contains(call.endpoint) {
                droppedEndpoints.insert(call.endpoint)
                return .partialResult(result)
            }
            return .result(result)
        case .dropFirst:
            if !droppedEndpoints.contains(call.endpoint) {
                droppedEndpoints.insert(call.endpoint)
                return .drop
            }
            return .result(result)
        case .relayOfflineFirst:
            if !droppedEndpoints.contains(call.endpoint) {
                droppedEndpoints.insert(call.endpoint)
                return .relayOffline(id: nil)
            }
            return .result(result)
        case .relayOfflineWithIDFirst:
            if !droppedEndpoints.contains(call.endpoint) {
                droppedEndpoints.insert(call.endpoint)
                return .relayOffline(id: call.id)
            }
            return .result(result)
        case .rateLimitedFirst(let retryAfterMs):
            if !droppedEndpoints.contains(call.endpoint) {
                droppedEndpoints.insert(call.endpoint)
                return .rateLimited(retryAfterMs: retryAfterMs)
            }
            return .result(result)
        case .unknownResultMember:
            return .unknownResultMember
        case .corruptAEAD:
            return .corruptAEAD
        case .ignore:
            return .ignore
        }
    }

    func handleOpen(_ open: FakeOpenRecord) -> FakeStreamPolicy {
        opens.append(open)
        return streamPolicies[open.endpoint] ?? .snapshotThenEnd
    }

    func recordCancel(_ streamId: String) {
        cancels.append(streamId)
    }
}

enum FakeCallOutcome: Sendable {
    case result(PCLinkJSON)
    case chunkedResult(PCLinkJSON)
    case partialResult(PCLinkJSON)
    case drop
    case relayOffline(id: String?)
    case rateLimited(retryAfterMs: Int)
    case unknownResultMember
    case corruptAEAD
    case ignore
}

// MARK: - Fake PC connection

final class FakePCConnection: @unchecked Sendable {
    private let server: FakePCServer
    private let phoneIdentity: PCLinkIdentity
    private let origin: String
    // Handshake state.
    private var sid: String?
    private var sidBytes: Data?
    private var th1: Data?
    private var th2: Data?
    private var pcEphemeral: PCLinkCrypto.EphemeralKey?
    private var pcNonce: Data?
    private var phoneEph: Data?
    private var phoneNonce: Data?
    private var keys: PCLinkCrypto.SessionKeys?
    private var sendSeq: UInt64 = 0
    private var lastRecvSeq: Int64?
    private var peerHelloReceived = false
    private var established = false
    private var waitingCancels = Set<String>()
    private var challengeNonceValue: Data?
    private var pcMachineId = ""
    private var pcIdentity: PCLinkIdentity?

    init(server: FakePCServer, phoneIdentity: PCLinkIdentity, origin: String) {
        self.server = server
        self.phoneIdentity = phoneIdentity
        self.origin = origin
    }

    func run(socket: FakeWebSocket) async {
        _ = await server.registerConnection()
        let identity = await server.pcIdentity
        pcIdentity = identity
        pcMachineId = identity.machineId
        let challengeNonce = try? PCLinkRandom.bytes(32)
        challengeNonceValue = challengeNonce
        if let challengeNonce {
            await sendRelay(socket, .object([
                "v": .int(1), "type": .string("relay.challenge"),
                "nonce": .string(PCLinkBase64URL.encode(challengeNonce)),
                "relay": .string(origin),
            ]))
        }
        var ready = false
        while true {
            guard let message = try? await socket.receive() else { return }
            guard case .text(let text) = message else { continue }
            guard let frame = try? PCLinkJSONParser.parseObject(Data(text.utf8)) else { continue }
            switch frame["type"]?.stringValue {
            case "relay.challenge", "relay.ready", "relay.error":
                continue
            case "relay.ping":
                if let nonce = frame["nonce"] {
                    await sendRelay(socket, .object(["v": .int(1), "type": .string("relay.pong"),
                                                     "nonce": nonce]))
                }
            case "relay.pong":
                continue
            case "peer.auth":
                guard !ready, verifyAuth(frame) else { return }
                ready = true
                await sendRelay(socket, .object([
                    "v": .int(1), "type": .string("relay.ready"),
                    "machineId": .string(phoneIdentity.machineId), "role": .string("phone"),
                ]))
            default:
                guard ready else { continue }
                if await handleFrame(frame, socket: socket) { return }
            }
        }
    }

    private func verifyAuth(_ frame: PCLinkJSON) -> Bool {
        guard let machineId = frame["machineId"]?.stringValue,
              machineId == phoneIdentity.machineId,
              let publicKeyText = frame["publicKey"]?.stringValue,
              let publicKey = try? PCLinkBase64URL.decode(publicKeyText, expectedBytes: 32),
              publicKey == phoneIdentity.publicKey,
              frame["role"]?.stringValue == "phone",
              let sigText = frame["sig"]?.stringValue,
              let signature = try? PCLinkBase64URL.decode(sigText, expectedBytes: 64),
              let nonce = challengeNonceValue else { return false }
        return PCLinkCrypto.ed25519Verify(
            publicKey: publicKey,
            message: PCLinkCrypto.relayAuthTranscript(origin: origin, nonce: nonce),
            signature: signature)
    }

    private func sendRelay(_ socket: FakeWebSocket, _ frame: PCLinkJSON) async {
        guard let text = try? PCLinkJSONEncoder.encodeString(frame) else { return }
        try? await socket.send(text: text)
    }

    /// Returns true when the connection must stop.
    private func handleFrame(_ frame: PCLinkJSON, socket: FakeWebSocket) async -> Bool {
        switch frame["type"]?.stringValue {
        case "e2e.handshake":
            await handleHandshake(frame, socket: socket)
            return false
        case "e2e":
            guard established, let keys else { return false }
            guard let sid = sid, frame["sid"]?.stringValue == sid,
                  frame["from"]?.stringValue == phoneIdentity.machineId,
                  frame["to"]?.stringValue == pcMachineId else {
                return false
            }
            guard let seq = frame["seq"]?.intValue, seq >= 0 else { return false }
            await server.noteReceivedSeq(seq)
            do {
                guard let body = try? PCLinkBase64URL.decode(
                    frame["body"]?.stringValue ?? "") else { return false }
                let aad = PCLinkCrypto.aad(sid: sid, seq: UInt64(seq),
                                           from: phoneIdentity.machineId,
                                           to: pcMachineId)
                let plaintext = try PCLinkCrypto.aeadOpen(
                    ciphertext: body, key: keys.phoneToPC,
                    nonce: PCLinkCrypto.aeadNonce(seq: UInt64(seq)), aad: aad)
                guard let inner = try? PCLinkJSONParser.parseObject(plaintext) else { return false }
                lastRecvSeq = seq
                if !peerHelloReceived {
                    guard inner["type"]?.stringValue == "peer.hello" else { return true }
                    peerHelloReceived = true
                    return false
                }
                await handleInner(inner, socket: socket)
            } catch {
                return true
            }
            return false
        case "session.close":
            return true
        default:
            return false
        }
    }

    private func handleHandshake(_ frame: PCLinkJSON, socket: FakeWebSocket) async {
        guard let body = frame["body"] else { return }
        switch body["type"]?.stringValue {
        case "session.init":
            guard let sidText = frame["sid"]?.stringValue,
                  let sidRaw = try? PCLinkBase64URL.decode(sidText, expectedBytes: 16),
                  body["sid"]?.stringValue == sidText,
                  body["suite"]?.stringValue == PCLinkCrypto.suite,
                  let ephRaw = try? PCLinkBase64URL.decode(
                    body["eph"]?.stringValue ?? "", expectedBytes: 32),
                  let nonceRaw = try? PCLinkBase64URL.decode(
                    body["nonce"]?.stringValue ?? "", expectedBytes: 32) else { return }
            if await server.rejectUnpairedValue {
                let code = "unpaired"
                let signature = try? pcIdentity?.sign(
                    PCLinkCrypto.sessionRejectTranscript(th1: PCLinkCrypto.sha256(
                        PCLinkCrypto.sessionInitTranscript(
                            phoneMachineId: phoneIdentity.machineId,
                            pcMachineId: pcMachineId,
                            sid: sidRaw, ephPhone: ephRaw, noncePhone: nonceRaw)), code: code))
                let th1 = PCLinkCrypto.sha256(PCLinkCrypto.sessionInitTranscript(
                    phoneMachineId: phoneIdentity.machineId, pcMachineId: pcMachineId,
                    sid: sidRaw, ephPhone: ephRaw, noncePhone: nonceRaw))
                await sendRelay(socket, .object([
                    "v": .int(1), "type": .string("e2e.handshake"),
                    "sid": .string(sidText), "from": .string(pcMachineId),
                    "to": .string(phoneIdentity.machineId),
                    "body": .object([
                        "v": .int(1), "type": .string("session.reject"),
                        "sid": .string(sidText), "code": .string(code),
                        "message": .string("no pairing record"),
                        "sig": .string(PCLinkBase64URL.encode(signature ?? Data())),
                    ]),
                ]))
                _ = th1
                return
            }
            do {
                let pcEph = try PCLinkCrypto.generateX25519()
                let pcNonce = try PCLinkRandom.bytes(32)
                let th1 = PCLinkCrypto.sha256(PCLinkCrypto.sessionInitTranscript(
                    phoneMachineId: phoneIdentity.machineId,
                    pcMachineId: pcMachineId,
                    sid: sidRaw, ephPhone: ephRaw, noncePhone: nonceRaw))
                let transcript = PCLinkCrypto.sessionRespTranscript(th1: th1, ephPc: pcEph.publicKey,
                                                                    noncePc: pcNonce)
                let th2 = PCLinkCrypto.sha256(transcript)
                let dh = try PCLinkCrypto.x25519SharedSecret(privateKey: pcEph.privateKey,
                                                             publicKey: ephRaw)
                let keys = PCLinkCrypto.sessionKeys(dh: dh, th2: th2)
                guard let identity = pcIdentity else { return }
                let signature = try identity.sign(transcript)
                let confirm = PCLinkCrypto.confirmation(key: keys.confirmPC, th: th2)
                self.sid = sidText
                self.sidBytes = sidRaw
                self.th1 = th1
                self.th2 = th2
                self.pcEphemeral = pcEph
                self.pcNonce = pcNonce
                self.phoneEph = ephRaw
                self.phoneNonce = nonceRaw
                self.keys = keys
                await server.registerHandshake(sidText)
                await sendRelay(socket, .object([
                    "v": .int(1),
                    "type": .string("e2e.handshake"),
                    "sid": .string(sidText),
                    "from": .string(pcMachineId),
                    "to": .string(phoneIdentity.machineId),
                    "body": .object([
                        "v": .int(1), "type": .string("session.resp"),
                        "sid": .string(sidText),
                        "eph": .string(PCLinkBase64URL.encode(pcEph.publicKey)),
                        "nonce": .string(PCLinkBase64URL.encode(pcNonce)),
                        "sig": .string(PCLinkBase64URL.encode(signature)),
                        "confirm": .string(PCLinkBase64URL.encode(confirm)),
                    ]),
                ]))
            } catch {
                return
            }
        case "session.confirm":
            guard let sid, let sidBytes, let th2, let keys,
                  body["sid"]?.stringValue == sid,
                  let sigText = body["sig"]?.stringValue,
                  let signature = try? PCLinkBase64URL.decode(sigText, expectedBytes: 64),
                  let confirmText = body["confirm"]?.stringValue,
                  let confirm = try? PCLinkBase64URL.decode(confirmText, expectedBytes: 32) else { return }
            let transcript = PCLinkCrypto.sessionConfirmTranscript(
                th2: th2, phoneMachineId: phoneIdentity.machineId,
                pcMachineId: pcMachineId, sid: sidBytes)
            let th3 = PCLinkCrypto.sha256(transcript)
            guard PCLinkCrypto.ed25519Verify(publicKey: phoneIdentity.publicKey,
                                             message: transcript, signature: signature),
                  PCLinkCrypto.constantTimeEquals(
                    confirm, PCLinkCrypto.confirmation(key: keys.confirmPhone, th: th3)) else { return }
            let hello = try? PCLinkPeerHello.make(
                role: "pc", caps: await server.capsValue,
                dshVersion: await server.dshVersionValue, dshCommit: "66491b05",
                appName: "dsh-pclink", appVersion: "0.1.0", name: "My PC")
            guard let hello else { return }
            established = true
            await sendInner(hello.json, socket: socket)
        default:
            return
        }
    }

    /// Chunked `rpc.result`; `partial` sends only part 0 with `last:false`
    /// and then goes silent (receiver timeout test).
    private func sendResultChunks(_ value: PCLinkJSON, id: String, partial: Bool,
                                  socket: FakeWebSocket) async {
        let result = PCLinkJSON.object([
            "type": .string("rpc.result"), "id": .string(id), "ok": .bool(true),
            "result": value,
        ])
        guard let bytes = try? PCLinkJSONEncoder.encode(result) else { return }
        let chunks = PCLinkChunking.split(bytes, chunkBytes: 11)
        for chunk in (partial ? chunks.prefix(1) : chunks[...]) {
            await sendInner(.object([
                "type": .string("rpc.result.chunk"), "id": .string(id),
                "part": .int(Int64(chunk.part)), "last": .bool(chunk.last),
                "data": .string(chunk.base64URL),
            ]), socket: socket)
        }
    }

    private func sendInner(_ inner: PCLinkJSON, socket: FakeWebSocket) async {
        guard let keys, let sid else { return }
        guard let plaintext = try? PCLinkJSONEncoder.encode(inner) else { return }
        let seq = sendSeq
        let aad = PCLinkCrypto.aad(sid: sid, seq: seq,
                                   from: pcMachineId,
                                   to: phoneIdentity.machineId)
        guard let body = try? PCLinkCrypto.aeadSeal(plaintext: plaintext, key: keys.pcToPhone,
                                                     nonce: PCLinkCrypto.aeadNonce(seq: seq),
                                                     aad: aad) else { return }
        sendSeq += 1
        await sendRelay(socket, .object([
            "v": .int(1), "type": .string("e2e"), "sid": .string(sid),
            "seq": .int(Int64(seq)),
            "from": .string(pcMachineId),
            "to": .string(phoneIdentity.machineId),
            "body": .string(PCLinkBase64URL.encode(body)),
        ]))
    }

    private func handleInner(_ inner: PCLinkJSON, socket: FakeWebSocket) async {
        guard let type = inner["type"]?.stringValue, let sid else { return }
        switch type {
        case "peer.hello":
            return
        case "rpc.call":
            guard let id = inner["id"]?.stringValue,
                  let endpoint = inner["endpoint"]?.stringValue else { return }
            let record = FakeCallRecord(sid: sid, id: id, endpoint: endpoint,
                                        args: inner["args"] ?? .null)
            if await server.consumeNotice() {
                await sendInner(.object([
                    "type": .string("pclink.notice"), "kind": .string("paired"),
                    "name": .string("Other iPhone"),
                    "fingerprint": .string("gewr-a3lz-quax"),
                    "at": .string("2026-11-09T00:00:05Z"),
                ]), socket: socket)
            }
            switch await server.handleCall(record) {
            case .result(let value):
                await sendInner(.object([
                    "type": .string("rpc.result"), "id": .string(id), "ok": .bool(true),
                    "result": value,
                ]), socket: socket)
            case .chunkedResult(let value):
                await sendResultChunks(value, id: id, partial: false, socket: socket)
            case .partialResult(let value):
                await sendResultChunks(value, id: id, partial: true, socket: socket)
            case .drop:
                await socket.close(code: 1001, reason: "drop")
                return
            case .relayOffline(let offlineID):
                var frame: PCLinkJSONObject = [
                    "v": .int(1), "type": .string("relay.offline"),
                    "to": .string(phoneIdentity.machineId), "sid": .string(sid),
                ]
                if let offlineID { frame["id"] = .string(offlineID) }
                await sendRelay(socket, .object(frame))
            case .rateLimited(let retryAfterMs):
                await sendRelay(socket, .object([
                    "v": .int(1), "type": .string("relay.error"),
                    "code": .string("rate_limited"),
                    "retryAfterMs": .int(Int64(retryAfterMs)),
                    "sid": .string(sid),
                ]))
            case .unknownResultMember:
                await sendInner(.object([
                    "type": .string("rpc.result"), "id": .string(id), "ok": .bool(true),
                    "result": .object([:]), "unexpected": .bool(true),
                ]), socket: socket)
            case .corruptAEAD:
                await sendCorruptInner(socket: socket)
            case .ignore:
                break
            }
        case "rpc.stream.open":
            guard let streamId = inner["streamId"]?.stringValue,
                  let endpoint = inner["endpoint"]?.stringValue else { return }
            guard await server.registerOpenStreamID(streamId) else {
                await sendInner(.object([
                    "type": .string("rpc.stream.error"), "streamId": .string(streamId),
                    "error": .object([
                        "code": .string("bad_frame"),
                        "message": .string("streamId was reused in this session"),
                    ]),
                ]), socket: socket)
                return
            }
            let record = FakeOpenRecord(sid: sid, streamId: streamId, endpoint: endpoint,
                                        payload: inner["payload"] ?? .null)
            let policy = await server.handleOpen(record)
            switch policy {
            case .snapshotThenEnd:
                await emitSnapshot(streamId: streamId, socket: socket)
                await sendInner(.object(["type": .string("rpc.stream.end"),
                                         "streamId": .string(streamId)]), socket: socket)
            case .chunkedThenEnd:
                let value: PCLinkJSON = .object(["type": .string("snapshot"),
                                                 "cursor": .int(0), "records": .array([])])
                let bytes = try? PCLinkJSONEncoder.encode(value)
                if let bytes {
                    for chunk in PCLinkChunking.split(bytes, chunkBytes: 7) {
                        await sendInner(.object([
                            "type": .string("rpc.stream.chunk"), "streamId": .string(streamId),
                            "part": .int(Int64(chunk.part)), "last": .bool(chunk.last),
                            "data": .string(chunk.base64URL),
                        ]), socket: socket)
                    }
                }
                await sendInner(.object(["type": .string("rpc.stream.end"),
                                         "streamId": .string(streamId)]), socket: socket)
            case .awaitCancelThenEnd:
                waitingCancels.insert(streamId)
                await emitSnapshot(streamId: streamId, socket: socket)
            case .oversizeChunkThenEnd:
                waitingCancels.insert(streamId)
                await sendInner(.object([
                    "type": .string("rpc.stream.chunk"), "streamId": .string(streamId),
                    "part": .int(0), "last": .bool(false),
                    "data": .string(String(repeating: "A",
                                           count: PCLinkLimits.maxChunkCharacters + 1)),
                ]), socket: socket)
            case .partialChunkThenAwaitCancel:
                waitingCancels.insert(streamId)
                await sendInner(.object([
                    "type": .string("rpc.stream.chunk"), "streamId": .string(streamId),
                    "part": .int(0), "last": .bool(false),
                    "data": .string(PCLinkBase64URL.encode(Data("partial".utf8))),
                ]), socket: socket)
            }
        case "rpc.stream.cancel":
            guard let streamId = inner["streamId"]?.stringValue else { return }
            await server.recordCancel(streamId)
            if waitingCancels.remove(streamId) != nil {
                await sendInner(.object(["type": .string("rpc.stream.end"),
                                         "streamId": .string(streamId)]), socket: socket)
            }
        case "session.close":
            if let code = inner["code"]?.stringValue {
                await server.recordCloseCode(code)
            }
            return
        default:
            if type.hasPrefix("task.") || type.hasPrefix("call.") {
                let prefix = type.split(separator: ".").first.map(String.init) ?? "task"
                await sendInner(.object([
                    "type": .string("\(prefix).reserved.error"),
                    "code": .string("unavailable"),
                ]), socket: socket)
            }
        }
    }

    /// Produces a structurally valid e2e frame whose AEAD tag is wrong. The
    /// phone must map that to `auth_failed` (§5.4), not `bad_frame`.
    private func sendCorruptInner(socket: FakeWebSocket) async {
        guard let keys, let sid else { return }
        let inner: PCLinkJSON = .object([
            "type": .string("rpc.result"), "id": .string("corrupt"), "ok": .bool(true),
            "result": .object([:]),
        ])
        guard let plaintext = try? PCLinkJSONEncoder.encode(inner) else { return }
        let seq = sendSeq
        let aad = PCLinkCrypto.aad(sid: sid, seq: seq,
                                   from: pcMachineId, to: phoneIdentity.machineId)
        guard var body = try? PCLinkCrypto.aeadSeal(plaintext: plaintext, key: keys.pcToPhone,
                                                    nonce: PCLinkCrypto.aeadNonce(seq: seq),
                                                    aad: aad),
              !body.isEmpty else { return }
        body[body.count - 1] ^= 0xFF
        sendSeq += 1
        await sendRelay(socket, .object([
            "v": .int(1), "type": .string("e2e"), "sid": .string(sid),
            "seq": .int(Int64(seq)),
            "from": .string(pcMachineId),
            "to": .string(phoneIdentity.machineId),
            "body": .string(PCLinkBase64URL.encode(body)),
        ]))
    }

    private func emitSnapshot(streamId: String, socket: FakeWebSocket) async {
        await sendInner(.object([
            "type": .string("rpc.stream.item"),
            "streamId": .string(streamId),
            "value": .object(["type": .string("snapshot"), "cursor": .int(0),
                              "records": .array([])]),
        ]), socket: socket)
    }
}

// MARK: - Factory

final class FakeRelayNetwork: PCLinkWebSocketFactory, @unchecked Sendable {
    let server: FakePCServer
    let phoneIdentity: PCLinkIdentity
    let origin: String
    let clientSendHook: (@Sendable (String) async -> Void)?

    private let dialLock = NSLock()
    private var dialFailures = 0
    private var dials = 0

    /// Dial count observed under the lock (tests assert the reconnect count).
    var dialCount: Int {
        dialLock.lock(); defer { dialLock.unlock() }
        return dials
    }

    init(server: FakePCServer, phoneIdentity: PCLinkIdentity, origin: String,
         clientSendHook: (@Sendable (String) async -> Void)? = nil) {
        self.server = server
        self.phoneIdentity = phoneIdentity
        self.origin = origin
        self.clientSendHook = clientSendHook
    }

    /// Fail the next `count` dials with a retryable network error. Drives the
    /// reconnect backoff without touching the fake PC's call policies.
    func failNextDials(_ count: Int) {
        dialLock.lock(); defer { dialLock.unlock() }
        dialFailures = count
    }

    private func takeDialFailure() -> Bool {
        dialLock.lock(); defer { dialLock.unlock() }
        dials += 1
        guard dialFailures > 0 else { return false }
        dialFailures -= 1
        return true
    }

    func connect(to url: URL) async throws -> any PCLinkWebSocket {
        if takeDialFailure() { throw PCLinkError.unavailable("dial refused by test") }
        let pair = FakeDuplex.make(clientSendHook: clientSendHook)
        let connection = FakePCConnection(server: server, phoneIdentity: phoneIdentity,
                                          origin: origin)
        Task { await connection.run(socket: pair.server) }
        return pair.client
    }
}

// MARK: - Client fixture

/// Clients created by fixtures are stopped at the end of each test so a leaked
/// reconnect loop from an earlier case cannot perturb a later one.
enum PCLinkTestTracker {
    private static let lock = NSLock()
    private static var clients: [PCLinkClient] = []

    static func track(_ client: PCLinkClient) {
        lock.lock(); defer { lock.unlock() }
        clients.append(client)
    }

    private static func takeAll() -> [PCLinkClient] {
        lock.lock(); defer { lock.unlock() }
        let current = clients
        clients.removeAll()
        return current
    }

    static func stopAll() async {
        let current = takeAll()
        for client in current {
            await client.stop()
        }
    }
}

struct PCLinkTestFixture {
    let phoneIdentity: PCLinkIdentity
    let pcIdentity: PCLinkIdentity
    let server: FakePCServer
    let network: FakeRelayNetwork
    let client: PCLinkClient
    let transport: RelayDSHTransport
    let origin = "https://relay.example"

    static func make(seedSuffix: String = UUID().uuidString,
                     configure: (inout PCLinkClientConfiguration) -> Void = { _ in },
                     clientSendHook: (@Sendable (String) async -> Void)? = nil,
                     prepareServer: (FakePCServer) async -> Void = { _ in }) async throws -> PCLinkTestFixture {
        let phone = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("pclink-test/phone/\(seedSuffix)".utf8)))
        let pc = try PCLinkIdentity(seed: PCLinkCrypto.sha256(Data("pclink-test/pc/\(seedSuffix)".utf8)))
        let server = FakePCServer(pcIdentity: pc, phoneMachineId: phone.machineId,
                                  phonePublicKey: phone.publicKey, relayOrigin: "https://relay.example")
        await prepareServer(server)
        let network = FakeRelayNetwork(server: server, phoneIdentity: phone,
                                       origin: "https://relay.example",
                                       clientSendHook: clientSendHook)
        var config = PCLinkClientConfiguration(
            websocketFactory: network,
            reconnectPolicy: PCLinkReconnectPolicy(delays: [0.01]),
            connectTimeout: 5,
            handshakeTimeout: 5,
            callRetryDeadline: 5,
            pairingTimeout: 5,
            pairingPromptTimeout: 5,
            heartbeatIntervalRange: 0.05...0.05,
            heartbeatEnabled: false)
        configure(&config)
        let record = TestSupport.record(peerMachineId: pc.machineId,
                                        peerPublicKey: pc.publicKey,
                                        peerName: "My PC",
                                        relayOrigin: "https://relay.example")
        let client = PCLinkClient(
            identityStore: InMemoryIdentityStore(seed: phone.seed),
            pairingStore: InMemoryPairingStore(record: record, phoneMachineId: phone.machineId),
            configuration: config)
        PCLinkTestTracker.track(client)
        try await client.start()
        let transport = RelayDSHTransport(client: client)
        return PCLinkTestFixture(phoneIdentity: phone, pcIdentity: pc, server: server,
                                 network: network, client: client, transport: transport)
    }
}
