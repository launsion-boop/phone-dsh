// SPDX-License-Identifier: MIT
// PC pairing page (D2). Camera scan is the preferred path; a paste field is
// always available (DEBUG and release) for the simulator and camera-less
// setups, and the manual 16-character code uses the default relay origin.
// The page shows this phone's own 12-character fingerprint and the §4.6
// full-owner warning before the explicit confirmation.

import AVFoundation
import PhoneDSHPCLink
import ProbeKit
import SwiftUI
import UIKit

struct PCPairingPage: View {
    @Environment(\.workspaceModels) private var models
    @Environment(\.dismiss) private var dismiss

    @State private var flow: PCPairingFlow?
    @State private var pasteURI = ""
    @State private var manualCode = ""
    @State private var showScanner = false
    @State private var showManual = false
    @State private var cameraDenied = false
    @State private var localError: String?
    @State private var autoEnteredWorkspace = false

    private var state: PCPairingPageState { flow?.state ?? .idle }
    private var fingerprint: String {
        let own = flow?.state.prompt?.ownFingerprint ?? models.pcLink.ownFingerprint
        return own.isEmpty ? "读取中…" : own
    }

    var body: some View {
        List {
            pluginInstallSection
            fingerprintSection
            if case .awaitingApproval(let prompt) = state {
                approvalSection(prompt)
            } else if case .paired(let record) = state {
                pairedSection(record)
            } else if case .failed(let message) = state {
                failureSection(message)
            } else if state.isBusy {
                busySection
            } else {
                scanSection
                manualSection
                warningSection
            }
        }
        .homeGroupedList()
        .navigationTitle("连接电脑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    if flow?.state.isBusy == true { Task { await flow?.cancel() } }
                    dismiss()
                }
            }
        }
        .task {
            if flow == nil { flow = PCPairingFlow(client: models.pcLink.client) }
            // Load/create the phone identity so the fingerprint is available
            // before the PC's approval prompt.
            if models.pcLink.ownFingerprint.isEmpty {
                await models.pcLink.retry()
            }
            #if DEBUG
            await runDebugPairingIfRequested()
            #endif
        }
        .onChange(of: models.pcLink.status) { _, status in
            flow?.sync(clientStatus: status)
        }
        .onChange(of: flow?.state) { _, state in
            // Pairing completion is driven by the client's pairing update
            // stream after the authenticated pair.confirm. Enter the PC
            // workspace automatically; the approval button remains the
            // explicit consent / timeout-retry entry.
            if case .paired = state { enterPCWorkspace() }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PCPairingScannerView { code in
                    showScanner = false
                    pasteURI = code
                    startQR(code)
                }
                .navigationTitle("扫码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showScanner = false }
                    }
                }
            }
        }
    }

    #if DEBUG
    /// Unattended simulator E2E: paste the pairing URI through the same
    /// `PCPairingFlow` the text field uses, then optionally perform the explicit
    /// confirm after a delay long enough for a reviewer to capture the
    /// compared-fingerprint state. Never compiled into release.
    private func runDebugPairingIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        if let uri = env["PDSH_PCLINK_PAIR_URI"],
           !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           flow?.state == .idle {
            pasteURI = uri
            await flow?.begin(qrURI: uri)
        }
        if env["PDSH_PCLINK_AUTOCONFIRM"] == "1" {
            let milliseconds = Int(env["PDSH_PCLINK_AUTOCONFIRM_DELAY_MS"] ?? "") ?? 2000
            try? await Task.sleep(for: .milliseconds(max(0, milliseconds)))
            if case .awaitingApproval = flow?.state {
                await flow?.confirm()
            }
        }
        if env["PDSH_PCLINK_AUTOCLOSE_PAIRING"] == "1", case .paired = flow?.state {
            try? await Task.sleep(for: .milliseconds(1500))
            dismiss()
        }
    }
    #endif

    // MARK: Sections

    /// pclink-pacing: the same copyable install/pairing guide as the drawer
    /// empty state. The command text has one owner in ProbeKit next to the
    /// relay-origin configuration.
    private var pluginInstallSection: some View {
        Section {
            PCPluginInstallGuide()
                .listRowInsets(EdgeInsets(top: 10, leading: 16,
                                          bottom: 10, trailing: 16))
        } header: {
            Text(PCLinkInstallGuide.title)
        } footer: {
            Text("在电脑终端运行上面的命令，按提示用手机扫码。脚本会检查环境、安装插件、加载 dsh web 并显示配对二维码。")
        }
    }

    private var fingerprintSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("本机指纹")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                Text(fingerprint)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .textSelection(.enabled)
                Text("在电脑上输入这串指纹来批准配对。电脑只会显示手机名称，不会显示指纹。")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                openScanner()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                    Text("扫码配对")
                        .font(.system(size: HomeSpec.bodySize, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HomeSpec.textPlaceholder)
                }
                .frame(minHeight: 48)
            }
            if cameraDenied {
                Text("相机不可用或未授权。请在系统设置里允许相机，或使用下面的粘贴链接/手动输码。")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("粘贴配对链接")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                TextField("pclink://pair?…", text: $pasteURI, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(2...4)
                    .accessibilityLabel("配对链接")
                Button("用链接配对") { startQR(pasteURI) }
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .frame(minHeight: 44)
                    .disabled(pasteURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.vertical, 4)
        } header: {
            Text("扫码或链接")
        } footer: {
            if let localError {
                Text(localError).foregroundStyle(NativePagePalette.danger)
            }
        }
    }

    private var manualSection: some View {
        Section {
            Button(showManual ? "收起手动输码" : "手动输入配对码") {
                withAnimation(.easeOut(duration: 0.18)) { showManual.toggle() }
            }
            .frame(minHeight: 44)
            if showManual {
                TextField("XXXX-XXXX-XXXX-XXXX", text: $manualCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 18, design: .monospaced))
                    .onChange(of: manualCode) { _, value in
                        manualCode = Self.formatManualCode(value)
                    }
                    .accessibilityLabel("配对码")
                Text("16 位，单次使用，5 分钟内有效。使用默认中继地址 \(PCLinkRelayConfiguration.manualPairingOrigin)。")
                    .font(.system(size: 12))
                    .foregroundStyle(HomeSpec.textSecondary)
                Button("手动配对") { startManual() }
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .frame(minHeight: 44)
                    .disabled(manualCode.count != 19)
            }
        } header: {
            Text("手动配对码")
        } footer: {
            Text("电脑上没有相机或扫码不可用时使用。")
        }
    }

    private var warningSection: some View {
        Section {
            Text(PCLinkPairingPrompt.fullOwnerWarning)
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("配对后")
        } footer: {
            Text("电脑会要求本机操作员核对上面的指纹；指纹不符时配对被作废。")
        }
    }

    private var busySection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(state.isBusy ? "正在连接中继并等待电脑…" : "")
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            .frame(minHeight: 48)
            Button("取消配对") { Task { await flow?.cancel() } }
                .foregroundStyle(.red)
        }
    }

    private func approvalSection(_ prompt: PCPairingApproval) -> some View {
        Section {
            Text("已找到电脑：\(prompt.pcName)")
                .font(.system(size: 16, weight: .semibold))
            Text("请在电脑上输入本机指纹批准：\(prompt.ownFingerprint)")
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt.warningText)
                .font(.system(size: 14))
                .foregroundStyle(HomeSpec.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button("我已批准，继续配对") {
                Task { await flow?.confirm() }
            }
            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
            .frame(minHeight: 48)
            Button("取消配对") { Task { await flow?.cancel() } }
                .foregroundStyle(.red)
                .frame(minHeight: 44)
        } header: {
            Text("等待电脑批准")
        } footer: {
            Text("点一次即提交。电脑批准后会自动完成配对并进入 PC 工作区；超过时限或失败时，这里保留为重新提交的兜底入口。")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pairedSection(_ record: PCLinkPairingRecord) -> some View {
        Section {
            Label("已连接 \(record.peerName)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HomeSpec.success)
            Text("电脑指纹 \(record.fingerprint)")
                .font(.system(size: 13))
                .foregroundStyle(HomeSpec.textSecondary)
            Button("完成") { dismiss() }
                .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                .frame(minHeight: 48)
        } footer: {
            Text("现在可以切到「PC」分段查看电脑上的会话。")
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(NativePagePalette.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新开始") {
                localError = nil
                flow?.reset()
            }
            .frame(minHeight: 44)
        } header: {
            Text("配对没有完成")
        } footer: {
            Text("超时、电脑拒绝、指纹不符或配对槽被销毁都会停在这里。重新开始会打开一次新的配对。")
        }
    }

    // MARK: Actions

    private func openScanner() {
        guard AVCaptureDevice.default(for: .video) != nil else {
            cameraDenied = true
            localError = "这台设备没有可用相机，请粘贴配对链接或手动输入配对码。"
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                if granted { showScanner = true } else { cameraDenied = true }
            }
        }
    }

    private func startQR(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        localError = nil
        Task { await flow?.begin(qrURI: code) }
    }

    /// Completion leaves the sheet and selects the PC segment; the record is
    /// already durable when `.paired` appears.
    private func enterPCWorkspace() {
        guard !autoEnteredWorkspace else { return }
        autoEnteredWorkspace = true
        models.select(.pc)
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        }
    }

    private func startManual() {
        localError = nil
        let code = manualCode
        Task {
            await flow?.beginManual(code: code,
                                    relayOrigin: PCLinkRelayConfiguration.manualPairingOrigin)
        }
    }

    /// `XXXX-XXXX-XXXX-XXXX` while typing; the decoder also accepts no
    /// separators, spaces and letter case (PCLink §4.5).
    static func formatManualCode(_ raw: String) -> String {
        PCLinkManualCodeInput.format(raw)
    }
}

// MARK: - Camera

private struct PCPairingScannerView: View {
    let onCode: (String) -> Void

    var body: some View {
        Group {
            if AVCaptureDevice.default(for: .video) == nil {
                ContentUnavailableView("没有可用相机",
                                       systemImage: "camera",
                                       description: Text("模拟器或这台设备没有相机。请返回并使用粘贴配对链接或手动输入配对码。"))
            } else {
                CameraScannerRepresentable(onCode: onCode)
                    .ignoresSafeArea()
            }
        }
    }
}

private struct CameraScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerController {
        let controller = CameraScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraScannerController, context: Context) {}
}

private final class CameraScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        delivered = true
        onCode?(value)
    }
}
