// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: tono-account HTTP client and session store.
//
// spec/v1/tono-account.md §2–§3. The transport is a seam so tests drive a
// local fake and never reach account.tonoai.cn (it sends real SMS). The
// production transport follows no redirect and bounds the response body.

import Foundation

/// One HTTP exchange with the account service. Throwing means a transport
/// error (no answer).
public protocol TonoAccountTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer
}

/// `URLSession` transport: ephemeral, no cookies or cache, no redirects.
public final class URLSessionTonoAccountTransport: TonoAccountTransport, @unchecked Sendable {
    public static let maximumBodyBytes = 64 * 1024
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let delegateBox = RedirectRefusal()
        self.session = URLSession(configuration: configuration, delegate: delegateBox, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: URLRequest) async throws -> TonoAccountProtocol.Answer {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= Self.maximumBodyBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return TonoAccountProtocol.Answer(status: http.statusCode, headers: headers, body: data)
    }

    private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // §2: a 3xx is handed back and classified `transient`.
            completionHandler(nil)
        }
    }
}

/// The four account-service operations, classified per §2.
public struct TonoAccountClient: Sendable {
    public let origin: URL
    private let transport: any TonoAccountTransport

    public init(origin: URL = TonoAccountProtocol.accountOrigin, transport: any TonoAccountTransport) {
        self.origin = origin
        self.transport = transport
    }

    public func sendCode(phone: String) async -> TonoAccountProtocol.OTPOutcome {
        TonoAccountProtocol.classifySendCode(
            await exchange(TonoAccountProtocol.sendCodeRequest(phone: phone, origin: origin)))
    }

    public func signIn(phone: String, challengeID: String, code: String,
                       device: TonoAccountProtocol.DeviceInfo) async -> TonoAccountProtocol.LoginOutcome {
        TonoAccountProtocol.classifySignIn(await exchange(TonoAccountProtocol.signInRequest(
            phone: phone, challengeID: challengeID, code: code, device: device, origin: origin)))
    }

    public func refresh(refreshToken: String) async -> TonoAccountProtocol.RefreshOutcome {
        TonoAccountProtocol.classifyRefresh(
            await exchange(TonoAccountProtocol.refreshRequest(refreshToken: refreshToken, origin: origin)))
    }

    /// Best effort; the outcome is ignored by design (§3 sign-out).
    public func signOut(accessToken: String) async {
        _ = await exchange(TonoAccountProtocol.signOutRequest(accessToken: accessToken, origin: origin))
    }

    private func exchange(_ request: URLRequest) async -> TonoAccountProtocol.Answer? {
        try? await transport.send(request)
    }
}

/// The one secret item holding the session record (§3). `save` replaces the
/// item in one write; it never deletes and re-adds.
public protocol TonoAccountSessionStore: Sendable {
    /// The stored bytes, `nil` when absent. Throws when the store cannot be read.
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public enum TonoAccountStoreError: Error, Equatable {
    case keychain(Int32)
    case unavailable
}

/// Keychain item `dev.phone-dsh.tono-account` / `session`,
/// `AfterFirstUnlockThisDeviceOnly`.
public struct KeychainTonoAccountSessionStore: TonoAccountSessionStore {
    public static let defaultService = "dev.phone-dsh.tono-account"
    public static let defaultAccount = "session"
    public let service: String
    public let account: String

    public init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    #if canImport(Security)
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    #endif

    public func load() throws -> Data? {
        #if canImport(Security)
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TonoAccountStoreError.keychain(status)
        }
        return data
        #else
        throw TonoAccountStoreError.unavailable
        #endif
    }

    public func save(_ data: Data) throws {
        #if canImport(Security)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw TonoAccountStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw TonoAccountStoreError.keychain(status)
        }
        #else
        throw TonoAccountStoreError.unavailable
        #endif
    }

    public func delete() throws {
        #if canImport(Security)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TonoAccountStoreError.keychain(status)
        }
        #else
        throw TonoAccountStoreError.unavailable
        #endif
    }
}
