// SPDX-License-Identifier: MIT
import Foundation
import Network

protocol ADBTransport: Sendable {
    func start() async throws
    func read(count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close()
}

final class ADBTCPTransport: ADBTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "phone-dsh.adb")
    private let lock = NSLock()
    private var startup: CheckedContinuation<Void, Error>?
    private var taskCancelled = false

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func start() async throws {
        try Task.checkCancellation()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock { startup = continuation }
                    connection.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready: self?.finishStart(nil)
                        case .failed(let error): self?.finishStart(Self.connectionFailure(error))
                        case .cancelled:
                            if let self { self.finishStart(self.cancelledStartFailure()) }
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                }
            } onCancel: { self.closeForCancellation() }
        } catch {
            throw Self.networkFailure(error)
        }
    }

    private func finishStart(_ error: Error?) {
        let pending = lock.withLock { let value = startup; startup = nil; return value }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }

    /// The connection can be cancelled by the caller's timeout or by task
    /// cancellation; only the latter is reported as `.cancelled`.
    private func cancelledStartFailure() -> ADBFailure {
        let cancelled = lock.withLock { taskCancelled }
        return ADBFailure("ADB connection cancelled or timed out", kind: cancelled ? .cancelled : .unreachable)
    }

    private static func connectionFailure(_ error: Error) -> ADBFailure {
        if let failure = error as? ADBFailure { return failure }
        return ADBFailure(error.localizedDescription, kind: .unreachable)
    }

    private static func networkFailure(_ error: Error) -> ADBFailure {
        let message = (error as? ADBFailure)?.message ?? error.localizedDescription
        if error is CancellationError || Task.isCancelled {
            return ADBFailure(message, kind: .cancelled)
        }
        if let failure = error as? ADBFailure { return failure }
        return ADBFailure(message, kind: .unreachable)
    }

    private func closeForCancellation() {
        lock.withLock { taskCancelled = true }
        connection.cancel()
    }

    func read(count: Int) async throws -> Data {
        var output = Data()
        while output.count < count {
            try Task.checkCancellation()
            let remaining = count - output.count
            let part: Data
            do {
                part = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                            if let data, !data.isEmpty { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? ADBFailure("ADB connection closed; check authorization and TCP/IP debugging", kind: .unreachable)) }
                        }
                    }
                } onCancel: { self.closeForCancellation() }
            } catch {
                throw Self.networkFailure(error)
            }
            output.append(part)
        }
        return output
    }

    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            } onCancel: { self.closeForCancellation() }
        } catch {
            throw Self.networkFailure(error)
        }
    }

    func close() { connection.cancel() }
}
