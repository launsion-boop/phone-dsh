// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ReadySweep as a registry of demand sources.
//
// PLAN §2.9 / host contract §10.3 (I4): every ReadySweep step is a source with
// `id`, `due(now)` and `run(context)`; the orchestrator owns the registry and
// never grows a new `switch` when a source is added. Steps 1–3 are native and
// live here/app-side; steps 4–7 belong to the Bot composition; steps 8–9
// (DSH schedule mirror, host-owned retries) are hosted by the orchestrator.

import Foundation

/// One registered source of ReadySweep work.
@MainActor
public protocol ReadySweepSource: AnyObject {
    /// The contract identity and position of this source.
    var id: ReadySweepStep { get }

    /// Whether this source has work due at `nowMs`. The registry asks this
    /// after the lease gate, so a source never runs without budget; returning
    /// false is reported as `skipped("not-due")`, not as a failure.
    func due(nowMs: Int64) async -> Bool

    /// Runs exactly this source's step. It must be idempotent: a lost wake
    /// runs it again rather than losing work.
    func run(_ context: ReadySweepContext) async -> ReadySweepOutcome
}

/// The one ReadySweep pass: enumerate the contract sources in order, give each
/// the lease gate, then run the due ones. A source that is absent from the
/// registry is reported, never silently skipped.
@MainActor
public final class ReadySweepRegistry {
    /// Sources are resolved at run time: the Bot composition is created after
    /// phase A, so its four sources cannot be frozen at registry construction.
    public typealias SourceProvider = @MainActor () -> [any ReadySweepSource]

    private var providers: [SourceProvider]

    public init(providers: [SourceProvider] = []) {
        self.providers = providers
    }

    public func addProvider(_ provider: @escaping SourceProvider) {
        providers.append(provider)
    }

    /// Every registered source, keyed by contract id (last provider wins).
    public func sources() -> [ReadySweepStep: any ReadySweepSource] {
        var byID: [ReadySweepStep: any ReadySweepSource] = [:]
        for provider in providers {
            for source in provider() { byID[source.id] = source }
        }
        return byID
    }

    /// One pass over every contract source (PLAN §2.9 source order).
    ///
    /// The lease is re-read for every source; an unfinished source is skipped
    /// whole for the next wake (never half-run). A source failure is recorded
    /// and the pass continues.
    public func run(_ context: ReadySweepContext,
                    nowMs: Int64 = Int64((Date().timeIntervalSince1970 * 1000).rounded())) async -> ReadySweepReport {
        let byID = sources()
        var report = ReadySweepReport()
        for step in ReadySweepStep.allCases {
            guard let source = byID[step] else {
                report.record(step, .failed(reason: "source_unavailable"))
                continue
            }
            guard ReadySweepPolicy.shouldRun(step, remainingMs: context.remainingMs()) else {
                report.record(step, .skipped(.lease))
                continue
            }
            guard await source.due(nowMs: nowMs) else {
                report.record(step, .skipped(.noWork))
                continue
            }
            report.record(step, await source.run(context))
        }
        return report
    }
}
