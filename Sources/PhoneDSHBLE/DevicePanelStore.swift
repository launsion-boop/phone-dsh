// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

/// device-panel.md §4.1: the host-private copy of an adopted descriptor.
/// One file per Link device ID, raw bytes, atomic replacement. The store never
/// re-serializes the descriptor; it re-evaluates it on every read.
public final class DevicePanelStore {
    public static let shared = DevicePanelStore()

    /// Host-private directory holding adopted descriptors. Injectable for tests.
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("device-panels", isDirectory: true)
    }

    /// Evaluate first; write only on `.ok`. A rejected descriptor leaves any
    /// previously adopted copy untouched. Returns the evaluation result.
    @discardableResult
    public func adopt(
        _ bytes: Data,
        linkDeviceID: String,
        tools: [JSONValue]
    ) throws -> DevicePanelDescriptorResult {
        fatalError("WP3: DevicePanelStore.swift adopt not implemented")
    }

    /// Read and re-evaluate against the *current* tools. `nil` when nothing was
    /// adopted; a non-`ok` result is returned without deleting the file.
    public func active(
        linkDeviceID: String,
        tools: [JSONValue]
    ) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?)? {
        fatalError("WP3: DevicePanelStore.swift active not implemented")
    }

    public func remove(linkDeviceID: String) throws {
        fatalError("WP3: DevicePanelStore.swift remove not implemented")
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
