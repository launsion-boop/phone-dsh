// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: the VFS write-time quota.
//
// budgets.md §4: the VFS caps are logical bytes enforced at write time; a
// write that would push a prefix (or the total) over its cap is a resource
// refusal (ENOSPC) and consumes no mseq. The single-file cap has always been
// enforced; this type adds the prefix and total caps that the design always
// promised.

import Foundation

/// The write-time VFS caps of one device tier (`BudgetTable`).
public struct VfsQuota: Equatable, Sendable {
    /// Total logical bytes of every VFS file.
    public var logicalBytes: Int
    /// `/dsh/workspace/**`.
    public var workspaceBytes: Int
    /// `/dsh/home/sessions/**`.
    public var sessionBytes: Int
    /// `/dsh/tmp/**`.
    public var tmpBytes: Int

    public init(logicalBytes: Int, workspaceBytes: Int, sessionBytes: Int, tmpBytes: Int) {
        self.logicalBytes = max(0, logicalBytes)
        self.workspaceBytes = max(0, workspaceBytes)
        self.sessionBytes = max(0, sessionBytes)
        self.tmpBytes = max(0, tmpBytes)
    }

    public enum Bucket: Equatable, Sendable {
        case workspace
        case sessions
        case tmp
        case other
    }

    public static func bucket(for path: String) -> Bucket {
        if path == "/dsh/workspace" || path.hasPrefix("/dsh/workspace/") { return .workspace }
        if path == "/dsh/home/sessions" || path.hasPrefix("/dsh/home/sessions/") { return .sessions }
        if path == "/dsh/tmp" || path.hasPrefix("/dsh/tmp/") { return .tmp }
        return .other
    }

    public func limit(for bucket: Bucket) -> Int? {
        switch bucket {
        case .workspace: return workspaceBytes
        case .sessions: return sessionBytes
        case .tmp: return tmpBytes
        case .other: return nil
        }
    }

    public func name(for bucket: Bucket) -> String {
        switch bucket {
        case .workspace: return "workspace"
        case .sessions: return "sessions"
        case .tmp: return "tmp"
        case .other: return "vfs"
        }
    }
}
