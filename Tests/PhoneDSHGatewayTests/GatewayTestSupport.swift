// SPDX-License-Identifier: MIT
// Shared support for the PhoneDSHGateway tests: an injected clock,
// response collection with a hard timeout, temporary workspace roots and
// credential helpers.

import Foundation
import XCTest
import PhoneDSHGateway
import PhoneDSHAgentCore

enum GatewayTestError: Error {
    case timedOut
}

/// Clock whose sleeps are recorded and resolved immediately. Tests assert the
/// retry schedule without waiting in real time.
final class ManualGatewayClock: GatewayClock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "phone-dsh.gateway.test-clock")
    private var current: Date
    private var recorded: [TimeInterval] = []

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    var now: Date {
        queue.sync { current }
    }

    var sleeps: [TimeInterval] {
        queue.sync { recorded }
    }

    func sleep(for seconds: TimeInterval) async throws {
        queue.sync {
            recorded.append(seconds)
            current = current.addingTimeInterval(seconds)
        }
    }
}

struct CollectedGatewayResponse {
    var status: Int?
    var headers: [String: String] = [:]
    var body = Data()
    var chunks: [GatewayResponseChunk] = []
}

private final class GatewayCollectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CollectedGatewayResponse?
    private var error: Error?
    private var timedOut = false

    func finish(_ result: CollectedGatewayResponse) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func outcome() -> (result: CollectedGatewayResponse?, error: Error?, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (result, error, timedOut)
    }
}

/// Drains a gateway response stream, failing after `timeout` seconds.
func collectGatewayResponse(_ stream: AsyncThrowingStream<GatewayResponseChunk, Error>,
                            timeout: TimeInterval = 10) async throws -> CollectedGatewayResponse {
    let box = GatewayCollectionBox()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            var result = CollectedGatewayResponse()
            do {
                for try await chunk in stream {
                    result.chunks.append(chunk)
                    if let status = chunk.status {
                        result.status = status
                        result.headers = chunk.headers
                    }
                    result.body.append(chunk.body)
                }
                box.finish(result)
            } catch {
                box.fail(error)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            box.markTimedOut()
        }
        await group.next()
        group.cancelAll()
    }
    let outcome = box.outcome()
    if outcome.timedOut {
        throw GatewayTestError.timedOut
    }
    if let error = outcome.error {
        throw error
    }
    guard let result = outcome.result else {
        throw GatewayTestError.timedOut
    }
    return result
}

/// Collects a stream and expects it to fail.
func expectGatewayFailure(_ stream: AsyncThrowingStream<GatewayResponseChunk, Error>,
                          timeout: TimeInterval = 10) async throws -> Error {
    do {
        _ = try await collectGatewayResponse(stream, timeout: timeout)
    } catch {
        return error
    }
    throw GatewayTestError.timedOut
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pdsh-gateway-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeBearerProvider(host: String, value: String) -> StaticCredentialProvider {
    StaticCredentialProvider([
        CredentialScope(service: host): Credential(kind: .bearer, value: value),
    ])
}

/// Thread-safe collector for the gateway's bounded response receipts.
final class GatewayReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GatewayResponseReceipt] = []

    init() {}

    func record(_ receipt: GatewayResponseReceipt) {
        lock.lock()
        storage.append(receipt)
        lock.unlock()
    }

    var receipts: [GatewayResponseReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func dispositions() -> [GatewayResponseDisposition] {
        receipts.map(\.disposition)
    }
}

/// RFC 1123 date used by `Retry-After`.
func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.string(from: date)
}

/// Simple thread-safe attempt counter for scripted upstreams.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Every regular file below `directory`, recursively. Used by the response-log
/// secret scan; hidden directories are included so pending/staging leftovers
/// cannot hide a leak.
func regularFiles(under directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files.append(url)
        }
    }
    return files
}

/// Files below `directory` whose raw bytes contain `needle` (UTF-8).
func filesContaining(_ needle: String, under directory: URL) throws -> [URL] {
    let bytes = Data(needle.utf8)
    return try regularFiles(under: directory).filter { url in
        (try? Data(contentsOf: url))?.range(of: bytes) != nil
    }
}

/// Credential provider whose failure message contains a secret. The gateway
/// must never forward it into an error description.
struct SecretBearingCredentialProvider: CredentialProvider {
    let secret: String

    struct Leak: Error, LocalizedError {
        let secret: String
        var errorDescription: String? { "provider rejected with \(secret)" }
    }

    func credential(for scope: CredentialScope) async throws -> Credential {
        throw Leak(secret: secret)
    }

    func invalidate(_ credential: Credential, for scope: CredentialScope) async {}
}

/// Thread-safe string/data box for responses assembled on another queue.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
