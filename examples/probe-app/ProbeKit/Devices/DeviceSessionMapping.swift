// SPDX-License-Identifier: MIT

import Foundation

public struct DeviceSessionMapping: Codable, Hashable, Identifiable, Sendable {
    public let deviceID: String
    public let sessionID: String
    public var displayName: String

    public var id: String { deviceID }

    public init(deviceID: String, sessionID: String, displayName: String) {
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.displayName = displayName
    }
}

public enum DeviceSessionMappingStoreError: LocalizedError, Equatable {
    case invalidMapping
    case sessionAlreadyAssigned(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMapping:
            return "设备 ID、Session ID 和设备名称不能为空。"
        case .sessionAlreadyAssigned(let deviceID):
            return "这个 DSH Session 已分配给设备 \(deviceID)。"
        }
    }
}

@MainActor
public protocol DeviceSessionMappingStore {
    func allMappings() throws -> [DeviceSessionMapping]
    func save(_ mapping: DeviceSessionMapping) throws
    /// Forgets one device mapping. Used when the DSH Session it points at is gone; the
    /// next open then creates a fresh Session instead of failing forever.
    func remove(deviceID: String) throws
}

@MainActor
public final class UserDefaultsDeviceSessionMappingStore: DeviceSessionMappingStore {
    public static let standard = UserDefaultsDeviceSessionMappingStore()

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "tonoteam.deviceSessions.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func allMappings() throws -> [DeviceSessionMapping] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([DeviceSessionMapping].self, from: data)
            .sorted { $0.deviceID < $1.deviceID }
    }

    public func save(_ mapping: DeviceSessionMapping) throws {
        guard !mapping.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !mapping.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceSessionMappingStoreError.invalidMapping
        }
        var mappings = try allMappings()
        if let duplicate = mappings.first(where: {
            $0.sessionID == mapping.sessionID && $0.deviceID != mapping.deviceID
        }) {
            throw DeviceSessionMappingStoreError.sessionAlreadyAssigned(duplicate.deviceID)
        }
        if let index = mappings.firstIndex(where: { $0.deviceID == mapping.deviceID }) {
            mappings[index] = mapping
        } else {
            mappings.append(mapping)
        }
        mappings.sort { $0.deviceID < $1.deviceID }
        let data = try JSONEncoder().encode(mappings)
        defaults.set(data, forKey: key)
    }

    public func remove(deviceID: String) throws {
        var mappings = try allMappings()
        mappings.removeAll { $0.deviceID == deviceID }
        let data = try JSONEncoder().encode(mappings)
        defaults.set(data, forKey: key)
    }
}
