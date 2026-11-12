// SPDX-License-Identifier: MIT
// W7 (§13): the observability bridge stops probing once the page is ready and
// keeps every error-level console line while rate limiting the rest.

import XCTest
@testable import PhoneDSHEngine

final class WebEngineScriptsTests: XCTestCase {
    private var script: String {
        WebEngineScripts.observabilityBridge(handlerName: "phoneDSH")
    }

    func testProbeDisconnectsItsObserversAfterReady() {
        XCTAssertTrue(script.contains("var bootObservers = [];"))
        XCTAssertTrue(script.contains("function stopObserving()"))
        XCTAssertTrue(script.contains("bootObservers[i].disconnect()"),
                      "the document and title observers must be disconnected")
        XCTAssertTrue(script.contains("if (state === 'ready') { stopObserving(); }"),
                      "a ready probe must stop watching the whole document")
        XCTAssertTrue(script.contains("window.removeEventListener('load', inspectBoot)"))
    }

    func testConsoleRateLimitKeepsEveryErrorLevelLine() {
        XCTAssertTrue(script.contains("if (level === 'error') { return true; }"),
                      "error-level console output must never be rate limited")
        XCTAssertTrue(script.contains("consoleBudgetPerLevel = 50"))
        XCTAssertTrue(script.contains("post({ kind: 'console', level: level"))
    }
}
