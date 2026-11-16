// SPDX-License-Identifier: MIT

#if canImport(CoreLocation)
import CoreLocation
import Foundation

/// A user-confirmed geofence. Coordinates are kept only in this in-memory value
/// and in the OS region registration; they are not written into the observation
/// payload (the observation names the fence, not the user's location).
public struct BotContextGeofenceSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public var label: String?

    public init(id: String, latitude: Double, longitude: Double,
                radiusMeters: Double, label: String? = nil) throws {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, cleanID.unicodeScalars.count <= 100,
              cleanID.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                      || scalar == "." || scalar == "_" || scalar == "-")
              }) else {
            throw BotContextSourceError.invalidRequest("geofence id must be a bounded ASCII identifier")
        }
        guard latitude.isFinite, latitude >= -90, latitude <= 90,
              longitude.isFinite, longitude >= -180, longitude <= 180,
              radiusMeters.isFinite, radiusMeters >= 10, radiusMeters <= 1_000 else {
            throw BotContextSourceError.invalidRequest("geofence coordinates/radius are outside the supported range")
        }
        self.id = cleanID
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.label = label.map { String($0.prefix(120)) }
    }

    public var regionIdentifier: String { "pdsh.context." + id }
}

/// System geofence source. It never starts continuous location: only
/// `CLCircularRegion` entry/exit callbacks are observed. The App must be granted
/// Always authorization and the user must confirm each fence before it is added.
public final class LocationRegionSource: BotContextSource, BotContextSourceStreaming,
                                         BotContextSourceRequesting, BotContextSourceDiagnosing,
                                         @unchecked Sendable {
    public let kind: BotContextSourceKind = .locationFence
    private let lock = NSLock()
    private let buffer = BotContextSourceBuffer()
    private let now: @Sendable () -> Int64
    private var manager: CLLocationManager?
    private var delegate: LocationRegionDelegate?
    private var fences: [BotContextGeofenceSpec]
    private var activeRevision: Int?
    private var emit: (@Sendable (BotContextObservation) -> Void)?

    public init(fences: [BotContextGeofenceSpec] = [],
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.fences = fences
        self.now = now
    }

    public func authorization() async -> BotSourceAuthorization {
        Self.map(CLLocationManager.authorizationStatus())
    }

    public func authorizationDiagnostic() async -> String? {
        String(CLLocationManager.authorizationStatus().rawValue)
    }

    public func requestAuthorization() async -> BotSourceAuthorization {
        await MainActor.run { [weak self] in
            guard let self else { return }
            if self.manager == nil {
                let manager = CLLocationManager()
                let delegate = LocationRegionDelegate()
                delegate.onAuthorization = { [weak self] in
                    guard let self else { return }
                    self.handleAuthorizationChanged()
                }
                manager.delegate = delegate
                self.manager = manager
                self.delegate = delegate
            }
            self.manager?.requestAlwaysAuthorization()
        }
        // The OS prompt is asynchronous; give the prompt a bounded chance to
        // settle. The caller may also observe the change through the delegate.
        for _ in 0..<50 {
            let status = await authorization()
            if status != .notDetermined { return status }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await authorization()
    }

    public func start(permissionRevision: Int,
                      emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        let status = await authorization()
        guard status == .authorized || status == .limited else {
            throw BotContextSourceError.unsupported("geofence monitoring requires Always authorization")
        }
        lock.lock()
        activeRevision = permissionRevision
        self.emit = emit
        let requested = fences
        lock.unlock()
        await MainActor.run { [weak self] in
            guard let self else { return }
            let manager = self.manager ?? CLLocationManager()
            if self.delegate == nil {
                let delegate = LocationRegionDelegate()
                delegate.onRegion = { [weak self] regionID, entered in
                    self?.handleRegion(identifier: regionID, entered: entered)
                }
                delegate.onFailure = { [weak self] message in
                    self?.handleFailure(message)
                }
                delegate.onAuthorization = { [weak self] in
                    self?.handleAuthorizationChanged()
                }
                manager.delegate = delegate
                self.delegate = delegate
            }
            self.manager = manager
            for fence in requested {
                guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
                let region = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: fence.latitude, longitude: fence.longitude),
                    radius: fence.radiusMeters,
                    identifier: fence.regionIdentifier)
                region.notifyOnEntry = true
                region.notifyOnExit = true
                manager.startMonitoring(for: region)
            }
        }
    }

    public func stop() async {
        lock.lock()
        let manager = self.manager
        self.manager = nil
        self.delegate = nil
        activeRevision = nil
        emit = nil
        buffer.clear()
        lock.unlock()
        await MainActor.run {
            guard let manager else { return }
            for region in manager.monitoredRegions where region.identifier.hasPrefix("pdsh.context.") {
                manager.stopMonitoring(for: region)
            }
            manager.delegate = nil
        }
    }

    public func observations(since: Int64?) async throws -> [BotContextObservation] {
        buffer.observations(since: since)
    }

    /// Adds/replaces the user-confirmed fences while the source is active. A
    /// removed fence stops monitoring only this source's `pdsh.context.` region;
    /// regions owned by another App feature are never touched.
    public func updateFences(_ next: [BotContextGeofenceSpec]) async throws {
        lock.lock()
        let revision = activeRevision
        let sink = emit
        let previous = fences
        fences = next
        lock.unlock()
        guard let revision, sink != nil else {
            throw BotContextSourceError.revoked(.locationFence)
        }
        let previousIDs = Set(previous.map(\.regionIdentifier))
        let nextIDs = Set(next.map(\.regionIdentifier))
        await MainActor.run { [weak self] in
            guard let self, let manager = self.manager else { return }
            for region in manager.monitoredRegions
                where region.identifier.hasPrefix("pdsh.context.") && !nextIDs.contains(region.identifier) {
                manager.stopMonitoring(for: region)
            }
            for fence in next where !previousIDs.contains(fence.regionIdentifier) {
                let region = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: fence.latitude, longitude: fence.longitude),
                    radius: fence.radiusMeters,
                    identifier: fence.regionIdentifier)
                region.notifyOnEntry = true
                region.notifyOnExit = true
                manager.startMonitoring(for: region)
            }
        }
        _ = revision
    }

    private func handleRegion(identifier: String, entered: Bool) {
        let fenceID = identifier.hasPrefix("pdsh.context.")
            ? String(identifier.dropFirst("pdsh.context.".count)) : identifier
        lock.lock()
        let revision = activeRevision
        let sink = emit
        let label = fences.first { $0.id == fenceID }?.label
        lock.unlock()
        guard let revision, let sink else { return }
        let stamp = now()
        var payload: [String: BotJSONValue] = [
            "regionId": .string(String(fenceID.prefix(100))),
            "entered": .bool(entered),
        ]
        if let label { payload["label"] = .string(label) }
        guard let observation = try? BotContextObservation(
            id: "location:\(fenceID):\(entered ? "enter" : "exit"):\(stamp)",
            source: .locationFence,
            kind: entered ? .locationEntered : .locationExited,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(
                level: .medium,
                reason: "system-geofence-delivery-is-delayed-and-approximate",
                completeness: .partial),
            delivery: .os,
            payload: .object(payload),
            dedupeKey: "location:\(fenceID):\(entered ? "enter" : "exit"):\(stamp / 60_000)",
            wakeRequested: true) else { return }
        buffer.append(observation)
        sink(observation)
    }

    private func handleFailure(_ message: String) {
        lock.lock()
        let sink = emit
        let revision = activeRevision
        lock.unlock()
        guard sink != nil, let revision else { return }
        // A region failure is not an observation of the user's location; keep
        // it as a bounded diagnostic only (no payload, no wake).
        let stamp = now()
        guard let observation = try? BotContextObservation(
            id: "location:failure:\(stamp)",
            source: .locationFence,
            kind: .locationFailed,
            observedAt: stamp,
            permissionRevision: revision,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(
                level: .high, reason: String(message.prefix(200)), completeness: .partial),
            delivery: .os,
            payload: .object(["failed": .bool(true)]),
            dedupeKey: "location:failure:\(stamp / 60_000)",
            wakeRequested: false) else { return }
        buffer.append(observation)
    }

    private func handleAuthorizationChanged() {
        // The registry mirrors OS status on the next authorize/read; a source
        // adapter does not auto-grant or auto-revoke. If the OS drops Always,
        // subsequent callbacks still carry the old revision and are dropped by
        // the registry, while this adapter stops monitoring its own regions.
        let status = CLLocationManager.authorizationStatus()
        guard status != .authorizedAlways, status != .notDetermined else { return }
        lock.lock()
        let sink = emit
        lock.unlock()
        if sink != nil {
            Task { [weak self] in
                await self?.stop()
            }
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> BotSourceAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways: return .authorized
        case .authorizedWhenInUse: return .limited
        @unknown default: return .notDetermined
        }
    }
}

private final class LocationRegionDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var onRegion: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAuthorization: (() -> Void)?

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        onRegion?(region.identifier, true)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        onRegion?(region.identifier, false)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?()
    }
}
#endif
