// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

/// The persisted TonoLink layout (`phone-dsh.tonolink.phone-layout.v1`) and when its learned
/// mirror route must be learned again.
final class TonoLinkPhoneLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testLayoutSavedByAnOlderBuildIsNotLearned() throws {
        let legacy = Data(#"""
        {"assistiveButton":{"x":913,"y":566},"assistiveHome":{"x":662,"y":680},
         "assistiveControlCenter":{"x":826,"y":820},"mirrorButton":{"x":401,"y":564},"mirrorTarget":{"x":567,"y":579}}
        """#.utf8)
        let layout = try JSONDecoder().decode(TonoLinkPhoneLayout.self, from: legacy)
        XCTAssertNil(layout.mirrorRouteLearned)
        XCTAssertFalse(layout.mirrorRouteUsable, "another phone's defaults are never tapped blind")
        XCTAssertTrue(layout.mirrorRouteNeedsLearning(now: now))
    }

    func testLearnedRouteIsReusedForAWeekThenRelearned() {
        var layout = TonoLinkPhoneLayout()
        layout.markMirrorRouteLearned(at: now)
        XCTAssertTrue(layout.mirrorRouteUsable)
        XCTAssertFalse(layout.mirrorRouteNeedsLearning(now: now.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertTrue(layout.mirrorRouteNeedsLearning(now: now.addingTimeInterval(8 * 24 * 3600)))
        XCTAssertTrue(layout.mirrorRouteUsable, "age alone does not stop a blind restart")
        XCTAssertTrue(layout.mirrorRouteNeedsLearning(now: now.addingTimeInterval(-3600)),
                      "a learning date in the future (clock change) counts as stale")
    }

    func testRouteLearnedWithoutADateIsRelearned() {
        var layout = TonoLinkPhoneLayout()
        layout.mirrorRouteLearned = true
        XCTAssertTrue(layout.mirrorRouteUsable)
        XCTAssertTrue(layout.mirrorRouteNeedsLearning(now: now))
    }

    func testInvalidatedRouteIsNeitherReplayedNorTrusted() throws {
        var layout = TonoLinkPhoneLayout()
        layout.markMirrorRouteLearned(at: now)
        layout.invalidateMirrorRoute()
        XCTAssertFalse(layout.mirrorRouteUsable)
        XCTAssertTrue(layout.mirrorRouteNeedsLearning(now: now))
        let decoded = try JSONDecoder().decode(TonoLinkPhoneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
        XCTAssertFalse(decoded.mirrorRouteUsable)
    }
}
