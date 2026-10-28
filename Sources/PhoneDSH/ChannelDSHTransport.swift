// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: the ordered-channel DSH client.
//
// PLAN §2.2 (D2, D3) and spec/v1/channel.md §3.7–§3.10. This is the
// App-side `DSHRemoteTransport`: unary calls become one `0x40 API_REQ` and a
// streamed `0x41 API_RES` / `0x42 API_END` / `0x43 API_ABORT` response. The DSH
// API envelope (`client-request` / `server-response`) is the same one
// `PhoneDSHAgentCore.DSHWebTransport` speaks over HTTP, so `DSHRemoteHarness`
// needs no change.
//
// The `/api/remote.mux` WebSocket is represented as a pair of channel API
// requests with explicit headers (``PhoneDSHMuxProtocol``):
//
//   POST /api/remote.mux
//   x-pdsh-mux-id: <32 lowercase hex>
//   x-pdsh-mux-op: send | receive | close
//
// `send` carries one canonical JSON mux frame as the request body; the Worker
// bridge answers 2xx. `receive` is a long-lived request whose body chunks are
// newline-delimited canonical JSON mux frames; it ends when the mux closes or
// the channel connection dies. The Worker entry bridges these three operations
// to its in-process `/api/remote.mux` server (D23); the header/path contract
// above is the whole interface between the two sides.
//
// D22: requests over the ordered channel are authenticated by the channel
// bearer the host validated when it accepted the WebSocket upgrade. No cookie
// exchange happens over the channel, and this transport never adds a
// launch-token or Cookie header; the page cookie is a loopback HTTP concern
// only.
//
// D2: no request is replayed by the host. When a connection dies, the
// initiator re-issues every in-flight unary request with a fresh `req_id` on
// the next connection. ``call`` and the mux `send` implement that retry; the
// stream owner (`DSHRemoteHarness`) reopens a mux after `receive` returns nil.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHLoopback
import PhoneDSHWire

/// Header and path contract between ``ChannelDSHTransport`` and the Worker's
/// remote.mux bridge.
public enum PhoneDSHMuxProtocol {
    /// The DSH stream mux path (stream-protocol.ts `REMOTE_STREAM_MUX_PATH`).
    public static let path = "/api/remote.mux"
    /// 32 lowercase hex characters; one logical mux session per connection.
    public static let muxIDHeader = "x-pdsh-mux-id"
    /// `send`, `receive` or `close`.
    public static let operationHeader = "x-pdsh-mux-op"
    /// Operation value: the body is one canonical JSON mux frame to deliver
    /// to the Worker's `/api/remote.mux` server.
    public static let sendOperation = "send"
    /// Operation value: a long-lived request whose body chunks are
    /// newline-delimited canonical JSON mux frames.
    public static let receiveOperation = "receive"
    /// Operation value: closes the logical mux session.
    public static let closeOperation = "close"
    /// `Content-Type` header name used by the mux requests.
    public static let contentTypeHeader = "content-type"
    /// `Content-Type` of one canonical JSON mux frame (`send`/`close`).
    public static let jsonContentType = "application/json"
    /// `Content-Type` of the newline-delimited mux stream (`receive`).
    public static let ndjsonContentType = "application/x-ndjson"

    /// A fresh 128-bit mux identifier.
    public static func makeMuxID() -> String {
        PhoneDSHBootID.make()
    }
}

/// The `DSHRemoteTransport` over the ordered channel.
public actor ChannelDSHTransport: DSHRemoteTransport {
    /// Retry and framing policy.
    public struct Configuration: Equatable, Sendable {
        /// How long a request waits for the next channel connection.
        public var connectTimeout: TimeInterval
        /// Attempts per unary request, including the first one.
        public var maximumAttempts: Int
        /// Response header carrying the mux content type.
        public var receiveContentType: String

        /// Creates the retry/framing policy.
        ///
        /// - Parameters:
        ///   - connectTimeout: How long a request waits for a channel.
        ///   - maximumAttempts: Attempts per unary request, first included.
        ///   - receiveContentType: Expected `receive` stream content type.
        public init(connectTimeout: TimeInterval = 10,
                    maximumAttempts: Int = 3,
                    receiveContentType: String = PhoneDSHMuxProtocol.ndjsonContentType) {
            self.connectTimeout = max(0.1, connectTimeout)
            self.maximumAttempts = max(1, maximumAttempts)
            self.receiveContentType = receiveContentType
        }
    }

    struct HTTPResult {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    /// Internal signal: the connection died before the response completed.
    private struct ChannelClosed: Error {}

    private let channelProvider: PhoneDSHChannelProvider
    /// Retry and framing policy in force for this transport.
    public let configuration: Configuration

    /// Creates the transport over a channel provider.
    ///
    /// - Parameter channelProvider: Waits for the current ordered channel and
    ///   receives the ids of already-dead connections to skip.
    public init(channelProvider: @escaping PhoneDSHChannelProvider,
                configuration: Configuration = Configuration()) {
        self.channelProvider = channelProvider
        self.configuration = configuration
    }

    // MARK: - DSHRemoteTransport

    public func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        let rpcID = UUID().uuidString.lowercased()
        let envelope = JSONValue.object([
            "type": .string("client-request"),
            "rpcId": .string(rpcID),
            "method": .string(endpoint),
            "payload": .object(["args": args]),
        ])
        let body: Data
        do {
            body = try envelope.encoded()
        } catch {
            throw PhoneDSHError.invalidResponse("cannot encode the client-request envelope")
        }
        let head = ApiRequestHead(method: "POST", path: "/api/" + endpoint,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHMuxProtocol.jsonContentType,
                                    "accept": PhoneDSHMuxProtocol.jsonContentType,
                                  ])
        let result = try await sendWithReconnect(head: head, body: body)
        switch result.status {
        case 200:
            return try Self.unwrap(result.body, rpcID: rpcID)
        case 401:
            await authenticationFailed()
            throw ProviderError.unauthorized("the Worker rejected the remote API request")
        case 403:
            throw ProviderError.unauthorized("the Worker refused the remote API request")
        case 413:
            throw ProviderError.invalidRequest("remote API request body is too large")
        default:
            let message = String(decoding: result.body.prefix(256), as: UTF8.self)
            throw DSHRemoteError(code: "gateway/http-\(result.status)",
                                 message: message.isEmpty ? "HTTP \(result.status)" : message)
        }
    }

    /// Opens one stored session for writing so the Worker's phone persistence
    /// wrapper runs DSH's tool-journal reconcile, then closes the handle.
    ///
    /// This is the production recovery entry: `session/follow` and
    /// `session/page` only read history and never open the writer, so they
    /// cannot settle a journal `start` into a terminal record. The route is
    /// authenticated by the ordered channel exactly like every other call.
    public func reconcileSessionForRecovery(_ sessionID: String) async throws {
        try await reconcileSessionForRecovery(sessionID, budget: .standard)
    }

    /// The budgeted production entry. `timeoutMs` is a private extension to
    /// the phone-only recovery body; the surface clamps it and aborts the real
    /// open/reconcile/ack wait at that deadline, closing the writer before it
    /// answers. A non-200 answer is always a failure, never a claimed close.
    public func reconcileSessionForRecovery(_ sessionID: String,
                                            budget: PhoneDSHRecoveryBudget) async throws {
        let body = try JSONValue.object([
            "sessionId": .string(sessionID),
            "timeoutMs": .number(Double(budget.timeoutMilliseconds)),
        ]).encoded()
        let head = ApiRequestHead(method: "POST", path: PhoneDSHRecoveryProtocol.path,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHRecoveryProtocol.contentType,
                                    "accept": PhoneDSHRecoveryProtocol.contentType,
                                  ])
        let result = try await sendWithReconnect(head: head, body: body)
        switch result.status {
        case 200:
            return
        case 404:
            throw DSHRemoteError(code: "recovery/session-not-found",
                                 message: "the Worker has no stored session to reconcile")
        case 409:
            throw DSHRemoteError(code: "recovery/session-writer-held",
                                 message: "another owner holds the session write handle")
        case 504:
            throw DSHRemoteError(code: "recovery/timeout",
                                 message: "the Worker released the writer at its recovery deadline")
        default:
            let message = String(decoding: result.body.prefix(256), as: UTF8.self)
            throw DSHRemoteError(code: "gateway/http-\(result.status)",
                                 message: message.isEmpty ? "HTTP \(result.status)" : message)
        }
    }

    /// Resumes one stored session through DSH's own crash-recovery path.
    ///
    /// The route runs only the durable first phase of the pinned
    /// `AgentLoop.resume`: it opens the stored session, reads it, appends the
    /// `interrupted` tail closers and closes the writer. It does not create,
    /// publish or dispose an Agent, and it never prompts the model. This is the
    /// only production entry that closes an interrupted turn after the old
    /// Worker (which owned the live Agent) was terminated; the caller still
    /// verifies the materialized DSH journal itself.
    public func resumeSessionForRecovery(_ sessionID: String) async throws {
        try await resumeSessionForRecovery(sessionID, budget: .resumeDefault)
    }

    /// The budgeted resume/repair entry. A non-200 answer is a failure, never a
    /// claimed terminal turn; the caller still verifies the materialized DSH
    /// journal itself.
    public func resumeSessionForRecovery(_ sessionID: String,
                                         budget: PhoneDSHRecoveryBudget) async throws {
        let body = try JSONValue.object([
            "sessionId": .string(sessionID),
            "timeoutMs": .number(Double(budget.timeoutMilliseconds)),
        ]).encoded()
        let head = ApiRequestHead(method: "POST", path: PhoneDSHRecoveryProtocol.resumePath,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHRecoveryProtocol.contentType,
                                    "accept": PhoneDSHRecoveryProtocol.contentType,
                                  ])
        let result = try await sendWithReconnect(head: head, body: body)
        switch result.status {
        case 200:
            return
        case 404:
            throw DSHRemoteError(code: "recovery/session-not-found",
                                 message: "the Worker has no stored session to repair")
        case 409:
            throw DSHRemoteError(code: "recovery/session-writer-held",
                                 message: "another owner holds the session writer during repair")
        case 504:
            throw DSHRemoteError(code: "recovery/timeout",
                                 message: "the Worker did not finish the DSH repair at its deadline")
        default:
            let message = String(decoding: result.body.prefix(256), as: UTF8.self)
            throw DSHRemoteError(code: "gateway/http-\(result.status)",
                                 message: message.isEmpty ? "HTTP \(result.status)" : message)
        }
    }

    public func openMux() async throws -> any DSHMuxConnection {
        let channel: any PhoneDSHChannel
        do {
            channel = try await channelProvider([])
        } catch {
            throw ProviderError.unavailable(retryAfter: nil)
        }
        return ChannelDSHMuxConnection(transport: self,
                                       channelID: channel.id,
                                       muxID: PhoneDSHMuxProtocol.makeMuxID())
    }

    /// D22: the ordered channel authenticates by the bearer validated at the
    /// WebSocket upgrade; there is no launch-token cookie to clear here.
    /// Authentication failures are reported by the response status code and
    /// nothing is cached.
    public func authenticationFailed() async {}

    // MARK: - Unary requests

    func sendWithReconnect(head: ApiRequestHead, body: Data) async throws -> HTTPResult {
        var excluded: Set<UUID> = []
        for _ in 0..<configuration.maximumAttempts {
            let channel: any PhoneDSHChannel
            do {
                channel = try await channelProvider(excluded)
            } catch {
                throw error
            }
            do {
                return try await collect(channel: channel, head: head, body: body)
            } catch is ChannelClosed {
                excluded.insert(channel.id)
                continue
            } catch {
                throw error
            }
        }
        throw PhoneDSHError.channelUnavailable
    }

    private func collect(channel: any PhoneDSHChannel, head: ApiRequestHead,
                         body: Data) async throws -> HTTPResult {
        let stream: AsyncStream<ChannelAPIEvent>
        do {
            stream = try await channel.sendAPIRequest(head: head, body: body)
        } catch {
            throw ChannelClosed()
        }
        var status: Int?
        var headers: [String: String] = [:]
        var responseBody = Data()
        var ended = false
        for await event in stream {
            switch event {
            case .response(_, let chunkStatus, let chunkHeaders, let chunkBody):
                if let chunkStatus {
                    status = chunkStatus
                    headers = chunkHeaders
                }
                responseBody.append(chunkBody)
            case .end:
                ended = true
            case .abort(_, let reason):
                if reason == "connection_closed" { throw ChannelClosed() }
                throw DSHRemoteError(code: "gateway/aborted", message: reason)
            }
            if ended { break }
        }
        guard ended, let status else { throw ChannelClosed() }
        return HTTPResult(status: status, headers: headers, body: responseBody)
    }

    static func unwrap(_ data: Data, rpcID: String) throws -> JSONValue {
        guard let envelope = try? JSONValue.parse(data),
              envelope["type"]?.stringValue == "server-response" else {
            throw PhoneDSHError.invalidResponse("not a server-response envelope")
        }
        guard envelope["rpcId"]?.stringValue == rpcID else {
            throw PhoneDSHError.invalidResponse("rpcId mismatch")
        }
        guard let result = envelope["result"] else {
            throw PhoneDSHError.invalidResponse("the envelope has no result")
        }
        if result["ok"]?.boolValue == true {
            return result["value"] ?? .null
        }
        throw DSHRemoteError(code: result["error"]?["code"]?.stringValue ?? "unknown",
                             message: result["error"]?["message"]?.stringValue ?? "")
    }

    // MARK: - Mux requests (called by the mux connection)

    func muxSend(muxID: String, frame: JSONValue,
                 excluding: Set<UUID>) async throws -> UUID {
        let body: Data
        do {
            body = try frame.encoded()
        } catch {
            throw PhoneDSHError.invalidResponse("cannot encode a mux frame")
        }
        let head = ApiRequestHead(method: "POST", path: PhoneDSHMuxProtocol.path,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHMuxProtocol.jsonContentType,
                                    PhoneDSHMuxProtocol.muxIDHeader: muxID,
                                    PhoneDSHMuxProtocol.operationHeader:
                                        PhoneDSHMuxProtocol.sendOperation,
                                  ])
        var excluded = excluding
        for _ in 0..<configuration.maximumAttempts {
            let channel = try await channelProvider(excluded)
            do {
                let result = try await collect(channel: channel, head: head, body: body)
                guard (200...299).contains(result.status) else {
                    throw DSHRemoteError(code: "gateway/mux-\(result.status)",
                                         message: "the mux bridge rejected a send")
                }
                return channel.id
            } catch is ChannelClosed {
                excluded.insert(channel.id)
                continue
            }
        }
        throw PhoneDSHError.channelUnavailable
    }

    func muxReceiveStream(muxID: String,
                          excluding: Set<UUID>) async throws -> (UUID, AsyncStream<ChannelAPIEvent>) {
        let head = ApiRequestHead(method: "POST", path: PhoneDSHMuxProtocol.path,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHMuxProtocol.ndjsonContentType,
                                    PhoneDSHMuxProtocol.muxIDHeader: muxID,
                                    PhoneDSHMuxProtocol.operationHeader:
                                        PhoneDSHMuxProtocol.receiveOperation,
                                  ])
        var excluded = excluding
        var lastError: Error?
        for _ in 0..<configuration.maximumAttempts {
            let channel = try await channelProvider(excluded)
            do {
                let stream = try await channel.sendAPIRequest(head: head, body: Data())
                return (channel.id, stream)
            } catch {
                excluded.insert(channel.id)
                lastError = error
                continue
            }
        }
        if let lastError { throw lastError }
        throw PhoneDSHError.channelUnavailable
    }

    func muxClose(muxID: String, excluding: Set<UUID>) async {
        let head = ApiRequestHead(method: "POST", path: PhoneDSHMuxProtocol.path,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHMuxProtocol.jsonContentType,
                                    PhoneDSHMuxProtocol.muxIDHeader: muxID,
                                    PhoneDSHMuxProtocol.operationHeader:
                                        PhoneDSHMuxProtocol.closeOperation,
                                  ])
        let provider = channelProvider
        Task {
            guard let channel = try? await provider(excluding) else { return }
            guard let stream = try? await channel.sendAPIRequest(head: head, body: Data()) else {
                return
            }
            for await _ in stream {}
        }
    }
}

// MARK: - Mux connection

/// One logical `/api/remote.mux` session over the ordered channel.
actor ChannelDSHMuxConnection: DSHMuxConnection {
    private let transport: ChannelDSHTransport
    private let muxID: String
    private var connectionID: UUID?
    private var iterator: AsyncStream<ChannelAPIEvent>.Iterator?
    private var receiveBuffer = Data()
    private var queued: [JSONValue] = []
    private var headReceived = false
    private var ended = false
    private var closed = false
    private var receiving = false

    init(transport: ChannelDSHTransport, channelID: UUID, muxID: String) {
        self.transport = transport
        self.connectionID = channelID
        self.muxID = muxID
    }

    func send(_ frame: JSONValue) async throws {
        guard !closed else { throw ProviderError.cancelled }
        connectionID = try await transport.muxSend(muxID: muxID, frame: frame,
                                                   excluding: [])
    }

    func receive() async throws -> JSONValue? {
        if let frame = queued.first {
            queued.removeFirst()
            return frame
        }
        if let frame = try takeFrame() { return frame }
        if ended { return nil }
        guard !receiving else {
            throw DSHRemoteError(code: "gateway/concurrent-receive",
                                 message: "receive() is already in flight")
        }
        receiving = true
        defer { receiving = false }
        if iterator == nil {
            let (id, stream) = try await transport.muxReceiveStream(muxID: muxID,
                                                                    excluding: [])
            connectionID = id
            iterator = stream.makeAsyncIterator()
        }
        while true {
            guard var current = iterator else { return nil }
            let event = await current.next()
            iterator = current
            guard let event else {
                ended = true
                return nil
            }
            switch event {
            case .response(_, let status, _, let body):
                if let status, headReceived == false {
                    headReceived = true
                    guard (200...299).contains(status) else {
                        ended = true
                        throw DSHRemoteError(code: "gateway/mux-\(status)",
                                             message: "the mux bridge rejected the receive")
                    }
                }
                receiveBuffer.append(body)
                if let frame = try takeFrame() { return frame }
            case .end:
                ended = true
                if let frame = try takeFrame() { return frame }
                return nil
            case .abort(_, let reason):
                ended = true
                if reason == "connection_closed" { return nil }
                throw DSHRemoteError(code: "gateway/aborted", message: reason)
            }
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        ended = true
        await transport.muxClose(muxID: muxID, excluding: [])
    }

    private func takeFrame() throws -> JSONValue? {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[receiveBuffer.startIndex..<newline]
            receiveBuffer = Data(receiveBuffer[receiveBuffer.index(after: newline)...])
            guard line.isEmpty == false else { continue }
            do {
                return try JSONValue.parse(Data(line))
            } catch {
                throw PhoneDSHError.invalidResponse("malformed mux frame")
            }
        }
        return nil
    }
}
