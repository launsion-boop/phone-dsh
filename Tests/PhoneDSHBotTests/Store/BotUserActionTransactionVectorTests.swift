// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotUserActionTransactionVectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bot-action-vectors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testUserActionTransactionPhoneVectorsRunThroughTheRealStore() async throws {
        let cases = try BotVectorFixture.load("user-action-transaction.phone.json")
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            let runner = BotVectorRunner(
                fileURL: BotVectorFixture.fileURL(for: testCase, directory: directory),
                clock: (testCase["clock"] as? NSNumber)?.int64Value ?? 1_000,
                leaseTTLms: (testCase["leaseTTLms"] as? NSNumber)?.int64Value ?? 30_000,
                ephemeralCapacity: (testCase["ephemeralCapacity"] as? NSNumber)?.intValue ?? 256)
            try await runner.run(testCase, name: name)
        }
    }
}
