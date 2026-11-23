// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: unlock a locked iPhone by typing its owner's numeric passcode through
// the TonoLink board's keyboard over BLE (tonolink-board.md §4.4). BLE, not USB HTTP: iOS may cut
// the USB accessory while the phone is locked, the BLE link stays. The passcode is never logged,
// stored or put in an error by this file.
import Foundation

public enum TonoLinkUnlock {
    /// A numeric iOS passcode: 4–10 ASCII digits.
    public static func isValidPasscode(_ passcode: String) -> Bool {
        (4...10).contains(passcode.utf8.count) && passcode.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// The `cmd` lines for one attempt, starting at `seq` with consecutive values (§4.4).
    /// Throws (without echoing the passcode) for an invalid passcode or a start that would wrap.
    public static func commands(seq: UInt16, passcode: String) throws -> [(seq: UInt16, line: Data)] {
        guard isValidPasscode(passcode) else { throw TonoLinkUSBOTAError("passcode must be 4–10 digits") }
        let needsEnter = ![4, 6].contains(passcode.utf8.count)
        // The keypad drops the first key after the wake (measured on the phone: 3 of 4 digits arrived,
        // whether typed in one `type` line or one `key` line per digit). A second backspace takes that
        // place: dropped, or a no-op on the empty passcode field. Then one key per digit.
        let texts = ["hid_mode 1", "key backspace", "key backspace"] + passcode.map { "key \($0)" } + (needsEnter ? ["key enter"] : [])
        guard Int(seq) >= 1, Int(seq) + texts.count - 1 <= Int(UInt16.max) else {
            throw TonoLinkUSBOTAError("unlock seq would wrap past 65535; start again at 1")
        }
        return try texts.enumerated().map { offset, text in
            let s = seq + UInt16(offset)
            return (s, try TonoLinkBLECommand.line("\(s) \(text)"))
        }
    }

    /// What the board said, without the passcode.
    public enum Outcome: Equatable, Sendable {
        /// Every line was acked `ok`. iOS still decides whether the passcode was right.
        case typed
        /// The wake key alone unlocked it (no passcode was required yet): nothing was typed.
        case unlockedByWake
        /// Stopped at a step (1-based) with the board's answer; nothing was retried.
        case refused(step: Int, answer: String)
    }

    /// Settling time after each step, measured on the phone (hid_mode → keyboard subscribed,
    /// backspace → 输入密码 shown).
    public struct Timing: Sendable {
        public var afterAttach: Duration = .seconds(2)
        public var afterWake: Duration = .seconds(2)
        public var afterAbsorb: Duration = .milliseconds(600)
        public var betweenDigits: Duration = .milliseconds(300)
        public var ack: Duration = .seconds(4)
        public init() {}
    }

    /// Writes the lines in order, stopping at the first answer other than `ok`. `stillLocked` is
    /// asked after the wake key (the caller looks at the mirrored screen for the passcode page):
    /// when it says no, the digits are not typed (they would land in whatever is now in front).
    @MainActor
    public static func run(link: TonoLinkCtrlLink, seq: UInt16, passcode: String, timing: Timing = Timing(),
                           stillLocked: @MainActor () async -> Bool = { true }) async throws -> Outcome {
        let lines = try commands(seq: seq, passcode: passcode)
        try await link.connect(timeout: .seconds(10))
        for (index, item) in lines.enumerated() {
            let answer: String
            do {
                let ack = try await link.command(item.line, seq: item.seq, timeout: timing.ack)
                answer = ack.ok ? "ok" : "err \(ack.error ?? "?")"
            } catch {
                return .refused(step: index + 1, answer: "no answer")
            }
            guard answer == "ok" else { return .refused(step: index + 1, answer: answer) }
            if index == 0 { try await Task.sleep(for: timing.afterAttach) }
            if index == 1 {
                try await Task.sleep(for: timing.afterWake)
                if !(await stillLocked()) { return .unlockedByWake }
            } else if index == 2 {
                try await Task.sleep(for: timing.afterAbsorb)
            } else if index >= 3 {
                try await Task.sleep(for: timing.betweenDigits)
            }
        }
        return .typed
    }
}
