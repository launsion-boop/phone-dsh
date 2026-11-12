// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import PhoneDSHStandardError

final class StandardErrorTests: XCTestCase {
    /// The 2026-11-12 Bot-stop crash: stderr was a pipe whose reader had gone
    /// away, so the diagnostic write raised an uncatchable ObjC exception and
    /// the process aborted. The shared writer must return after EPIPE.
    ///
    /// A closed process-wide stderr would also break XCTest's own logging, and
    /// a plain POSIX write would kill the test process with SIGPIPE. The probe
    /// therefore runs in a forked child whose exit status is the assertion:
    /// 0 = the diagnostic write degraded instead of trapping.
    func testClosedStderrReturnsWithoutTrapping() {
        // Build every allocation before fork; the child only performs the
        // signal mask/write syscalls and the pre-built helper call.
        let message: [UInt8] = Array("closed stderr diagnostic\n".utf8)
        let pid = forkViaDL()
        guard pid >= 0 else {
            return XCTFail("fork failed: \(errno)")
        }
        if pid == 0 {
            var descriptors: [Int32] = [0, 0]
            guard pipe(&descriptors) == 0 else { _exit(10) }
            close(descriptors[0]) // The reader is gone: writes fail with EPIPE.
            guard dup2(descriptors[1], STDERR_FILENO) == STDERR_FILENO else { _exit(11) }
            close(descriptors[1])
            // A plain write would be killed by SIGPIPE; the helper must block
            // the signal for the call and consume the pending one.
            _ = signal(SIGPIPE, SIG_DFL)
            _ = PhoneDSHStandardError.write(message)
            _exit(0)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        // Darwin wait(2) macros are not imported into Swift; decode by hand.
        let exited = (status & 0x7f) == 0
        let exitCode = exited ? (status >> 8) & 0xff : -1
        XCTAssertTrue(exited, "diagnostic write killed the child (status \(status))")
        XCTAssertEqual(exitCode, 0)
    }

    /// `fork` is marked unavailable by the Foundation overlay; the C symbol is
    /// still the only way to run the writer in a disposable process. The child
    /// performs no allocation and exits immediately.
    private func forkViaDL() -> pid_t {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "fork") else { return -1 }
        typealias Fork = @convention(c) () -> pid_t
        return unsafeBitCast(symbol, to: Fork.self)()
    }

    func testEmptyWriteIsANoOp() {
        XCTAssertTrue(PhoneDSHStandardError.write(Data()))
        XCTAssertTrue(PhoneDSHStandardError.write([UInt8]()))
    }
}
