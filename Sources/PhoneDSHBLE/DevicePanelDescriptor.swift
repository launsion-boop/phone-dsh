// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

/// device-panel.md §4.2: the first failure wins, in the order of the table.
public enum DevicePanelDescriptorResult: String, Equatable, Sendable, CaseIterable {
    case ok
    case too_large
    case invalid_json
    case duplicate_key
    case schema
    case unsupported_version
    case device_mismatch
    case tool_not_advertised
    case tool_not_supported
    case preset_invalid
}

/// One evaluated control. `preset` is the raw JSON object from the descriptor;
/// it is only meaningful for a button control (device-panel.md §4).
public struct DevicePanelControl: Equatable, Sendable {
    public var tool: String
    public var label: String
    public var group: String?
    public var preset: JSONValue?

    public init(tool: String, label: String, group: String? = nil, preset: JSONValue? = nil) {
        self.tool = tool
        self.label = label
        self.group = group
        self.preset = preset
    }
}

/// A descriptor that evaluated to `.ok`. Controls keep descriptor array order.
public struct DevicePanelDescriptor: Equatable, Sendable {
    public var title: String?
    public var controls: [DevicePanelControl]

    public init(title: String? = nil, controls: [DevicePanelControl]) {
        self.title = title
        self.controls = controls
    }
}

/// INTERFACE SKELETON frozen by the coordinator for parallel work (WP1 owns the
/// implementation). Evaluates raw descriptor bytes against the device's current
/// advertised tools; a value is returned only for `.ok`.
public func evaluateDevicePanelDescriptor(
    _ bytes: Data,
    linkDeviceID: String,
    tools: [JSONValue]
) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?) {
    fatalError("WP1: DevicePanelDescriptor.swift evaluator not implemented")
}
