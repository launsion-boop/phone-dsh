// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Darwin
import PhoneDSHAgentCore

/// device-panel.md §4.1: the host-private copy of an adopted descriptor.
/// One file per Link device ID, raw bytes, atomic replacement. The store never
/// re-serializes the descriptor; it re-evaluates it on every read.
///
/// The class is nonisolated like the rest of `PhoneDSHBLE`: `adopt`/`remove`
/// do bounded synchronous file I/O (a descriptor is at most 16 KiB) and may be
/// called from main-actor UI code. `active` is re-evaluated on every call and
/// never caches, so a firmware rollback can make a previously rejected
/// descriptor valid again.
public final class DevicePanelStore {
    public static let shared = DevicePanelStore()

    /// Host-private directory holding adopted descriptors. Injectable for tests.
    /// Defaults to `Application Support/device-panels/` (P18).
    public let directory: URL

    /// The frozen WP1 evaluator signature, injectable so storage tests do not
    /// depend on the evaluator implementation. Production always uses
    /// `evaluateDevicePanelDescriptor`.
    typealias DescriptorEvaluator = (Data, String, [JSONValue]) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?)

    private let evaluator: DescriptorEvaluator

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("device-panels", isDirectory: true)
        self.evaluator = evaluateDevicePanelDescriptor
    }

    /// Test seam only. The public initializer above binds the real evaluator.
    init(directory: URL, evaluator: @escaping DescriptorEvaluator) {
        self.directory = directory
        self.evaluator = evaluator
    }

    /// What an adopted copy says about itself, for listing panels without a
    /// connected device. Read leniently from the stored bytes and never
    /// evaluated here: whether the descriptor is in effect is still decided by
    /// `active` against the device's live tool table (device-panel.md §4.1).
    public struct AdoptedSummary: Equatable, Sendable {
        public let linkDeviceID: String
        public let title: String?
    }

    /// Every adopted descriptor in the store, sorted by title then device ID.
    /// Bounded: at most 64 files of at most 16 KiB each are read.
    public func adoptedSummaries() -> [AdoptedSummary] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && $0.count == 64 + 5 }.sorted().prefix(64)
        var summaries: [AdoptedSummary] = []
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let bytes = (try? handle.read(upToCount: 16_385)) ?? Data()
            try? handle.close()
            guard bytes.count <= 16_384, let document = try? JSONValue.parse(bytes),
                  let deviceID = document["device_id"]?.stringValue, !deviceID.isEmpty,
                  fileURL(linkDeviceID: deviceID).lastPathComponent == name else { continue }
            summaries.append(AdoptedSummary(linkDeviceID: deviceID, title: document["title"]?.stringValue))
        }
        return summaries.sorted { ($0.title ?? "", $0.linkDeviceID) < ($1.title ?? "", $1.linkDeviceID) }
    }

    /// Evaluate first; write only on `.ok`. A rejected descriptor leaves any
    /// previously adopted copy untouched. Returns the evaluation result.
    ///
    /// The adopted bytes are copied verbatim (device-panel.md §4.1 rule 4):
    /// no wrapper, no metadata, no re-encoding.
    @discardableResult
    public func adopt(
        _ bytes: Data,
        linkDeviceID: String,
        tools: [JSONValue]
    ) throws -> DevicePanelDescriptorResult {
        let (result, _) = evaluator(bytes, linkDeviceID, tools)
        guard result == .ok else { return result }
        try replaceAtomically(bytes, at: fileURL(linkDeviceID: linkDeviceID))
        return result
    }

    /// Read and re-evaluate against the *current* tools. `nil` when nothing was
    /// adopted; a non-`ok` result is returned without deleting the file.
    ///
    /// The file is deliberately kept on every evaluation failure: a firmware
    /// rollback or a restored tool table may make the same bytes valid again
    /// (§6). The store never returns a cached descriptor.
    public func active(
        linkDeviceID: String,
        tools: [JSONValue]
    ) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?)? {
        let file = fileURL(linkDeviceID: linkDeviceID)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: file)
        } catch {
            // No adopted copy (including a file removed after we computed the
            // URL): the panel falls back to §2.
            if Self.isFileMissing(error) { return nil }
            // The file exists but cannot be read. The frozen result enum has no
            // I/O error, so report the same failure the evaluator gives bytes it
            // cannot use; claiming "nothing adopted" or crashing would both be
            // wrong. The file is left in place.
            return (.invalid_json, nil)
        }
        return evaluator(bytes, linkDeviceID, tools)
    }

    /// Delete that device's copy. A missing file is not an error (§4.1 rule 6).
    public func remove(linkDeviceID: String) throws {
        let file = fileURL(linkDeviceID: linkDeviceID)
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            if Self.isFileMissing(error) { return }
            throw error
        }
        Self.fsyncDirectoryBestEffort(directory)
    }

    // MARK: - Host-private file naming (P18)

    /// `<SHA-256 of the UTF-8 Link device ID, lowercase hex>.json`.
    ///
    /// The Link device ID is an arbitrary device-supplied string and may contain
    /// `/`, `..`, NUL or hundreds of scalars; it is never used as a path
    /// component. The descriptor bytes inside the file are the file format.
    private func fileURL(linkDeviceID: String) -> URL {
        let digest = SHA256.hash(data: Data(linkDeviceID.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - Atomic replacement

    /// Write `bytes` to a sibling temporary file, fsync it, then rename it over
    /// `destination`. `rename(2)` replaces the previous copy atomically, so a
    /// reader sees either the old bytes or the new bytes. On any failure the
    /// temporary file is removed and the previous copy is untouched.
    private func replaceAtomically(_ bytes: Data, at destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        var descriptor: Int32 = -1
        do {
            descriptor = temporary.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            }
            guard descriptor >= 0 else { throw POSIXError(Self.currentPOSIXError()) }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(Self.currentPOSIXError())
                    }
                    guard count > 0 else { throw POSIXError(.EIO) }
                    written += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(Self.currentPOSIXError()) }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw POSIXError(Self.currentPOSIXError())
            }
            descriptor = -1
            let renamed = temporary.path.withCString { source in
                destination.path.withCString { target in
                    Darwin.rename(source, target)
                }
            }
            guard renamed == 0 else { throw POSIXError(Self.currentPOSIXError()) }
            // The rename is already atomic. Persisting it across a power loss
            // is best-effort: reporting an adopt failure after the bytes were
            // adopted would be the bigger lie.
            Self.fsyncDirectoryBestEffort(directory)
        } catch {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private static func currentPOSIXError() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: errno) ?? .EIO
    }

    private static func fsyncDirectoryBestEffort(_ url: URL) {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        _ = Darwin.close(descriptor)
    }

    /// Foundation reports "not found" as `NSFileReadNoSuchFileError` when
    /// reading, `NSFileNoSuchFileError` when removing, and `ENOENT` in POSIX
    /// terms. Handle all three so absence is not an error.
    private static func isFileMissing(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return true
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }
}

// §6 convenience entry points for callers that use the shared store.
@discardableResult
public func adoptDevicePanelDescriptor(
    _ bytes: Data,
    linkDeviceID: String,
    tools: [JSONValue]
) throws -> DevicePanelDescriptorResult {
    try DevicePanelStore.shared.adopt(bytes, linkDeviceID: linkDeviceID, tools: tools)
}

public func activeDevicePanelDescriptor(
    linkDeviceID: String,
    tools: [JSONValue]
) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?)? {
    DevicePanelStore.shared.active(linkDeviceID: linkDeviceID, tools: tools)
}

public func removeDevicePanelDescriptor(linkDeviceID: String) throws {
    try DevicePanelStore.shared.remove(linkDeviceID: linkDeviceID)
}
