// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — Worker boot phase observability.
//
// The page and the Worker already publish `console.info` lines through the
// existing console pipe; this parser turns the reserved `pdsh-boot-phase`
// shape into one diagnostic line in `boot-timings.log`. No channel frame,
// query parameter or boot field is added: the format is console text only.
//
// Example page line:
//   pdsh-boot-phase scope=page phase=worker-spawn active_ms=42
// Example Worker line (buffered by the entry's console forwarder until HELLO,
// so `active_ms` remains measured in the Worker):
//   pdsh-boot-phase scope=worker phase=channel-connected active_ms=381

import Foundation

/// One page/Worker boot phase from an existing console line.
public struct PhoneDSHBootPhase: Equatable, Sendable {
    /// `page` or `worker`; future producers may use another bounded token.
    public var scope: String
    /// Phase name (`worker-spawn`, `channel-connected`, `host-started`, …).
    public var phase: String
    /// Active (monotonic) milliseconds reported by the producer.
    public var activeMilliseconds: Double
    /// Query-free Worker-side path for the two fetch diagnostics. Nil for every
    /// pre-existing phase.
    public var path: String?
    /// Completed fetch duration for `slow-fetch`. Nil for `fetch-inflight`.
    public var elapsedMilliseconds: Double?

    public init(scope: String, phase: String, activeMilliseconds: Double,
                path: String? = nil, elapsedMilliseconds: Double? = nil) {
        self.scope = scope
        self.phase = phase
        self.activeMilliseconds = max(0, activeMilliseconds)
        self.path = path
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// Parses the reserved console line. Returns nil for every unrelated line
    /// and for a malformed/oversized token, so arbitrary page console output
    /// can never become a boot-phase record.
    public static func parse(_ text: String) -> PhoneDSHBootPhase? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("pdsh-boot-phase ") else { return nil }
        let body = trimmed.dropFirst("pdsh-boot-phase ".count)
        var scope: String?
        var phase: String?
        var active: Double?
        var path: String?
        var elapsed: Double?
        for field in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let equals = field.firstIndex(of: "=") else { return nil }
            let name = field[..<equals]
            let value = field[field.index(after: equals)...]
            switch name {
            case "scope":
                scope = boundedToken(String(value))
            case "phase":
                phase = boundedToken(String(value))
            case "active_ms":
                guard let number = Double(value), number.isFinite, number >= 0 else {
                    return nil
                }
                active = min(number, 24 * 60 * 60 * 1_000)
            case "path":
                guard let token = boundedPath(String(value)) else { return nil }
                path = token
            case "elapsed_ms":
                guard let number = Double(value), number.isFinite, number >= 0 else {
                    return nil
                }
                elapsed = min(number, 24 * 60 * 60 * 1_000)
            default:
                // The reserved line has exactly these fields. A line that
                // carries anything else is not one of our producers, so it
                // must not become a boot-phase record.
                return nil
            }
        }
        guard let scope, let phase, let active else { return nil }
        // Only the two fetch diagnostics may carry the optional path/elapsed
        // fields. Existing phases keep their exact three-field shape.
        if path != nil || elapsed != nil {
            guard phase == "slow-fetch" || phase == "fetch-inflight" else {
                return nil
            }
        }
        if phase == "slow-fetch" {
            guard path != nil, elapsed != nil else { return nil }
        } else if phase == "fetch-inflight" {
            guard path != nil else { return nil }
        }
        return PhoneDSHBootPhase(scope: scope, phase: phase,
                                 activeMilliseconds: active,
                                 path: path,
                                 elapsedMilliseconds: elapsed)
    }

    /// A diagnostic path is bounded, starts at `/`, and cannot carry a query,
    /// fragment, whitespace or control character.
    private static func boundedPath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), raw.count <= 200,
              raw.contains("?") == false, raw.contains("#") == false,
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return raw
    }

    private static func boundedToken(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard raw.isEmpty == false, raw.count <= 48,
              raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return raw
    }
}

/// Buffers the boot's phase lines and appends them to `boot-timings.log` when
/// the boot line is written. The file is the same one the host already owns,
/// so no new artifact is introduced.
final class PhoneDSHBootPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fileURL: URL?
    private var bootID = ""
    private var startedAt = Date()
    private var phases: [PhoneDSHBootPhase] = []
    private var flushScheduled = false

    func begin(bootID: String, workspaceRoot: URL, now: Date = Date()) {
        lock.lock()
        self.fileURL = workspaceRoot.deletingLastPathComponent()
            .appendingPathComponent("boot-timings.log")
        self.bootID = bootID
        self.startedAt = now
        self.phases.removeAll()
        self.flushScheduled = false
        lock.unlock()
    }

    /// Records one parsed phase. The phase is also written immediately, so a
    /// Worker boot that is killed before the boot line still leaves evidence.
    func record(_ phase: PhoneDSHBootPhase, now: Date = Date()) {
        lock.lock()
        let fileURL: URL?
        let bootID: String
        let wall = now.timeIntervalSince(startedAt) * 1_000
        self.phases.append(phase)
        fileURL = self.fileURL
        bootID = self.bootID
        lock.unlock()
        guard let fileURL else { return }
        let line = Self.line(phase: phase, bootID: bootID,
                             wallMilliseconds: wall, timestamp: now)
        Self.append(line, to: fileURL)
    }

    /// Appends one already-formatted diagnostic line (loopback slow request,
    /// gateway upstream). The recorder owns the file URL; the caller never
    /// needs the workspace path. A line is written immediately so a later
    /// boot failure cannot erase it.
    func recordDiagnostic(_ line: String) {
        lock.lock()
        let fileURL = self.fileURL
        lock.unlock()
        guard let fileURL else { return }
        let bounded = line
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        Self.append(bounded + "\n", to: fileURL)
    }

    /// Number of recorded phases (test seam).
    var recordedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return phases.count
    }

    static func line(phase: PhoneDSHBootPhase, bootID: String,
                     wallMilliseconds: Double, timestamp: Date) -> String {
        var line = "worker-phases \(ISO8601DateFormatter().string(from: timestamp)) "
            + "boot=\(bootID) scope=\(phase.scope) phase=\(phase.phase) "
            + "active_ms=\(Int(phase.activeMilliseconds.rounded())) "
            + "wall_ms=\(Int(max(0, wallMilliseconds).rounded()))"
        if let path = phase.path { line += " path=\(path)" }
        if let elapsed = phase.elapsedMilliseconds {
            line += " elapsed_ms=\(Int(max(0, elapsed).rounded()))"
        }
        return line + "\n"
    }

    static func append(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
