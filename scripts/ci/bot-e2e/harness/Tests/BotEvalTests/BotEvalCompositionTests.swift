// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — prove the eval target compiles the production
// App sources rather than a copied "simplified Bot".

import Foundation
import XCTest
@testable import BotEvalApp
import PhoneDSHBot

final class BotEvalCompositionTests: XCTestCase {
    func testBotEvalAppSourcesAreSymlinksToProduction() throws {
        let harness = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = harness.appendingPathComponent("Sources/BotEvalApp", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sources, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 10,
            "the eval target must link the production Bot sources")
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink,
                           "\(file.lastPathComponent) must be a symlink, not a copied source")
            let resolved = file.resolvingSymlinksInPath().path
            XCTAssertTrue(
                resolved.contains("/examples/probe-app/")
                    || resolved.hasSuffix("/scripts/ci/bot-e2e/app/Sources/BotTurnProcessShim.swift"),
                "\(file.lastPathComponent) resolves outside the production App sources: \(resolved)")
        }
        XCTAssertTrue(BotRuntimeComposition.workerTokenPlaceholder.hasPrefix("phone-host-injects"),
                      "the production composition must be the linked one")
    }
}
