// SPDX-License-Identifier: MIT
// App side of xiaozhi-firmware-v1 (spec/device/v1/xiaozhi-firmware.md), DEBUG builds only: the shared
// model behind the Bot tools and the 「小智固件」 settings page. It owns the build jobs (on top of
// `FirmwareBuilderModel`), the source export into a Bot's workspace, the staged-image bookkeeping and
// the device-Bot trigger. The OTA relay itself (listener, device records, rewrite, staged image store)
// is the SDK's (`XiaozhiOTARelayServer`, `XiaozhiStagedImages`, spec §7); this file reaches it only
// through `XiaozhiRelayControlling`, installed by `XiaozhiFirmwareWiring` (INTEGRATION).
#if DEBUG
import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHBot
import PhoneDSHEngine
import SwiftUI

// MARK: - Values shared with the Bot tool wiring (spec §6)

/// A tool error: `code` is one of spec §6.5.
struct XiaozhiToolError: Error, Equatable {
    var code: String
    var message: String
    var jobID: String?
}

struct XiaozhiBuiltImage: Equatable {
    var bytes: Int
    /// SHA-256 of the whole image (what the relay serves at `/xiaozhi/firmware/<sha>.bin`).
    var sha256: String
    var elfSha256: String
    var version: String
    var matchesReference: Bool?
}

struct XiaozhiBuildJob: Equatable {
    enum State: String { case running, done, failed }
    var id: String
    var state: State
    /// Editable files whose bytes differ from the pack and were built as overrides.
    var changed: [String]
    /// Files below the export directory that are not editable paths.
    var ignored: [String]
    var error: XiaozhiToolError?
    var image: XiaozhiBuiltImage?
}

struct XiaozhiExportResult: Equatable {
    /// Absolute workspace path the import committed (`…/imports/xiaozhi-src[-N]`).
    var directory: String
    var files: Int
    var bytes: Int
    var project: String
    var target: String
}

/// One board that checked in at the relay (spec §3).
struct XiaozhiDeviceView: Identifiable, Equatable {
    var mac: String
    var version: String?
    var elfSha256: String?
    var boardType: String?
    var lastSeen: Date?
    /// `passthrough`, `hold`, `offer` or `upstream_failed`.
    var lastDecision: String?
    var id: String { mac }
}

/// The image staged for one device (spec §2.4, §6.3).
struct XiaozhiStagedView: Equatable {
    var sha256: String
    var elfSha256: String
    var url: String
}

struct XiaozhiStatusSnapshot: Equatable {
    var job: XiaozhiBuildJob?
    var device: XiaozhiDeviceView?
    var staged: XiaozhiStagedView?
    var relayOn: Bool
    var otaURL: String?
}

/// The SDK relay as the app model sees it. INTEGRATION: `XiaozhiFirmwareWiring` supplies an adapter over
/// `XiaozhiOTARelayServer` + `XiaozhiStagedImages` (Sources/PhoneDSHBLE/Xiaozhi); until then
/// `XiaozhiRelayUnavailable` keeps the page and the build/export logic usable on their own.
@MainActor protocol XiaozhiRelayControlling: AnyObject {
    var isOn: Bool { get }
    func setOn(_ on: Bool) async
    /// `http://<Wi-Fi IPv4>:8781/xiaozhi/ota/`, nil without a Wi-Fi IPv4 (spec §2.1).
    var otaURL: String? { get }
    var devices: [XiaozhiDeviceView] { get }
    func staged(mac: String) -> XiaozhiStagedView?
    /// Stages `image` for `mac`, replacing any earlier staged image for it (spec §6.4).
    func stage(mac: String, image: Data, elfSha256: String) throws -> XiaozhiStagedView
}

@MainActor final class XiaozhiRelayUnavailable: XiaozhiRelayControlling {
    var isOn: Bool { false }
    func setOn(_ on: Bool) async {}
    var otaURL: String? { nil }
    var devices: [XiaozhiDeviceView] { [] }
    func staged(mac: String) -> XiaozhiStagedView? { nil }
    func stage(mac: String, image: Data, elfSha256: String) throws -> XiaozhiStagedView {
        throw XiaozhiToolError(code: "relay_off", message: "the OTA relay is not installed in this build")
    }
}

// MARK: - Model

@MainActor @Observable final class XiaozhiFirmwareModel {
    static let shared = XiaozhiFirmwareModel()
    /// The Bot tools wait this long for a build before answering `running` (spec §6.2).
    static let buildWait: Duration = .seconds(100)
    /// The sum of override bytes one build accepts.
    static let maxOverrideBytes = 16 << 20

    /// INTEGRATION: replaced by `XiaozhiFirmwareWiring.attach` with the adapter over the SDK relay.
    var relay: any XiaozhiRelayControlling = XiaozhiRelayUnavailable()
    private(set) var jobs: [String: XiaozhiBuildJob] = [:]
    private(set) var latestJobID: String?
    /// Last message of the trust action, shown on the page.
    private(set) var trustNote = ""
    @ObservationIgnored private var builtImages: [String: Data] = [:]
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private let builder = FirmwareBuilderModel.shared

    var runningJob: XiaozhiBuildJob? { jobs.values.first { $0.state == .running } }

    // MARK: Pack

    /// The pack and its editable files, or the spec §6.5 error (`no_editable_sources`).
    func editableSources() -> Result<(pack: FirmwareBuilderPack, files: [FirmwareEditableSource]), XiaozhiToolError> {
        let pack: FirmwareBuilderPack
        switch FirmwareBuilderModel.pack() {
        case .success(let value): pack = value
        case .failure(let error): return .failure(XiaozhiToolError(code: "no_editable_sources", message: error.message))
        }
        guard pack.sourcesRoot != nil else {
            return .failure(XiaozhiToolError(code: "no_editable_sources", message: "the staged firmware pack has no editable sources (manifest.sources_root)"))
        }
        do {
            let files = try FirmwareBuilderSources.list(pack: pack)
            guard !files.isEmpty else {
                return .failure(XiaozhiToolError(code: "no_editable_sources", message: "the pack lists no files below sources_root"))
            }
            return .success((pack, files))
        } catch {
            return .failure(XiaozhiToolError(code: "no_editable_sources", message: error.localizedDescription))
        }
    }

    /// True when the app should offer the Bot tools: a DEBUG build with a staged pack that has `sources_root`.
    var hasEditableSources: Bool { (try? editableSources().get()) != nil }

    // MARK: Export (spec §6.1)

    /// Copies every editable file into `botID`'s workspace through the import RPCs: target directory the Bot
    /// root, entry name `xiaozhi-src`. Paths below the export root are relative to `sources_root`.
    func export(botID: String) async -> Result<XiaozhiExportResult, XiaozhiToolError> {
        let pack: FirmwareBuilderPack, files: [FirmwareEditableSource]
        switch editableSources() {
        case .success(let value): pack = value.pack; files = value.files
        case .failure(let error): return .failure(error)
        }
        guard let composition = ChatModel.shared.botRuntime else {
            return .failure(XiaozhiToolError(code: "export_failed", message: "the Bot runtime is not running"))
        }
        let context: (transport: any DSHRemoteTransport, sessionID: String)
        do { context = try await composition.ensureUnit(for: botID, reason: "xiaozhi-export").remote.attachmentImportContext() }
        catch { return .failure(XiaozhiToolError(code: "export_failed", message: "the Bot session is not ready: \(error.localizedDescription)")) }

        let botRoot = BotWorkspaceLayout.botRoot(botId: botID, dataDirectory: BotSessionRegistry.botDataDirectory)
        let manifest = WebEngineDirectoryImportManifest(
            sessionID: context.sessionID, targetDirectory: botRoot, entryName: "xiaozhi-src",
            directories: Self.directories(of: files.map(\.relativePath)),
            files: files.map { WebEngineDirectoryImportFile(path: $0.relativePath, size: $0.length) },
            totalBytes: files.reduce(0) { $0 + $1.length })
        let sink = PhoneDSHWorkspaceImportSink(transport: context.transport)
        var importID: String?
        do {
            let started = try await sink.begin(manifest)
            importID = started
            let chunk = 1 << 20
            for file in files {
                let data = try FirmwareBuilderSources.read(file)
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunk, data.count)
                    try await sink.write(importID: started, path: file.relativePath, offset: offset, data: data.subdata(in: offset..<end))
                    offset = end
                }
            }
            let committed = try await sink.commit(importID: started)
            return .success(XiaozhiExportResult(directory: committed.absolutePath, files: files.count,
                                                bytes: manifest.totalBytes, project: pack.project, target: pack.target))
        } catch {
            if let importID { await sink.abort(importID: importID) }
            return .failure(XiaozhiToolError(code: "export_failed", message: error.localizedDescription))
        }
    }

    /// Every ancestor directory of `paths`, shallow first (the import manifest lists child directories).
    nonisolated static func directories(of paths: [String]) -> [String] {
        var seen = Set<String>()
        for path in paths {
            var parts = path.split(separator: "/").dropLast().map(String.init)
            while !parts.isEmpty { seen.insert(parts.joined(separator: "/")); parts.removeLast() }
        }
        return seen.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
    }

    // MARK: Build (spec §6.2)

    /// Starts a build unless one is running, then waits up to 100 s. `directory` is an export directory
    /// (§6.1); without it the build is the reference build.
    func startBuild(directory: String?) async -> Result<XiaozhiBuildJob, XiaozhiToolError> {
        let files: [FirmwareEditableSource]
        switch editableSources() {
        case .success(let value): files = value.files
        case .failure(let error): return .failure(error)
        }
        if let running = runningJob {
            return .failure(XiaozhiToolError(code: "busy", message: "a firmware build is already running", jobID: running.id))
        }
        guard !builder.running else { return .failure(XiaozhiToolError(code: "busy", message: "the firmware builder page is building")) }

        var overrides: [String: Data] = [:]
        var changed: [String] = [], ignored: [String] = []
        if let directory {
            switch Self.collectOverrides(directory: directory, editable: files) {
            case .success(let value): overrides = value.overrides; changed = value.changed; ignored = value.ignored
            case .failure(let error): return .failure(error)
            }
        }
        let id = "xzb-" + String(UUID().uuidString.lowercased().prefix(8))
        let job = XiaozhiBuildJob(id: id, state: .running, changed: changed, ignored: ignored)
        jobs[id] = job
        latestJobID = id
        buildTask = Task { [weak self] in await self?.runBuild(id: id, overrides: overrides) }

        let deadline = ContinuousClock.now + Self.buildWait
        while jobs[id]?.state == .running, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .success(jobs[id] ?? job)
    }

    /// Kicks off a build and returns the running job at once, without the §6.2 wait. The Bot tool
    /// host owns the 100 s wait (it polls `job(id:)`), so the firmware-build tool must not block here
    /// too. Shares every guard and the override collection with `startBuild`.
    func beginBuild(directory: String?) -> Result<XiaozhiBuildJob, XiaozhiToolError> {
        let files: [FirmwareEditableSource]
        switch editableSources() {
        case .success(let value): files = value.files
        case .failure(let error): return .failure(error)
        }
        if let running = runningJob {
            return .failure(XiaozhiToolError(code: "busy", message: "a firmware build is already running", jobID: running.id))
        }
        guard !builder.running else { return .failure(XiaozhiToolError(code: "busy", message: "the firmware builder page is building")) }
        var overrides: [String: Data] = [:]
        var changed: [String] = [], ignored: [String] = []
        if let directory {
            switch Self.collectOverrides(directory: directory, editable: files) {
            case .success(let value): overrides = value.overrides; changed = value.changed; ignored = value.ignored
            case .failure(let error): return .failure(error)
            }
        }
        let id = "xzb-" + String(UUID().uuidString.lowercased().prefix(8))
        let job = XiaozhiBuildJob(id: id, state: .running, changed: changed, ignored: ignored)
        jobs[id] = job
        latestJobID = id
        buildTask = Task { [weak self] in await self?.runBuild(id: id, overrides: overrides) }
        return .success(job)
    }

    /// The job with `id`, or the latest job when `id` is nil.
    func job(id: String?) -> XiaozhiBuildJob? {
        if let id { return jobs[id] }
        return latestJobID.flatMap { jobs[$0] }
    }

    /// Whether a finished build of this app session produced an image with that ELF SHA-256.
    func hasBuiltImage(elfSha256: String) -> Bool { builtImages[elfSha256] != nil }

    /// The bytes of a finished build's image, for staging on the relay.
    func builtImage(elfSha256: String) -> Data? { builtImages[elfSha256] }

    private func runBuild(id: String, overrides: [String: Data]) async {
        let ok = await builder.build(overrides: overrides)
        guard var job = jobs[id] else { return }
        if ok, let image = builder.image {
            let built = XiaozhiBuiltImage(bytes: image.data.count, sha256: builder.imageSHA256, elfSha256: image.elfSHA256,
                                          version: image.version, matchesReference: builder.matchesReference)
            builtImages[image.elfSHA256] = image.data
            job.state = .done; job.image = built
        } else {
            job.state = .failed
            let failure = builder.failure
            job.error = XiaozhiToolError(code: failure?.code == "not_editable" ? "not_editable" : "build_failed",
                                         message: failure?.message ?? builder.result)
        }
        jobs[id] = job
    }

    /// The directory's files as overrides: a file whose relative path is editable and whose bytes differ from
    /// the pack is an override; another path is `ignored`; an unchanged editable file is neither.
    static func collectOverrides(directory: String, editable: [FirmwareEditableSource]) -> Result<(overrides: [String: Data], changed: [String], ignored: [String]), XiaozhiToolError> {
        guard let root = materializedDirectory(forWorkspacePath: directory) else {
            return .failure(XiaozhiToolError(code: "invalid_arguments", message: "directory is not an export directory returned by XiaozhiSourceExport"))
        }
        let byPath = Dictionary(uniqueKeysWithValues: editable.map { ($0.relativePath, $0) })
        var overrides: [String: Data] = [:], changed: [String] = [], ignored: [String] = []
        var total = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return .failure(XiaozhiToolError(code: "invalid_arguments", message: "the export directory cannot be read yet; wait for the workspace to sync"))
        }
        let prefix = root.path + "/"
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, url.path.hasPrefix(prefix) else { continue }
            let rel = String(url.path.dropFirst(prefix.count))
            guard let source = byPath[rel] else { ignored.append(rel); continue }
            guard let data = try? Data(contentsOf: url), let original = try? FirmwareBuilderSources.read(source) else { continue }
            if data != original {
                total += data.count
                guard total <= maxOverrideBytes else {
                    return .failure(XiaozhiToolError(code: "invalid_arguments", message: "the edited files are larger than 16 MiB in total"))
                }
                overrides[rel] = data; changed.append(rel)
            }
        }
        return .success((overrides, changed.sorted(), ignored.sorted()))
    }

    /// `directory` must be an export directory: `<…>/imports/xiaozhi-src` or `xiaozhi-src-<N>`. Maps the Worker
    /// VFS path to the materialized workspace mirror (`PreviewPathResolver` rules); nil if it is anything else.
    static func materializedDirectory(forWorkspacePath path: String) -> URL? {
        let relative = PreviewPathResolver.normalize(path)
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.contains(".."), parts.count >= 2, parts[parts.count - 2] == "imports",
              parts[parts.count - 1].range(of: #"^xiaozhi-src(-[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        let base = ChatModel.shared.workspaceRoot.appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true).resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(relative, isDirectory: true).resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(base.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return candidate
    }

    // MARK: Status and flash (spec §6.3, §6.4)

    func status(jobID: String?, mac: String) -> Result<XiaozhiStatusSnapshot, XiaozhiToolError> {
        var job: XiaozhiBuildJob?
        if let jobID {
            guard let known = jobs[jobID] else { return .failure(XiaozhiToolError(code: "invalid_arguments", message: "unknown jobId")) }
            job = known
        } else {
            job = latestJobID.flatMap { jobs[$0] }
        }
        return .success(XiaozhiStatusSnapshot(job: job, device: relay.devices.first { $0.mac == mac }, staged: relay.staged(mac: mac),
                                              relayOn: relay.isOn, otaURL: relay.otaURL))
    }

    /// Stages the finished build with this ELF SHA-256 for `mac`. The caller (the SDK tool) has already asked the user.
    func flash(elfSha256: String, mac: String) -> Result<XiaozhiStagedView, XiaozhiToolError> {
        guard relay.isOn else { return .failure(XiaozhiToolError(code: "relay_off", message: "the OTA relay is not listening")) }
        guard let image = builtImages[elfSha256] else {
            return .failure(XiaozhiToolError(code: "no_build", message: "no finished build in this app session has that elfSha256"))
        }
        do { return .success(try relay.stage(mac: mac, image: image, elfSha256: elfSha256)) }
        catch let error as XiaozhiToolError { return .failure(error) }
        catch { return .failure(XiaozhiToolError(code: "relay_off", message: error.localizedDescription)) }
    }

    // MARK: Device Bot trigger (spec §4)

    /// The user tapped 「信任并创建 Bot」 on a recorded device.
    func trust(mac: String) async {
        if let bot = await DeviceBotRegistry.shared.xiaozhiTrusted(mac: mac) {
            trustNote = NativeText("已为 \(mac) 创建 Bot（\(bot)）", "Bot ready for \(mac) (\(bot))")
        } else {
            trustNote = NativeText("没能创建 Bot：Bot 运行时还没就绪", "Could not create the Bot: the Bot runtime is not ready")
        }
    }
}

// MARK: - Page

struct XiaozhiFirmwarePage: View {
    @State private var model = XiaozhiFirmwareModel.shared

    var body: some View {
        List {
            Section {
                Text(NativeText("把使用小智固件（78/xiaozhi-esp32）的板子的 OTA 地址指向这台 iPhone。板子检查更新时先经过手机，手机转发给官方服务器；之后 Bot 可以导出并修改源码、在这台 iPhone 上编译，经你批准后通过 Wi-Fi 刷入。仅 DEBUG 构建。",
                                "Point the OTA URL of a board running the xiaozhi firmware (78/xiaozhi-esp32) at this iPhone. The board's update check goes through the phone, which forwards it to the official server. A Bot can then export and edit the sources, build on this iPhone, and flash over Wi-Fi after you approve. DEBUG builds only."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            relaySection
            TimelineView(.periodic(from: .now, by: 2)) { _ in devicesSection }
            packSection
            if !model.trustNote.isEmpty { Section { Text(model.trustNote).font(.callout) } }
        }
        .navigationTitle(NativeText("小智固件", "Xiaozhi firmware"))
    }

    private var relaySection: some View {
        Section(NativeText("OTA 中继", "OTA relay")) {
            Toggle(NativeText("开启 OTA 中继（端口 8781）", "OTA relay on (port 8781)"),
                   isOn: Binding(get: { model.relay.isOn }, set: { on in Task { await model.relay.setOn(on) } }))
            if let url = model.relay.otaURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NativeText("在板子上填写的 OTA 地址", "OTA URL to type into the board")).font(.caption).foregroundStyle(.secondary)
                    Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            } else {
                Text(NativeText("没有 Wi-Fi IPv4 地址，连上 Wi-Fi 后再来。", "No Wi-Fi IPv4 address; join a Wi-Fi network first."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var devicesSection: some View {
        Section(NativeText("已检查更新的设备", "Devices that checked in")) {
            let devices = model.relay.devices
            if devices.isEmpty {
                Text(NativeText("还没有设备来检查更新。", "No device has checked in yet.")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in deviceRow(device) }
        }
    }

    private func deviceRow(_ device: XiaozhiDeviceView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(device.mac).font(.system(.body, design: .monospaced))
            if let board = device.boardType { LabeledContent(NativeText("板型", "Board"), value: board) }
            LabeledContent(NativeText("版本", "Version"), value: device.version ?? "—")
            LabeledContent("ELF SHA-256", value: device.elfSha256.map { String($0.prefix(12)) + "…" } ?? "—")
            LabeledContent(NativeText("最近一次", "Last check"), value: Self.describe(device))
            if let staged = model.relay.staged(mac: device.mac) {
                LabeledContent(NativeText("已暂存镜像", "Staged image"), value: "ELF " + String(staged.elfSha256.prefix(12)) + "…")
                Text(staged.url).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if DeviceBotRegistry.shared.xiaozhiBotID(mac: device.mac) != nil {
                Label(NativeText("已有 Bot", "Bot exists"), systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button(NativeText("信任并创建 Bot", "Trust and create Bot")) { Task { await model.trust(mac: device.mac) } }
            }
        }
        .padding(.vertical, 2)
    }

    private static func describe(_ device: XiaozhiDeviceView) -> String {
        let decision: String
        switch device.lastDecision {
        case "passthrough": decision = NativeText("原样转发", "passed through")
        case "hold": decision = NativeText("已是暂存镜像", "running the staged image")
        case "offer": decision = NativeText("已提供暂存镜像", "offered the staged image")
        case "upstream_failed": decision = NativeText("官方服务器不可达", "upstream unreachable")
        default: decision = "—"
        }
        guard let seen = device.lastSeen else { return decision }
        return decision + " · " + seen.formatted(.relative(presentation: .named))
    }

    private var packSection: some View {
        Section(NativeText("固件源码与构建", "Sources and build")) {
            switch model.editableSources() {
            case .success(let value):
                LabeledContent(NativeText("可编辑文件", "Editable files"), value: "\(value.files.count)")
                if let root = value.pack.sourcesRoot { Text(root).font(.caption).foregroundStyle(.secondary) }
            case .failure(let error):
                Text(error.message).font(.footnote).foregroundStyle(.secondary)
            }
            if let job = model.latestJobID.flatMap({ model.jobs[$0] }) {
                LabeledContent(NativeText("最近的构建", "Latest build"), value: job.id)
                LabeledContent(NativeText("状态", "State"), value: job.state.rawValue)
                if !job.changed.isEmpty { Text(job.changed.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary) }
                if let image = job.image { LabeledContent("ELF SHA-256", value: String(image.elfSha256.prefix(12)) + "…") }
                if let error = job.error { Text(error.message).font(.footnote).foregroundStyle(.red) }
            }
            NavigationLink(NativeText("固件构建页", "Firmware builder page")) { FirmwareBuilderPage() }
        }
    }
}
#endif
