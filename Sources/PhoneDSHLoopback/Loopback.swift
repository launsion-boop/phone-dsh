// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: one loopback HTTP origin.
//
// PLAN §2.1/§2.2 and spec/v1/channel.md §7–§9. The App hosts a single
// HTTP/1.1 origin on 127.0.0.1 with a random port: static worker assets
// (`Cache-Control: no-store`), the WebSocket upgrade that carries the ordered
// channel, and `/v1/http` egress. WebKit runs the page and Worker from this
// origin, which is why the COOP/COEP headers are part of the fixed
// configuration.
//
// The server never leaves the main actor: everything here is an actor or a
// plain Sendable value, and the transport runs on Network.framework.

import Foundation
import PhoneDSHWire

/// Loopback listener configuration.
public struct LoopbackConfiguration: Equatable, Sendable {
    /// The listener is never bound to a wildcard address.
    public static let loopbackHost = "127.0.0.1"

    /// Always `127.0.0.1`; exposed as an instance property for routing logs.
    public let host: String
    /// 0 requests an ephemeral port; the bound port is reported by the server.
    public var port: UInt16
    /// Bearer token required by the upgrade and by privileged routes.
    ///
    /// An empty token asks `LoopbackServer.start()` to generate a fresh
    /// 128-bit token for every start; a non-empty value pins it (tests only).
    public var token: String
    /// Emit `Cross-Origin-Opener-Policy: same-origin` and
    /// `Cross-Origin-Embedder-Policy: require-corp` on page responses.
    public var crossOriginIsolation: Bool
    /// Largest accepted HTTP request body (PLAN W1: 64 MiB).
    public var maxRequestBodyBytes: Int

    public init(token: String = "", port: UInt16 = 0, crossOriginIsolation: Bool = true,
                maxRequestBodyBytes: Int = 64 * 1024 * 1024) {
        self.host = LoopbackConfiguration.loopbackHost
        self.port = port
        self.token = token
        self.crossOriginIsolation = crossOriginIsolation
        self.maxRequestBodyBytes = maxRequestBodyBytes
    }
}

/// One HTTP request received by the loopback origin.
public struct LoopbackRequest: Equatable, Sendable {
    public var method: String
    /// Path and query string, always starting with `/`.
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// Cache policy of a served resource (PLAN §2.3 boot overlay).
public enum LoopbackCachePolicy: String, CaseIterable, Equatable, Sendable {
    /// Worker code and pages; immutable for one boot.
    case `static`
    /// `lazy/<sha256>.tar.gz` image shards; served with `Cache-Control: no-store`.
    case lazy
    /// Channel-adjacent responses; never stored.
    case noStore
}

/// Where the loopback router sends one request.
public enum LoopbackRoute: Equatable, Sendable {
    case staticAsset(path: String, cache: LoopbackCachePolicy)
    case lazyImage(sha256: String)
    case modelGateway
    case channelUpgrade
    case notFound
}

/// Maps an HTTP request to a handler.
public protocol LoopbackRouting: Sendable {
    func route(_ request: LoopbackRequest) async -> LoopbackRoute
}

/// Channel server callbacks, one method per worker → host frame type
/// (spec/v1/channel.md §2). The server validates `seq` and `mseq`
/// before it calls these methods, so an implementation only persists or runs.
public protocol ChannelHandling: Sendable {
    func handleHello(_ payload: HelloPayload) async throws
    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws
    /// Called after the server accepted an mseq for a structurally valid
    /// mutation; implementations that persist through a workspace log override
    /// this so the log allocation can be checked against the wire mseq.
    func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64, seq: UInt64) async throws
    func handleVFSBarrier(_ body: VfsBarrierBody) async throws
    func handleExecRequest(_ payload: ExecRequestPayload) async throws
    func handleExecControl(_ payload: ExecControlPayload) async throws
    func handleJournal(_ body: JournalBody) async throws
    func handleAPIResponse(_ frame: ApiResponseFrame) async throws
    func handleAPIEnd(_ frame: ApiEndFrame) async throws
    func handleAPIAbort(_ frame: ApiAbortFrame) async throws
    func handleConsole(_ payload: ConsolePayload) async throws
    func handleError(_ payload: ErrorPayload) async throws
}

extension ChannelHandling {
    /// Default for handlers that predate the mseq overload: forward to the
    /// skeleton requirement, which owns persistence.
    public func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64,
                                  seq: UInt64) async throws {
        try await handleVFSMutation(body, seq: seq)
    }
}

/// One outbound HTTP request for the host egress (`/v1/http` upstreams, static
/// assets or the model gateway).
public struct HTTPEgressRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One response chunk: the first chunk carries the status and headers, later
/// chunks carry body bytes only.
public struct HTTPEgressChunk: Equatable, Sendable {
    public var status: Int?
    public var headers: [String: String]
    public var body: Data
    public var isFinal: Bool

    public init(status: Int? = nil, headers: [String: String] = [:], body: Data = Data(),
                isFinal: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.isFinal = isFinal
    }
}

/// Streaming response source used by the loopback server for `/v1/http`.
/// The model gateway implements this protocol (PLAN §2.1); the loopback server
/// never buffers a stream before forwarding its first chunk.
public protocol HTTPEgress: Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error>
}

/// Errors surfaced by the loopback service.
public enum LoopbackError: Error, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case invalidEndpoint(String)
    case channelUnavailable
    case upstreamFailed(String)
    case closed
}

extension LoopbackError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyRunning: return "the loopback server is already running"
        case .notRunning: return "the loopback server is not running"
        case .invalidEndpoint(let detail): return "invalid endpoint: \(detail)"
        case .channelUnavailable: return "no workspace log is configured"
        case .upstreamFailed(let detail): return "upstream failed: \(detail)"
        case .closed: return "the connection is closed"
        }
    }
}
