// SPDX-License-Identifier: MIT
#if !canImport(UIKit)
import Foundation
import PhoneDSHBot

/// macOS-only production-assembly eval shim.
///
/// The App's `BotWorkspaceModelImage` bridge imports UIKit/Photos/PDFKit and
/// cannot compile on the macOS harness. The eval runner has no image
/// attachments, so this shim keeps the same call shape and fails closed
/// instead of silently returning a fake image. It is the only non-symlink
/// source in `Sources/BotEvalApp`; the composition test allows exactly this
/// file and requires the `#if !canImport(UIKit)` guard.
enum BotWorkspaceModelImage {
    static func image(for request: BotModelAttachmentRequest) async throws -> BotModelImage {
        throw NSError(
            domain: "BotEvalShim",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "image attachments are unavailable on the macOS eval harness"])
    }
}
#endif
