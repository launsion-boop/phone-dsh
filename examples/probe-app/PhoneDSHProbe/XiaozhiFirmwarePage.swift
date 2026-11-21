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

/// One firmware download the relay served (progress UI only).
struct XiaozhiDownloadView: Equatable {
    enum State: Equatable { case sending, complete, aborted }
    var sha256: String
    var sent: Int
    var total: Int
    var startedAt: Date
    var updatedAt: Date
    var state: State
}

/// The on-phone build as the progress UI shows it.
struct XiaozhiBuildProgress: Equatable {
    enum Phase: Equatable { case preparing, compiling(done: Int, total: Int), linking }
    var jobID: String
    var phase: Phase
    var startedAt: Date?

    /// 0…1; compile is 90 % of the bar, link the rest.
    var fraction: Double? {
        switch phase {
        case .preparing: return nil
        case .compiling(let done, let total): return total > 0 ? 0.9 * Double(done) / Double(total) : nil
        case .linking: return 0.95
        }
    }
}

/// Where a flash stands for one device, from what the relay saw after the image was staged
/// (spec §2.4: offer → download → reboot → hold). Derived only; nothing here changes a response.
enum XiaozhiFlashPhase: Equatable {
    /// Staged; the board has not checked for updates since. It checks at boot.
    case waitingForReboot
    /// The relay offered the image; the board has not started the download yet.
    case offered
    case downloading(sent: Int, total: Int)
    /// The download stalled: no bytes taken for `stallAfter`.
    case stalled(sent: Int, total: Int)
    /// All bytes sent; the board is writing, verifying and rebooting.
    case installing
    /// The board checked in running the staged ELF.
    case done
    /// The download broke off, or the board came back on another ELF after a full download.
    case failed(String)

    var isActive: Bool {
        switch self {
        case .done, .failed: return false
        default: return true
        }
    }
}

struct XiaozhiFlashProgress: Equatable {
    var mac: String
    var elfSha256: String
    var stagedAt: Date
    var phase: XiaozhiFlashPhase
    /// When the phase was last confirmed (staging, the last check-in or the last bytes sent).
    var updatedAt: Date

    static let stallAfter: TimeInterval = 20

    /// Pure: the phase from the staging time, the device record and the latest download.
    static func resolve(mac: String, staged: XiaozhiStagedView, stagedAt: Date, device: XiaozhiDeviceView?,
                        download: XiaozhiDownloadView?, now: Date) -> XiaozhiFlashProgress {
        func make(_ phase: XiaozhiFlashPhase, _ at: Date) -> XiaozhiFlashProgress {
            XiaozhiFlashProgress(mac: mac, elfSha256: staged.elfSha256, stagedAt: stagedAt, phase: phase, updatedAt: at)
        }
        let seen = device?.lastSeen.flatMap { $0 >= stagedAt ? $0 : nil }
        let transfer = download.flatMap { $0.sha256 == staged.sha256 && $0.startedAt >= stagedAt ? $0 : nil }
        // A check-in on the staged ELF after staging is the only proof the flash took.
        if let seen, device?.elfSha256 == staged.elfSha256 { return make(.done, seen) }
        if let transfer {
            switch transfer.state {
            case .aborted:
                if let seen, seen > transfer.updatedAt, device?.lastDecision == "offer" {
                    return make(.offered, seen) // the board asks again and will retry
                }
                return make(.failed(NativeText("下载中断（\(Self.percent(transfer.sent, transfer.total))），重启小智会重试",
                                               "Download broke off at \(Self.percent(transfer.sent, transfer.total)); restart the board to retry")),
                            transfer.updatedAt)
            case .sending:
                if now.timeIntervalSince(transfer.updatedAt) > stallAfter {
                    return make(.stalled(sent: transfer.sent, total: transfer.total), transfer.updatedAt)
                }
                return make(.downloading(sent: transfer.sent, total: transfer.total), transfer.updatedAt)
            case .complete:
                if let seen, seen > transfer.updatedAt {
                    // Back after a full download but not on the staged ELF: the board rejected the image.
                    return make(.failed(NativeText("小智下载完后没有换上新固件（仍在跑 \(device?.elfSha256.map { String($0.prefix(8)) } ?? "旧固件")）",
                                                   "The board downloaded the image but did not switch to it")), seen)
                }
                return make(.installing, transfer.updatedAt)
            }
        }
        if let seen, device?.lastDecision == "offer" { return make(.offered, seen) }
        return make(.waitingForReboot, stagedAt)
    }

    static func percent(_ sent: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(sent) / Double(total) * 100).rounded(.down)))%"
    }
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
    /// The latest firmware download the relay served for `mac` (progress UI only).
    func download(mac: String) -> XiaozhiDownloadView?
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
    func download(mac: String) -> XiaozhiDownloadView? { nil }
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
    /// When each job finished, so the chat strip can fade a finished build out.
    private(set) var finishedAt: [String: Date] = [:]
    /// Last message of the trust action, shown on the page.
    private(set) var trustNote = ""
    @ObservationIgnored private var builtImages: [String: Data] = [:]
    /// When each MAC's current image was staged (spec §6.4), the start of its flash timeline.
    private(set) var stagedAt: [String: Date] = [:]
    /// Flash timelines the user closed in the chat strip, by MAC → the staging time they closed.
    private(set) var dismissedFlash: [String: Date] = [:]
    /// The build job the user closed in the chat strip.
    private(set) var dismissedJobID: String?
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

    /// Device-test hook (spec §8): installs the SDK relay if needed and switches it on, so a board or a
    /// Wi-Fi test client can reach `http://<Wi-Fi IPv4>:8781/xiaozhi/ota/` without the page UI.
    func startRelayForDiagnostics() async {
        guard hasEditableSources else { return }
        if !(relay is XiaozhiSDKRelayAdapter) { relay = XiaozhiSDKRelayAdapter() }
        await relay.setOn(true)
    }

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
        finishedAt[id] = Date()
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
        do {
            let staged = try relay.stage(mac: mac, image: image, elfSha256: elfSha256)
            stagedAt[mac] = Date()
            return .success(staged)
        }
        catch let error as XiaozhiToolError { return .failure(error) }
        catch { return .failure(XiaozhiToolError(code: "relay_off", message: error.localizedDescription)) }
    }

    // MARK: Progress (UI only)

    /// The running build with the builder's live compile counters; nil when no Bot build runs.
    var buildProgress: XiaozhiBuildProgress? {
        guard let job = runningJob else { return nil }
        let phase: XiaozhiBuildProgress.Phase
        switch builder.stage {
        case "compile" where builder.total > 0: phase = .compiling(done: builder.done, total: builder.total)
        case "link": phase = .linking
        default: phase = .preparing
        }
        return XiaozhiBuildProgress(jobID: job.id, phase: phase, startedAt: builder.startedAt)
    }

    /// The flash timeline of `mac` since its image was staged in this app session.
    func flashProgress(mac: String, now: Date = Date()) -> XiaozhiFlashProgress? {
        guard let staged = relay.staged(mac: mac), let at = stagedAt[mac] else { return nil }
        return XiaozhiFlashProgress.resolve(mac: mac, staged: staged, stagedAt: at,
                                            device: relay.devices.first { $0.mac == mac },
                                            download: relay.download(mac: mac), now: now)
    }

    /// The latest job if the chat strip should still show it: running, or finished within 2 minutes.
    func stripJob(now: Date = Date()) -> XiaozhiBuildJob? {
        guard let job = job(id: nil), job.id != dismissedJobID else { return nil }
        if job.state == .running { return job }
        guard let finished = finishedAt[job.id], now.timeIntervalSince(finished) < 120 else { return nil }
        return job
    }

    /// The flash timeline if the chat strip should still show it: active, done within 2 minutes or
    /// failed within 10 minutes, and not closed by the user.
    func stripFlash(mac: String, now: Date = Date()) -> XiaozhiFlashProgress? {
        guard let progress = flashProgress(mac: mac, now: now), dismissedFlash[mac] != progress.stagedAt else { return nil }
        switch progress.phase {
        case .done: return now.timeIntervalSince(progress.updatedAt) < 120 ? progress : nil
        case .failed: return now.timeIntervalSince(progress.updatedAt) < 600 ? progress : nil
        default: return progress
        }
    }

    func dismissStrip(mac: String?) {
        if let job = job(id: nil), job.state != .running { dismissedJobID = job.id }
        if let mac, let at = stagedAt[mac], flashProgress(mac: mac)?.phase.isActive == false { dismissedFlash[mac] = at }
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
            TimelineView(.periodic(from: .now, by: 1)) { _ in devicesSection }
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
            if let progress = model.flashProgress(mac: device.mac) {
                XiaozhiProgressContent.flash(progress, now: Date())
            }
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
            if let progress = model.buildProgress {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    XiaozhiProgressContent.build(progress, now: context.date)
                }
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

// MARK: - Progress views (UI only; the chat strip and the page share them)

enum XiaozhiProgressText {
    static func elapsed(since start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// One progress row: icon, title, trailing figure, an optional bar and a hint line.
struct XiaozhiProgressContent: View {
    var icon: String
    var tint: Color
    var title: String
    var trailing: String?
    /// nil: no bar; .some(nil): indeterminate bar.
    var bar: Double??
    var hint: String?
    var steps: (current: Int, failed: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let bar {
                if let value = bar {
                    ProgressView(value: min(1, max(0, value))).tint(tint)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(tint)
                }
            }
            if let steps { XiaozhiFlashSteps(current: steps.current, failed: steps.failed) }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 放出 → 下载 → 安装 → 完成, the four checkpoints the relay can see.
struct XiaozhiFlashSteps: View {
    static let labels = [NativeText("放出", "Staged"), NativeText("下载", "Download"),
                         NativeText("安装", "Install"), NativeText("完成", "Done")]
    var current: Int
    var failed: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.labels.enumerated()), id: \.offset) { index, label in
                let reached = index < current || (index == current && !failed && current == Self.labels.count - 1)
                let here = index == current
                HStack(spacing: 3) {
                    Image(systemName: reached ? "checkmark.circle.fill"
                          : (here ? (failed ? "xmark.circle.fill" : "circle.dotted") : "circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(reached ? Color.green : (here ? (failed ? Color.red : Color.accentColor) : Color.secondary.opacity(0.5)))
                    Text(label).font(.caption2)
                        .foregroundStyle(here || reached ? Color.primary : Color.secondary)
                }
                if index < Self.labels.count - 1 {
                    Rectangle().fill(index < current ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25))
                        .frame(height: 1).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

extension XiaozhiProgressContent {
    static func build(_ progress: XiaozhiBuildProgress, now: Date) -> XiaozhiProgressContent {
        let title: String
        switch progress.phase {
        case .preparing: title = NativeText("准备编译固件…", "Preparing the build…")
        case .compiling(let done, let total): title = NativeText("编译固件 \(done)/\(total)", "Compiling \(done)/\(total)")
        case .linking: title = NativeText("链接固件…", "Linking…")
        }
        return XiaozhiProgressContent(icon: "hammer.fill", tint: .accentColor, title: title,
                                      trailing: XiaozhiProgressText.elapsed(since: progress.startedAt, now: now),
                                      bar: .some(progress.fraction),
                                      hint: NativeText("在这台 iPhone 上编译，通常几分钟；请保持应用在前台。",
                                                       "Building on this iPhone, usually a few minutes; keep the app in the foreground."))
    }

    static func finished(_ job: XiaozhiBuildJob, seconds: Double?) -> XiaozhiProgressContent {
        let time = seconds.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) }
        if job.state == .failed {
            return XiaozhiProgressContent(icon: "exclamationmark.triangle.fill", tint: .red,
                                          title: NativeText("编译失败", "Build failed"), trailing: time, bar: nil,
                                          hint: job.error?.message)
        }
        return XiaozhiProgressContent(icon: "checkmark.seal.fill", tint: .green,
                                      title: NativeText("编译完成", "Build finished"), trailing: time, bar: nil,
                                      hint: job.image.map { NativeText("固件 \(XiaozhiProgressText.bytes($0.bytes)) · ELF \($0.elfSha256.prefix(8))，确认后即可刷入",
                                                                       "Image \(XiaozhiProgressText.bytes($0.bytes)) · ELF \($0.elfSha256.prefix(8)); ready to flash after you approve") })
    }

    static func flash(_ progress: XiaozhiFlashProgress, now: Date) -> XiaozhiProgressContent {
        let elapsed = XiaozhiProgressText.elapsed(since: progress.stagedAt, now: now)
        switch progress.phase {
        case .waitingForReboot:
            return XiaozhiProgressContent(icon: "arrow.clockwise.circle.fill", tint: .orange,
                                          title: NativeText("固件已放出，等小智重启", "Image staged; restart the board"),
                                          trailing: elapsed, bar: nil,
                                          hint: NativeText("按复位键或断电重开小智，它开机检查更新时会自动下载。",
                                                           "Press reset or power-cycle the board; it downloads the image when it checks for updates at boot."),
                                          steps: (0, false))
        case .offered:
            return XiaozhiProgressContent(icon: "arrow.down.circle", tint: .accentColor,
                                          title: NativeText("小智收到更新，准备下载", "The board got the update; starting the download"),
                                          trailing: elapsed, bar: .some(nil), hint: nil, steps: (1, false))
        case .downloading(let sent, let total):
            return XiaozhiProgressContent(icon: "arrow.down.circle.fill", tint: .accentColor,
                                          title: NativeText("小智下载中 \(XiaozhiFlashProgress.percent(sent, total))",
                                                            "Downloading \(XiaozhiFlashProgress.percent(sent, total))"),
                                          trailing: "\(XiaozhiProgressText.bytes(sent)) / \(XiaozhiProgressText.bytes(total))",
                                          bar: .some(total > 0 ? Double(sent) / Double(total) : nil),
                                          hint: NativeText("下载期间别给小智断电。", "Do not power off the board while it downloads."),
                                          steps: (1, false))
        case .stalled(let sent, let total):
            return XiaozhiProgressContent(icon: "pause.circle.fill", tint: .orange,
                                          title: NativeText("下载停住了 \(XiaozhiFlashProgress.percent(sent, total))",
                                                            "Download stalled at \(XiaozhiFlashProgress.percent(sent, total))"),
                                          trailing: "\(XiaozhiProgressText.bytes(sent)) / \(XiaozhiProgressText.bytes(total))",
                                          bar: .some(total > 0 ? Double(sent) / Double(total) : nil),
                                          hint: NativeText("确认小智和手机在同一个 Wi-Fi，信号够好；断了的话重启小智会重试。",
                                                           "Check the board and the phone share a Wi-Fi with good signal; restarting the board retries."),
                                          steps: (1, true))
        case .installing:
            return XiaozhiProgressContent(icon: "cpu.fill", tint: .accentColor,
                                          title: NativeText("下载完成，小智正在写入并重启", "Downloaded; the board is writing and rebooting"),
                                          trailing: elapsed, bar: .some(nil),
                                          hint: NativeText("一般几十秒；它重新上线时会自动确认新固件。",
                                                           "Usually under a minute; the new firmware is confirmed when it checks in again."),
                                          steps: (2, false))
        case .done:
            return XiaozhiProgressContent(icon: "checkmark.seal.fill", tint: .green,
                                          title: NativeText("刷入成功，小智已在运行新固件", "Flashed; the board runs the new firmware"),
                                          trailing: elapsed, bar: nil,
                                          hint: "ELF \(progress.elfSha256.prefix(12))", steps: (3, false))
        case .failed(let reason):
            return XiaozhiProgressContent(icon: "exclamationmark.triangle.fill", tint: .red,
                                          title: NativeText("刷入没有完成", "The flash did not finish"),
                                          trailing: elapsed, bar: nil, hint: reason, steps: (2, true))
        }
    }
}

/// Where `BotChatPage` puts the strip: directly below the transcript, above the activity band. Only a
/// Bot bound to a `xiaozhi:` key gets one; every other Bot's page is unchanged.
struct XiaozhiChatProgressSlot: ViewModifier {
    let botID: String

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            if let mac = DeviceBotRegistry.shared.xiaozhiMAC(forBot: botID) {
                XiaozhiChatProgressStrip(mac: mac)
            }
        }
    }
}

/// Pinned above the composer in a `xiaozhi:` device Bot's chat while a build or a flash is under way, and
/// briefly after it ends, so the user sees compile counters and the board's download without asking the
/// Bot. The relay is not observable, so the strip re-reads it once a second while it is on screen.
struct XiaozhiChatProgressStrip: View {
    let mac: String
    @State private var model = XiaozhiFirmwareModel.shared
    @State private var builder = FirmwareBuilderModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let content = content(now: context.date) {
                HStack(alignment: .top, spacing: 8) {
                    content.0
                    if content.1 {
                        Button { model.dismissStrip(mac: mac) } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(HomeSpec.textTertiary).frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NativeText("关闭进度", "Close progress"))
                        .accessibilityIdentifier("bot.xiaozhi.progress.close")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(HomeSpec.borderList, lineWidth: 0.5))
                .padding(.horizontal, HomeSpec.contentInset)
                .padding(.top, 6)
                .accessibilityIdentifier("bot.xiaozhi.progress")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.runningJob?.id)
    }

    /// The row to show and whether it can be closed (only once nothing is in progress).
    private func content(now: Date) -> (XiaozhiProgressContent, Bool)? {
        if let build = model.buildProgress { return (.build(build, now: now), false) }
        let flash = model.stripFlash(mac: mac, now: now)
        if let flash, flash.phase.isActive { return (.flash(flash, now: now), false) }
        // A finished build is shown only until an image of it is staged.
        if let job = model.stripJob(now: now), job.state != .running,
           flash == nil || (model.finishedAt[job.id] ?? .distantPast) > (flash?.stagedAt ?? .distantPast) {
            return (.finished(job, seconds: builder.seconds), true)
        }
        if let flash { return (.flash(flash, now: now), true) }
        return nil
    }
}

/// Headless end-to-end hook (spec §8): `PDSH_XIAOZHI_E2E=<mac>` starts the relay, creates the device Bot,
/// builds the reference firmware on the phone and stages it for `<mac>` on the relay — the whole phone side
/// of a flash, minus the UI approval. Writes Documents/xiaozhi-e2e.json. A Wi-Fi client (or the board) then
/// sees an `offer` from the relay and downloads the image. Used by the device E2E; never in Release.
@MainActor enum XiaozhiE2EDiagnostics {
    static let environmentKey = "PDSH_XIAOZHI_E2E"

    static func run(mac: String) async {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xiaozhi-e2e.json")
        var report: [String: Any] = ["mac": mac, "status": "running"]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) } }
        save()
        try? await Task.sleep(for: .seconds(2))
        let model = XiaozhiFirmwareModel.shared
        await model.startRelayForDiagnostics()
        report["relay_on"] = model.relay.isOn
        report["ota_url"] = model.relay.otaURL as Any
        guard model.relay.isOn else { report["status"] = "failed"; report["error"] = "relay not listening (no Wi-Fi?)"; save(); return }
        let botID = await DeviceBotRegistry.shared.xiaozhiTrusted(mac: mac)
        report["bot_id"] = botID as Any
        guard botID != nil else { report["status"] = "failed"; report["error"] = "could not create the device Bot (bad MAC or runtime not ready)"; save(); return }

        // Edit mode: append a comment to the first editable C/C++ source so the build's ELF differs from the
        // board's current firmware (the relay then offers it instead of holding). A comment is a safe no-op.
        var overrides: [String: Data] = [:]
        if ProcessInfo.processInfo.environment["PDSH_XIAOZHI_E2E_EDIT"] != nil {
            switch model.editableSources() {
            case .failure(let error): report["status"] = "failed"; report["error"] = "edit: \(error.code) \(error.message)"; save(); return
            case .success(let value):
                guard let target = value.files.first(where: { $0.relativePath.hasSuffix(".cc") || $0.relativePath.hasSuffix(".c") }),
                      let original = try? FirmwareBuilderSources.read(target) else {
                    report["status"] = "failed"; report["error"] = "edit: no editable C/C++ source"; save(); return
                }
                // Prepend, so every code line below shifts: the debug line table changes and the ELF digest
                // differs from the board's current firmware (a trailing comment leaves the ELF byte-identical).
                let marker = "// phoneDSH xiaozhi OTA e2e \(Int(Date().timeIntervalSince1970))\n"
                overrides[target.relativePath] = Data(marker.utf8) + original
                report["edited_file"] = target.relativePath
            }
        }

        report["status"] = "building"; save()
        let builder = FirmwareBuilderModel.shared
        let ok = await builder.build(overrides: overrides)
        guard ok, let image = builder.image else {
            report["status"] = "failed"; report["error"] = "build failed: \(builder.result)"; report["build"] = builder.report; save(); return
        }
        report["image"] = ["bytes": image.data.count, "sha256": builder.imageSHA256, "elf_sha256": image.elfSHA256,
                           "version": image.version, "matches_reference": builder.matchesReference as Any]
        report["status"] = "staging"; save()
        do {
            let staged = try model.relay.stage(mac: mac, image: image.data, elfSha256: image.elfSHA256)
            report["staged"] = ["sha256": staged.sha256, "elf_sha256": staged.elfSha256, "url": staged.url]
            report["status"] = "passed"; save()
        } catch {
            report["status"] = "failed"; report["error"] = "stage: \(error.localizedDescription)"; save()
        }
    }
}
#endif

#if !DEBUG
import SwiftUI

/// Release builds have no xiaozhi firmware feature: the Bot page slot is a no-op.
struct XiaozhiChatProgressSlot: ViewModifier {
    let botID: String
    func body(content: Content) -> some View { content }
}
#endif
