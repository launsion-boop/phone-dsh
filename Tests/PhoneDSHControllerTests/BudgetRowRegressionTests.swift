// SPDX-License-Identifier: MIT
// The two byte-exact device values and the 8 GiB VFS row must not drift
// (budgets.md §4; verified on the phone 2026-10-29).

import XCTest
@testable import PhoneDSHController

final class BudgetRowRegressionTests: XCTestCase {
    private let mib = 1024 * 1024

    func testTheVerifiedSingleFileAndHotInstanceValues() {
        let eight = BudgetTable.eightGB
        // The phone refused file growth at 128 MiB (EFBIG at the 129th MiB).
        XCTAssertEqual(eight.singleFileBytes, 128 * mib)
        // The phone killed the python3 WASI instance at exactly 272629760 B.
        XCTAssertEqual(eight.wasiHotInstanceBytes, 272_629_760)
    }

    func testTheEightGiBVFSRow() {
        let eight = BudgetTable.eightGB
        XCTAssertEqual(eight.workspaceBytes, 288 * mib)
        XCTAssertEqual(eight.vfsLogicalBytes, 388 * mib)
        XCTAssertEqual(eight.sessionBytes, 50 * mib)
        XCTAssertEqual(eight.tmpBytes, 50 * mib)
    }

    func testTheTwelveGiBRowKeepsThe256MiBFileBudget() {
        let twelve = BudgetTable.twelveGB
        XCTAssertEqual(twelve.singleFileBytes, 256 * mib)
        XCTAssertEqual(twelve.workspaceBytes, 576 * mib)
        XCTAssertEqual(twelve.vfsLogicalBytes, 768 * mib)
        XCTAssertEqual(twelve.wasiHotInstanceBytes, 640 * mib)
    }
}
