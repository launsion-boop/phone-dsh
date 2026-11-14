// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

/// A ctrl link that answers from a script and records what was written.
@MainActor private final class ScriptedLink: TonoLinkCtrlLink {
    var answers: [String?]   // nil = ok, "range" = err range, "-" = no answer
    var written: [String] = []
    init(_ answers: [String?]) { self.answers = answers }
    func connect(timeout: Duration) async throws {}
    func disconnect() {}
    func command(_ line: Data, seq: UInt16, timeout: Duration) async throws -> TonoLinkCtrlAck {
        written.append(String(decoding: line, as: UTF8.self))
        let answer = answers.isEmpty ? nil : answers.removeFirst()
        if answer == "-" { throw TonoLinkUSBOTAError("timed out") }
        return TonoLinkCtrlAck(seq: seq, error: answer)
    }
}

@MainActor final class TonoLinkUnlockTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/device/v1/golden/tonolink-voice.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var fast: TonoLinkUnlock.Timing {
        var timing = TonoLinkUnlock.Timing(); timing.afterAttach = .zero; timing.afterWake = .zero; timing.betweenDigits = .zero; timing.afterAbsorb = .zero; return timing
    }

    func testSharedCommandVectors() throws {
        let vectors = try XCTUnwrap(try cases()["unlock_commands"] as? [[String: Any]])
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            let seq = UInt16(vector["seq"] as! Int), passcode = vector["passcode"] as! String
            if let expected = vector["lines"] as? [String] {
                let lines = try TonoLinkUnlock.commands(seq: seq, passcode: passcode)
                XCTAssertEqual(lines.map { String(decoding: $0.line, as: UTF8.self) }, expected)
                XCTAssertEqual(lines.map(\.seq), (0..<expected.count).map { seq + UInt16($0) })
            } else {
                XCTAssertThrowsError(try TonoLinkUnlock.commands(seq: seq, passcode: passcode), "seq \(seq) wraps")
            }
        }
    }

    func testRejectedPasscodesNeverReachTheBoardOrTheError() async throws {
        let rejected = try XCTUnwrap(try cases()["unlock_rejected"] as? [String])
        for passcode in rejected {
            XCTAssertFalse(TonoLinkUnlock.isValidPasscode(passcode), passcode)
            let link = ScriptedLink([])
            do {
                _ = try await TonoLinkUnlock.run(link: link, seq: 1, passcode: passcode, timing: fast)
                XCTFail("accepted \(passcode)")
            } catch {
                if !passcode.isEmpty { XCTAssertFalse("\(error)".contains(passcode), "the error echoes the passcode") }
            }
            XCTAssertTrue(link.written.isEmpty, "nothing is written for an invalid passcode")
        }
        XCTAssertThrowsError(try TonoLinkUnlock.commands(seq: 0, passcode: "0000"), "seq 0 is not a ctrl seq")
    }

    func testRunWritesEveryStepInOrder() async throws {
        let link = ScriptedLink(Array(repeating: nil, count: 9))
        let outcome = try await TonoLinkUnlock.run(link: link, seq: 40, passcode: "24680", timing: fast)
        XCTAssertEqual(outcome, .typed)
        XCTAssertEqual(link.written, ["40 hid_mode 1", "41 key backspace", "42 key backspace", "43 key 2", "44 key 4", "45 key 6", "46 key 8", "47 key 0", "48 key enter"])
    }

    func testRunStopsAtTheFirstRefusalWithoutRetrying() async throws {
        let refused = ScriptedLink([nil, "range"])
        let outcome = try await TonoLinkUnlock.run(link: refused, seq: 1, passcode: "0000", timing: fast)
        XCTAssertEqual(outcome, .refused(step: 2, answer: "err range"))
        XCTAssertEqual(refused.written, ["1 hid_mode 1", "2 key backspace"], "the digits are not typed after a refusal")

        let silent = ScriptedLink(["-"])
        let quiet = try await TonoLinkUnlock.run(link: silent, seq: 1, passcode: "0000", timing: fast)
        XCTAssertEqual(quiet, .refused(step: 1, answer: "no answer"))
        XCTAssertEqual(silent.written.count, 1)
    }

    func testDigitsAreNotTypedWhenTheWakeKeyAloneUnlocked() async throws {
        let link = ScriptedLink([nil, nil, nil])
        let outcome = try await TonoLinkUnlock.run(link: link, seq: 1, passcode: "0000", timing: fast, stillLocked: { false })
        XCTAssertEqual(outcome, .unlockedByWake)
        XCTAssertEqual(link.written, ["1 hid_mode 1", "2 key backspace"])
    }
}
