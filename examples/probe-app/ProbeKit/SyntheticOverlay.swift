// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: synthetic overlay fixtures (PLAN W3-APP).
//
// The Memory page measures the cost of booting the Worker with an overlay of
// 20/50/100 MB. `PhoneDSHHost` always packs the overlay from the workspace log's
// materialized copy (PLAN §2.3, D21 gzip tar), so the probe seeds synthetic
// files *under the materialized tree* after the log has created its manifest.
// The bytes are deterministic but incompressible, so the packed overlay really
// carries the requested size instead of compressing to nothing.
//
// Constraints: the write happens while no host is running; each file stays
// below the 15 MiB single-file cap (PLAN §2.5) and the total stays below the
// 150 MB VFS cap. A workspace whose materialized tree has no manifest is
// rejected: recovery would rebuild that tree from WAL and delete the fixtures.

import Foundation

/// Synthetic overlay seeding for the Memory page.
public enum SyntheticOverlay {
    /// Largest synthetic file, below the PLAN 15 MiB single-file cap.
    public static let chunkBytes = 8 * 1024 * 1024
    /// Allowed overlay levels in MB.
    public static let levelsMB = [20, 50, 100]

    /// Error returned when the workspace has not finished a first boot.
    public struct MissingManifestError: Error, CustomStringConvertible, Sendable {
        public var description: String {
            "the workspace has no manifest.json; boot the host once before seeding synthetic overlay files"
        }
    }

    /// Writes exactly `levelMB` MiB of synthetic overlay content into
    /// `<workspaceRoot>/materialized/workspace/overlay/`.
    ///
    /// - Parameters:
    ///   - levelMB: One of ``levelsMB``.
    ///   - workspaceRoot: The host workspace root (`Library/xl/<workspace_id>/`).
    /// - Returns: The number of bytes written and the files created.
    @discardableResult
    public static func write(levelMB: Int, to workspaceRoot: URL,
                             fileManager: FileManager = .default) throws -> (bytes: Int64,
                                                                             files: Int) {
        guard levelsMB.contains(levelMB) else {
            throw NSError(domain: "ProbeKit.SyntheticOverlay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "overlay level \(levelMB) MB is not one of \(levelsMB)"])
        }
        let manifest = workspaceRoot.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifest.path) else {
            throw MissingManifestError()
        }
        let total = Int64(levelMB) * 1024 * 1024
        let directory = workspaceRoot
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("overlay", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var remaining = total
        var index = 0
        var files = 0
        while remaining > 0 {
            let size = Int(min(Int64(chunkBytes), remaining))
            let url = directory.appendingPathComponent(
                String(format: "synthetic-%04d.bin", index))
            let data = incompressibleData(count: size, seed: UInt64(index) &+ 1)
            try data.write(to: url, options: .atomic)
            remaining -= Int64(size)
            index += 1
            files += 1
        }
        return (total, files)
    }

    /// Total size of the synthetic fixtures currently present.
    public static func currentBytes(workspaceRoot: URL,
                                    fileManager: FileManager = .default) -> Int64 {
        let directory = workspaceRoot
            .appendingPathComponent("materialized/workspace/overlay", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var total: Int64 = 0
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Deterministic xorshift64 bytes: incompressible enough that the gzip
    /// overlay does not shrink the synthetic level to a fraction of its size.
    static func incompressibleData(count: Int, seed: UInt64) -> Data {
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        var bytes = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            // xorshift64*
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = state &* 0x2545_F491_4F6C_DD1D
            var word = value
            for _ in 0..<8 where index < count {
                bytes[index] = UInt8(truncatingIfNeeded: word)
                word >>= 8
                index += 1
            }
        }
        return Data(bytes)
    }
}
