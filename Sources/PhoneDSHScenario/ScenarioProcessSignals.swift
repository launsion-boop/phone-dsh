// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: process-signal guard.
//
// G2-FIX-Q3. The full `swift test` suite occasionally ended with the XCTest
// process gone before its summary: no assertion, no `fatalError` text and no
// SwiftPM "unexpected signal" diagnostic, just a log that stopped mid-suite and
// a gate exit status of 1. Two controlled experiments reproduce that exact log
// shape with this toolchain: sending the runner SIGKILL or SIGBUS both leave
// the same truncated log, run the zero-test Swift Testing phase and return
// 1 — with no crash report written for the xctest agent in either case. The
// absence of a crash report therefore does not rule out a fatal fault, and
// SIGKILL cannot be caught at all.
//
// Two guards are installed here:
//
//  * SIGTERM, SIGINT and SIGHUP are catchable external stop requests. They are
//    recorded (async-signal-safe: one `sig_atomic_t` word) and the process
//    keeps running, so a scenario that is executing reports the request as an
//    ordinary failure through ``throwIfTerminationRequested()`` instead of
//    letting the log end silently.
//  * SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGTRAP and SIGABRT are fatal faults
//    that cannot be converted into an assertion. Their handler writes one
//    unbuffered signature line to stderr and exits with ``fatalExitCode`` so
//    the gate log names the signal instead of stopping mid-suite. Set
//    `PDSH_SCENARIO_SIGNAL_BACKTRACE=1` in the test environment to also dump the
//    faulting stack through `backtrace_symbols_fd`.
//
// The handlers only use async-signal-safe operations: no allocation, no
// locks, no Swift runtime formatting. Everything else runs on the normal
// thread.

import Darwin
import Foundation

/// Fixed-width slot the catchable-signal handler writes. `sig_atomic_t` reads
/// and writes are atomic with respect to signal handlers on Darwin.
private var xlScenarioReceivedSignal: Int32 = 0
private var xlScenarioSignalGuardInstalled = false
private var xlScenarioSignalBacktraceEnabled = false
/// Preallocated so the fatal-signal handler never allocates.
private let xlScenarioBacktraceCapacity = 128
private let xlScenarioBacktraceFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>
    .allocate(capacity: 128)

/// Records (and neutralises) the signals a test process can receive from
/// outside while a scenario batch is running.
public enum ScenarioProcessSignals {
    /// Exit status used after the fatal-signal signature was written. 70 is
    /// not a signal status, so the harness sees a normal non-zero exit with
    /// the signature line in the log.
    public static let fatalExitCode: Int32 = 70

    /// The signals whose default action kills the process and whose cause is
    /// reported on stderr before the process exits.
    public static let fatalSignalNumbers: [Int32] = [
        SIGBUS, SIGSEGV, SIGILL, SIGFPE, SIGTRAP, SIGABRT,
    ]

    /// The external stop requests that are recorded and turned into a
    /// scenario failure instead of terminating the process.
    public static let terminationSignalNumbers: [Int32] = [
        SIGTERM, SIGINT, SIGHUP,
    ]

    /// Installs the guard once. Later calls are no-ops.
    ///
    /// SIGKILL cannot be handled by any process; the scenario runner's gates
    /// keep their retry for the silent-exit class, and this guard narrows the
    /// class by naming every handleable signal.
    public static func install() {
        guard !xlScenarioSignalGuardInstalled else { return }
        xlScenarioSignalGuardInstalled = true
        xlScenarioSignalBacktraceEnabled =
            ProcessInfo.processInfo.environment["PDSH_SCENARIO_SIGNAL_BACKTRACE"] == "1"
        // Force the preallocated backtrace buffer to be initialized now: the
        // fatal handler must never trigger a lazy global initializer.
        _ = xlScenarioBacktraceFrames
        for number in terminationSignalNumbers {
            _ = signal(number, xlScenarioSignalHandler)
        }
        for number in fatalSignalNumbers {
            _ = signal(number, xlScenarioFatalSignalHandler)
        }
    }

    /// Whether ``install()`` has run in this process.
    public static var isInstalled: Bool { xlScenarioSignalGuardInstalled }

    /// The last termination signal received, or `nil` when none arrived.
    public static var lastSignal: Int32? {
        let value = xlScenarioReceivedSignal
        return value == 0 ? nil : value
    }

    /// The last termination signal, consuming it.
    public static func takeSignal() -> Int32? {
        let value = xlScenarioReceivedSignal
        xlScenarioReceivedSignal = 0
        return value == 0 ? nil : value
    }

    /// Throws when an external termination request arrived.
    ///
    /// Called by the long-running waits so a run stops with a reportable
    /// reason instead of continuing as if nothing happened.
    public static func throwIfTerminationRequested() throws {
        guard let signal = lastSignal else { return }
        throw ScenarioError.infra(
            "the test process received \(name(of: signal)) from outside the scenario; "
            + "the harness stopped the run instead of letting the process terminate silently "
            + "(a batch or tooling cleanup sent the signal; the gate must carry this as a "
            + "test failure, not a missing XCTest summary)")
    }

    /// Human name of a signal number, for diagnostics.
    public static func name(of signal: Int32) -> String {
        if let name = staticSignalName(signal) {
            return String(decoding: UnsafeBufferPointer(start: name.utf8Start,
                                                        count: name.utf8CodeUnitCount),
                          as: UTF8.self)
        }
        return "signal \(signal)"
    }

    /// Test seam: clears the recorded signal and keeps the handler installed.
    public static func resetForTesting() {
        xlScenarioReceivedSignal = 0
    }
}

// MARK: - Signal names without allocation

private func staticSignalName(_ signal: Int32) -> StaticString? {
    switch signal {
    case SIGTERM: return "SIGTERM"
    case SIGINT: return "SIGINT"
    case SIGHUP: return "SIGHUP"
    case SIGPIPE: return "SIGPIPE"
    case SIGKILL: return "SIGKILL"
    case SIGBUS: return "SIGBUS"
    case SIGSEGV: return "SIGSEGV"
    case SIGILL: return "SIGILL"
    case SIGFPE: return "SIGFPE"
    case SIGTRAP: return "SIGTRAP"
    case SIGABRT: return "SIGABRT"
    default: return nil
    }
}

/// Writes `text` to stderr with the raw `write(2)` call. Async-signal-safe.
private func xlWriteToStandardError(_ text: StaticString) {
    text.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress else { return }
        var written = 0
        while written < buffer.count {
            let result = write(STDERR_FILENO, base + written, buffer.count - written)
            if result <= 0 { return }
            written += result
        }
    }
}

/// The catchable-termination handler: async-signal-safe, no allocation, no
/// locking.
private func xlScenarioSignalHandler(_ signalNumber: Int32) {
    xlScenarioReceivedSignal = signalNumber
}

/// The fatal-fault handler: writes one unbuffered signature line, optionally
/// dumps the faulting stack and exits with a normal non-zero status so the
/// gate log carries the signal name instead of a truncated log.
private func xlScenarioFatalSignalHandler(_ signalNumber: Int32) {
    if let name = staticSignalName(signalNumber) {
        xlWriteToStandardError("XL-Q3-FATAL-SIGNAL: ")
        xlWriteToStandardError(name)
        xlWriteToStandardError("\n")
    } else {
        xlWriteToStandardError("XL-Q3-FATAL-SIGNAL: unknown fatal signal\n")
    }
    if xlScenarioSignalBacktraceEnabled {
        let count = backtrace(xlScenarioBacktraceFrames, Int32(xlScenarioBacktraceCapacity))
        if count > 0 {
            backtrace_symbols_fd(xlScenarioBacktraceFrames, count, STDERR_FILENO)
        }
    }
    _exit(ScenarioProcessSignals.fatalExitCode)
}
