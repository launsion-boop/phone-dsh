// SPDX-License-Identifier: MIT
// Line-oriented byte transport for IMAP and SMTP. Production is an
// implicit-TLS `NWConnection` (IMAPS 993, SMTPS 465); tests script it.

import Foundation
import Network

public enum MailError: Error, LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case timeout
    case closed
    case authenticationFailed(String)
    case protocolError(String)
    case messageTooLarge(Int)
    case notFound
    case invalidArguments(String)
    case store

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail): return "无法连接邮件服务器：\(detail)"
        case .timeout: return "邮件服务器响应超时。"
        case .closed: return "邮件服务器关闭了连接。"
        case .authenticationFailed(let detail):
            return "登录失败：\(detail)。请确认邮箱地址和客户端授权码，并已在邮箱网页设置里开启 IMAP/SMTP 服务。"
        case .protocolError(let detail): return "邮件服务器返回错误：\(detail)"
        case .messageTooLarge(let size): return "邮件过大（\(size) 字节），无法读取。"
        case .notFound: return "找不到这封邮件。"
        case .invalidArguments(let detail): return "参数无效：\(detail)"
        case .store: return "无法读取或保存邮箱账号。请解锁设备后重试。"
        }
    }
}

public protocol MailLineTransport: Sendable {
    func send(_ data: Data) async throws
    /// One line without its CRLF.
    func readLine() async throws -> Data
    func read(count: Int) async throws -> Data
    func close() async
}

public protocol MailTransportFactory: Sendable {
    func connect(host: String, port: Int) async throws -> any MailLineTransport
}

public struct TLSMailTransportFactory: MailTransportFactory {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 30) { self.timeout = timeout }

    public func connect(host: String, port: Int) async throws -> any MailLineTransport {
        try await TLSMailTransport.open(host: host, port: port, timeout: timeout)
    }
}

/// Implicit TLS over Network.framework with a small read buffer.
public actor TLSMailTransport: MailLineTransport {
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var buffer = Data()
    /// A line longer than this is a protocol violation, not a message body.
    static let maxLine = 1 << 20

    private init(connection: NWConnection, timeout: TimeInterval) {
        self.connection = connection
        self.timeout = timeout
    }

    static func open(host: String, port: Int, timeout: TimeInterval) async throws -> TLSMailTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw MailError.connectionFailed("invalid port")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls)
        let transport = TLSMailTransport(connection: connection, timeout: timeout)
        try await transport.start()
        return transport
    }

    private func start() async throws {
        let once = ResumeOnce()
        try await withDeadline(timeout, onTimeout: { [connection] in connection.cancel() }) { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed(let error): once.run { continuation.resume(throwing: MailError.connectionFailed(error.localizedDescription)) }
                    case .waiting(let error): once.run { continuation.resume(throwing: MailError.connectionFailed(error.localizedDescription)) }
                    case .cancelled: once.run { continuation.resume(throwing: MailError.closed) }
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    public func send(_ data: Data) async throws {
        try await withDeadline(timeout, onTimeout: { [connection] in connection.cancel() }) { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: MailError.connectionFailed(error.localizedDescription)) }
                    else { continuation.resume() }
                })
            }
        }
    }

    public func readLine() async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[buffer.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            guard buffer.count < Self.maxLine else { throw MailError.protocolError("line too long") }
            try await fill()
        }
    }

    public func read(count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let chunk = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return chunk
    }

    public func close() async {
        connection.cancel()
    }

    private func fill() async throws {
        let chunk: Data = try await withDeadline(timeout, onTimeout: { [connection] in connection.cancel() }) { [connection] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: MailError.connectionFailed(error.localizedDescription)); return }
                    if let data, !data.isEmpty { continuation.resume(returning: data); return }
                    continuation.resume(throwing: MailError.closed)
                }
            }
        }
        buffer.append(chunk)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Run `operation` with a deadline. A continuation-based operation cannot be
/// cancelled cooperatively, so `onTimeout` must make it finish (for a
/// connection: cancel it, which fails every pending callback).
func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                               onTimeout: @escaping @Sendable () -> Void = {},
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw MailError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
