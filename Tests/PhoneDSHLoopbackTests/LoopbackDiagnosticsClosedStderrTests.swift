// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import PhoneDSHStandardError
@testable import PhoneDSHLoopback

final class LoopbackDiagnosticsClosedStderrTests: XCTestCase {
    /// The exact 2026-11-12 SIGABRT path: an egress diagnostic written while
    /// stderr is a pipe with no reader. It must lose the line, not the App.
    ///
    /// A closed process-wide stderr would also break XCTest's own logging, so
    /// the write runs in a forked child. Every lazily initialised Objective-C
    /// class it touches is warmed in the parent first; `fork` in a
    /// multi-threaded XCTest process cannot initialize classes safely.
    func testEgressDiagnosticSurvivesClosedStderr() {
        let warmup = HTTPEgressFailure(
            status: 502, code: "transport_failed",
            message: "warmup", host: "api.example.test")
        _ = warmup.diagnosticLine(target: "https://api.example.test/v1")
        _ = PhoneDSHStandardError.write(Data())
        // Warm the FileHandle singleton too: with the old implementation the
        // fork child then reaches the real EPIPE exception instead of the
        // Objective-C "class initialized after fork" abort.
        _ = FileHandle.standardError.fileDescriptor

        let pid = forkViaDL()
        guard pid >= 0 else { return XCTFail("fork failed: \(errno)") }
        if pid == 0 {
            var descriptors: [Int32] = [0, 0]
            guard pipe(&descriptors) == 0 else { _exit(10) }
            close(descriptors[0]) // The reader is gone: writes fail with EPIPE.
            guard dup2(descriptors[1], STDERR_FILENO) == STDERR_FILENO else { _exit(11) }
            close(descriptors[1])
            // The real App has SIGPIPE ignored (Foundation installs that
            // disposition); the field failure was the uncatchable ObjC EPIPE
            // exception raised by FileHandle.write, so the probe reproduces
            // that state instead of a SIGPIPE kill.
            _ = signal(SIGPIPE, SIG_IGN)
            let failure = HTTPEgressFailure(
                status: 502, code: "transport_failed",
                message: "unreachable upstream", host: "api.example.test")
            LoopbackEgressDiagnostics.record(failure, target: "https://api.example.test/v1")
            _exit(0)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        let exited = (status & 0x7f) == 0
        let exitCode = exited ? (status >> 8) & 0xff : -1
        XCTAssertTrue(exited, "the egress diagnostic killed the process (status \(status))")
        XCTAssertEqual(exitCode, 0)
    }

    /// `fork` is marked unavailable by the Foundation overlay; the C symbol is
    /// still the only way to run the diagnostic in a disposable process.
    private func forkViaDL() -> pid_t {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "fork") else { return -1 }
        typealias Fork = @convention(c) () -> pid_t
        return unsafeBitCast(symbol, to: Fork.self)()
    }
}
