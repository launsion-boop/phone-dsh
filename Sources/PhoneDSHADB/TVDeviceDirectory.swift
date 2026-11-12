// SPDX-License-Identifier: MIT
import Foundation

/// One Android TV / ADB endpoint remembered across launches.
///
/// `serial` is the stable identity: it survives DHCP changes, so a later
/// discovery pass can match a new address to a previously connected TV.
public struct TVDeviceRecord: Codable, Hashable, Sendable {
    public var serial: String
    public var model: String
    public var host: String
    public var port: UInt16
    public var mac: String?
    public var lastSeen: Date

    public init(serial: String, model: String, host: String, port: UInt16, mac: String? = nil,
                lastSeen: Date) {
        self.serial = serial
        self.model = model
        self.host = host
        self.port = port
        self.mac = mac
        self.lastSeen = lastSeen
    }
}

/// Persists recently connected TVs and the last successful endpoint.
///
/// Records are keyed by serial, capped at eight entries and returned newest
/// first. `UserDefaults` is itself thread-safe, but a `remember`/`forget`
/// performs a read-modify-write over the key, so an `NSLock` serializes those
/// cycles and keeps the device list and the endpoint key consistent.
public final class TVDeviceDirectory: @unchecked Sendable {
    public static let shared = TVDeviceDirectory()

    /// The on-disk values are internal to this class; the names are fixed.
    private static let devicesKey = "phone-dsh.tv-discovery.devices.v1"
    private static let lastEndpointKey = "phone-dsh.tv-discovery.last-endpoint.v1"
    private static let capacity = 8

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The most recent records, at most eight, ordered by `lastSeen` descending.
    public func records() -> [TVDeviceRecord] {
        lock.withLock {
            Array(Self.newestFirst(Self.load(from: defaults)).prefix(Self.capacity))
        }
    }

    /// Inserts or replaces `record` by serial, evicts the oldest records beyond
    /// the eight-entry cap, and records its endpoint as the last successful one.
    public func remember(_ record: TVDeviceRecord) {
        lock.withLock {
            var records = Self.load(from: defaults)
            records.removeAll { $0.serial == record.serial }
            records.append(record)
            records = Array(Self.newestFirst(records).prefix(Self.capacity))
            if let data = try? Self.encoder.encode(records) {
                defaults.set(data, forKey: Self.devicesKey)
            }
            let endpoint = LastEndpoint(host: record.host, port: record.port)
            if let data = try? Self.encoder.encode(endpoint) {
                defaults.set(data, forKey: Self.lastEndpointKey)
            }
        }
    }

    /// The endpoint of the last successful connection, or nil before one exists.
    public func lastEndpoint() -> (host: String, port: UInt16)? {
        lock.withLock {
            guard let data = defaults.data(forKey: Self.lastEndpointKey),
                  let endpoint = try? Self.decoder.decode(LastEndpoint.self, from: data),
                  !endpoint.host.isEmpty, endpoint.port > 0 else { return nil }
            return (host: endpoint.host, port: endpoint.port)
        }
    }

    /// Removes a record by serial. The remembered endpoint is cleared too when
    /// it points at the forgotten device, so the directory never auto-connects
    /// to a device the user removed.
    public func forget(serial: String) {
        lock.withLock {
            var records = Self.load(from: defaults)
            let removed = records.filter { $0.serial == serial }
            guard !removed.isEmpty else { return }
            records.removeAll { $0.serial == serial }
            if let data = try? Self.encoder.encode(records) {
                defaults.set(data, forKey: Self.devicesKey)
            }
            guard let last = lastEndpointLocked(),
                  removed.contains(where: { $0.host == last.host && $0.port == last.port }) else {
                return
            }
            defaults.removeObject(forKey: Self.lastEndpointKey)
        }
    }

    // MARK: - UserDefaults document

    private struct LastEndpoint: Codable {
        var host: String
        var port: UInt16
    }

    /// Every date is written as seconds since 1970 so a stored document can be
    /// decoded by this class alone, without locale or formatter state.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private static func load(from defaults: UserDefaults) -> [TVDeviceRecord] {
        guard let data = defaults.data(forKey: devicesKey),
              let records = try? decoder.decode([TVDeviceRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Newest first. Entries with the same timestamp keep their stored order,
    /// which makes eviction deterministic for records written in one batch.
    private static func newestFirst(_ records: [TVDeviceRecord]) -> [TVDeviceRecord] {
        records.enumerated().sorted { lhs, rhs in
            if lhs.element.lastSeen == rhs.element.lastSeen {
                return lhs.offset < rhs.offset
            }
            return lhs.element.lastSeen > rhs.element.lastSeen
        }.map { $0.element }
    }

    /// The unlocked form of ``lastEndpoint()`` for use inside `lock.withLock`.
    private func lastEndpointLocked() -> (host: String, port: UInt16)? {
        guard let data = defaults.data(forKey: Self.lastEndpointKey),
              let endpoint = try? Self.decoder.decode(LastEndpoint.self, from: data),
              !endpoint.host.isEmpty, endpoint.port > 0 else { return nil }
        return (host: endpoint.host, port: endpoint.port)
    }
}
