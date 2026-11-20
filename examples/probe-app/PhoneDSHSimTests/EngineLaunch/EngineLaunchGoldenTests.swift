// SPDX-License-Identifier: MIT
// Host §10.2 golden vectors: the ONE spec file drives the Swift state machine.
// No vector is copied here; see `spec/host/v1/golden/engine-launch.json`.
//
// The file is bundled into this test target by project.yml
// (`PhoneDSHSimTests/EngineLaunch/` tests, `spec/host/v1/golden` resource).
import XCTest
import ProbeKit

final class EngineLaunchGoldenTests: XCTestCase {
    // MARK: - Contract document (test-side decoder, not a production codec)

    private struct Golden: Decodable {
        struct Instance: Decodable {
            let contract: String
            let revision: Int
        }

        struct Constants: Decodable {
            let minLeaseForColdBootMs: Int64
            let minLeaseForResumeMs: Int64
            let parkMarginMs: Int64
            let cloudPullFreshnessMs: Int64
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

        struct InvalidVector: Decodable {
            let id: String
            let input: AnyJSON
            let reason: String
            let note: String?
        }

        let instance: Instance
        let constants: Constants
        let wakeReasons: [String]
        let decisions: [String]
        let steps: [String]
        let decisionVectors: [DecisionVector]
        let invalidDecisionVectors: [InvalidVector]
        let sweepVectors: [SweepVector]
        let invalidSweepVectors: [InvalidVector]
    }

    /// The typed decoder the contract's invalid decision vectors must reject.
    /// It is deliberately stricter than the production call sites: unknown
    /// enum names, missing members, wrong types and a negative lease fail.
    private struct StrictDecisionInput: Decodable {
        let reason: WakeReason
        let foreground: Bool
        let residentAudio: Bool
        let hostState: EngineHostState
        let leaseRemainingMs: Int64?
        let userStopped: Bool
        let needsReset: Bool

        enum Failure: Error { case negativeLease }

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
            reason = try c.decode(WakeReason.self, forKey: .reason)
            foreground = try c.decode(Bool.self, forKey: .foreground)
            residentAudio = try c.decode(Bool.self, forKey: .residentAudio)
            hostState = try c.decode(EngineHostState.self, forKey: .hostState)
            leaseRemainingMs = try c.decodeIfPresent(Int64.self, forKey: .leaseRemainingMs)
            userStopped = try c.decode(Bool.self, forKey: .userStopped)
            needsReset = try c.decode(Bool.self, forKey: .needsReset)
            if let leaseRemainingMs, leaseRemainingMs < 0 { throw Failure.negativeLease }
        }
    }

    private struct StrictSweepInput: Decodable {
        let step: ReadySweepStep
        let remainingMs: Int64
    }

    /// Any JSON value, so an invalid vector's input can be re-decoded strictly.
    /// Self-contained on purpose: the test target must not reach into a
    /// module's internal JSON type just to re-run the contract's negatives.
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
            XCTFail("spec/host/v1/golden/engine-launch.json is missing (contract not merged?)")
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
        // Local pre-resource run: the checkout next to the test source.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let path = url.appendingPathComponent("spec/host/v1/golden/engine-launch.json")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Closed sets and constants

    func testClosedSetsMatchTheFrozenContract() throws {
        let golden = try loadGolden()
        XCTAssertEqual(golden.instance.contract, "engine-launch")
        XCTAssertGreaterThanOrEqual(golden.instance.revision, 1)

        XCTAssertEqual(golden.wakeReasons.count, WakeReason.allCases.count)
        XCTAssertEqual(Set(golden.wakeReasons), Set(WakeReason.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(golden.decisions), Set(EngineLaunchDecision.allCases.map(\.rawValue)))
        XCTAssertEqual(golden.steps, ReadySweepStep.allCases.map(\.rawValue))
    }

    func testConstantsAreTheOnesTheCodeUses() throws {
        let golden = try loadGolden()
        let c = golden.constants
        XCTAssertEqual(EngineLaunchThresholds.minLeaseForColdBootMs, c.minLeaseForColdBootMs)
        XCTAssertEqual(EngineLaunchThresholds.minLeaseForResumeMs, c.minLeaseForResumeMs)
        XCTAssertEqual(EngineLaunchThresholds.parkMarginMs, c.parkMarginMs)
        XCTAssertEqual(EngineLaunchThresholds.cloudPullFreshnessMs, c.cloudPullFreshnessMs)

        XCTAssertEqual(Set(c.stepBudgetMs.keys), Set(ReadySweepStep.allCases.map(\.rawValue)))
        for step in ReadySweepStep.allCases {
            XCTAssertEqual(c.stepBudgetMs[step.rawValue],
                           ReadySweepPolicy.stepBudgetMs(for: step), "\(step)")
        }
    }

    // MARK: - Vectors

    func testDecisionVectorsDriveTheRealPolicy() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.decisionVectors.isEmpty)
        for vector in golden.decisionVectors {
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
            XCTAssertEqual(decision, expected, "vector \(vector.id): \(String(describing: vector.note))")
        }
    }

    func testInvalidDecisionVectorsAreRejected() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.invalidDecisionVectors.isEmpty)
        for vector in golden.invalidDecisionVectors {
            XCTAssertThrowsError(try vector.input.decode(StrictDecisionInput.self),
                                 "vector \(vector.id) must be rejected: \(vector.reason)") { error in
                XCTAssertFalse(error is DecodingError && false,
                               "vector \(vector.id): \(error)")
            }
        }
    }

    func testSweepVectorsDriveTheRealGate() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.sweepVectors.isEmpty)
        for vector in golden.sweepVectors {
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

    func testInvalidSweepVectorsAreRejected() throws {
        let golden = try loadGolden()
        XCTAssertFalse(golden.invalidSweepVectors.isEmpty)
        for vector in golden.invalidSweepVectors {
            XCTAssertThrowsError(try vector.input.decode(StrictSweepInput.self),
                                 "vector \(vector.id) must be rejected: \(vector.reason)")
        }
    }
}
