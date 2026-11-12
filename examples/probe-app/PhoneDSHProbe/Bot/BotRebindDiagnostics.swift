// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore

/// Diagnostic timeline for the Bot runtime/bind and Bot info refresh. It is
/// separate from `BotRuntimeComposition` so the Bot UI capture target (which
/// excludes production composition services) can log the same lines.
@MainActor
enum BotRebindDiagnostics {
    /// Test seam; production appends to the App's existing status log.
    static var sink: ((String) -> Void)?

    @MainActor
    struct Step {
        let name: String
        let attempt: Int
        let started: Date

        func end(ok: Bool = true, error: Error? = nil) {
            let milliseconds = Int(max(0, Date().timeIntervalSince(started)) * 1_000)
            var line = "bot-rebind step=\(name) attempt=\(attempt) ms=\(milliseconds) event=end"
            line += ok ? " ok" : " \(BotRebindDiagnostics.errorToken(error))"
            BotRebindDiagnostics.emit(line)
        }
    }

    static func start(_ name: String, attempt: Int, detail: String = "") -> Step {
        var line = "bot-rebind step=\(name) attempt=\(attempt) event=start"
        if !detail.isEmpty { line += " " + detail }
        emit(line)
        return Step(name: name, attempt: attempt, started: Date())
    }

    /// Runs one awaited stage with paired start/end lines, including the
    /// failure token when it throws.
    static func run<T>(_ name: String, attempt: Int, detail: String = "",
                       _ body: () async throws -> T) async throws -> T {
        let step = start(name, attempt: attempt, detail: detail)
        do {
            let value = try await body()
            step.end()
            return value
        } catch {
            step.end(ok: false, error: error)
            throw error
        }
    }

    static func emit(_ line: String) {
        if let sink {
            sink(line)
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-status.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// A stable, content-free token for a failure. Remote errors keep their
    /// code; anything else keeps only its type name.
    static func errorToken(_ error: Error?) -> String {
        guard let error else { return "error=unknown" }
        if error is CancellationError { return "error=cancelled" }
        if let remote = error as? DSHRemoteError {
            return "error=" + sanitized(remote.code)
        }
        return "error=" + sanitized(String(describing: type(of: error)))
    }

    private static func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let token = raw.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .prefix(48)
        return token.isEmpty ? "unknown" : String(token)
    }
}
