// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// Persists one connector cursor document per connector.
///
/// The on-disk envelope is exactly the contract's `connector-cursor` document
/// (`{version, connector, cursor, updatedAt, status, lastError?}`); the file
/// name only separates connectors. A missing file means "never scanned"; a
/// corrupt file is treated as missing, so the next scan establishes a fresh
/// baseline and emits nothing (contract: reset silently to the upstream head).
public actor ConnectorCursorFileStore: ConnectorCursorStoring {
    private let directory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func cursor(for connector: ConnectorKind) async -> ConnectorCursorState? {
        let url = fileURL(for: connector)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? decoder.decode(ConnectorCursorState.self, from: data),
              state.version == 1, state.connector == connector else { return nil }
        return state
    }

    public func save(_ state: ConnectorCursorState) async throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: fileURL(for: state.connector), options: [.atomic])
    }

    public func clear(_ connector: ConnectorKind) async throws {
        try? fileManager.removeItem(at: fileURL(for: connector))
    }

    private func fileURL(for connector: ConnectorKind) -> URL {
        directory.appendingPathComponent("connector-cursor-\(connector.rawValue).json")
    }
}
