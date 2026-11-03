// SPDX-License-Identifier: MIT

import ProbeKit
import QuickLook
import SwiftUI

struct PersonalAgentArtifactPreview: View {
    let artifactID: String
    @State private var url: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let url {
                PersonalAgentQuickLook(url: url)
                    .frame(minHeight: 320)
            } else if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(HomeSpec.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task {
            do { url = try await OfficeArtifactStore.shared.fileURL(for: artifactID) }
            catch { errorMessage = "产物不可用：\(error.localizedDescription)" }
        }
    }
}

private struct PersonalAgentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
