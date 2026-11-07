// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
@testable import PhoneDSHBot

struct BotScriptedEvent {
    let type: String
    let data: BotJSONValue
    let time: Int64
    let stream: Bool

    init(_ type: String, _ data: BotJSONValue = .object([:]), time: Int64 = 1_000, stream: Bool = false) {
        self.type = type
        self.data = data
        self.time = time
        self.stream = stream
    }

    static func turn(_ number: Int = 1, time: Int64 = 1_000) -> Self {
        Self("turn/start", .object(["turn": .number(Double(number))]), time: time)
    }

    static func assistant(_ text: String, time: Int64 = 1_010) -> Self {
        Self("assistant/message", .object([
            "message": .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
            "usage": .object([
                "inputTokens": .number(10), "outputTokens": .number(5),
                "cacheReadTokens": .number(4), "cacheWriteTokens": .number(2),
            ]),
        ]), time: time)
    }

    static func delta(_ text: String, time: Int64 = 1_005) -> Self {
        Self("assistant-stream", .object([
            "type": .string("chunk"),
            "chunk": .object(["type": .string("text-delta"), "text": .string(text)]),
        ]), time: time, stream: true)
    }

    static func toolCall(_ name: String, id: String = "call-1", time: Int64 = 1_002) -> Self {
        Self("tool/call", .object([
            "callId": .string(id), "name": .string(name), "arguments": .string("{}"),
        ]), time: time)
    }

    static func toolResult(id: String = "call-1", failed: Bool = false, time: Int64 = 1_003) -> Self {
        Self("tool/result", .object([
            "message": .object([
                "toolCallId": .string(id), "isError": .bool(failed),
                "content": .array([.object(["type": .string("text"), "text": .string("已显示提问卡")])]),
            ]),
        ]), time: time)
    }

    static func end(_ reason: String = "completed", turn: Int = 1, time: Int64 = 1_020) -> Self {
        Self("turn/end", .object([
            "turn": .number(Double(turn)), "reason": .object(["kind": .string(reason)]),
        ]), time: time)
    }
}

private actor BotScriptedGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

final class BotScriptedRemoteTransport: DSHRemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String: [[BotScriptedEvent]]]
    private let mainId: String
    private var nextCreateIndex = 0
    private var gates: [String: BotScriptedGate] = [:]
    private var failingPages: [String: Int] = [:]

    private(set) var prompts: [String: (sessionId: String, mode: String, text: String)] = [:]
    private(set) var promptHistory: [(sessionId: String, mode: String, text: String)] = []
    private(set) var promptRequestIds: [(sessionId: String, requestId: String, mode: String)] = []
    private(set) var cancellations: [String] = []
    private(set) var createdIDs: [String] = []
    private(set) var requestedSessionIds: [String] = []
    private(set) var claimedSessions: [String] = []
    private(set) var openMuxCount = 0

    init(mainId: String = "gb-main", scripts: [String: [[BotScriptedEvent]]]) {
        self.mainId = mainId
        self.scripts = scripts
    }

    var createCount: Int { lock.withLock { createdIDs.count } }

    func queue(sessionId: String, events: [BotScriptedEvent]) {
        lock.withLock {
            scripts[sessionId, default: []].append(events)
        }
    }

    func pause(_ sessionId: String) {
        lock.withLock {
            if gates[sessionId] == nil { gates[sessionId] = BotScriptedGate() }
        }
    }

    func resume(_ sessionId: String) {
        let gate = lock.withLock { gates[sessionId] }
        if let gate { Task { await gate.open() } }
    }

    func failPage(_ sessionId: String, times: Int? = nil) {
        lock.withLock { failingPages[sessionId] = times ?? -1 }
    }

    func call(_ endpoint: String, args: BotJSONValue) async throws -> BotJSONValue {
        switch endpoint {
        case "session/create":
            let requested = args["request"]?["sessionId"]?.stringValue ?? ""
            let id = lock.withLock { () -> String in
                defer { nextCreateIndex += 1 }
                requestedSessionIds.append(requested)
                let id = nextCreateIndex == 0 ? mainId : "gb-created-\(nextCreateIndex)"
                createdIDs.append(id)
                return id
            }
            return .object(["sessionId": .string(id)])
        case "phone/botClaimSession":
            let sessionId = args["request"]?["sessionId"]?.stringValue ?? ""
            lock.withLock { claimedSessions.append(sessionId) }
            return .object(["ok": .bool(true), "sessionId": .string(sessionId)])
        case "session/page":
            let sessionId = args["request"]?["address"]?["sessionId"]?.stringValue ?? ""
            let failed = lock.withLock { () -> Bool in
                guard let remaining = failingPages[sessionId], remaining != 0 else { return false }
                if remaining > 0 { failingPages[sessionId] = remaining - 1 }
                return true
            }
            if failed {
                throw DSHRemoteError(code: "session/not-found", message: "session \"\(sessionId)\" not found")
            }
            return .object(["sessionId": .string(sessionId)])
        case "session/prompt":
            let request = args["request"] ?? .null
            let sessionId = request["sessionId"]?.stringValue ?? ""
            let mode = request["mode"]?.stringValue ?? ""
            let text = (request["content"]?.arrayValue ?? []).compactMap {
                $0["text"]?.stringValue
            }.joined()
            let requestId = request["requestId"]?.stringValue ?? ""
            lock.withLock {
                prompts[sessionId] = (sessionId, mode, text)
                promptHistory.append((sessionId, mode, text))
                promptRequestIds.append((sessionId, requestId, mode))
            }
            return .object([:])
        case "session/cancel":
            let sessionId = args["request"]?["sessionId"]?.stringValue ?? ""
            lock.withLock { cancellations.append(sessionId) }
            return .object([:])
        default: return .object([:])
        }
    }

    func openMux() async throws -> any DSHMuxConnection {
        lock.withLock { openMuxCount += 1 }
        return BotScriptedMux(
            eventsForSession: { [weak self] sessionId in
                guard let self else { return [] }
                return self.lock.withLock {
                    guard let events = self.scripts[sessionId], !events.isEmpty else { return [] }
                    return self.scripts[sessionId]!.removeFirst()
                }
            },
            gateForSession: { [weak self] sessionId in
                self?.lock.withLock { self?.gates[sessionId] } ?? nil
            })
    }

    func authenticationFailed() async {}
}

private actor BotScriptedMux: DSHMuxConnection {
    private let eventsForSession: (String) -> [BotScriptedEvent]
    private let gateForSession: (String) -> BotScriptedGate?
    private var events: [BotScriptedEvent] = []
    private var snapshotReturned = false
    private var index = 0
    private var gate: BotScriptedGate?
    private var gateWaited = false

    init(eventsForSession: @escaping (String) -> [BotScriptedEvent],
         gateForSession: @escaping (String) -> BotScriptedGate?) {
        self.eventsForSession = eventsForSession
        self.gateForSession = gateForSession
    }

    func send(_ frame: BotJSONValue) async throws {
        guard frame["endpoint"]?.stringValue == "session/follow" else { return }
        let address = frame["payload"]?["args"]?["request"]?["address"]
        let sessionId = address?["sessionId"]?.stringValue ?? ""
        events = eventsForSession(sessionId)
        gate = gateForSession(sessionId)
    }

    func receive() async throws -> BotJSONValue? {
        if !snapshotReturned {
            snapshotReturned = true
            return .object([
                "type": .string("item"), "streamId": .string("follow"),
                "value": .object(["type": .string("snapshot"), "cursor": .number(0), "records": .array([])]),
            ])
        }
        if index == 1, !gateWaited, let gate {
            gateWaited = true
            await gate.wait()
        }
        guard index < events.count else { return nil }
        let event = events[index]
        index += 1
        if event.stream {
            return .object([
                "type": .string("item"), "streamId": .string("follow"),
                "value": .object([
                    "type": .string("assistant-stream"), "time": .number(Double(event.time)),
                    "frame": event.data,
                ]),
            ])
        }
        return .object([
            "type": .string("item"), "streamId": .string("follow"),
            "value": .object([
                "type": .string("event"),
                "event": .object([
                    "type": .string(event.type), "seq": .number(Double(index)),
                    "time": .number(Double(event.time)), "data": event.data,
                ]),
            ]),
        ])
    }

    func close() async {}
}
