// SPDX-License-Identifier: MIT
// Builds ESP32 firmware on this iPhone: GCC cc1 / cc1plus, GNU as, ar and ld
// compiled to WebAssembly run in a hidden WKWebView (Web Workers, in-memory
// WASI host), then a JavaScript elf2image writes the flashable image. Nothing
// leaves the phone and no computer is contacted. The tools and the prebuilt SDK
// pack are app resources (`firmware-builder/`); the page code is `FirmwareBuilder/`.
//
// What it can and cannot do is fixed by the pack: one target (ESP32-S3 for
// TonoLink, ESP32-C3 for xiaozhi on the AI Passport), one project, and the pack's
// own list of sources and flags. It recompiles the project's sources; it does not
// run CMake and does not rebuild ESP-IDF. Only a TonoLink (ESP32-S3) image can be
// handed to the board firmware page. DEBUG only.
#if DEBUG
import CryptoKit
import SwiftUI
import WebKit
import PhoneDSHBLE

/// Serves `pdsh-fwb://app/<file>` from the app bundle: `artifacts/<name>` from the
/// staged pack, everything else from the page code. Files are streamed in chunks so
/// the 130 MiB SDK pack never sits in this process as one `Data`.
@MainActor final class FirmwareBuilderSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pdsh-fwb"
    static let page = URL(string: "pdsh-fwb://app/builder.html")!
    private static let chunk = 1 << 20
    private var live = Set<ObjectIdentifier>()

    static var codeDirectory: URL? { Bundle.main.url(forResource: "FirmwareBuilder", withExtension: nil) }
    static var packDirectory: URL? { Bundle.main.url(forResource: "firmware-builder", withExtension: nil) }

    /// Maps a request path to a bundle file. Only a single plain file name is accepted
    /// in either directory, so a path can never leave them.
    static func file(forPath path: String) -> URL? {
        var parts = path.split(separator: "/").map(String.init)
        let root: URL?
        if parts.first == "artifacts" { parts.removeFirst(); root = packDirectory } else { root = codeDirectory }
        guard parts.count == 1, let name = parts.first, !name.hasPrefix("."), name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
        return root?.appendingPathComponent(name)
    }

    static func contentType(_ url: URL) -> String {
        switch url.pathExtension {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "wasm": "application/wasm"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(forPath: url.path),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let handle = try? FileHandle(forReadingFrom: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let id = ObjectIdentifier(task)
        live.insert(id)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.contentType(file), "Content-Length": String(size), "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        Task { @MainActor in
            defer { try? handle.close(); live.remove(id) }
            while live.contains(id) {
                let data = await Task.detached { (try? handle.read(upToCount: Self.chunk)) ?? Data() }.value
                guard live.contains(id) else { return }
                if data.isEmpty { task.didFinish(); return }
                task.didReceive(data)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { live.remove(ObjectIdentifier(task)) }
}

/// Forwards the page's `fwb` messages; kept apart so the web view does not retain the model.
@MainActor private final class FirmwareBuilderBridge: NSObject, WKScriptMessageHandler {
    var onMessage: (([String: Any]) -> Void)?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { onMessage?(body) }
    }
}

struct FirmwareBuilderPack: Equatable {
    var project: String
    var target: String
    var toolchain: String
    var bytes: Int
    var referenceImageSHA256: String
    /// File name of the app image the pack builds (`manifest.image`); older packs build agent_s3.bin.
    var imageName: String
    /// The TonoLink board firmware page can only flash the ESP32-S3 TonoLink image.
    var flashableOverUSB: Bool { target == "esp32s3" }
}

struct FirmwareBuilderError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor @Observable final class FirmwareBuilderModel {
    static let shared = FirmwareBuilderModel()
    /// Always present; the pack also lists cc1.wasm and/or cc1plus.wasm for its C and C++ sources.
    static let required = ["as.wasm", "ar.wasm", "ld.wasm", "sdk.bin", "project.bin"]

    var workers = 3
    private(set) var running = false
    private(set) var stage = ""
    private(set) var done = 0
    private(set) var total = 0
    private(set) var log: [String] = []
    private(set) var result = ""
    private(set) var report: [String: Any] = [:]
    private(set) var image: TonoLinkFirmwareImage?
    private(set) var imageSHA256 = ""
    private(set) var matchesReference: Bool?
    private(set) var seconds = 0.0

    @ObservationIgnored private var webView: WKWebView?
    @ObservationIgnored private var bridge: FirmwareBuilderBridge?
    @ObservationIgnored private var schemeHandler: FirmwareBuilderSchemeHandler?
    @ObservationIgnored private var pending: CheckedContinuation<[String: Any], any Error>?
    @ObservationIgnored private var loaded: CheckedContinuation<Void, any Error>?

    /// The staged pack, or nil with the reason it cannot be used.
    static func pack() -> Result<FirmwareBuilderPack, FirmwareBuilderError> {
        guard let directory = FirmwareBuilderSchemeHandler.packDirectory, FirmwareBuilderSchemeHandler.codeDirectory != nil else {
            return .failure(FirmwareBuilderError(NativeText("应用里没有固件构建资源", "The app has no firmware builder resources")))
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = manifest["files"] as? [String: [String: Any]] else {
            return .failure(FirmwareBuilderError(NativeText("没有安装工具链和 SDK 包（见 Bundle/firmware-builder/README.md）", "The toolchain and SDK pack are not staged (see Bundle/firmware-builder/README.md)")))
        }
        guard files["cc1.wasm"] != nil || files["cc1plus.wasm"] != nil else {
            return .failure(FirmwareBuilderError(NativeText("包里没有编译器（cc1.wasm / cc1plus.wasm）", "The pack has no compiler (cc1.wasm / cc1plus.wasm)")))
        }
        var bytes = 0
        for name in Set(required).union(files.keys.filter { $0.hasSuffix(".wasm") }).sorted() {
            guard let expected = files[name]?["bytes"] as? Int,
                  let actual = (try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize, actual == expected else {
                return .failure(FirmwareBuilderError(NativeText("包文件缺失或大小不符：\(name)", "Pack file missing or wrong size: \(name)")))
            }
            bytes += actual
        }
        let reference = (manifest["reference"] as? [String: Any])?["image_sha256"] as? String ?? ""
        return .success(FirmwareBuilderPack(project: manifest["project"] as? String ?? "", target: manifest["target"] as? String ?? "",
                                            toolchain: manifest["toolchain"] as? String ?? "", bytes: bytes, referenceImageSHA256: reference,
                                            imageName: Self.safeImageName(manifest["image"] as? String)))
    }

    /// A plain `*.bin` file name, or agent_s3.bin when the manifest names none.
    static func safeImageName(_ name: String?) -> String {
        guard let name, name.hasSuffix(".bin"), !name.hasPrefix("."),
              name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return "agent_s3.bin" }
        return name
    }

    static func outputURL(_ pack: FirmwareBuilderPack) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("firmware-builder/\(pack.imageName)")
    }

    /// Compiles, links and writes the image. Returns false with `result` set on failure.
    @discardableResult
    func build() async -> Bool {
        guard !running else { return false }
        running = true; stage = "start"; done = 0; total = 0; log = []; result = ""; report = [:]; image = nil; imageSHA256 = ""; matchesReference = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let started = Date()
        defer { running = false; seconds = Date().timeIntervalSince(started); UIApplication.shared.isIdleTimerDisabled = false; tearDown() }
        do {
            let pack = try Self.pack().get()
            try await openPage()
            let reply = try await run()
            guard let encoded = reply["imageBase64"] as? String, let data = Data(base64Encoded: encoded) else { throw FirmwareBuilderError("the page returned no image") }
            report = reply["report"] as? [String: Any] ?? [:]
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let claimed = (report["link"] as? [String: Any])?["imageSha256"] as? String
            guard claimed == digest else { throw FirmwareBuilderError("image digest changed between the page and the app") }
            let parsed = try TonoLinkFirmwareImage(data: data)
            let output = Self.outputURL(pack)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
            image = parsed; imageSHA256 = digest
            matchesReference = pack.referenceImageSHA256.isEmpty ? nil : pack.referenceImageSHA256 == digest
            stage = "done"
            result = NativeText("固件已生成：\(data.count) 字节", "Firmware built: \(data.count) bytes")
            return true
        } catch {
            stage = "failed"
            result = NativeText("失败：", "Failed: ") + error.localizedDescription
            return false
        }
    }

    /// Hands the built image to the board firmware page's model.
    func handOffToBoardPage() {
        guard let image else { return }
        TonoLinkUSBOTAModel.shared.image = image
        TonoLinkUSBOTAModel.shared.imageName = NativeText("agent_s3.bin（本机构建）", "agent_s3.bin (built on this iPhone)")
    }

    private func openPage() async throws {
        let handler = FirmwareBuilderSchemeHandler(), bridge = FirmwareBuilderBridge()
        bridge.onMessage = { [weak self] message in self?.receive(message) }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: FirmwareBuilderSchemeHandler.scheme)
        configuration.userContentController.add(bridge, name: "fwb")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.isInspectable = true
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        // A web view outside a window is throttled; keep it attached while building.
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        window?.addSubview(view)
        webView = view; self.bridge = bridge; schemeHandler = handler
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            loaded = continuation
            view.load(URLRequest(url: FirmwareBuilderSchemeHandler.page))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishLoad(.failure(FirmwareBuilderError("the builder page did not load")))
            }
        }
    }

    private func run() async throws -> [String: Any] {
        guard let webView else { throw FirmwareBuilderError("the builder page is gone") }
        let count = max(1, min(4, workers))
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            webView.evaluateJavaScript("window.fwbStart({workers: \(count)}); true") { [weak self] _, error in
                if let error { Task { @MainActor in self?.finish(.failure(error)) } }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                self?.finish(.failure(FirmwareBuilderError("the build did not finish within 30 minutes")))
            }
        }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "loaded": finishLoad(.success(()))
        case "log": if let text = message["message"] as? String { log.append(text) }
        case "progress":
            stage = message["stage"] as? String ?? stage
            done = message["done"] as? Int ?? done
            total = message["total"] as? Int ?? total
        case "done": finish(.success(message))
        case "error": finish(.failure(FirmwareBuilderError(message["message"] as? String ?? "build failed")))
        default: break
        }
    }

    private func finishLoad(_ outcome: Result<Void, any Error>) {
        guard let continuation = loaded else { return }
        loaded = nil
        continuation.resume(with: outcome)
    }

    private func finish(_ outcome: Result<[String: Any], any Error>) {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume(with: outcome)
    }

    private func tearDown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "fwb")
        webView?.removeFromSuperview()
        webView = nil; bridge = nil; schemeHandler = nil
        finishLoad(.failure(CancellationError())); finish(.failure(CancellationError()))
    }
}

struct FirmwareBuilderPage: View {
    @State private var model = FirmwareBuilderModel.shared
    @State private var board = TonoLinkUSBOTAModel.shared

    var body: some View {
        List {
            Section {
                Text(NativeText("在这台 iPhone 上把工程源码编译、链接成 ESP32 固件，全程不联网、不需要电脑。目标芯片、预编译的 ESP-IDF 库和编译清单都来自随应用安装的 SDK 包，所以只能重编包里已有的源文件。构建期间请保持应用在前台。",
                                "Compiles and links the project into ESP32 firmware on this iPhone, offline and without a computer. The target chip, the prebuilt ESP-IDF libraries and the build recipe come from the SDK pack installed with the app, so only the sources already in the pack are rebuilt. Keep the app in the foreground while it builds."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(NativeText("工具链和 SDK 包", "Toolchain and SDK pack")) {
                switch FirmwareBuilderModel.pack() {
                case .success(let pack):
                    LabeledContent(NativeText("工程", "Project"), value: pack.project)
                    LabeledContent(NativeText("目标", "Target"), value: pack.target)
                    LabeledContent(NativeText("大小", "Size"), value: ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file))
                    Text(pack.toolchain).font(.caption).foregroundStyle(.secondary)
                case .failure(let error):
                    Text(error.message).foregroundStyle(.red)
                }
            }
            Section(NativeText("构建", "Build")) {
                Stepper(NativeText("并行编译：\(model.workers) 路", "Parallel compiles: \(model.workers)"), value: $model.workers, in: 1...4).disabled(model.running)
                Button(NativeText("构建固件", "Build firmware")) { Task { await model.build() } }
                    .disabled(model.running || (try? FirmwareBuilderModel.pack().get()) == nil)
                if model.running {
                    if model.stage == "compile", model.total > 0 {
                        ProgressView(value: Double(model.done), total: Double(model.total)) { Text(NativeText("编译 \(model.done) / \(model.total)", "Compiling \(model.done) / \(model.total)")) }
                    } else {
                        ProgressView { Text(model.stage == "link" ? NativeText("链接中…", "Linking…") : NativeText("准备中…", "Preparing…")) }
                    }
                }
                if !model.result.isEmpty { Text(model.result).font(.callout) }
            }
            if let image = model.image {
                Section(NativeText("产物", "Output")) {
                    LabeledContent(NativeText("大小", "Size"), value: "\(image.data.count) B")
                    LabeledContent(NativeText("版本", "Version"), value: image.version)
                    LabeledContent("ELF SHA-256", value: String(image.elfSHA256.prefix(16)) + "…")
                    LabeledContent(NativeText("镜像 SHA-256", "Image SHA-256"), value: String(model.imageSHA256.prefix(16)) + "…")
                    LabeledContent(NativeText("耗时", "Time"), value: String(format: "%.0f s", model.seconds))
                    if let matches = model.matchesReference {
                        Label(matches ? NativeText("与电脑上的参考构建逐字节一致", "Byte-identical to the reference build made on a computer")
                                      : NativeText("与参考构建不同（源码改过时属正常）", "Differs from the reference build (expected when sources changed)"),
                              systemImage: matches ? "checkmark.seal" : "exclamationmark.triangle")
                            .font(.footnote)
                    }
                    if (try? FirmwareBuilderModel.pack().get())?.flashableOverUSB == true {
                        NavigationLink(NativeText("刷到板子（USB）", "Flash to the board (USB)")) { TonoLinkUSBOTAPage() }
                            .simultaneousGesture(TapGesture().onEnded { model.handOffToBoardPage() })
                            .disabled(board.running)
                    } else {
                        Text(NativeText("镜像已存到“文件 › Phone DSH › firmware-builder”。这个芯片的板子不能从本页刷写，请用电脑上的 esptool 刷入。",
                                        "The image is saved in Files › Phone DSH › firmware-builder. This chip's board cannot be flashed from this page; flash it with esptool on a computer."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.log.isEmpty {
                Section(NativeText("过程", "Steps")) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element).font(.caption) }
                }
            }
        }
        .navigationTitle(NativeText("固件构建", "Firmware builder"))
    }
}

/// Headless entry for device verification: `PDSH_FIRMWARE_BUILD=build|build-flash`
/// (optional `PDSH_FIRMWARE_BUILD_WORKERS`). The report goes to
/// Documents/firmware-builder.json and the image to Documents/firmware-builder/<manifest image>.
/// `build-flash` then runs the board page's USB update with the built image (TonoLink packs only).
@MainActor enum FirmwareBuilderDiagnostics {
    static let environmentKey = "PDSH_FIRMWARE_BUILD"

    static func run(_ mode: String) async {
        let environment = ProcessInfo.processInfo.environment
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("firmware-builder.json")
        var report: [String: Any] = ["run_id": environment["PDSH_HEADLESS_RUN_ID"] ?? "", "mode": mode, "status": "running"]
        func save() { if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) } }
        save()
        guard mode == "build" || mode == "build-flash" else { report["status"] = "failed"; report["error"] = "unknown mode"; save(); return }
        // The key window must exist before the hidden web view can attach to it.
        try? await Task.sleep(for: .seconds(2))
        let model = FirmwareBuilderModel.shared
        if let text = environment["PDSH_FIRMWARE_BUILD_WORKERS"], let count = Int(text) { model.workers = count }
        let built = await model.build()
        report["seconds"] = model.seconds
        report["log"] = model.log
        report["build"] = model.report
        report["result"] = model.result
        guard built, let image = model.image else { report["status"] = "failed"; save(); return }
        report["image"] = ["bytes": image.data.count, "sha256": model.imageSHA256, "elf_sha256": image.elfSHA256, "version": image.version,
                           "matches_reference": model.matchesReference.map { $0 as Any } ?? NSNull()]
        guard mode == "build-flash" else { report["status"] = "passed"; save(); return }
        guard (try? FirmwareBuilderModel.pack().get())?.flashableOverUSB == true else {
            report["status"] = "failed"; report["error"] = "this pack's image cannot be flashed over the TonoLink USB link"; save(); return
        }
        report["status"] = "flashing"; save()
        model.handOffToBoardPage()
        let board = TonoLinkUSBOTAModel.shared
        if let name = environment["PDSH_TONOLINK_NAME"] { board.nameHint = name }
        let flashed = await board.perform(.update)
        report["flash"] = ["result": board.result, "steps": board.log,
                           "board": board.boardState.map { ["version": $0.version, "slot": $0.slot, "state": $0.state, "elf_sha256": $0.elfSHA256, "boot": $0.boot] as [String: Any] } ?? [:]]
        report["status"] = flashed ? "passed" : "failed"
        save()
    }
}
#endif
