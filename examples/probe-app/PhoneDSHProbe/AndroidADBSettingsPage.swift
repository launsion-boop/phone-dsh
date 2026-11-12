// SPDX-License-Identifier: MIT
import SwiftUI
import PhoneDSHADB

struct AndroidADBSettingsPage: View {
    @State private var enabled = false
    @State private var host = ""
    @State private var port = "5555"
    @State private var status = ""
    @State private var busy = false
    @State private var failed = false

    // Discovery state. One foreground scan and one connection attempt at a time
    // keep the disabled-button rules and the per-row progress unambiguous.
    @State private var candidates: [TVCandidate] = []
    @State private var scanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scanGeneration = 0
    @State private var connectionPhases: [String: TVConnectPhase] = [:]
    @State private var connectingID: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionGeneration = 0

    var body: some View {
        Form {
            Section {
                Button(NativeText("扫描局域网", "Scan local network")) { scan() }
                    .disabled(scanning || busy || connectingID != nil)
                if scanning {
                    Text(NativeText("正在查找局域网里的电视…", "Looking for TVs on your local network…"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !scanning && candidates.isEmpty {
                    Text(NativeText("尚未发现电视。确认电视和这台 iPhone 连接同一 Wi-Fi，并在电视上开启网络调试；也可以手动添加地址。", "No TVs discovered yet. Make sure the TV and this iPhone share the same Wi-Fi and the TV allows network debugging, or add its address manually."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(sortedCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.displayName).font(.headline)
                        // `Text("... \(Int) ...")` is a LocalizedStringKey: the port
                        // renders with the locale's grouping separator (5,555). An
                        // endpoint is not a number to localize, so keep it verbatim.
                        Text(verbatim: "\(candidate.host):\(candidate.port) · \(tvKindLabel(candidate.kind)) · \(tvControlLabel(candidate))")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let phase = connectionPhases[candidate.id] {
                            if case .probing = phase {
                                Text(NativeText("正在连接…", "Connecting…")).font(.footnote)
                            } else if case .awaitingAuthorization(let elapsed) = phase {
                                Text(NativeText("请在电视上点“允许”…（已等待 \(tvElapsedSeconds(elapsed)) 秒）", "Tap “Allow” on the TV… (waiting \(tvElapsedSeconds(elapsed)) s)"))
                                    .font(.footnote)
                            } else if case .connected(let model) = phase {
                                Text(NativeText("已连接：\(model)", "Connected: \(model)")).font(.footnote)
                            } else if case .failed(_, let message) = phase {
                                Text(message).font(.footnote).foregroundStyle(.red)
                            }
                        }
                        HStack {
                            Button(NativeText("连接", "Connect")) { connect(candidate) }
                                .disabled(scanning || busy || connectingID != nil)
                            if isConnectionInProgress(candidate) {
                                Button(NativeText("取消", "Cancel"), role: .cancel) { cancelConnection() }
                            }
                        }
                    }
                }
            } header: {
                Text(NativeText("发现的电视", "Discovered TVs"))
            } footer: {
                Text(NativeText("只扫描这台 iPhone 当前 Wi-Fi 的局域网。开放端口只说明“像电视”，不代表已授权；连接后需要在电视上确认调试授权，等待授权时请保持此页打开。手动添加仍在下方可用。", "Only this iPhone's current Wi-Fi network is scanned. An open port suggests a TV but does not prove it; the TV must confirm debugging authorization after you connect, so keep this page open while waiting. Manual setup remains available below."))
            }
            Section {
                Toggle("允许控制 Android", isOn: $enabled)
                TextField("Android IP 地址或主机名", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("ADB 端口", text: $port).keyboardType(.numberPad)
                // A discovery connection owns the ADB slot too; keep the manual
                // form from starting a second connection while it runs.
                Button("保存") { save() }.disabled(busy || connectingID != nil)
                Button(busy ? "正在连接…" : "测试连接") { check() }
                    .disabled(busy || !enabled || connectingID != nil)
                Button("停止当前 Android 操作", role: .cancel) {
                    // Same scope as the Android host: the label means the whole
                    // Android operation, including a discovery connection or scan.
                    cancelTasks()
                    Task { await ADBMCPServer.shared.cancel() }
                }
            } header: {
                Text(NativeText("手动添加（高级）", "Manual setup (advanced)"))
            } footer: {
                Text("可直接告诉模型“连接 Android 地址和端口”，由模型启用控制并保存连接，无需手动填写。保存后立即生效。模型可控制屏幕、查询和管理应用、安装或卸载 APK、读取日志和执行 Android shell。首次连接请解锁 Android，并允许这台 iPhone 的调试密钥。")
            }
            if !status.isEmpty {
                Section("连接状态") {
                    Text(status).foregroundStyle(failed ? .red : .primary).textSelection(.enabled)
                }
            }
            Section("连接准备") {
                Text("两台手机连接同一局域网，在 Android 上开启开发者选项和 USB 调试。")
                Text("当前支持 TCP/IP ADB。首次可用电脑通过 USB 执行 adb tcpip 5555，再填入 Android 的 IP 地址。部分设备可直接开启网络 ADB；设备重启后可能需要重新开启。")
                Text("Android 11+「无线调试」里的六位配对码和 TLS 端口暂不支持。这里填写 TCP/IP ADB 端口，通常为 5555。")
                Text("文本输入支持可打印 ASCII。中文等 Unicode 输入需要 Android 输入法支持，当前会明确报错。")
            }
            Section("应用与 APK") {
                Text("可以说：列出 Android 上的第三方应用；查看某个应用的版本和权限；安装工作区里的 APK；卸载指定包名的应用。")
                Text("支持工作区或 Android 本机上的单个 APK。工作区安装上限 128 MiB；暂不支持 AAB、XAPK、APKS 和拆分 APK 组合。")
                Text("卸载应用和删除下载的 APK 文件是两种操作。应用管理默认作用于 Android 当前用户；清除应用数据会删除登录状态和本地数据。")
            }
        }
        .navigationTitle("Android ADB")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let saved = ADBSettings.shared.load()
            enabled = saved.enabled; host = saved.host; port = String(saved.port)
            // With no manually saved target, start from the last endpoint this
            // iPhone actually controlled instead of an empty form.
            if saved.host.isEmpty, let last = TVDeviceDirectory.shared.lastEndpoint() {
                host = last.host; port = String(last.port)
            }
            if candidates.isEmpty { candidates = rememberedCandidates() }
            // Foolproof default: a fresh install starts with control enabled.
            // A saved target (non-empty host) keeps the person's explicit
            // on/off choice; nothing is granted until 保存 / a successful
            // connection, so this only removes one tap from the draft.
            if saved.host.isEmpty, host.isEmpty { enabled = true }
            // Foolproof default: opening the page starts one foreground scan
            // (and triggers iOS's one-time local-network prompt) instead of
            // waiting for another tap. The button remains for a manual
            // refresh; scan() itself refuses while a scan/connection runs.
            if !scanning, connectingID == nil { scan() }
        }
        .onDisappear { cancelTasks() }
    }

    // MARK: - Discovery

    private var sortedCandidates: [TVCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.host < rhs.host
        }
    }

    private func rememberedCandidates() -> [TVCandidate] {
        TVDeviceDirectory.shared.records().map { record in
            let model = record.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return TVCandidate(id: "\(record.host):\(record.port)",
                               host: record.host,
                               port: record.port,
                               displayName: model.isEmpty ? "Android TV · \(record.host)" : model,
                               kind: .androidTV,
                               evidence: [.remembered(record.serial)],
                               score: 70,
                               authorization: .granted)
        }
    }

    private func scan() {
        guard !scanning, !busy, connectingID == nil else { return }
        let known = rememberedCandidates()
        scanning = true
        if candidates.isEmpty { candidates = known }
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            let engine = TVDiscoveryEngine()
            var found = await engine.scan(hosts: tvLocalSubnetHosts(), remembered: known)
            // A newer scan or a disappearing page owns the state now.
            guard !Task.isCancelled, scanGeneration == generation else {
                if scanGeneration == generation {
                    scanning = false; scanTask = nil
                }
                return
            }
            found.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
                return lhs.host < rhs.host
            }
            candidates = found
            scanning = false
            scanTask = nil
        }
    }

    private func tvKindLabel(_ kind: TVCandidate.Kind) -> String {
        switch kind {
        case .androidTV: return "Android TV"
        case .cast: return "Google Cast"
        case .airplay: return "AirPlay"
        case .roku: return "Roku"
        case .smartTV: return NativeText("智能电视", "Smart TV")
        case .unknown: return NativeText("未知类型", "Unknown type")
        }
    }

    private func tvControlLabel(_ candidate: TVCandidate) -> String {
        // An open port is evidence, not permission: only a successful
        // connection may print 可控制. A refused/absent authorization prints
        // 需要授权 so the row no longer contradicts the footer.
        switch candidate.authorization {
        case .required: return NativeText("需要授权", "Authorization needed")
        case .granted: return NativeText("可控制", "Controllable")
        case .unknown: break
        }
        let remembered = candidate.evidence.contains { evidence in
            if case .remembered = evidence { return true }
            return false
        }
        if candidate.score >= 80 || remembered {
            return NativeText("可尝试连接", "Try connecting")
        }
        return NativeText("可能不是电视", "Maybe not a TV")
    }

    private func tvElapsedSeconds(_ duration: Duration) -> Int {
        let components = duration.components
        let roundedUp = components.seconds + (components.attoseconds > 0 ? 1 : 0)
        return max(0, Int(roundedUp))
    }

    // MARK: - Connection

    private func connect(_ candidate: TVCandidate) {
        guard !scanning, !busy, connectingID == nil else { return }
        connectingID = candidate.id
        connectionPhases[candidate.id] = .probing
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            let stream = TVConnector().connect(host: candidate.host, port: candidate.port)
            for await phase in stream {
                guard connectionGeneration == generation else { break }
                connectionPhases[candidate.id] = phase
                if case .connected(let model) = phase {
                    await save(candidate: candidate, model: model)
                } else if case .failed(kind: .unauthorized, _) = phase {
                    markAuthorizationRequired(candidate)
                }
                if isTerminalPhase(phase) { break }
            }
            // The stream can end without a terminal phase when the underlying
            // attempt is cancelled; never leave the row stuck on "connecting".
            guard connectionGeneration == generation else { return }
            if connectingID == candidate.id {
                if let phase = connectionPhases[candidate.id], !isTerminalPhase(phase) {
                    connectionPhases[candidate.id] = nil
                }
                connectingID = nil
            }
            connectionTask = nil
        }
    }

    private func save(candidate: TVCandidate, model: String) async {
        do {
            // Use the same active-slot guard as 保存 / 测试连接: a model turn or a
            // manual check in flight must not be redirected by a discovery
            // connection that finished meanwhile.
            try await ADBMCPServer.shared.configure(ADBConfiguration(enabled: true, host: candidate.host, port: candidate.port))
            enabled = true
            host = candidate.host
            port = String(candidate.port)
            status = NativeText("已连接 \(model) 并保存。", "Connected to \(model) and saved.")
            failed = false
            markAuthorization(candidate, .granted)
        } catch {
            status = error.localizedDescription
            failed = true
            connectionPhases[candidate.id] = .failed(kind: .device, message: error.localizedDescription)
        }
    }

    private func markAuthorizationRequired(_ candidate: TVCandidate) {
        markAuthorization(candidate, .required)
    }

    private func markAuthorization(_ candidate: TVCandidate, _ authorization: TVCandidate.Authorization) {
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index].authorization = authorization
        }
    }

    private func isConnectionInProgress(_ candidate: TVCandidate) -> Bool {
        guard connectingID == candidate.id, let phase = connectionPhases[candidate.id] else { return false }
        switch phase {
        case .probing, .awaitingAuthorization: return true
        case .idle, .connected, .failed: return false
        }
    }

    private func isTerminalPhase(_ phase: TVConnectPhase) -> Bool {
        switch phase {
        case .connected, .failed: return true
        case .idle, .probing, .awaitingAuthorization: return false
        }
    }

    private func cancelConnection() {
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        if let id = connectingID { connectionPhases[id] = nil }
        connectingID = nil
    }

    private func cancelTasks() {
        scanGeneration += 1
        connectionGeneration += 1
        scanTask?.cancel()
        connectionTask?.cancel()
        scanTask = nil
        connectionTask = nil
        scanning = false
        connectingID = nil
        connectionPhases = [:]
    }

    // MARK: - Manual form

    private func configuration() throws -> ADBConfiguration {
        guard let number = UInt16(port), number > 0 else { throw ADBFailure("端口必须是 1–65535") }
        return ADBConfiguration(enabled: enabled, host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: number)
    }
    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do { try await ADBMCPServer.shared.configure(configuration()); status = "已保存。"; failed = false }
            catch { status = error.localizedDescription; failed = true }
        }
    }
    private func check() {
        busy = true; failed = false; status = "请查看 Android 上的调试授权提示。"
        Task {
            defer { busy = false }
            do {
                status = try await ADBMCPServer.shared.checkConnection(configuration())
                failed = false
            } catch { status = error.localizedDescription; failed = true }
        }
    }
}
