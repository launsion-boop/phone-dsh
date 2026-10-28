// SPDX-License-Identifier: MIT
import SwiftUI
import PhoneDSHShell
import PhoneDSHAgentCore

/// Phone presentation of the linked xz-shell accelerator registry. It never
/// accepts a shell command string; argv[0] must come from the linked caps.
struct PDSHShellPage: View {
    @State private var provider = PDSHShellProvider(
        materializedWorkspace: ChatModel.shared.workspaceRoot.appendingPathComponent("materialized/workspace", isDirectory: true),
        materializedHome: ChatModel.shared.workspaceRoot.appendingPathComponent("materialized/home", isDirectory: true))
    @State private var command = ""
    @State private var arguments = ""
    @State private var workingDirectory = "/dsh/workspace"
    @State private var output = ""
    @State private var error: String?
    @State private var runningID: String?

    private var commands: [String] { provider.acceleratorNames }

    var body: some View {
        List {
            Section("这台手机") {
                LabeledContent("状态", value: commands.isEmpty ? "未链接或未配置" : provider.capabilities.environment)
                LabeledContent("网络", value: "不可用")
                // 只报数量:英文目录名不上屏,认不出就写「未设置」。
                LabeledContent("工作区", value: provider.helloMounts.isEmpty
                               ? "未设置"
                               : "\(provider.helloMounts.count) 个文件夹")
                Text("这些命令在这台手机上跑,只能读不能写。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if commands.isEmpty {
                Section {
                    ContentUnavailableView("还没接上命令", systemImage: "terminal",
                        description: Text("先选一个工作文件夹,就会列出能用的命令。"))
                }
            } else {
                Section("运行命令") {
                    Picker("命令", selection: $command) {
                        ForEach(commands, id: \.self) { Text($0).tag($0) }
                    }
                    if ["phone", "ctx"].contains(command) {
                        Text("这个命令要连上 App 才能跑,现在跑不了。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    StrictASCIITextField("工作目录", text: $workingDirectory)
                        .accessibilityLabel("工作目录")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("参数,每行一个")
                            .font(.footnote).foregroundStyle(.secondary)
                        ZStack(alignment: .topLeading) {
                            StrictASCIITextView(text: $arguments)
                            if arguments.isEmpty {
                                Text("例如:--help\n文件名")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(height: 112)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary, lineWidth: 1))
                        .accessibilityLabel("参数,每行一个")
                    }
                    HStack {
                        Button("运行", systemImage: "play.fill") { Task { await run() } }
                            .disabled(runningID != nil || command.isEmpty || ["phone", "ctx"].contains(command))
                        if let runningID {
                            Button("取消", systemImage: "stop.fill", role: .destructive) {
                                Task { await provider.cancel(execID: runningID) }
                            }
                        }
                    }
                }
                Section("输出") {
                    if let error { Text(error).foregroundStyle(.red) }
                    Text(output.isEmpty ? "运行结果会显示在这里。" : output)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("限制") {
                    LabeledContent("超时", value: "\(provider.limits.timeoutMilliseconds / 1000) 秒")
                    LabeledContent("输出上限", value: ByteCountFormatter.string(fromByteCount: Int64(provider.limits.maxOutputBytes), countStyle: .file))
                    LabeledContent("文件数上限", value: "\(provider.limits.maxFiles)")
                    LabeledContent("单文件上限", value: ByteCountFormatter.string(fromByteCount: Int64(provider.limits.maxFileBytes), countStyle: .file))
                }
            }
        }
        .navigationTitle("命令")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if command.isEmpty { command = commands.first ?? "" } }
    }

    @MainActor
    private func run() async {
        guard commands.contains(command), runningID == nil else { return }
        let id = UUID().uuidString
        runningID = id
        output = ""
        error = nil
        let argv = [command] + arguments.split(whereSeparator: \.isNewline).map(String.init)
        let request = ExecRequest(execID: id, argv: argv, cwd: workingDirectory, deadline: Date().addingTimeInterval(Double(provider.limits.timeoutMilliseconds) / 1000))
        do {
            for try await event in provider.run(request) {
                switch event {
                case .stdout(_, let data): output += String(decoding: data, as: UTF8.self)
                case .stderr(_, let data): output += String(decoding: data, as: UTF8.self)
                case .exit(let code, let signal, let truncated):
                    output += "\n[结束：\(code.map(String.init) ?? "未知")\(signal.map { ", signal \($0)" } ?? "")\(truncated ? "，输出已截断" : "")]"
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        runningID = nil
    }
}
