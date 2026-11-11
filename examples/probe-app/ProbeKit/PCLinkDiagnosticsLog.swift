// SPDX-License-Identifier: MIT
// PCLink presence diagnostics (P18, PC-20261110-pclink-workspace-cache).
//
// A phone-side record of the transitions the drawer renders, so a later report
// of "it said the PC was offline" can be answered from the device instead of
// from a reproduction. Only state names, reason names and durations are
// written: no session titles, message text, keys or fingerprints.

import Foundation
import PhoneDSHPCLink

/// One line of the presence log.
public struct PCLinkDiagnosticEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case state
        case notice
        case longOffline
    }

    public var at: Date
    public var kind: Kind
    /// `online`, `reconnecting` or `offline` for a state line.
    public var state: String
    /// The `PCLinkOfflineReason` case name, or the notice name.
    public var reason: String?
    /// Free-form, already redacted context (durations, counts).
    public var detail: String?

    public init(at: Date = Date(), kind: Kind = .state, state: String,
                reason: String? = nil, detail: String? = nil) {
        self.at = at
        self.kind = kind
        self.state = state
        self.reason = reason
        self.detail = detail
    }

    public var line: String {
        var parts = [kind.rawValue, state]
        if let reason { parts.append("reason=\(reason)") }
        if let detail { parts.append(detail) }
        let stamp = ISO8601DateFormatter.pclinkDiagnostic.string(from: at)
        return stamp + " " + parts.joined(separator: " ")
    }
}

extension ISO8601DateFormatter {
    /// Millisecond-precision UTC stamps for the diagnostics file.
    static let pclinkDiagnostic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

extension PCLinkDiagnosticsLog {
    /// Stable case name for an offline reason. A `switch` (not reflection) so a
    /// new reason case is a compile error here instead of an unlabelled line.
    public static func reasonName(_ reason: PCLinkOfflineReason) -> String {
        switch reason {
        case .notStarted: return "not_started"
        case .network: return "network"
        case .peerOffline: return "peer_offline"
        case .replaced: return "replaced"
        case .authenticationFailed: return "authentication_failed"
        case .versionUnsupported: return "version_unsupported"
        case .unpairedPrompt: return "unpaired_prompt"
        case .protocolError: return "protocol_error"
        case .storage: return "storage"
        }
    }
}

/// Append-only, size-bounded log at `Documents/pclink-diag.log`. Rotates once
/// (`pclink-diag.1.log`) so a long session cannot fill the container.
public enum PCLinkDiagnosticsLog {
    public static let fileName = "pclink-diag.log"
    public static let rotatedFileName = "pclink-diag.1.log"
    /// Rotate at 256 KiB; two files cap the log at ~512 KiB.
    public static let maxBytes = 256 * 1024

    public static func url(documentsDirectory: URL? = nil,
                           fileManager: FileManager = .default) -> URL? {
        guard let documents = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent(fileName)
    }

    public static func append(_ event: PCLinkDiagnosticEvent,
                              documentsDirectory: URL? = nil,
                              fileManager: FileManager = .default) {
        guard let target = url(documentsDirectory: documentsDirectory, fileManager: fileManager)
        else { return }
        let text = event.line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let current = (try? fileManager.attributesOfItem(atPath: target.path))?[.size] as? Int ?? 0
        if current + data.count > maxBytes {
            let rotated = target.deletingLastPathComponent()
                .appendingPathComponent(rotatedFileName)
            try? fileManager.removeItem(at: rotated)
            try? fileManager.moveItem(at: target, to: rotated)
        }
        if !fileManager.fileExists(atPath: target.path) {
            try? data.write(to: target, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: target) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Lines currently on disk, oldest first. Used by the support export and by
    /// tests; a missing file is an empty log, not an error.
    public static func read(documentsDirectory: URL? = nil,
                            fileManager: FileManager = .default) -> [String] {
        guard let target = url(documentsDirectory: documentsDirectory, fileManager: fileManager),
              let text = try? String(contentsOf: target, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
