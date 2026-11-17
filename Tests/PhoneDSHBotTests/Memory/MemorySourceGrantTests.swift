// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// G-1 r19: a real grant decision must survive the P baseline/builder and the
/// P→L derivation mapping. P never invents a grant; this test supplies one.
final class MemorySourceGrantTests: XCTestCase {
    func testGrantSurvivesStateBuilderAndDerivationMapping() throws {
        let ref = "record://session/gb-main#1"
        let state = BotSourceState(
            ref: ref, resolved: true, erased: false,
            observedAtMS: 1_760_000_000_000, recordType: "user/message",
            trust: .user, version: nil, grantId: "grant-7")
        let baselines = try BotSourceBaselineBuilder.baselines(
            evidence: [ref], reviewRefs: [], states: [state])
        let baseline = try XCTUnwrap(baselines.first)
        XCTAssertEqual(baseline.grantId, "grant-7")
        XCTAssertEqual(baseline.provenanceSource().grantId, "grant-7")
    }

    func testNoGrantStaysNil() throws {
        let ref = "record://session/gb-main#1"
        let state = BotSourceState(
            ref: ref, resolved: true, erased: false,
            observedAtMS: nil, recordType: nil, trust: nil, version: nil)
        let baseline = try XCTUnwrap(try BotSourceBaselineBuilder.baselines(
            evidence: [ref], reviewRefs: [], states: [state]).first)
        XCTAssertNil(baseline.grantId)
        XCTAssertNil(baseline.provenanceSource().grantId)
    }
}
