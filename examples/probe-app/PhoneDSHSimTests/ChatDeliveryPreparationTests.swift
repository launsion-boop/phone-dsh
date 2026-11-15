// SPDX-License-Identifier: MIT
import XCTest
import ProbeKit

final class ChatDeliveryPreparationTests: XCTestCase {
    private func decision(foreground: Bool = true, keepingAlive: Bool = false,
                          host: Bool = true, parked: Bool = false, transition: Bool = false,
                          busy: Bool = false, ready: Bool = true, recovery: Bool = false) -> ChatDeliveryPreparation {
        ChatDeliveryPreparation.decide(foreground: foreground, keepingAlive: keepingAlive,
            hostPresent: host, parked: parked, transitioning: transition, busy: busy,
            transportReady: ready, requiresRecovery: recovery)
    }

    func testExistingHostIsNotProofOfReadiness() {
        XCTAssertEqual(decision(parked: true), .resume)
        XCTAssertEqual(decision(ready: false), .wait)
        XCTAssertEqual(decision(transition: true), .wait)
        XCTAssertEqual(decision(busy: true), .wait)
        XCTAssertEqual(decision(), .ready)
        XCTAssertEqual(decision(host: false, ready: false), .start)
    }

    func testBackgroundNeverStartsOrResumesEvenWithKeepAlive() {
        for kept in [false, true] {
            XCTAssertEqual(decision(foreground: false, keepingAlive: kept, host: false), .deferred)
            XCTAssertEqual(decision(foreground: false, keepingAlive: kept, parked: true), .deferred)
        }
        XCTAssertEqual(decision(foreground: false), .deferred)
        XCTAssertEqual(decision(foreground: false, keepingAlive: true), .ready)
    }

    func testRecoveryAndTransitionsRemainAuthoritative() {
        XCTAssertEqual(ChatDeliveryPreparation.decide(foreground: true, keepingAlive: false,
            hostPresent: false, parked: false, transitioning: false, busy: false,
            transportReady: false, requiresRecovery: false, userPaused: true), .needsAttention)
        XCTAssertEqual(decision(host: false, recovery: true), .needsAttention)
        XCTAssertEqual(decision(parked: true, recovery: true), .needsAttention)
        XCTAssertEqual(decision(host: false, transition: true), .wait)
        XCTAssertEqual(decision(parked: true, busy: true), .wait)
    }

    func testEligibilityLostBeforeTransportCanDeferWithoutChangingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = SendOutbox(directory: root)
        let entry = try await queue.enqueue(sessionID: "original-session", text: "defer")
        _ = try await queue.markSubmitting(rpcId: entry.rpcId)
        XCTAssertEqual(decision(foreground: false, parked: true), .deferred)
        // This sender has not invoked transport. Recovered entries do not have this proof.
        _ = try await queue.markOutcomeUnknown(rpcId: entry.rpcId, lastError: "not submitted")
        _ = try await queue.requeue(rpcId: entry.rpcId)
        let saved = await SendOutbox(directory: root).entry(rpcId: entry.rpcId)
        XCTAssertEqual(saved?.state, .queued)
        XCTAssertEqual(saved?.sessionId, entry.sessionId)
        XCTAssertEqual(saved?.rpcId, entry.rpcId)
    }

    func testDeferredDeliverySurvivesReopenWithOriginalDestinationAndKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = SendOutbox(directory: root)
        let entry = try await queue.enqueue(sessionID: "original-session", text: "处理设备消息")
        XCTAssertEqual(decision(foreground: false, parked: true), .deferred)
        let reopened = SendOutbox(directory: root)
        let saved = await reopened.entry(rpcId: entry.rpcId)
        XCTAssertEqual(saved?.sessionId, "original-session")
        XCTAssertEqual(saved?.rpcId, entry.rpcId)
        XCTAssertEqual(saved?.state, .queued)
        // Preparation is not a delivery receipt and cannot mutate the queue.
        XCTAssertEqual(decision(parked: true), .resume)
        let afterPreparation = await reopened.entry(rpcId: entry.rpcId)
        XCTAssertEqual(afterPreparation, saved)
    }
}
