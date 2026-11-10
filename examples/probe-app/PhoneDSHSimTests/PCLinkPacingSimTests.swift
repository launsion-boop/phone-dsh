// SPDX-License-Identifier: MIT
// pclink-pacing simulator regressions: P18 last-workspace key, PC grouping by
// DSH workspace, drawer loading/error state and the single install command.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHPCLink
import ProbeKit
import XCTest

@MainActor
final class PCLinkPacingSimTests: XCTestCase {
    func testPCNewSessionWorkspacePersistsPerComputerAndClearsOnUnpair() {
        let store = TestDefaults()
        defer { store.remove() }
        let defaults = store.defaults
        let pcA = BackendID.pc(machineId: "aaaaaaaaaaaaaaaaaaaaaaaaaa")
        let pcB = BackendID.pc(machineId: "bbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertNil(WorkspaceStorage.lastWorkspaceID(for: pcA, defaults: defaults))
        WorkspaceStorage.setLastWorkspaceID("ws-alpha", for: pcA, defaults: defaults)
        XCTAssertEqual(WorkspaceStorage.lastWorkspaceID(for: pcA, defaults: defaults), "ws-alpha")
        XCTAssertNil(WorkspaceStorage.lastWorkspaceID(for: pcB, defaults: defaults))
        // The phone backend has one workspace and must not read/write the key.
        WorkspaceStorage.setLastWorkspaceID("ws-phone", for: .phone, defaults: defaults)
        XCTAssertNil(WorkspaceStorage.lastWorkspaceID(for: .phone, defaults: defaults))
        XCTAssertEqual(WorkspaceStorage.lastWorkspaceID(for: pcA, defaults: defaults), "ws-alpha")
        // Removing the PC pairing drops its key but leaves another PC's alone.
        WorkspaceStorage.setLastWorkspaceID("ws-beta", for: pcB, defaults: defaults)
        WorkspaceStorage.removeLocalData(for: pcA, defaults: defaults)
        XCTAssertNil(WorkspaceStorage.lastWorkspaceID(for: pcA, defaults: defaults))
        XCTAssertEqual(WorkspaceStorage.lastWorkspaceID(for: pcB, defaults: defaults), "ws-beta")
    }

    func testPCWorkspaceGroupingUsesMembershipThenLongestCwd() {
        let alpha = ManagedWorkspace(id: "alpha", title: " Alpha 项目 ", path: "/work/alpha",
                                     sessionIDs: ["explicit"])
        let beta = ManagedWorkspace(id: "beta", title: "Beta", path: "/work/alpha/sub",
                                    sessionIDs: [])
        let workspaces = [alpha, beta]
        func session(_ id: String, cwd: String?) -> ManagedSession {
            ManagedSession(id: id, title: id, updatedAt: Date(timeIntervalSince1970: 0),
                           running: false, blank: false, cwd: cwd,
                           parentSessionID: nil, searchSnippet: nil)
        }
        XCTAssertEqual(PCLinkWorkspaceGrouping.workspaceID(for: session("explicit", cwd: "/work/alpha/sub/x"),
                                                            in: workspaces), "alpha",
                       "an explicit workspace/sessionIds membership wins over a cwd guess")
        XCTAssertEqual(PCLinkWorkspaceGrouping.workspaceID(for: session("nested", cwd: "/work/alpha/sub/x"),
                                                            in: workspaces), "beta",
                       "the longest host path owns the session")
        XCTAssertNil(PCLinkWorkspaceGrouping.workspaceID(for: session("sibling", cwd: "/work/alphabet"),
                                                          in: workspaces),
                     "a path match respects component boundaries")
        XCTAssertEqual(PCLinkWorkspaceGrouping.title(alpha.title, fallback: "工作区"), "Alpha 项目")
        XCTAssertEqual(PCLinkWorkspaceGrouping.title("  ", fallback: "工作区"), "工作区")
    }

    func testPCWorkspaceSelectionValidatesEveryCandidate() {
        let workspaces = [
            ManagedWorkspace(id: "alpha", title: "Alpha", path: "/work/alpha", sessionIDs: []),
            ManagedWorkspace(id: "beta", title: "Beta", path: "/work/beta", sessionIDs: []),
        ]
        XCTAssertEqual(PCLinkWorkspaceSelection.resolve(pending: "alpha", stored: "beta",
                                                        recent: nil, workspaces: workspaces), "alpha")
        XCTAssertEqual(PCLinkWorkspaceSelection.resolve(pending: "deleted", stored: "beta",
                                                        recent: "alpha", workspaces: workspaces), "beta")
        XCTAssertEqual(PCLinkWorkspaceSelection.resolve(pending: nil, stored: "deleted",
                                                        recent: "alpha", workspaces: workspaces), "alpha")
        XCTAssertNil(PCLinkWorkspaceSelection.resolve(pending: "gone", stored: "gone",
                                                       recent: "gone", workspaces: workspaces))
    }

    func testDrawerListStateNeverShowsEmptyWhileLoadingOrAfterAnError() {
        XCTAssertEqual(PCLinkDrawerPolicy.listState(isLoading: true, error: nil, sessionCount: 0),
                       .loading)
        XCTAssertEqual(PCLinkDrawerPolicy.listState(isLoading: false,
                                                    error: "session/list failed", sessionCount: 0),
                       .error, "a failed read must not read as 还没有 PC 会话")
        XCTAssertEqual(PCLinkDrawerPolicy.listState(isLoading: false,
                                                    error: "session/list failed", sessionCount: 3),
                       .rows, "cached rows stay visible with the error row above them")
        XCTAssertEqual(PCLinkDrawerPolicy.listState(isLoading: false, error: nil, sessionCount: 0),
                       .empty)
    }

    func testInstallGuideIsTheTestedShortCommandShape() {
        XCTAssertEqual(PCLinkInstallGuide.installCommand,
                       "dsh plugin --profile web add 'github:launsion-boop/phone-dsh#main&path:/pclink'")
        XCTAssertEqual(PCLinkInstallGuide.pairingCommand,
                       "~/.dsh/profiles/web/node_modules/.bin/pclink pair")
        XCTAssertTrue(PCLinkInstallGuide.requirement.contains("0.2.2"))
        XCTAssertTrue(PCLinkInstallGuide.restartHint.contains("dsh web"))
    }
}
