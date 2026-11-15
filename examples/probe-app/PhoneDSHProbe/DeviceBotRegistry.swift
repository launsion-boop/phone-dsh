// SPDX-License-Identifier: MIT
// One Bot per connected device (tonolink-board.md §4.1, device-panel.md §4.3): when a device
// first finishes its Link handshake and lists its tools, the phone creates a Bot for it and
// remembers the pair here. The binding is phone-local (the shared Bot profile is unchanged): a
// deleted Bot is created again at the next connection; forgetting the device keeps its Bot.
import Foundation
import PhoneDSHBLE
import PhoneDSHBot

@MainActor
final class DeviceBotRegistry {
    static let shared = DeviceBotRegistry()

    private let defaults: UserDefaults
    private static let key = "deviceBots.v1"   // [Link device id: Bot id]
    private var creating: Set<String> = []
    private var watcher: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var bindings: [String: String] {
        get { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }
        set {
            defaults.set(newValue, forKey: Self.key)
            defaults.synchronize()   // a killed app must not forget the pair and create a second Bot
        }
    }

    func botID(forDevice deviceID: String) -> String? { bindings[deviceID.lowercased()] }

    /// The device a Bot manages, if any.
    func deviceID(forBot botID: String) -> String? { bindings.first { $0.value == botID }?.key }

    /// The device record a Bot manages, when it is known to the device store.
    func device(forBot botID: String) -> BLEDeviceStore.Device? {
        guard let deviceID = deviceID(forBot: botID) else { return nil }
        return BLEDeviceStore.shared.devices.first { $0.linkDeviceID.lowercased() == deviceID }
            ?? BLEDeviceStore.shared.devices.first { $0.linkIdentity == deviceID }
    }

    /// The TonoLink board's voice link connects outside the Link device list, so its Bot is keyed
    /// by the board's BLE name (`tonolink:PhoneAgent-xxxx`) and created when that link comes up.
    private(set) var boardName: String?
    static func boardKey(_ name: String) -> String { "tonolink:" + name.lowercased() }

    func boardConnected(name: String) {
        boardName = name
        trace("board connected \(name) runtime=\(ChatModel.shared.botRuntime != nil)")
        Task { await ensureBot(key: Self.boardKey(name), name: "手机助手", description: Self.boardDescription(name)) }
    }

    /// The Bot of the TonoLink board the voice link last connected to, if there is one.
    func tonoLinkBotID() -> String? { boardName.flatMap { botID(forDevice: Self.boardKey($0)) } }

    /// The board's BLE name when this Bot is a TonoLink board's.
    func boardName(forBot botID: String) -> String? {
        guard let key = deviceID(forBot: botID), key.hasPrefix("tonolink:") else { return nil }
        return String(key.dropFirst("tonolink:".count))
    }

    private func trace(_ line: String) { TonoLinkVoiceHost.shared.log("device-bot " + line) }

    private func ensureBot(key: String, name: String, description: String) async {
        guard let composition = ChatModel.shared.botRuntime else { trace("\(key): no Bot runtime yet"); return }
        // The roster model the Bot page shows: the profile store's actor can wait on the engine.
        let bots = composition.rosterModel.bots
        if let bound = bindings[key], bots.contains(where: { $0.id == bound }) { return }
        // A Bot made for this device earlier (its pair was lost): bind it instead of a second one.
        if let existing = bots.first(where: { $0.name == name && $0.description == description }) {
            var updated = bindings
            updated[key] = existing.id
            bindings = updated
            trace("\(key): bound existing \(existing.id)")
            return
        }
        guard !creating.contains(key) else { return }
        creating.insert(key)
        defer { creating.remove(key) }
        trace("\(key): creating \(name) (bots=\(bots.count))")
        do {
            let profile = try await composition.createBot(name: name, description: description, color: nil, hairstyle: nil)
            var updated = bindings
            updated[key] = profile.id
            bindings = updated
            trace("\(key): created \(profile.id) \(name)")
        } catch {
            trace("\(key): create \(name) failed: \(error)")
        }
    }

    static func boardDescription(_ name: String) -> String {
        "通过小智 Link（\(name)）帮你操作这台 iPhone：打开 App、点按、输入、看屏幕，也能调板子的灯效。对板子说「你好小智」就会找我。"
    }

    /// Watches the device list while the app runs; creates a Bot for each Link device without one.
    func start() {
        guard watcher == nil else { return }
        trace("watcher started")
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.createMissingBots()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func createMissingBots() async {
        guard let composition = ChatModel.shared.botRuntime else { return }
        let alive = Set(composition.rosterModel.bots.map(\.id))
        // The board connected before the Bot runtime was up (the app was in the background).
        if let board = boardName, !(bindings[Self.boardKey(board)].map(alive.contains) ?? false) {
            await ensureBot(key: Self.boardKey(board), name: "手机助手", description: Self.boardDescription(board))
        }
        for device in BLEDeviceStore.shared.devices where !device.linkDeviceID.isEmpty && !device.linkTools.isEmpty {
            // The TonoLink board has its Bot from the voice link (boardConnected).
            if TonoLinkPhoneControlSection.applies(to: device.name) { continue }
            let key = device.linkDeviceID.lowercased()
            if let bound = bindings[key], alive.contains(bound) { continue }
            await ensureBot(key: key, name: Self.botName(for: device), description: Self.description(for: device))
        }
    }

    static func botName(for device: BLEDeviceStore.Device) -> String {
        if TonoLinkPhoneControlSection.applies(to: device.name) { return "手机助手" }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? "设备助手" : name).prefix(60))
    }

    static func description(for device: BLEDeviceStore.Device) -> String {
        if TonoLinkPhoneControlSection.applies(to: device.name) {
            return "通过小智 Link（\(device.name)）帮你操作这台 iPhone：打开 App、点按、输入、看屏幕，也能调板子的灯效。对板子说「你好小智」就会找我。"
        }
        let tools = device.linkTools.prefix(8).joined(separator: "、")
        return "管理设备「\(device.name)」。它能用的工具：\(tools)。"
    }
}
