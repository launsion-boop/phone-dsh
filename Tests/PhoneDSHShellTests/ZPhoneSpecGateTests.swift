// SPDX-License-Identifier: MIT
// phone-spec gate execution record.
//
// `scripts/ci/check.sh --only phone-spec` runs the independent checker
// `spec/v1/tools/spec_golden.py` over the landed specification. The
// G2 acceptance for the VFS resource-refusal repair requires that gate to PASS
// with an execution record from the pipeline rather than a prose claim. This
// test runs the stage's own command against the checkout and fails when the
// stage fails, so the pipeline's `sdk-all` log carries the record on every
// clean run. The class name starts with `Z` on purpose: XCTest runs test
// suites in name order and the check commands keep only the tail of the log.
//
// macOS-only: the test drives a subprocess and `Process` is unavailable on
// iOS; the spec gate itself is a host-side static check.

#if os(macOS)
import Foundation
import XCTest

final class ZPhoneSpecGateTests: XCTestCase {
    /// The checkout root. `#filePath` is
    /// `<repo>/Tests/PhoneDSHShellTests/ZPhoneSpecGateTests.swift`.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhoneDSHShellTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
    }

    /// Runs `bash scripts/ci/check.sh --only phone-spec` in the checkout and
    /// records the stage result in the test output (the same command the
    /// `phone-spec` CI stage runs).
    func testPhoneSpecGatePasses() throws {
        let root = Self.repositoryRoot
        let checker = root.appendingPathComponent("spec/v1/tools/spec_golden.py")
        guard FileManager.default.fileExists(atPath: checker.path) else {
            XCTFail("the tracked spec/v1 checker is missing from the resolved checkout root")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "scripts/ci/check.sh", "--only", "phone-spec"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self)
        process.waitUntilExit()

        print("phone-spec gate: `bash scripts/ci/check.sh --only phone-spec` "
            + "rc=\(process.terminationStatus)")
        for line in output.split(separator: "\n") where line.contains("files checked")
            || line.contains("PASS: phone-spec") || line.contains("FAIL: phone-spec")
            || line.contains("CI GATE") {
            print("phone-spec gate: \(line)")
        }

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("== PASS: phone-spec"), output)
        XCTAssertTrue(output.contains("files checked, 0 error(s)"), output)
    }
}
#endif
