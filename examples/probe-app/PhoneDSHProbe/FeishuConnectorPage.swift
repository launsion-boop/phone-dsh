// SPDX-License-Identifier: MIT

import PhoneDSH
import SwiftUI

struct FeishuConnectorPage: View {
    private let client = TonoLiveFeishuClient()

    @State private var snapshot: TonoLiveFeishuClient.Snapshot?
    @State private var pending: Pending?
    @State private var signedIn = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var documentInput = ""
    @State private var documentText: String?
    @State private var accountGeneration = UUID()
    @State private var requestTask: Task<Void, Never>?

    private enum Mutation {
        case start(TonoLiveFeishuClient.Recipe, TonoLiveFeishuClient.AppChoice?)
        case update(TonoLiveFeishuClient.Attempt, TonoLiveFeishuClient.Action)
    }

    private struct Pending {
        let mutation: Mutation
        let key = UUID()
    }

    var body: some View {
        List {
            if let connection = snapshot?.readableConnection {
                documentSection(connection)
            } else if let attempt = activeAttempt {
                attemptSection(attempt)
            } else if let snapshot {
                setupSection(snapshot)
            } else if !signedIn {
                NavigationLink { TonoAccountPage() } label: {
                    Label(NativeText("登录 Tono 账号", "Sign in to Tono"), systemImage: "person.crop.circle")
                }
            }
            if busy { ProgressView() }
            if let errorText { Text(errorText).foregroundStyle(.secondary) }
            if pending != nil, !busy {
                Button(NativeText("检查操作结果", "Check operation result"), action: checkPending)
            }
            if signedIn {
                Button(NativeText("刷新连接状态", "Refresh connection"), action: reload)
                    .disabled(busy || pending != nil)
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("飞书", "Feishu"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            for await state in await TonoAccountSession.shared.states() {
                requestTask?.cancel()
                accountGeneration = UUID()
                snapshot = nil
                pending = nil
                documentText = nil
                documentInput = ""
                errorText = nil
                busy = false
                if case .signedIn = state {
                    signedIn = true
                    reload()
                } else {
                    signedIn = false
                }
            }
        }
    }

    private var activeAttempt: TonoLiveFeishuClient.Attempt? {
        guard let attempt = snapshot?.currentAttempt else { return nil }
        switch attempt.phase {
        case .registeringApp, .authorizingUser, .awaitingConfirmation, .uncertain: return attempt
        case .connected, .failed, .expired, .cancelled: return nil
        }
    }

    private func setupSection(_ snapshot: TonoLiveFeishuClient.Snapshot) -> some View {
        Section {
            ForEach(snapshot.approvedApps.filter(\.available)) { choice in
                Button(NativeText("使用 \(choice.name)", "Use \(choice.name)")) {
                    mutate(.start(snapshot.scopeRecipe, choice))
                }
            }
            Button(NativeText("创建飞书应用", "Create a Feishu app")) {
                mutate(.start(snapshot.scopeRecipe, nil))
            }
            .disabled(snapshot.connection?.credentialBackend == "managed")
            .accessibilityIdentifier("feishu.connect")
            DisclosureGroup(NativeText("查看飞书将请求的权限", "View requested Feishu permissions")) {
                Text(snapshot.scopeRecipe.requested.joined(separator: "\n"))
                    .font(.caption)
                    .textSelection(.enabled)
            }
        } header: {
            Text(NativeText("连接飞书", "Connect Feishu"))
        } footer: {
            Text(NativeText(
                "已有应用可以直接选用。首次连接时，按飞书提示确认创建应用和授权。",
                "Use an existing app or follow Feishu’s prompts to create one and authorize access."
            ))
        }
        .disabled(busy || pending != nil)
    }

    private func attemptSection(_ attempt: TonoLiveFeishuClient.Attempt) -> some View {
        Section {
            if let reader = attempt.readerIdentity, attempt.phase == .awaitingConfirmation {
                LabeledContent(NativeText("飞书账号", "Feishu account"), value: reader.userName)
                Button(NativeText("确认连接", "Confirm connection")) { mutate(.update(attempt, .confirm)) }
            } else if attempt.phase == .uncertain {
                if attempt.recovery.operationRef != nil {
                    Button(NativeText("检查授权结果", "Check authorization result")) {
                        mutate(.update(attempt, .recover))
                    }
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if context.date >= attempt.expiresAt {
                        Text(NativeText("授权链接已过期", "Authorization link expired"))
                    } else {
                        if let link = attempt.verificationLink {
                            Link(attempt.phase == .registeringApp
                                 ? NativeText("打开飞书确认创建", "Open Feishu to create the app")
                                 : NativeText("打开飞书授权", "Open Feishu to authorize"), destination: link)
                        }
                        Button(NativeText("我已确认，继续", "I’ve confirmed, continue")) {
                            mutate(.update(attempt, .advance))
                        }
                        .disabled(attempt.nextPollAt.map { context.date < $0 } ?? true)
                    }
                }
            }
            Button(NativeText("取消本次连接", "Cancel connection"), role: .destructive) {
                mutate(.update(attempt, .cancel))
            }
        }
        .disabled(busy || pending != nil)
    }

    private func documentSection(_ connection: TonoLiveFeishuClient.Connection) -> some View {
        Section {
            LabeledContent(NativeText("飞书账号", "Feishu account"), value: connection.accountName)
            TextField(NativeText("飞书文档链接或 ID", "Feishu document link or ID"), text: $documentInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: documentInput) { _, _ in documentText = nil }
            Button(NativeText("读取正文", "Read document")) {
                guard let id = TonoLiveFeishuClient.documentID(documentInput) else { return }
                documentText = nil
                run {
                    let text = try await client.read(id, connection: connection)
                    try Task.checkCancellation()
                    if TonoLiveFeishuClient.documentID(documentInput) == id { documentText = text }
                }
            }
            .accessibilityIdentifier("feishu.read")
            .disabled(busy || pending != nil || TonoLiveFeishuClient.documentID(documentInput) == nil)
            if let documentText {
                Text(documentText.isEmpty ? NativeText("文档正文为空", "The document is empty") : documentText)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("feishu.document.body")
            }
        }
    }

    private func reload() {
        documentText = nil
        run {
            let next = try await client.snapshot()
            try Task.checkCancellation()
            snapshot = next
        }
    }

    private func mutate(_ mutation: Mutation) {
        let operation = Pending(mutation: mutation)
        pending = operation
        submit(operation)
    }

    private func submit(_ operation: Pending) {
        run { try await apply(operation) }
    }

    private func checkPending() {
        guard let operation = pending else { return }
        run {
            do {
                let next = try await client.recover(key: operation.key)
                try Task.checkCancellation()
                snapshot = next
                pending = nil
            } catch TonoLiveFeishuClient.Failure.rejected(404) {
                try await apply(operation)
            }
        }
    }

    private func apply(_ operation: Pending) async throws {
        let next: TonoLiveFeishuClient.Snapshot
        switch operation.mutation {
        case .start(let recipe, let choice):
            next = try await client.start(recipe: recipe, choice: choice, key: operation.key)
        case .update(let attempt, let action):
            next = try await client.update(attempt, action: action, key: operation.key)
        }
        try Task.checkCancellation()
        snapshot = next
        pending = nil
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorText = nil
        let generation = accountGeneration
        requestTask = Task { @MainActor in
            defer { if accountGeneration == generation { busy = false } }
            do { try await operation() }
            catch {
                guard accountGeneration == generation else { return }
                if case TonoLiveFeishuClient.Failure.rejected(let status) = error,
                   [400, 401, 403, 409, 422].contains(status) {
                    pending = nil
                    errorText = NativeText("飞书连接请求未通过（\(status)）。请刷新连接状态或检查账号权限。",
                                           "Feishu connection request was rejected (\(status)). Refresh the connection or check account access.")
                } else {
                    errorText = NativeText("暂时无法完成飞书请求，请重试。", "Could not complete the Feishu request. Try again.")
                }
            }
        }
    }
}
