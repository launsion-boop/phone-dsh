// SPDX-License-Identifier: MIT

import Foundation

public actor BotVolatileContextProducer {
    public static let defaultTimeout: TimeInterval = 5

    private let provider: any BotVolatileContextProviding
    private let timeout: TimeInterval
    private var revision = 0

    public init(provider: any BotVolatileContextProviding, timeout: TimeInterval = BotVolatileContextProducer.defaultTimeout) {
        self.provider = provider
        self.timeout = max(0.001, timeout)
    }

    public func snapshot(request: BotJSONValue, principal: BotGatewayPrincipal) async throws -> BotVolatileSnapshot {
        guard case .object(let object) = request,
              Set(object.keys) == Set(["sessionId"]),
              case .string(let sessionId)? = object["sessionId"],
              !sessionId.isEmpty, sessionId.unicodeScalars.count <= 200 else {
            throw BotMCPError.invalidRequest("BotVolatileContext requires only sessionId (1–200 characters)")
        }
        guard sessionId == principal.sessionId else { throw BotMCPError.crossSessionDenied }
        revision += 1
        let currentRevision = revision
        let blocks = try await withTimeout {
            try await self.provider.snapshot(botId: principal.botId, sessionId: sessionId, kind: principal.kind)
        }
        try Self.validate(blocks: blocks)
        return BotVolatileSnapshot(sessionId: sessionId, revision: currentRevision, blocks: blocks)
    }

    private func withTimeout(_ operation: @escaping @Sendable () async throws -> BotVolatileBlocks) async throws -> BotVolatileBlocks {
        let task = Task { try await operation() }
        let timeoutTask = Task { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = BotVolatileTimeoutGate(continuation: continuation, operation: task)
            Task {
                try? await timeoutTask.value
                await gate.timeout()
            }
            Task {
                do {
                    try await gate.finish(try await task.value)
                } catch {
                    await gate.fail(error)
                }
            }
        }
    }

    private static func validate(blocks: BotVolatileBlocks) throws {
        var total = 0
        for (text, limit) in [
            (blocks.variant, 12_000), (blocks.persona, 12_000),
            (blocks.memory, 4_000), (blocks.automation, 4_000),
        ] {
            guard let text else { continue }
            let count = text.unicodeScalars.count
            guard count <= limit else { throw BotMCPError.unavailable("volatile context block exceeds its size limit") }
            total += count
            if containsSecret(text) { throw BotMCPError.unavailable("volatile context contains credential-shaped data") }
        }
        guard total <= 24_000 else { throw BotMCPError.unavailable("volatile context exceeds its total size limit") }
    }

    private static func containsSecret(_ text: String) -> Bool {
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"\bsk-[A-Za-z0-9][A-Za-z0-9_-]{14,}\b"#,
            #"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#,
            #"(?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)\s*[:=]\s*[^\s]{4,}"#,
            #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}

private final class BotVolatileTimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<BotVolatileBlocks, Error>?
    private let operation: Task<BotVolatileBlocks, Error>

    init(continuation: CheckedContinuation<BotVolatileBlocks, Error>, operation: Task<BotVolatileBlocks, Error>) {
        self.continuation = continuation
        self.operation = operation
    }

    func finish(_ value: BotVolatileBlocks) {
        resume { $0.resume(returning: value) }
    }

    func fail(_ error: Error) {
        resume { $0.resume(throwing: error) }
    }

    func timeout() {
        operation.cancel()
        resume { $0.resume(throwing: BotMCPError.timeout) }
    }

    private func resume(_ body: (CheckedContinuation<BotVolatileBlocks, Error>) -> Void) {
        let next = lock.withLock { () -> CheckedContinuation<BotVolatileBlocks, Error>? in
            let next = continuation
            continuation = nil
            return next
        }
        if let next { body(next) }
    }
}
