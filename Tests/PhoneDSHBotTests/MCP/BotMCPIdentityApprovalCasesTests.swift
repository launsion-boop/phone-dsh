// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// D13 identity/approval contract, driven from
/// `spec/bot/v1/golden/identity-approval-cases.phone.json` through the real
/// `BotMCPHandler` and `BotApprovalCoordinator`.
final class BotMCPIdentityApprovalCasesTests: XCTestCase {
    private var vector: [String: Any] = [:]

    override func setUpWithError() throws {
        vector = try BotContractFixture.object("identity-approval-cases.phone")
    }

    func testMCPIdentityApprovalFixtureMetadata() throws {
        XCTAssertEqual(vector["vector"] as? String, "identity-approval-cases.phone")
        XCTAssertEqual(vector["upstream"] as? [String], [])
        let valid = try BotContractFixture.array(vector["valid"], "valid")
        let invalid = try BotContractFixture.array(vector["invalid"], "invalid")
        XCTAssertFalse(valid.isEmpty)
        XCTAssertFalse(invalid.isEmpty)
        let defaults = try BotContractFixture.object(vector["defaults"], "defaults")
        XCTAssertEqual(try BotContractFixture.int(defaults["approvalTimeoutMs"], "approvalTimeoutMs"),
                       Int(BotApprovalCoordinator.defaultTimeoutMilliseconds))
        XCTAssertEqual(try BotContractFixture.int(defaults["approvalExpiryMs"], "approvalExpiryMs"),
                       Int(BotApprovalCoordinator.defaultDurableExpiryMilliseconds))
    }

    func testMCPCredentialContract() async throws {
        let contract = try BotContractFixture.object(vector["credentialContract"], "credentialContract")
        let prefix = try BotContractFixture.string(contract["tokenPrefix"], "tokenPrefix")
        let length = try BotContractFixture.int(contract["tokenLength"], "tokenLength")
        let alphabet = Set(try BotContractFixture.string(contract["tokenURLSafeAlphabet"], "alphabet"))
        let incarnationLength = try BotContractFixture.int(contract["incarnationHexLength"], "incarnation")
        XCTAssertEqual(Int(BotTokenRegistry.defaultTTLMilliseconds),
                       try BotContractFixture.int(contract["defaultTTLMilliseconds"], "ttl"))
        XCTAssertEqual(BotTokenRegistry.defaultMaximumTokens,
                       try BotContractFixture.int(contract["maximumTokens"], "maximumTokens"))
        XCTAssertEqual(Int(BotAttributionRegistry.defaultTTLMilliseconds),
                       try BotContractFixture.int(contract["attributionTTLMilliseconds"], "attrTTL"))
        XCTAssertEqual(BotAttributionRegistry.defaultMaximumEntries,
                       try BotContractFixture.int(contract["attributionMaximumEntries"], "attrMax"))

        let registry = BotTokenRegistry(now: { 1_000 })
        let issued = try await registry.issue(botId: "main", sessionId: "gb-main", kind: .chat)
        XCTAssertEqual(issued.token.count, length)
        XCTAssertTrue(issued.token.hasPrefix(prefix))
        XCTAssertTrue(issued.token.dropFirst(prefix.count).allSatisfy { alphabet.contains($0) })
        XCTAssertEqual(issued.principal.incarnation.count, incarnationLength)
        XCTAssertTrue(issued.principal.incarnation.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(issued.principal.expiresAt,
                       1_000 + Int64(try BotContractFixture.int(contract["defaultTTLMilliseconds"], "ttl")))
        let lookedUp = await registry.lookup(issued.token)
        XCTAssertEqual(lookedUp, issued.principal)

        let rotatedValue = try await registry.rotate(issued.token)
        let rotated = try XCTUnwrap(rotatedValue)
        let oldLookup = await registry.lookup(issued.token)
        let newLookup = await registry.lookup(rotated.token)
        XCTAssertNil(oldLookup, "the old token must be revoked")
        XCTAssertEqual(newLookup, rotated.principal)
        XCTAssertEqual(rotated.principal.sessionId, issued.principal.sessionId)
        XCTAssertEqual(rotated.principal.botId, issued.principal.botId)
        XCTAssertNotEqual(rotated.principal.incarnation, issued.principal.incarnation)
        XCTAssertEqual(rotated.principal.expiresAt, issued.principal.expiresAt)
        let revoked = await registry.revokeSession("gb-main")
        let sessionLookup = await registry.lookupSession("gb-main")
        let active = await registry.activeSessionIDs()
        XCTAssertEqual(revoked, 1)
        XCTAssertNil(sessionLookup)
        XCTAssertTrue(active.isEmpty)

        let small = BotTokenRegistry(now: { 1_000 }, maximumTokens: 1)
        _ = try await small.issue(botId: "main", sessionId: "gb-a", kind: .chat)
        do {
            _ = try await small.issue(botId: "main", sessionId: "gb-b", kind: .chat)
            XCTFail("the registry must enforce its capacity")
        } catch BotTokenRegistryError.registryFull {}
    }

    func testMCPIdentityApprovalValidCases() async throws {
        let cases = try BotContractFixture.array(vector["valid"], "valid")
        for (index, object) in cases.enumerated() {
            let name = (object["name"] as? String) ?? "?"
            try await runCase(object, label: "valid[\(index)] \(name)")
        }
    }

    func testMCPIdentityApprovalInvalidCases() async throws {
        let cases = try BotContractFixture.array(vector["invalid"], "invalid")
        for (index, object) in cases.enumerated() {
            let name = (object["name"] as? String) ?? "?"
            try await runCase(object, label: "invalid[\(index)] \(name)")
        }
    }

    // MARK: - cases

    private func runCase(_ object: [String: Any], label: String) async throws {
        let setup = try BotContractFixture.object(object["setup"], "\(label).setup")
        let kind = try BotContractFixture.string(object["kind"], "\(label).kind")
        let timeout = (object["approvalTimeoutMs"] as? NSNumber)?.int64Value
            ?? BotApprovalCoordinator.defaultTimeoutMilliseconds
        let expiry = (object["approvalExpiryMs"] as? NSNumber)?.int64Value
            ?? BotApprovalCoordinator.defaultDurableExpiryMilliseconds
        let fixture = try makeBotMCPFixture(approvalTimeoutMs: timeout, approvalExpiryMs: expiry)
        defer { fixture.cleanup() }
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let session = try BotContractFixture.string(setup["sessionId"], "\(label).setup.sessionId")
        let botId = try BotContractFixture.string(setup["botId"], "\(label).setup.botId")
        let kindRaw = try BotContractFixture.string(setup["kind"], "\(label).setup.kind")
        let capabilities = (setup["capabilities"] as? [String]) ?? []
        let issued = try await fixture.runtime.issueSessionToken(
            botId: botId, sessionId: session,
            kind: BotSessionKind(rawValue: kindRaw) ?? .chat, capabilities: capabilities)

        switch kind {
        case "register":
            try await runRegister(object, handler: handler, fixture: fixture,
                                  session: session, token: issued.token, label: label)
        case "cancel":
            try await runCancel(object, handler: handler, fixture: fixture,
                                session: session, token: issued.token, label: label)
        case "approval":
            try await runApproval(object, handler: handler, fixture: fixture,
                                  session: session, token: issued.token, label: label)
        default:
            XCTFail("\(label): unsupported kind \(kind)")
        }
    }

    private func runRegister(_ object: [String: Any], handler: BotMCPHandler,
                             fixture: BotMCPTestFixture, session: String, token: String,
                             label: String) async throws {
        let registration = try BotContractFixture.object(object["registration"], "\(label).registration")
        let args = try BotContractFixture.json(registration["arguments"] ?? [:])
        let bodyOverrides = (object["body"] as? [String: Any]) ?? [:]
        let tokenMode = (object["token"] as? String) ?? "current"
        var suppliedToken: String?
        switch tokenMode {
        case "current": suppliedToken = token
        case "none": suppliedToken = nil
        case "wrong": suppliedToken = "dshg_" + String(repeating: "A", count: 43)
        case "revoked":
            _ = await fixture.runtime.gateway.tokens.revoke(token)
            suppliedToken = token
        case "foreign":
            let foreignSession = (bodyOverrides["tokenSession"] as? String) ?? "gb-foreign"
            let foreign = try await fixture.runtime.issueSessionToken(
                botId: "main", sessionId: foreignSession, kind: .chat)
            suppliedToken = foreign.token
        default:
            XCTFail("\(label): unknown token mode \(tokenMode)")
        }
        var body: [String: Any] = [
            "runtimeId": BotMCPRuntime.defaultRuntimeID,
            "sessionId": session,
            "callId": registration["callId"] as? String ?? "call",
            "name": registration["tool"] as? String ?? "",
            "arguments": registration["arguments"] ?? [:],
        ]
        if bodyOverrides["omitName"] as? Bool == true { body.removeValue(forKey: "name") }
        let digestMode = (object["argsDigest"] as? String) ?? "computed"
        if digestMode == "computed" {
            body["argsDigest"] = try BotContractFixture.digest(args)
        } else if digestMode == "mismatch" {
            body["argsDigest"] = String(repeating: "0", count: 64)
        }
        if let suppliedToken { body["sessionToken"] = suppliedToken }
        let reply = await handler.registerIdentity(try BotContractFixture.json(body))
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        BotContractFixture.assertSubset(reply, try BotContractFixture.json(expect), label)
        guard expect["ok"] as? Bool == true else { return }
        let id = try XCTUnwrap(reply["id"]?.stringValue, "\(label): success needs an id")
        XCTAssertEqual(id.count, 32, "\(label): registration id is 16 random bytes hex")
        let live = await fixture.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session,
            callId: registration["callId"] as? String ?? "")
        XCTAssertNotNil(live, "\(label): registration must be claimable")
        if let expectedName = (object["flags"] as? [String: Any])?["registeredBareName"] as? String {
            XCTAssertEqual(live?.attribution.name, expectedName, label)
        }
    }

    private func runCancel(_ object: [String: Any], handler: BotMCPHandler,
                           fixture: BotMCPTestFixture, session: String, token: String,
                           label: String) async throws {
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        if let _ = object["body"] as? [String: Any] {
            let reply = await handler.cancelIdentity(try BotContractFixture.json(object["body"]!))
            XCTAssertEqual(reply["ok"], .bool(expect["ok"] as? Bool ?? false), label)
            return
        }
        let registration = try BotContractFixture.object(object["registration"], "\(label).registration")
        let args = try BotContractFixture.json(registration["arguments"] ?? [:])
        let registered = await handler.registerIdentity(try BotContractFixture.json([
            "runtimeId": BotMCPRuntime.defaultRuntimeID, "sessionId": session,
            "callId": registration["callId"] as? String ?? "call",
            "name": registration["tool"] as? String ?? "",
            "arguments": registration["arguments"] ?? [:],
            "argsDigest": try BotContractFixture.digest(args),
            "sessionToken": token,
        ]))
        let id = try XCTUnwrap(registered["id"]?.stringValue, "\(label): registration failed")
        let first = await handler.cancelIdentity(.object(["id": .string(id)]))
        XCTAssertEqual(first["ok"], .bool(expect["first"] as? Bool ?? expect["ok"] as? Bool ?? false), label)
        if object["twice"] as? Bool == true {
            let second = await handler.cancelIdentity(.object(["id": .string(id)]))
            XCTAssertEqual(second["ok"], .bool(expect["second"] as? Bool ?? false), label)
        }
        let live = await fixture.runtime.identityForApproval(
            runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: session,
            callId: registration["callId"] as? String ?? "")
        XCTAssertNil(live, "\(label): cancelled registration must not be claimable")
    }

    private func runApproval(_ object: [String: Any], handler: BotMCPHandler,
                             fixture: BotMCPTestFixture, session: String, token: String,
                             label: String) async throws {
        let registration = try BotContractFixture.object(object["registration"], "\(label).registration")
        let args = try BotContractFixture.json(registration["arguments"] ?? [:])
        let computedDigest = try BotContractFixture.digest(args)
        if let declared = object["argsDigest"] as? String, declared != String(repeating: "0", count: 64) {
            XCTAssertEqual(declared, computedDigest, "\(label): fixture digest must match the canonical JSON")
        }
        let registered = await handler.registerIdentity(try BotContractFixture.json([
            "runtimeId": BotMCPRuntime.defaultRuntimeID, "sessionId": session,
            "callId": registration["callId"] as? String ?? "call",
            "name": registration["tool"] as? String ?? "",
            "arguments": registration["arguments"] ?? [:],
            "argsDigest": computedDigest,
            "sessionToken": token,
        ]))
        let registrationID = try XCTUnwrap(registered["id"]?.stringValue, "\(label): registration failed")

        let approval = try BotContractFixture.object(object["approval"], "\(label).approval")
        var body: [String: Any] = [
            "sessionId": session,
            "callId": registration["callId"] as? String ?? "call",
            "tool": registration["tool"] as? String ?? "",
            "argsDigest": object["argsDigest"] as? String ?? computedDigest,
            "alwaysScope": approval["alwaysScope"] as? String ?? "until",
        ]
        if approval["omitAlwaysScope"] as? Bool == true { body.removeValue(forKey: "alwaysScope") }
        for key in ["action", "detail", "command", "effects", "askAction"] {
            if let value = approval[key] { body[key] = value }
        }
        if let callId = approval["callId"] { body["callId"] = callId }

        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        let post = (object["post"] as? [String: Any]) ?? [:]
        let immediate = object["immediate"] as? Bool == true
        var reply: BotJSONValue
        if immediate {
            reply = await handler.approval(try BotContractFixture.json(body))
        } else {
            let task = Task { await handler.approval(try BotContractFixture.json(body)) }
            var approvalID: String?
            for _ in 0..<400 {
                if let first = await fixture.runtime.approvals.pendingIDs.first {
                    approvalID = first
                    break
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let approvalID else {
                task.cancel()
                XCTFail("\(label): approval never became pending")
                return
            }
            if post["cancelRegistration"] as? Bool == true {
                _ = await handler.cancelIdentity(.object(["id": .string(registrationID)]))
            } else if let decision = object["decision"] as? String {
                let resolved = await fixture.runtime.approvals.resolve(
                    approvalId: approvalID,
                    decision: BotApprovalDecision(rawValue: decision) ?? .deny,
                    digest: computedDigest)
                XCTAssertEqual(resolved, .resolved, "\(label): resolve failed")
            } else {
                task.cancel()
                XCTFail("\(label): no decision or cancel action for a pending approval")
                return
            }
            reply = try await task.value
        }
        BotContractFixture.assertSubset(reply, try BotContractFixture.json(expect), label)

        if expect["pending"] as? Bool == true {
            if (object["flags"] as? [String: Any])?["expiresAtPositive"] as? Bool == true {
                XCTAssertGreaterThan(reply["expiresAt"]?.numberValue ?? 0, 0, label)
            }
            guard let approvalID = await fixture.runtime.approvals.pendingIDs.first else {
                XCTFail("\(label): durable approval should still be pending")
                return
            }
            if let expireAfter = object["expireAfterMs"] as? NSNumber {
                try await Task.sleep(nanoseconds: UInt64(expireAfter.intValue) * 1_000_000)
            }
            if let expectedStatus = post["durableStatus"] as? String {
                let status = await fixture.runtime.approvals.durableStatus(approvalId: approvalID)
                XCTAssertEqual(status.rawValue, expectedStatus, label)
            }
            if let resolve = post["resolve"] as? String {
                let resolved = await fixture.runtime.approvals.resolve(
                    approvalId: approvalID,
                    decision: BotApprovalDecision(rawValue: resolve) ?? .allowOnce,
                    digest: computedDigest)
                if expect["pending"] as? Bool == true, post["durableStatus"] == nil {
                    XCTAssertEqual(resolved, .resolved, label)
                } else if let reason = post["durableStatus"] as? String {
                    XCTAssertEqual(resolved, .stale(reason: reason), label)
                }
            }
        }
    }
}

private extension BotJSONValue {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
