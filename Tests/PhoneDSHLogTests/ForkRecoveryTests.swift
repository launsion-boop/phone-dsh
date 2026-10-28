// SPDX-License-Identifier: MIT
// Crash recovery simulated with fork(): the child appends records through the
// synchronous WAL appender (one write() per record, i.e. the level-1 promise),
// then _exit(0) without closing anything. The parent waitpid()s and reopens the
// workspace; every acknowledged record must still be readable and materialize.

import Darwin
import Foundation
import XCTest
@testable import PhoneDSHLog
import PhoneDSHWire

final class ForkRecoveryTests: XCTestCase {
    /// The Swift Darwin overlay marks `fork()` unavailable; the W1 crash test
    /// still needs it. Resolve the libc symbol explicitly.
    private static let forkFunction: @convention(c) () -> pid_t = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else {
            fatalError("fork symbol is unavailable")
        }
        return unsafeBitCast(symbol, to: (@convention(c) () -> pid_t).self)
    }()

    private func exitedNormally(_ status: Int32) -> Bool {
        (status & 0x7F) == 0
    }

    private func exitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xFF
    }

    func testForkedCrashKeepsEveryLevelOneRecord() async throws {
        let root = LogTestSupport.root(for: self)
        let configuration = LogTestSupport.configuration(root: root)
        let bootID = LogTestSupport.bootID(0x10)
        let writer = try WALWriter(configuration: configuration, bootID: bootID)
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/parent-a.txt",
                                                         data: "parent-a"))
        _ = try await writer.append(LogTestSupport.write("/dsh/workspace/parent-b.txt",
                                                         data: "parent-b"))
        try await writer.recordMaterializedUpto(2)
        _ = try await writer.closeEpoch()

        let childRecords = 5
        let pid = Self.forkFunction()
        if pid == 0 {
            do {
                let appender = try WALSynchronousAppender(configuration: configuration,
                                                          bootID: bootID)
                for index in 0..<childRecords {
                    _ = try appender.append(LogTestSupport.write(
                        "/dsh/workspace/child-\(index).txt", data: "child-\(index)"))
                }
                // No close, no fsync, no atexit; this is a kill after write().
                _exit(0)
            } catch {
                _exit(2)
            }
        }
        XCTAssertGreaterThan(pid, 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertTrue(exitedNormally(status), "child status \(status)")
        XCTAssertEqual(exitCode(status), 0)

        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.count, 2 + childRecords)
        XCTAssertEqual(records.map(\.mseq), Array(1...(UInt64(2 + childRecords))))

        // Reopen through the full recovery path and materialize the tail.
        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: LogTestSupport.bootID(0x11))
        let report = try await log.recover()
        XCTAssertEqual(report.materializedUptoMseq, UInt64(2 + childRecords))
        let materializedRoot = WorkspacePaths(root: root).materializedDirectory
        for index in 0..<childRecords {
            let url = materializedRoot
                .appendingPathComponent("workspace/child-\(index).txt")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "child-\(index)")
        }
    }

    func testForkedCrashDuringSegmentRotationRecoversAllRecords() async throws {
        let root = LogTestSupport.root(for: self)
        var configuration = LogTestSupport.configuration(root: root)
        configuration.segmentRollBytes = 260
        let bootID = LogTestSupport.bootID(0x20)
        let writer = try WALWriter(configuration: configuration, bootID: bootID)
        _ = try await writer.append(LogTestSupport.write(
            "/dsh/workspace/parent.txt", data: String(repeating: "p", count: 80)))
        try await writer.recordMaterializedUpto(1)
        _ = try await writer.closeEpoch()

        let childRecords = 8
        let pid = Self.forkFunction()
        if pid == 0 {
            do {
                let appender = try WALSynchronousAppender(configuration: configuration,
                                                          bootID: bootID)
                for index in 0..<childRecords {
                    _ = try appender.append(LogTestSupport.write(
                        "/dsh/workspace/rotated-\(index).txt",
                        data: String(repeating: "c", count: 80)))
                }
                _exit(0)
            } catch {
                _exit(3)
            }
        }
        XCTAssertGreaterThan(pid, 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertTrue(exitedNormally(status))
        XCTAssertEqual(exitCode(status), 0)

        let segments = try LogTestSupport.segments(in: root)
        XCTAssertGreaterThan(segments.count, 3, "the child must have rotated segments")
        let records = try LogTestSupport.records(in: root)
        XCTAssertEqual(records.count, 1 + childRecords)
        XCTAssertEqual(records.map(\.mseq), Array(1...UInt64(1 + childRecords)))

        let log = try WorkspaceLog(configuration: configuration,
                                   bootID: LogTestSupport.bootID(0x21))
        let report = try await log.recover()
        XCTAssertEqual(report.materializedUptoMseq, UInt64(1 + childRecords))
        XCTAssertEqual(report.nextMseq, UInt64(2 + childRecords))
    }
}
