// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHShell

public struct CompositePhoneToolBridge: PhoneToolBridge {
    public let supportsContext: Bool
    public let handles: Set<String>
    private let bridges: [any PhoneToolBridge]

    public init(bridges: [any PhoneToolBridge]) {
        self.bridges = bridges
        supportsContext = bridges.contains { $0.supportsContext }
        handles = bridges.reduce(into: Set<String>()) { $0.formUnion($1.handles) }
    }

    public init(office: OfficeToolBridge, phone: PhoneCapabilityBridge) {
        self.init(bridges: [office, phone])
    }

    private var phoneBridge: PhoneCapabilityBridge? {
        bridges.compactMap { $0 as? PhoneCapabilityBridge }.first
    }

    public func callTool(name: String, arguments: String) async throws -> String {
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        guard let bridge = bridges.first(where: { $0.handles.contains(tool) }) else {
            return try PhoneToolEnvelope.failure(tool: tool, error: .unknownTool(tool))
        }
        // Any bridge can declare a tool as capability-gated. The declaration drives the
        // gate, so a tool added later cannot be dispatched without authorization.
        if let gated = bridge as? any CapabilityGatedToolBridge,
           gated.capabilityGatedTools.contains(tool) {
            guard let phone = phoneBridge else {
                return try PhoneToolEnvelope.failure(tool: tool, error: .unavailable(
                    nil, "能力门禁未接入；未执行任何系统操作"))
            }
            do {
                try await phone.authorizeLegacyTool(tool)
            } catch let error as PhoneToolError {
                return try PhoneToolEnvelope.failure(tool: tool, error: error)
            }
        }
        if !Thread.isMainThread, let phone = bridge as? PhoneCapabilityBridge {
            return try await Task { @MainActor in
                try await phone.callTool(name: tool, arguments: arguments)
            }.value
        }
        return try await bridge.callTool(name: tool, arguments: arguments)
    }
}
