// SPDX-License-Identifier: MIT

import Observation
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class ConnectorConfigurationModel {
    var githubPAT = ""
    var githubRepositories = ""
    private(set) var isConnecting = false
    private(set) var errorMessage: String?

    private let composition: AppComposition

    init(composition: AppComposition = .shared) {
        self.composition = composition
    }

    func connectGitHub() async {
        await perform {
            try await composition.connectGitHub(
                pat: githubPAT.trimmingCharacters(in: .whitespacesAndNewlines),
                repositories: githubRepositories.components(separatedBy: CharacterSet(charactersIn: ",，\n")))
            githubPAT = ""
        }
    }

    func connectGmail() async {
        await perform { try await composition.connectGmail() }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await action()
        } catch let error as GitHubClientError {
            errorMessage = error.message
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
        Group {
            SecureField(NativeText("Personal Access Token", "Personal Access Token"), text: $model.githubPAT)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("connector.github.pat")
            TextField(NativeText("授权仓库，逗号分隔，例如 owner/repo", "Repositories, comma separated, for example owner/repo"),
                      text: $model.githubRepositories, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("connector.github.repositories")
            Button(NativeText("验证并连接 GitHub", "Verify and connect GitHub")) {
                Task { await model.connectGitHub() }
            }
            .disabled(model.isConnecting || model.githubPAT.isEmpty || model.githubRepositories.isEmpty)
            .accessibilityIdentifier("connector.github.connect")
        }
    }

    private var gmail: some View {
        Button(NativeText("使用 Google 账号连接", "Connect with Google")) {
            Task { await model.connectGmail() }
        }
        .disabled(model.isConnecting)
        .accessibilityIdentifier("connector.gmail.connect")
    }
}
