// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: accepted VFS logical sizes.
//
// budgets.md §4 and channel.md §3.1/§6/§8: one mutation carries at most
// `WireLimits.maxMutationDataBytes`, so a large file is published as one
// complete write plus appended suffixes. The
// host does not trust the worker's file-size claim; it tracks the logical size
// of every accepted path (the WAL tail plus the materialized copy at boot) and
// refuses a mutation that would grow one file past the configured single-file
// budget. The refusal happens before the WAL append, so the rejected mutation
// never consumes an mseq.
//
// The index deliberately accepts an appended chunk whose `append_from` does not
// match its own size: D8's base-mismatch path owns that decision (the
// materialized copy may lag the accepted WAL, and the worker is authoritative
// while it lives). The cap projection is conservative: the accepted logical
// size is `max(current, append_from + data)`.

import Foundation
import PhoneDSHWire

/// Logical sizes of the accepted `/dsh/home/**` and `/dsh/workspace/**` paths.
struct VfsLogicalIndex {
    private(set) var sizes: [String: Int] = [:]
    /// Largest permitted logical size of one file.
    let singleFileLimitBytes: Int
    /// Prefix/total caps; nil keeps the historical single-file-only policy.
    let quota: VfsQuota?

    /// Bytes of the accepted logical VFS, for diagnostics and tests.
    var totalBytes: Int { sizes.values.reduce(0, +) }

    init(paths: WorkspacePaths,
         materializedUptoMseq: UInt64,
         singleFileLimitBytes: Int,
         quota: VfsQuota? = nil) throws {
        self.singleFileLimitBytes = singleFileLimitBytes
        self.quota = quota
        try seedFromMaterializedCopy(paths: paths)
        try replayWALTail(paths: paths, after: materializedUptoMseq)
    }

    /// Refuses a write that would exceed the per-file budget. Other ops have no
    /// size effect. Throws `LogError.vfsRefused` without touching any state.
    func validate(_ body: VfsMutationBody) throws {
        guard body.op == .write else { return }
        let projected = projectedSize(for: body)
        guard projected <= singleFileLimitBytes else {
            throw LogError.vfsRefused(path: body.path,
                                      limit: singleFileLimitBytes,
                                      projected: projected)
        }
        guard let quota else { return }
        let current = sizes[body.path] ?? 0
        let delta = projected - current
        guard delta > 0 else { return }
        let bucket = VfsQuota.bucket(for: body.path)
        if let limit = quota.limit(for: bucket) {
            let bucketProjected = sum(of: bucket) + delta
            guard bucketProjected <= limit else {
                throw LogError.vfsQuotaExceeded(path: body.path,
                                                bucket: quota.name(for: bucket),
                                                limit: limit,
                                                projected: bucketProjected)
            }
        }
        let totalProjected = totalBytes + delta
        guard totalProjected <= quota.logicalBytes else {
            throw LogError.vfsQuotaExceeded(path: body.path,
                                            bucket: "vfs",
                                            limit: quota.logicalBytes,
                                            projected: totalProjected)
        }
    }

    /// Logical bytes currently held by one prefix.
    func sum(of bucket: VfsQuota.Bucket) -> Int {
        sizes.reduce(0) { partial, entry in
            VfsQuota.bucket(for: entry.key) == bucket ? partial + entry.value : partial
        }
    }

    /// Records the accepted mutation. Call only after the WAL append returned.
    mutating func apply(_ body: VfsMutationBody) {
        switch body.op {
        case .write:
            sizes[body.path] = projectedSize(for: body)
        case .remove:
            removeSubtree(body.path)
        case .mkdir, .chmod:
            break
        }
    }

    // MARK: - Internals

    private func projectedSize(for body: VfsMutationBody) -> Int {
        let current = sizes[body.path] ?? 0
        guard body.mflags.contains(.appended) else { return body.data.count }
        guard body.appendFrom <= UInt64(Int.max),
              body.data.count <= Int.max - Int(body.appendFrom) else {
            return Int.max
        }
        return max(current, Int(body.appendFrom) + body.data.count)
    }

    private mutating func removeSubtree(_ path: String) {
        sizes.removeValue(forKey: path)
        let prefix = path + "/"
        let descendants = sizes.keys.filter { $0.hasPrefix(prefix) }
        for key in descendants {
            sizes.removeValue(forKey: key)
        }
    }

    private mutating func seedFromMaterializedCopy(paths: WorkspacePaths) throws {
        let roots: [(URL, String)] = [
            (paths.materializedHomeDirectory, "/dsh/home"),
            (paths.materializedWorkspaceDirectory, "/dsh/workspace"),
        ]
        for (root, vfsRoot) in roots {
            guard LogFile.exists(root) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []) else { continue }
            for case let entry as URL in enumerator {
                let values = try entry.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                guard let relative = Self.relativePath(of: entry, under: root) else {
                    continue
                }
                sizes[vfsRoot + "/" + relative] = values.fileSize ?? 0
            }
        }
    }

    private mutating func replayWALTail(paths: WorkspacePaths,
                                       after materializedUptoMseq: UInt64) throws {
        let from = materializedUptoMseq == UInt64.max
            ? UInt64.max : materializedUptoMseq + 1
        let records = try WALReader.records(directory: paths.walDirectory, fromMseq: from)
        for record in records {
            guard let body = try? record.mutationBody() else { continue }
            guard WireValidation.isValidMutationPath(body.path) else { continue }
            apply(body)
        }
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
