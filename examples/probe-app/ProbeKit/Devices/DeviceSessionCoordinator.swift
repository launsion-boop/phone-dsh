// SPDX-License-Identifier: MIT

import Foundation
import Observation

@MainActor
public protocol DeviceSessionProviding {
    func openSession(deviceID: String, displayName: String,
                     existingSessionID: String?) async throws -> String
}

public enum DeviceSessionCoordinatorError: LocalizedError, Equatable {
    case deviceOffline(String)
    case providerUnavailable
    case invalidSessionID
    case sessionIdentityMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .deviceOffline(let deviceID):
            return "设备 \(deviceID) 当前不在线，不能打开设备会话。"
        case .providerUnavailable:
            return "设备 Session Provider 尚未配置。"
        case .invalidSessionID:
            return "DSH 没有返回有效的 Session ID。"
        case .sessionIdentityMismatch(let expected, let actual):
            return "恢复设备会话时 ID 不一致：应为 \(expected)，实际为 \(actual)。"
        }
    }
}

@MainActor
@Observable
public final class DeviceSessionCoordinator {
    public static let shared = DeviceSessionCoordinator()

    public private(set) var isConnectorAvailable = false
    public private(set) var lifecycle: DeviceConnectorLifecycle = .unavailable
    public private(set) var devices: [DeviceConnectionSnapshot] = []
    public private(set) var errorMessage: String?

    @ObservationIgnored private var connector: (any DeviceConnector)?
    @ObservationIgnored private var provider: (any DeviceSessionProviding)?
    @ObservationIgnored private let mappingStore: any DeviceSessionMappingStore
    @ObservationIgnored private var mappings: [String: DeviceSessionMapping] = [:]
    @ObservationIgnored private var snapshots: [String: DeviceConnectionSnapshot] = [:]
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var installation = 0
    @ObservationIgnored private var resolutions: [String: Task<DeviceSessionMapping, Error>] = [:]

    public var onlineDevices: [DeviceConnectionSnapshot] {
        devices.filter { $0.state == .online }
    }
    public var hasOnlineDevices: Bool { !onlineDevices.isEmpty }
    public var mappedSessionIDs: Set<String> { Set(mappings.values.map(\.sessionID)) }
    public var activeConnector: (any DeviceConnector)? { connector }
    public func isDeviceSession(_ sessionID: String) -> Bool {
        mappings.values.contains { $0.sessionID == sessionID }
    }

    public func reportBotIngressFailure(_ error: Error) {
        errorMessage = "设备消息未接受：\(String(error.localizedDescription.prefix(200)))"
    }

    public init(provider: (any DeviceSessionProviding)? = nil,
                mappingStore: (any DeviceSessionMappingStore)? = nil) {
        self.provider = provider
        self.mappingStore = mappingStore ?? UserDefaultsDeviceSessionMappingStore.standard
        do {
            mappings = Dictionary(uniqueKeysWithValues: try self.mappingStore.allMappings().map { ($0.deviceID, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setProvider(_ provider: any DeviceSessionProviding) {
        self.provider = provider
    }

    public func install(connector newConnector: (any DeviceConnector)?) async {
        installation += 1
        let currentInstallation = installation
        eventTask?.cancel()
        eventTask = nil
        let previous = connector
        connector = nil
        isConnectorAvailable = false
        devices = []
        snapshots = [:]
        errorMessage = nil
        lifecycle = .unavailable
        if let previous { await previous.stop() }
        guard currentInstallation == installation else { return }
        guard let newConnector else { return }

        connector = newConnector
        isConnectorAvailable = true
        lifecycle = .idle
        let stream = newConnector.events()
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self, self.installation == currentInstallation else { return }
                self.apply(event)
            }
        }
        do {
            lifecycle = .starting
            try await newConnector.start()
        } catch {
            guard currentInstallation == installation else { return }
            lifecycle = .failed
            errorMessage = error.localizedDescription
        }
    }

    public func savedMapping(for deviceID: String) -> DeviceSessionMapping? {
        mappings[deviceID]
    }

    /// Drops one device mapping so the next open creates a fresh Session. This is the
    /// explicit user action for an orphaned mapping; it never happens silently.
    public func forgetMapping(for deviceID: String) throws {
        try mappingStore.remove(deviceID: deviceID)
        mappings[deviceID] = nil
        resolutions[deviceID] = nil
    }

    public func resolveSession(for deviceID: String) async throws -> DeviceSessionMapping {
        guard let device = onlineDevices.first(where: { $0.deviceID == deviceID }) else {
            throw DeviceSessionCoordinatorError.deviceOffline(deviceID)
        }
        if let resolution = resolutions[deviceID] {
            return try await resolution.value
        }
        let resolution = Task { @MainActor in
            defer { self.resolutions[deviceID] = nil }
            return try await self.resolveNow(device)
        }
        resolutions[deviceID] = resolution
        return try await resolution.value
    }

    private func resolveNow(_ device: DeviceConnectionSnapshot) async throws -> DeviceSessionMapping {
        guard let provider else { throw DeviceSessionCoordinatorError.providerUnavailable }
        let saved = mappings[device.deviceID]
        let sessionID = try await provider.openSession(
            deviceID: device.deviceID,
            displayName: device.displayName,
            existingSessionID: saved?.sessionID)
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceSessionCoordinatorError.invalidSessionID
        }
        if let expected = saved?.sessionID, sessionID != expected {
            throw DeviceSessionCoordinatorError.sessionIdentityMismatch(expected: expected, actual: sessionID)
        }
        let mapping = DeviceSessionMapping(deviceID: device.deviceID, sessionID: sessionID,
                                           displayName: device.displayName)
        try mappingStore.save(mapping)
        mappings[device.deviceID] = mapping
        return mapping
    }

    private func apply(_ event: DeviceConnectorEvent) {
        switch event {
        case .lifecycle(let state):
            lifecycle = state
        case .deviceChanged(let snapshot):
            snapshots[snapshot.deviceID] = snapshot
            devices = snapshots.values.sorted {
                if $0.displayName == $1.displayName { return $0.deviceID < $1.deviceID }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .failure(let failure):
            errorMessage = failure.message
            guard let deviceID = failure.deviceID, var snapshot = snapshots[deviceID] else { return }
            snapshot.state = .failed
            snapshot.lastError = failure.message
            snapshots[deviceID] = snapshot
            devices = devices.map { $0.deviceID == deviceID ? snapshot : $0 }
        }
    }
}
