// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotMaintenanceQualityGateTests: XCTestCase {
    private let catalog = String(repeating: "a", count: 64)
    private let specSHA = String(repeating: "b", count: 64)

    private func spec(
        correction: Double = 0.75,
        stale: Double = 0.75,
        violations: Int = 0,
        falseVerified: Int = 0,
        regressions: Int = 0,
        minBatches: Int = 2,
        contradictionCount: Int = 2,
        staleCount: Int = 2,
        catalogSHA: String? = nil
    ) -> BotMaintenanceQualityGateSpec {
        BotMaintenanceQualityGateSpec(
            frozenBy: "G", gateRevision: "G-1",
            samples: .init(
                contradiction: contradictionCount, staleExternal: staleCount,
                catalogSHA256: catalogSHA ?? catalog,
                catalogSHA256Policy: "evaluator supplies the catalog SHA-256"),
            thresholds: .init(
                correctionRateMin: correction, staleDetectionRateMin: stale,
                mechanicalViolationsMax: violations,
                falseVerifiedMax: falseVerified,
                memorySuiteRegressionsMax: regressions,
                minRealBatches: minBatches, repeatCount: 1))
    }

    private func sample(
        _ id: String, _ kind: BotMaintenanceQualitySampleKind,
        status: BotMaintenanceQualitySampleStatus = .pass,
        corrected: Bool = true, preserved: Bool = false,
        stale: Bool = false
    ) -> BotMaintenanceQualitySampleResult {
        BotMaintenanceQualitySampleResult(
            id: id, kind: kind, status: status, corrected: corrected,
            preservedBothSides: preserved, staleDetected: stale)
    }

    private func batch(
        _ id: String = "mm-1", checks: Bool = true,
        falseVerified: Int = 0, violations: Int = 0
    ) -> BotMaintenanceQualityBatchEvidence {
        BotMaintenanceQualityBatchEvidence(
            batchID: id, status: "committed", checksPassed: checks,
            falseVerifiedDocuments: falseVerified,
            mechanicalViolations: violations, tokensUsed: 1_000)
    }

    private func memorySuite(
        baseline: Int = 0, candidate: Int = 0
    ) -> BotMaintenanceMemorySuiteRegression {
        BotMaintenanceMemorySuiteRegression(
            suite: "PhoneDSHBotTests.Memory", baselineFailures: baseline,
            candidateFailures: candidate)
    }

    private func evaluate(
        spec: BotMaintenanceQualityGateSpec,
        samples: [BotMaintenanceQualitySampleResult],
        batches: [BotMaintenanceQualityBatchEvidence],
        suites: [BotMaintenanceMemorySuiteRegression] = []
    ) -> BotMaintenanceQualityEvaluation {
        BotMaintenanceQualityGate.evaluate(
            spec: spec, specSHA256: specSHA, catalogSHA256: catalog,
            samples: samples, batches: batches, memorySuites: suites,
            evaluatedAtMS: 1_760_000_000_000)
    }

    func testAllThresholdsMetIsPass() {
        let result = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction),
                sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1"), batch("mm-2")],
            suites: [memorySuite()])
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.metrics.contradictionRate, 1.0)
        XCTAssertEqual(result.metrics.staleRate, 1.0)
        XCTAssertEqual(result.metrics.realBatches, 2)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testUncertainButBothSidesPreservedCountsAsCorrection() {
        let result = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction, corrected: false, preserved: true),
                sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1"), batch("mm-2")],
            suites: [memorySuite()])
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.metrics.contradictionCorrected, 2)
    }

    func testBelowRateFails() {
        let result = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction),
                sample("c2", .contradiction, corrected: false),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1"), batch("mm-2")],
            suites: [memorySuite()])
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertTrue(result.reasons.contains("correction-rate-below-threshold"))
    }

    func testFalseVerifiedFailsEvenWhenRatesPass() {
        let result = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction), sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1", falseVerified: 1), batch("mm-2")],
            suites: [memorySuite()])
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertTrue(result.reasons.contains("false-verified"))
    }

    func testMechanicalViolationOrCommittedFailedBatchFails() {
        let result = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction), sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1", checks: false, violations: 1), batch("mm-2")],
            suites: [memorySuite()])
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertTrue(result.reasons.contains("mechanical-violations"))
        XCTAssertTrue(result.reasons.contains("committed-batch-with-failed-checks"))
    }

    func testMemorySuiteRegressionFails() {
        let result = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction), sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1"), batch("mm-2")],
            suites: [memorySuite(baseline: 0, candidate: 1)])
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertTrue(result.reasons.contains("memory-suite-regression"))
    }

    func testMissingSamplesIsNotRunNotFail() {
        let result = evaluate(
            spec: spec(),
            samples: [sample("c1", .contradiction)],
            batches: [batch("mm-1"), batch("mm-2")],
            suites: [memorySuite()])
        XCTAssertEqual(result.verdict, .notRun)
        XCTAssertTrue(result.reasons.contains { $0.hasPrefix("missing-samples") })
    }

    func testMissingRealBatchesOrMemorySuiteIsNotRun() {
        let noBatches = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction), sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [],
            suites: [memorySuite()])
        XCTAssertEqual(noBatches.verdict, .notRun)
        XCTAssertTrue(noBatches.reasons.contains("too-few-real-batches"))

        let noSuite = evaluate(
            spec: spec(),
            samples: [
                sample("c1", .contradiction), sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1"), batch("mm-2")],
            suites: [])
        XCTAssertEqual(noSuite.verdict, .notRun)
        XCTAssertTrue(noSuite.reasons.contains("memory-suite-not-run"))
    }

    func testCatalogMismatchIsNotRun() {
        let spec = spec(catalogSHA: String(repeating: "c", count: 64))
        let result = BotMaintenanceQualityGate.evaluate(
            spec: spec, specSHA256: specSHA, catalogSHA256: catalog,
            samples: [
                sample("c1", .contradiction), sample("c2", .contradiction),
                sample("s1", .staleExternal, stale: true),
                sample("s2", .staleExternal, stale: true),
            ],
            batches: [batch("mm-1"), batch("mm-2")],
            memorySuites: [memorySuite()],
            evaluatedAtMS: 1_760_000_000_000)
        XCTAssertEqual(result.verdict, .notRun)
        XCTAssertTrue(result.reasons.contains("catalog-sha-mismatch"))
    }

    func testFrozenSpecHashMismatchIsRejected() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m-gate-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(spec())
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let actual = BotMaintenanceQualityGate.sha256Hex(data)
        XCTAssertNoThrow(try BotMaintenanceQualityGate.loadSpec(
            at: url, expectedSHA256: actual))
        XCTAssertThrowsError(try BotMaintenanceQualityGate.loadSpec(
            at: url, expectedSHA256: String(repeating: "0", count: 64))) { error in
            guard case BotMaintenanceQualityGateError.specHashMismatch = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testSpecWithoutSamplesIsInvalid() throws {
        let spec = spec(contradictionCount: 0, staleCount: 0)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m-gate-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(spec)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BotMaintenanceQualityGate.loadSpec(
            at: url, expectedSHA256: BotMaintenanceQualityGate.sha256Hex(data)))
    }
}
