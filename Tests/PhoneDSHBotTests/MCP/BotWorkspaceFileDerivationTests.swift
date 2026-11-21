// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// G-2 §50 workspaceFile producer shape. The L status/erase assertions run in
/// the integration candidate that carries L's API; this test locks the
/// producer's path normalization, canonical user event source and frozen
/// derivation shape without inventing a source.
final class BotWorkspaceFileDerivationTests: XCTestCase {
    func testToolWritePathParsesBothArgumentShapes() {
        let json = #"{"file_path":"docs/current.md","content":"x"}"#
        XCTAssertEqual(BotDSHRemoteRuntime.toolWritePath(from: .object([
            "arguments": .string(json),
        ])), "docs/current.md")
        XCTAssertEqual(BotDSHRemoteRuntime.toolWritePath(from: .object([
            "arguments": .object(["path": .string("notes/a.md")]),
        ])), "notes/a.md")
        XCTAssertNil(BotDSHRemoteRuntime.toolWritePath(from: .object([
            "arguments": .string("not-json"),
        ])))
    }

    func testRelativePathStaysInsideBotRootAndRejectsEscapes() {
        let root = "/dsh/workspace/.dshbot/agents/main"
        XCTAssertEqual(
            BotDSHRemoteRuntime.workspaceRelativePath(
                "/dsh/workspace/.dshbot/agents/main/docs/current.md", root: root),
            "docs/current.md")
        XCTAssertEqual(
            BotDSHRemoteRuntime.workspaceRelativePath("docs/current.md", root: root),
            "docs/current.md")
        XCTAssertNil(BotDSHRemoteRuntime.workspaceRelativePath("/tmp/outside.md", root: root))
        XCTAssertNil(BotDSHRemoteRuntime.workspaceRelativePath("/dsh/workspace/.dshbot/agents/other/x.md", root: root))
        XCTAssertNil(BotDSHRemoteRuntime.workspaceRelativePath("docs/../secret.md", root: root))
        XCTAssertNil(BotDSHRemoteRuntime.workspaceRelativePath("docs//empty.md", root: root))
    }

    func testDerivationUsesCanonicalUserEventAndWorkspaceFileIdentity() throws {
        let value = BotDSHRemoteRuntime.workspaceFileDerivation(
            path: "docs/current.md", botID: "main",
            userRecord: "record://event/14",
            creatorRecord: "record://event/15")
        let derivation = try XCTUnwrap(value.objectValue)
        let artifact = try XCTUnwrap(derivation["artifact"]?.objectValue)
        XCTAssertEqual(artifact["kind"]?.stringValue, "workspaceFile")
        XCTAssertEqual(artifact["id"]?.stringValue, "docs/current.md")
        XCTAssertNil(artifact["version"])
        let sources = try XCTUnwrap(derivation["sources"]?.arrayValue)
        XCTAssertEqual(sources.count, 2)
        let source = try XCTUnwrap(sources.first?.objectValue)
        XCTAssertEqual(source["record"]?.stringValue, "record://event/14")
        XCTAssertEqual(source["role"]?.stringValue, "trigger")
        let cre = try XCTUnwrap(sources.last?.objectValue)
        XCTAssertEqual(cre["record"]?.stringValue, "record://event/15")
        XCTAssertEqual(cre["role"]?.stringValue, "creator")
        let resource = try XCTUnwrap(source["resource"]?.objectValue)
        XCTAssertEqual(resource["kind"]?.stringValue, "workspace-file")
        XCTAssertEqual(resource["key"]?.stringValue, "docs/current.md")
        XCTAssertEqual(resource["owner"]?.stringValue, "main")
        XCTAssertEqual(resource["scope"]?.stringValue, "agent")
    }
}
