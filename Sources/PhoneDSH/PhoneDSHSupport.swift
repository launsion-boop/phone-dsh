// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: adapters and small helpers.
//
// PLAN §2.1/§2.3/§2.5 and W2-FACADE. This file contains the glue the facade
// needs between the landed modules: the WorkspaceLog/journals seams of the
// loopback server, the model-gateway HTTP egress adapter, the default WKWebView
// engine factory and the boot-id helper. Nothing here changes a landed API.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHEngine
import PhoneDSHGateway
import PhoneDSHLog
import PhoneDSHLoopback
import PhoneDSHWire

// MARK: - Boot id

enum PhoneDSHBootID {
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        var text = ""
        text.reserveCapacity(32)
        for byte in bytes {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 0x0F)])
        }
        return text
    }

    static func data(hex: String) -> Data? {
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}

// MARK: - Workspace log seams

/// Adapts ``PhoneDSHLog/WorkspaceLog`` to the small workspace-log seam
/// of the loopback module (PLAN §2.1 keeps that dependency edge out of the
/// loopback target).
struct PhoneDSHWorkspaceLogBridge: LoopbackWorkspaceLog {
    let log: WorkspaceLog

    func append(_ mutation: VfsMutationBody) async throws -> UInt64 {
        try await log.append(mutation)
    }

    func acks() -> AsyncStream<LoopbackWorkspaceAck> {
        let source = log.acks()
        return AsyncStream { continuation in
            let task = Task {
                for await ack in source {
                    continuation.yield(LoopbackWorkspaceAck(level: ack.level.wireLevel,
                                                            uptoMseq: ack.uptoMseq))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func closeEpoch() async throws -> LoopbackWorkspaceAck? {
        let ack = try await log.closeEpoch()
        return LoopbackWorkspaceAck(level: ack.level.wireLevel, uptoMseq: ack.uptoMseq)
    }

    func resyncs() -> AsyncStream<String> {
        log.resyncRequests()
    }
}

/// Adapts the persistent journal of ``WorkspaceLog`` to the loopback seam.
///
/// `ChannelServer` appends a `0x30` record through this seam *before* it calls
/// the channel handler, so the drain's write-frame counter must include this
/// append as well: a journal write is a durable side effect like a VFS sink
/// write (G2-FIX-17).
struct PhoneDSHJournalBridge: LoopbackJournalLog {
    let log: WorkspaceLog
    let coordinator: PhoneDSHChannelCoordinator

    func appendJournal(sessionID: String, jseq: UInt64, record: Data) async throws -> UInt64 {
        await coordinator.inboundWriteStarted()
        do {
            let appended = try await log.journalAppend(
                JournalBody(jseq: jseq, sessionID: sessionID, record: record))
            await coordinator.inboundWriteFinished()
            return appended
        } catch {
            await coordinator.inboundWriteFinished()
            throw error
        }
    }

    func lastJseq(sessionID: String) async -> UInt64 {
        await log.journalLastJseq(sessionID: sessionID)
    }
}

// MARK: - Model gateway egress

/// Bridges ``PhoneDSHGateway/ModelGateway`` onto the loopback
/// `/v1/http` seam. The gateway drops Worker credentials and injects the host
/// credential; the loopback server never sees them.
struct PhoneDSHGatewayEgress: HTTPEgress {
    let gateway: ModelGateway

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let upstream = GatewayRequest(method: request.method,
                                                  url: request.url,
                                                  headers: request.headers,
                                                  body: request.body)
                    for try await chunk in gateway.handle(upstream) {
                        continuation.yield(HTTPEgressChunk(status: chunk.status,
                                                           headers: chunk.headers,
                                                           body: chunk.body,
                                                           isFinal: chunk.isFinal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Engine factory

/// Creates the WKWebView engine the host boots.
///
/// The factory is a parameter of ``PhoneDSHHost`` rather than of the
/// configuration so the App can create the WebEngine on its UI actor, and the
/// tests can inject a deterministic engine that drives an in-process channel
/// client without WebKit.
public typealias PhoneDSHEngineFactory =
    @Sendable (WebEngineConfiguration) async throws -> any WebEngineControlling

extension PhoneDSHHost {
    /// The production factory: creates ``PhoneDSHEngine/WebEngine`` on
    /// the standard UI actor.
    public static let defaultEngineFactory: PhoneDSHEngineFactory = { configuration in
        await Task { @WebEngineUIActor in
            WebEngine(configuration: configuration) as any WebEngineControlling
        }.value
    }
}

// MARK: - Bundle validation

extension PhoneDSHConfiguration {
    /// Checks the bundle and workspace root before the host allocates services.
    func validateForStart(fileManager: FileManager = .default) throws {
        guard let bundle else {
            throw PhoneDSHError.invalidBundle("PhoneDSHConfiguration.bundle is nil")
        }
        guard bundle.exists(fileManager: fileManager) else {
            throw PhoneDSHError.invalidBundle(
                "static www, worker-entry.js, image.tar.gz and lazy/ must exist")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspaceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PhoneDSHError.invalidBundle(
                "the workspace root is not a directory")
        }
        // G2-FIX-12: the turn inactivity threshold is configuration, so an
        // unusable value must fail the start loudly rather than silently
        // disabling (or instantly tripping) the watchdog.
        guard turnInactivityTimeout.isFinite, turnInactivityTimeout > 0 else {
            throw PhoneDSHError.invalidConfiguration(
                "turnInactivityTimeout must be a positive finite number of seconds")
        }
        // A configured remote path must be usable before any local state is
        // opened. A cleartext endpoint, or one whose URL could carry a
        // credential/query into the authority intent, would make the client
        // refuse every handoff only after the local Worker was already drained.
        if let handoff {
            do {
                try handoff.validateEndpoint()
            } catch let error as HandoffError {
                throw PhoneDSHError.invalidConfiguration(error.description)
            } catch {
                throw PhoneDSHError.invalidConfiguration(
                    "handoff.endpoint is invalid")
            }
            guard !handoff.credentialService
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PhoneDSHError.invalidConfiguration(
                    "handoff.credentialService must not be empty")
            }
        }
    }
}
