// SPDX-License-Identifier: MIT
// One Bot per connected device (spec/device/v1/device-bot.md, device-bot-v1). The key space, the
// name and description templates and the idempotent creation decision live in
// Sources/PhoneDSHBot/DeviceBot and run the shared golden file; this file only decides *when* a
// trigger fires and adapts the Bot host. The binding is phone-local (the shared Bot profile is
// unchanged): a deleted Bot is created again at the next trigger; forgetting the device keeps
// its Bot; a Bot is never found by its name or description.
//
// Triggers wired here (device-bot.md §4):
//   - Link device: identity passed and `tools/list` returned (observed on the device store).
//   - TonoLink board voice link: legacy key `tonolink:<name>` until the board lists tools, then
//     the Link key takes over and the legacy binding moves to it (alias).
// TODO(device-bot-v1 §4, standard GATT): the trigger is "the user turned on a read or alert
//   grant". The app sets `BLEDeviceStore.trustConnectedDevices = true`, which makes read and
//   alert allowed by default on connection, so the stored flags cannot tell a user's turn-on
//   from a bare connection; the only honest hook is the user's action in BluetoothDevicesPage
//   (`store.grant(_:read:alert:)`), outside this file's ownership. Key and templates are ready:
//   DeviceBotKey.gatt, DeviceBotText.gattDescription.
// TODO(device-bot-v1 §4, LAN MCP): the trigger is "the user saved the exact-URL grant and the
//   credential for that endpoint" (MCPSettingsModel's save path), outside this file. Key and
//   templates are ready: DeviceBotKey.lan, DeviceBotText.lanDescription.
import Foundation
import PhoneDSHBLE
import PhoneDSHBot

@MainActor
final class DeviceBotRegistry {
    static let shared = DeviceBotRegistry()

    private let store: DeviceBotMapStore
    private let binder: DeviceBotBinder
    private var watcher: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        let store = DeviceBotMapStore(defaults: defaults)
        self.store = store
        self.binder = DeviceBotBinder(store: store, host: ProbeDeviceBotHost())
    }

    // MARK: Lookups

    func botID(forDevice deviceID: String) -> String? { store.bindings[deviceID.lowercased()] }

    /// Every key bound to this Bot (a board holds its legacy key and its Link key).
    private func keys(forBot botID: String) -> [String] {
        store.bindings.filter { $0.value == botID }.map(\.key).sorted()
    }

    /// The device a Bot manages, if any: its Link key when it has one, else its first key.
    func deviceID(forBot botID: String) -> String? {
        let keys = keys(forBot: botID)
        return keys.first { !$0.contains(":") } ?? keys.first
    }

    /// The device record a Bot manages, when it is known to the device store.
    func device(forBot botID: String) -> BLEDeviceStore.Device? {
        for key in keys(forBot: botID) where !key.contains(":") {
            if let device = BLEDeviceStore.shared.devices.first(where: { $0.linkDeviceID.lowercased() == key })
                ?? BLEDeviceStore.shared.devices.first(where: { $0.linkIdentity == key }) {
                return device
            }
        }
        return nil
    }

    /// The TonoLink board's voice link connects outside the Link device list.
    private(set) var boardName: String?

    func boardConnected(name: String) {
        boardName = name
        trace("board connected \(name) runtime=\(ChatModel.shared.botRuntime != nil)")
        Task { await ensureBoard(name: name) }
    }

    /// The Bot of the TonoLink board the voice link last connected to, if there is one.
    func tonoLinkBotID() -> String? {
        guard let name = boardName else { return nil }
        if let linkKey = boardLinkKey(name: name), let bot = store.bindings[linkKey] { return bot }
        return DeviceBotKey.tonolink(bleName: name).flatMap { store.bindings[$0] }
    }

    /// The board's BLE name when this Bot is a TonoLink board's.
    func boardName(forBot botID: String) -> String? {
        keys(forBot: botID).lazy.compactMap(DeviceBotKey.tonolinkName(inKey:)).first
    }

    private func trace(_ line: String) { TonoLinkVoiceHost.shared.log("device-bot " + line) }

    // MARK: Triggers

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
        guard ChatModel.shared.botRuntime != nil else { return }
        // The board connected before the Bot runtime was up (the app was in the background).
        if let board = boardName { await ensureBoard(name: board) }
        for device in BLEDeviceStore.shared.devices where !device.linkDeviceID.isEmpty && !device.linkTools.isEmpty {
            await ensureLink(device)
        }
    }

    /// Voice link: the Link key when the board already has one (the legacy key is never created
    /// for such a board), otherwise the legacy key.
    private func ensureBoard(name: String) async {
        if let device = BLEDeviceStore.shared.devices.first(where: { $0.name == name && !$0.linkDeviceID.isEmpty && !$0.linkTools.isEmpty }) {
            await ensureLink(device)
            return
        }
        guard let key = DeviceBotKey.tonolink(bleName: name) else { return }
        await run(DeviceBotRequest(key: key, rawName: DeviceBotText.boardName,
                                   description: DeviceBotText.boardDescription))
    }

    // MARK: Explicit-grant triggers (device-bot.md §4). Entry points only; call sites are the
    // user's grant actions in the BLE device page and the MCP settings save path.

    /// Standard GATT: the user turned on a read or alert grant for this peripheral.
    func gattGrantTurnedOn(peripheralUUID: String, name: String, profiles: [String]) {
        guard let key = DeviceBotKey.gatt(peripheralUUID: peripheralUUID) else { return }
        Task { await run(DeviceBotRequest(key: key, rawName: name,
                                          description: DeviceBotText.gattDescription(profiles: profiles))) }
    }

    /// LAN MCP: the user saved the exact-URL grant and the credential for this endpoint.
    func lanGrantSaved(host: String, port: Int, name: String) {
        guard let key = DeviceBotKey.lan(host: host, port: port) else { return }
        Task { await run(DeviceBotRequest(key: key, rawName: name,
                                          description: DeviceBotText.lanDescription(host: host))) }
    }

    private func ensureLink(_ device: BLEDeviceStore.Device) async {
        guard let key = DeviceBotKey.link(deviceID: device.linkDeviceID) else { return }
        let isBoard = TonoLinkPhoneControlSection.applies(to: device.name)
        let request = isBoard
            ? DeviceBotRequest(key: key, rawName: DeviceBotText.boardName, description: DeviceBotText.boardDescription,
                               alias: DeviceBotKey.tonolink(bleName: device.name))
            : DeviceBotRequest(key: key, rawName: device.name,
                               description: DeviceBotText.linkDescription(tools: device.linkTools))
        await run(request)
    }

    private func boardLinkKey(name: String) -> String? {
        BLEDeviceStore.shared.devices.first { $0.name == name && !$0.linkDeviceID.isEmpty && !$0.linkTools.isEmpty }
            .flatMap { DeviceBotKey.link(deviceID: $0.linkDeviceID) }
    }

    private func run(_ request: DeviceBotRequest) async {
        let outcome = await binder.ensure(request)
        switch outcome {
        case .existing, .busy: break
        case .bound(let bot): trace("\(request.key): bound \(bot)")
        case .created(let bot): trace("\(request.key): created \(bot)")
        case .failed(let reason): trace("\(request.key): \(reason)")
        }
    }
}

/// The Bot host of the probe app: roster from the roster model, creation rows from the durable
/// event log, creation through the production composition.
@MainActor
private final class ProbeDeviceBotHost: DeviceBotHost {
    private var composition: BotRuntimeComposition? { ChatModel.shared.botRuntime }

    private struct NoRuntime: Error {}

    func roster() async throws -> [(id: String, name: String)] {
        guard let composition else { throw NoRuntime() }
        return composition.rosterModel.bots.map { ($0.id, $0.name) }
    }

    func createdBots() async throws -> [String: String] {
        guard let composition else { throw NoRuntime() }
        var created: [String: String] = [:]
        for event in try await BotProductionEventReader.all(domain: composition.domain)
        where event.type == "ui.system_event" && event.data["event"]?.stringValue == "teammate.created" {
            if let creationID = event.data["author"]?["creationId"]?.stringValue,
               let bot = event.data["agentId"]?.stringValue {
                created[creationID] = bot
            }
        }
        return created
    }

    func createDeviceBot(name: String, description: String, key: String, creationID: String) async throws -> String {
        guard let composition else { throw NoRuntime() }
        let profile = try await composition.createBot(
            name: name, description: description, color: nil, hairstyle: nil, author: nil)
        // CCR (device-bot-v1 §6): `BotTeammateAuthor` has no device kind, key or creation id, and
        // the audit event is encoded in BotRuntimeComposition. Until the contract owner extends
        // that path, the registry appends the same `teammate.created` row itself, with the author
        // `{kind:"device", key, creationId}`, right after the Bot exists. A kill between the two
        // calls is the documented "intent without a created event" case (device-bot.md §6).
        let eventID = "teammate-created-\(profile.id)"
        let event = BotEvent(
            type: "ui.system_event", eventId: eventID,
            time: botProductionNowMilliseconds(), origin: .local(source: "comm-service"),
            traceId: eventID,
            principal: BotPrincipal(botId: profile.id, sessionId: nil, kind: "team"),
            causationId: nil, correlationId: creationID,
            data: .object([
                "event": .string("teammate.created"),
                "agentId": .string(profile.id),
                "name": .string(profile.name),
                "description": .string(profile.description),
                "author": .object([
                    "kind": .string("device"),
                    "key": .string(key),
                    "creationId": .string(creationID),
                ]),
            ]))
        _ = try await composition.domain.append(event)
        return profile.id
    }
}
