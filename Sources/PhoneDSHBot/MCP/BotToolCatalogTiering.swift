// SPDX-License-Identifier: MIT

import Foundation

/// Runtime visibility class of one native tool group (W5,
/// PC-20261112-w5-tool-catalog-roundtrips, spec/bot/v1 §2).
public enum BotDeviceClass: String, CaseIterable, Sendable, Equatable, Hashable {
    case adb
    case ble
    case venus
    case ssh
}

/// The device groups that are currently connected or configured. The value is
/// recomputed from the live stores for every `tools/list`; a request never
/// changes it, so the list cannot churn between two identical requests.
public struct BotDeviceAvailability: Sendable, Equatable {
    public var adb: Bool
    public var ble: Bool
    public var venus: Bool
    public var ssh: Bool

    public init(adb: Bool = false, ble: Bool = false, venus: Bool = false, ssh: Bool = false) {
        self.adb = adb
        self.ble = ble
        self.venus = venus
        self.ssh = ssh
    }

    public static let none = Self()
    public static let all = Self(adb: true, ble: true, venus: true, ssh: true)

    public func isAvailable(_ deviceClass: BotDeviceClass) -> Bool {
        switch deviceClass {
        case .adb: return adb
        case .ble: return ble
        case .venus: return venus
        case .ssh: return ssh
        }
    }
}

/// Stable reason strings shared with `golden/tool-catalog-tiers.phone.json`.
public enum BotToolTierValidationError: String, Error, Sendable, Equatable {
    case coreToolMissingFromP0 = "core_tool_missing_from_p0"
    case unknownDeviceClass = "unknown_device_class"
    case deviceToolInCore = "device_tool_in_core"
    case staleDeviceListing = "stale_device_listing"
    case toolInTwoTiers = "tool_in_two_tiers"
    case duplicateDeviceClass = "duplicate_device_class"
    case emptyToolName = "empty_tool_name"
}

/// Additive `tiers` member of `spec/bot/v1/tool-catalog.schema.json`. `p0`/`p1`
/// remain the complete static list; this type only decides which of those
/// tools a runtime `tools/list` exposes right now.
public struct BotToolTierCatalog: Sendable, Equatable {
    public struct DeviceGroup: Sendable, Equatable {
        public let deviceClass: BotDeviceClass
        public let tools: [String]
        public let catalogVersion: Int?

        public init(deviceClass: BotDeviceClass, tools: [String], catalogVersion: Int? = nil) {
            self.deviceClass = deviceClass
            self.tools = tools
            self.catalogVersion = catalogVersion
        }
    }

    public let p0: [String]
    public let p1: [String]
    public let core: [String]
    public let device: [DeviceGroup]
    public let discoverable: [String]
    /// `requires` from the p0/p1 item, used to reject a device tool placed in
    /// the core tier even when it has no explicit group.
    public let requires: [String: Set<BotDeviceClass>]

    /// Static Bot catalog (no native device groups yet).
    public init(core: [String], discoverable: [String]) {
        p0 = BotToolCatalog.p0Names
        p1 = BotToolCatalog.p1TargetNames
        self.core = core
        self.discoverable = discoverable
        device = []
        requires = [:]
    }

    public init(json: BotJSONValue) throws {
        let p0Rows = json["p0"]?.arrayValue ?? []
        let p1Rows = json["p1"]?.arrayValue ?? []
        var p0Names: [String] = []
        var p1Names: [String] = []
        var requirements: [String: Set<BotDeviceClass>] = [:]
        func collect(_ rows: [BotJSONValue], into names: inout [String]) throws {
            for row in rows {
                guard let name = row["name"]?.stringValue, !name.isEmpty else {
                    throw BotToolTierValidationError.emptyToolName
                }
                names.append(name)
                if let raw = row["requires"]?.stringValue {
                    requirements[name] = try Self.classes(fromRequires: raw)
                }
            }
        }
        try collect(p0Rows, into: &p0Names)
        try collect(p1Rows, into: &p1Names)

        let tiers = json["tiers"]
        let core = tiers?["core"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let discoverable = tiers?["discoverable"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var groups: [DeviceGroup] = []
        for row in tiers?["device"]?.arrayValue ?? [] {
            guard let rawClass = row["class"]?.stringValue,
                  let deviceClass = BotDeviceClass(rawValue: rawClass) else {
                throw BotToolTierValidationError.unknownDeviceClass
            }
            guard groups.allSatisfy({ $0.deviceClass != deviceClass }) else {
                throw BotToolTierValidationError.duplicateDeviceClass
            }
            let tools = row["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
            groups.append(DeviceGroup(deviceClass: deviceClass, tools: tools,
                                      catalogVersion: row["catalogVersion"]?.intValue))
        }
        p0 = p0Names
        p1 = p1Names
        self.core = core
        self.device = groups
        self.discoverable = discoverable
        requires = requirements
    }

    private static func classes(fromRequires raw: String) throws -> Set<BotDeviceClass> {
        var result = Set<BotDeviceClass>()
        for part in raw.split(separator: "+") {
            guard let deviceClass = BotDeviceClass(rawValue: String(part)) else {
                throw BotToolTierValidationError.unknownDeviceClass
            }
            result.insert(deviceClass)
        }
        guard !result.isEmpty else { throw BotToolTierValidationError.unknownDeviceClass }
        return result
    }

    public var allToolNames: Set<String> { Set(p0).union(p1) }

    public var deviceToolNames: Set<String> {
        device.reduce(into: Set<String>()) { $0.formUnion($1.tools) }
    }

    /// The names a `tools/list` must expose: core and discoverable always, a
    /// device group only while its class is connected/configured. p0 order is
    /// kept for the always-visible tiers; device groups follow in schema order.
    public func listedNames(availability: BotDeviceAvailability) -> [String] {
        let coreSet = Set(core)
        let discoverableSet = Set(discoverable)
        var names: [String] = []
        var seen = Set<String>()
        for name in p0 + p1 where coreSet.contains(name) || discoverableSet.contains(name) {
            if seen.insert(name).inserted { names.append(name) }
        }
        for group in device where availability.isAvailable(group.deviceClass) {
            for name in group.tools where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// Structural checks plus the requested listing. Reasons match the shared
    /// golden vectors; the first failure wins.
    public func validate(availability: BotDeviceAvailability = .all,
                         listed: [String]? = nil) throws {
        let coreSet = Set(core)
        let discoverableSet = Set(discoverable)
        let deviceSet = deviceToolNames
        guard coreSet.isDisjoint(with: discoverableSet),
              coreSet.isDisjoint(with: deviceSet),
              discoverableSet.isDisjoint(with: deviceSet) else {
            throw BotToolTierValidationError.toolInTwoTiers
        }
        for name in core where !allToolNames.contains(name) {
            throw BotToolTierValidationError.coreToolMissingFromP0
        }
        // A p0/p1 item that declares a device requirement may not sit in core.
        for name in core {
            if let required = requires[name], !required.isEmpty {
                throw BotToolTierValidationError.deviceToolInCore
            }
        }
        for group in device where !availability.isAvailable(group.deviceClass) {
            for name in group.tools where coreSet.contains(name) {
                throw BotToolTierValidationError.deviceToolInCore
            }
        }
        if let listed {
            let unavailable = Set(device.filter { !availability.isAvailable($0.deviceClass) }
                .flatMap(\.tools))
            if listed.contains(where: unavailable.contains) {
                throw BotToolTierValidationError.staleDeviceListing
            }
        }
    }
}

public extension BotToolCatalog {
    /// The Bot-owned catalog has no native tools: every p0 tool is core and
    /// the target-only p1 rows are discoverable. Native device families are
    /// tiered by their own servers (`ADBMCPServer`, `DeviceMCPServer`,
    /// `IPhoneAgentMCPServer`), which is where the connection state lives.
    static var tiers: BotToolTierCatalog {
        BotToolTierCatalog(core: BotToolCatalog.p0Names,
                           discoverable: BotToolCatalog.p1TargetNames)
    }
}
