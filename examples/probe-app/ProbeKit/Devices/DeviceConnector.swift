// SPDX-License-Identifier: MIT

import Foundation

public enum DeviceConnectorLifecycle: String, Equatable, Sendable {
    case unavailable
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed
}

public enum DeviceConnectionState: String, Equatable, Sendable {
    case connecting
    case online
    case disconnected
    case failed
}

public struct DeviceCapabilityMetadata: Equatable, Sendable {
    public var names: Set<String>
    public var values: [String: String]

    public init(names: Set<String> = [], values: [String: String] = [:]) {
        self.names = names
        self.values = values
    }
}

public struct DeviceConnectionSnapshot: Identifiable, Equatable, Sendable {
    public let deviceID: String
    public var displayName: String
    public var state: DeviceConnectionState
    public var capabilities: DeviceCapabilityMetadata
    public var lastError: String?

    public var id: String { deviceID }

    public init(deviceID: String, displayName: String, state: DeviceConnectionState,
                capabilities: DeviceCapabilityMetadata = DeviceCapabilityMetadata(),
                lastError: String? = nil) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.state = state
        self.capabilities = capabilities
        self.lastError = lastError
    }
}

public struct DeviceConnectorFailure: Error, Equatable, Sendable {
    public let deviceID: String?
    public let message: String

    public init(deviceID: String? = nil, message: String) {
        self.deviceID = deviceID
        self.message = message
    }
}

public enum DeviceConnectorEvent: Equatable, Sendable {
    case lifecycle(DeviceConnectorLifecycle)
    case deviceChanged(DeviceConnectionSnapshot)
    case failure(DeviceConnectorFailure)
}

public protocol DeviceConnector: Sendable {
    func events() -> AsyncStream<DeviceConnectorEvent>
    func start() async throws
    func stop() async
    func connect(to deviceID: String) async throws
    func disconnect(from deviceID: String) async throws
}
