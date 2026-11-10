// SPDX-License-Identifier: MIT
import SwiftUI
import PhoneDSHVenus

struct VisionSettingsPage: View {
    @State private var baseURL = ""
    @State private var key = ""
    @State private var model = "ui-venus-2-9b"
    @State private var models: [String] = []
    @State private var status = ""
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                TextField("HTTPS OpenAI Base URL", text: $baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("此服务的 API Key（留空保留）", text: $key).textInputAutocapitalization(.never)
                Picker("视觉模型", selection: $model) {
                    ForEach(models.isEmpty ? VisionModels.supported : models, id: \.self) { id in
                        Text(id + (VisionModels.isOCR(id) ? " · OCR" : "")).tag(id)
                    }
                }.accessibilityIdentifier("vision.model")
                Button("保存") { save() }.disabled(busy).accessibilityIdentifier("vision.save")
                Button(busy ? "正在检查…" : "检查服务与模型列表") { check() }.disabled(busy).accessibilityIdentifier("vision.check")
            } header: { Text("视觉服务") } footer: {
                Text("这是 Android 截图分析与操作规划服务。聊天模型保持独立；MiniCPM 用于 OCR。密钥仅保存在 iPhone 钥匙串中。")
            }
            if !status.isEmpty { Section("状态") { Text(status).textSelection(.enabled).accessibilityIdentifier("vision.status") } }
            Section("使用") {
                Text("可以说：用 UI-Venus 查看 Android 屏幕，帮我完成某项操作；或用 Qwen 识别屏幕。")
                Text("每次观察只发送当前一张截图。动作执行前重新核对屏幕和目标，变化后重新观察。冷启动可能需要等待，最长 600 秒，不自动重复请求或操作。")
            }
        }.navigationTitle("视觉模型").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let saved = VenusSettings.shared.load(); baseURL = saved.baseURL; model = saved.model
        }
        .onDisappear { task?.cancel() }
    }
    private func save() {
        do {
            try VenusSettings.shared.save(VenusConfiguration(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), model: model), key: key.isEmpty ? nil : key)
            key = ""; status = "已保存。新视觉请求立即使用所选模型。"
        } catch { status = error.localizedDescription }
    }
    private func check() {
        save()
        guard status.hasPrefix("已保存") else { return }
        busy = true
        task = Task {
            defer { busy = false }
            do {
                let found = try await VenusClient().models()
                guard found.contains(model) else { status = "模型目录中没有所选模型，请重新选择。"; models = found; return }
                models = found; status = "服务已连接，\(found.count) 个可选模型。\n" + found.joined(separator: "\n")
            } catch is CancellationError { }
            catch { status = error.localizedDescription }
        }
    }
}
