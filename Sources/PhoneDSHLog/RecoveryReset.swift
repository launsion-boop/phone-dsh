// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLog: adopt the materialized tree after a
// mid-materialization termination.
//
// The process can be killed after a materialized write succeeded but before
// the manifest watermark advanced (an install, a jetsam kill). On the next
// boot the retained WAL no longer proves a local repair: the materialized
// copy is ahead of every retained base, so the invariant blocks the boot.
// The materialized tree is the durable output of that write; this reset keeps
// it and drops the unprovable WAL tail. It is never silent: the caller logs
// the reset before continuing.

import Foundation

public extension LogError {
    /// True when recovery found the materialized copy ahead of the retained
    /// WAL and no retained base could prove a local repair.
    var isMaterializedDivergence: Bool {
        guard case .corrupt(let message) = self else { return false }
        return message.hasPrefix("materialized copy diverges from the retained WAL")
    }
}

public enum RecoveryReset {
    /// Drops every retained WAL segment and keeps the materialized tree.
    ///
    /// - Parameter root: the workspace root (`manifest.json` + `wal/`).
    /// - Returns: the materialized watermark the next epoch continues from.
    /// - Throws: when the manifest is missing or unreadable.
    public static func adoptMaterializedTree(root: URL) throws -> UInt64 {
        let store = ManifestStore(root: root)
        var manifest = try store.read() ?? {
            throw LogError.corrupt("manifest.json is missing")
        }()
        let paths = WorkspacePaths(root: root)
        for segment in manifest.segments {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(segment.file))
        }
        // The open epoch's segments are not listed in the manifest, so clear
        // the directory too: they cannot be proved against anything now.
        if let files = try? FileManager.default.contentsOfDirectory(
            at: paths.walDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "xlwal" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        manifest.segments = []
        try store.write(manifest)
        return manifest.materializedUptoMseq
    }
}
