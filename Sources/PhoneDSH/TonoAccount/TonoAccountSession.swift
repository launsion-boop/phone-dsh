// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: the tono-account session.
//
// spec/v1/tono-account.md §3. One actor owns the session: the refresh token
// lives in one secret item and in memory, the access token only in memory.
// A refresh is single-flight; a rotated refresh token is written in one store
// write before the new access token is published; sign-in and sign-out start a
// new generation, so a late refresh can neither write the store nor publish a
// token for a session that no longer exists.

import Foundation
import os

/// The seam the model/search credential routers use (spec §4).
public protocol TonoAccessTokenSource: Sendable {
    /// A currently valid access token, refreshing when needed. `nil` means
    /// signed out: the caller uses its existing API-key path. Throws while
    /// signed in when no token can be obtained (fail closed, never the key).
    func accessToken() async throws -> String?
    /// The service rejected `accessToken`; the next call refreshes.
    func invalidate(accessToken: String) async
    /// Synchronous hint for launch decisions: a session record is present.
    var hasSession: Bool { get }
}

public enum TonoAccountNotice: Equatable, Sendable {
    /// The account service ended the session (reuse, expiry, revocation).
    case sessionEnded
    /// 180 days since sign-in: the phone must be verified again.
    case reverifyRequired
}

/// What the page may show. No token and no full phone number.
public struct TonoAccountSummary: Equatable, Sendable {
    public var phoneHint: String?
    public var signedInAt: Date
    public var reverifyAt: Date
}

public enum TonoAccountState: Equatable, Sendable {
    case signedOut(notice: TonoAccountNotice?)
    case signedIn(TonoAccountSummary)
}

public enum TonoAccountError: Error, Equatable, Sendable, LocalizedError {
    case invalidPhone
    case invalidCode
    case wrongCode
    case rejected
    case rateLimited(retryAfterSeconds: Int?)
    case protocolError
    case temporarilyUnavailable
    case sessionEnded
    case reverifyRequired

    public var errorDescription: String? {
        switch self {
        case .invalidPhone: return "请输入 11 位中国大陆手机号。"
        case .invalidCode: return "请输入短信里的数字验证码。"
        case .wrongCode: return "验证码错误或已过期，请重新获取。"
        case .rejected: return "账号服务拒绝了这次请求。"
        case .rateLimited(let seconds):
            if let seconds { return "操作太频繁，请 \(seconds) 秒后再试。" }
            return "操作太频繁，请稍后再试。"
        case .protocolError: return "账号服务返回了无法识别的结果，请稍后再试。"
        case .temporarilyUnavailable: return "暂时连不上账号服务，请稍后再试。"
        case .sessionEnded: return "登录已失效，请重新登录。"
        case .reverifyRequired: return "登录已满 180 天，请重新验证手机号。"
        }
    }
}

/// A sent code waiting for the person to type it.
public struct TonoAccountChallenge: Equatable, Sendable {
    public let phone: String
    public let challengeID: String

    public var phoneHint: String? { TonoAccountProtocol.phoneHint(phone) }
}

public actor TonoAccountSession: TonoAccessTokenSource {
    /// Process-wide session used by the app (Keychain + URLSession).
    public static let shared = TonoAccountSession(
        client: TonoAccountClient(transport: URLSessionTonoAccountTransport()),
        store: KeychainTonoAccountSessionStore())

    private struct Access {
        var token: String
        var issuedAtMs: Int64
        var expiresIn: Int
    }

    private enum RefreshResult: Sendable {
        case token(String)
        case failed(TonoAccountError)
        /// The session changed generation while the refresh was in flight.
        case stale
    }

    private let client: TonoAccountClient
    private let store: any TonoAccountSessionStore
    private let now: @Sendable () -> Date
    private let device: TonoAccountProtocol.DeviceInfo
    private nonisolated let sessionHint: OSAllocatedUnfairLock<Bool?>

    private var loaded = false
    private var record: TonoAccountProtocol.SessionRecord?
    private var access: Access?
    private var generation: UInt64 = 0
    private var refreshTask: (generation: UInt64, task: Task<RefreshResult, Never>)?
    private var persistPending = false
    private var notice: TonoAccountNotice?
    private var observers: [UUID: AsyncStream<TonoAccountState>.Continuation] = [:]

    public init(client: TonoAccountClient,
                store: any TonoAccountSessionStore,
                device: TonoAccountProtocol.DeviceInfo = .current(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.device = device
        self.now = now
        self.sessionHint = OSAllocatedUnfairLock(initialState: nil)
    }

    // MARK: - Observation

    public var state: TonoAccountState {
        loadIfNeeded()
        return currentState
    }

    /// Every state change, starting with the current one.
    public func states() -> AsyncStream<TonoAccountState> {
        loadIfNeeded()
        let id = UUID()
        let (stream, continuation) = AsyncStream<TonoAccountState>.makeStream()
        observers[id] = continuation
        continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// The page acknowledged the notice.
    public func clearNotice() {
        guard notice != nil else { return }
        notice = nil
        publish()
    }

    public nonisolated var hasSession: Bool {
        if let cached = sessionHint.withLock({ $0 }) { return cached }
        let present = (try? store.load()).flatMap { $0 }.flatMap(TonoAccountProtocol.decodeRecord) != nil
        sessionHint.withLock { if $0 == nil { $0 = present } }
        return present
    }

    // MARK: - Sign in / out

    public func requestCode(phone raw: String) async throws -> TonoAccountChallenge {
        guard let phone = TonoAccountProtocol.canonicalPhone(raw) else { throw TonoAccountError.invalidPhone }
        switch await client.sendCode(phone: phone) {
        case .challenge(let id): return TonoAccountChallenge(phone: phone, challengeID: id)
        case .protocolError: throw TonoAccountError.protocolError
        case .rejected: throw TonoAccountError.rejected
        case .rateLimited(let seconds): throw TonoAccountError.rateLimited(retryAfterSeconds: seconds)
        case .transient: throw TonoAccountError.temporarilyUnavailable
        }
    }

    public func signIn(_ challenge: TonoAccountChallenge, code raw: String) async throws {
        guard let code = TonoAccountProtocol.canonicalCode(raw) else { throw TonoAccountError.invalidCode }
        let outcome = await client.signIn(phone: challenge.phone, challengeID: challenge.challengeID,
                                          code: code, device: device)
        switch outcome {
        case .signedIn(let grant):
            loadIfNeeded()
            let nowMs = Self.milliseconds(now())
            generation &+= 1
            refreshTask = nil
            let newRecord = TonoAccountProtocol.SessionRecord(
                refreshToken: grant.refreshToken, loginAtMs: nowMs,
                userID: grant.userID, phoneHint: grant.phoneHint ?? challenge.phoneHint)
            record = newRecord
            persist(newRecord)
            access = Access(token: grant.accessToken, issuedAtMs: nowMs, expiresIn: grant.expiresIn)
            notice = nil
            publish()
        case .protocolError: throw TonoAccountError.protocolError
        case .invalidCode: throw TonoAccountError.wrongCode
        case .rejected: throw TonoAccountError.rejected
        case .rateLimited(let seconds): throw TonoAccountError.rateLimited(retryAfterSeconds: seconds)
        case .transient: throw TonoAccountError.temporarilyUnavailable
        }
    }

    /// §3 sign-out: local state is cleared first and unconditionally; the
    /// server call is best effort.
    public func signOut() async {
        loadIfNeeded()
        var token: String?
        if let access, let record,
           TonoAccountProtocol.clockDecision(issuedAtMs: access.issuedAtMs, expiresIn: access.expiresIn,
                                             loginAtMs: record.loginAtMs,
                                             nowMs: Self.milliseconds(now())) == .use {
            token = access.token
        }
        endLocally(notice: nil)
        if let token { await client.signOut(accessToken: token) }
    }

    // MARK: - TonoAccessTokenSource

    public func accessToken() async throws -> String? {
        loadIfNeeded()
        guard let record else { return nil }
        let nowMs = Self.milliseconds(now())
        if let access {
            switch TonoAccountProtocol.clockDecision(issuedAtMs: access.issuedAtMs,
                                                     expiresIn: access.expiresIn,
                                                     loginAtMs: record.loginAtMs, nowMs: nowMs) {
            case .use: return access.token
            case .reverifyRequired:
                endLocally(notice: .reverifyRequired)
                throw TonoAccountError.reverifyRequired
            case .refresh: break
            }
        } else if nowMs - record.loginAtMs >= TonoAccountProtocol.reverifyAfterSeconds * 1000 {
            endLocally(notice: .reverifyRequired)
            throw TonoAccountError.reverifyRequired
        }
        switch await refreshSingleFlight() {
        case .token(let token): return token
        case .failed(let error): throw error
        case .stale: return try await accessToken()
        }
    }

    public func invalidate(accessToken token: String) {
        if access?.token == token { access = nil }
    }

    // MARK: - Refresh

    private func refreshSingleFlight() async -> RefreshResult {
        if let running = refreshTask, running.generation == generation {
            return await running.task.value
        }
        guard let record else { return .stale }
        let generation = self.generation
        let refreshToken = record.refreshToken
        let task = Task { await self.performRefresh(generation: generation, refreshToken: refreshToken) }
        refreshTask = (generation, task)
        return await task.value
    }

    private func performRefresh(generation: UInt64, refreshToken: String) async -> RefreshResult {
        if persistPending, let record { persist(record) }
        let outcome = await client.refresh(refreshToken: refreshToken)
        defer {
            if refreshTask?.generation == generation { refreshTask = nil }
        }
        guard generation == self.generation, let current = record else { return .stale }
        switch outcome {
        case .rotated(let grant):
            let rotated = TonoAccountProtocol.SessionRecord(
                refreshToken: grant.refreshToken, loginAtMs: current.loginAtMs,
                userID: grant.userID ?? current.userID, phoneHint: grant.phoneHint ?? current.phoneHint)
            // The old refresh token is already invalid on the server: memory
            // holds the new one whatever the store write does.
            record = rotated
            persist(rotated)
            access = Access(token: grant.accessToken, issuedAtMs: Self.milliseconds(now()),
                            expiresIn: grant.expiresIn)
            return .token(grant.accessToken)
        case .sessionEnded:
            endLocally(notice: .sessionEnded)
            return .failed(.sessionEnded)
        case .transient:
            return .failed(.temporarilyUnavailable)
        }
    }

    // MARK: - State

    private var currentState: TonoAccountState {
        guard let record else { return .signedOut(notice: notice) }
        let signedInAt = Date(timeIntervalSince1970: TimeInterval(record.loginAtMs) / 1000)
        return .signedIn(TonoAccountSummary(
            phoneHint: record.phoneHint,
            signedInAt: signedInAt,
            reverifyAt: signedInAt.addingTimeInterval(TimeInterval(TonoAccountProtocol.reverifyAfterSeconds))))
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        let data: Data?
        do {
            data = try store.load()
        } catch {
            // A locked Keychain throws: stay unloaded and read again later.
            return
        }
        loaded = true
        // An unreadable record is signed out and kept until sign-in or sign-out.
        let decoded = data.flatMap(TonoAccountProtocol.decodeRecord)
        record = decoded
        sessionHint.withLock { $0 = decoded != nil }
    }

    private func persist(_ record: TonoAccountProtocol.SessionRecord) {
        do {
            try store.save(TonoAccountProtocol.encodeRecord(record))
            persistPending = false
        } catch {
            persistPending = true
        }
        sessionHint.withLock { $0 = true }
    }

    private func endLocally(notice: TonoAccountNotice?) {
        generation &+= 1
        refreshTask = nil
        record = nil
        access = nil
        persistPending = false
        loaded = true
        try? store.delete()
        sessionHint.withLock { $0 = false }
        self.notice = notice
        publish()
    }

    private func publish() {
        let state = currentState
        for continuation in observers.values { continuation.yield(state) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
