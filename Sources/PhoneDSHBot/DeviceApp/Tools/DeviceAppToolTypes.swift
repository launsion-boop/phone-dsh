// SPDX-License-Identifier: MIT

import Foundation

/// P26 host tools of `device-app-v1` (spec/device/v1/device-app.md §7).
/// PhoneDSHBot depends on none of the Link, BLE or validator code: those
/// ends are injected through the closures below.
public enum DeviceAppToolNames {
    public static let stage = "DeviceAppStage"
    public static let install = "DeviceAppInstall"
    /// `device-app-v1.5`: read the installed apps / stop and remove one.
    public static let list = "DeviceAppList"
    public static let remove = "DeviceAppRemove"
    public static let all: [String] = [stage, install, list, remove]
    public static func handles(_ name: String) -> Bool { all.contains(name) }
}

/// One source file of a candidate bundle. `content` is UTF-8 text.
public struct DeviceAppFile: Sendable, Equatable {
    public let path: String
    public let content: String
    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
    public var data: Data { Data(content.utf8) }
}

/// One line of the §4 manifest digest input: path, byte size, lowercase sha256.
public struct DeviceAppFileEntry: Sendable, Equatable, Codable {
    public let path: String
    public let size: Int
    public let sha256: String
    public init(path: String, size: Int, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// First violation of the static check (§9). `line` is 0 for `size` and `exit_path`.
public struct DeviceAppValidationFailure: Sendable, Equatable {
    public let code: String
    public let path: String
    public let line: Int
    public let message: String?
    public init(code: String, path: String, line: Int, message: String? = nil) {
        self.code = code
        self.path = path
        self.line = line
        self.message = message
    }
}

/// The parts of `app.json` the host shows in the approval card.
public struct DeviceAppManifestSummary: Sendable, Equatable {
    public let name: String
    public let title: String
    public let version: Int
    public let perms: [String]
}

/// What the injected installer receives. It is built only after approval.
public struct DeviceAppInstallRequest: Sendable, Equatable {
    public let installID: String
    public let deviceKey: String
    public let manifest: DeviceAppManifestSummary
    public let files: [DeviceAppFile]
    public let entries: [DeviceAppFileEntry]
    public let digest: String
}

/// What the injected installer observed. Only `.installed` is a success.
public enum DeviceAppInstallOutcome: Sendable, Equatable {
    case installed(digest: String)
    case failed(code: String, message: String)
    /// Commit reply lost and `app.info` could not settle it.
    case outcomeUnknown(message: String)
}

/// One app of the device's `app.info` reply (device-app.md §5), as the phone reads it.
public struct DeviceAppListedApp: Sendable, Equatable {
    public let name: String
    /// nil when the device reports none.
    public let title: String?
    public let version: Int?
    public let running: Bool
    public init(name: String, title: String? = nil, version: Int? = nil, running: Bool = false) {
        self.name = name
        self.title = title
        self.version = version
        self.running = running
    }
}

/// What a full `app.info` read says (list and remove; the install path keeps `DeviceAppInfoResult`).
public enum DeviceAppSnapshot: Sendable, Equatable {
    case reply(protocolName: String?, apps: [DeviceAppListedApp])
    case unavailable(String)
}

/// Outcome of `DeviceAppList`'s injected reader.
public enum DeviceAppListOutcome: Sendable, Equatable {
    case apps([DeviceAppListedApp])
    case failed(code: String, message: String)
}

/// What the injected remover receives. It is built only after approval; the device is the
/// Bot's binding and `name` passed the §2 app-name rule.
public struct DeviceAppRemoveRequest: Sendable, Equatable {
    public let deviceKey: String
    public let name: String
    public init(deviceKey: String, name: String) {
        self.deviceKey = deviceKey
        self.name = name
    }
}

/// What the injected remover observed. Only `.removed` is a success.
public enum DeviceAppRemoveOutcome: Sendable, Equatable {
    /// `wasRunning`: the app was open and the host stopped it first.
    case removed(wasRunning: Bool)
    case failed(code: String, message: String)
    /// The remove reply was lost and `app.info` could not settle it.
    case outcomeUnknown(message: String)
}

public enum DeviceAppAuditAction: String, Sendable, Equatable { case install, remove }

/// The durable `ui.system_event{event:"device.app.install"}` payload. With `action: .remove` it is
/// the `device.app.remove` event of `DeviceAppRemove` (device-app-v1.5): no digest, no files.
public struct DeviceAppInstallAudit: Sendable, Equatable {
    public static let event = "device.app.install"
    public static let removeEvent = "device.app.remove"
    public let deviceKey: String
    public let manifest: DeviceAppManifestSummary
    public let digest: String
    public let files: [DeviceAppFileEntry]
    public let author: BotTeammateAuthor
    public var action: DeviceAppAuditAction = .install
    public var wasRunning: Bool = false

    public var eventData: BotJSONValue {
        if action == .remove {
            var fields: [String: BotJSONValue] = [
                "event": .string(Self.removeEvent),
                "device": .string(deviceKey),
                "name": .string(manifest.name),
                "was_running": .bool(wasRunning),
            ]
            if !manifest.title.isEmpty { fields["title"] = .string(manifest.title) }
            if let data = try? JSONEncoder().encode(author),
               let value = try? BotJSONValue.parse(data) {
                fields["author"] = value
            }
            return .object(fields)
        }
        var fields: [String: BotJSONValue] = [
            "event": .string(Self.event),
            "device": .string(deviceKey),
            "name": .string(manifest.name),
            "title": .string(manifest.title),
            "version": .number(Double(manifest.version)),
            "digest": .string(digest),
            "files": .array(files.map {
                .object(["path": .string($0.path), "size": .number(Double($0.size)),
                         "sha256": .string($0.sha256)])
            }),
        ]
        if let data = try? JSONEncoder().encode(author),
           let value = try? BotJSONValue.parse(data) {
            fields["author"] = value
        }
        return .object(fields)
    }
}
