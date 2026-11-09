// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: `RelayDSHTransport: DSHRemoteTransport` over one PCLink
// end-to-end session (§6, §7, §9.2). It does not reuse the direct-loopback
// cookie/401/403 seam of `DSHWebTransport`.

import Foundation
import PhoneDSHAgentCore

/// Explicit Swift error for §7 `unsafe` outcomes: the call may have executed
/// but no definitive reply arrived. It is never retried by this transport.
public struct PCLinkUnknownOutcome: Error, Equatable, Sendable, LocalizedError {
    public var endpoint: String
    public var code: String { "unknown_outcome" }

    public init(endpoint: String) {
        self.endpoint = endpoint
    }

    public var errorDescription: String? {
        "[unknown_outcome] \(endpoint) may have executed but no definitive reply arrived; re-read state before retrying"
    }
}

public final class RelayDSHTransport: DSHRemoteTransport, @unchecked Sendable {
    // @unchecked: the only stored state is an immutable reference to the
    // `PCLinkClient` actor.
    public let client: PCLinkClient

    public init(client: PCLinkClient) {
        self.client = client
    }

    public func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        do {
            let result = try await client.rpcCall(endpoint: endpoint, args: PCLinkJSON(args))
            return result.jsonValue
        } catch let error as PCLinkRPCError {
            // DSH endpoint errors keep their own namespace and map through the
            // existing DSHRemoteError branches (§9.1).
            throw error.dshRemoteError
        } catch let error as PCLinkError {
            if case .unknownOutcome = error {
                throw PCLinkUnknownOutcome(endpoint: endpoint)
            }
            throw PCLinkErrorMapping.providerError(for: error)
        } catch let lost as PCLinkSessionLost {
            throw PCLinkErrorMapping.providerError(for: lost.reason)
        } catch let outcome as PCLinkUnknownOutcome {
            throw outcome
        }
    }

    public func openMux() async throws -> any DSHMuxConnection {
        do {
            let endpoint = try await client.openMux()
            return RelayDSHMuxConnection(client: client, endpoint: endpoint)
        } catch let error as PCLinkError {
            throw PCLinkErrorMapping.providerError(for: error)
        } catch let lost as PCLinkSessionLost {
            throw PCLinkErrorMapping.providerError(for: lost.reason)
        }
    }

    /// No cookie, launch token, `Host`/`Origin` fence or 401 refresh exists on
    /// the relay path. `ProviderError.unauthorized` is never produced for a
    /// pairing state; this seam is a no-op (§9.2, P0 spike Q5).
    public func authenticationFailed() async {}
}

public actor RelayDSHMuxConnection: DSHMuxConnection {
    private let client: PCLinkClient
    private let id: UUID
    private var iterator: AsyncStream<PCLinkJSON>.Iterator
    private var closed = false
    private var receiving = false

    init(client: PCLinkClient, endpoint: PCLinkMuxEndpoint) {
        self.client = client
        self.id = endpoint.id
        self.iterator = endpoint.frames.makeAsyncIterator()
    }

    public func send(_ frame: JSONValue) async throws {
        guard !closed else { throw ProviderError.cancelled }
        do {
            try await client.muxSend(id: id, frame: PCLinkJSON(frame))
        } catch let error as PCLinkError {
            if case .unknownOutcome = error {
                throw PCLinkUnknownOutcome(endpoint: frame["endpoint"]?.stringValue ?? "stream")
            }
            throw PCLinkErrorMapping.providerError(for: error)
        } catch let lost as PCLinkSessionLost {
            throw PCLinkErrorMapping.providerError(for: lost.reason)
        }
    }

    public func receive() async throws -> JSONValue? {
        if closed { return nil }
        guard !receiving else {
            throw ProviderError.invalidResponse("concurrent mux receive()")
        }
        receiving = true
        defer { receiving = false }
        var iterator = self.iterator
        let frame = await iterator.next()
        self.iterator = iterator
        guard let frame else {
            closed = true
            return nil
        }
        return frame.jsonValue
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await client.closeMux(id: id)
    }
}

public extension PCLinkClient {
    /// The DSH Remote adapter over this client. All calls and muxes share the
    /// one E2E session (so `$events` and `$events/result` use the same owner
    /// Peer on the PC, §6.1).
    nonisolated func makeTransport() -> RelayDSHTransport {
        RelayDSHTransport(client: self)
    }

    /// Convenience alias for the current DSH Remote adapter.
    nonisolated var transport: RelayDSHTransport {
        RelayDSHTransport(client: self)
    }
}
