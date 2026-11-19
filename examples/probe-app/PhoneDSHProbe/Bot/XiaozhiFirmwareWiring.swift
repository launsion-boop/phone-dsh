// SPDX-License-Identifier: MIT
// App side of xiaozhi-firmware-v1 Bot tools (spec/device/v1/xiaozhi-firmware.md §6, §7), DEBUG only.
// Parallel to `DeviceAppLiveWiring`. It drives the SDK's `XiaozhiFirmwareToolHost` (Sources/PhoneDSHBot,
// which owns the tool JSON, the device binding and the Flash approval) from `XiaozhiFirmwareModel`
// (the app's relay + on-phone builder), and installs the SDK OTA relay (Sources/PhoneDSHBLE) behind the
// app's `XiaozhiRelayControlling` protocol. The device is never taken from model arguments: the host
// resolves the `xiaozhi:` key of the calling Bot through `DeviceBotRegistry`.
#if DEBUG
import Foundation
import PhoneDSHBLE
import PhoneDSHBot

/// `XiaozhiRelayControlling` backed by the SDK relay server (spec §2, §3, §7): one NWListener on
/// port 8781, the device records it keeps and the per-MAC staged images.
@MainActor final class XiaozhiSDKRelayAdapter: XiaozhiRelayControlling {
    private let server = XiaozhiOTARelayServer(relay: XiaozhiOTARelay())

    var isOn: Bool { server.isRunning }

    func setOn(_ on: Bool) async {
        if on { try? server.start() } else { server.stop() }
    }

    var otaURL: String? {
        TonoLinkNetworkInfo.wifiIPv4().map { "http://\($0):\(XiaozhiOTARelay.port)/xiaozhi/ota/" }
    }

    var devices: [XiaozhiDeviceView] {
        server.records.all.map {
            XiaozhiDeviceView(mac: $0.mac, version: $0.version, elfSha256: $0.elfSha256,
                              boardType: $0.boardType, lastSeen: $0.lastSeen, lastDecision: $0.lastDecision.rawValue)
        }
    }

    func staged(mac: String) -> XiaozhiStagedView? {
        server.images.staged(forMAC: mac).map(Self.view)
    }

    func stage(mac: String, image: Data, elfSha256: String) throws -> XiaozhiStagedView {
        guard let staged = server.images.stage(mac: mac, imageData: image, elfSha256: elfSha256) else {
            throw XiaozhiToolError(code: "relay_off", message: "could not stage the image (mac or elf not canonical)")
        }
        return Self.view(staged)
    }

    func download(mac: String) -> XiaozhiDownloadView? {
        server.downloads.latest(forMAC: mac).map {
            let state: XiaozhiDownloadView.State
            switch $0.state {
            case .sending: state = .sending
            case .complete: state = .complete
            case .aborted: state = .aborted
            }
            return XiaozhiDownloadView(sha256: $0.sha256, sent: $0.sent, total: $0.total,
                                       startedAt: $0.startedAt, updatedAt: $0.updatedAt, state: state)
        }
    }

    /// The firmware download URL (spec §2.5) the board is told to fetch.
    private static func view(_ staged: PhoneDSHBLE.XiaozhiStagedImage) -> XiaozhiStagedView {
        let url = TonoLinkNetworkInfo.wifiIPv4().map { "http://\($0):\(XiaozhiOTARelay.port)/xiaozhi/firmware/\(staged.sha256).bin" } ?? ""
        return XiaozhiStagedView(sha256: staged.sha256, elfSha256: staged.elfSha256, url: url)
    }
}

@MainActor
enum XiaozhiFirmwareWiring {
    /// Installs the SDK relay adapter into the model and the four Bot tools into the runtime. A no-op
    /// without a staged pack that has `sources_root` (spec §6: the tools are listed only when the host
    /// is installed), so a build with the old TonoLink-only pack registers nothing.
    static func attach(runtime: BotMCPRuntime) async {
        let model = XiaozhiFirmwareModel.shared
        guard model.hasEditableSources else { return }
        if !(model.relay is XiaozhiSDKRelayAdapter) { model.relay = XiaozhiSDKRelayAdapter() }
        await runtime.setXiaozhiFirmwareTools(Self.makeHost(model: model))
    }

    /// Builds the SDK tool host from the app model. Each closure hops to the main actor to touch the
    /// `@MainActor` model, then maps the app's value types to the SDK's (spec §7).
    static func makeHost(model: XiaozhiFirmwareModel) -> XiaozhiFirmwareToolHost {
        XiaozhiFirmwareToolHost(
            deviceKey: { botID in
                await MainActor.run { DeviceBotRegistry.shared.xiaozhiMAC(forBot: botID).flatMap(DeviceBotKey.xiaozhi) }
            },
            exportSources: { request in
                let result = await model.export(botID: request.principal.botId)
                switch result {
                case .success(let value):
                    return .exported(directory: value.directory, files: value.files, bytes: value.bytes,
                                     project: value.project, target: value.target)
                case .failure(let error):
                    return .failed(code: error.code == "no_editable_sources" ? "no_editable_sources" : "export_failed",
                                   message: error.message)
                }
            },
            startBuild: { request in
                let started = await MainActor.run { model.beginBuild(directory: request.directory) }
                switch started {
                case .success(let job): return .started(Self.job(job))
                case .failure(let error):
                    if error.code == "busy" { return .busy(jobId: error.jobID ?? "") }
                    return .failed(code: error.code, message: error.message)
                }
            },
            pollBuild: { jobID in
                await MainActor.run { model.job(id: jobID).map(Self.job) }
            },
            deviceRecord: { mac in
                await MainActor.run {
                    model.relay.devices.first { $0.mac == mac }.map {
                        XiaozhiDeviceRecord(mac: $0.mac, version: $0.version, elfSha256: $0.elfSha256,
                                            lastSeen: $0.lastSeen, lastDecision: $0.lastDecision)
                    }
                }
            },
            stagedImage: { mac in
                await MainActor.run {
                    model.relay.staged(mac: mac).map {
                        PhoneDSHBot.XiaozhiStagedImage(sha256: $0.sha256, elfSha256: $0.elfSha256, url: $0.url)
                    }
                }
            },
            relayState: {
                await MainActor.run { XiaozhiRelayState(on: model.relay.isOn, otaURL: model.relay.otaURL) }
            },
            buildExists: { elf in
                await MainActor.run { model.hasBuiltImage(elfSha256: elf) }
            },
            stageImage: { request in
                let result = await MainActor.run { model.flash(elfSha256: request.elfSha256, mac: request.mac) }
                switch result {
                case .success(let view):
                    return .staged(PhoneDSHBot.XiaozhiStagedImage(sha256: view.sha256, elfSha256: view.elfSha256, url: view.url))
                case .failure(let error):
                    switch error.code {
                    case "no_build": return .noBuild
                    case "relay_off": return .relayOff
                    default: return .failed(code: error.code, message: error.message)
                    }
                }
            })
    }

    /// Maps the app's build job to the SDK's (spec §6.2). Pure; callable from the @Sendable closures.
    private nonisolated static func job(_ j: XiaozhiBuildJob) -> PhoneDSHBot.XiaozhiBuildJob {
        let state: XiaozhiJobState = j.state == .done ? .done : (j.state == .failed ? .failed : .running)
        let image = j.image.map {
            XiaozhiImageInfo(bytes: $0.bytes, sha256: $0.sha256, elfSha256: $0.elfSha256,
                             version: $0.version, matchesReference: $0.matchesReference ?? false)
        }
        return PhoneDSHBot.XiaozhiBuildJob(jobId: j.id, state: state, changed: j.changed,
                                           ignored: j.ignored, error: j.error?.message, image: image)
    }
}
#endif
