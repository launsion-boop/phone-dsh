// SPDX-License-Identifier: MIT
// WebEngineNativePreview tests: message parsing, session/path refusal and
// realpath containment. They never create a WKWebView or present Quick Look;
// the resolver is injected, so the security checks run on any macOS test host.

import Foundation
import XCTest
@testable import PhoneDSHEngine

final class WebEngineNativePreviewTests: XCTestCase {
    // MARK: - Message parsing

    func testParsesTheExactAcceptedMessage() throws {
        let message: [String: Any] = [
            "v": NSNumber(value: 1),
            "id": "preview-1",
            "sessionId": "session-1",
            "path": "docs/report.docx",
        ]
        let request = try WebEngineNativePreviewRequest.parse(message)
        XCTAssertEqual(request.id, "preview-1")
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertEqual(request.path, "docs/report.docx")
    }

    func testRejectsExtraFields() {
        assertInvalid([
            "v": NSNumber(value: 1),
            "id": "preview-1",
            "sessionId": "session-1",
            "path": "docs/report.docx",
            "url": "file:///etc/passwd",
        ])
    }

    func testRejectsUnsupportedVersions() {
        assertUnsupportedVersion([
            "v": NSNumber(value: 2),
            "id": "preview-1",
            "sessionId": "session-1",
            "path": "docs/report.docx",
        ])
        assertUnsupportedVersion([
            "v": "1",
            "id": "preview-1",
            "sessionId": "session-1",
            "path": "docs/report.docx",
        ])
        assertUnsupportedVersion([
            "v": NSNumber(value: true),
            "id": "preview-1",
            "sessionId": "session-1",
            "path": "docs/report.docx",
        ])
    }

    func testRejectsMalformedValues() {
        for message: [String: Any] in [
            ["v": NSNumber(value: 1), "id": "", "sessionId": "s", "path": "a.docx"],
            ["v": NSNumber(value: 1), "id": "i", "sessionId": "", "path": "a.docx"],
            ["v": NSNumber(value: 1), "id": "i", "sessionId": "s", "path": ""],
            ["v": NSNumber(value: 1), "id": NSNull(), "sessionId": "s", "path": "a.docx"],
            ["v": NSNumber(value: 1), "id": "i", "sessionId": "s",
             "path": "bad\u{0}.docx"],
            ["v": NSNumber(value: 1), "id": "i\n", "sessionId": "s", "path": "a.docx"],
        ] {
            assertInvalid(message)
        }
        assertInvalid("not an object")
    }

    // MARK: - Path validation

    func testAcceptsWorkspaceRelativeAndAbsolutePaths() throws {
        XCTAssertEqual(try WebEngineNativePreviewPath.relativePath(
            fromRequestPath: "docs/report.docx"), "docs/report.docx")
        XCTAssertEqual(try WebEngineNativePreviewPath.relativePath(
            fromRequestPath: "/dsh/workspace/docs/report.docx"),
            "docs/report.docx")
        XCTAssertEqual(try WebEngineNativePreviewPath.relativePath(
            fromRequestPath: "./docs/report.docx"), "docs/report.docx")
    }

    func testRejectsTraversalAndOtherRootsBeforeStat() throws {
        for path in ["../secret.docx", "docs/../../secret.docx",
                     "/etc/passwd", "/dsh/home/secret.docx",
                     "/dsh/workspace-other/secret.docx",
                     "/dsh/workspace", "docs//report.docx",
                     "docs/", "docs\\report.docx", "~/report.docx"] {
            XCTAssertThrowsError(try WebEngineNativePreviewPath.relativePath(
                fromRequestPath: path), "accepted \(path)") { error in
                let failure = error as? WebEngineNativePreviewFailure
                XCTAssertNotNil(failure, "unexpected error for \(path): \(error)")
                XCTAssertTrue([WebEngineNativePreviewFailure.pathOutsideWorkspace("").code,
                               WebEngineNativePreviewFailure.invalidMessage("").code]
                    .contains(failure?.code ?? ""), "unexpected code for \(path)")
            }
        }
    }

    func testRejectsStatPathsOutsideTheWorkspaceMount() throws {
        for path in ["/dsh/home/secret.docx", "/tmp/report.docx",
                     "/dsh/workspace-other/report.docx", "/dsh/workspace",
                     "/dsh/workspace/../home/secret.docx"] {
            XCTAssertThrowsError(try WebEngineNativePreviewPath.relativePath(
                fromStatAbsolutePath: path), "accepted \(path)") { error in
                XCTAssertEqual((error as? WebEngineNativePreviewFailure)?.code,
                               WebEngineNativePreviewFailure.pathOutsideWorkspace("").code)
            }
        }
    }

    // MARK: - Service: session authority

    func testUnknownCurrentSessionIsRefusedWithoutStat() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = TestResolver(sessionID: nil,
                                    result: .success("/dsh/workspace/a.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(request())
        assertFailure(result, code: "unknown-session")
        XCTAssertEqual(resolver.calls.count, 0)
    }

    func testNonCurrentSessionIsRefusedWithoutStat() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = TestResolver(sessionID: "another-session",
                                    result: .success("/dsh/workspace/a.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(request())
        assertFailure(result, code: "session-mismatch")
        XCTAssertEqual(resolver.calls.count, 0)
    }

    // MARK: - Service: resolver and realpath

    func testResolvesARealMaterializedFile() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("docs/report.docx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("real docx bytes".utf8).write(to: file)
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/workspace/docs/report.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(request(path: "docs/report.docx"))
        guard case .success(let url) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(url.standardizedFileURL.resolvingSymlinksInPath(),
                       file.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(resolver.calls.count, 1)
        XCTAssertEqual(resolver.calls.first?.0, "session-1")
        XCTAssertEqual(resolver.calls.first?.1, "docs/report.docx")
    }

    func testAbsoluteWorkspacePathIsNormalizedBeforeStat() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("docs/report.docx")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("real docx bytes".utf8).write(to: file)
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/workspace/docs/report.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(
            request(path: "/dsh/workspace/docs/report.docx"))
        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(resolver.calls.first?.1, "docs/report.docx")
    }

    func testSymlinkInsideTheWorkspaceResolvesToItsContainedTarget() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("docs/report.docx")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.docx"),
            withDestinationURL: target)
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/workspace/link.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(request(path: "link.docx"))
        guard case .success(let url) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(url.standardizedFileURL.resolvingSymlinksInPath(),
                       target.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testStatErrorIsReportedAsARealFailure() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .failure(TestError("no such session")))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(request())
        assertFailure(result, code: "workspace-file-unavailable")
    }

    func testStatOutsideWorkspaceIsRefused() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/home/secret.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        let result = await service.resolve(request())
        assertFailure(result, code: "path-outside-workspace")
    }

    func testMissingAndDirectoryPathsAreRefused() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/workspace/docs/report.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        assertFailure(await service.resolve(request(path: "docs/report.docx")),
                      code: "not-regular-file")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
        assertFailure(await service.resolve(request(path: "docs/report.docx")),
                      code: "not-regular-file")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs/report.docx"),
            withIntermediateDirectories: true)
        assertFailure(await service.resolve(request(path: "docs/report.docx")),
                      code: "not-regular-file")
    }

    func testSymlinkEscapingTheMaterializedWorkspaceIsRefused() async throws {
        let root = try makeWorkspace()
        let outside = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("secret.docx")
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.docx"),
            withDestinationURL: outsideFile)
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/workspace/escape.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        assertFailure(await service.resolve(request(path: "escape.docx")),
                      code: "path-outside-workspace")
    }

    func testTraversalRequestDoesNotCallStat() async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = TestResolver(sessionID: "session-1",
                                    result: .success("/dsh/workspace/a.docx"))
        let service = WebEngineNativePreviewService(resolver: resolver,
                                                    workspaceDirectory: root)
        for path in ["../secret.docx", "/dsh/home/secret.docx", "/etc/passwd"] {
            let result = await service.resolve(request(path: path))
            assertFailure(result, code: "path-outside-workspace")
        }
        XCTAssertEqual(resolver.calls.count, 0)
    }

    // MARK: - In-flight ownership

    func testSecondRequestSupersedesAResolveThatHasNotPresented() {
        var flight = WebEngineNativePreviewFlight()
        let first = flight.admit(requestID: "first")
        guard case .admitted(let firstToken) = first else {
            return XCTFail("expected the first request to be admitted, got \(first)")
        }
        let second = flight.admit(requestID: "second")
        guard case .superseded(let previousRequestID, let secondToken) = second else {
            return XCTFail("expected the second request to supersede, got \(second)")
        }
        XCTAssertEqual(previousRequestID, "first")
        XCTAssertFalse(flight.isResolving(token: firstToken, requestID: "first"))
        XCTAssertTrue(flight.isResolving(token: secondToken, requestID: "second"))
        // The first stat call may still finish; its token can no longer present.
        let stalePresentation = flight.beginPresenting(token: firstToken,
                                                       requestID: "first")
        XCTAssertFalse(stalePresentation)
        let currentPresentation = flight.beginPresenting(token: secondToken,
                                                         requestID: "second")
        XCTAssertTrue(currentPresentation)
    }

    func testRequestWhilePresentingIsBusyAndKeepsThePresentedRequest() {
        var flight = WebEngineNativePreviewFlight()
        let first = flight.admit(requestID: "first")
        guard case .admitted(let firstToken) = first else {
            return XCTFail("expected the first request to be admitted, got \(first)")
        }
        let presentation = flight.beginPresenting(token: firstToken,
                                                  requestID: "first")
        XCTAssertTrue(presentation)
        XCTAssertEqual(flight.admit(requestID: "second"), .busy)
        XCTAssertTrue(flight.isPresenting(token: firstToken, requestID: "first"))
        let dismissed = flight.finishPresenting(token: firstToken, requestID: "first")
        XCTAssertTrue(dismissed)
        guard case .admitted = flight.admit(requestID: "second") else {
            return XCTFail("a dismissed presentation must admit the next request")
        }
    }

    func testStaleResolveCompletionCannotClearANewerRequest() {
        var flight = WebEngineNativePreviewFlight()
        let first = flight.admit(requestID: "first")
        guard case .admitted(let firstToken) = first else {
            return XCTFail("expected the first request to be admitted, got \(first)")
        }
        let finished = flight.finishResolving(token: firstToken, requestID: "first")
        XCTAssertTrue(finished)
        let second = flight.admit(requestID: "second")
        guard case .admitted(let secondToken) = second else {
            return XCTFail("expected the second request to be admitted, got \(second)")
        }
        let staleCompletion = flight.finishResolving(token: firstToken,
                                                     requestID: "first")
        XCTAssertFalse(staleCompletion)
        XCTAssertTrue(flight.isResolving(token: secondToken, requestID: "second"))
    }

    // MARK: - Result script

    func testResultCallbackShape() throws {
        let success = WebEngineNativePreviewResult.presented(id: "p-1")
        let script = try XCTUnwrap(success.javaScriptCall())
        XCTAssertTrue(script.hasPrefix(
            "window.__PDSH_NATIVE_PREVIEW_RESULT__ && window.__PDSH_NATIVE_PREVIEW_RESULT__("))
        XCTAssertTrue(script.contains("\"id\":\"p-1\""))
        XCTAssertTrue(script.contains("\"ok\":true"))
        XCTAssertTrue(script.contains("\"code\":\"presented\""))
        XCTAssertTrue(script.contains("\"message\":\"\""))

        let failure = WebEngineNativePreviewResult.failed(
            id: "p-2", failure: .previewUnavailable("cannot preview"))
        let failureScript = try XCTUnwrap(failure.javaScriptCall())
        XCTAssertTrue(failureScript.contains("\"ok\":false"))
        XCTAssertTrue(failureScript.contains("\"code\":\"preview-unavailable\""))
        XCTAssertTrue(failureScript.contains("\"message\":\"cannot preview\""))
    }

    // MARK: - Helpers

    private func request(path: String = "docs/report.docx")
        -> WebEngineNativePreviewRequest {
        WebEngineNativePreviewRequest(id: "preview-1", sessionID: "session-1",
                                      path: path)
    }

    private func assertInvalid(_ body: Any, file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try WebEngineNativePreviewRequest.parse(body),
                             file: file, line: line) { error in
            XCTAssertEqual((error as? WebEngineNativePreviewFailure)?.code,
                           "invalid-message", file: file, line: line)
        }
    }

    private func assertUnsupportedVersion(_ body: Any, file: StaticString = #filePath,
                                          line: UInt = #line) {
        XCTAssertThrowsError(try WebEngineNativePreviewRequest.parse(body),
                             file: file, line: line) { error in
            XCTAssertEqual((error as? WebEngineNativePreviewFailure)?.code,
                           "unsupported-version", file: file, line: line)
        }
    }

    private func assertFailure(_ result: Result<URL, WebEngineNativePreviewFailure>,
                               code: String, file: StaticString = #filePath,
                               line: UInt = #line) {
        switch result {
        case .success(let url):
            XCTFail("expected \(code), resolved \(url.path)", file: file, line: line)
        case .failure(let failure):
            XCTAssertEqual(failure.code, code, file: file, line: line)
        }
    }

    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pdsh-native-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return root
    }
}

private struct TestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Thread-safe injected resolver; no WebKit or Quick Look is involved.
private final class TestResolver: WebEngineNativePreviewResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: String?
    private let result: Result<String, Error>
    private var recordedCalls: [(String, String)] = []

    init(sessionID: String?, result: Result<String, Error>) {
        self.sessionID = sessionID
        self.result = result
    }

    var calls: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func currentSessionID() async -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    func workspacePath(sessionID: String, path: String) async throws -> String {
        lock.lock()
        recordedCalls.append((sessionID, path))
        lock.unlock()
        return try result.get()
    }
}
