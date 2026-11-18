// SPDX-License-Identifier: MIT
//
// The logic of the native 「设备应用」 page (spec/device/v1/device-panel.md §9, device-app.md §13,
// device-app-v1.6). No SwiftUI here: the page renders this model, and tests drive it with a fake
// `DeviceAppsLink`. Every action is the user's own tap on the page; the Link calls go out as the user
// origin (the v1.3 waiver covers exactly the eight `app.*` names), so no Bot, approval card or standing
// grant is involved. Device text (titles) is untrusted display text: sanitized, never markup.

import Foundation
import PhoneDSHAgentCore

public struct DeviceAppsRow: Equatable, Identifiable, Sendable {
    /// The device's app name. Only an identifier for the next call; shown only to tell apart two
    /// apps with the same title.
    public let id: String
    public let title: String
    public let detail: String?
    public let running: Bool
}

public enum DeviceAppsInfoResult: Sendable {
    /// The `result` object of a successful `app.info`.
    case reply(JSONValue)
    /// The machine code of a failure (customer text comes from `DeviceAppCustomerText`).
    case failed(code: String)
}

/// What the page needs from the device. The app implements it over the user-origin Link entry.
public struct DeviceAppsLink: Sendable {
    public var connected: @Sendable () async -> Bool
    public var info: @Sendable () async -> DeviceAppsInfoResult
    /// nil: it worked; otherwise the machine code.
    public var run: @Sendable (_ name: String) async -> String?
    public var stop: @Sendable () async -> String?
    public var remove: @Sendable (_ name: String) async -> String?

    public init(connected: @escaping @Sendable () async -> Bool,
                info: @escaping @Sendable () async -> DeviceAppsInfoResult,
                run: @escaping @Sendable (String) async -> String?,
                stop: @escaping @Sendable () async -> String?,
                remove: @escaping @Sendable (String) async -> String?) {
        self.connected = connected; self.info = info; self.run = run; self.stop = stop; self.remove = remove
    }
}

@MainActor
public final class DeviceAppsPageModel: ObservableObject {
    public enum Phase: Equatable { case loading, notConnected, failed(String), ready }
    public struct Banner: Equatable { public let text: String; public let isError: Bool }

    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var rows: [DeviceAppsRow] = []
    @Published public private(set) var freeSpace: String?
    @Published public private(set) var banner: Banner?
    @Published public private(set) var busy = false
    /// The row waiting for the delete confirmation.
    @Published public var pendingDelete: DeviceAppsRow?

    private let link: DeviceAppsLink
    private var known: [String: Known] = [:]
    public init(link: DeviceAppsLink) { self.link = link }

    // MARK: Pure rules (also used by the entry decision)

    /// device-bot.md §5 / device-app.md: exactly these eight names, no prefix or case matching.
    public static let requiredTools = ["app.info", "app.begin", "app.put", "app.abort",
                                       "app.commit", "app.run", "app.stop", "app.remove"]

    public static func isDeviceAppTarget(tools: [String]) -> Bool {
        let have = Set(tools)
        return requiredTools.allSatisfy(have.contains)
    }

    public static func freeSpaceText(bytes: Int) -> String {
        let value = max(0, bytes)
        if value >= 1_048_576 { return String(format: "设备剩余空间约 %.1f MB", Double(value) / 1_048_576) }
        return "设备剩余空间约 \(max(1, value / 1024)) KB"
    }

    /// What the page remembers of an app between reads.
    public struct Known: Equatable, Sendable { public let title: String; public let version: Int? }

    public static func parse(_ result: JSONValue) -> (rows: [DeviceAppsRow], freeBytes: Int?) {
        let parsed = parse(result, known: [:])
        return (parsed.rows, parsed.freeBytes)
    }

    /// `known`: the titles of the previous read. The board's `app.info` can answer an entry without its
    /// manifest data (title = name, version 0, no digest) when it is short of memory; such an entry
    /// keeps the title and version remembered for that name instead of flashing the internal name.
    public static func parse(_ result: JSONValue, known: [String: Known])
        -> (rows: [DeviceAppsRow], freeBytes: Int?, known: [String: Known]) {
        let apps = result["apps"]?.arrayValue ?? []
        struct Raw { let name: String; let title: String; let version: Int?; let running: Bool }
        var remembered = known
        let raws: [Raw] = apps.compactMap { app in
            guard let name = app["name"]?.stringValue, !name.isEmpty else { return nil }
            let shownName = DeviceAppToolEffects.display(name, max: 40)
            let title = DeviceAppToolEffects.display(app["title"]?.stringValue ?? "", max: 40)
            let version = app["version"]?.intValue
            let digest = app["digest"]?.stringValue ?? ""
            let degraded = (title.isEmpty || title == shownName) && (version ?? 0) == 0 && digest.isEmpty
            if degraded, let old = known[name], old.title != shownName {
                return Raw(name: name, title: old.title, version: old.version, running: app["running"]?.boolValue == true)
            }
            remembered[name] = Known(title: title.isEmpty ? shownName : title, version: version)
            return Raw(name: name, title: title.isEmpty ? shownName : title,
                       version: version, running: app["running"]?.boolValue == true)
        }
        var count: [String: Int] = [:]
        for raw in raws { count[raw.title, default: 0] += 1 }
        let rows = raws.map { raw -> DeviceAppsRow in
            var detail: String?
            if count[raw.title, default: 0] > 1 {
                let version = raw.version.map { "版本 \($0)" } ?? ""
                detail = version.isEmpty ? "名称 \(DeviceAppToolEffects.display(raw.name, max: 40))"
                                         : "\(version)（\(DeviceAppToolEffects.display(raw.name, max: 40))）"
            }
            return DeviceAppsRow(id: raw.name, title: raw.title, detail: detail, running: raw.running)
        }
        return (rows, result["free_bytes"]?.intValue, remembered)
    }

    // MARK: Actions

    public func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await load()
    }

    private func load() async {
        guard await link.connected() else { phase = .notConnected; rows = []; freeSpace = nil; return }
        switch await link.info() {
        case .failed(let code):
            if rows.isEmpty { phase = .failed(DeviceAppCustomerText.listSentence(forCode: code)) }
            else { banner = Banner(text: DeviceAppCustomerText.listSentence(forCode: code), isError: true) }
        case .reply(let result):
            let parsed = Self.parse(result, known: known)
            known = parsed.known
            rows = parsed.rows
            freeSpace = parsed.freeBytes.map(Self.freeSpaceText(bytes:))
            phase = .ready
        }
    }

    public func open(_ row: DeviceAppsRow) async {
        await act { [link] in
            if let code = await link.run(row.id) { return Banner(text: DeviceAppCustomerText.runSentence(forCode: code), isError: true) }
            return Banner(text: DeviceAppCustomerText.opened(title: row.title), isError: false)
        }
    }

    public func stop(_ row: DeviceAppsRow) async {
        await act { [link] in
            if let code = await link.stop() { return Banner(text: DeviceAppCustomerText.stopSentence(forCode: code), isError: true) }
            return Banner(text: DeviceAppCustomerText.stopped(title: row.title), isError: false)
        }
    }

    public func requestDelete(_ row: DeviceAppsRow) { pendingDelete = row }
    public func cancelDelete() { pendingDelete = nil }

    /// The user confirmed. A running app is stopped first (the device refuses to remove a running one).
    public func confirmDelete() async {
        guard let row = pendingDelete else { return }
        pendingDelete = nil
        await act { [link] in
            if row.running, let code = await link.stop() {
                return Banner(text: DeviceAppCustomerText.removeSentence(forCode: code == "device_not_connected" ? code : "stop_failed"), isError: true)
            }
            if let code = await link.remove(row.id) { return Banner(text: DeviceAppCustomerText.removeSentence(forCode: code), isError: true) }
            return Banner(text: DeviceAppCustomerText.deleted(title: row.title), isError: false)
        }
    }

    private func act(_ work: @escaping () async -> Banner) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        banner = nil
        guard await link.connected() else { phase = .notConnected; banner = Banner(text: DeviceAppCustomerText.pageNotConnected, isError: true); return }
        let result = await work()
        await load()
        banner = result          // after the reload so a refresh failure does not hide the action's result
    }

    public func dismissBanner() { banner = nil }
}
