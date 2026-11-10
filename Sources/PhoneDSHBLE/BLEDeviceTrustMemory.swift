// SPDX-License-Identifier: MIT
import Foundation

/// What the user decided about boards they connected (ble-link.md, "Trusted connected devices").
///
/// Connecting a board in the app is the trust decision: everything it offers is allowed by
/// default, and only the user's revocations are stored, so a switch turned off stays off across
/// reconnects. Link tools are keyed by the board's Link device ID (self-reported in the Link
/// HELLO, not cryptographic: a board reporting the same ID inherits the decisions); standard
/// read/alert ("@read", "@alert") are keyed by the peripheral identifier. Boards the user
/// connected are remembered so the app can reconnect them on launch.
public struct BLEDeviceTrustMemory: Sendable {
    public static let revokedKey = "phone-dsh.ble.revoked-grants.v1"
    public static let boardsKey = "phone-dsh.ble.remembered-boards.v1"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func revokedMap() -> [String: [String]] {
        defaults.dictionary(forKey: Self.revokedKey) as? [String: [String]] ?? [:]
    }

    /// Names the user turned off for this key (a Link device ID or a peripheral UUID).
    public func revoked(for key: String) -> Set<String> {
        let id = key.lowercased()
        return id.isEmpty ? [] : Set(revokedMap()[id] ?? [])
    }

    /// Records one switch: `revoked == false` returns it to the default (allowed).
    public func setRevoked(_ name: String, _ revoked: Bool, for key: String) {
        let id = key.lowercased()
        guard !id.isEmpty, !name.isEmpty else { return }
        var all = revokedMap()
        var names = Set(all[id] ?? [])
        if revoked { names.insert(name) } else { names.remove(name) }
        all[id] = names.isEmpty ? nil : names.sorted()
        defaults.set(all, forKey: Self.revokedKey)
    }

    /// Peripheral identifiers of boards the user connected, to reconnect on launch.
    public func rememberedBoards() -> [UUID] {
        (defaults.dictionary(forKey: Self.boardsKey) as? [String: String] ?? [:]).keys.compactMap(UUID.init(uuidString:))
    }

    public func rememberBoard(_ id: UUID, name: String) {
        var all = defaults.dictionary(forKey: Self.boardsKey) as? [String: String] ?? [:]
        all[id.uuidString] = name
        defaults.set(all, forKey: Self.boardsKey)
    }

    /// The user disconnected this board: stop reconnecting it (revocations are kept).
    public func forgetBoard(_ id: UUID) {
        var all = defaults.dictionary(forKey: Self.boardsKey) as? [String: String] ?? [:]
        all[id.uuidString] = nil
        defaults.set(all, forKey: Self.boardsKey)
    }
}
