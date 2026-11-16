// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Evaluates the real maintainer batch evidence produced by
/// `Tests/PhoneDSHBotTests/Maintenance/Quality/judge.py` against the G-frozen
/// quality gate. Skipped unless the evidence paths are supplied, so a normal
/// unit run never invents a quality verdict.
final class BotMaintenanceQualityEvidenceTests: XCTestCase {
    private struct Evidence: Decodable {
        var catalogSHA256: String
        var samples: [BotMaintenanceQualitySampleResult]
        var batches: [BotMaintenanceQualityBatchEvidence]
        var memorySuites: [BotMaintenanceMemorySuiteRegression]

        enum CodingKeys: String, CodingKey {
            case catalogSHA256 = "catalog_sha256"
            case samples, batches
            case memorySuites = "memory_suites"
        }
    }

    func testFrozenGateOverRealEvidence() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let evidencePath = environment["M_QUALITY_EVIDENCE"],
              let gatePath = environment["M_QUALITY_GATE"],
              let gateSHA = environment["M_QUALITY_GATE_SHA"],
              let outPath = environment["M_QUALITY_OUT"] else {
            throw XCTSkip("M_QUALITY_EVIDENCE/M_QUALITY_GATE(_SHA)/M_QUALITY_OUT not set")
        }
        let evidence = try JSONDecoder().decode(
            Evidence.self, from: Data(contentsOf: URL(fileURLWithPath: evidencePath)))
        let (spec, specSHA) = try BotMaintenanceQualityGate.loadSpec(
            at: URL(fileURLWithPath: gatePath), expectedSHA256: gateSHA)
        let evaluation = BotMaintenanceQualityGate.evaluate(
            spec: spec,
            specSHA256: specSHA,
            catalogSHA256: evidence.catalogSHA256,
            expectedCatalogSHA256: environment["M_QUALITY_CATALOG_SHA"],
            samples: evidence.samples,
            batches: evidence.batches,
            memorySuites: evidence.memorySuites,
            evaluatedAtMS: Int64(Date().timeIntervalSince1970 * 1_000))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evaluation).write(
            to: URL(fileURLWithPath: outPath), options: .atomic)
    }
}
