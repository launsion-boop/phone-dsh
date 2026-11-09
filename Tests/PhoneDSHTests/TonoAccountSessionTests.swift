// SPDX-License-Identifier: MIT
// spec/v1/tono-account.md §2–§4 on iOS. The shared cases judge the real
// parser, request builders, classifiers, record codec and clock; the session
// runs against a local fake of the account service that rotates refresh
// tokens and revokes the whole session when an old one is reused. No test
// contacts account.tonoai.cn and no value here is a real phone number.

import Foundation
import XCTest
@testable import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHGateway

// MARK: - Shared cases

final class TonoAccountCasesTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/v1/golden/tono-account/cases.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func list(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(try cases()[key] as? [[String: Any]], key)
    }

    private func body(_ item: [String: Any]) throws -> Data {
        if let text = item["body_text"] as? String { return Data(text.utf8) }
        guard let body = item["body"] else { return Data() }
        return try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
    }

    private func answer(_ item: [String: Any]) throws -> TonoAccountProtocol.Answer? {
        if item["transport_error"] as? Bool == true { return nil }
        return TonoAccountProtocol.Answer(status: try XCTUnwrap(item["status"] as? Int),
                                          headers: item["headers"] as? [String: String] ?? [:],
                                          body: try body(item))
    }

    func testConstants() throws {
        let constants = try XCTUnwrap(try cases()["constants"] as? [String: Any])
        XCTAssertEqual(constants["account_origin"] as? String, TonoAccountProtocol.accountOrigin.absoluteString)
        XCTAssertEqual(constants["client_id"] as? String, TonoAccountProtocol.clientID)
        XCTAssertEqual(constants["otp_grant_type"] as? String, TonoAccountProtocol.otpGrantType)
        XCTAssertEqual(constants["default_access_lifetime_seconds"] as? Int, TonoAccountProtocol.defaultAccessLifetimeSeconds)
        XCTAssertEqual(constants["refresh_skew_seconds"] as? Int, TonoAccountProtocol.refreshSkewSeconds)
        XCTAssertEqual((constants["reverify_after_seconds"] as? NSNumber)?.int64Value, TonoAccountProtocol.reverifyAfterSeconds)
        XCTAssertEqual(constants["token_max_length"] as? Int, TonoAccountProtocol.tokenMaxLength)
        XCTAssertEqual(constants["record_version"] as? Int, TonoAccountProtocol.recordVersion)
    }

    func testPhonesAndCodes() throws {
        for item in try list("phones") {
            XCTAssertEqual(TonoAccountProtocol.canonicalPhone(item["input"] as! String),
                           item["canonical"] as? String, "\(item["input"]!)")
        }
        for item in try list("codes") {
            XCTAssertEqual(TonoAccountProtocol.canonicalCode(item["input"] as! String),
                           item["canonical"] as? String, "\(item["input"]!)")
        }
    }

    func testRequestEncodings() throws {
        for item in try list("requests") {
            let name = item["name"] as! String
            let input = item["input"] as! [String: Any]
            let expect = item["expect"] as! [String: Any]
            let request: URLRequest
            switch item["operation"] as! String {
            case "send_code":
                request = TonoAccountProtocol.sendCodeRequest(phone: input["phone"] as! String)
            case "sign_in":
                let device = input["device_info"] as! [String: String]
                request = TonoAccountProtocol.signInRequest(
                    phone: input["phone"] as! String, challengeID: input["challenge_id"] as! String,
                    code: input["code"] as! String,
                    device: .init(platform: device["platform"]!, deviceName: device["device_name"]!,
                                  appVersion: device["app_version"]!, osVersion: device["os_version"]!))
            case "refresh":
                request = TonoAccountProtocol.refreshRequest(refreshToken: input["refresh_token"] as! String)
            case "sign_out":
                request = TonoAccountProtocol.signOutRequest(accessToken: input["access_token"] as! String)
            default:
                XCTFail("unknown operation in \(name)"); continue
            }
            XCTAssertEqual(request.httpMethod, expect["method"] as? String, name)
            XCTAssertEqual(request.url?.absoluteString, expect["url"] as? String, name)
            let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
            for (key, value) in expect["headers"] as! [String: String] {
                XCTAssertEqual(headers[key], value, "\(name) \(key)")
            }
            for key in expect["absent_headers"] as? [String] ?? [] {
                XCTAssertNil(headers[key], "\(name) \(key)")
            }
            let sent = request.httpBody ?? Data()
            if let text = expect["body"] as? String {
                XCTAssertEqual(String(decoding: sent, as: UTF8.self), text, name)
            }
            if let json = expect["body_json"] {
                let actual = try JSONSerialization.jsonObject(with: sent) as? NSDictionary
                XCTAssertEqual(actual, json as? NSDictionary, name)
            }
        }
    }

    func testTokenResponses() throws {
        for item in try list("token_responses") {
            let name = item["name"] as! String
            let expect = item["expect"] as! [String: Any]
            let grant = TonoAccountProtocol.parseTokenResponse(try body(item))
            guard expect["valid"] as! Bool else { XCTAssertNil(grant, name); continue }
            let parsed = try XCTUnwrap(grant, name)
            XCTAssertEqual(parsed.accessToken, expect["access_token"] as? String, name)
            XCTAssertEqual(parsed.refreshToken, expect["refresh_token"] as? String, name)
            XCTAssertEqual(parsed.expiresIn, expect["expires_in"] as? Int, name)
            XCTAssertEqual(parsed.userID, expect["user_id"] as? String, name)
            XCTAssertEqual(parsed.phoneHint, expect["phone_hint"] as? String, name)
            XCTAssertFalse(parsed.description.contains(parsed.accessToken), name)
        }
    }

    func testOutcomeClasses() throws {
        for item in try list("otp_outcomes") {
            let expect = item["expect"] as! [String: Any]
            let outcome = TonoAccountProtocol.classifySendCode(try answer(item))
            switch expect["outcome"] as! String {
            case "challenge": XCTAssertEqual(outcome, .challenge(expect["challenge_id"] as! String), "\(item["name"]!)")
            case "protocol_error": XCTAssertEqual(outcome, .protocolError, "\(item["name"]!)")
            case "rejected": XCTAssertEqual(outcome, .rejected, "\(item["name"]!)")
            case "rate_limited": XCTAssertEqual(outcome, .rateLimited(retryAfterSeconds: expect["retry_after_seconds"] as? Int), "\(item["name"]!)")
            case "transient": XCTAssertEqual(outcome, .transient, "\(item["name"]!)")
            default: XCTFail("\(item)")
            }
        }
        for item in try list("login_outcomes") {
            let expect = item["expect"] as! [String: Any]
            let outcome = TonoAccountProtocol.classifySignIn(try answer(item))
            let name = "\(item["name"]!)"
            switch expect["outcome"] as! String {
            case "signed_in":
                guard case .signedIn = outcome else { XCTFail(name); continue }
            case "protocol_error": XCTAssertEqual(outcome, .protocolError, name)
            case "invalid_code": XCTAssertEqual(outcome, .invalidCode, name)
            case "rejected": XCTAssertEqual(outcome, .rejected, name)
            case "rate_limited": XCTAssertEqual(outcome, .rateLimited(retryAfterSeconds: expect["retry_after_seconds"] as? Int), name)
            case "transient": XCTAssertEqual(outcome, .transient, name)
            default: XCTFail("\(item)")
            }
        }
        for item in try list("refresh_outcomes") {
            let expect = item["expect"] as! [String: Any]
            let outcome = TonoAccountProtocol.classifyRefresh(try answer(item))
            let name = "\(item["name"]!)"
            switch expect["outcome"] as! String {
            case "rotated":
                guard case .rotated = outcome else { XCTFail(name); continue }
            case "session_ended": XCTAssertEqual(outcome, .sessionEnded, name)
            case "transient": XCTAssertEqual(outcome, .transient, name)
            default: XCTFail("\(item)")
            }
        }
    }

    func testSessionRecords() throws {
        for item in try list("session_records") {
            let name = item["name"] as! String
            let expect = item["expect"] as! [String: Any]
            let record = TonoAccountProtocol.decodeRecord(Data((item["stored_text"] as! String).utf8))
            guard expect["readable"] as! Bool else { XCTAssertNil(record, name); continue }
            let decoded = try XCTUnwrap(record, name)
            XCTAssertEqual(decoded.refreshToken, expect["refresh_token"] as? String, name)
            XCTAssertEqual(decoded.loginAtMs, (expect["login_at_ms"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(decoded.userID, expect["user_id"] as? String, name)
            XCTAssertEqual(decoded.phoneHint, expect["phone_hint"] as? String, name)
            // The writer produces a record its own reader accepts unchanged.
            XCTAssertEqual(TonoAccountProtocol.decodeRecord(TonoAccountProtocol.encodeRecord(decoded)), decoded, name)
        }
    }

    func testClock() throws {
        for item in try list("clock") {
            let decision = TonoAccountProtocol.clockDecision(
                issuedAtMs: (item["issued_at_ms"] as! NSNumber).int64Value,
                expiresIn: item["expires_in"] as! Int,
                loginAtMs: (item["login_at_ms"] as! NSNumber).int64Value,
                nowMs: (item["now_ms"] as! NSNumber).int64Value)
            let expected: TonoAccountProtocol.ClockDecision
            switch item["expect"] as! String {
            case "use": expected = .use
            case "refresh": expected = .refresh
            default: expected = .reverifyRequired
            }
            XCTAssertEqual(decision, expected, "\(item["name"]!)")
        }
    }
}

// MARK: - Fakes

/// A local account service: OTP challenges, rotating refresh tokens, reuse
/// revocation, logout. `holdRefresh` keeps refresh answers pending so tests
/// can overlap callers deterministically.
final class FakeTonoAccountService: TonoAccountTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private var liveRefresh: String?
    private var usedRefresh: Set<String> = []
    private var currentAccess: String?
    private(set) var revoked = false
    var expiresIn = 7200
    /// Answers to return for the next refresh calls instead of rotating.
    var scriptedRefresh: [TonoAccountProtocol.Answer?] = []
    var refreshDelayNanoseconds: UInt64 = 0
    private(set) var refreshTokensSent: [String] = []
    private(set) var logoutAuthorizations: [String] = []
    private(set) var paths: [String] = []

    var refreshCount: Int { lock.withLock { refreshTokensSent.count } }
    var accessToken: String? { lock.withLock { currentAccess } }

    func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer {
        let path = request.url?.path ?? ""
        lock.withLock { paths.append(path) }
        switch path {
        case "/v1/auth/otp/send":
            return json(200, ["challenge_id": "ch_TEST_0001"])
        case "/v1/oauth/token":
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.hasPrefix("application/json") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                guard body?["code"] as? String == "123456" else { return json(400, ["error": "invalid_grant"]) }
                return lock.withLock { issueLocked() }
            }
            let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let token = form.components(separatedBy: "&").first { $0.hasPrefix("refresh_token=") }
                .map { String($0.dropFirst("refresh_token=".count)).removingPercentEncoding ?? "" } ?? ""
            lock.withLock { refreshTokensSent.append(token) }
            if refreshDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: refreshDelayNanoseconds) }
            return lock.withLock {
                if !scriptedRefresh.isEmpty, let scripted = scriptedRefresh.removeFirst() { return scripted }
                if revoked { return jsonLocked(400, ["error": "invalid_grant"]) }
                if usedRefresh.contains(token) {
                    // Reuse of a rotated token revokes the whole session.
                    revoked = true
                    liveRefresh = nil
                    currentAccess = nil
                    return jsonLocked(400, ["error": "invalid_grant"])
                }
                guard token == liveRefresh else { return jsonLocked(400, ["error": "invalid_grant"]) }
                usedRefresh.insert(token)
                return issueLocked()
            }
        case "/v1/auth/logout":
            lock.withLock {
                logoutAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                revoked = true
            }
            return json(204, [:])
        default:
            return json(404, [:])
        }
    }

    private func issueLocked() -> TonoAccountProtocol.Answer {
        counter += 1
        let refresh = "rt_TEST_REFRESH_\(counter)"
        let access = "at_TEST_ACCESS_\(counter)"
        liveRefresh = refresh
        currentAccess = access
        return jsonLocked(200, ["access_token": access, "refresh_token": refresh,
                                "token_type": "Bearer", "expires_in": expiresIn,
                                "user": ["id": "u_TEST_0001", "phone": "+8610000001234"]])
    }

    private func json(_ status: Int, _ object: [String: Any]) -> TonoAccountProtocol.Answer {
        lock.withLock { jsonLocked(status, object) }
    }

    private func jsonLocked(_ status: Int, _ object: [String: Any]) -> TonoAccountProtocol.Answer {
        TonoAccountProtocol.Answer(status: status, headers: ["content-type": "application/json"],
                                   body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

final class OfflineTransport: TonoAccountTransport {
    func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer { throw URLError(.notConnectedToInternet) }
}

/// One-item store with write-failure injection; records every operation.
final class MemoryTonoAccountStore: TonoAccountSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    var failSaves = false
    private(set) var operations: [String] = []

    init(_ value: Data? = nil) { self.value = value }

    var data: Data? { lock.withLock { value } }
    var record: TonoAccountProtocol.SessionRecord? { data.flatMap(TonoAccountProtocol.decodeRecord) }

    func load() throws -> Data? { lock.withLock { value } }
    func save(_ data: Data) throws {
        try lock.withLock {
            operations.append("save")
            if failSaves { throw TonoAccountStoreError.unavailable }
            value = data
        }
    }
    func delete() throws { lock.withLock { operations.append("delete"); value = nil } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_762_214_400)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

// MARK: - Session

final class TonoAccountSessionTests: XCTestCase {
    private let device = TonoAccountProtocol.DeviceInfo(platform: "ios", deviceName: "iPhone",
                                                        appVersion: "0.1.0", osVersion: "26.1")

    private func makeSession(_ service: any TonoAccountTransport,
                             _ store: MemoryTonoAccountStore,
                             _ clock: TestClock) -> TonoAccountSession {
        TonoAccountSession(client: TonoAccountClient(transport: service), store: store,
                           device: device, now: { clock.now })
    }

    private func signIn(_ session: TonoAccountSession) async throws {
        let challenge = try await session.requestCode(phone: "100 0000 0000")
        XCTAssertEqual(challenge.phone, "+8610000000000")
        try await session.signIn(challenge, code: " 123456 ")
    }

    func testSignInStoresOnlyTheRefreshTokenAndServesTheAccessToken() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let session = makeSession(service, store, TestClock())
        try await signIn(session)

        XCTAssertEqual(store.record?.refreshToken, "rt_TEST_REFRESH_1")
        XCTAssertEqual(store.record?.phoneHint, "1234")
        let stored = String(decoding: store.data ?? Data(), as: UTF8.self)
        XCTAssertFalse(stored.contains("at_TEST_ACCESS"), "the access token is memory-only")
        let token = try await session.accessToken()
        XCTAssertEqual(token, "at_TEST_ACCESS_1")
        XCTAssertEqual(service.refreshCount, 0)
        guard case .signedIn(let summary) = await session.state else { return XCTFail("not signed in") }
        XCTAssertEqual(summary.phoneHint, "1234")
        XCTAssertTrue(session.hasSession)
    }

    func testInvalidInputSendsNothing() async throws {
        let service = FakeTonoAccountService()
        let session = makeSession(service, MemoryTonoAccountStore(), TestClock())
        do {
            _ = try await session.requestCode(phone: "+1 2025550100")
            XCTFail("accepted a non-+86 number")
        } catch let error as TonoAccountError { XCTAssertEqual(error, .invalidPhone) }
        let challenge = try await session.requestCode(phone: "10000000000")
        do {
            try await session.signIn(challenge, code: "12a456")
            XCTFail("accepted a non-digit code")
        } catch let error as TonoAccountError { XCTAssertEqual(error, .invalidCode) }
        do {
            try await session.signIn(challenge, code: "654321")
            XCTFail("accepted a wrong code")
        } catch let error as TonoAccountError { XCTAssertEqual(error, .wrongCode) }
        XCTAssertEqual(service.paths, ["/v1/auth/otp/send", "/v1/oauth/token"])
        let token = try await session.accessToken()
        XCTAssertNil(token)
    }

    func testRotationReplacesTheStoredTokenAtomicallyAndNeverResendsTheOldOne() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        let session = makeSession(service, store, clock)
        try await signIn(session)

        for round in 2...4 {
            clock.advance(7200 - 300)
            let token = try await session.accessToken()
            XCTAssertEqual(token, "at_TEST_ACCESS_\(round)")
            XCTAssertEqual(store.record?.refreshToken, "rt_TEST_REFRESH_\(round)")
        }
        XCTAssertEqual(service.refreshTokensSent, ["rt_TEST_REFRESH_1", "rt_TEST_REFRESH_2", "rt_TEST_REFRESH_3"])
        XCTAssertFalse(store.operations.contains("delete"), "rotation never deletes and re-adds the item")
        XCTAssertFalse(service.revoked)
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        let session = makeSession(service, store, clock)
        try await signIn(session)
        clock.advance(7200)
        service.refreshDelayNanoseconds = 100_000_000

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<24 { group.addTask { try await session.accessToken() } }
            var all: [String?] = []
            for try await token in group { all.append(token) }
            return all
        }
        XCTAssertEqual(service.refreshCount, 1, "single flight")
        XCTAssertEqual(Set(tokens.compactMap { $0 }), ["at_TEST_ACCESS_2"])
        XCTAssertEqual(tokens.count, 24)
        XCTAssertFalse(service.revoked)
    }

    func testReuseOfARotatedTokenEndsTheSessionWithAVisibleNotice() async throws {
        // A rotation whose store write failed, then a relaunch: the new
        // process only has the old refresh token. Its reuse revokes the
        // session on the server, and the app must ask for a new sign-in.
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        let first = makeSession(service, store, clock)
        try await signIn(first)
        store.failSaves = true
        clock.advance(7200)
        let rotated = try await first.accessToken()
        XCTAssertEqual(rotated, "at_TEST_ACCESS_2", "a failed write still serves the rotated token")
        XCTAssertEqual(store.record?.refreshToken, "rt_TEST_REFRESH_1", "the old token is still on disk")

        store.failSaves = false
        let relaunched = makeSession(service, store, clock)
        do {
            _ = try await relaunched.accessToken()
            XCTFail("a reused token must not produce a credential")
        } catch let error as TonoAccountError {
            XCTAssertEqual(error, .sessionEnded)
        }
        XCTAssertTrue(service.revoked)
        XCTAssertNil(store.data, "the ended session is deleted")
        let state = await relaunched.state
        XCTAssertEqual(state, .signedOut(notice: .sessionEnded))
        let afterwards = try await relaunched.accessToken()
        XCTAssertNil(afterwards, "signed out: callers fall back to their API-key path")
        XCTAssertFalse(relaunched.hasSession)
    }

    func testFailedWriteIsRetriedBeforeTheNextRefresh() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        let session = makeSession(service, store, clock)
        try await signIn(session)
        store.failSaves = true
        clock.advance(7200)
        _ = try await session.accessToken()
        store.failSaves = false
        clock.advance(7200)
        let token = try await session.accessToken()
        XCTAssertEqual(token, "at_TEST_ACCESS_3")
        XCTAssertEqual(store.record?.refreshToken, "rt_TEST_REFRESH_3")
        XCTAssertEqual(service.refreshTokensSent, ["rt_TEST_REFRESH_1", "rt_TEST_REFRESH_2"])
    }

    func testTransientRefreshFailureKeepsTheSession() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        let session = makeSession(service, store, clock)
        try await signIn(session)
        clock.advance(7200)
        service.scriptedRefresh = [
            TonoAccountProtocol.Answer(status: 503, headers: ["retry-after": "3"],
                                       body: Data(#"{"error":{"code":"identity_unavailable"}}"#.utf8)),
            nil,
        ]
        do {
            _ = try await session.accessToken()
            XCTFail("no token while the account service is unavailable")
        } catch let error as TonoAccountError {
            XCTAssertEqual(error, .temporarilyUnavailable)
        }
        XCTAssertEqual(store.record?.refreshToken, "rt_TEST_REFRESH_1")
        guard case .signedIn = await session.state else { return XCTFail("a transient failure ended the session") }
        let token = try await session.accessToken()
        XCTAssertEqual(token, "at_TEST_ACCESS_2")
    }

    func testInvalidateOnlyDropsTheCurrentToken() async throws {
        let service = FakeTonoAccountService()
        let session = makeSession(service, MemoryTonoAccountStore(), TestClock())
        try await signIn(session)
        await session.invalidate(accessToken: "pdsk_TEST_NOT_OURS")
        let unchanged = try await session.accessToken()
        XCTAssertEqual(unchanged, "at_TEST_ACCESS_1")
        XCTAssertEqual(service.refreshCount, 0)
        await session.invalidate(accessToken: "at_TEST_ACCESS_1")
        let refreshed = try await session.accessToken()
        XCTAssertEqual(refreshed, "at_TEST_ACCESS_2")
        // A late 401 for the old value must not trigger a second refresh.
        await session.invalidate(accessToken: "at_TEST_ACCESS_1")
        let same = try await session.accessToken()
        XCTAssertEqual(same, "at_TEST_ACCESS_2")
        XCTAssertEqual(service.refreshCount, 1)
    }

    func testSignOutClearsLocallyAndCallsLogoutWithTheAccessToken() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let session = makeSession(service, store, TestClock())
        try await signIn(session)
        await session.signOut()
        XCTAssertNil(store.data)
        XCTAssertEqual(service.logoutAuthorizations, ["Bearer at_TEST_ACCESS_1"])
        let state = await session.state
        XCTAssertEqual(state, .signedOut(notice: nil))
        let token = try await session.accessToken()
        XCTAssertNil(token)
    }

    func testSignOutSucceedsOffline() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        try await signIn(makeSession(service, store, clock))
        let offline = makeSession(OfflineTransport(), store, clock)
        await offline.signOut()
        XCTAssertNil(store.data)
        let state = await offline.state
        XCTAssertEqual(state, .signedOut(notice: nil))
    }

    func testLateRefreshAfterSignOutIsDiscarded() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        let session = makeSession(service, store, clock)
        try await signIn(session)
        clock.advance(7200)
        service.refreshDelayNanoseconds = 200_000_000
        let pending = Task { try await session.accessToken() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await session.signOut()
        let token = try await pending.value
        XCTAssertNil(token, "the stale refresh publishes nothing")
        XCTAssertNil(store.data, "the stale refresh writes nothing")
        let state = await session.state
        XCTAssertEqual(state, .signedOut(notice: nil))
    }

    func testReverificationAfter180Days() async throws {
        let service = FakeTonoAccountService()
        let store = MemoryTonoAccountStore()
        let clock = TestClock()
        try await signIn(makeSession(service, store, clock))
        clock.advance(TimeInterval(TonoAccountProtocol.reverifyAfterSeconds))
        let relaunched = makeSession(service, store, clock)
        do {
            _ = try await relaunched.accessToken()
            XCTFail("expired by the 180-day rule")
        } catch let error as TonoAccountError {
            XCTAssertEqual(error, .reverifyRequired)
        }
        XCTAssertEqual(service.refreshCount, 0, "no request after the local limit")
        XCTAssertNil(store.data)
        let state = await relaunched.state
        XCTAssertEqual(state, .signedOut(notice: .reverifyRequired))
    }

    func testUnreadableRecordIsSignedOutAndKept() async throws {
        let stored = Data(#"{"version":2,"refresh_token":"rt_TEST_REFRESH_1","login_at_ms":0}"#.utf8)
        let store = MemoryTonoAccountStore(stored)
        let session = makeSession(FakeTonoAccountService(), store, TestClock())
        let token = try await session.accessToken()
        XCTAssertNil(token)
        let state = await session.state
        XCTAssertEqual(state, .signedOut(notice: nil))
        XCTAssertEqual(store.data, stored, "an unknown version is not deleted")
        XCTAssertFalse(session.hasSession)
    }
}

// MARK: - Credential precedence (§4)

final class TonoAccountCredentialPrecedenceTests: XCTestCase {
    private struct FixedTokens: TonoAccessTokenSource {
        var token: String?
        var fails = false
        var hasSession: Bool { token != nil || fails }
        func accessToken() async throws -> String? {
            if fails { throw TonoAccountError.temporarilyUnavailable }
            return token
        }
        func invalidate(accessToken: String) async {}
    }

    private struct Secrets: ModelProviderSecretStore {
        func secret(for reference: String) throws -> String? { "pdsk_TEST_SHARED_KEY" }
        func setSecret(_ secret: String, for reference: String) throws {}
        func deleteSecret(for reference: String) throws {}
    }

    private func modelProvider(_ endpoint: String, _ tokens: FixedTokens?) -> ModelProviderCredentialProvider {
        let url = URL(string: endpoint)!
        return ModelProviderCredentialProvider(modelHost: url.host!, credentialRef: "provider.default",
                                               secretStore: Secrets(), egressAllowHosts: [],
                                               modelEndpoint: url, accountTokens: tokens)
    }

    private func scope(_ url: String) -> CredentialScope {
        ModelGatewayCredentialRouting.scope(for: URL(string: url)!)
    }

    func testModelPathsOnTheCloudOriginUseTheTokenOnTheSameHeader() async throws {
        let provider = modelProvider("https://pdsh.tonoai.cn/v1/llm/anthropic", FixedTokens(token: "at_TEST_ACCESS_1"))
        let credential = try await provider.credential(for: scope("https://pdsh.tonoai.cn/v1/llm/anthropic/v1/messages"))
        XCTAssertEqual(credential, Credential(kind: .apiKey(header: "x-api-key"), value: "at_TEST_ACCESS_1"))
        // Path admission still decides first: a same-origin non-model path gets nothing.
        let other = try await provider.credential(for: scope("https://pdsh.tonoai.cn/v1/tts/speech"))
        XCTAssertEqual(other, .none)
        let port = try await provider.credential(for: scope("https://pdsh.tonoai.cn:8443/v1/llm/anthropic/v1/messages"))
        XCTAssertEqual(port, .none)
    }

    func testSignedOutKeepsTheApiKeyPath() async throws {
        let provider = modelProvider("https://pdsh.tonoai.cn/v1/llm/anthropic", FixedTokens(token: nil))
        let credential = try await provider.credential(for: scope("https://pdsh.tonoai.cn/v1/llm/anthropic/v1/messages"))
        XCTAssertEqual(credential.value, "pdsk_TEST_SHARED_KEY")
    }

    func testOtherOriginsNeverSeeTheToken() async throws {
        let provider = modelProvider("https://api.deepseek.com/anthropic", FixedTokens(token: "at_TEST_ACCESS_1"))
        let credential = try await provider.credential(for: scope("https://api.deepseek.com/anthropic/v1/messages"))
        XCTAssertEqual(credential.value, "pdsk_TEST_SHARED_KEY")
    }

    func testSignedInWithoutATokenFailsClosed() async {
        let provider = modelProvider("https://pdsh.tonoai.cn/v1/llm/anthropic", FixedTokens(token: nil, fails: true))
        do {
            _ = try await provider.credential(for: scope("https://pdsh.tonoai.cn/v1/llm/anthropic/v1/messages"))
            XCTFail("fell back to the shared key")
        } catch {}
    }

    func testIndependentSearchOnTheCloudOriginUsesTheTokenAsBearer() async throws {
        let router = PhoneWebSearchCredentialRouter(
            modelProvider: StaticCredentialProvider([:]), searchHost: "pdsh.tonoai.cn",
            searchScheme: "https", searchPort: 443,
            operationPaths: ["/v1/web/search", "/v1/web/fetch"],
            credentialRef: "search.deepseek.api", secretStore: Secrets(),
            accountTokens: FixedTokens(token: "at_TEST_ACCESS_1"))
        let credential = try await router.credential(for: scope("https://pdsh.tonoai.cn/v1/web/search"))
        XCTAssertEqual(credential, Credential(kind: .bearer, value: "at_TEST_ACCESS_1"))
        let signedOut = PhoneWebSearchCredentialRouter(
            modelProvider: StaticCredentialProvider([:]), searchHost: "pdsh.tonoai.cn",
            searchScheme: "https", searchPort: 443,
            operationPaths: ["/v1/web/search", "/v1/web/fetch"],
            credentialRef: "search.deepseek.api", secretStore: Secrets(),
            accountTokens: FixedTokens(token: nil))
        let key = try await signedOut.credential(for: scope("https://pdsh.tonoai.cn/v1/web/fetch"))
        XCTAssertEqual(key, Credential(kind: .bearer, value: "pdsk_TEST_SHARED_KEY"))
    }

    func testSettingsOnlyPassTheTokenSourceForCloudSearchBases() throws {
        let suite = "tono-precedence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PhoneWebSearchSettings(defaults: defaults, secretStore: Secrets(),
                                              accountTokens: FixedTokens(token: "at_TEST_ACCESS_1"))
        let cloud = PhoneWebSearchSnapshot(configuration: PhoneWebSearchConfiguration(
            mode: .searchAPI, baseURL: "https://pdsh.tonoai.cn/v1/web"))
        let other = PhoneWebSearchSnapshot(configuration: PhoneWebSearchConfiguration(
            mode: .searchAPI, baseURL: "https://search.example.com"))
        XCTAssertTrue(settings.usesAccountCredential(cloud))
        XCTAssertFalse(settings.usesAccountCredential(other))
        let signedOut = PhoneWebSearchSettings(defaults: defaults, secretStore: Secrets(),
                                               accountTokens: FixedTokens(token: nil))
        XCTAssertFalse(signedOut.usesAccountCredential(cloud))
    }
}
