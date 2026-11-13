// SPDX-License-Identifier: MIT

import CoreGraphics
import XCTest
@testable import PhoneDSHBot

/// Regression tests for the layout math behind `BotAdaptiveBubbleLayout` and
/// the card-heading probes. The 2026-11-12 field samples showed the chat page
/// stuck in `LazySubviewPlacements.updateValue/placeSubviews` while the
/// keyboard was open: a custom Layout whose result changed with the available
/// height, plus a probe callback that wrote SwiftUI state during layout, can
/// keep the lazy transcript re-measuring forever.
final class BotCardLayoutSupportTests: XCTestCase {
    private let ratio: CGFloat = 0.86

    // MARK: - Bubble geometry

    func testContentProposalIgnoresTheAvailableHeight() {
        // The keyboard changes the available height, not the column width.
        // The child must be measured at its natural height in every case;
        // forwarding a finite height makes the measured height oscillate.
        for height in [CGFloat?.none, 0, 160, 320, 844] {
            let proposal = BotAdaptiveBubbleGeometry.contentProposal(
                availableWidth: 390, availableHeight: height, ratio: ratio)
            XCTAssertEqual(proposal?.width, 390 * ratio)
            XCTAssertNil(proposal?.height,
                         "a parent height of \(String(describing: height)) leaked into the child proposal")
        }
    }

    func testContentProposalIsStableForTheSameWidth() {
        let first = BotAdaptiveBubbleGeometry.contentProposal(
            availableWidth: 390, availableHeight: 844, ratio: ratio)
        let second = BotAdaptiveBubbleGeometry.contentProposal(
            availableWidth: 390, availableHeight: 120, ratio: ratio)
        XCTAssertEqual(first?.width, second?.width)
        XCTAssertEqual(first?.height, second?.height)
    }

    func testContentProposalHasNoWidthWhenTheParentHasNoWidth() {
        XCTAssertNil(BotAdaptiveBubbleGeometry.contentProposal(
            availableWidth: nil, availableHeight: 844, ratio: ratio))
        XCTAssertNil(BotAdaptiveBubbleGeometry.contentProposal(
            availableWidth: 0, availableHeight: 844, ratio: ratio))
    }

    func testBubbleSizeUsesTheContentHeightOnly() {
        let first = BotAdaptiveBubbleGeometry.bubbleSize(availableWidth: 390, contentHeight: 123.5)
        let second = BotAdaptiveBubbleGeometry.bubbleSize(availableWidth: 390, contentHeight: 123.5)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.width, 390)
        XCTAssertEqual(first.height, 123.5)
    }

    func testPlacementUsesTheBoundsWidthInsteadOfAStaleCache() {
        let bounds = CGRect(x: 20, y: 100, width: 344, height: 200)
        // The cache was measured for a different proposal (e.g. before the
        // keyboard/safe-area pass settled).
        let height = BotAdaptiveBubbleGeometry.contentHeight(
            boundsWidth: bounds.width, cachedWidth: 100, cachedHeight: 40) { measuredWidth in
                XCTAssertEqual(measuredWidth, bounds.width)
                return 88
            }
        XCTAssertEqual(height, 88)

        let x = BotAdaptiveBubbleGeometry.contentOriginX(
            bounds: bounds, contentWidth: bounds.width * ratio, trailing: false)
        XCTAssertEqual(x, bounds.minX)

        let trailingX = BotAdaptiveBubbleGeometry.contentOriginX(
            bounds: bounds, contentWidth: bounds.width * ratio, trailing: true)
        XCTAssertEqual(trailingX, bounds.maxX - bounds.width * ratio)
    }

    func testPlacementReusesTheCacheForTheSameWidth() {
        var measures = 0
        let height = BotAdaptiveBubbleGeometry.contentHeight(
            boundsWidth: 344, cachedWidth: 344, cachedHeight: 88) { _ in
                measures += 1
                return 1
            }
        XCTAssertEqual(height, 88)
        XCTAssertEqual(measures, 0)
    }

    func testShortTrailingBubbleUsesItsMeasuredWidthNotTheWidthCap() {
        // 2026-11-13 field sample: after tapping 建议下一步 the sent message
        // bubble sat at the 20% mark with empty space to its right. The
        // trailing origin must use the content-sized width; the 0.80 ratio is
        // only the maximum, so a 150pt bubble in a 390pt column starts at
        // 240pt, not at 390 - 390 * 0.80 = 78pt.
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 44)
        let measured: CGFloat = 150
        let origin = BotAdaptiveBubbleGeometry.contentOriginX(
            bounds: bounds, contentWidth: measured, trailing: true)
        XCTAssertEqual(origin, 240)
        XCTAssertNotEqual(origin, bounds.maxX - bounds.width * 0.80,
                          "the trailing edge must not be computed from the width cap")
        XCTAssertEqual(origin + measured, bounds.maxX)
    }

    func testTrailingBubbleAtTheWidthCapStillHugsTheTrailingEdge() {
        let bounds = CGRect(x: 12, y: 0, width: 390, height: 44)
        let measured = bounds.width * 0.80
        let origin = BotAdaptiveBubbleGeometry.contentOriginX(
            bounds: bounds, contentWidth: measured, trailing: true)
        XCTAssertEqual(origin, bounds.maxX - measured)
    }

    // MARK: - Heading probe coordination

    func testRepeatedProbeReportDoesNotRescheduleWhilePending() {
        var measurement = BotCardTextMeasurement()
        let heights = BotCardTextHeights(full: 84, limited: 40)

        XCTAssertTrue(measurement.report(heights))
        // The layout pass can report the same value again before the deferred
        // task runs. Scheduling another apply would dirty the graph again.
        XCTAssertFalse(measurement.report(heights),
                       "the same probed height scheduled a second layout-invalidating apply")
        XCTAssertTrue(measurement.needsCommit)
    }

    func testCommitAppliesTheLatestReportOnlyOnce() {
        var measurement = BotCardTextMeasurement()
        let heights = BotCardTextHeights(full: 84, limited: 40)
        XCTAssertTrue(measurement.report(heights))
        XCTAssertEqual(measurement.commit(), heights)
        XCTAssertNil(measurement.commit())
        XCTAssertFalse(measurement.needsCommit)
    }

    func testChangedReportBeforeCommitKeepsOnlyTheLatestValue() {
        var measurement = BotCardTextMeasurement()
        XCTAssertTrue(measurement.report(BotCardTextHeights(full: 60, limited: 40)))
        XCTAssertTrue(measurement.report(BotCardTextHeights(full: 84, limited: 40)))
        XCTAssertEqual(measurement.commit(), BotCardTextHeights(full: 84, limited: 40))
    }

    func testSubHalfPointProbeJitterDoesNotReschedule() {
        var measurement = BotCardTextMeasurement()
        XCTAssertTrue(measurement.report(BotCardTextHeights(full: 84, limited: 40)))
        XCTAssertFalse(measurement.report(BotCardTextHeights(full: 84.2, limited: 40.2)),
                       "text-layout rounding started another measurement pass")
        XCTAssertEqual(measurement.commit(), BotCardTextHeights(full: 84, limited: 40))
        XCTAssertTrue(measurement.report(BotCardTextHeights(full: 84.8, limited: 40)))
    }

    func testStableReportAfterCommitDoesNotReschedule() {
        var measurement = BotCardTextMeasurement()
        let heights = BotCardTextHeights(full: 84, limited: 40)
        XCTAssertTrue(measurement.report(heights))
        _ = measurement.commit()
        XCTAssertFalse(measurement.report(heights))
        XCTAssertFalse(measurement.needsCommit)
    }

    func testExpansionControlOnlyAppearsForRealTruncation() {
        XCTAssertTrue(BotCardTextHeights(full: 84, limited: 40).needsExpansionControl)
        XCTAssertFalse(BotCardTextHeights(full: 40, limited: 40).needsExpansionControl)
        // Half-point text rounding must not flash the control.
        XCTAssertFalse(BotCardTextHeights(full: 40.4, limited: 40).needsExpansionControl)
    }
}
