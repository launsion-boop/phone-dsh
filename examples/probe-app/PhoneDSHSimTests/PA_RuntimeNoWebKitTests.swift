// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import ProbeKit

final class PA_RuntimeNoWebKitTests: XCTestCase {
    func testNativeTurnCompletesWithoutWebKitOrDSHHostDependencies() async throws {
        let transport = PA_RuntimeScriptedTransport(replies: [pa_runtimeTextResponse("native only")])
        let adapter = try NativeMainAgentAdapter(clientResolver: PA_RuntimeFixedResolver(transport: transport))
        let events = try await pa_runtimeCollect(adapter.run(turn: pa_runtimeTurn(mandate: nil)))
        XCTAssertEqual(pa_runtimeCompletedText(events), "native only")

        let runtimeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ProbeKit/PersonalAgent/Runtime", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: runtimeURL, includingPropertiesForKeys: nil))
        var sourceCount = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sourceCount += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["import WebKit", "WKWebView", "WebEngine", "PhoneDSHHost"] {
                XCTAssertFalse(source.contains(forbidden), "\(url.lastPathComponent) references \(forbidden)")
            }
        }
        XCTAssertGreaterThan(sourceCount, 0)
    }
}
