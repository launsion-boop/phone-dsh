// SPDX-License-Identifier: MIT
// Host §10.2–§10.3 golden vectors: the ONE spec file drives the Swift state
// machine. No vector is copied here.
//
// The file is bundled into this test target by project.yml
// (`spec/host/v1/golden/engine-launch.json`).
import XCTest
import ProbeKit

final class EngineLaunchGoldenTests: XCTestCase {
    // MARK: - Contract document (test-side decoder, not a production codec)

    private struct Golden: Decodable {
        struct Instance: Decodable {
            let contract: String
            let revision: Int
            let constants: Constants
            let wakeReasons: [String]
            let decisions: [String]
            let steps: [String]
            let demandSources: [String]
            let decisionVectors: [DecisionVector]
            let invalidDecisionVectors: [InvalidVector]
            let sweepVectors: [SweepVector]
            let invalidSweepVectors: [InvalidVector]
            let projectionVectors: [ProjectionVector]
            let invalidProjectionVectors: [InvalidVector]
        }

        struct Constants: Decodable {
            let minLeaseForColdBootMs: Int64
            let minLeaseForResumeMs: Int64
            let parkMarginMs: Int64
            let cloudPullFreshnessMs: Int64
            let connectorScanIntervalMs: Int64
            let minBackgroundDelayMs: Int64
            let stepBudgetMs: [String: Int64]
        }

        struct DecisionVector: Decodable {
            let id: String
            let input: StrictDecisionInput
            let expected: String
            let note: String?
        }

        struct SweepVector: Decodable {
            let id: String
            let step: String
            let remainingMs: Int64
            let expected: String
            let note: String?
        }

        struct ProjectionVector: Decodable {
            let id: String
            let input: WakeProjectionRequest
            let expected: WakeProjection
            let note: String?
        }

        struct InvalidVector: Decodable {
            let id: String
            let input: AnyJSON
            let reason: String
            let note: String?
        }

        let instance: Instance
    }

    private struct Rejection: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// The strict decoder the contract's invalid decision vectors must reject,
    /// with the golden's own reason vocabulary.
    private struct StrictDecisionInput: Decodable {
        let reason: WakeReason
        let foreground: Bool
        let residentAudio: Bool
        let hostState: EngineHostState
        let leaseRemainingMs: Int64?
        let userStopped: Bool
        let needsReset: Bool

        enum CodingKeys: String, CodingKey {
            case reason
            case foreground
            case residentAudio
            case hostState
            case leaseRemainingMs
            case userStopped
            case needsReset
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.reason) else { throw Rejection("missing-member") }
            guard let reasonName = try? c.decode(String.self, forKey: .reason) else {
                throw Rejection("member-type")
            }
            guard let reason = WakeReason(rawValue: reasonName) else {
                throw Rejection("unknown-reason")
            }
            self.reason = reason

            guard c.contains(.foreground),
                  let foreground = try? c.decode(Bool.self, forKey: .foreground) else {
                throw Rejection(c.contains(.foreground) ? "member-type" : "missing-member")
            }
            self.foreground = foreground

            guard c.contains(.residentAudio),
                  let residentAudio = try? c.decode(Bool.self, forKey: .residentAudio) else {
                throw Rejection(c.contains(.residentAudio) ? "member-type" : "missing-member")
            }
            self.residentAudio = residentAudio

            guard c.contains(.hostState) else { throw Rejection("missing-member") }
            guard let hostName = try? c.decode(String.self, forKey: .hostState) else {
                throw Rejection("member-type")
            }
            guard let host = EngineHostState(rawValue: hostName) else {
                throw Rejection("unknown-host-state")
            }
            self.hostState = host

            guard c.contains(.leaseRemainingMs) else { throw Rejection("missing-member") }
            if try c.decodeNil(forKey: .leaseRemainingMs) {
                leaseRemainingMs = nil
            } else {
                guard let lease = try? c.decode(Int64.self, forKey: .leaseRemainingMs) else {
                    throw Rejection("lease-not-integer")
                }
                guard lease >= 0 else { throw Rejection("lease-negative") }
                leaseRemainingMs = lease
            }

            guard c.contains(.userStopped),
                  let userStopped = try? c.decode(Bool.self, forKey: .userStopped) else {
                throw Rejection(c.contains(.userStopped) ? "member-type" : "missing-member")
            }
            self.userStopped = userStopped

            guard c.contains(.needsReset),
                  let needsReset = try? c.decode(Bool.self, forKey: .needsReset) else {
                throw Rejection(c.contains(.needsReset) ? "member-type" : "missing-member")
            }
            self.needsReset = needsReset
        }
    }

    private struct StrictSweepInput: Decodable {
        enum CodingKeys: String, CodingKey {
            case step
            case remainingMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.step) else { throw Rejection("missing-member") }
            guard let stepName = try? c.decode(String.self, forKey: .step) else {
                throw Rejection("member-type")
            }
            guard ReadySweepStep(rawValue: stepName) != nil else {
                throw Rejection("unknown-step")
            }
            guard c.contains(.remainingMs) else { throw Rejection("missing-member") }
            guard let remaining = try? c.decode(Int64.self, forKey: .remainingMs) else {
                throw Rejection("member-type")
            }
            guard remaining >= 0 else { throw Rejection("remaining-negative") }
        }
    }

    /// Any JSON value, so an invalid vector's input can be re-decoded strictly.
    private enum AnyJSON: Codable {
        case null
        case bool(Bool)
        case integer(Int64)
        case double(Double)
        case string(String)
        case array([AnyJSON])
        case object([String: AnyJSON])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Int64.self) { self = .integer(v); return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
            if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .integer(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }

        var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: data)
        }
    }

    // MARK: - Loading

    private enum GoldenError: Error { case missing }

    private func loadGolden() throws -> Golden {
        guard let url = goldenURL() else {
            XCTFail("spec/host/v1/golden/engine-launch.json is missing")
            throw GoldenError.missing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Golden.self, from: data)
    }

    private func goldenURL() -> URL? {
        if let bundled = Bundle(for: Self.self).url(forResource: "engine-launch",
                                                    withExtension: "json") {
            return bundled
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let path = url.appendingPathComponent("spec/host/v1/golden/engine-launch.json")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Closed sets and constants

    func testClosedSetsMatchTheFrozenContract() throws {
        let golden = try loadGolden()
        let instance = golden.instance
        XCTAssertEqual(instance.contract, "engine-launch")
        XCTAssertGreaterThanOrEqual(instance.revision, 2)

        XCTAssertEqual(instance.wakeReasons.count, WakeReason.allCases.count)
        XCTAssertEqual(Set(instance.wakeReasons), Set(WakeReason.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(instance.decisions), Set(EngineLaunchDecision.allCases.map(\.rawValue)))
        XCTAssertEqual(instance.steps, ReadySweepStep.allCases.map(\.rawValue))
        XCTAssertEqual(instance.demandSources, WakeDemandSource.allCases.map(\.rawValue))
    }

    func testConstantsAreTheOnesTheCodeUses() throws {
        let golden = try loadGolden()
        let c = golden.instance.constants
        XCTAssertEqual(EngineLaunchThresholds.minLeaseForColdBootMs, c.minLeaseForColdBootMs)
        XCTAssertEqual(EngineLaunchThresholds.minLeaseForResumeMs, c.minLeaseForResumeMs)
        XCTAssertEqual(EngineLaunchThresholds.parkMarginMs, c.parkMarginMs)
        XCTAssertEqual(EngineLaunchThresholds.cloudPullFreshnessMs, c.cloudPullFreshnessMs)
        XCTAssertEqual(EngineLaunchThresholds.connectorScanIntervalMs, c.connectorScanIntervalMs)
        XCTAssertEqual(EngineLaunchThresholds.minBackgroundDelayMs, c.minBackgroundDelayMs)

        XCTAssertEqual(Set(c.stepBudgetMs.keys), Set(ReadySweepStep.allCases.map(\.rawValue)))
        for step in ReadySweepStep.allCases {
            XCTAssertEqual(c.stepBudgetMs[step.rawValue],
                           ReadySweepPolicy.stepBudgetMs(for: step), "\(step)")
        }
    }

    // MARK: - Decision vectors

    func testDecisionVectorsDriveTheRealPolicy() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.instance.decisionVectors.isEmpty)
        for vector in golden.instance.decisionVectors {
            let input = vector.input
            let expected = try XCTUnwrap(EngineLaunchDecision(rawValue: vector.expected),
                                         "unknown expected decision \(vector.expected)")
            let decision = EngineLaunchPolicy.decide(
                reason: input.reason,
                foreground: input.foreground,
                residentAudio: input.residentAudio,
                hostState: input.hostState,
                leaseRemainingMs: input.leaseRemainingMs,
                userStopped: input.userStopped,
                needsReset: input.needsReset)
            XCTAssertEqual(decision, expected,
                           "vector \(vector.id): \(String(describing: vector.note))")
        }
    }

    func testInvalidDecisionVectorsAreRejectedWithTheStatedReason() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.instance.invalidDecisionVectors.isEmpty)
        for vector in golden.instance.invalidDecisionVectors {
            XCTAssertThrowsError(
                try vector.input.decode(StrictDecisionInput.self),
                "vector \(vector.id) must be rejected: \(vector.reason)"
            ) { error in
                XCTAssertEqual((error as? Rejection)?.reason, vector.reason,
                               "vector \(vector.id): \(error)")
            }
        }
    }

    // MARK: - Sweep vectors

    func testSweepVectorsDriveTheRealGate() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.instance.sweepVectors.isEmpty)
        for vector in golden.instance.sweepVectors {
            let step = try XCTUnwrap(ReadySweepStep(rawValue: vector.step),
                                     "unknown step \(vector.step) in \(vector.id)")
            let expected: Bool
            switch vector.expected {
            case "run": expected = true
            case "skip": expected = false
            default: XCTFail("vector \(vector.id): unknown expected \(vector.expected)"); continue
            }
            XCTAssertEqual(ReadySweepPolicy.shouldRun(step, remainingMs: vector.remainingMs),
                           expected, "vector \(vector.id): \(String(describing: vector.note))")
        }
    }

    func testInvalidSweepVectorsAreRejectedWithTheStatedReason() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.instance.invalidSweepVectors.isEmpty)
        for vector in golden.instance.invalidSweepVectors {
            XCTAssertThrowsError(
                try vector.input.decode(StrictSweepInput.self),
                "vector \(vector.id) must be rejected: \(vector.reason)"
            ) { error in
                XCTAssertEqual((error as? Rejection)?.reason, vector.reason,
                               "vector \(vector.id): \(error)")
            }
        }
    }

    // MARK: - Projection vectors

    func testProjectionVectorsDriveTheRealPlan() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.instance.projectionVectors.isEmpty)
        for vector in golden.instance.projectionVectors {
            let plan = WakeProjection.plan(vector.input)
            XCTAssertEqual(plan, vector.expected,
                           "vector \(vector.id): \(String(describing: vector.note))")
        }
    }

    func testInvalidProjectionVectorsAreRejectedWithTheStatedReason() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.instance.invalidProjectionVectors.isEmpty)
        for vector in golden.instance.invalidProjectionVectors {
            XCTAssertThrowsError(
                try vector.input.decode(WakeProjectionRequest.self),
                "vector \(vector.id) must be rejected: \(vector.reason)"
            ) { error in
                let typed = error as? WakeContractError
                XCTAssertEqual(typed?.rawValue, vector.reason,
                               "vector \(vector.id): \(error)")
            }
        }
    }
}
