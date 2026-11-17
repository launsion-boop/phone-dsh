// SPDX-License-Identifier: MIT
// Test-target-only symbol needed because the production BotWorkspaceModelImage
// resolves workspace images through the App's PreviewPathResolver. The eval
// test does not exercise image attachments; this shim keeps the production call
// shape compilable without pulling the entire App preview surface into the test
// target.
import Foundation

enum PreviewPathResolver {
    static func fileURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
