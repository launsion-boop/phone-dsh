// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHController: memory-proxy signal.
//
// budgets.md §3 `memory proxy`: VFS bytes by prefix, session bytes and the
// WebContent termination count drive the §4 budget actions. The sample is
// produced by the workspace log (`WorkspaceLog.metrics()`), and the same
// sample is passed through the landed ``BudgetMonitor`` so the drainer / App
// sees exactly the controller's decision for it.

import Foundation
import PhoneDSHLog

/// Supplies one memory-proxy sample.
public protocol MemoryProxyProviding: Sendable {
    /// The current VFS / session / termination counters.
    func memoryProxySample() async -> MemoryProxySample
}

/// Adapter over the landed `WorkspaceLog.metrics()` snapshot.
public struct WorkspaceLogMemoryProxyProvider: MemoryProxyProviding {
    private let log: WorkspaceLog
    private let webContentTerminations: @Sendable () -> UInt64
    private let engineHeapBytes: @Sendable () -> Int?

    /// Creates the adapter.
    ///
    /// - Parameters:
    ///   - log: The workspace log that owns the WAL and journal bytes.
    ///   - webContentTerminations: Counter maintained by the WebKit delegate.
    ///   - engineHeapBytes: Optional WebContent heap probe. When provided, the
    ///     same sample also drives the heap branch of the budget actions.
    public init(log: WorkspaceLog,
                webContentTerminations: @escaping @Sendable () -> UInt64 = { 0 },
                engineHeapBytes: @escaping @Sendable () -> Int? = { nil }) {
        self.log = log
        self.webContentTerminations = webContentTerminations
        self.engineHeapBytes = engineHeapBytes
    }

    public func memoryProxySample() async -> MemoryProxySample {
        let terminations = webContentTerminations()
        let heap = engineHeapBytes()
        guard let metrics = try? await log.metrics() else {
            return MemoryProxySample(vfsBytesByPrefix: [:], sessionBytes: 0,
                                     webContentTerminations: terminations,
                                     engineHeapBytes: heap)
        }
        return MemoryProxySample(metrics: metrics,
                                 webContentTerminations: terminations,
                                 engineHeapBytes: heap)
    }
}

/// Fixed sample provider for Apps and tests that compute the counters
/// themselves.
public struct StaticMemoryProxyProvider: MemoryProxyProviding {
    public var sample: MemoryProxySample

    public init(_ sample: MemoryProxySample) {
        self.sample = sample
    }

    public func memoryProxySample() async -> MemoryProxySample { sample }
}

/// Publishes memory-proxy samples and the budget decision of each one.
///
/// The sampling loop is optional: the facade can also call ``refresh()`` at
/// the points it already measures (tool-call boundary, scene-phase change).
/// `BudgetMonitor` consumes the sample and emits at most one action per
/// evaluation in the fixed clear-tmp -> planned-restart -> handoff order.
public final class MemoryProxySignalSource: @unchecked Sendable {
    /// Sampling period used by ``start()``. A policy constant, not a
    /// measurement.
    public static let defaultIntervalSeconds: TimeInterval = 30

    /// The injected clock (sleeps are cancellable).
    public let clock: any HostClock
    /// The sampling period in seconds; `0` disables the automatic loop.
    public let interval: TimeInterval
    /// The controller's budget monitor.
    public let monitor: BudgetMonitor

    private let provider: any MemoryProxyProviding
    private let sampleHub = SignalBroadcaster<MemoryProxySample>()
    private let decisionHub = SignalBroadcaster<BudgetDecision>()
    private let lock = NSLock()
    private var running = false
    private var pollTask: Task<Void, Never>?

    /// Creates the source.
    ///
    /// - Parameters:
    ///   - provider: Sample provider; usually
    ///     ``WorkspaceLogMemoryProxyProvider``.
    ///   - monitor: Budget monitor; the controller uses the same-instance
    ///     `BudgetMonitor` as its diagnostics so the two views agree.
    ///   - interval: Sampling period for ``start()``; `0` disables it.
    ///   - clock: Injected clock; tests advance a manual clock instead of
    ///     sleeping.
    public init(provider: any MemoryProxyProviding,
                monitor: BudgetMonitor = BudgetMonitor(),
                interval: TimeInterval = MemoryProxySignalSource.defaultIntervalSeconds,
                clock: any HostClock = SystemHostClock()) {
        self.provider = provider
        self.monitor = monitor
        self.interval = max(0, interval)
        self.clock = clock
    }

    /// Samples; the last sample is replayed.
    public var stream: AsyncStream<MemoryProxySample> { sampleHub.stream() }
    /// Budget decisions; the last decision is replayed.
    public var decisions: AsyncStream<BudgetDecision> { decisionHub.stream() }

    /// Starts sampling at ``interval``. Idempotent.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await self.refresh()
                let interval = self.interval
                guard interval > 0 else { break }
                await self.clock.sleep(for: interval)
                if Task.isCancelled { break }
            }
        }
        lock.withLock { pollTask = task }
    }

    /// Stops sampling and finishes both streams.
    public func stop() {
        let task: Task<Void, Never>? = lock.withLock {
            running = false
            let task = pollTask
            pollTask = nil
            return task
        }
        task?.cancel()
        sampleHub.finish()
        decisionHub.finish()
    }

    /// Samples once, evaluates the budget and publishes both values.
    @discardableResult
    public func refresh() async -> BudgetDecision {
        let sample = await provider.memoryProxySample()
        let decision = await monitor.evaluate(sample)
        sampleHub.yield(sample)
        decisionHub.yield(decision)
        return decision
    }
}
