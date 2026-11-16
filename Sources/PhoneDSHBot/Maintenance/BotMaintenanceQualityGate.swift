// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Independent quality gate for the background memory maintainer (E5).
///
/// The gate does not trust the maintainer model's self-report. It consumes
/// deterministic sample results produced from real maintainer batches (durable
/// events + final memory documents + the records they cite) and the frozen
/// thresholds from `spec/bot/v2/maintenance-quality-gate.json` (G-owned,
/// G-1 @ 45ab603e3). A missing/mismatched spec, too few real batches, an
/// unpinned catalog or missing memory-suite evidence is `not_run`, never
/// `pass`.
///
/// Enabling the maintainer stays a user action: a `pass` verdict is evidence
/// for the user/UI, this module never writes `enabled = true`.

public enum BotMaintenanceQualityVerdict: String, Codable, Sendable, Equatable {
    case pass
    case fail
    case notRun = "not_run"
}

public enum BotMaintenanceQualitySampleKind: String, Codable, Sendable, Equatable {
    case contradiction
    case staleExternal = "stale-external"
}

public enum BotMaintenanceQualitySampleStatus: String, Codable, Sendable, Equatable {
    case pass
    case fail
    case invalid
    case notRun = "not_run"
}

public struct BotMaintenanceQualityThresholds: Codable, Sendable, Equatable {
    public var correctionRateMin: Double
    public var staleDetectionRateMin: Double
    public var mechanicalViolationsMax: Int
    public var falseVerifiedMax: Int
    public var memorySuiteRegressionsMax: Int
    public var minRealBatches: Int
    public var repeatCount: Int

    public init(correctionRateMin: Double, staleDetectionRateMin: Double,
                mechanicalViolationsMax: Int, falseVerifiedMax: Int,
                memorySuiteRegressionsMax: Int, minRealBatches: Int,
                repeatCount: Int) {
        self.correctionRateMin = correctionRateMin
        self.staleDetectionRateMin = staleDetectionRateMin
        self.mechanicalViolationsMax = max(0, mechanicalViolationsMax)
        self.falseVerifiedMax = max(0, falseVerifiedMax)
        self.memorySuiteRegressionsMax = max(0, memorySuiteRegressionsMax)
        self.minRealBatches = max(1, minRealBatches)
        self.repeatCount = max(1, repeatCount)
    }

    enum CodingKeys: String, CodingKey {
        case correctionRateMin = "correction_rate_min"
        case staleDetectionRateMin = "stale_detection_rate_min"
        case mechanicalViolationsMax = "mechanical_violations_max"
        case falseVerifiedMax = "false_verified_max"
        case memorySuiteRegressionsMax = "memory_suite_regressions_max"
        case minRealBatches = "min_real_batches"
        case repeatCount = "repeat"
    }
}

/// `samples` in the frozen JSON is an object (not an array):
/// `{"contradiction": 2, "stale_external": 2, "catalog_sha256_policy": …}`.
/// `catalog_sha256` is an optional extension; while it is absent the evaluator
/// must be given the frozen catalog digest by the evidence run and the result
/// is NOT_RUN if that digest is missing.
public struct BotMaintenanceQualitySampleCounts: Codable, Sendable, Equatable {
    public var contradiction: Int
    public var staleExternal: Int
    public var catalogSHA256: String?
    public var catalogSHA256Policy: String?

    public init(contradiction: Int, staleExternal: Int,
                catalogSHA256: String? = nil,
                catalogSHA256Policy: String? = nil) {
        self.contradiction = max(0, contradiction)
        self.staleExternal = max(0, staleExternal)
        self.catalogSHA256 = catalogSHA256
        self.catalogSHA256Policy = catalogSHA256Policy
    }

    enum CodingKeys: String, CodingKey {
        case contradiction
        case staleExternal = "stale_external"
        case catalogSHA256 = "catalog_sha256"
        case catalogSHA256Policy = "catalog_sha256_policy"
    }
}

public struct BotMaintenanceQualityGateSpec: Codable, Sendable, Equatable {
    public var schema: String
    public var frozenBy: String
    public var gateRevision: String
    public var defaultState: String
    public var samples: BotMaintenanceQualitySampleCounts
    public var thresholds: BotMaintenanceQualityThresholds
    public var judge: String
    public var notes: [String]?

    public init(schema: String = "bot-maintenance-quality-gate/v1",
                frozenBy: String, gateRevision: String,
                defaultState: String = "off",
                samples: BotMaintenanceQualitySampleCounts,
                thresholds: BotMaintenanceQualityThresholds,
                judge: String = "deterministic-independent",
                notes: [String]? = nil) {
        self.schema = schema
        self.frozenBy = frozenBy
        self.gateRevision = gateRevision
        self.defaultState = defaultState
        self.samples = samples
        self.thresholds = thresholds
        self.judge = judge
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case frozenBy = "frozen_by"
        case gateRevision = "gate_revision"
        case defaultState = "default_state"
        case samples, thresholds, judge, notes
    }
}

// MARK: - Evidence

public struct BotMaintenanceQualitySampleResult: Codable, Sendable, Equatable {
    public var id: String
    public var kind: BotMaintenanceQualitySampleKind
    public var status: BotMaintenanceQualitySampleStatus
    /// The contradicted/old claim is gone or explicitly marked uncertain.
    public var corrected: Bool
    /// An uncertain result keeps both claims and their record references.
    public var preservedBothSides: Bool
    /// A newer external observation replaced or flagged the stale claim.
    public var staleDetected: Bool
    public var detail: String

    public init(id: String, kind: BotMaintenanceQualitySampleKind,
                status: BotMaintenanceQualitySampleStatus,
                corrected: Bool, preservedBothSides: Bool,
                staleDetected: Bool, detail: String = "") {
        self.id = id
        self.kind = kind
        self.status = status
        self.corrected = corrected
        self.preservedBothSides = preservedBothSides
        self.staleDetected = staleDetected
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, status, corrected, detail
        case preservedBothSides = "preserved_both_sides"
        case staleDetected = "stale_detected"
    }
}

public struct BotMaintenanceQualityBatchEvidence: Codable, Sendable, Equatable {
    public var batchID: String
    public var status: String
    public var checksPassed: Bool
    /// Committed documents whose persisted `review=verified` was not backed
    /// by the host recheck.
    public var falseVerifiedDocuments: Int
    /// Host mechanical-check failures (any of the five checks).
    public var mechanicalViolations: Int
    public var tokensUsed: Int

    public init(batchID: String, status: String, checksPassed: Bool,
                falseVerifiedDocuments: Int, mechanicalViolations: Int,
                tokensUsed: Int) {
        self.batchID = batchID
        self.status = status
        self.checksPassed = checksPassed
        self.falseVerifiedDocuments = falseVerifiedDocuments
        self.mechanicalViolations = mechanicalViolations
        self.tokensUsed = tokensUsed
    }

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case status
        case checksPassed = "checks_passed"
        case falseVerifiedDocuments = "false_verified_documents"
        case mechanicalViolations = "mechanical_violations"
        case tokensUsed = "tokens_used"
    }
}

public struct BotMaintenanceMemorySuiteRegression: Codable, Sendable, Equatable {
    public var suite: String
    public var baselineFailures: Int
    public var candidateFailures: Int

    public init(suite: String, baselineFailures: Int, candidateFailures: Int) {
        self.suite = suite
        self.baselineFailures = max(0, baselineFailures)
        self.candidateFailures = max(0, candidateFailures)
    }

    public var regressions: Int { max(0, candidateFailures - baselineFailures) }

    enum CodingKeys: String, CodingKey {
        case suite
        case baselineFailures = "baseline_failures"
        case candidateFailures = "candidate_failures"
    }
}

public struct BotMaintenanceQualityMetrics: Codable, Sendable, Equatable {
    public var contradictionSamples: Int
    public var contradictionCorrected: Int
    public var contradictionRate: Double
    public var staleSamples: Int
    public var staleDetected: Int
    public var staleRate: Double
    public var realBatches: Int
    public var mechanicalViolations: Int
    public var falseVerifiedDocuments: Int
    public var memorySuiteRegressions: Int

    enum CodingKeys: String, CodingKey {
        case contradictionSamples = "contradiction_samples"
        case contradictionCorrected = "contradiction_corrected"
        case contradictionRate = "contradiction_rate"
        case staleSamples = "stale_samples"
        case staleDetected = "stale_detected"
        case staleRate = "stale_rate"
        case realBatches = "real_batches"
        case mechanicalViolations = "mechanical_violations"
        case falseVerifiedDocuments = "false_verified_documents"
        case memorySuiteRegressions = "memory_suite_regressions"
    }
}

public struct BotMaintenanceQualityEvaluation: Codable, Sendable, Equatable {
    public var verdict: BotMaintenanceQualityVerdict
    public var reasons: [String]
    public var specSHA256: String
    public var gateRevision: String
    public var catalogSHA256: String
    public var evaluatedAtMS: Int64
    public var metrics: BotMaintenanceQualityMetrics
    public var samples: [BotMaintenanceQualitySampleResult]
    public var batches: [BotMaintenanceQualityBatchEvidence]
    public var memorySuites: [BotMaintenanceMemorySuiteRegression]

    public init(verdict: BotMaintenanceQualityVerdict, reasons: [String],
                specSHA256: String, gateRevision: String,
                catalogSHA256: String, evaluatedAtMS: Int64,
                metrics: BotMaintenanceQualityMetrics,
                samples: [BotMaintenanceQualitySampleResult],
                batches: [BotMaintenanceQualityBatchEvidence],
                memorySuites: [BotMaintenanceMemorySuiteRegression]) {
        self.verdict = verdict
        self.reasons = reasons
        self.specSHA256 = specSHA256
        self.gateRevision = gateRevision
        self.catalogSHA256 = catalogSHA256
        self.evaluatedAtMS = evaluatedAtMS
        self.metrics = metrics
        self.samples = samples
        self.batches = batches
        self.memorySuites = memorySuites
    }

    enum CodingKeys: String, CodingKey {
        case verdict, reasons, samples, batches, metrics
        case specSHA256 = "spec_sha256"
        case gateRevision = "gate_revision"
        case catalogSHA256 = "catalog_sha256"
        case evaluatedAtMS = "evaluated_at_ms"
        case memorySuites = "memory_suites"
    }
}

// MARK: - Loading the frozen spec

public enum BotMaintenanceQualityGateError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case specUnreadable(String)
    case specHashMismatch(expected: String, actual: String)
    case specInvalid(String)

    public var description: String {
        switch self {
        case .specUnreadable(let reason):
            return "maintenance quality gate spec is unreadable: \(reason)"
        case .specHashMismatch(let expected, let actual):
            return "maintenance quality gate spec hash \(actual) != frozen \(expected)"
        case .specInvalid(let reason):
            return "maintenance quality gate spec is invalid: \(reason)"
        }
    }
}

public enum BotMaintenanceQualityGate {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads the G-frozen spec and refuses anything but the expected bytes.
    public static func loadSpec(at url: URL,
                                expectedSHA256: String) throws
        -> (spec: BotMaintenanceQualityGateSpec, sha256: String) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BotMaintenanceQualityGateError.specUnreadable(
                error.localizedDescription)
        }
        let actual = sha256Hex(data)
        guard actual == expectedSHA256.lowercased() else {
            throw BotMaintenanceQualityGateError.specHashMismatch(
                expected: expectedSHA256.lowercased(), actual: actual)
        }
        do {
            let spec = try JSONDecoder().decode(
                BotMaintenanceQualityGateSpec.self, from: data)
            guard spec.schema == "bot-maintenance-quality-gate/v1" else {
                throw BotMaintenanceQualityGateError.specInvalid(
                    "unsupported schema \(spec.schema)")
            }
            guard !spec.frozenBy.isEmpty, !spec.gateRevision.isEmpty else {
                throw BotMaintenanceQualityGateError.specInvalid(
                    "frozen_by/gate_revision missing")
            }
            guard spec.samples.contradiction > 0,
                  spec.samples.staleExternal > 0 else {
                throw BotMaintenanceQualityGateError.specInvalid(
                    "sample counts must be positive")
            }
            return (spec, actual)
        } catch let error as BotMaintenanceQualityGateError {
            throw error
        } catch {
            throw BotMaintenanceQualityGateError.specInvalid(
                error.localizedDescription)
        }
    }

    /// Deterministic aggregation. Every declared sample must be present and
    /// marked pass/fail; invalid/not-run samples stay in the denominator so a
    /// model or harness cannot shrink its way to a pass.
    public static func evaluate(
        spec: BotMaintenanceQualityGateSpec,
        specSHA256: String,
        catalogSHA256: String,
        expectedCatalogSHA256: String? = nil,
        samples: [BotMaintenanceQualitySampleResult],
        batches: [BotMaintenanceQualityBatchEvidence],
        memorySuites: [BotMaintenanceMemorySuiteRegression],
        evaluatedAtMS: Int64
    ) -> BotMaintenanceQualityEvaluation {
        var reasons: [String] = []

        let pinnedCatalog = spec.samples.catalogSHA256 ?? expectedCatalogSHA256
        if let pinnedCatalog {
            if catalogSHA256.lowercased() != pinnedCatalog.lowercased() {
                reasons.append("catalog-sha-mismatch")
            }
        } else {
            reasons.append("catalog-sha-unpinned")
        }
        let realBatches = batches.count
        if realBatches < spec.thresholds.minRealBatches {
            reasons.append("too-few-real-batches")
        }
        for batch in batches where batch.status == "committed" && !batch.checksPassed {
            reasons.append("committed-batch-with-failed-checks")
        }
        let mechanicalViolations = batches.reduce(0) {
            $0 + max(0, $1.mechanicalViolations)
        }
        let falseVerified = batches.reduce(0) {
            $0 + max(0, $1.falseVerifiedDocuments)
        }
        if mechanicalViolations > spec.thresholds.mechanicalViolationsMax {
            reasons.append("mechanical-violations")
        }
        if falseVerified > spec.thresholds.falseVerifiedMax {
            reasons.append("false-verified")
        }
        let regressions = memorySuites.reduce(0) { $0 + $1.regressions }
        if regressions > spec.thresholds.memorySuiteRegressionsMax {
            reasons.append("memory-suite-regression")
        }
        if memorySuites.isEmpty {
            reasons.append("memory-suite-not-run")
        }

        let contradictionTotal = spec.samples.contradiction
        let contradictionMatching = samples.filter { $0.kind == .contradiction }
        if contradictionMatching.count < contradictionTotal {
            reasons.append("missing-samples:contradiction")
        }
        let contradictionPassed = contradictionMatching.filter {
            $0.status == .pass && ($0.corrected
                || ($0.preservedBothSides && $0.corrected == false))
        }.count
        let staleTotal = spec.samples.staleExternal
        let staleMatching = samples.filter { $0.kind == .staleExternal }
        if staleMatching.count < staleTotal {
            reasons.append("missing-samples:stale-external")
        }
        let stalePassed = staleMatching.filter {
            $0.status == .pass && $0.staleDetected
        }.count

        let correctionRate = contradictionTotal == 0 ? 0
            : Double(contradictionPassed) / Double(contradictionTotal)
        let staleRate = staleTotal == 0 ? 0
            : Double(stalePassed) / Double(staleTotal)
        if contradictionTotal == 0 {
            reasons.append("no-contradiction-samples")
        } else if correctionRate < spec.thresholds.correctionRateMin {
            reasons.append("correction-rate-below-threshold")
        }
        if staleTotal == 0 {
            reasons.append("no-stale-samples")
        } else if staleRate < spec.thresholds.staleDetectionRateMin {
            reasons.append("stale-rate-below-threshold")
        }

        let metrics = BotMaintenanceQualityMetrics(
            contradictionSamples: contradictionTotal,
            contradictionCorrected: contradictionPassed,
            contradictionRate: correctionRate,
            staleSamples: staleTotal,
            staleDetected: stalePassed,
            staleRate: staleRate,
            realBatches: realBatches,
            mechanicalViolations: mechanicalViolations,
            falseVerifiedDocuments: falseVerified,
            memorySuiteRegressions: regressions)
        let notRunReasons = reasons.contains(where: {
            $0.hasPrefix("missing-samples")
                || $0 == "too-few-real-batches"
                || $0 == "memory-suite-not-run"
                || $0 == "catalog-sha-mismatch"
                || $0 == "catalog-sha-unpinned"
        })
        let verdict: BotMaintenanceQualityVerdict
        if reasons.isEmpty {
            verdict = .pass
        } else if notRunReasons {
            verdict = .notRun
        } else {
            verdict = .fail
        }
        return BotMaintenanceQualityEvaluation(
            verdict: verdict, reasons: reasons.sorted(),
            specSHA256: specSHA256,
            gateRevision: spec.gateRevision,
            catalogSHA256: catalogSHA256,
            evaluatedAtMS: evaluatedAtMS,
            metrics: metrics, samples: samples, batches: batches,
            memorySuites: memorySuites)
    }
}
