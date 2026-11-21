// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// Persists one connector cursor document per connector.
///
/// The on-disk bytes are exactly the contract's `connector-cursor` document
/// (`{version, connector, cursor, updatedAt, status, lastError?}`) produced by
/// `ConnectorCursorCodec`; the file name only separates connectors. A missing
/// file means "never scanned"; a file that cannot be decoded is reported as
/// `corrupt`, so the scanner resets to the upstream head silently and emits
/// nothing instead of guessing an interval.
public actor ConnectorCursorFileStore: ConnectorCursorStoring {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(_ connector: ConnectorKind) async throws -> ConnectorCursorLoad {
        let url = fileURL(for: connector)
        // A missing file is the documented "never scanned" state. An existing
        // file that cannot be read is a different state: data protection before
        // the first unlock is common during a background wake. Throwing keeps
        // the scan from treating it as a baseline and silently skipping the
        // interval between the old cursor and the upstream head.
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConnectorCursorStoreError.unavailable
        }
        do {
            let state = try ConnectorCursorCodec.decode(data)
            guard state.connector == connector else { return .corrupt }
            return .stored(state)
        } catch {
            return .corrupt
        }
    }

    public func save(_ state: ConnectorCursorState) async throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ConnectorCursorCodec.encode(state)
        #if os(iOS)
        // BG wakes run before the first unlock; the cursor must be readable at
        // the same protection class the Bot store uses, never only when
        // unlocked.
        try data.write(to: fileURL(for: state.connector),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL(for: state.connector), options: [.atomic])
        #endif
    }

    public func clear(_ connector: ConnectorKind) async throws {
        try? fileManager.removeItem(at: fileURL(for: connector))
    }

    private func fileURL(for connector: ConnectorKind) -> URL {
        directory.appendingPathComponent("connector-cursor-\(connector.rawValue).json")
    }
}
