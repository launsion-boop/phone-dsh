// SPDX-License-Identifier: MIT
// App side of xiaozhi-firmware-v1 Bot tools (spec/device/v1/xiaozhi-firmware.md §6, §7), DEBUG only.
// Parallel to `DeviceAppLiveWiring`; it binds the SDK's `XiaozhiFirmwareToolHost` (Sources/PhoneDSHBot/Xiaozhi)
// to `XiaozhiFirmwareModel`. The device is never taken from model arguments: it is the MAC of the
// `xiaozhi:` key `DeviceBotRegistry` bound to the calling Bot.
//
// Everything that does not need an SDK symbol is implemented and compiles on its own
// (`XiaozhiFirmwareBackend`). The few lines that name SDK types written by the other ends
// (`XiaozhiOTARelayServer`, `XiaozhiStagedImages`, `XiaozhiFirmwareToolHost`,
// `BotMCPRuntime.setXiaozhiFirmwareTools`) sit behind `#if XIAOZHI_SDK` and are marked INTEGRATION:
// the integrator deletes the conditional and reconciles the exact initializers.
#if DEBUG
import Foundation
import PhoneDSHBLE
import PhoneDSHBot

/// What the Bot tools need from the app, in the app's own value types (no SDK type involved). The tool
/// host adapter maps these to the tool JSON of spec §6 and runs the approval for flash itself.
struct XiaozhiFirmwareBackend {
    var export: (_ botID: String) async -> Result<XiaozhiExportResult, XiaozhiToolError>
    var build: (_ directory: String?) async -> Result<XiaozhiBuildJob, XiaozhiToolError>
    var status: (_ jobID: String?, _ mac: String) async -> Result<XiaozhiStatusSnapshot, XiaozhiToolError>
    /// Stages the finished build for the device. Call only after the user approved (spec §6.4).
    var stageImage: (_ elfSha256: String, _ mac: String) async -> Result<XiaozhiStagedView, XiaozhiToolError>
    /// The MAC of the xiaozhi board this Bot is bound to, nil for any other Bot.
    var boundMAC: (_ botID: String) async -> String?
    var relayOn: () async -> Bool
    /// The device record the relay holds for `mac`.
    var deviceRecord: (_ mac: String) async -> XiaozhiDeviceView?

    @MainActor static func live(model: XiaozhiFirmwareModel = .shared) -> XiaozhiFirmwareBackend {
        XiaozhiFirmwareBackend(
            export: { botID in await model.export(botID: botID) },
            build: { directory in await model.startBuild(directory: directory) },
            status: { jobID, mac in await model.status(jobID: jobID, mac: mac) },
            stageImage: { elfSha256, mac in await model.flash(elfSha256: elfSha256, mac: mac) },
            boundMAC: { botID in await MainActor.run { DeviceBotRegistry.shared.xiaozhiMAC(forBot: botID) } },
            relayOn: { await MainActor.run { model.relay.isOn } },
            deviceRecord: { mac in await MainActor.run { model.relay.devices.first { $0.mac == mac } } })
    }
}

@MainActor
enum XiaozhiFirmwareWiring {
    /// Installs the relay adapter and the tool host. A no-op without a staged pack that has `sources_root`
    /// (spec §6: the tools are listed only when the app installed the host).
    static func attach(runtime: BotMCPRuntime) async {
        let model = XiaozhiFirmwareModel.shared
        guard model.hasEditableSources else { return }
        let backend = XiaozhiFirmwareBackend.live(model: model)
        #if XIAOZHI_SDK
        // INTEGRATION (A: Sources/PhoneDSHBLE/Xiaozhi): wrap the SDK relay. The adapter below is the one
        // place that names `XiaozhiOTARelayServer` / `XiaozhiStagedImages`; adjust to their final API.
        if !(model.relay is XiaozhiSDKRelayAdapter) { model.relay = XiaozhiSDKRelayAdapter() }
        // INTEGRATION (B: Sources/PhoneDSHBot/Xiaozhi): build the host from the backend closures and install it.
        // The host owns the JSON of spec §6, the `deviceKey` resolution from the calling Bot and the
        // 「给小智刷入固件」 approval; `backend.stageImage` runs only after that approval.
        await runtime.setXiaozhiFirmwareTools(XiaozhiFirmwareToolHost(
            boundMAC: backend.boundMAC, export: backend.export, build: backend.build,
            status: backend.status, stageImage: backend.stageImage))
        #else
        _ = (runtime, backend)
        #endif
    }
}

#if XIAOZHI_SDK
/// INTEGRATION: `XiaozhiRelayControlling` over the SDK relay (spec §2, §3, §7). Names follow spec §7;
/// the members used here are guesses until the SDK end is merged.
@MainActor @Observable
final class XiaozhiSDKRelayAdapter: XiaozhiRelayControlling {
    private let server = XiaozhiOTARelayServer()
    private let images = XiaozhiStagedImages()

    var isOn: Bool { server.isListening }
    func setOn(_ on: Bool) async { on ? await server.start() : await server.stop() }
    var otaURL: String? { TonoLinkNetworkInfo.wifiIPv4().map { "http://\($0):8781/xiaozhi/ota/" } }
    var devices: [XiaozhiDeviceView] {
        server.records.map {
            XiaozhiDeviceView(mac: $0.mac, version: $0.version, elfSha256: $0.elfSha256, boardType: $0.boardType,
                              lastSeen: $0.lastSeen, lastDecision: $0.lastDecision.rawValue)
        }
    }
    func staged(mac: String) -> XiaozhiStagedView? {
        images.staged(mac: mac).map { XiaozhiStagedView(sha256: $0.sha256, elfSha256: $0.elfSha256, url: $0.url) }
    }
    func stage(mac: String, image: Data, elfSha256: String) throws -> XiaozhiStagedView {
        let staged = try images.stage(mac: mac, image: image, elfSha256: elfSha256)
        return XiaozhiStagedView(sha256: staged.sha256, elfSha256: staged.elfSha256, url: staged.url)
    }
}
#endif
#endif
