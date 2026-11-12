// SPDX-License-Identifier: MIT
import Foundation
import Network

// MARK: - Candidate model

/// One observation that a host may be a controllable TV.
///
/// Evidence is evidence, not an assertion: a port being open says the host
/// looks like a TV, not that ADB is authorized on it.
public enum TVEvidence: Hashable, Sendable {
    /// A Bonjour service type observed for the host, e.g. `_googlecast._tcp`.
    case bonjour(String)
    /// A TCP port that accepted a connection during this scan.
    case port(UInt16)
    /// A serial from the remembered-device directory.
    case remembered(String)
}

/// A discovered TV-ish endpoint, reduced to what the connection flow needs.
///
/// `id` is the stable key `host:port`. Discovery always proposes port 5555
/// because that is the endpoint ADB will later dial, even when the only
/// evidence was a non-ADB service on the same host.
public struct TVCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case androidTV = "android-tv"
        case cast
        case airplay
        case roku
        case smartTV = "smart-tv"
        case unknown
    }

    public enum Authorization: String, Hashable, Sendable {
        case unknown
        case required = "required"
        case granted
    }

    public let id: String
    public var host: String
    public var port: UInt16
    public var displayName: String
    public var kind: Kind
    public var evidence: Set<TVEvidence>
    public var score: Int
    public var authorization: Authorization

    public init(id: String, host: String, port: UInt16, displayName: String, kind: Kind,
                evidence: Set<TVEvidence>, score: Int, authorization: Authorization) {
        self.id = id
        self.host = host
        self.port = port
        self.displayName = displayName
        self.kind = kind
        self.evidence = evidence
        self.score = score
        self.authorization = authorization
    }
}

// MARK: - Discovery inputs

/// A bounded TCP dial used to decide whether a port is open.
public protocol TVPortProbe: Sendable {
    func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool
}

/// One resolved Bonjour service that could belong to a TV.
public struct TVBonjourHit: Hashable, Sendable {
    public let service: String
    public let name: String
    public let host: String
    public let port: UInt16

    public init(service: String, name: String, host: String, port: UInt16) {
        self.service = service
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Browses one or more DNS-SD service types for a fixed window.
public protocol TVBonjourBrowsing: Sendable {
    func browse(types: [String], duration: Duration) async -> [TVBonjourHit]
}

/// Limits and service catalog for one discovery pass.
public struct TVDiscoveryConfig: Sendable {
    /// TCP ports dialed on every host, strongest evidence first.
    public var ports: [UInt16]
    /// Maximum number of simultaneous probes.
    public var concurrency: Int
    /// Per-connection timeout.
    public var connectTimeout: Duration
    /// Hard budget for the whole pass; partial results are returned when it
    /// expires.
    public var overallTimeout: Duration
    /// DNS-SD service types to browse.
    public var bonjourTypes: [String]
    /// How long the Bonjour catalog listens before it stops.
    public var bonjourDuration: Duration

    public static let `default` = TVDiscoveryConfig()

    public init(ports: [UInt16] = [5555, 6095, 6091, 8009, 7000, 6466, 6467, 8060],
                concurrency: Int = 64,
                connectTimeout: Duration = .milliseconds(400),
                overallTimeout: Duration = .seconds(8),
                bonjourTypes: [String] = [
                    "_androidtvremote2._tcp", "_googlecast._tcp", "_airplay._tcp", "_roku-rcp._tcp",
                ],
                bonjourDuration: Duration = .seconds(5)) {
        self.ports = ports
        self.concurrency = concurrency
        self.connectTimeout = connectTimeout
        self.overallTimeout = overallTimeout
        self.bonjourTypes = bonjourTypes
        self.bonjourDuration = bonjourDuration
    }
}

// MARK: - Merge

/// Folds port, Bonjour and remembered-device evidence into ranked candidates.
///
/// This type deliberately performs no I/O so a UI can re-rank a cached result
/// set off the main thread and tests can drive every rule deterministically.
public enum TVCandidateMerge {
    public static func merge(hosts: [String], openPorts: [String: Set<UInt16>],
                             bonjour: [TVBonjourHit], remembered: [TVCandidate],
                             config: TVDiscoveryConfig) -> [TVCandidate] {
        var buckets: [String: TVHostEvidence] = [:]

        for (rawHost, ports) in openPorts {
            guard let identity = tvHostIdentity(rawHost) else { continue }
            let open = ports.filter { $0 > 0 }
            guard !open.isEmpty else { continue }
            var bucket = buckets[identity.key] ?? TVHostEvidence(host: identity.host)
            bucket.ports.formUnion(open)
            buckets[identity.key] = bucket
        }

        for hit in bonjour {
            guard let identity = tvHostIdentity(hit.host) else { continue }
            var bucket = buckets[identity.key] ?? TVHostEvidence(host: identity.host)
            bucket.hits.append(hit)
            buckets[identity.key] = bucket
        }

        for candidate in remembered {
            guard let identity = tvHostIdentity(candidate.host) else { continue }
            var bucket = buckets[identity.key] ?? TVHostEvidence(host: identity.host)
            bucket.remembered.append(candidate)
            for case .remembered(let serial) in candidate.evidence where !serial.isEmpty {
                bucket.serials.insert(serial)
            }
            buckets[identity.key] = bucket
        }

        var candidates: [TVCandidate] = []
        for bucket in buckets.values {
            let hasADB = bucket.ports.contains(tvADBPort)
            let hasXiaomiService = !bucket.ports.isDisjoint(with: tvXiaomiServicePorts)
            let hasMediaService = !bucket.ports.isDisjoint(with: tvMediaServicePorts)
            let kinds = Set(bucket.hits.compactMap { serviceKind($0.service) })
            let hasTVService = !kinds.isEmpty

            // Strongest evidence wins; remembered devices are surfaced at 70
            // without ever downgrading a live observation.
            var score = 0
            if hasADB && hasXiaomiService {
                score = 100
            } else if hasADB {
                score = 80
            } else if hasXiaomiService {
                score = 60
            } else if hasTVService {
                score = 50
            } else if hasMediaService {
                score = 40
            }
            if !bucket.remembered.isEmpty {
                score = max(score, 70)
            }
            // Generic Bonjour services alone are not enough to propose a TV.
            guard score > 0 else { continue }

            let kind = candidateKind(kinds: kinds, hasXiaomiService: hasXiaomiService,
                                     hasMediaService: hasMediaService)
            var evidence = Set<TVEvidence>()
            for port in bucket.ports {
                evidence.insert(.port(port))
            }
            for hit in bucket.hits {
                evidence.insert(.bonjour(hit.service))
            }
            for serial in bucket.serials {
                evidence.insert(.remembered(serial))
            }

            let displayName = preferredBonjourName(bucket.hits)
                ?? preferredRememberedName(bucket.remembered)
                ?? "TV · \(bucket.host)"

            // A remembered device keeps the port it was actually connected to,
            // so a saved :5556 target survives an automatic scan. A live 5555
            // hit overrides it; a live-only host (e.g. only 8009 answered)
            // still proposes 5555 because that is the endpoint ADB will dial.
            let port = hasADB ? tvADBPort : (bucket.remembered.first?.port ?? tvADBPort)

            candidates.append(TVCandidate(id: "\(bucket.host):\(port)",
                                          host: bucket.host,
                                          port: port,
                                          displayName: displayName,
                                          kind: kind,
                                          evidence: evidence,
                                          score: score,
                                          authorization: .unknown))
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.host < rhs.host
        }
        return candidates
    }

    private static func candidateKind(kinds: Set<TVCandidate.Kind>, hasXiaomiService: Bool,
                                      hasMediaService: Bool) -> TVCandidate.Kind {
        if hasXiaomiService || kinds.contains(.androidTV) { return .androidTV }
        if kinds.contains(.cast) { return .cast }
        if kinds.contains(.airplay) { return .airplay }
        if kinds.contains(.roku) { return .roku }
        if hasMediaService { return .smartTV }
        return .unknown
    }

    /// Maps a DNS-SD service type to the family it advertises. Only families
    /// that are known to be TV-shaped earn the Bonjour score; generic types
    /// stay as supporting evidence for a host discovered another way.
    private static func serviceKind(_ rawService: String) -> TVCandidate.Kind? {
        let service = tvNormalizedServiceType(rawService)
        guard !service.isEmpty else { return nil }
        if service.contains("androidtv") || service.contains("android-tv")
            || service.contains("googlesat") || service.contains("googletv") {
            return .androidTV
        }
        if service.contains("googlecast") || service.contains("chromecast") {
            return .cast
        }
        if service.contains("airplay") || service.contains("raop") {
            return .airplay
        }
        if service.contains("roku") {
            return .roku
        }
        return nil
    }

    private static func preferredBonjourName(_ hits: [TVBonjourHit]) -> String? {
        let named = hits.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let sorted = named.sorted { lhs, rhs in
            let left = kindPriority(serviceKind(lhs.service))
            let right = kindPriority(serviceKind(rhs.service))
            if left != right { return left < right }
            if lhs.service != rhs.service { return lhs.service < rhs.service }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.host < rhs.host
        }
        return sorted.first?.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preferredRememberedName(_ candidates: [TVCandidate]) -> String? {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.displayName < rhs.displayName
        }
        for candidate in sorted {
            let name = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func kindPriority(_ kind: TVCandidate.Kind?) -> Int {
        guard let kind else { return 5 }
        switch kind {
        case .androidTV: return 0
        case .cast: return 1
        case .airplay: return 2
        case .roku: return 3
        case .smartTV: return 4
        case .unknown: return 5
        }
    }
}

private struct TVHostEvidence {
    let host: String
    var ports: Set<UInt16> = []
    var hits: [TVBonjourHit] = []
    var remembered: [TVCandidate] = []
    var serials: Set<String> = []
}

// MARK: - Discovery engine

/// Runs one foreground discovery pass: bounded port probes and a Bonjour
/// catalog in parallel, merged into ranked candidates.
///
/// The actor is intentionally stateless between scans; overlapping scans each
/// own their collector and cancellation, so a refresh never corrupts a pass
/// that is still winding down.
public actor TVDiscoveryEngine {
    private let config: TVDiscoveryConfig
    private let probe: any TVPortProbe
    private let browser: any TVBonjourBrowsing

    public init(config: TVDiscoveryConfig = .default,
                probe: any TVPortProbe = NWTVPortProbe(),
                browser: any TVBonjourBrowsing = BonjourTVBrowser()) {
        self.config = config
        self.probe = probe
        self.browser = browser
    }

    public func scan(hosts: [String], remembered: [TVCandidate] = []) async -> [TVCandidate] {
        let config = self.config
        let probe = self.probe
        let browser = self.browser
        let hosts = tvUniqueHosts(hosts)
        let ports = tvUniquePorts(config.ports)
        // A Bonjour window that outlives the pass budget would never finish, so
        // the engine clamps it and skips DNS-SD entirely when no room is left.
        let bonjourDuration = tvClampedBonjourDuration(config)
        let collector = TVDiscoveryCollector(pendingSources: bonjourDuration == nil ? 1 : 2)

        let portsTask = Task.detached {
            await tvProbePorts(hosts: hosts, ports: ports, concurrency: config.concurrency,
                               timeout: config.connectTimeout, probe: probe, collector: collector)
            collector.sourceFinished()
        }
        let bonjourTask = bonjourDuration.map { duration in
            Task.detached {
                let hits = await browser.browse(types: config.bonjourTypes, duration: duration)
                collector.addBonjour(hits)
                collector.sourceFinished()
            }
        }
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: tvNonNegative(config.overallTimeout))
            } catch {
                return
            }
            portsTask.cancel()
            bonjourTask?.cancel()
            // A cooperative source can flush partial results while unwinding.
            // The grace is short and bounded so a wedged probe is abandoned
            // instead of being awaited past the budget.
            try? await Task.sleep(for: .milliseconds(80))
            collector.finish()
        }

        let partial = await withTaskCancellationHandler {
            await collector.wait()
        } onCancel: {
            portsTask.cancel()
            bonjourTask?.cancel()
            timeoutTask.cancel()
            collector.finish()
        }

        timeoutTask.cancel()
        portsTask.cancel()
        bonjourTask?.cancel()

        return TVCandidateMerge.merge(hosts: hosts, openPorts: partial.openPorts,
                                      bonjour: partial.bonjour, remembered: remembered,
                                      config: config)
    }
}

private func tvProbePorts(hosts: [String], ports: [UInt16], concurrency: Int,
                          timeout: Duration, probe: any TVPortProbe,
                          collector: TVDiscoveryCollector) async {
    // Port-major, not host-major: the ports are ordered strongest evidence
    // first, so within the fixed overall budget every host gets its ADB-port
    // dial before any host gets a weaker port. Host-major order queues a late
    // /24 host's ADB dial behind every earlier host's full port catalogue, so
    // slow or unreachable early hosts can consume the budget before that host
    // is tried. (A 2026-11-11 iPhone run first suggested this; direct probes
    // then showed that run's missing TV was TCP-unreachable from the phone,
    // not a queue problem. The ordering is still the correct bounded-budget
    // behaviour and is asserted by testEngineDialsTheADBPortAcrossAllHosts...)
    let jobs = ports.flatMap { port in hosts.map { ($0, port) } }
    guard !jobs.isEmpty else { return }
    let limit = max(1, min(concurrency, jobs.count))

    await withTaskGroup(of: (String, UInt16, Bool).self) { group in
        var next = 0
        var running = 0
        while next < jobs.count || running > 0 {
            if Task.isCancelled {
                group.cancelAll()
                break
            }
            while running < limit && next < jobs.count {
                let (host, port) = jobs[next]
                next += 1
                running += 1
                group.addTask {
                    let open = await probe.isOpen(host: host, port: port, timeout: timeout)
                    return (host, port, open)
                }
            }
            guard let result = await group.next() else { break }
            running -= 1
            if result.2 {
                collector.addPort(host: result.0, port: result.1)
            }
        }
    }
}

/// Collects partial scan state and releases the waiting scan exactly once.
private final class TVDiscoveryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSources: Int
    private var continuation: CheckedContinuation<TVScanPartial, Never>?
    private var finished = false
    private var openPorts: [String: Set<UInt16>] = [:]
    private var bonjour: [TVBonjourHit] = []
    private var seenBonjour: Set<TVBonjourHit> = []

    init(pendingSources: Int) {
        self.remainingSources = pendingSources
    }

    func wait() async -> TVScanPartial {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let snapshot = currentPartialLocked()
                lock.unlock()
                continuation.resume(returning: snapshot)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func addPort(host: String, port: UInt16) {
        lock.lock()
        if !finished {
            openPorts[host, default: []].insert(port)
        }
        lock.unlock()
    }

    func addBonjour(_ hits: [TVBonjourHit]) {
        lock.lock()
        if !finished {
            for hit in hits where seenBonjour.insert(hit).inserted {
                bonjour.append(hit)
            }
        }
        lock.unlock()
    }

    func sourceFinished() {
        var resume: CheckedContinuation<TVScanPartial, Never>?
        var snapshot: TVScanPartial?
        lock.lock()
        if !finished {
            remainingSources -= 1
            if remainingSources <= 0 {
                finished = true
                resume = continuation
                continuation = nil
                snapshot = currentPartialLocked()
            }
        }
        lock.unlock()
        if let resume, let snapshot {
            resume.resume(returning: snapshot)
        }
    }

    func finish() {
        var resume: CheckedContinuation<TVScanPartial, Never>?
        var snapshot: TVScanPartial?
        lock.lock()
        if !finished {
            finished = true
            resume = continuation
            continuation = nil
            snapshot = currentPartialLocked()
        }
        lock.unlock()
        if let resume, let snapshot {
            resume.resume(returning: snapshot)
        }
    }

    private func currentPartialLocked() -> TVScanPartial {
        TVScanPartial(openPorts: openPorts, bonjour: bonjour)
    }
}

private struct TVScanPartial: Sendable {
    var openPorts: [String: Set<UInt16>] = [:]
    var bonjour: [TVBonjourHit] = []
}

// MARK: - Network.framework port probe

/// TCP connect probe built on `NWConnection`.
///
/// A connection is cancelled on every exit path: ready, failure, timeout and
/// task cancellation. The continuation is resumed exactly once.
public struct NWTVPortProbe: TVPortProbe {
    public init() {}

    public func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let host = tvNormalizedHost(host)
        let seconds = tvTimeInterval(timeout)
        guard !host.isEmpty, seconds > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let state = TVPortProbeState(connection: connection)
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                state.finish(open: true)
            case .failed, .cancelled:
                state.finish(open: false)
            default:
                break
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard state.attach(continuation) else {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                    return
                }
                if state.isFinished {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    return
                }
                connection.start(queue: TVPortProbeState.queue)
                TVPortProbeState.queue.asyncAfter(deadline: .now() + seconds) {
                    state.finish(open: false)
                }
            }
        } onCancel: {
            state.finish(open: false)
        }
    }
}

private final class TVPortProbeState: @unchecked Sendable {
    static let queue = DispatchQueue(label: "phone-dsh.tv-discovery.probe", attributes: .concurrent)

    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// Returns false when the probe already finished, in which case the caller
    /// owns the continuation and must resume it.
    func attach(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        self.continuation = continuation
        return true
    }

    func finish(open: Bool) {
        let continuation: CheckedContinuation<Bool, Never>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: open)
    }
}

// MARK: - Bonjour catalog

/// DNS-SD catalog backed by `NetServiceBrowser`.
///
/// `NetServiceBrowser` delivers callbacks on the run loop it is scheduled on,
/// so each browse runs on a dedicated thread with its own run loop instead of a
/// Swift-concurrency worker that has no running loop. Resolution results are
/// collected behind a lock; services that do not resolve inside the window are
/// dropped.
public final class BonjourTVBrowser: NSObject, TVBonjourBrowsing, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func browse(types: [String], duration: Duration) async -> [TVBonjourHit] {
        let services = tvUniqueServiceTypes(types)
        let seconds = tvTimeInterval(duration)
        guard !services.isEmpty, seconds > 0 else { return [] }

        let session = TVBonjourSession(types: services, duration: seconds)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[TVBonjourHit], Never>) in
                session.start(continuation)
            }
        } onCancel: {
            session.cancel()
        }
    }
}

private final class TVBonjourSession: NSObject, NetServiceBrowserDelegate, NetServiceDelegate,
    @unchecked Sendable {
    private let types: [String]
    private let deadline: Date
    private let resolveTimeout: TimeInterval
    private let lock = NSLock()
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var hits: Set<TVBonjourHit> = []
    private var continuation: CheckedContinuation<[TVBonjourHit], Never>?
    private var finished = false
    private var cancelled = false

    init(types: [String], duration: TimeInterval) {
        self.types = types
        self.deadline = Date(timeIntervalSinceNow: duration)
        self.resolveTimeout = max(0.1, min(5, duration))
        super.init()
    }

    func start(_ continuation: CheckedContinuation<[TVBonjourHit], Never>) {
        lock.lock()
        if finished {
            let snapshot = Self.sorted(self.hits)
            lock.unlock()
            continuation.resume(returning: snapshot)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let thread = Thread { [self] in
            self.run()
        }
        thread.name = "phone-dsh.tv-discovery.bonjour"
        thread.qualityOfService = .utility
        thread.start()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish()
    }

    private func run() {
        if isFinished || isCancelled {
            finish()
            return
        }

        for type in types {
            if isFinished || isCancelled { break }
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .current, forMode: .default)
            browser.searchForServices(ofType: type, inDomain: "local.")
            // Always retain the browser so the cleanup below can stop it, even
            // when cancellation lands in the middle of the type loop.
            lock.lock()
            browsers.append(browser)
            lock.unlock()
        }

        while !isFinished && !isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.05, remaining)))
            if !isFinished && !isCancelled {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        stopBrowsing()
        finish()
    }

    private func stopBrowsing() {
        lock.lock()
        let browsers = self.browsers
        let services = self.services
        self.browsers = []
        self.services = []
        lock.unlock()
        for browser in browsers { browser.stop() }
        for service in services { service.stop() }
    }

    private func finish() {
        let continuation: CheckedContinuation<[TVBonjourHit], Never>?
        let hits: [TVBonjourHit]
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation = self.continuation
        self.continuation = nil
        hits = Self.sorted(self.hits)
        lock.unlock()
        continuation?.resume(returning: hits)
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func sorted(_ hits: Set<TVBonjourHit>) -> [TVBonjourHit] {
        hits.sorted { lhs, rhs in
            if lhs.host != rhs.host { return lhs.host < rhs.host }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            if lhs.service != rhs.service { return lhs.service < rhs.service }
            return lhs.name < rhs.name
        }
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                           moreComing: Bool) {
        lock.lock()
        guard !finished, services.count < 128 else {
            lock.unlock()
            return
        }
        services.append(service)
        lock.unlock()

        service.delegate = self
        service.schedule(in: .current, forMode: .default)
        service.resolve(withTimeout: resolveTimeout)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService,
                           moreComing: Bool) {
        // A disappearing advertisement does not retract an address that was
        // already resolved during this window.
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // The window still ends at its deadline; a failed type simply adds no
        // hits.
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0, sender.port <= Int(UInt16.max),
              let host = Self.ipv4Host(of: sender) ?? Self.fallbackHost(of: sender) else {
            return
        }
        let type = tvNormalizedServiceType(sender.type)
        guard !type.isEmpty else { return }
        let hit = TVBonjourHit(service: type, name: sender.name, host: host,
                               port: UInt16(sender.port))
        lock.lock()
        if !finished {
            hits.insert(hit)
        }
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        lock.lock()
        services.removeAll { $0 === sender }
        lock.unlock()
    }

    private static func ipv4Host(of service: NetService) -> String? {
        for data in service.addresses ?? [] {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            let host: String? = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                guard family == sa_family_t(AF_INET) else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                return tvIPv4String(UInt32(bigEndian: address.sin_addr.s_addr))
            }
            if let host { return host }
        }
        return nil
    }

    private static func fallbackHost(of service: NetService) -> String? {
        guard let name = service.hostName else { return nil }
        let host = tvNormalizedHost(name)
        return host.isEmpty ? nil : host
    }
}

// MARK: - Local subnet enumeration

/// IPv4 host addresses for every up, non-loopback Wi-Fi or wired interface.
///
/// Only `en*` interfaces represent the reachable LAN. Cellular (`pdp_ip*`),
/// tunnels, peer-to-peer links, bridges and synthesized interfaces are skipped
/// so a phone on mobile data never dials the carrier's subnet. The network and
/// broadcast addresses are excluded. The total is capped at 4096 unique
/// addresses so a misconfigured mask cannot turn one scan into a
/// multi-million-dial pass.
public func tvLocalSubnetHosts() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(first) }

    let capacity = 4096
    var addresses = Set<UInt32>()
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor, addresses.count < capacity {
        let interface = entry.pointee
        cursor = interface.ifa_next

        let flags = Int32(bitPattern: interface.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard let name = interface.ifa_name, tvIsLANInterface(String(cString: name)) else { continue }
        guard let address = tvIPv4Value(interface.ifa_addr),
              let mask = tvIPv4Value(interface.ifa_netmask),
              address != 0 else { continue }

        let network = address & mask
        let broadcast = network | ~mask
        guard network < broadcast else { continue }

        var candidate = network &+ 1
        while candidate < broadcast && addresses.count < capacity {
            if candidate != 0xffff_ffff {
                addresses.insert(candidate)
            }
            candidate &+= 1
        }
    }

    return addresses.sorted().map(tvIPv4String)
}

/// Interface families that never carry the LAN a TV scan may dial.
private let tvExcludedInterfacePrefixes = [
    "pdp_ip", "utun", "ipsec", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi", "anri", "lo",
]

/// Whether a BSD interface name is Wi-Fi or wired Ethernet.
///
/// `en` covers both on Apple platforms; every other family (cellular, tunnel,
/// peer-to-peer, bridge, synthesized) is rejected explicitly so a new system
/// interface cannot silently widen the scan into an unrelated subnet.
private func tvIsLANInterface(_ name: String) -> Bool {
    guard name.hasPrefix("en") else { return false }
    return !tvExcludedInterfacePrefixes.contains { name.hasPrefix($0) }
}

private func tvIPv4Value(_ address: UnsafeMutablePointer<sockaddr>?) -> UInt32? {
    guard let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
    return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
        UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
    }
}

private func tvIPv4String(_ value: UInt32) -> String {
    "\((value >> 24) & 0xff).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
}

// MARK: - Shared defaults and helpers

private let tvADBPort: UInt16 = 5555
private let tvXiaomiServicePorts: Set<UInt16> = [6095, 6091]
private let tvMediaServicePorts: Set<UInt16> = [8009, 7000, 6466, 6467, 8060]

private func tvTimeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds)
        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
}

private func tvNonNegative(_ duration: Duration) -> Duration {
    duration < .zero ? .zero : duration
}

/// Bonjour window that fits inside one pass.
///
/// A DNS-SD catalog is useless if it outlives the scan, so the configured
/// duration is clamped to leave a 200 ms tail for the sources to flush and the
/// merge to run. A non-positive result means there is no room for Bonjour at
/// all and the engine must not start that source.
private func tvClampedBonjourDuration(_ config: TVDiscoveryConfig) -> Duration? {
    let available = config.overallTimeout - .milliseconds(200)
    let duration = min(config.bonjourDuration, available)
    return duration > .zero ? duration : nil
}

private func tvNormalizedHost(_ host: String) -> String {
    var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix(".") {
        value.removeLast()
    }
    return value
}

private func tvHostIdentity(_ host: String) -> (key: String, host: String)? {
    let value = tvNormalizedHost(host)
    guard !value.isEmpty else { return nil }
    return (value.lowercased(), value)
}

private func tvUniqueHosts(_ hosts: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for rawHost in hosts {
        let host = tvNormalizedHost(rawHost)
        guard !host.isEmpty, seen.insert(host.lowercased()).inserted else { continue }
        result.append(host)
    }
    return result
}

private func tvUniquePorts(_ ports: [UInt16]) -> [UInt16] {
    var seen = Set<UInt16>()
    return ports.filter { $0 > 0 && seen.insert($0).inserted }
}

private func tvNormalizedServiceType(_ rawService: String) -> String {
    var service = rawService.trimmingCharacters(in: .whitespacesAndNewlines)
    while service.hasSuffix(".") {
        service.removeLast()
    }
    return service
}

private func tvUniqueServiceTypes(_ types: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for rawType in types {
        let type = tvNormalizedServiceType(rawType)
        guard !type.isEmpty, seen.insert(type.lowercased()).inserted else { continue }
        // NetServiceBrowser expects a trailing dot on the service type.
        result.append(type + ".")
    }
    return result
}
