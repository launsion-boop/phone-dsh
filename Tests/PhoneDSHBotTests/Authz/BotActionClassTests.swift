// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// A standing approval must cover the *class* of a destructive command, not one
/// path: the person answers "always" once for deletes, and the next delete of a
/// different target must not ask again. At the same time a class grant may
/// never widen past its family, and an exact deny still wins.
final class BotActionClassTests: XCTestCase {
    private let workspace = "/dsh/workspace/.dshbot/agents/main"
    private let principal = BotExecutionPrincipal(botId: "main", sessionId: "s1")

    // MARK: classification

    func testReadOnlyCommandsClassifyAsRead() {
        for command in ["ls -la", "git status", "cat notes.md", "rg TODO src",
                        "jq '.a' data.json", "find . -name '*.md'"] {
            XCTAssertEqual(BotShellActionClassifier.classify(command: command), .execRead,
                           "expected read: \(command)")
        }
    }

    func testDeleteAndGitResetAreNamedFamilies() {
        for command in ["rm -rf build", "rm notes.md", "find . -name '*.tmp' -delete",
                        "ls; rm -rf build"] {
            XCTAssertEqual(BotShellActionClassifier.classify(command: command), .execDelete,
                           "expected delete: \(command)")
        }
        XCTAssertEqual(BotShellActionClassifier.classify(command: "git reset --hard HEAD"),
                       .execGitReset)
    }

    func testEverythingElseStaysUnknown() {
        for command in ["python3 run.py", "sed -i s/a/b/ f", "ls; ls", "cat x | sh",
                        "curl -X POST https://example.test", ""] {
            XCTAssertEqual(BotShellActionClassifier.classify(command: command), .execUnknown,
                           "expected unknown: \(command)")
        }
        XCTAssertFalse(BotActionClass.execUnknown.isStandable)
        XCTAssertTrue(BotActionClass.execDelete.isStandable)
    }

    func testAnalyzerEffectsCarryTheClass() {
        let rm = BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string("rm -rf build")]),
            workspace: workspace)
        XCTAssertEqual(rm.map(\.actionClass), [.execDelete])
        XCTAssertEqual(rm.first?.grantOperation, "exec:delete")
        XCTAssertEqual(rm.first?.stableGrantResource, "*")
        XCTAssertTrue(rm.first?.canUseStandingGrant == true)

        let reset = BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string("git reset --hard")]),
            workspace: workspace)
        XCTAssertEqual(reset.map(\.actionClass), [.execGitReset])

        // A read-only command still draws no card and has no class.
        XCTAssertTrue(BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string("ls -la")]),
            workspace: workspace).isEmpty)
    }

    // MARK: grants

    private func deleteEffect(_ path: String, operation: String = "rm-destructive") -> BotToolEffect {
        BotToolEffect(tool: "bash", operation: operation, resource: path,
                      mutability: .destructive, policy: .ask,
                      label: "Delete files or directories (rm)", detail: path,
                      actionClass: .execDelete)
    }

    private func classGrant(_ operation: String, decision: BotGrantDecision = .allow,
                            scope: BotGrantScope = .until) -> BotGrant {
        BotGrant(botId: "main", tool: "bash", operation: operation, resource: "*",
                 scope: scope, createdAt: 1_000, decision: decision)
    }

    func testClassGrantCoversEveryTargetInTheFamily() async throws {
        let clock = BotTestClock(1_000)
        let store = BotGrantStore(now: { clock.now() })
        let authorizer = BotExecutionAuthorizer(grants: store)
        _ = try await store.add(classGrant("exec:delete"))

        let first = await authorizer.authorizeExecution(
            principal: principal, effects: [deleteEffect("/w/build")])
        XCTAssertTrue(first.allowed, "class grant must cover the first delete")
        let second = await authorizer.authorizeExecution(
            principal: principal,
            effects: [deleteEffect("/w/dist", operation: "rm-destructive")])
        XCTAssertTrue(second.allowed, "a different target in the same class must not ask again")
        let findDelete = await authorizer.authorizeExecution(
            principal: principal,
            effects: [deleteEffect("/w/tmp", operation: "find-delete")])
        XCTAssertTrue(findDelete.allowed, "find -delete is the same delete family")

        // The class never widens to another family or to an unclassified call.
        let reset = await authorizer.authorizeExecution(
            principal: principal,
            effects: [BotToolEffect(tool: "bash", operation: "git-destructive",
                                    resource: "git reset --hard", mutability: .destructive,
                                    policy: .ask, actionClass: .execGitReset)])
        XCTAssertFalse(reset.allowed)
        let unclassified = await authorizer.authorizeExecution(
            principal: principal,
            effects: [BotToolEffect(tool: "bash", operation: "sandbox-escalation",
                                    resource: "run=python3", mutability: .write,
                                    policy: .ask)])
        XCTAssertFalse(unclassified.allowed)
    }

    func testExactDenyBeatsAClassAllow() async throws {
        let clock = BotTestClock(1_000)
        let store = BotGrantStore(now: { clock.now() })
        let authorizer = BotExecutionAuthorizer(grants: store)
        _ = try await store.add(classGrant("exec:delete"))
        _ = try await store.add(BotGrant(botId: "main", tool: "bash",
                                         operation: "rm-destructive",
                                         resource: "/w/protected", scope: .until,
                                         createdAt: 1_000, decision: .deny))

        let allowed = await authorizer.authorizeExecution(
            principal: principal, effects: [deleteEffect("/w/build")])
        XCTAssertTrue(allowed.allowed)
        let denied = await authorizer.authorizeExecution(
            principal: principal, effects: [deleteEffect("/w/protected")])
        XCTAssertFalse(denied.allowed)
        XCTAssertEqual(denied.reason, "standing-deny")
    }

    func testClassGrantIsPerBotAndPerTool() async throws {
        let clock = BotTestClock(1_000)
        let store = BotGrantStore(now: { clock.now() })
        let authorizer = BotExecutionAuthorizer(grants: store)
        _ = try await store.add(classGrant("exec:delete"))
        let otherBot = await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(botId: "sidekick", sessionId: "s2"),
            effects: [deleteEffect("/w/build")])
        XCTAssertFalse(otherBot.allowed)
        let otherTool = await authorizer.authorizeExecution(
            principal: principal,
            effects: [BotToolEffect(tool: "write", operation: "exec:delete",
                                    resource: "/w/x", mutability: .write,
                                    policy: .ask, actionClass: .execDelete)])
        XCTAssertFalse(otherTool.allowed)
    }

    func testClassGrantSurvivesTheSnapshotRoundTrip() async throws {
        let clock = BotTestClock(1_000)
        let store = BotGrantStore(now: { clock.now() })
        let grant = try await store.add(classGrant("exec:delete"))
        XCTAssertEqual(grant.operation, "exec:delete")
        XCTAssertEqual(grant.resource, "*")
        XCTAssertEqual(grant.scope, .until)
    }
}