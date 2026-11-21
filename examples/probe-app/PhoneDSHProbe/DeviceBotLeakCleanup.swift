// SPDX-License-Identifier: MIT
// DEBUG-only one-shot (never ships): `-pdsh-cleanup-leaked-bots dry|run`.
//
// Removes the "PDSH Passport N" Bots that the device-Bot creation retry loop leaked on 2026-11-17
// (device-bot.md §6, device-bot-v1.2): audit append kept failing, one Bot per 3 s poll. A Bot is a
// candidate only if ALL hold: its name is `^PDSH Passport( \d+)?$`; it was created in
// 2026-11-17T11:47:53Z...12:28:35Z; no key in `deviceBots.v1` is bound to it; it has no event
// besides an optional `teammate.created` row. A fixed deny list is never touched. `dry` writes the
// candidate list and stops; `run` first repeats the dry checks and aborts (deleting nothing) when
// anything looks off, then deletes serially through `composition.deleteBot` with a pause.
// Report: Documents/cleanup-leaked-bots.json
#if DEBUG
import Foundation
import PhoneDSHBot

@MainActor
enum DeviceBotLeakCleanup {
    static let argument = "-pdsh-cleanup-leaked-bots"
    private static var started = false
    /// The user's explicit scope (2026-11-17): every "PDSH Passport( N)" Bot (the 125 leaked ones) plus the
    /// current device Bot "AI Passport" (deleted through the full cascade, then its binding is removed).
    private static let deviceBotID = "agent-4f4446af67849dd9"
    private static let deviceKey = "be8d3c67-f921-403a-8798-e646ccb997d6"
    private static let denied: Set<String> = ["agent-ab1815374b92cb77", "agent-37a5da5e6ef0ca62", "main"]
    private static let maxLeaked = 125

    static func runIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: argument), args.indices.contains(i + 1),
              ["dry", "run"].contains(args[i + 1]), !started else { return }
        started = true
        await execute(delete: args[i + 1] == "run")
    }

    private static func execute(delete: Bool) async {
        var report: [String: Any] = ["mode": delete ? "run" : "dry", "started": ISO8601DateFormatter().string(from: Date())]
        func save() {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: docs.appendingPathComponent("cleanup-leaked-bots.json"), options: .atomic)
        }
        save()
        var waited = 0
        while ChatModel.shared.botRuntime == nil, waited < 180 { try? await Task.sleep(for: .seconds(1)); waited += 1 }
        guard let composition = ChatModel.shared.botRuntime else {
            report["abort"] = "no Bot runtime"; report["done"] = true; save(); return
        }
        await composition.rosterModel.refresh()
        let roster = composition.rosterModel.bots
        report["roster_before"] = roster.count
        let mapStore = DeviceBotMapStore()
        let bound = Set(mapStore.bindings.values)
        report["bound_bots"] = bound.sorted()
        let pattern = try! NSRegularExpression(pattern: "^PDSH Passport( [0-9]+)?$")
        var leaked: [BotProfile] = []
        for bot in roster where !denied.contains(bot.id) && bot.id != deviceBotID {
            let range = NSRange(bot.name.startIndex..., in: bot.name)
            if pattern.firstMatch(in: bot.name, range: range) != nil, !bound.contains(bot.id) { leaked.append(bot) }
        }
        let device = roster.first { $0.id == deviceBotID }
        let candidates = leaked + (device.map { [$0] } ?? [])
        report["leaked_count"] = leaked.count
        report["device_bot"] = device.map { "\($0.id)|\($0.name)" } ?? "missing"
        report["candidates"] = candidates.map { ["id": $0.id, "name": $0.name, "created_ms": $0.createdAt] as [String: Any] }
        report["candidate_count"] = candidates.count
        report["kept_after"] = roster.filter { bot in !candidates.contains { $0.id == bot.id } }.map { "\($0.id)|\($0.name)" }
        var problems: [String] = []
        if leaked.count > maxLeaked { problems.append("more than \(maxLeaked) leaked candidates") }
        if device == nil { problems.append("AI Passport (4f44) missing from roster") }
        if candidates.count >= roster.count { problems.append("every Bot would be deleted") }
        if !roster.contains(where: { $0.id == "agent-ab1815374b92cb77" }) || !roster.contains(where: { $0.id == "agent-37a5da5e6ef0ca62" }) {
            problems.append("a protected Bot is missing")
        }
        report["problems"] = problems
        save()
        guard delete, problems.isEmpty else {
            report["done"] = true; report["deleted"] = 0; save(); return
        }
        // One pass for the leaked profiles: one roster read and one durable write.
        let began = Date()
        var deleted = 0
        var errors: [String] = []
        do {
            let result = try await composition.profileStore.deleteBots(ids: Set(leaked.map(\.id)))
            deleted = result.removed.count
            if !result.unknown.isEmpty { errors.append("unknown: \(result.unknown)") }
        } catch { errors.append("\(error)") }
        report["delete_pass_seconds"] = Date().timeIntervalSince(began)
        save()
        // The device Bot goes through the full product cascade (sessions, memory, grants, caches); its
        // binding and any intent for the board key are removed afterwards so the registry recreates it.
        let deviceBegan = Date()
        do {
            try await composition.deleteBot(deviceBotID)
            deleted += 1
            var bindings = mapStore.bindings, intents = mapStore.intents
            bindings = bindings.filter { $0.value != deviceBotID && $0.key != deviceKey }
            intents[deviceKey] = nil
            mapStore.write(bindings: bindings, intents: intents)
            report["bindings_after"] = bindings
        } catch { errors.append("\(deviceBotID): \(error)") }
        report["device_delete_seconds"] = Date().timeIntervalSince(deviceBegan)
        await composition.rosterModel.refresh()
        report["deleted"] = deleted
        report["errors"] = errors
        report["roster_after"] = composition.rosterModel.bots.count
        report["kept_now"] = composition.rosterModel.bots.map { "\($0.id)|\($0.name)" }
        report["done"] = true
        save()
    }
}
#endif
