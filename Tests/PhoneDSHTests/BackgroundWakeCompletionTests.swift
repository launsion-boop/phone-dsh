// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSH

final class BackgroundWakeCompletionTests: XCTestCase {
    func testExpirationCancelsOwnedWorkAndCompletesOnce() {
        let gate = BackgroundWakeCompletion()
        let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        gate.attach(work)
        var completions = 0
        gate.finish(expired: true) { completions += 1 }
        gate.finish(expired: false) { completions += 1 }
        XCTAssertTrue(work.isCancelled)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(completions, 1)
    }

    func testExpirationBeforeAttachmentCancelsLateWork() {
        let gate = BackgroundWakeCompletion()
        gate.finish(expired: true) {}
        let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        gate.attach(work)
        XCTAssertTrue(work.isCancelled)
    }

    func testExpirationAfterSuccessfulCompletionDoesNotCancelWork() {
        let gate = BackgroundWakeCompletion()
        let work = Task<Void, Never> {}
        gate.attach(work)
        gate.finish(expired: false) {}
        gate.finish(expired: true) { XCTFail("Completed the same OS task twice") }
        XCTAssertFalse(work.isCancelled)
    }
}
