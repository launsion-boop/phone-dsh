// SPDX-License-Identifier: MIT
// PLAN §2.9 I4: ReadySweep is a registry of sources. These cases prove the
// order, the per-source lease gate, `due`, failure isolation and that a source
// added later needs no orchestrator change.
import XCTest
import ProbeKit

@MainActor
final class ReadySweepRegistryTests: XCTestCase {
    private final class FakeSource: ReadySweepSource {
        let id: ReadySweepStep
        var isDue: Bool
        var outcome: ReadySweepOutcome
        private(set) var runs = 0

        init(_ id: ReadySweepStep, due: Bool = true, outcome: ReadySweepOutcome = .ran) {
            self.id = id
            self.isDue = due
            self.outcome = outcome
        }

        func due(nowMs: Int64) async -> Bool { isDue }

        func run(_ context: ReadySweepContext) async -> ReadySweepOutcome {
            runs += 1
            return outcome
        }
    }

    private func context(remaining: Int64 = .max) -> ReadySweepContext {
        ReadySweepContext(wakeId: "w", reason: .scheduledDemand,
                          engineIncarnation: 1, remainingMs: { remaining })
    }

    func testEveryContractSourceAppearsInOrder() async {
        let all = ReadySweepStep.allCases.map { FakeSource($0) }
        let registry = ReadySweepRegistry(providers: [{ all }])
        let report = await registry.run(context(), nowMs: 0)
        XCTAssertEqual(report.steps.map(\.step), ReadySweepStep.allCases)
        XCTAssertEqual(report.steps.map(\.outcome), Array(repeating: .ran, count: all.count))
    }

    func testMissingSourceIsReportedNotSilentlySkipped() async {
        let source = FakeSource(.userOutbox)
        let registry = ReadySweepRegistry(providers: [{ [source] }])
        let report = await registry.run(context(), nowMs: 0)
        XCTAssertEqual(report.outcome(for: .userOutbox), .ran)
        XCTAssertEqual(report.outcome(for: .hostRetries), .failed(reason: "source_unavailable"))
        XCTAssertEqual(report.steps.count, ReadySweepStep.allCases.count)
    }

    func testLeaseGateIsCheckedPerSource() async {
        // The approval budget is 1 s + 5 s margin; the connector budget 10 s +
        // margin. 8 s clears the first gate and not the second.
        let source = FakeSource(.approvalReminderSync)
        let connector = FakeSource(.connectorScan)
        let registry = ReadySweepRegistry(providers: [{ [source, connector] }])
        let report = await registry.run(context(remaining: 8_000), nowMs: 0)
        XCTAssertEqual(report.outcome(for: .approvalReminderSync), .ran)
        XCTAssertEqual(report.outcome(for: .connectorScan), .skipped(.lease))
        XCTAssertEqual(connector.runs, 0)
    }

    func testNotDueSourceDoesNotRun() async {
        let source = FakeSource(.botHeldInbox, due: false)
        let registry = ReadySweepRegistry(providers: [{ [source] }])
        let report = await registry.run(context(), nowMs: 0)
        XCTAssertEqual(report.outcome(for: .botHeldInbox), .skipped(.noWork))
        XCTAssertEqual(source.runs, 0)
    }

    func testFailureIsIsolatedToItsSource() async {
        let failing = FakeSource(.externalAdmission, outcome: .failed(reason: "boom"))
        let next = FakeSource(.cloudTaskPull)
        let registry = ReadySweepRegistry(providers: [{ [failing, next] }])
        let report = await registry.run(context(), nowMs: 0)
        XCTAssertEqual(report.outcome(for: .externalAdmission), .failed(reason: "boom"))
        XCTAssertEqual(report.outcome(for: .cloudTaskPull), .ran)
        XCTAssertEqual(next.runs, 1)
    }

    func testProvidersResolveAtRunTime() async {
        var sources: [any ReadySweepSource] = []
        let registry = ReadySweepRegistry(providers: [{ sources }])
        let first = await registry.run(context(), nowMs: 0)
        XCTAssertEqual(first.outcome(for: .dshSchedule), .failed(reason: "source_unavailable"))
        let added = FakeSource(.dshSchedule)
        sources = [added]
        let second = await registry.run(context(), nowMs: 0)
        XCTAssertEqual(second.outcome(for: .dshSchedule), .ran)
    }
}
