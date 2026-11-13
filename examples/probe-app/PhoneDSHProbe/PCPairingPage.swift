// SPDX-License-Identifier: MIT
// PC pairing page (P09, pclink-qr-approval). One screen: one install command,
// one scan action, the other entries folded away, and one permission line. The
// phone's scan/code entry is the approval (v1.6); there is no fingerprint card
// and no "type this fingerprint on the PC" copy. The fingerprint lives on
// 我的 › 已连接的电脑 for verification.

import AVFoundation
import PhoneDSHPCLink
import ProbeKit
import SwiftUI
import UIKit

struct PCPairingPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.workspaceModels) private var models
    @Environment(\.dismiss) private var dismiss

    @State private var flow: PCPairingFlow?
    @State private var pasteURI = ""
    @State private var manualCode = ""
    @State private var showScanner = false
    @State private var showOther = false
    @State private var cameraDenied = false
    @State private var interrupted = false
    @State private var showOldPCHint = false
    @State private var autoEnteredWorkspace = false

    private var state: PCPairingPageState { flow?.state ?? .idle }

    var body: some View {
        List {
            switch state {
            case .idle, .joining:
                installSection
                scanSection
                otherSection
                if case .joining = state { joiningSection }
                permissionSection
            case .connecting(let prompt):
                connectingSection(prompt)
                if interrupted { interruptionNotice }
                permissionSection
            case .paired(let record):
                pairedSection(record)
            case .failed(let message):
                failureSection(message)
                permissionSection
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
            #if DEBUG
            await runDebugPairingIfRequested()
            #endif
        }
        .onChange(of: models.pcLink.status) { _, status in
            flow?.sync(clientStatus: status)
        }
        .onChange(of: flow?.state) { _, state in
            if case .paired = state { enterPCWorkspace() }
        }
        .onChange(of: appModel.isSceneActive) { _, active in
            // Lock/background during the hand-off drops the relay socket on a
            // real device. Keep the page open and say so instead of spinning.
            // The app entry owns the scene-phase observer; this page only reads
            // its UI-only `isSceneActive` projection.
            if !active, state.isBusy { interrupted = true }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PCPairingScannerView { code in
                    showScanner = false
                    pasteURI = code
                    startQR(code)
                }
                .navigationTitle("扫码连接")
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
    /// Unattended simulator E2E: paste the URI through the same production
    /// flow. The flow auto-submits `pair.auth`; there is no approval button.
    private func runDebugPairingIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        if let uri = env["PDSH_PCLINK_PAIR_URI"],
           !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           flow?.state == .idle {
            pasteURI = uri
            await flow?.begin(qrURI: uri)
        }
        if env["PDSH_PCLINK_AUTOCLOSE_PAIRING"] == "1", case .paired = flow?.state {
            try? await Task.sleep(for: .milliseconds(1500))
            dismiss()
        }
    }
    #endif

    // MARK: Sections

    private var installSection: some View {
        Section {
            Text("在电脑终端运行：")
                .font(.system(size: HomeSpec.bodySize))
                .foregroundStyle(HomeSpec.textPrimary)
            PCInstallCommandCard()
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                openScanner()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18, weight: .semibold))
                    Text("扫码连接")
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(HomeSpec.primaryButtonInk)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(HomeSpec.primaryButton, in: Capsule())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            Text("扫描终端里出现的二维码")
                .font(.system(size: 13))
                .foregroundStyle(HomeSpec.textSecondary)
            if cameraDenied {
                Text("相机不可用或未授权。请允许相机，或使用「其他方式」。")
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var otherSection: some View {
        Section {
            Button(showOther ? "收起其他方式" : "其他方式") {
                withAnimation(.easeOut(duration: 0.18)) { showOther.toggle() }
            }
            .frame(minHeight: 44)
            if showOther {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("pclink://pair?…", text: $pasteURI, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(1...3)
                        .accessibilityLabel("配对链接")
                    Button("用链接配对") { startQR(pasteURI) }
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                        .frame(minHeight: 44)
                        .disabled(pasteURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $manualCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 18, design: .monospaced))
                        .onChange(of: manualCode) { _, value in
                            manualCode = Self.formatManualCode(value)
                        }
                        .accessibilityLabel("配对码")
                    Text("16 位，单次使用，5 分钟内有效。")
                        .font(.system(size: 12))
                        .foregroundStyle(HomeSpec.textSecondary)
                    Button("手动连接") { startManual() }
                        .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                        .frame(minHeight: 44)
                        .disabled(manualCode.count != 19)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var permissionSection: some View {
        Section {
            Text(PCLinkPairingPrompt.fullOwnerWarning)
                .font(.system(size: 13))
                .foregroundStyle(HomeSpec.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var joiningSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text("正在连接电脑…")
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            .frame(minHeight: 44)
            Button("取消配对") { Task { await flow?.cancel() } }
                .foregroundStyle(.red)
        }
    }

    private func connectingSection(_ prompt: PCPairingApproval) -> some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(PCLinkWorkspaceText.pairingConnecting(prompt.pcName))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HomeSpec.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 48)
            if showOldPCHint {
                Text(PCLinkWorkspaceText.pairingOldPCConfirm)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("取消配对") { Task { await flow?.cancel() } }
                .foregroundStyle(.red)
                .frame(minHeight: 44)
        }
        .task(id: prompt.id) {
            // A v1.6 PC confirms in one round trip. Only an old PC can still be
            // waiting for its own operator; say so without mentioning a
            // fingerprint and without blocking the success path.
            try? await Task.sleep(for: .seconds(3))
            if case .connecting = state { showOldPCHint = true }
        }
    }

    private var interruptionNotice: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NativePagePalette.warning)
                Text(PCLinkWorkspaceText.pairingInterrupted)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pairedSection(_ record: PCLinkPairingRecord) -> some View {
        Section {
            Label("已连接 \(record.peerName)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HomeSpec.success)
            Button("完成") { dismiss() }
                .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                .frame(minHeight: 48)
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(NativePagePalette.danger)
                .fixedSize(horizontal: false, vertical: true)
            if interrupted, message != PCLinkWorkspaceText.pairingInterrupted {
                Text(PCLinkWorkspaceText.pairingInterrupted)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("重试") {
                interrupted = false
                showOldPCHint = false
                flow?.reset()
                openScanner()
            }
            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
            .frame(minHeight: 44)
        }
    }

    // MARK: Actions

    private func openScanner() {
        guard AVCaptureDevice.default(for: .video) != nil else {
            cameraDenied = true
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
        interrupted = false
        showOldPCHint = false
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
        interrupted = false
        showOldPCHint = false
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
                                       description: Text("模拟器或这台设备没有相机。请返回并使用「其他方式」。"))
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
