// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHStandardError: a crash-free standard-error write.
//
// Diagnostic writers run on paths that must never take the process down:
// loopback egress failures, gateway timings, WAL forensic lines and the
// controller's logger. `FileHandle.standardError.write` raises an Objective-C
// exception when the descriptor is a pipe whose reader has gone away (`EPIPE`);
// Swift cannot catch that exception, so the process aborts (the 2026-11-12
// Bot-stop crash: SIGABRT inside `FileHandle.standardError.write`). A closed
// stderr must only lose the line.
//
// The helper below writes with POSIX `write`, ignores the result, and blocks
// SIGPIPE for the duration of the call. Blocking the signal for this thread is
// what makes a broken pipe return `EPIPE` instead of terminating the process;
// a pending SIGPIPE produced by this write is consumed before the mask is
// restored. No global signal handler is installed.

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum PhoneDSHStandardError {
    /// Writes UTF-8 bytes to file descriptor 2 and returns whether the whole
    /// buffer was accepted. Never throws and never traps; a closed pipe,
    /// `EINTR` from a signal storm or a non-blocking descriptor degrades to a
    /// short/empty write.
    @discardableResult
    public static func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return true }
            return writeAll(base.assumingMemoryBound(to: UInt8.self), count: raw.count)
        }
    }

    /// Writes one UTF-8 string (a trailing newline is added by default).
    @discardableResult
    public static func write(_ line: String, newline: Bool = true) -> Bool {
        let text = newline ? line + "\n" : line
        return write(Data(text.utf8))
    }

    /// Byte-level entry point used by tests and by writers that already hold
    /// UTF-8 bytes.
    @discardableResult
    public static func write(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return true }
            return writeAll(base, count: buffer.count)
        }
    }

    private static func writeAll(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
        var pipeSet = sigset_t()
        sigemptyset(&pipeSet)
        sigaddset(&pipeSet, SIGPIPE)
        var previous = sigset_t()
        // Blocking SIGPIPE on this thread scopes the protection to the write;
        // it does not change the process-wide disposition other code relies on.
        let blocked = pthread_sigmask(SIG_BLOCK, &pipeSet, &previous) == 0
        defer {
            if blocked {
                // `write` returned EPIPE: the kernel also queued SIGPIPE for
                // this thread. Consume that pending signal before restoring the
                // mask, otherwise the defer itself would deliver it.
                var pending = sigset_t()
                if sigpending(&pending) == 0, sigismember(&pending, SIGPIPE) == 1 {
                    var received: Int32 = 0
                    // The signal is pending and blocked on this thread, so
                    // `sigwait` consumes it without blocking.
                    _ = sigwait(&pipeSet, &received)
                }
                pthread_sigmask(SIG_SETMASK, &previous, nil)
            }
        }
        var offset = 0
        while offset < count {
            let written = base.advanced(by: offset).withMemoryRebound(to: CChar.self, capacity: count - offset) {
                POSIX_write(STDERR_FILENO, $0, count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            // EPIPE / EAGAIN / EBADF / anything else: the diagnostic is lost,
            // the process is not. Deliberately do not retry a broken pipe.
            return false
        }
        return true
    }
}

#if canImport(Darwin)
@inline(__always)
private func POSIX_write(_ fd: Int32, _ buffer: UnsafePointer<CChar>, _ count: Int) -> Int {
    Darwin.write(fd, buffer, count)
}
#else
@inline(__always)
private func POSIX_write(_ fd: Int32, _ buffer: UnsafePointer<CChar>, _ count: Int) -> Int {
    Glibc.write(fd, buffer, count)
}
#endif
