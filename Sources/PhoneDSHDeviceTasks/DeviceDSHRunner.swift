// SPDX-License-Identifier: MIT
import CryptoKit
import Foundation
import PhoneDSHAgentCore

/// Uses one isolated DSH session per device. A task is never sent until the
/// packaged preset document and live session projection have been verified.
public actor DeviceDSHRunner: DeviceTaskRunner {
    private static let preset = "pdsh-device-task"
    private static let presetDigest = "fee91c0e29e6cde569076ee899b32935fda12bdb3824501cca58b5b233a12887"
    private let transport: any DSHRemoteTransport
    private let harness: DSHRemoteHarness

    public init(transport: any DSHRemoteTransport) {
        self.transport = transport
        self.harness = DSHRemoteHarness(transport: transport)
    }

    public func session(for deviceID: String, existingSession: String?) async throws -> String {
        try await verifyGuard()
        try await verifyDocument()
        if let existingSession {
            _ = try await verifiedCursor(sessionID: existingSession)
            return existingSession
        }
        let result = try await transport.call("session/create", args: .object([
            "request": .object(["cwd": .string("/dsh/workspace"), "agentPreset": .string(Self.preset)])
        ]))
        guard let id = result["sessionId"]?.stringValue, !id.isEmpty,
              result["agentPreset"]?.stringValue == Self.preset else { throw DeviceTaskError.unauthorized }
        _ = try await verifiedCursor(sessionID: id)
        return id
    }

    public func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome {
        guard task == record.task,
              let goal = record.uplinkEnvelope["text"]?.stringValue else {
            return .failed(kind: .denied, message: "Device task identity did not match its journal.")
        }
        let cursor: UInt64?
        do {
            try await verifyGuard()
            try await verifyDocument()
            cursor = try await verifiedCursor(sessionID: record.sessionID)
        } catch {
            return .failed(kind: .unavailable, message: "Device task isolation could not be verified.")
        }
        let events = harness.events(sessionID: record.sessionID, after: cursor)
        do {
            try await harness.send(.prompt(text: goal, attachments: [], requestID: record.requestID), to: record.sessionID)
        } catch {
            return .failed(kind: .unknownOutcome, message: "Prompt submission was not confirmed.")
        }
        var observedInput = false
        var currentTurn: String?
        var targetTurn: String?
        var lastAnswer = ""
        do {
            for try await event in events {
                try Task.checkCancellation()
                switch event.kind {
                case .userMessage:
                    let request = event.userMessageData?["source"]?["rpcId"]?.stringValue
                    if request == record.requestID {
                        observedInput = true
                        targetTurn = currentTurn
                    } else if observedInput && event.userMessageData?["source"]?["kind"]?.stringValue == "user" {
                        return .failed(kind: .unknownOutcome, message: "Another input entered the device session.")
                    }
                case .turnStarted(let turn):
                    currentTurn = turn
                    if observedInput && targetTurn == nil { targetTurn = turn }
                case .assistantMessage(let text):
                    if observedInput && targetTurn != nil { lastAnswer = text }
                case .turnEnded(let turn, let reason):
                    defer { currentTurn = nil }
                    guard observedInput, targetTurn == turn else { continue }
                    switch reason {
                    case .completed: return .boundedOutput(lastAnswer)
                    case .cancelled: return .failed(kind: .failed, message: "The device task was cancelled.")
                    case .failed, .budgetExhausted: return .failed(kind: .failed, message: "The device task did not complete.")
                    }
                case .toolCall, .permissionRequested, .questionRequested:
                    if observedInput {
                        try? await harness.send(.cancel, to: record.sessionID)
                        return .failed(kind: .denied, message: "Device task requested a disallowed capability.")
                    }
                default: break
                }
            }
        } catch {
            return .failed(kind: .unknownOutcome, message: "The task event stream ended before a confirmed result.")
        }
        return .failed(kind: .unknownOutcome, message: "The task event stream ended before a confirmed result.")
    }

    public func cancel(sessionID: String) async {
        try? await harness.send(.cancel, to: sessionID)
    }

    private func verifyDocument() async throws {
        let value = try await transport.call("agentPresets/read", args: .object(["agentPreset": .string(Self.preset)]))
        guard let content = value["content"]?.stringValue else { throw DeviceTaskError.unauthorized }
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.presetDigest else { throw DeviceTaskError.unauthorized }
    }

    private func verifyGuard() async throws {
        let result = try await transport.call("phone/pluginList", args: .object([:]))
        guard result["ok"]?.boolValue == true,
              let entries = result["value"]?["entries"]?.arrayValue else { throw DeviceTaskError.unauthorized }
        let guards = entries.filter { $0["entryId"]?.stringValue == "include:device-task-guard" }
        guard guards.count == 1,
              guards[0]["moduleName"]?.stringValue == "@phone-dsh/dsh-lifecycle-gate/device-guard",
              guards[0]["enabled"]?.boolValue == true,
              guards[0]["fiberPhase"]?.stringValue == "active" else { throw DeviceTaskError.unauthorized }
    }

    private func verifiedCursor(sessionID: String) async throws -> UInt64? {
        let value = try await transport.call("session/projections", args: .object([
            "request": .object(["sessionId": .string(sessionID)])
        ]))
        guard value["kind"]?.stringValue == "sequenced",
              value["values"]?["agentPreset"]?.stringValue == Self.preset,
              let raw = value["asOfSeq"]?.numberValue, raw.isFinite,
              raw.rounded(.towardZero) == raw, raw >= -1,
              raw <= 9_007_199_254_740_991, let seq = Int(exactly: raw) else { throw DeviceTaskError.unauthorized }
        if seq < 0 { return nil }
        return UInt64(seq) * 8 + 7
    }
}
