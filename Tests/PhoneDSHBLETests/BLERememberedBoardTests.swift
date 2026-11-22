// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

/// Device log 2026-11-22: with a TonoLink board and an AI Passport both remembered, the voice
/// link took "the first remembered board" and on half the launches parked on the Passport.
final class BLERememberedBoardTests: XCTestCase {
    private func memory() -> (BLEDeviceTrustMemory, UserDefaults) {
        let suite = "BLERememberedBoardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (BLEDeviceTrustMemory(defaults: defaults), defaults)
    }

    func testPicksTheBoardByNameAmongOtherRememberedDevices() {
        let (memory, _) = memory()
        let board = UUID(uuidString: "85E7479A-E98C-8583-EC93-D3C81082CCD0")!
        let passport = UUID(uuidString: "D5997DCF-53CF-90A3-FCAA-7B4B06C70557")!
        memory.rememberBoard(passport, name: "AI Passport")
        memory.rememberBoard(board, name: "PhoneAgent-7356")
        for _ in 0..<50 { XCTAssertEqual(memory.rememberedBoard(namePrefix: "PhoneAgent"), board) }
    }

    func testNoMatchIsNilSoTheCallerScansByName() {
        let (memory, _) = memory()
        memory.rememberBoard(UUID(), name: "AI Passport")
        XCTAssertNil(memory.rememberedBoard(namePrefix: "PhoneAgent"))
        XCTAssertNil(memory.rememberedBoard(namePrefix: ""), "an empty prefix matches nothing")
    }

    func testSeveralMatchesResolveToTheLowestIdentifier() {
        let (memory, _) = memory()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
        memory.rememberBoard(high, name: "PhoneAgent-0002")
        memory.rememberBoard(low, name: "PhoneAgent-0001")
        XCTAssertEqual(memory.rememberedBoard(namePrefix: "PhoneAgent"), low)
        memory.forgetBoard(low)
        XCTAssertEqual(memory.rememberedBoard(namePrefix: "PhoneAgent"), high)
    }
}
