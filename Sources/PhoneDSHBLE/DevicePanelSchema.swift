// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

/// device-panel.md §2: the deterministic mapping from one advertised tool's
/// `inputSchema` to panel editors. This is a pure function: no Link access, no
/// UI state, no file I/O.
public enum DevicePanelEditor: Equatable, Sendable {
    case toggle(arg: String, required: Bool)
    case slider(arg: String, required: Bool, integer: Bool, min: Double, max: Double)
    case picker(arg: String, required: Bool, options: [String])
}

public enum DevicePanelRender: Equatable, Sendable {
    case editors([DevicePanelEditor])
    case agentOnly
}

/// INTERFACE SKELETON frozen by the coordinator for parallel work (WP1 owns the
/// implementation). Do not ship this placeholder: device-panel.md §2 requires
/// the real classifier before the panel may be presented as usable.
public func classifyDevicePanelTool(inputSchema: JSONValue) -> DevicePanelRender {
    fatalError("WP1: DevicePanelSchema.swift classifier not implemented")
}
