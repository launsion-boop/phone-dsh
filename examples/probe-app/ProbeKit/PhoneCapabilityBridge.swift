// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHShell

/// A bridge whose tools live outside ``PhoneCapabilityBridge`` but still have to pass
/// this app's capability gate. Declaring them keeps the gate a data dependency instead
/// of an inline name list that a newly added tool can silently miss.
public protocol CapabilityGatedToolBridge: PhoneToolBridge {
    /// Every tool this bridge exposes that must be authorized by the capability gate.
    var capabilityGatedTools: Set<String> { get }
}

public final class PhoneCapabilityBridge: PhoneToolBridge, @unchecked Sendable {
    /// Routes for tools implemented by another bridge. This table is the single source
    /// of truth: a tool declared gated without a route fails closed with `unknownTool`.
    public static let legacyRoutes: [String: PhoneToolRoute] = [
        "contacts.search": PhoneToolRoute(capability: .contacts, scope: "contacts.read"),
        "calendar.create_event": PhoneToolRoute(capability: .calendar,
                                                scope: "calendar.write", writes: true),
    ]

    public let supportsContext = false
    public let handles = Set(PhoneToolCatalog.routes.keys)
    private let engine: PhoneCapabilityEngine

    @MainActor
    public init(store: OfficeArtifactStore = .shared,
                presenter: PhoneCapabilityPresenter = .shared,
                permissionStore: PhonePermissionStore = .shared,
                requester: PhonePermissionRequester = .shared,
                audit: PhoneCapabilityAudit = .shared) {
        engine = PhoneCapabilityEngine(store: store, presenter: presenter,
                                       permissionStore: permissionStore,
                                       requester: requester, audit: audit)
    }

    public nonisolated(nonsending) func callTool(name: String, arguments: String) async throws -> String {
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        guard Thread.isMainThread else {
            return try PhoneToolEnvelope.failure(tool: tool, error: .unavailable(
                PhoneToolCatalog.routes[tool]?.capability,
                "手机能力工具必须在主线程调用；未执行任何系统操作"))
        }
        return await engine.call(tool: tool, arguments: arguments)
    }

    @MainActor
    public func authorizeLegacyTool(_ tool: String) async throws {
        try await engine.authorizeLegacyTool(tool)
    }
}

@MainActor
private final class PhoneCapabilityEngine {
    private let gate: PhoneCapabilityGate
    private let personal: PhonePersonalTools
    private let media: PhoneMediaTools
    private let device: PhoneDeviceTools
    private let extended: PhoneExtendedTools
    private let audit: PhoneCapabilityAudit

    init(store: OfficeArtifactStore, presenter: PhoneCapabilityPresenter,
         permissionStore: PhonePermissionStore, requester: PhonePermissionRequester,
         audit: PhoneCapabilityAudit) {
        gate = PhoneCapabilityGate(store: permissionStore, requester: requester)
        personal = PhonePersonalTools()
        media = PhoneMediaTools(store: store, presenter: presenter)
        device = PhoneDeviceTools(requester: requester)
        extended = PhoneExtendedTools(permissions: requester.extended)
        self.audit = audit
    }

    func authorizeLegacyTool(_ tool: String) async throws {
        guard let route = PhoneCapabilityBridge.legacyRoutes[tool] else {
            throw PhoneToolError.unknownTool(tool)
        }
        try await gate.authorize(tool: tool, route: route)
    }

    func call(tool: String, arguments: String) async -> String {
        guard let route = PhoneToolCatalog.routes[tool] else {
            return (try? PhoneToolEnvelope.failure(tool: tool, error: .unknownTool(tool)))
                ?? #"{"ok":false,"tool":"unknown","error":{"code":"unknown_tool"}}"#
        }
        do {
            try await gate.authorize(tool: tool, route: route)
            let object = try PhoneToolEnvelope.object(arguments)
            let payload: PhoneToolPayload
            switch tool {
            case "contacts.get":
                payload = try await personal.contact(object: object)
            case "calendar.list":
                payload = try await personal.calendar(object: object)
            case "reminders.list":
                payload = try await personal.reminders(object: object)
            case "reminders.create":
                payload = try await personal.createReminder(object: object)
            case "reminders.complete":
                payload = try await personal.completeReminder(object: object)
            case "health.summary":
                payload = try await personal.healthSummary(object: object)
            case "health.query":
                payload = try await personal.healthQuery(object: object)
            case "photos.recent":
                payload = try await personal.photos(object: object, search: false)
            case "photos.search":
                payload = try await personal.photos(object: object, search: true)
            case "camera.capture":
                payload = try await media.capture(object: object)
            case "camera.scan_document":
                payload = try await media.scanDocument(object: object)
            case "audio.record":
                payload = try await media.record(object: object)
            case "audio.transcribe":
                payload = try await media.transcribe(object: object)
            case "location.current":
                payload = try await device.currentLocation(object: object)
            case "notify.local":
                payload = try await device.notify(object: object)
            case "clipboard.read":
                payload = try device.readClipboard()
            case "clipboard.write":
                payload = try device.writeClipboard(object: object)
            case "files.grant_folder":
                payload = try await device.grantFolder(object: object)
            case "files.list_roots":
                payload = device.listRoots()
            case "device.status":
                payload = await device.deviceStatus()
            case "motion.activity":
                payload = try await device.motionActivity(object: object)
            case "motion.steps":
                payload = try await device.steps(object: object)
            case "bluetooth.scan":
                payload = try await device.bluetoothScan(object: object)
            case "network.browse":
                payload = await device.browseNetwork()
            case "location.geofence":
                payload = try extended.geofence(object: object)
            case "focus.status":
                payload = extended.focus()
            case "home.list":
                payload = try extended.homeList(object: object)
            case "home.set":
                payload = try await extended.homeSet(object: object)
            case "music.play":
                payload = try await extended.musicPlay(object: object)
            case "activity.start":
                payload = try extended.activityStart(object: object)
            case "activity.update":
                payload = try await extended.activityUpdate(object: object)
            case "shortcuts.run":
                payload = try await extended.runShortcut(object: object)
            default:
                throw PhoneToolError.unknownTool(tool)
            }
            let scope = await gate.scope(for: route.capability)
            let result = try PhoneToolEnvelope.success(
                tool: tool, scope: scope, data: payload.data, egress: true,
                nextCursor: payload.nextCursor, truncated: payload.truncated)
            await audit.record(PhoneCapabilityAuditRecord(
                capability: route.capability, tool: tool, egress: true, outcome: "success"))
            return result
        } catch let error as PhoneToolError {
            await audit.record(PhoneCapabilityAuditRecord(
                capability: route.capability, tool: tool, egress: false, outcome: error.auditOutcome))
            return (try? PhoneToolEnvelope.failure(tool: tool, error: error))
                ?? #"{"ok":false,"error":{"code":"unavailable"}}"#
        } catch let error as OfficeToolError {
            let mapped: PhoneToolError
            switch error {
            case .invalidArguments, .invalidRange, .unknownArtifact:
                mapped = .invalidArguments(error.localizedDescription)
            case .cancelled:
                mapped = .cancelled
            case .resultTooLarge:
                mapped = .resultTooLarge
            default:
                mapped = .unavailable(route.capability, error.localizedDescription)
            }
            await audit.record(PhoneCapabilityAuditRecord(
                capability: route.capability, tool: tool, egress: false, outcome: mapped.auditOutcome))
            return (try? PhoneToolEnvelope.failure(tool: tool, error: mapped))
                ?? #"{"ok":false,"error":{"code":"unavailable"}}"#
        } catch {
            let error = PhoneToolError.unavailable(route.capability, error.localizedDescription)
            await audit.record(PhoneCapabilityAuditRecord(
                capability: route.capability, tool: tool, egress: false, outcome: "unavailable"))
            return (try? PhoneToolEnvelope.failure(tool: tool, error: error))
                ?? #"{"ok":false,"error":{"code":"unavailable"}}"#
        }
    }
}

private extension PhoneToolError {
    var auditOutcome: String {
        switch self {
        case .invalidArguments: return "invalid_arguments"
        case .permissionRequired: return "permission_required"
        case .permissionDenied: return "permission_denied"
        case .capabilityDisabled: return "capability_disabled"
        case .unavailable: return "unavailable"
        case .unknownTool: return "unknown_tool"
        case .resultTooLarge: return "result_too_large"
        case .noData: return "no_data"
        case .cancelled: return "cancelled"
        }
    }
}
