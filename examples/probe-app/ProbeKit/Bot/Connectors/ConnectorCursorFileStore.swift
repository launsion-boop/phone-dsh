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

    public func load(_ connector: ConnectorKind) async -> ConnectorCursorLoad {
        let url = fileURL(for: connector)
        guard let data = try? Data(contentsOf: url) else { return .absent }
        do {
            var state = try ConnectorCursorCodec.decode(data)
            guard state.connector == connector else { return .corrupt }
            state.connector = connector
            return .stored(state)
        } catch {
            return .corrupt
        }
    }

    public func save(_ state: ConnectorCursorState) async throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ConnectorCursorCodec.encode(state)
        try data.write(to: fileURL(for: state.connector), options: [.atomic])
    }

    public func clear(_ connector: ConnectorKind) async throws {
        try? fileManager.removeItem(at: fileURL(for: connector))
    }

    private func fileURL(for connector: ConnectorKind) -> URL {
        directory.appendingPathComponent("connector-cursor-\(connector.rawValue).json")
    }
}
