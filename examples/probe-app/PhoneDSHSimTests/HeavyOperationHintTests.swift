// SPDX-License-Identifier: MIT
//
// S1-E: the pre-hint recognises a few typical heavy tool invocations from the
// already-parsed `toolCall`, including quoted strings, pipes and `&&` chains.
// It never estimates a size and never blocks the call.

import XCTest
@testable import ProbeKit

final class HeavyOperationHintTests: XCTestCase {
    private func operations(_ command: String) -> [HeavyOperation] {
        HeavyOperationHint.operations(inCommandLine: command)
    }

    private func tool(_ command: String) -> Bool {
        HeavyOperationHint.isHeavy(toolName: "bash", arguments: ["command": command])
    }

    // MARK: - git clone

    func testFullGitCloneIsHeavyButShallowCloneIsNot() {
        XCTAssertTrue(tool("git clone https://github.com/example/repo.git"))
        XCTAssertTrue(tool("git -C /dsh/workspace clone https://example.test/r.git"))
        XCTAssertFalse(tool("git clone --depth 1 https://example.test/r.git"))
        XCTAssertFalse(tool("git clone --depth=1 --single-branch https://example.test/r.git"))
        XCTAssertFalse(tool("git clone https:/x.test/r.git --depth 1"))
        XCTAssertFalse(tool("git status"))
    }

    // MARK: - package installs

    func testDependencyInstallFamilies() {
        XCTAssertTrue(tool("npm install"))
        XCTAssertTrue(tool("npm i left-pad"))
        XCTAssertTrue(tool("npm ci"))
        XCTAssertTrue(tool("pnpm install --frozen-lockfile"))
        XCTAssertTrue(tool("pnpm add lodash"))
        XCTAssertTrue(tool("yarn"))
        XCTAssertTrue(tool("yarn install"))
        XCTAssertTrue(tool("yarn build"))
        XCTAssertFalse(tool("npm run test"))
        XCTAssertFalse(tool("npm --version"))
        XCTAssertFalse(tool("yarn --version"))
        XCTAssertTrue(tool("pip install requests"))
        XCTAssertTrue(tool("pip3 install --user numpy"))
        XCTAssertTrue(tool("python3 -m pip install flask"))
        XCTAssertFalse(tool("pip list"))
        XCTAssertFalse(tool("python3 -m pip --version"))
    }

    // MARK: - downloads and extraction

    func testDownloadsAndExtraction() {
        XCTAssertTrue(tool("curl -L https://example.test/big.bin -o big.bin"))
        XCTAssertTrue(tool("wget https://example.test/big.bin"))
        XCTAssertFalse(tool("curl --version"))
        XCTAssertFalse(tool("wget --help"))
        XCTAssertTrue(tool("unzip archive.zip"))
        XCTAssertTrue(tool("tar -xzf archive.tgz"))
        XCTAssertTrue(tool("tar xzf archive.tgz"))
        XCTAssertTrue(tool("tar --extract -f archive.tar"))
        XCTAssertFalse(tool("tar -czf archive.tgz dir"))
        XCTAssertFalse(tool("tar --list -f archive.tar"))
    }

    // MARK: - quotes, pipes, chains

    func testQuotedStringsAreNotCommands() {
        XCTAssertFalse(tool("echo 'git clone https://example.test/r.git'"))
        XCTAssertFalse(tool("printf \"npm install\" > note.txt"))
        XCTAssertFalse(tool("cat notes.md | grep npm"))
        XCTAssertFalse(tool("grep -R \"pip install\" ."))
    }

    func testPipesAndChainsSplitCommands() {
        XCTAssertTrue(tool("cd /dsh/workspace && npm install"))
        XCTAssertTrue(tool("echo starting && git clone https://example.test/r.git"))
        XCTAssertTrue(tool("cat list.txt | xargs -n1 unzip"))
        XCTAssertTrue(tool("curl -L https://example.test/a | tar -xz"))
        XCTAssertTrue(tool("false || pip install x"))
        XCTAssertTrue(tool("echo one; wget https://example.test/a"))
        XCTAssertTrue(tool("sudo npm install"))
        XCTAssertTrue(tool("FOO=1 BAR=2 pnpm install"))
        XCTAssertTrue(tool("env K=V yarn add x"))
    }

    func testQuotedChainOperatorsStayInsideOneCommand() {
        XCTAssertTrue(tool("curl 'https://example.test/a?x=1&&y=2'"))
        XCTAssertFalse(tool("echo 'one && two'"))
        XCTAssertFalse(tool("echo \"a;b\""))
    }

    // MARK: - tool-name gating and argument shapes

    func testOnlyShellishToolsAreInspected() {
        XCTAssertFalse(HeavyOperationHint.isHeavy(toolName: "write",
                                                  arguments: ["content": "npm install"]))
        XCTAssertFalse(HeavyOperationHint.isHeavy(toolName: "grep",
                                                  arguments: ["pattern": "git clone"]))
        XCTAssertTrue(HeavyOperationHint.isHeavy(toolName: "mcp__device__run_command",
                                                 arguments: ["command": "unzip a.zip"]))
        XCTAssertTrue(HeavyOperationHint.isHeavy(toolName: "pwsh",
                                                 arguments: ["command": "npm install"]))
        XCTAssertFalse(HeavyOperationHint.isHeavy(toolName: "bash", arguments: [:]))
    }

    func testOperationsAreDeduplicatedAndStable() {
        let found = operations("npm install && curl -L https://example.test/a && unzip a.zip")
        XCTAssertEqual(found, [.dependencyInstall, .download, .extract])
        XCTAssertEqual(operations("echo hi"), [])
        XCTAssertEqual(HeavyOperationHint.badge, "可能较重")
    }
}
