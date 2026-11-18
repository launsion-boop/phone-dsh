// SPDX-License-Identifier: MIT

import Foundation

/// P26 host tools of `xiaozhi-firmware-v1` (spec/device/v1/xiaozhi-firmware.md §6).
/// PhoneDSHBot depends on neither the firmware builder, the OTA relay (PhoneDSHBLE) nor the
/// probe app: every device, build and relay effect is injected into `XiaozhiFirmwareToolHost`
/// through the closures declared there. DEBUG app builds only.
public enum XiaozhiFirmwareToolNames {
    public static let export = "XiaozhiSourceExport"
    public static let build = "XiaozhiFirmwareBuild"
    public static let status = "XiaozhiFirmwareStatus"
    public static let flash = "XiaozhiFirmwareFlash"
    public static let all: [String] = [export, build, status, flash]
    public static func handles(_ name: String) -> Bool { all.contains(name) }
}

/// §4: a device Bot bound to `xiaozhi:<mac>` is the only caller that lists these tools.
public enum XiaozhiFirmwareBinding {
    public static let keyPrefix = "xiaozhi:"

    /// The MAC inside a `xiaozhi:` device-Bot key; nil for any other (or malformed) key.
    public static func mac(inKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let mac = String(key.dropFirst(keyPrefix.count))
        return DeviceBotKey.isCanonicalMAC(mac) ? mac : nil
    }
}

// MARK: - Values the app returns through the injected closures

/// §3 device record as the status tool shows it. `boardType` is deliberately absent: it is
/// device-supplied text and never enters Bot-visible results.
public struct XiaozhiDeviceRecord: Sendable, Equatable {
    public var mac: String
    public var version: String?
    public var elfSha256: String?
    public var lastSeen: Date?
    /// `passthrough`, `hold`, `offer` or `upstream_failed`.
    public var lastDecision: String?
    public init(mac: String, version: String? = nil, elfSha256: String? = nil,
                lastSeen: Date? = nil, lastDecision: String? = nil) {
        self.mac = mac
        self.version = version
        self.elfSha256 = elfSha256
        self.lastSeen = lastSeen
        self.lastDecision = lastDecision
    }
}

/// A finished image of a build (§6.2).
public struct XiaozhiImageInfo: Sendable, Equatable {
    public var bytes: Int
    public var sha256: String
    public var elfSha256: String
    public var version: String?
    public var matchesReference: Bool
    public init(bytes: Int, sha256: String, elfSha256: String, version: String? = nil,
                matchesReference: Bool) {
        self.bytes = bytes
        self.sha256 = sha256
        self.elfSha256 = elfSha256
        self.version = version
        self.matchesReference = matchesReference
    }
}

public enum XiaozhiJobState: String, Sendable, Equatable { case running, done, failed }

/// One build job (§6.2 / §6.3).
public struct XiaozhiBuildJob: Sendable, Equatable {
    public var jobId: String
    public var state: XiaozhiJobState
    /// Editable paths the build used as overrides.
    public var changed: [String]
    /// Files below the export directory that are not editable paths.
    public var ignored: [String]
    public var error: String?
    public var image: XiaozhiImageInfo?
    public init(jobId: String, state: XiaozhiJobState, changed: [String] = [], ignored: [String] = [],
                error: String? = nil, image: XiaozhiImageInfo? = nil) {
        self.jobId = jobId
        self.state = state
        self.changed = changed
        self.ignored = ignored
        self.error = error
        self.image = image
    }
}

/// An image staged on the OTA relay for the bound device.
public struct XiaozhiStagedImage: Sendable, Equatable {
    public var sha256: String
    public var elfSha256: String
    public var url: String
    public init(sha256: String, elfSha256: String, url: String) {
        self.sha256 = sha256
        self.elfSha256 = elfSha256
        self.url = url
    }
}

public struct XiaozhiRelayState: Sendable, Equatable {
    public var on: Bool
    /// `http://<Wi-Fi IPv4>:8781/xiaozhi/ota/`; nil when off or without a Wi-Fi IPv4.
    public var otaURL: String?
    public init(on: Bool, otaURL: String? = nil) {
        self.on = on
        self.otaURL = otaURL
    }
}

public enum XiaozhiExportOutcome: Sendable, Equatable {
    /// `directory` is the absolute workspace path the import committed.
    case exported(directory: String, files: Int, bytes: Int, project: String, target: String)
    /// `code` is one of `no_editable_sources`, `export_failed`.
    case failed(code: String, message: String)
}

public enum XiaozhiBuildStartOutcome: Sendable, Equatable {
    case started(XiaozhiBuildJob)
    /// A build is already running.
    case busy(jobId: String)
    /// `code` is one of `no_editable_sources`, `not_editable`, `build_failed`, `invalid_arguments`.
    case failed(code: String, message: String)
}

public struct XiaozhiExportRequest: Sendable, Equatable {
    public let principal: BotGatewayPrincipal
}

public struct XiaozhiBuildRequest: Sendable, Equatable {
    public let principal: BotGatewayPrincipal
    /// Absolute workspace path returned earlier by the export tool; nil = reference build.
    public let directory: String?
}

/// What the injected stager receives. Built only after the user's approval.
public struct XiaozhiStageRequest: Sendable, Equatable {
    public let mac: String
    public let elfSha256: String
    public let approvalID: String
    public let authority: BotTurnAuthority
}

public enum XiaozhiStageOutcome: Sendable, Equatable {
    case staged(XiaozhiStagedImage)
    case noBuild
    case relayOff
    case failed(code: String, message: String)
}
