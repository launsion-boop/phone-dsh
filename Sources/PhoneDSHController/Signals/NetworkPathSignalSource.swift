// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: network-path signal.
//
// budgets.md §3 `NWPathMonitor`: an unsatisfied path moves `Running` to
// `Backoff`; a satisfied path lets a successful probe reopen admission. The
// source only publishes the documented `NWPath.Status` cases and keeps no
// policy of its own.

import Foundation
import Network

/// Abstraction over `NWPathMonitor` so the source can be tested without a real
/// network interface.
public protocol NetworkPathMonitoring: Sendable {
    /// Starts monitoring. `handler` receives the current path immediately when
    /// the system reports it and again on every change.
    func start(handler: @escaping @Sendable (NetworkPathStatus) -> Void)
    /// Stops monitoring and releases the underlying monitor.
    func stop()
}

/// `NWPathMonitor` adapter on a private serial queue.
public final class SystemNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "phone-dsh.phone-dsh.nwpath")
    private var monitor: NWPathMonitor?

    public init() {}

    public func start(handler: @escaping @Sendable (NetworkPathStatus) -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            handler(NetworkPathStatus(pathStatus: path.status))
        }
        let replaced: NWPathMonitor? = lock.withLock {
            let previous = self.monitor
            self.monitor = monitor
            return previous
        }
        replaced?.cancel()
        monitor.start(queue: queue)
    }

    public func stop() {
        let monitor: NWPathMonitor? = lock.withLock {
            let current = self.monitor
            self.monitor = nil
            return current
        }
        monitor?.cancel()
    }
}

extension NetworkPathStatus {
    /// Maps the documented `NWPath.Status` cases. An unknown future case is
    /// treated as `unsatisfied` so the host backs off instead of assuming a
    /// working network.
    public init(pathStatus status: NWPath.Status) {
        switch status {
        case .satisfied: self = .satisfied
        case .unsatisfied: self = .unsatisfied
        case .requiresConnection: self = .requiresConnection
        @unknown default: self = .unsatisfied
        }
    }
}

/// Publishes ``NetworkPathStatus`` values from an injected path monitor.
public final class NetworkPathSignalSource: @unchecked Sendable {
    private let monitor: any NetworkPathMonitoring
    private let initialStatus: NetworkPathStatus?
    private let hub = SignalBroadcaster<NetworkPathStatus>()
    private let gate: SignalValueGate<NetworkPathStatus>
    private let lock = NSLock()
    private var running = false

    /// Creates a path source.
    ///
    /// - Parameters:
    ///   - monitor: Path monitor; defaults to ``SystemNetworkPathMonitor``.
    ///   - initial: Value emitted first; the platform source leaves it `nil`
    ///     because `NWPathMonitor` reports the current path once started.
    public init(monitor: any NetworkPathMonitoring = SystemNetworkPathMonitor(),
                initial: NetworkPathStatus? = nil) {
        self.monitor = monitor
        self.initialStatus = initial
        self.gate = SignalValueGate()
    }

    /// The platform source (`NWPathMonitor`).
    public static func platform() -> NetworkPathSignalSource {
        NetworkPathSignalSource()
    }

    /// Path statuses; the last value is replayed.
    public var stream: AsyncStream<NetworkPathStatus> { hub.stream() }

    /// Starts the monitor and publishes the initial status once.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            if running { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        monitor.start { [weak self] status in
            self?.emit(status)
        }
        if let initialStatus {
            emit(initialStatus)
        }
    }

    /// Stops the monitor and finishes the stream.
    public func stop() {
        lock.withLock { running = false }
        monitor.stop()
        hub.finish()
    }

    private func emit(_ status: NetworkPathStatus) {
        let isRunning = lock.withLock { running }
        guard isRunning, gate.accept(status) else { return }
        hub.yield(status)
    }
}
