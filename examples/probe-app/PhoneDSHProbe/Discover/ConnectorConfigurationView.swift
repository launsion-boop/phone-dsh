// SPDX-License-Identifier: MIT

import Observation
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class ConnectorConfigurationModel {
    let githubModel: GitHubConnectorModel
    private(set) var isConnecting = false
    private(set) var errorMessage: String?

    private let composition: AppComposition

    init(composition: AppComposition = .shared) {
        self.composition = composition
        githubModel = GitHubConnectorModel(registry: composition.registry, client: composition.githubClient,
                                           credentials: composition.credentials)
    }

    func connectGmail() async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await composition.connectGmail()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ConnectorConfigurationView: View {
    let connectorID: String
    @Bindable var model: ConnectorConfigurationModel

    var body: some View {
        Group {
            switch connectorID {
            case "github": github
            case "gmail": gmail
            default: EmptyView()
            }
            if model.isConnecting { ProgressView().controlSize(.small) }
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(NativeParityTokens.warning)
                    .accessibilityIdentifier("connector.configuration.error")
            }
        }
    }

    private var github: some View {
        GitHubConnectorConfigurationSection(model: model.githubModel)
    }

    private var gmail: some View {
        Button(NativeText("使用 Google 账号连接", "Connect with Google")) {
            Task { await model.connectGmail() }
        }
        .disabled(model.isConnecting)
        .accessibilityIdentifier("connector.gmail.connect")
    }
}
