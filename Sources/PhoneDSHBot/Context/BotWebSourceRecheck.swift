// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

// G-1 r5 §4.5: a web/connector source must have a real producer that observes
// the same resource identity again at read/decision time. This file is that
// producer's transport-neutral half:
//
// - it performs one conditional GET (If-None-Match / If-Modified-Since) or a
//   bounded content digest fallback and returns a G-1 `source_version` basis;
// - it never owns a socket. The host injects a transport that uses the
//   existing `/v1/http` gateway / egress path, so existing host allow-list and
//   credential policy are the authorization boundary. GET/HEAD are not Bot
//   egress writes (`ModelGateway.isBotEgressWriteMethod` only covers
//   POST/PUT/PATCH/DELETE), so this producer needs no new egress Grant and
//   presents no approval card;
// - it keeps no body, log line, cookie or credential. Only the revision basis
//   and value leave a call.
//
// Failure vocabulary is frozen by G-1: `refresh-denied`, `refresh-unavailable`,
// `refresh-not-performed`, `no-resource-identity`.

public enum BotWebResourceKind: String, Codable, Sendable, Equatable {
    case webURL = "web-url"
    case connector
}

/// One G-1 source version. `value` carries the basis prefix required by
/// `spec/bot/v2/provenance.md` §2.3 (`etag:`, `last-modified:`, `sha256:`).
public struct BotWebRevision: Codable, Sendable, Equatable {
    public enum Basis: String, Codable, Sendable, Equatable {
        case etag
        case lastModified = "last-modified"
        case contentSHA256 = "content-sha256"
    }

    public var basis: Basis
    public var value: String
    public var observedAtMS: Int64

    public init(basis: Basis, value: String, observedAtMS: Int64) {
        self.basis = basis
        self.value = value
        self.observedAtMS = observedAtMS
    }
}

/// The same resource identity the stored observation used (§2.3). `scope` is
/// metadata for the source-status resolver; it is not a network permission.
public struct BotWebResourceIdentity: Codable, Sendable, Equatable {
    public var kind: BotWebResourceKind
    public var url: String
    public var owner: String?
    public var scope: String?

    public init(kind: BotWebResourceKind, url: String,
                owner: String? = nil, scope: String? = nil) {
        self.kind = kind
        self.url = url
        self.owner = owner
        self.scope = scope
    }
}

public struct BotWebRecheckRequest: Sendable, Equatable {
    public static let defaultTimeoutMilliseconds = 2_000
    public static let maximumTimeoutMilliseconds = 3_000
    public static let defaultMaximumBodyBytes = 1_048_576
    public static let maximumBodyBytes = 2_097_152

    public var resource: BotWebResourceIdentity
    /// The last recorded revision for the same identity, when one exists. Its
    /// basis selects the conditional header and the comparison.
    public var baseline: BotWebRevision?
    public var timeoutMilliseconds: Int
    public var maximumBodyBytes: Int

    public init(resource: BotWebResourceIdentity, baseline: BotWebRevision? = nil,
                timeoutMilliseconds: Int = BotWebRecheckRequest.defaultTimeoutMilliseconds,
                maximumBodyBytes: Int = BotWebRecheckRequest.defaultMaximumBodyBytes) {
        self.resource = resource
        self.baseline = baseline
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumBodyBytes = maximumBodyBytes
    }
}

public enum BotWebRecheckFailure: String, Codable, Sendable, Equatable {
    case refreshDenied = "refresh-denied"
    case refreshUnavailable = "refresh-unavailable"
    case refreshNotPerformed = "refresh-not-performed"
    case noResourceIdentity = "no-resource-identity"
}

public enum BotWebRecheckOutcome: Sendable, Equatable {
    /// First observation, or an observation with no comparable baseline.
    case observed(current: BotWebRevision, previous: BotWebRevision?, httpStatus: Int)
    /// The producer observed the same basis and value as the baseline.
    case unchanged(BotWebRevision)
    /// The producer observed the same basis with a different value.
    case changed(previous: BotWebRevision?, current: BotWebRevision)
    /// The producer observed a different basis; G-1 must report
    /// `revision-basis-mismatch`, never equality/inequality across bases.
    case basisMismatch(previous: BotWebRevision, current: BotWebRevision)
    case denied(BotWebRecheckFailure, httpStatus: Int?)
    case unavailable(BotWebRecheckFailure)
    case notPerformed(BotWebRecheckFailure)
    case cancelled
}

public struct BotWebRecheckHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    /// Only conditional/identity-safe headers. Never credentials or cookies.
    public var headers: [String: String]
    public var timeoutMilliseconds: Int
    public var maximumBodyBytes: Int
    public var followsRedirects: Bool

    public init(method: String, url: URL, headers: [String: String],
                timeoutMilliseconds: Int, maximumBodyBytes: Int,
                followsRedirects: Bool = false) {
        self.method = method
        self.url = url
        self.headers = headers
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumBodyBytes = maximumBodyBytes
        self.followsRedirects = followsRedirects
    }
}

public struct BotWebRecheckHTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Lower-cased header names. The rechecker normalizes them again, so a
    /// transport may also pass the raw dictionary.
    public var headers: [String: String]
    public var body: Data
    /// The transport must not follow redirects; when it can report the final
    /// URL, the rechecker refuses a different identity.
    public var finalURL: URL?

    public init(status: Int, headers: [String: String], body: Data,
                finalURL: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
}

public enum BotWebRecheckTransportError: Error, Sendable, Equatable {
    /// Host/policy refused the request (allow-list, MCP egress gate, grant,
    /// origin policy). The associated code is diagnostic only.
    case denied(code: String)
    /// Network, DNS, TLS, timeout, truncated body or oversized body.
    case unavailable(code: String)
    case invalidResponse
}

/// The host seam. C injects a transport over the existing `/v1/http` gateway
/// (`PhoneDSHGatewayEgress` / `ModelGateway`), so the recheck uses the same
/// allow-list, credential routing and cancellation as every other egress.
/// Without one the source is honestly "not performed".
public protocol BotWebRecheckTransport: Sendable {
    func perform(_ request: BotWebRecheckHTTPRequest) async throws -> BotWebRecheckHTTPResponse
}

public struct UnavailableBotWebRecheckTransport: BotWebRecheckTransport {
    public init() {}
    public func perform(_ request: BotWebRecheckHTTPRequest) async throws -> BotWebRecheckHTTPResponse {
        throw BotWebRecheckTransportError.unavailable(code: "no-provider")
    }
}

public struct BotWebSourceRechecker: Sendable {
    private let transport: any BotWebRecheckTransport
    private let now: @Sendable () -> Int64

    public init(transport: any BotWebRecheckTransport,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.transport = transport
        self.now = now
    }

    public func recheck(_ request: BotWebRecheckRequest) async -> BotWebRecheckOutcome {
        guard let url = Self.normalizedURL(request.resource.url) else {
            return .notPerformed(.noResourceIdentity)
        }
        guard (100...BotWebRecheckRequest.maximumTimeoutMilliseconds)
            .contains(request.timeoutMilliseconds),
              (4_096...BotWebRecheckRequest.maximumBodyBytes)
            .contains(request.maximumBodyBytes) else {
            return .notPerformed(.refreshNotPerformed)
        }
        var headers: [String: String] = [:]
        if let baseline = request.baseline, let conditional = Self.conditionalValue(baseline) {
            switch baseline.basis {
            case .etag: headers["if-none-match"] = conditional
            case .lastModified: headers["if-modified-since"] = conditional
            case .contentSHA256: break
            }
        }
        let httpRequest = BotWebRecheckHTTPRequest(
            method: "GET",
            url: url,
            headers: headers,
            timeoutMilliseconds: request.timeoutMilliseconds,
            maximumBodyBytes: request.maximumBodyBytes,
            followsRedirects: false)
        do {
            let response = try await Self.withDeadline(
                milliseconds: request.timeoutMilliseconds) {
                try await self.transport.perform(httpRequest)
            }
            return Self.classify(response, request: request, url: url, now: now)
        } catch is CancellationError {
            return .cancelled
        } catch let error as BotWebRecheckTransportError {
            switch error {
            case .denied:
                return .denied(.refreshDenied, httpStatus: nil)
            case .unavailable, .invalidResponse:
                return .unavailable(.refreshUnavailable)
            }
        } catch {
            return .unavailable(.refreshUnavailable)
        }
    }

    // MARK: - classification

    private static func classify(_ response: BotWebRecheckHTTPResponse,
                                 request: BotWebRecheckRequest,
                                 url: URL,
                                 now: @Sendable () -> Int64) -> BotWebRecheckOutcome {
        if let finalURL = response.finalURL,
           normalizedURL(finalURL.absoluteString) != url {
            // A redirect changed the resource identity; do not claim freshness.
            return .unavailable(.refreshUnavailable)
        }
        guard response.body.count <= request.maximumBodyBytes else {
            return .unavailable(.refreshUnavailable)
        }
        let headers = Dictionary(response.headers.map { ($0.key.lowercased(), $0.value) },
                                 uniquingKeysWith: { first, _ in first })
        let observedAtMS = now()
        switch response.status {
        case 304:
            guard let baseline = request.baseline else {
                return .unavailable(.refreshUnavailable)
            }
            return .unchanged(BotWebRevision(
                basis: baseline.basis, value: baseline.value, observedAtMS: observedAtMS))
        case 200, 203, 204, 205:
            if let etag = cleanHeader(headers["etag"]), !etag.isEmpty {
                let current = BotWebRevision(
                    basis: .etag, value: prefixed("etag:", etag), observedAtMS: observedAtMS)
                return comparison(current, baseline: request.baseline,
                                  httpStatus: response.status)
            }
            if let lastModified = cleanHeader(headers["last-modified"]), !lastModified.isEmpty {
                let current = BotWebRevision(
                    basis: .lastModified,
                    value: prefixed("last-modified:", lastModified),
                    observedAtMS: observedAtMS)
                return comparison(current, baseline: request.baseline,
                                  httpStatus: response.status)
            }
            let current = BotWebRevision(
                basis: .contentSHA256,
                value: "sha256:" + sha256(response.body),
                observedAtMS: observedAtMS)
            return comparison(current, baseline: request.baseline,
                              httpStatus: response.status)
        case 300...399:
            return .unavailable(.refreshUnavailable)
        case 401, 403, 407, 451:
            return .denied(.refreshDenied, httpStatus: response.status)
        case 404, 410, 408, 425, 429, 500...599:
            return .unavailable(.refreshUnavailable)
        default:
            return .unavailable(.refreshUnavailable)
        }
    }

    private static func comparison(_ current: BotWebRevision,
                                   baseline: BotWebRevision?,
                                   httpStatus: Int) -> BotWebRecheckOutcome {
        guard let baseline else {
            return .observed(current: current, previous: nil, httpStatus: httpStatus)
        }
        guard baseline.basis == current.basis else {
            return .basisMismatch(previous: baseline, current: current)
        }
        if baseline.value == current.value {
            return .unchanged(current)
        }
        return .changed(previous: baseline, current: current)
    }

    private static func conditionalValue(_ revision: BotWebRevision) -> String? {
        switch revision.basis {
        case .etag:
            return stripPrefix("etag:", revision.value)
        case .lastModified:
            return stripPrefix("last-modified:", revision.value)
        case .contentSHA256:
            return nil
        }
    }

    private static func stripPrefix(_ prefix: String, _ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 256 else { return nil }
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        let stripped = String(trimmed.dropFirst(prefix.count))
        return stripped.isEmpty ? nil : stripped
    }

    private static func prefixed(_ prefix: String, _ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix(prefix) ? trimmed : prefix + trimmed
        return String(value.unicodeScalars.prefix(256))
    }

    private static func cleanHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 256,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return trimmed
    }

    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 2_048,
              var components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        guard let url = components.url else { return nil }
        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func withDeadline<T: Sendable>(
        milliseconds: Int,
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds)) * 1_000_000)
                throw BotWebRecheckTimeout.expired
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw BotWebRecheckTimeout.expired
            }
            return first
        }
    }
}

private enum BotWebRecheckTimeout: Error {
    case expired
}
