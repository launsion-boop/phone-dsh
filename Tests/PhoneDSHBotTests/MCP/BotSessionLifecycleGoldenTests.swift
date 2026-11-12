// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import XCTest
@testable import PhoneDSHBot

/// Runs `spec/bot/v1/golden/session-lifecycle.phone.json` through the real
/// `BotWorkspaceLayout`, `BotDSHRemoteRuntime` and `BotTokenRegistry`.
final class BotSessionLifecycleGoldenTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try BotGoldenFixture.rawObject("session-lifecycle.phone")
    }

    // MARK: - Workspace layout

    func testWorkspaceLayoutVectors() throws {
        let fixture = try fixture()
        let valid = try XCTUnwrap((fixture["valid"] as? [String: Any])?["workspace"] as? [[String: Any]])
        XCTAssertFalse(valid.isEmpty)
        for vector in valid {
            let botId = try XCTUnwrap(vector["botId"] as? String)
            let safe = try XCTUnwrap(vector["safe"] as? String)
            let root = try XCTUnwrap(vector["root"] as? String)
            XCTAssertEqual(BotWorkspaceLayout.safePathComponent(botId), safe,
                           "safePathComponent(\(botId.debugDescription))")
            let dataDirectory = vector["dataDirectory"] as? String
                ?? BotWorkspaceLayout.defaultBotDataDirectory
            XCTAssertEqual(BotWorkspaceLayout.botRoot(botId: botId, dataDirectory: dataDirectory), root,
                           "botRoot(\(botId.debugDescription), \(dataDirectory))")
        }
        let invalid = try XCTUnwrap((fixture["invalid"] as? [String: Any])?["workspace"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for vector in invalid {
            let botId = try XCTUnwrap(vector["botId"] as? String)
            let safe = try XCTUnwrap(vector["safe"] as? String)
            XCTAssertEqual(BotWorkspaceLayout.safePathComponent(botId), safe,
                           "fallback case \(vector["name"] ?? "")")
        }
    }

    // MARK: - Token registry

    func testTokenRegistryVectors() async throws {
        let fixture = try fixture()
        let registryVectors = try XCTUnwrap((fixture["valid"] as? [String: Any])?["tokenRegistry"] as? [String: Any])
        let defaults = try XCTUnwrap(registryVectors["defaults"] as? [String: Any])
        XCTAssertEqual(BotTokenRegistry.defaultTTLMilliseconds,
                       (defaults["defaultTTLMilliseconds"] as? NSNumber)?.int64Value)
        XCTAssertEqual(BotTokenRegistry.defaultMaximumTokens,
                       (defaults["defaultMaximumTokens"] as? NSNumber)?.intValue)
        XCTAssertEqual(BotGateway.chatTTLMilliseconds,
                       (defaults["chatTTLMilliseconds"] as? NSNumber)?.int64Value)
        XCTAssertEqual(BotGateway.ephemeralTTLMilliseconds,
                       (defaults["ephemeralTTLMilliseconds"] as? NSNumber)?.int64Value)

        let cases = try XCTUnwrap(registryVectors["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            try await runTokenCase(vector)
        }
        let invalid = try XCTUnwrap((fixture["invalid"] as? [String: Any])?["tokenRegistry"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for vector in invalid {
            try await runInvalidTokenCase(vector)
        }
    }

    private func expectField(_ step: [String: Any], _ key: String) -> Any? {
        (step["expect"] as? [String: Any])?[key]
    }

    private func tokenErrorName(_ error: BotTokenRegistryError) -> String {
        switch error {
        case .invalidInput(let name): return "invalidInput:\(name)"
        case .registryFull: return "registryFull"
        }
    }

    private func runTokenCase(_ vector: [String: Any]) async throws {
        let clock = ClockBox((vector["clock"] as? NSNumber)?.int64Value ?? 0)
        let maximum = (vector["maximumTokens"] as? NSNumber)?.intValue
            ?? BotTokenRegistry.defaultMaximumTokens
        let registry = BotTokenRegistry(now: { clock.value }, maximumTokens: maximum)
        var tokens: [BotIssuedToken] = []
        let steps = try XCTUnwrap(vector["steps"] as? [[String: Any]])
        for (index, step) in steps.enumerated() {
            let label = "\(vector["name"] ?? "token")[\(index)]"
            switch try XCTUnwrap(step["op"] as? String) {
            case "setClock":
                clock.value = (step["clock"] as? NSNumber)?.int64Value ?? clock.value
            case "issue", "issueSession":
                do {
                    let kind = try XCTUnwrap(BotSessionKind(rawValue: step["kind"] as? String ?? ""))
                    let token: BotIssuedToken
                    if (step["op"] as? String) == "issueSession" {
                        token = try await registry.issueSession(
                            botId: try XCTUnwrap(step["botId"] as? String),
                            sessionId: try XCTUnwrap(step["sessionId"] as? String),
                            kind: kind,
                            capabilities: step["capabilities"] as? [String] ?? [],
                            expiresAt: (step["expiresAt"] as? NSNumber)?.int64Value,
                            ttlMilliseconds: (step["ttlMilliseconds"] as? NSNumber)?.int64Value)
                    } else {
                        token = try await registry.issue(
                            botId: try XCTUnwrap(step["botId"] as? String),
                            sessionId: try XCTUnwrap(step["sessionId"] as? String),
                            kind: kind,
                            capabilities: step["capabilities"] as? [String] ?? [],
                            expiresAt: (step["expiresAt"] as? NSNumber)?.int64Value,
                            ttlMilliseconds: (step["ttlMilliseconds"] as? NSNumber)?.int64Value)
                    }
                    XCTAssertEqual(tokens.count, (expectField(step, "tokenIndex") as? NSNumber)?.intValue,
                                   "\(label): token index")
                    tokens.append(token)
                    try assertToken(token, expect: step["expect"], label: label)
                } catch let error as BotTokenRegistryError {
                    if let expected = step["expectError"] as? String {
                        XCTAssertEqual(tokenErrorName(error), expected, label)
                    } else {
                        XCTFail("\(label): unexpected \(error)")
                    }
                }
            case "lookup":
                let token = try token(tokens, step)
                let resolved = await registry.lookup(token.token)
                XCTAssertEqual(resolved != nil, resolveFlag(step), label)
            case "lookupRaw":
                let resolved = await registry.lookup(step["token"] as? String ?? "")
                XCTAssertEqual(resolved != nil, resolveFlag(step), label)
            case "lookupSession":
                let principal = await registry.lookupSession(step["sessionId"] as? String ?? "")
                XCTAssertEqual(principal != nil, resolveFlag(step), label)
                if let expected = (expectField(step, "tokenIndex") as? NSNumber)?.intValue,
                   let principal {
                    XCTAssertEqual(principal.sessionId, tokens[expected].principal.sessionId, label)
                    XCTAssertEqual(principal.incarnation, tokens[expected].principal.incarnation, label)
                }
            case "lookupBearer":
                let token = try token(tokens, step)
                let header = "\(step["scheme"] as? String ?? "Bearer") \(token.token)"
                let resolved = await registry.lookupBearer(header)
                XCTAssertEqual(resolved != nil, resolveFlag(step), label)
            case "lookupBearerRaw":
                let resolved = await registry.lookupBearer(step["header"] as? String ?? "")
                XCTAssertEqual(resolved != nil, resolveFlag(step), label)
            case "rotate", "rotateRaw":
                let old: String
                if (step["op"] as? String) == "rotate" {
                    old = try token(tokens, step).token
                } else {
                    old = step["token"] as? String ?? ""
                }
                do {
                    let replacement = try await registry.rotate(
                        old,
                        capabilities: step["capabilities"] as? [String],
                        expiresAt: (step["expiresAt"] as? NSNumber)?.int64Value,
                        ttlMilliseconds: (step["ttlMilliseconds"] as? NSNumber)?.int64Value)
                    let expect = (step["expect"] as? [String: Any]) ?? [:]
                    let expectedResolves = (expect["resolves"] as? NSNumber)?.boolValue ?? true
                    XCTAssertEqual(replacement != nil, expectedResolves, label)
                    if let index = (expect["tokenIndex"] as? NSNumber)?.intValue {
                        let unwrapped = try XCTUnwrap(replacement)
                        XCTAssertEqual(tokens.count, index, label)
                        tokens.append(unwrapped)
                        try assertToken(unwrapped, expect: expect, label: label)
                        if (expect["sameSession"] as? NSNumber)?.boolValue == true {
                            XCTAssertEqual(unwrapped.principal.sessionId, tokens[0].principal.sessionId, label)
                        }
                    }
                } catch let error as BotTokenRegistryError {
                    if let expected = step["expectError"] as? String {
                        XCTAssertEqual(tokenErrorName(error), expected, label)
                    } else {
                        XCTFail("\(label): unexpected \(error)")
                    }
                }
            case "revoke":
                let token = try token(tokens, step)
                let removed = await registry.revoke(token.token)
                XCTAssertEqual(removed, (expectField(step, "removed") as? NSNumber)?.boolValue ?? false, label)
            case "revokeRaw":
                let removed = await registry.revoke(step["token"] as? String ?? "")
                XCTAssertEqual(removed, (expectField(step, "removed") as? NSNumber)?.boolValue ?? false, label)
            case "revokeSession":
                let removed = await registry.revokeSession(step["sessionId"] as? String ?? "")
                XCTAssertEqual(removed, (expectField(step, "removed") as? NSNumber)?.intValue ?? -1, label)
            case "revokeBot":
                let removed = await registry.revokeBot(step["botId"] as? String ?? "")
                XCTAssertEqual(removed, (expectField(step, "removed") as? NSNumber)?.intValue ?? -1, label)
            case "count":
                let count = await registry.count
                XCTAssertEqual(count, (step["expect"] as? NSNumber)?.intValue, label)
            default:
                XCTFail("\(label): unknown token op")
            }
        }
    }

    private func runInvalidTokenCase(_ vector: [String: Any]) async throws {
        let clock = ClockBox((vector["clock"] as? NSNumber)?.int64Value ?? 0)
        let registry = BotTokenRegistry(now: { clock.value })
        let label = vector["name"] as? String ?? "token-invalid"
        let expect = (vector["expect"] as? [String: Any]) ?? [:]
        do {
            switch try XCTUnwrap(vector["op"] as? String) {
            case "issue":
                _ = try await registry.issue(
                    botId: vector["botId"] as? String ?? "",
                    sessionId: vector["sessionId"] as? String ?? "",
                    kind: try XCTUnwrap(BotSessionKind(rawValue: vector["kind"] as? String ?? "")))
            case "lookupRaw":
                let resolved = await registry.lookup(vector["token"] as? String ?? "")
                XCTAssertEqual(resolved != nil, (expect["resolves"] as? NSNumber)?.boolValue ?? false, label)
            case "revokeRaw":
                let removed = await registry.revoke(vector["token"] as? String ?? "")
                XCTAssertEqual(removed, (expect["removed"] as? NSNumber)?.boolValue ?? false, label)
            case "rotateRaw":
                let rotated = try await registry.rotate(vector["token"] as? String ?? "")
                XCTAssertEqual(rotated != nil, (expect["resolves"] as? NSNumber)?.boolValue ?? false, label)
            default:
                XCTFail("\(label): unknown invalid token op")
            }
        } catch let error as BotTokenRegistryError {
            XCTAssertEqual(tokenErrorName(error), vector["expectError"] as? String ?? "", label)
        }
    }

    private func resolveFlag(_ step: [String: Any]) -> Bool {
        (expectField(step, "resolves") as? NSNumber)?.boolValue ?? false
    }

    private func assertToken(_ token: BotIssuedToken, expect: Any?, label: String) throws {
        let expect = expect as? [String: Any] ?? [:]
        if let expiresAt = (expect["expiresAt"] as? NSNumber)?.int64Value {
            XCTAssertEqual(token.principal.expiresAt, expiresAt, "\(label): expiresAt")
        }
        if let pattern = expect["tokenPattern"] as? String {
            XCTAssertTrue(matchesRegex(token.token, pattern: stripRegexPrefix(pattern),
                                       label: "\(label): token"))
        }
        if let pattern = expect["incarnationPattern"] as? String {
            XCTAssertTrue(matchesRegex(token.principal.incarnation, pattern: stripRegexPrefix(pattern),
                                       label: "\(label): incarnation"))
        }
        if let principal = expect["principal"] as? [String: Any] {
            if let botId = principal["botId"] as? String {
                XCTAssertEqual(token.principal.botId, botId, label)
            }
            if let sessionId = principal["sessionId"] as? String {
                XCTAssertEqual(token.principal.sessionId, sessionId, label)
            }
            if let kind = principal["kind"] as? String {
                XCTAssertEqual(token.principal.kind.rawValue, kind, label)
            }
            if let capabilities = principal["capabilities"] as? [String] {
                XCTAssertEqual(token.principal.capabilities, capabilities, label)
            }
        }
    }

    private func token(_ tokens: [BotIssuedToken], _ step: [String: Any]) throws -> BotIssuedToken {
        let index = try XCTUnwrap((step["tokenIndex"] as? NSNumber)?.intValue)
        return tokens[index]
    }

    private func stripRegexPrefix(_ pattern: String) -> String {
        pattern.hasPrefix("re:") ? String(pattern.dropFirst(3)) : pattern
    }

    private func matchesRegex(_ value: String, pattern: String, label: String) -> Bool {
        let expression = try? NSRegularExpression(pattern: pattern)
        guard let expression else {
            XCTFail("\(label): invalid regex \(pattern)")
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else {
            XCTFail("\(label): \(value) does not match \(pattern)")
            return false
        }
        return match.range == range
    }

    // MARK: - Session transcripts

    func testSessionLifecycleVectors() async throws {
        let fixture = try fixture()
        let valid = try XCTUnwrap((fixture["valid"] as? [String: Any])?["sessions"] as? [[String: Any]])
        XCTAssertFalse(valid.isEmpty)
        for vector in valid {
            try await runSessionCase(vector, expectError: false)
        }
        let invalid = try XCTUnwrap((fixture["invalid"] as? [String: Any])?["sessions"] as? [[String: Any]])
        XCTAssertFalse(invalid.isEmpty)
        for vector in invalid {
            try await runSessionCase(vector, expectError: true)
        }
    }

    private func runSessionCase(_ vector: [String: Any], expectError: Bool) async throws {
        let label = vector["name"] as? String ?? "session"
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let transport = LifecycleTransport(vector["transport"] as? [String: Any] ?? [:])
        let seeds = vector["seedEvents"] as? [[String: Any]] ?? []
        if !seeds.isEmpty {
            // Startup writes the initial grant snapshot before any other
            // durable event; seed it first so recovery sees a valid log.
            try await fixture.runtime.grants.recover()
        }
        for (index, seed) in seeds.enumerated() {
            let type = try XCTUnwrap(seed["type"] as? String)
            let principalObject = try XCTUnwrap(seed["principal"] as? [String: Any])
            let principal = BotGatewayPrincipal(
                botId: principalObject["botId"] as? String ?? "main",
                sessionId: principalObject["sessionId"] as? String ?? "",
                kind: try XCTUnwrap(BotSessionKind(rawValue: principalObject["kind"] as? String ?? "chat")),
                capabilities: [], expiresAt: 1_000_000,
                incarnation: "seed\(String(format: "%028d", index))")
            _ = try await fixture.runtime.eventWriter.append(
                type: type, principal: principal,
                data: try encodeJSON(seed["data"]), eventId: "seed-\(index)", time: 1)
        }
        let remote = try await BotDSHRemoteRuntime(transport: transport, runtime: fixture.runtime,
                                                   now: { 2_000 })
        let initialHead = try await botEvents(fixture.store).count
        let recorder = LiveFrameRecorder()
        let subscription = await remote.subscribeLiveFrames { recorder.record($0) }
        defer {
            Task { await remote.unsubscribeLiveFrames(subscription) }
        }

        var results: [BotRemoteTurnResult] = []
        var resultObject: [String: Any]?
        var thrown: Error?
        do {
            switch try XCTUnwrap(vector["action"] as? String) {
            case "startMainSession":
                let sessionId = try await remote.startMainSession()
                resultObject = ["sessionId": sessionId]
            case "sendUserMessage":
                results = [try await remote.sendUserMessage(vector["text"] as? String ?? "")]
            case "sendHiddenInteraction":
                results = [try await remote.sendHiddenInteraction(
                    vector["text"] as? String ?? "",
                    requestId: try XCTUnwrap(vector["requestId"] as? String))]
            case "sendTwoMessages":
                for text in try XCTUnwrap(vector["texts"] as? [String]) {
                    results.append(try await remote.sendUserMessage(text))
                }
            case "switchMainSessionForErasure":
                let switched = try await remote.switchMainSessionForErasure(
                    erasureID: try XCTUnwrap(vector["erasureID"] as? String),
                    erasedRecords: vector["erasedRecords"] as? [String] ?? [])
                resultObject = ["old": switched.old, "new": switched.new]
            case "cancelDuringTurn":
                let task = Task { try await remote.sendUserMessage(vector["text"] as? String ?? "") }
                try await waitUntil { transport.promptCount >= 1 }
                try await remote.cancelMainTurn()
                results = [try await task.value]
            default:
                XCTFail("\(label): unknown action")
            }
        } catch {
            thrown = error
        }

        let expect = try XCTUnwrap(vector["expect"] as? [String: Any])
        if expectError {
            let error = try XCTUnwrap(thrown, "\(label): expected a failure")
            let description = String(describing: error)
            for fragment in expect["errorContains"] as? [String] ?? [] {
                XCTAssertTrue(description.localizedCaseInsensitiveContains(fragment),
                              "\(label): \(description) must contain \(fragment)")
            }
        } else {
            XCTAssertNil(thrown, "\(label): unexpected failure \(String(describing: thrown))")
        }
        guard !expectError else {
            return
        }

        let created = transport.createdSessionIds.last
        let expectedResult = expect["result"] as? [String: Any]
        if let expectedResult {
            if let pattern = expectedResult["pattern"] as? String {
                let actual = resultObject?["sessionId"] as? String ?? results.first?.sessionId ?? ""
                XCTAssertTrue(matchesRegex(actual, pattern: pattern, label: "\(label): result"))
            } else if expectedResult["status"] != nil {
                let actual = try XCTUnwrap(results.first, label)
                XCTAssertEqual(actual.status, expectedResult["status"] as? String, label)
                XCTAssertEqual(actual.text, expectedResult["text"] as? String, label)
                XCTAssertEqual(actual.turnId, expectedResult["turnId"] as? String, label)
            } else {
                XCTAssertEqual(resultObject?["old"] as? String, expectedResult["old"] as? String, label)
                let expectedNew = expectedResult["new"] as? String
                let actualNew = resultObject?["new"] as? String
                if expectedNew == "$created" {
                    XCTAssertEqual(actualNew, created, label)
                } else {
                    XCTAssertEqual(actualNew, expectedNew, label)
                }
            }
        }
        if let expectedResults = expect["results"] as? [[String: Any]] {
            XCTAssertEqual(results.count, expectedResults.count, label)
            for (index, expected) in expectedResults.enumerated() where index < results.count {
                XCTAssertEqual(results[index].status, expected["status"] as? String, label)
                XCTAssertEqual(results[index].text, expected["text"] as? String, label)
                XCTAssertEqual(results[index].turnId, expected["turnId"] as? String, label)
            }
        }

        if let expected = expect["createRequests"] as? [[String: Any]] {
            XCTAssertEqual(transport.createArguments.count, expected.count, "\(label): create count")
            for (index, value) in expected.enumerated() where index < transport.createArguments.count {
                XCTAssertTrue(match(value, transport.createArguments[index], created: created),
                              "\(label): create[\(index)] \(transport.createArguments[index])")
            }
        }
        if let expected = expect["claimRequests"] as? [[String: Any]] {
            let claims = transport.claimRequests
            XCTAssertEqual(claims.count, expected.count, "\(label): claim count")
            for (index, value) in expected.enumerated() where index < claims.count {
                XCTAssertTrue(match(value, claims[index], created: created),
                              "\(label): claim[\(index)] \(claims[index])")
            }
            if (expect["claimTokensEqual"] as? NSNumber)?.boolValue == true,
               claims.count > 1 {
                let tokens = claims.compactMap { $0["request"]?["sessionToken"]?.stringValue }
                XCTAssertEqual(Set(tokens).count, 1, "\(label): claims must reuse the current token")
            }
        }
        if let expected = expect["promptRequests"] as? [[String: Any]] {
            let prompts = transport.promptArguments
            XCTAssertEqual(prompts.count, expected.count, "\(label): prompt count")
            for (index, value) in expected.enumerated() where index < prompts.count {
                XCTAssertTrue(match(value, prompts[index], created: created),
                              "\(label): prompt[\(index)] \(prompts[index])")
            }
        }
        if let expected = expect["cancelRequests"] as? [[String: Any]] {
            XCTAssertEqual(transport.cancelArguments.count, expected.count, "\(label): cancel count")
            for (index, value) in expected.enumerated() where index < transport.cancelArguments.count {
                XCTAssertTrue(match(value, transport.cancelArguments[index], created: created),
                              "\(label): cancel[\(index)]")
            }
        }
        if let expected = expect["pageRequests"] as? [[String: Any]] {
            let pages = transport.pageArguments
            let count = (expect["pageRequestCount"] as? NSNumber)?.intValue ?? expected.count
            XCTAssertEqual(pages.count, count, "\(label): page count")
            for (index, value) in expected.enumerated() where index < pages.count {
                XCTAssertTrue(match(value, pages[index], created: created),
                              "\(label): page[\(index)]")
            }
        } else if let count = (expect["pageRequestCount"] as? NSNumber)?.intValue {
            XCTAssertEqual(transport.pageArguments.count, count, "\(label): page count")
        }
        if let count = (expect["listRequests"] as? NSNumber)?.intValue {
            XCTAssertEqual(transport.listArguments.count, count, "\(label): list count")
            if let expected = expect["listRequestArgs"] {
                XCTAssertTrue(match(expected, transport.listArguments.first ?? .null, created: created),
                              "\(label): list args")
            }
        }
        XCTAssertEqual(transport.archived, expect["archive"] as? [String] ?? [], "\(label): archived")
        XCTAssertEqual(transport.unarchived, expect["unarchive"] as? [String] ?? [], "\(label): unarchived")

        if let expected = expect["followOpen"] as? [Any] {
            XCTAssertEqual(transport.openFrames.count, expected.count, "\(label): follow opens")
            for (index, value) in expected.enumerated() where index < transport.openFrames.count {
                XCTAssertTrue(match(value, transport.openFrames[index], created: created),
                              "\(label): follow open[\(index)] \(transport.openFrames[index])")
            }
        }

        let lifecycleTypes: Set<String> = ["runtime.started", "runtime.exited"]
        let allEvents = try await botEvents(fixture.store)
        let appended = Array(allEvents.dropFirst(initialHead)).filter { lifecycleTypes.contains($0.type) }
        if let expected = expect["events"] as? [[String: Any]] {
            XCTAssertEqual(appended.count, expected.count, "\(label): lifecycle event count")
            for (index, value) in expected.enumerated() where index < appended.count {
                let event = appended[appended.startIndex + index]
                XCTAssertEqual(event.type, value["type"] as? String, "\(label): event type")
                XCTAssertTrue(match(value["data"], event.data, created: created),
                              "\(label): event data \(event.data)")
                let actualPrincipal: [String: Any] = [
                    "botId": event.principal.botId ?? "",
                    "sessionId": event.principal.sessionId ?? "",
                    "kind": event.principal.kind,
                ]
                XCTAssertTrue(match(value["principal"], actualPrincipal, created: created),
                              "\(label): event principal")
            }
        }

        if let expected = expect["liveFrames"] as? [[String: Any]] {
            let frames = recorder.frames
            XCTAssertEqual(frames.count, expected.count, "\(label): live frame count \(frames)")
            for (index, value) in expected.enumerated() where index < frames.count {
                XCTAssertEqual(frames[index]["kind"], value["kind"] as? String, label)
                if let text = value["text"] as? String {
                    XCTAssertEqual(frames[index]["text"], text, label)
                }
                if let type = value["type"] as? String {
                    XCTAssertEqual(frames[index]["type"], type, label)
                }
            }
        }
    }

    private func encodeJSON(_ value: Any?) throws -> BotJSONValue {
        guard let value else { return .object([:]) }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return try BotJSONValue.parse(data)
    }

    private func anyValue(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let json = value as? BotJSONValue,
           let data = try? JSONEncoder().encode(json) {
            return try? JSONSerialization.jsonObject(with: data)
        }
        return value
    }

    private func match(_ expected: Any?, _ actual: Any?, created: String?) -> Bool {
        let actual = anyValue(actual)
        func fail(_ reason: String) -> Bool {
            print("MATCH-FAIL \(reason) expected=\(String(describing: expected)) actual=\(String(describing: actual))")
            return false
        }
        guard let expected else { return actual == nil || actual is NSNull }
        if expected is NSNull { return actual == nil || actual is NSNull }
        if let pattern = expected as? String {
            guard let actualString = actual as? String else { return fail("not-string") }
            if pattern.hasPrefix("re:") {
                let expression = try? NSRegularExpression(pattern: String(pattern.dropFirst(3)))
                guard let expression else { return fail("bad-regex") }
                let range = NSRange(actualString.startIndex..<actualString.endIndex, in: actualString)
                return expression.firstMatch(in: actualString, range: range)?.range == range
                    ? true : fail("regex")
            }
            if pattern == "$created" { return actualString == created }
            return actualString == pattern ? true : fail("string")
        }
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { return fail("not-dict") }
            for (key, value) in expected {
                guard match(value, actual[key], created: created) else {
                    return fail("key-\(key)")
                }
            }
            return true
        }
        if let expected = expected as? [Any] {
            guard let actual = actual as? [Any], actual.count == expected.count else {
                return fail("array-shape")
            }
            for (index, value) in expected.enumerated() {
                guard match(value, actual[index], created: created) else {
                    return fail("array-\(index)")
                }
            }
            return true
        }
        if let expected = expected as? Bool {
            return (actual as? Bool) == expected ? true : fail("bool")
        }
        if let expected = expected as? NSNumber {
            return (actual as? NSNumber)?.doubleValue == expected.doubleValue ? true : fail("number")
        }
        return fail("unknown-type")
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition did not become true", file: file, line: line)
    }
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64

    init(_ value: Int64) { stored = value }

    var value: Int64 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LiveFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: String]] = []

    func record(_ frame: BotLiveTurnFrame) {
        var row: [String: String] = [:]
        switch frame.kind {
        case .streamStart:
            row["kind"] = "streamStart"
        case .textDelta(let text):
            row["kind"] = "textDelta"
            row["text"] = text
        case .event(let event):
            row["kind"] = "event"
            row["type"] = event["type"]?.stringValue ?? ""
        }
        lock.withLock { stored.append(row) }
    }

    var frames: [[String: String]] { lock.withLock { stored } }
}

/// Vector-driven `DSHRemoteTransport`. The vector is the request/response
/// transcript; this type only executes it.
private final class LifecycleTransport: DSHRemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var createResponses: [Any]
    private var pageResponses: [String: Any]
    private var listItems: [Any]
    private var claimResponses: [Any]
    private var turns: [[Any]]
    private var createIndex = 0
    private var claimIndex = 0
    private var turnIndex = 0
    private var archiveIDs: [String] = []
    private var unarchiveIDs: [String] = []
    private var createArgs: [BotJSONValue] = []
    private var claimArgs: [BotJSONValue] = []
    private var pageArgs: [BotJSONValue] = []
    private var listArgs: [BotJSONValue] = []
    private var promptArgs: [BotJSONValue] = []
    private var cancelArgs: [BotJSONValue] = []
    private var created: [String] = []
    private var opens: [BotJSONValue] = []
    private var cancellations = 0

    init(_ script: [String: Any]) {
        createResponses = script["create"] as? [Any] ?? []
        pageResponses = script["page"] as? [String: Any] ?? [:]
        listItems = script["list"] as? [Any] ?? []
        claimResponses = script["claim"] as? [Any] ?? []
        turns = script["turns"] as? [[Any]] ?? []
    }

    var createdSessionIds: [String] { lock.withLock { created } }
    var createArguments: [BotJSONValue] { lock.withLock { createArgs } }
    var claimRequests: [BotJSONValue] { lock.withLock { claimArgs } }
    var pageArguments: [BotJSONValue] { lock.withLock { pageArgs } }
    var listArguments: [BotJSONValue] { lock.withLock { listArgs } }
    var promptArguments: [BotJSONValue] { lock.withLock { promptArgs } }
    var promptCount: Int { lock.withLock { promptArgs.count } }
    var cancelArguments: [BotJSONValue] { lock.withLock { cancelArgs } }
    var archived: [String] { lock.withLock { archiveIDs } }
    var unarchived: [String] { lock.withLock { unarchiveIDs } }
    var openFrames: [BotJSONValue] { lock.withLock { opens } }

    func waitForCancel() async {
        for _ in 0..<400 {
            if lock.withLock({ cancellations }) > 0 { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func resolve(_ value: Any, requestedID: String, requestedPreset: String) -> Any {
        if let string = value as? String {
            if string == "$requested" { return requestedID }
            if string == "$requestedPreset" { return requestedPreset }
            return string
        }
        if let array = value as? [Any] {
            return array.map { resolve($0, requestedID: requestedID, requestedPreset: requestedPreset) }
        }
        if let object = value as? [String: Any] {
            return object.mapValues { resolve($0, requestedID: requestedID, requestedPreset: requestedPreset) }
        }
        return value
    }

    private func json(_ value: Any) -> BotJSONValue {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return try! BotJSONValue.parse(data)
    }

    private func throwIfError(_ response: [String: Any]) throws {
        if let error = response["error"] as? [String: Any] {
            throw DSHRemoteError(code: error["code"] as? String ?? "gateway/internal",
                                 message: error["message"] as? String ?? "")
        }
    }

    func call(_ endpoint: String, args: BotJSONValue) async throws -> BotJSONValue {
        let request = args["request"]
        let requestedID = request?["sessionId"]?.stringValue ?? ""
        let requestedPreset = request?["agentPreset"]?.stringValue ?? ""
        switch endpoint {
        case "session/create":
            lock.withLock {
                createArgs.append(args)
            }
            let response: [String: Any] = lock.withLock {
                let response = (createResponses[safe: createIndex] as? [String: Any]) ?? [:]
                createIndex += 1
                return response
            }
            try throwIfError(response)
            let resolved = resolve(response, requestedID: requestedID,
                                   requestedPreset: requestedPreset) as? [String: Any] ?? [:]
            if let id = resolved["sessionId"] as? String {
                lock.withLock { created.append(id) }
            }
            return json(resolved)
        case "session/page":
            lock.withLock { pageArgs.append(args) }
            let sessionID = request?["address"]?["sessionId"]?.stringValue ?? ""
            let response = lock.withLock {
                (pageResponses[sessionID] as? [String: Any]) ?? ["sessionId": sessionID]
            }
            try throwIfError(response)
            let resolved = resolve(response, requestedID: sessionID,
                                   requestedPreset: requestedPreset) as? [String: Any] ?? [:]
            return json(resolved)
        case "session/list":
            lock.withLock { listArgs.append(args) }
            return json(["items": listItems])
        case "phone/botClaimSession":
            lock.withLock { claimArgs.append(args) }
            let response: [String: Any] = lock.withLock {
                let response = (claimResponses[safe: claimIndex] as? [String: Any]) ?? ["ok": true]
                claimIndex += 1
                return response
            }
            try throwIfError(response)
            return json(["ok": response["ok"] ?? true, "sessionId": requestedID])
        case "workspace/archiveSession":
            let sessionID = request?["sessionId"]?.stringValue ?? ""
            lock.withLock { if !archiveIDs.contains(sessionID) { archiveIDs.append(sessionID) } }
            return json(["archivedSessionIds": [sessionID]])
        case "workspace/unarchiveSession":
            let sessionID = request?["sessionId"]?.stringValue ?? ""
            lock.withLock {
                archiveIDs.removeAll { $0 == sessionID }
                unarchiveIDs.append(sessionID)
            }
            return json(["archivedSessionIds": []])
        case "session/prompt":
            lock.withLock { promptArgs.append(args) }
            return .object([:])
        case "session/cancel":
            lock.withLock {
                cancelArgs.append(args)
                cancellations += 1
            }
            return .object([:])
        default:
            return .object([:])
        }
    }

    func openMux() async throws -> any DSHMuxConnection {
        let frames = lock.withLock { () -> [Any] in
            let frames = turns[safe: turnIndex] ?? []
            turnIndex += 1
            return frames
        }
        return LifecycleMux(frames: frames.map { json($0) }, transport: self)
    }

    func authenticationFailed() async {}

    func recordOpen(_ frame: BotJSONValue) {
        lock.withLock { opens.append(frame) }
    }
}

private final class LifecycleMux: DSHMuxConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [BotJSONValue]
    private var index = 0
    private weak var transport: LifecycleTransport?

    init(frames: [BotJSONValue], transport: LifecycleTransport) {
        self.frames = frames
        self.transport = transport
    }

    func send(_ frame: BotJSONValue) async throws {
        transport?.recordOpen(frame)
    }

    func receive() async throws -> BotJSONValue? {
        while true {
            let frame = lock.withLock { () -> BotJSONValue? in
                guard index < frames.count else { return nil }
                let frame = frames[index]
                index += 1
                return frame
            }
            guard let frame else { return nil }
            if frame["__awaitCancel"]?.boolValue == true {
                await transport?.waitForCancel()
                continue
            }
            return frame
        }
    }

    func close() async {}
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
