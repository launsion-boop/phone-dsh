// SPDX-License-Identifier: MIT

import Observation
import ProbeKit
import SwiftUI

@MainActor
@Observable
final class ConnectorConfigurationModel {
    let githubModel: GitHubConnectorModel
    var followUpRepository = ""
    var followUpPRNumber = ""
    private(set) var isConnecting = false
    private(set) var errorMessage: String?

    private let composition: AppComposition

    init(composition: AppComposition = .shared) {
        self.composition = composition
        githubModel = GitHubConnectorModel(registry: composition.registry, client: composition.githubClient,
                                           credentials: composition.credentials)
    }

    func connectGmail() async {
        await perform { try await composition.connectGmail() }
    }

    func createGitHubFollowUp() async {
        await perform {
            let repository = followUpRepository.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Int(followUpPRNumber), number > 0,
                  await composition.registry.state(of: "github").state == .connected,
                  let grant = await composition.registry.grant(of: "github"),
                  grant.allowedActions.contains(.read),
                  grant.scope.repositories.contains(where: { $0.lowercased() == repository.lowercased() }) else {
                throw ConnectorRegistryError.verificationFailed("请输入已授权仓库和有效的 PR 编号")
            }
            let existing = try await composition.followUps.records()
            guard !existing.contains(where: {
                $0.followUp.target.repository?.lowercased() == repository.lowercased() &&
                $0.followUp.target.number == number
            }) else {
                throw ConnectorRegistryError.verificationFailed("这个 PR 已在跟进中")
            }
            let followUp = FollowUp(
                goal: "跟进 \(repository)#\(number)，只报告新增阻塞",
                target: FollowUpTarget(kind: .githubPR, repository: repository, number: number),
                waitingReason: "等待新的 review 或 Checks 阻塞",
                nextCheckCondition: CheckCondition(expression: "new_blockers"),
                stopCondition: StopCondition(expression: "manual"),
                validUntil: Date().addingTimeInterval(7 * 86_400))
            _ = try await composition.followUps.create(followUp)
            _ = try await composition.requestNotificationAuthorization()
            _ = try await composition.followUpCoordinator.checkAll()
            await composition.personalModel.foreground()
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await action()
        } catch let error as ConnectorRegistryError {
            if case .verificationFailed(let message) = error { errorMessage = message }
            else { errorMessage = error.localizedDescription }
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
            GitHubConnectorConfigurationSection(model: model.githubModel)
            Section(NativeText("持续跟进 PR", "Follow a pull request")) {
                TextField("owner/repo", text: $model.followUpRepository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(NativeText("PR 编号", "PR number"), text: $model.followUpPRNumber)
                    .keyboardType(.numberPad)
                Button(NativeText("只告诉我新增阻塞", "Notify me only about new blockers")) {
                    Task { await model.createGitHubFollowUp() }
                }
                .disabled(model.isConnecting || model.followUpRepository.isEmpty || model.followUpPRNumber.isEmpty)
                Text(NativeText("打开 App 或回到前台时核验；没有新增阻塞就保持安静。", "Checks when the app opens or returns to the foreground; stays quiet without new blockers."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
