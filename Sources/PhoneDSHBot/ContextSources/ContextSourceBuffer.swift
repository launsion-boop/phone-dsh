// SPDX-License-Identifier: MIT

import Foundation

/// A small, bounded buffer used by adapters to satisfy
/// `BotContextSource.observations(since:)` without inventing a second durable
/// store. The registry is the authoritative read view; this buffer exists so a
/// caller can inspect one adapter directly and so a pull-based adapter has a
/// uniform surface.
public final class BotContextSourceBuffer: @unchecked Sendable {
    public static let maximum = 100
    private let lock = NSLock()
    private var items: [BotContextObservation] = []

    public init() {}

    public func append(_ observation: BotContextObservation) {
        lock.lock()
        defer { lock.unlock() }
        if items.contains(where: { $0.id == observation.id }) { return }
        items.append(observation)
        if items.count > Self.maximum {
            items.removeFirst(items.count - Self.maximum)
        }
    }

    public func observations(since: Int64?) -> [BotContextObservation] {
        lock.lock()
        defer { lock.unlock() }
        let threshold = max(0, since ?? 0)
        return items.filter { $0.observedAt >= threshold }
            .sorted { ($0.observedAt, $0.id) < ($1.observedAt, $1.id) }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        items = []
    }
}

/// Implemented by every real OS adapter. Keeping the diagnostic word separate
/// from the effective consent means an OS "authorized" never silently turns a
/// user's App-level opt-in on.
public enum BotContextOSStatusWord {
    public static func word(_ value: BotSourceAuthorization) -> String {
        switch value {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .revoked: return "revoked"
        }
    }
}
