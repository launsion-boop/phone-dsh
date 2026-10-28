// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator full-Web session E2E.
//
// This suite loads the complete DSH Web page the app reuses (`Bundle/worker/web`
// through `/static/web/index.html`) in a real `WKWebView`, boots the real
// `PhoneDSHHost` over the same loopback origin and the same ordered channel,
// and drives the page through its own DOM:
//
//   composer → session/prompt → Worker agent-loop → bash in the Worker VFS
//   → tool/result in the same Session → Web tool row + assistant text
//   → document previews → background park/new-engine resume → WebContent kill
//
// Every send gets a fresh nonce: it names the text/PNG files, stamps a tEXt
// chunk into the PNG bytes, prefixes the bash PNG-write marker and appears in
// the scripted assistant response. Old files, DOM rows and JSONL records can
// therefore never satisfy this run's evidence.
//
// Only the model response is scripted (`MockModelUpstream`, the existing
// harness fixture). The shell, VFS writes, WAL/materialized copy, session JSONL,
// the tool call/result events and the DOM are real. A real model endpoint is
// NOT_RUN here; no credential is used or printed. Text entry clears any restored
// draft through the editor's deletion input event, dispatches the prompt through
// the page's real DOM paste path (the production `PASTE_COMMAND` handler), polls
// the asynchronous Lexical commit, and clicks its own Send control; no trusted
// hardware-keyboard event is synthesized, so physical keyboard coverage stays
// NOT_VERIFIED on the simulator.
//
// The suite uses the same host assembly and persistent
// `Documents/chat-host` workspace the App's Chat page uses
// (`ChatHostConfiguration` + `WebHostConfiguration` in ProbeKit), including
// the pinned origin, persistent WebEngine store and shell provider; it does
// not build a parallel host. It also repeats `sim.sh`'s audit of the staged
// `web-build.json`/`sizes.json`/`probe-bundle.json` against the installed
// bundle, using the canonical pin and any explicitly selected controlled
// commit/version supplied by the CI runner (never the bundle's own expected
// fields), so an old prebuilt page cannot be stamped with the current pin and
// a controlled build cannot pass as the canonical one. The report fails loudly
// when the page path or web assets are not integrated yet.
// When `scripts/ci/sim.sh` starts the device-scoped WebContent watcher, the
// suite also hands its live WKWebView to a real `SIGKILL` and gates recovery
// from it; a direct `xcodebuild test` without the watcher records that row as
// NOT_RUN.
//
// NOT_VERIFIED on a physical iPhone: every row says `ios-simulator`.

import CoreGraphics
import CryptoKit
import Foundation
import XCTest
import WebKit
import PhoneDSHAgentCore
import PhoneDSHHarness
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHShell
import ProbeKit

@MainActor
final class PhoneDSHWebSurfaceTests: XCTestCase {
    /// Fixed contract from the integration owner: the complete Web page.
    private static let fullPagePath = "/static/web/index.html"
    /// Canonical 68-byte 1x1 RGBA PNG; ``makeTurn()`` appends a unique tEXt
    /// chunk so every run's file bytes differ while the image stays 1x1.
    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII="
    private static let hostAPIKey = "web-surface-host-key"
    private static let workerPlaceholderKey = "web-surface-worker-placeholder"

    /// One send's unique evidence identifiers.
    ///
    /// A fresh nonce names the text/PNG files, their contents, the PNG bytes
    /// (a tEXt chunk), the bash stdout marker and the scripted assistant
    /// response. A previous run's `pixel.png`, DOM row or JSONL record can
    /// therefore never satisfy this run's waits.
    private struct TurnExpectation {
        let nonce: String
        let textName: String
        let imageName: String
        let textPath: String
        let imagePath: String
        let textContent: String
        let marker: String
        let prompt: String
        let finalText: String
        let pngData: Data
    }

    private static func makeTurn() -> TurnExpectation {
        let nonce = "n" + String(UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let textName = "loop-\(nonce).txt"
        let imageName = "pixel-\(nonce).png"
        let textContent = "hello-\(nonce)"
        let marker = "PDSH_PNG_OK_\(nonce)"
        let pngData = uniquePNG(nonce: nonce)
        let prompt = "Run the local E2E \(nonce): write \(textName) and \(imageName), "
            + "then open both previews."
        let finalText = "Done \(nonce): \(textName) contains \(textContent). "
            + "[\(textName)](\(textName)) [\(imageName)](\(imageName))"
        return TurnExpectation(
            nonce: nonce,
            textName: textName,
            imageName: imageName,
            textPath: "/dsh/workspace/\(textName)",
            imagePath: "/dsh/workspace/\(imageName)",
            textContent: textContent,
            marker: marker,
            prompt: prompt,
            finalText: finalText,
            pngData: pngData)
    }

    /// One bash call that writes and reads this turn's text file, decodes the
    /// unique PNG from base64 inside the Worker, then prints `marker` only
    /// after a successful write. It finally proves a path outside the
    /// workspace roots is refused and captures that refusal on stdout. The
    /// `&&` before the marker is the evidence that the PNG write really
    /// happened; the old fixed `pixel.png` file cannot stand in for it.
    private static func toolCommand(_ turn: TurnExpectation) -> String {
        let pngBase64 = turn.pngData.base64EncodedString()
        return "printf '%s' '\(turn.textContent)' > \(turn.textPath) && cat \(turn.textPath)"
            + " && printf '%s' '\(pngBase64)' | base64 -d > \(turn.imagePath)"
            + " && printf '\(turn.marker)\\n'"
            + "; { printf 'nope' > /var/pdsh-outside.txt; } 2>/dsh/tmp/outside.err || true"
            + "; cat /dsh/tmp/outside.err"
    }

    /// Appends a tEXt chunk before IEND with this run's nonce. The pixels stay
    /// a valid 1x1 image, but the file bytes are unique and carry a marker
    /// that the test can correlate with this turn.
    private static func uniquePNG(nonce: String) -> Data {
        var data = Data(base64Encoded: pngBase64) ?? Data()
        guard data.count > 12 else { return data }
        let text = Data("Comment".utf8) + Data([0]) + Data("phone-dsh \(nonce)".utf8)
        var chunk = Data()
        appendBigEndian(UInt32(text.count), to: &chunk)
        chunk.append(Data("tEXt".utf8))
        chunk.append(text)
        appendBigEndian(crc32(Data("tEXt".utf8) + text), to: &chunk)
        // The final 12 bytes are the empty IEND chunk (length, type, CRC).
        data.insert(contentsOf: chunk, at: data.count - 12)
        return data
    }

    private static func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

    func testSimulatorFullWebSessionToolResultAndPreviews() async throws {
        let turn = Self.makeTurn()
        let directory = try SimEnvironment.reportsDirectory()
        let report = SimSuiteReport(suite: "web", gate: "G1", directory: directory,
                                    fileName: "web-surface-report.json")
        let eventLog = SimSmokeEventLog()
        let fileManager = FileManager.default
        // The App's Chat page owns `Documents/chat-host`. The installed probe
        // app's container is that same on-device location; using it here means
        // the session JSONL and the WAL are the App's persistent store, not a
        // detached test directory.
        guard let appContainer = SimEnvironment.appDataContainer() else {
            throw SimError.environment(
                "the probe app data container is missing; scripts/ci/sim.sh installs it first")
        }
        let documents = appContainer.appendingPathComponent("Documents", isDirectory: true)
        let workspace = ChatHostConfiguration.workspaceRoot(documents: documents)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        report.set("app_container", appContainer.path)
        report.set("workspace_root", workspace.path)
        report.set("session_store", workspace.path)
        report.set("full_page_path", Self.fullPagePath)
        report.set("turn_nonce", turn.nonce)
        report.set("text_path", turn.textPath)
        report.set("image_path", turn.imagePath)
        report.set("text_content", turn.textContent)
        report.set("png_marker", turn.marker)
        report.set("prompt", turn.prompt)
        let mock = MockModelUpstream()
        var window: SimVisibleWindow?
        var engine: WebEngine?
        var host: PhoneDSHHost?
        var failure: Error?

        do {
            // The complete page is a build-time asset. A checkout that has not
            // integrated it fails here with the exact path, never with a
            // silently different page that only looks similar.
            let bundle = try SimEnvironment.workerBundle()
            report.set("worker_static_directory", bundle.staticDirectory.path)
            report.set("worker_image", bundle.imageArchive.path)
            // The staged page and Worker image must both name the DSH source
            // selected for this run (the canonical pin by default), and the
            // page hashes must match the bytes in this bundle. The expectation
            // comes from the runner, not from the bundle's dsh_expected_*.
            // A stale prebuilt page whose missing record was synthesized by
            // the copy step can therefore never pass this E2E.
            let metadata = Self.workerAssetMetadata(bundle,
                                                    environment: SimEnvironment.variables)
            report.set("asset_metadata", metadata.metrics)
            try require(report, "page.metadata", metadata.passed,
                        metrics: metadata.metrics,
                        detail: metadata.detail)
            let fullPage = bundle.staticDirectory.appendingPathComponent("web/index.html")
            let pageAsset = fileManager.fileExists(atPath: fullPage.path)
            try require(report, "page.asset", pageAsset,
                        metrics: ["path": fullPage.path],
                        detail: "the complete Web page exists at \(fullPage.path)")
            guard pageAsset else {
                throw SimError.environment(
                    "the complete Web page is missing at \(fullPage.path); "
                    + "the Web bundle group has not staged Bundle/worker/web yet")
            }
            // The injected ./web-boot.js lives beside the page and resolves the
            // Worker as new URL('../worker-entry.js', import.meta.url), i.e.
            // /static/worker-entry.js. Both files must be staged with the page;
            // bootReady alone would time out without telling which asset was
            // dropped. The served URLs are also probed for HTTP 200 below.
            let webBootAsset = bundle.staticDirectory
                .appendingPathComponent("web/web-boot.js")
            let workerAsset = bundle.staticDirectory
                .appendingPathComponent("worker-entry.js")
            let webBootPresent = fileManager.fileExists(atPath: webBootAsset.path)
            let workerPresent = fileManager.fileExists(atPath: workerAsset.path)
            try require(report, "page.worker_asset", webBootPresent && workerPresent,
                        metrics: ["web_boot": webBootAsset.path,
                                  "worker_entry": workerAsset.path,
                                  "web_boot_present": webBootPresent,
                                  "worker_entry_present": workerPresent],
                        detail: "the page's ./web-boot.js and the /static/worker-entry.js it spawns are staged")

            mock.script = .generic(command: Self.toolCommand(turn),
                                   toolText: "Running the local bash tool.",
                                   finalText: turn.finalText)
            let mockURL = try mock.start()
            report.set("mock_model_url", mockURL.absoluteString)

            let visibleWindow = SimVisibleWindow(size: CGSize(width: 430, height: 932))
            window = visibleWindow
            guard visibleWindow.isAttached else {
                throw SimError.assertion("the full-Web window anchor is not attached")
            }
            // Use the same visible-anchor + engine factory the App's
            // WebHostModel uses. The engine must be created from the host's
            // final configuration (bound origin/token and the persistent
            // store), never from a placeholder created before start().
            let anchor = VisibleEngineAnchor()
            visibleWindow.anchor.addSubview(anchor.view)
            visibleWindow.window.layoutIfNeeded()
            guard anchor.isInWindow else {
                throw SimError.assertion("the WebEngine anchor is not in the window")
            }
            let fixedPort = WebHostConfiguration.freeLoopbackPort()
            let assembly = WebHostConfiguration.make(
                workspaceRoot: workspace,
                bundle: bundle,
                modelURL: mockURL,
                modelName: "web-surface",
                credentialProvider: StaticCredentialProvider([
                    CredentialScope(service: "127.0.0.1"):
                        Credential(kind: .apiKey(header: "x-api-key"),
                                   value: Self.hostAPIKey),
                ]),
                egressHosts: [],
                loopbackPort: fixedPort,
                workerPlaceholderKey: Self.workerPlaceholderKey,
                pagePath: Self.fullPagePath,
                drainDeadline: 5,
                helloTimeout: 240)
            var configuration = assembly.configuration
            // A hostless test has no App scene; give the page the same
            // mobile-width viewport the App's full-screen surface provides.
            configuration.engine.visibleAreaPoints = 430
            let shellAccelerators = assembly.shellProvider.channelAcceleratorNames
            let configuredAssembly: [String: Any] = [
                "page_path": configuration.engine.pagePath,
                "persistent_store": configuration.engine.usesPersistentWebsiteDataStore,
                "loopback_port": Int(configuration.loopback.port),
                "origin": configuration.engine.origin.absoluteString,
                "exec_provider": configuration.execProvider != nil,
                "shell_provider_equal": configuration.accelerators == assembly.shellProvider,
                "accelerator_names": configuration.acceleratorNames,
                "shell_accelerators": shellAccelerators,
            ]
            report.set("host_assembly", configuredAssembly)
            report.set("configured_page_path", configuration.engine.pagePath)
            try require(report, "host.assembly",
                        fixedPort != 0
                            && configuration.engine.pagePath == Self.fullPagePath
                            && configuration.engine.usesPersistentWebsiteDataStore
                            && configuration.loopback.port == fixedPort
                            && configuration.execProvider != nil
                            && configuration.accelerators == assembly.shellProvider
                            && (assembly.shellProvider.acceleratorNames.isEmpty
                                || configuration.acceleratorNames == shellAccelerators),
                        metrics: configuredAssembly,
                        detail: "the suite boots the App's WebHostConfiguration assembly: complete page, "
                            + "pinned origin, persistent store and the linked shell provider/accelerators")

            let engineSlot = EngineSlot()
            let webHost = PhoneDSHHost(
                configuration: configuration,
                engineFactory: WebHostConfiguration.engineFactory(anchor: anchor) { engine in
                    engineSlot.publish(engine)
                })
            host = webHost
            eventLog.attach(host: webHost)

            // MARK: Boot the real host and the complete page
            let bootStart = Date()
            try await webHost.start()
            try await simWait(timeout: 240, label: "host Running") {
                await webHost.state == .running
            }
            guard var realEngine = engineSlot.engine else {
                throw SimError.assertion("the host did not create a WebEngine")
            }
            engine = realEngine
            guard realEngine.isAttachedWithVisibleArea else {
                throw SimError.assertion("the WKWebView is not attached with a visible area")
            }
            // The loopback serves the staged files; do not wait for bootReady to
            // discover that the page's worker was not staged. The full page
            // loads ./web-boot.js, which spawns ../worker-entry.js, so the
            // served worker path is /static/worker-entry.js.
            let servedConfiguration = realEngine.configuration
            let servedOriginFixed = servedConfiguration.origin.host == "127.0.0.1"
                && servedConfiguration.origin.port == Int(fixedPort)
            let servedPersistentStore =
                realEngine.view.configuration.websiteDataStore.isPersistent
            let engineAssembly: [String: Any] = [
                "origin": servedConfiguration.origin.absoluteString,
                "origin_fixed": servedOriginFixed,
                "page_path": servedConfiguration.pagePath,
                "persistent_store_config": servedConfiguration.usesPersistentWebsiteDataStore,
                "persistent_store_actual": servedPersistentStore,
                "attached": realEngine.isAttachedWithVisibleArea,
            ]
            report.set("engine_assembly", engineAssembly)
            try require(report, "engine.assembly",
                        servedOriginFixed
                            && servedConfiguration.pagePath == Self.fullPagePath
                            && servedConfiguration.usesPersistentWebsiteDataStore
                            && servedPersistentStore,
                        metrics: engineAssembly,
                        detail: "the WebEngine was built from the bound loopback origin with a "
                            + "persistent WKWebsiteDataStore and the complete page path")
            let servedPage = try await Self.servedAsset(
                origin: servedConfiguration.origin,
                path: Self.fullPagePath,
                token: servedConfiguration.token)
            let servedWebBoot = try await Self.servedAsset(
                origin: servedConfiguration.origin,
                path: "/static/web/web-boot.js",
                token: servedConfiguration.token)
            let servedWorker = try await Self.servedAsset(
                origin: servedConfiguration.origin,
                path: servedConfiguration.workerPath,
                token: servedConfiguration.token)
            let servedAssets: [String: Any] = [
                "page": ["status": servedPage.status, "bytes": servedPage.bytes] as [String: Any],
                "web_boot": ["status": servedWebBoot.status,
                             "bytes": servedWebBoot.bytes] as [String: Any],
                "worker": ["status": servedWorker.status, "bytes": servedWorker.bytes,
                           "path": servedConfiguration.workerPath] as [String: Any],
            ]
            report.set("served_assets", servedAssets)
            try require(report, "page.served_assets",
                        servedPage.status == 200 && servedPage.bytes > 0
                            && servedWebBoot.status == 200 && servedWebBoot.bytes > 0
                            && servedWorker.status == 200 && servedWorker.bytes > 0,
                        metrics: ["page_status": servedPage.status,
                                  "web_boot_status": servedWebBoot.status,
                                  "worker_status": servedWorker.status,
                                  "worker_path": servedConfiguration.workerPath,
                                  "worker_bytes": servedWorker.bytes],
                        detail: "the loopback serves index.html, ./web-boot.js and the worker it spawns with HTTP 200")
            try await simWait(timeout: 240, label: "full Web page bootReady") {
                realEngine.lastBootStatus?.state == .ready
            }
            report.addPhase("boot_and_page_ready", milliseconds: Self.ms(since: bootStart))
            let hostDiagnostics = await webHost.diagnostics()
            let pagePath = realEngine.configuration.pagePath
            report.set("boot_id", hostDiagnostics.bootID)
            report.set("engine_page_path", pagePath)
            try require(report, "page.path", pagePath == Self.fullPagePath,
                        metrics: ["actual": pagePath, "expected": Self.fullPagePath],
                        detail: "PhoneDSHHost boots the complete page at \(Self.fullPagePath), not a placeholder")

            // One existing directory is registered through the same native
            // transport the app uses. This creates no Session: it gives the Web
            // page the workspace its own first-use flow needs, so the page
            // creates exactly one chat session for the prompt below.
            let transport = try await webHost.makeTransport()
            let workspaceValue = try await transport.call(
                "workspace/create",
                args: .object(["request": .object(["path": .string("/dsh/workspace")])]))
            report.set("workspace_create", [
                "created": workspaceValue["created"]?.boolValue ?? false,
                "workspace_id": workspaceValue["workspace"]?["workspaceId"]?.stringValue ?? "",
            ])
            // Let the page's workspace/follow baseline apply before its own
            // New Session gesture runs; otherwise the gesture can see an empty
            // registry and create nothing.
            try await Task.sleep(nanoseconds: 3_000_000_000)

            try await waitForShellAndComposer(realEngine, timeout: 120)
            report.record("web.dom.shell",
                          status: .pass, gating: true,
                          metrics: ["shell_overlay": true, "composer": true],
                          threshold: simG1Threshold("g1_web_shell_and_composer", measured: 1),
                          detail: "the complete page rendered [data-shell-overlay] and [data-composer-input]")

            // Baseline the journal immediately before submitting. An earlier
            // successful run can leave the identical bash command in an older
            // Session; the wait below only accepts a tool/result whose seq is
            // newer than this baseline (or a Session that did not exist yet),
            // and that Session's file must also have grown.
            let logsBefore = try sessionLogIDs(workspace: workspace)
            let sessionBaseline = try sessionLogBaselines(workspace: workspace)
            report.set("session_logs_before", logsBefore)
            report.set("session_baseline", sessionBaseline.mapValues { baseline -> [String: Any] in
                [
                    "max_seq": baseline.maxSeq,
                    "bytes": baseline.byteCount,
                    "modified": ISO8601DateFormatter().string(from: baseline.modified),
                ]
            })

            // MARK: Observe and normalize the live composer's real control state
            // The complete page owns the composer; the suite does not assume a
            // textarea or a disabled=false attribute. Record the actual tag,
            // contenteditable (attribute and property), aria-disabled,
            // visibility, focus, phase, placeholder and Session before typing.
            // That state and the resolved Session/Workspace/preset are what
            // separate a harness-input defect from a page whose Session was
            // restored in a different Workspace.
            //
            // The suite reuses the App's persistent Documents/chat-host store,
            // so record the draft this run inherited and clear it through the
            // editor's own deletion input event. A previous interrupted paste
            // must not be prepended to this run's exact prompt.
            let composerStateBefore = try await composerState(realEngine)
            report.set("composer_state_before_clear", composerStateBefore)
            let activeBefore = composerStateBefore["active"] as? [String: Any] ?? [:]
            let composerDraftBefore = (activeBefore["draft_length"] as? NSNumber)?.intValue ?? -1
            let composerSessionBefore = activeBefore["session"] as? String ?? ""
            // Diagnostic only: it must not prevent the draft cleanup if the
            // page's Session projection is temporarily unavailable.
            let composerSessionBeforeMetrics: [String: Any] =
                (try? await composerSessionEvidence(transport,
                                                    sessionID: composerSessionBefore))
                ?? ["status": "unavailable"]
            report.set("composer_session_before_clear", composerSessionBeforeMetrics)
            do {
                let draftClear = try await clearComposerDraft(realEngine)
                var draftClearMetrics = draftClear
                draftClearMetrics["draft_length_before"] = composerDraftBefore
                draftClearMetrics["input_method"] = "dom-beforeinput-delete"
                draftClearMetrics["trusted_hardware_keyboard"] = false
                report.set("composer_draft_clear", draftClearMetrics)
                try await simWait(timeout: 30, label: "composer draft cleared") {
                    try await self.composerDraftLength(realEngine) == 0
                }
                let clearedDraftLength = try await composerDraftLength(realEngine)
                try require(report, "composer.draft_clear",
                            clearedDraftLength == 0,
                            metrics: ["draft_length_before": composerDraftBefore,
                                      "draft_length_after": clearedDraftLength,
                                      "input_method": "dom-beforeinput-delete",
                                      "trusted_hardware_keyboard": false,
                                      "dispatch": draftClear],
                            detail: "the reused App store's draft was emptied through the editor's "
                                + "real deletion input event before this run's prompt")
            } catch {
                let cleanup: [String: Any] =
                    (try? await self.discardPersistedComposerDraft(realEngine))
                    ?? ["status": "failed"]
                report.set("composer_draft_cleanup", cleanup)
                throw error
            }

            // Poll the settled state instead of sampling once: the page can
            // expose an editable root before its composer seat is visible.
            try await simWait(timeout: 120, label: "visible editable composer in a Session") {
                let state = try await self.composerState(realEngine)
                return self.composerStateReady(state)
            }
            let composerSnapshot = try await self.composerState(realEngine)
            report.set("composer_state", composerSnapshot)
            let activeComposer = composerSnapshot["active"] as? [String: Any] ?? [:]
            let composerCount = (composerSnapshot["composer_count"] as? NSNumber)?.intValue ?? 0
            let composerTag = activeComposer["tag"] as? String ?? ""
            let composerEditableAttr = activeComposer["contenteditable_attr"] as? String ?? ""
            let composerContentEditable = activeComposer["is_content_editable"] as? Bool ?? false
            let composerAriaDisabled = activeComposer["aria_disabled"] as? String ?? ""
            let composerDisabledAttr = activeComposer["disabled_attr"] as? Bool ?? false
            let composerNativeDisabled = activeComposer["native_disabled"] as? Bool ?? false
            let composerVisible = activeComposer["visible"] as? Bool ?? false
            let composerFocused = activeComposer["focused"] as? Bool ?? false
            let composerDocumentFocused = activeComposer["document_has_focus"] as? Bool ?? false
            let composerPhase = activeComposer["phase"] as? String ?? ""
            let composerPlaceholder = activeComposer["placeholder"] as? String ?? ""
            let composerDraftCount = (activeComposer["draft_length"] as? NSNumber)?.intValue ?? -1
            let composerDraftText = activeComposer["draft_text"] as? String ?? ""
            let composerStoredDraftLength =
                (activeComposer["stored_draft_length"] as? NSNumber)?.intValue ?? -1
            let composerSessionID = activeComposer["session"] as? String ?? ""
            // Collect the selected Session's native workspace and preset before
            // the ready gate, so a disabled or wrong-workspace state still has
            // those diagnostic fields in the report.
            let composerSessionMetrics = try await composerSessionEvidence(
                transport, sessionID: composerSessionID)
            report.set("composer_session", composerSessionMetrics)
            let composerCwd = composerSessionMetrics["cwd"] as? String ?? ""
            let composerBlank = composerSessionMetrics["blank"] as? Bool ?? false
            let composerPreset = composerSessionMetrics["agent_preset"] as? String ?? ""
            let composerMetrics: [String: Any] = [
                "composer_count": composerCount,
                "tag": composerTag,
                "contenteditable_attr": composerEditableAttr,
                "is_content_editable": composerContentEditable,
                "aria_disabled": composerAriaDisabled,
                "disabled_attr": composerDisabledAttr,
                "native_disabled": composerNativeDisabled,
                "visible": composerVisible,
                "focused": composerFocused,
                "document_has_focus": composerDocumentFocused,
                "phase": composerPhase,
                "placeholder": composerPlaceholder,
                "draft_length": composerDraftCount,
                "draft_text": composerDraftText,
                "stored_draft_length": composerStoredDraftLength,
                "draft_cleared_before_input": true,
                "session_id": composerSessionID,
                "cwd": composerCwd,
                "blank": composerBlank,
                "agent_preset": composerPreset,
            ]
            try require(report, "composer.ready",
                        composerVisible
                            && composerEditableAttr == "true"
                            && composerContentEditable
                            && composerAriaDisabled != "true"
                            && !composerDisabledAttr
                            && !composerNativeDisabled
                            && !composerSessionID.isEmpty
                            && composerDraftCount == 0,
                        metrics: composerMetrics,
                        detail: "the live composer is a visible editable \(composerTag) in a Session "
                            + "with an empty draft after the persisted draft was cleared "
                            + "(contenteditable=true, aria-disabled is not true); no disabled state is bypassed")
            try require(report, "composer.workspace",
                        composerCwd == "/dsh/workspace",
                        metrics: composerSessionMetrics,
                        detail: "the Session selected by the page is the App-container /dsh/workspace "
                            + "Session (the same cwd the native session/list check requires later), with "
                            + "preset \(composerPreset.isEmpty ? "<unreported>" : composerPreset)")

            // MARK: Submit the prompt through the real DOM composer
            // The page's Lexical surface is not a textarea: execCommand
            // insertText in a WKWebView without a key window can be a no-op.
            // Use the production DOM paste path instead; it is the same
            // PASTE_COMMAND the real editor and clipboard use. The paste commit
            // reconciles in a microtask, so only report that the event was
            // dispatched here and poll the committed draft separately. Then
            // click the page's own Send control, so the submission is a real
            // DOM gesture rather than a fabricated session/prompt call.
            let pasteDispatch = try await evaluateString(realEngine,
                                                         Self.insertPromptScript(turn.prompt))
            try require(report, "composer.paste_dispatch",
                        pasteDispatch == "dispatched",
                        metrics: ["paste_dispatch": pasteDispatch,
                                  "input_method": "dom-paste-event",
                                  "trusted_hardware_keyboard": false],
                        detail: "the production Lexical PASTE_COMMAND received this run's prompt")
            try await simWait(timeout: 60, label: "composer draft after paste commit") {
                try await self.composerDraftMatches(realEngine, text: turn.prompt)
            }
            let composerStateAfterInsert = try await composerState(realEngine)
            report.set("composer_state_after_insert", composerStateAfterInsert)
            let insertedComposer = composerStateAfterInsert["active"] as? [String: Any] ?? [:]
            let inserted = insertedComposer["draft_text"] as? String ?? ""
            let insertedVisible = insertedComposer["visible"] as? Bool ?? false
            let insertedEditableAttr = insertedComposer["contenteditable_attr"] as? String ?? ""
            let insertedSession = insertedComposer["session"] as? String ?? ""
            try require(report, "composer.insert",
                        inserted == turn.prompt
                            && insertedVisible
                            && insertedEditableAttr == "true"
                            && insertedSession == composerSessionID,
                        metrics: ["composer_text": inserted,
                                  "expected_prompt": turn.prompt,
                                  "visible": insertedVisible,
                                  "contenteditable_attr": insertedEditableAttr,
                                  "session_id": insertedSession,
                                  "input_method": "dom-paste-event",
                                  "trusted_hardware_keyboard": false],
                        detail: "the run's exact unique prompt landed in the page's contenteditable composer "
                            + "after the asynchronous Lexical paste commit; no truncated or appended draft passed")
            let sendLabel = try await clickSend(realEngine, timeout: 60)
            report.set("send_button", sendLabel)
            try require(report, "composer.send",
                        !sendLabel.isEmpty,
                        metrics: ["send_button": sendLabel,
                                  "composer_phase": composerPhase],
                        detail: "the page's own enabled Send control was available after the draft landed")
            try await simWait(timeout: 120, label: "user row after Send click") {
                try await self.userRowVisible(realEngine, nonce: turn.nonce)
            }
            report.record("web.dom.user_message",
                          status: .pass, gating: true,
                          metrics: ["prompt": turn.prompt],
                          threshold: simG1Threshold("g1_web_user_message_submitted", measured: 1),
                          detail: "the page submitted this run's nonce prompt into its own session")

            // MARK: Wait for the real Worker tool result
            let turnStart = Date()
            try await simWait(timeout: 300, label: "session JSONL with the bash result") {
                guard let evidence = try self.loadNewBashLog(workspace: workspace,
                                                             baseline: sessionBaseline,
                                                             turn: turn) else {
                    return false
                }
                return evidence.trace.resultText.contains(turn.textContent)
                    && evidence.trace.resultText.contains(turn.marker)
                    && evidence.trace.resultText.contains("writable roots")
            }
            report.addPhase("bash_tool_turn", milliseconds: Self.ms(since: turnStart))
            guard let evidence = try loadNewBashLog(workspace: workspace,
                                                    baseline: sessionBaseline,
                                                    turn: turn) else {
                throw SimError.artifact("the session JSONL has no new bash tool call/result "
                    + "for this run's nonce beyond the pre-prompt baseline")
            }
            let initialLog = evidence.log
            let initialTrace = evidence.trace
            let sessionID = initialLog.sessionID
            report.set("session_id", sessionID)
            report.set("session_jsonl", initialLog.url.path)
            let initialToolTrace: [String: Any] = [
                "call_id": initialTrace.callID,
                "call_seq": initialTrace.callSeq,
                "result_seq": initialTrace.resultSeq,
                "marker": turn.marker,
                "text": turn.textContent,
            ]
            report.set("initial_tool_trace", initialToolTrace)

            // The page must show the same call and result. A standard Bash
            // row is mounted as soon as the page sees the call, including its
            // non-expandable `preparing` phase, and a settled row starts
            // collapsed with its output body lazily mounted. Waiting for the
            // row alone would therefore accept a row whose body was never
            // opened. Wait for this exact callId in this Session to settle and
            // become expandable, click the row's own aria disclosure control,
            // then require the expanded body. The text comes from the page's
            // own conversation projection, not from a test string.
            do {
                try await simWait(timeout: 180, label: "settled expandable DOM bash tool row") {
                    let observation = try await self.bashRowObservation(
                        realEngine, callID: initialTrace.callID, sessionID: sessionID)
                    guard Self.anyBool(observation["call_id_match"]) == true,
                          Self.anyBool(observation["session_match"]) == true,
                          (observation["sample_type"] as? String) == "bash",
                          Self.anyBool(observation["visible"]) == true,
                          Self.anyBool(observation["expandable"]) == true,
                          let state = observation["state"] as? String,
                          state == "ok" || state == "error" || state == "stopped"
                    else { return false }
                    if Self.anyBool(observation["expanded"]) == true { return true }
                    _ = try await self.clickBashRow(realEngine,
                                                    callID: initialTrace.callID,
                                                    sessionID: sessionID)
                    let opened = try await self.bashRowObservation(
                        realEngine, callID: initialTrace.callID, sessionID: sessionID)
                    return Self.anyBool(opened["expanded"]) == true
                }
            } catch {
                if let observation = try? await self.bashRowObservation(
                    realEngine, callID: initialTrace.callID, sessionID: sessionID) {
                    report.set("dom_bash_row_timeout", observation)
                }
                throw error
            }
            let domCallID = try await domBashCallID(realEngine,
                                                    callID: initialTrace.callID) ?? ""
            let rowObservation = try await bashRowObservation(
                realEngine, callID: initialTrace.callID, sessionID: sessionID)
            report.set("dom_bash_row", rowObservation)
            do {
                try await simWait(timeout: 120, label: "DOM tool output") {
                    let observation = try await self.bashRowObservation(
                        realEngine, callID: initialTrace.callID, sessionID: sessionID)
                    if Self.anyBool(observation["expandable"]) == true,
                       Self.anyBool(observation["expanded"]) != true,
                       Self.anyBool(observation["session_match"]) == true {
                        _ = try await self.clickBashRow(realEngine,
                                                        callID: initialTrace.callID,
                                                        sessionID: sessionID)
                    }
                    let text = try await self.domBashToolText(realEngine,
                                                              callID: initialTrace.callID)
                    return text.contains(turn.textContent)
                        && text.contains(turn.marker)
                        && text.contains("writable roots")
                }
            } catch {
                if let observation = try? await self.bashRowObservation(
                    realEngine, callID: initialTrace.callID, sessionID: sessionID) {
                    var diagnostic = observation
                    let text = (try? await self.domBashToolText(
                        realEngine, callID: initialTrace.callID)) ?? ""
                    diagnostic["contains_turn_text"] = text.contains(turn.textContent)
                    diagnostic["contains_png_marker"] = text.contains(turn.marker)
                    diagnostic["contains_refusal"] = text.contains("writable roots")
                    report.set("dom_bash_row_output_timeout", diagnostic)
                }
                throw error
            }
            let domToolText = try await domBashToolText(realEngine,
                                                        callID: initialTrace.callID)
            let rowAfterOutput = try await bashRowObservation(
                realEngine, callID: initialTrace.callID, sessionID: sessionID)
            report.set("dom_bash_row_after_output", rowAfterOutput)
            report.set("dom_call_id", domCallID)
            report.set("dom_tool_text", domToolText)
            try require(report, "dom.tool",
                        domCallID == initialTrace.callID
                            && Self.anyBool(rowObservation["session_match"]) == true
                            && Self.anyBool(rowObservation["expanded"]) == true
                            && domToolText.contains(turn.textContent)
                            && domToolText.contains(turn.marker)
                            && domToolText.contains("writable roots"),
                        metrics: ["call_id": domCallID,
                                  "expected_call_id": initialTrace.callID,
                                  "row_state": rowObservation["state"] ?? "",
                                  "row_expanded": Self.anyBool(rowObservation["expanded"]) ?? false,
                                  "row_session_match": Self.anyBool(rowObservation["session_match"]) ?? false,
                                  "contains_turn_text": domToolText.contains(turn.textContent),
                                  "contains_png_marker": domToolText.contains(turn.marker),
                                  "contains_refusal": domToolText.contains("writable roots")],
                        detail: "the Web tool row shows the same callId in the selected Session, "
                            + "its real aria disclosure is expanded, and the body carries this run's "
                            + "PNG-write marker and real bash stdout/refusal")

            // MARK: Assistant text follows the tool result
            try await simWait(timeout: 180, label: "DOM assistant final text") {
                let text = try await self.assistantText(realEngine)
                return text.contains("Done \(turn.nonce)")
                    && text.contains(turn.textName) && text.contains(turn.imageName)
            }
            let assistantFinalText = try await self.assistantText(realEngine)
            report.set("dom_assistant_text", assistantFinalText)
            try require(report, "dom.assistant",
                        assistantFinalText.contains("Done \(turn.nonce)")
                            && assistantFinalText.contains(turn.textName)
                            && assistantFinalText.contains(turn.imageName),
                        metrics: ["text": assistantFinalText],
                        detail: "the page rendered this run's unique assistant text after the real tool result")

            // The durable assistant message must carry the same nonce and a
            // real message id; an older identical-looking answer is rejected.
            try await simWait(timeout: 180, label: "session JSONL assistant message") {
                guard let log = try self.loadSessionLog(workspace: workspace,
                                                        sessionID: sessionID) else {
                    return false
                }
                return self.assistantMessage(log.events, turn: turn) != nil
            }
            guard let assistantLog = try loadSessionLog(workspace: workspace,
                                                        sessionID: sessionID),
                  let assistantEvidence = assistantMessage(assistantLog.events, turn: turn) else {
                throw SimError.artifact("the session JSONL has no assistant message "
                    + "for this run's nonce")
            }
            report.set("assistant_message_id", assistantEvidence.messageID)
            try require(report, "native.assistant",
                        !assistantEvidence.messageID.isEmpty
                            && assistantEvidence.text.contains("Done \(turn.nonce)")
                            && assistantEvidence.text.contains(turn.textName)
                            && assistantEvidence.text.contains(turn.imageName),
                        metrics: ["message_id": assistantEvidence.messageID,
                                  "contains_nonce": assistantEvidence.text.contains(turn.nonce),
                                  "contains_text_name": assistantEvidence.text.contains(turn.textName),
                                  "contains_image_name": assistantEvidence.text.contains(turn.imageName)],
                        detail: "the durable assistant message carries this run's nonce and a real message id")

            // MARK: Native session/page + JSONL authority
            let nativeList = try await transport.call("session/list", args: .object([:]))
            let nativeItems = nativeList["items"]?.arrayValue ?? []
            let nativeIDs = nativeItems.compactMap { $0["sessionId"]?.stringValue }
            let nativeSession = nativeItems.first { $0["sessionId"]?.stringValue == sessionID }
            let nativeCwd = nativeSession?["cwd"]?.stringValue ?? ""
            let allLogIDs = try sessionLogIDs(workspace: workspace)
            let expectedLogIDs = Set(logsBefore).union([sessionID]).sorted()
            let newLogIDs = allLogIDs.filter { !logsBefore.contains($0) }
            // A fresh store adds exactly the page's Session; an existing App
            // store resumes/uses that Session without creating another one.
            let journalSessionMatches = allLogIDs == expectedLogIDs
                && (newLogIDs == [sessionID]
                    || (newLogIDs.isEmpty && logsBefore.contains(sessionID)))
            try require(report, "native.session",
                        nativeIDs.contains(sessionID)
                            && journalSessionMatches
                            && nativeCwd == "/dsh/workspace"
                            && hostDiagnostics.state == .running,
                        metrics: ["dom_session_source": "page-created session",
                                  "native_session_ids": nativeIDs.joined(separator: ","),
                                  "journal_session_ids": allLogIDs.joined(separator: ","),
                                  "journal_ids_before": logsBefore.joined(separator: ","),
                                  "session_id": sessionID,
                                  "session_cwd": nativeCwd],
                        detail: "the Web page and the native transport use the same Session id in /dsh/workspace and add no second Session")

            let jsonlEvents = initialLog.events
            let lastSeq = jsonlEvents.map(\.seq).max() ?? 0
            let pageValue = try await transport.call(
                "session/page",
                args: .object(["request": .object([
                    "address": .object(["kind": .string("session"),
                                        "sessionId": .string(sessionID)]),
                    "throughSeq": .number(Double(lastSeq)),
                    "maxMessages": .number(200),
                ])]))
            let pageEvents = Self.events(fromRecords: pageValue["records"]?.arrayValue ?? [])
            guard let pageTrace = bashTrace(pageEvents, turn: turn) else {
                throw SimError.artifact("session/page has no bash call/result for the page session")
            }
            let journalResult = initialTrace.resultText
            let traceMatches = pageTrace.callID == initialTrace.callID
                && pageTrace.callSeq == initialTrace.callSeq
                && pageTrace.resultSeq == initialTrace.resultSeq
                && pageTrace.arguments.contains(turn.textName)
                && pageTrace.arguments.contains(turn.imageName)
                && pageTrace.resultText == journalResult
                && journalResult.contains(turn.textContent)
                && journalResult.contains(turn.marker)
                && journalResult.contains("writable roots")
            report.set("native_tool_trace", [
                "call_id": pageTrace.callID,
                "call_seq": pageTrace.callSeq,
                "result_seq": pageTrace.resultSeq,
                "page_result": pageTrace.resultText,
                "journal_call_id": initialTrace.callID,
                "journal_call_seq": initialTrace.callSeq,
                "journal_result_seq": initialTrace.resultSeq,
                "journal_result": journalResult,
                "result_text_equal": pageTrace.resultText == journalResult,
            ])
            try require(report, "native.tool_trace", traceMatches,
                        metrics: ["call_id": pageTrace.callID,
                                  "call_seq": pageTrace.callSeq,
                                  "result_seq": pageTrace.resultSeq,
                                  "journal_call_seq": initialTrace.callSeq,
                                  "journal_result_seq": initialTrace.resultSeq,
                                  "result_text_equal": pageTrace.resultText == journalResult],
                        detail: "session/page and the materialized session JSONL carry the same seq/callId "
                            + "and this run's unique tool result text")
            try require(report, "native.outside_write",
                        journalResult.contains("writable roots")
                            && !fileManager.fileExists(
                                atPath: workspace.appendingPathComponent("materialized/var/pdsh-outside.txt").path),
                        metrics: ["refusal": journalResult.contains("writable roots"),
                                  "path": "/var/pdsh-outside.txt"],
                        detail: "the real Worker shell refused the write outside /dsh/workspace, /dsh/home and /dsh/tmp")

            // MARK: Permission projection
            let projection = try await transport.call(
                "session/projections",
                args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            let permission = projection["values"]?["permissions"]?["currentValue"]?.stringValue ?? ""
            report.set("permission_preset", permission)
            try require(report, "native.permission", permission == "phone",
                        metrics: ["preset": permission],
                        detail: "the Session projection reports the phone permission preset")

            // MARK: Text and PNG previews, opened by the page's file links
            try await simWait(timeout: 60, label: "\(turn.textName) link in assistant text") {
                try await self.clickFileLink(realEngine, name: turn.textName)
            }
            try await simWait(timeout: 120, label: "text preview body") {
                let text = try await self.evaluateString(realEngine, """
                (() => {
                  const preview = document.querySelector('[data-textpreview-state="text"]');
                  return preview ? (preview.textContent || '') : '';
                })()
                """)
                return text.contains(turn.textContent) && text.contains(turn.textName)
            }
            let textPreview = try await evaluateString(realEngine, """
            (() => {
              const preview = document.querySelector('[data-textpreview-state="text"]');
              return preview ? (preview.textContent || '') : '';
            })()
            """)
            let materializedTextURL = workspace
                .appendingPathComponent("materialized/workspace/\(turn.textName)")
            try await simWait(timeout: 60, label: "materialized \(turn.textName)") {
                fileManager.fileExists(atPath: materializedTextURL.path)
            }
            let materializedText = try String(contentsOf: materializedTextURL,
                                              encoding: .utf8)
            report.set("text_preview", textPreview)
            report.set("materialized_text", materializedText)
            try require(report, "preview.text",
                        textPreview.contains(turn.textContent)
                            && textPreview.contains(turn.textName)
                            && materializedText == turn.textContent,
                        metrics: ["preview_contains_turn_text": textPreview.contains(turn.textContent),
                                  "preview_contains_path": textPreview.contains(turn.textName),
                                  "materialized_bytes": materializedText.utf8.count],
                        detail: "this run's text document preview shows the unique text the Worker wrote")

            try await simWait(timeout: 60, label: "\(turn.imageName) link in assistant text") {
                try await self.clickFileLink(realEngine, name: turn.imageName)
            }
            try await simWait(timeout: 120, label: "image preview ready") {
                let image = try await self.imagePreview(realEngine)
                let alt = image["alt"] as? String ?? ""
                return Self.anyInt(image["width"]) == 1
                    && Self.anyInt(image["height"]) == 1
                    && Self.anyBool(image["blob"]) == true
                    && alt.contains(turn.imageName)
            }
            let image = try await imagePreview(realEngine)
            let materializedImageURL = workspace
                .appendingPathComponent("materialized/workspace/\(turn.imageName)")
            try await simWait(timeout: 60, label: "materialized \(turn.imageName)") {
                fileManager.fileExists(atPath: materializedImageURL.path)
            }
            let materializedImage = try Data(contentsOf: materializedImageURL)
            let expectedImage = turn.pngData
            let materializedImageSHA = Self.sha256Hex(materializedImage)
            let expectedImageSHA = Self.sha256Hex(expectedImage)
            report.set("image_preview", image)
            report.set("materialized_image_bytes", materializedImage.count)
            report.set("materialized_image_sha256", materializedImageSHA)
            let previewAlt = image["alt"] as? String ?? ""
            try require(report, "preview.image",
                        materializedImage == expectedImage
                            && materializedImageSHA == expectedImageSHA
                            && Self.anyInt(image["width"]) == 1
                            && Self.anyInt(image["height"]) == 1
                            && Self.anyBool(image["blob"]) == true
                            && previewAlt.contains(turn.imageName),
                        metrics: ["preview_width": image["width"] ?? 0,
                                  "preview_height": image["height"] ?? 0,
                                  "blob_url": image["blob"] ?? false,
                                  "alt": previewAlt,
                                  "bytes": materializedImage.count,
                                  "expected_bytes": expectedImage.count,
                                  "sha256": materializedImageSHA,
                                  "expected_sha256": expectedImageSHA],
                        detail: "this run's uniquely named pixel preview rendered the exact 1x1 bytes "
                            + "the Worker decoded from this run's nonce PNG")

            // MARK: Background park -> new engine resume (the App's Web path)
            //
            // `WebHostModel.parkHost` calls `host.park()`, then shuts the
            // anchor's WKWebView down and drops `engine`; `resumeHost` calls
            // `host.resume()`, whose `bootRuntime` asks the same engine factory
            // for a *new* WebEngine from the final persistent configuration.
            // PlannedRestart and WebContent recovery reuse the old engine, so
            // only this path proves the persistent store/pinned origin really
            // survive a WKWebView recreation.
            let parkStart = Date()
            let sessionCountBefore = nativeIDs.count
            let engineCountBeforePark = engineSlot.created
            let oldEngine = realEngine
            let originBeforePark = oldEngine.configuration.origin
            try await webHost.park()
            try await simWait(timeout: 120, label: "host parked") {
                await webHost.state != .running
            }
            anchor.shutdown()
            engine = nil
            try await webHost.resume()
            try await simWait(timeout: 240, label: "host Running after park/resume") {
                await webHost.state == .running
            }
            try await simWait(timeout: 240, label: "new engine after park/resume") {
                engineSlot.created > engineCountBeforePark
            }
            guard let resumedEngine = engineSlot.engine,
                  engineSlot.created == engineCountBeforePark + 1,
                  resumedEngine !== oldEngine else {
                throw SimError.assertion(
                    "park/resume did not create exactly one new WebEngine "
                    + "(created \(engineSlot.created), expected \(engineCountBeforePark + 1))")
            }
            realEngine = resumedEngine
            try await simWait(timeout: 240, label: "full Web page after park/resume") {
                realEngine.lastBootStatus?.state == .ready
            }
            report.addPhase("park_resume_new_engine", milliseconds: Self.ms(since: parkStart))
            try await waitForShellAndComposer(realEngine, timeout: 120)
            try await simWait(timeout: 240, label: "same tool callId after park/resume") {
                let id = try await self.domBashCallID(realEngine,
                                                      callID: initialTrace.callID)
                return id == initialTrace.callID
            }
            try await simWait(timeout: 240, label: "same assistant nonce after park/resume") {
                let text = try await self.assistantText(realEngine)
                return text.contains("Done \(turn.nonce)") && text.contains(turn.textName)
            }
            let listAfterPark = try await transport.call("session/list", args: .object([:]))
            let itemsAfterPark = listAfterPark["items"]?.arrayValue ?? []
            let idsAfterPark = itemsAfterPark.compactMap { $0["sessionId"]?.stringValue }
            let cwdAfterPark = itemsAfterPark
                .first { $0["sessionId"]?.stringValue == sessionID }?["cwd"]?.stringValue ?? ""
            let logsAfterPark = try sessionLogIDs(workspace: workspace)
            let journalAfterPark = try loadSessionLog(workspace: workspace,
                                                      sessionID: sessionID)
            let traceAfterPark = journalAfterPark.flatMap { bashTrace($0.events, turn: turn) }
            let pageAfterPark = try await sessionPageBashTrace(
                transport,
                sessionID: sessionID,
                throughSeq: traceAfterPark?.resultSeq ?? lastSeq,
                turn: turn)
            let resumedConfiguration = resumedEngine.configuration
            let enginePersistent =
                resumedEngine.view.configuration.websiteDataStore.isPersistent
            let resumedOrigin = resumedConfiguration.origin
            let resumedOriginFixed = resumedOrigin == originBeforePark
            let textAfterPark = try String(contentsOf: materializedTextURL, encoding: .utf8)
            let imageAfterPark = try Data(contentsOf: materializedImageURL)
            let parkRestored = idsAfterPark == nativeIDs
                && idsAfterPark.count == sessionCountBefore
                && logsAfterPark == expectedLogIDs
                && cwdAfterPark == "/dsh/workspace"
                && Self.isSameTrace(traceAfterPark, as: initialTrace, turn: turn)
                && Self.isSameTrace(pageAfterPark, as: initialTrace, turn: turn)
                && resumedOriginFixed
                && resumedConfiguration.pagePath == Self.fullPagePath
                && resumedConfiguration.usesPersistentWebsiteDataStore
                && enginePersistent
                && textAfterPark == turn.textContent
                && imageAfterPark == expectedImage
            report.set("park_resume", [
                "session_id": sessionID,
                "engines_before": engineCountBeforePark,
                "engines_after": engineSlot.created,
                "engine_recreated": resumedEngine !== oldEngine,
                "origin_before": originBeforePark.absoluteString,
                "origin_after": resumedOrigin.absoluteString,
                "origin_fixed": resumedOriginFixed,
                "persistent_store_actual": enginePersistent,
                "native_session_ids_after": idsAfterPark.joined(separator: ","),
                "journal_session_ids_after": logsAfterPark.joined(separator: ","),
                "session_cwd": cwdAfterPark,
                "call_id": traceAfterPark?.callID ?? "",
                "call_seq": traceAfterPark?.callSeq ?? -1,
                "result_seq": traceAfterPark?.resultSeq ?? -1,
                "page_result": pageAfterPark?.resultText ?? "",
                "text_restored": textAfterPark == turn.textContent,
                "image_restored": imageAfterPark == expectedImage,
            ])
            try require(report, "restart.park_resume", parkRestored,
                        metrics: ["engines_before": engineCountBeforePark,
                                  "engines_after": engineSlot.created,
                                  "origin_fixed": resumedOriginFixed,
                                  "persistent_store_actual": enginePersistent,
                                  "sessions_after": idsAfterPark.count,
                                  "session_cwd": cwdAfterPark,
                                  "call_id": traceAfterPark?.callID ?? "",
                                  "call_seq": traceAfterPark?.callSeq ?? -1,
                                  "result_seq": traceAfterPark?.resultSeq ?? -1,
                                  "result_text_equal":
                                    pageAfterPark?.resultText == initialTrace.resultText,
                                  "text_restored": textAfterPark == turn.textContent,
                                  "image_restored": imageAfterPark == expectedImage],
                        detail: "background park shut the WKWebView down and resume created a second "
                            + "engine on the same pinned origin/persistent store, recovering the same "
                            + "Session id, cwd, callId, seq, tool result, files and page history")

            // MARK: Real WebContent kill and the same Session history
            let killStart = Date()
            let killRequested = try await requestRealWebContentKill(report: report,
                                                                    directory: directory)
            if killRequested {
                try await simWait(timeout: 120, label: "WebContent termination observed") {
                    realEngine.terminationCount >= 1
                }
                try await simWait(timeout: 240, label: "host Running after WebContent kill") {
                    await webHost.state == .running
                }
                try await simWait(timeout: 240, label: "full Web page after WebContent kill") {
                    realEngine.lastBootStatus?.state == .ready
                }
                report.addPhase("webcontent_kill_recovery",
                                milliseconds: Self.ms(since: killStart))
                try await waitForShellAndComposer(realEngine, timeout: 120)
                try await simWait(timeout: 240, label: "same tool callId after WebContent kill") {
                    let id = try await self.domBashCallID(realEngine,
                                                          callID: initialTrace.callID)
                    return id == initialTrace.callID
                }
                let listAfterKill = try await transport.call("session/list", args: .object([:]))
                let idsAfterKill = (listAfterKill["items"]?.arrayValue ?? [])
                    .compactMap { $0["sessionId"]?.stringValue }
                let logsAfterKill = try sessionLogIDs(workspace: workspace)
                let journalAfterKill = try loadSessionLog(workspace: workspace,
                                                          sessionID: sessionID)
                let traceAfterKill = journalAfterKill.flatMap {
                    bashTrace($0.events, turn: turn)
                }
                let pageAfterKill = try await sessionPageBashTrace(
                    transport,
                    sessionID: sessionID,
                    throughSeq: traceAfterKill?.resultSeq ?? lastSeq,
                    turn: turn)
                let killRestored = idsAfterKill == nativeIDs
                    && idsAfterKill.count == sessionCountBefore
                    && logsAfterKill == expectedLogIDs
                    && Self.isSameTrace(traceAfterKill, as: initialTrace, turn: turn)
                    && Self.isSameTrace(pageAfterKill, as: initialTrace, turn: turn)
                report.set("webcontent_kill_restart", [
                    "session_id": sessionID,
                    "terminations": realEngine.terminationCount,
                    "native_session_ids_after": idsAfterKill.joined(separator: ","),
                    "journal_session_ids_after": logsAfterKill.joined(separator: ","),
                    "call_id": traceAfterKill?.callID ?? "",
                    "call_seq": traceAfterKill?.callSeq ?? -1,
                    "result_seq": traceAfterKill?.resultSeq ?? -1,
                    "page_result": pageAfterKill?.resultText ?? "",
                    "result_text_equal": pageAfterKill?.resultText == initialTrace.resultText,
                ])
                try require(report, "restart.webcontent_kill", killRestored,
                            metrics: ["terminations": realEngine.terminationCount,
                                      "sessions_before": sessionCountBefore,
                                      "sessions_after": idsAfterKill.count,
                                      "call_id": traceAfterKill?.callID ?? "",
                                      "call_seq": traceAfterKill?.callSeq ?? -1,
                                      "result_seq": traceAfterKill?.resultSeq ?? -1,
                                      "result_text_equal":
                                        pageAfterKill?.resultText == initialTrace.resultText],
                            detail: "a real SIGKILL of this simulator's WebContent was followed by the same "
                                + "Session id, callId, seq and tool result text")
            }

            // MARK: Host restart and the same Session history
            let restartStart = Date()
            try await webHost.plannedRestart(reason: "web-surface-e2e")
            try await simWait(timeout: 240, label: "host Running after restart") {
                await webHost.state == .running
            }
            try await simWait(timeout: 240, label: "full Web page after restart") {
                realEngine.lastBootStatus?.state == .ready
            }
            report.addPhase("planned_restart", milliseconds: Self.ms(since: restartStart))
            try await waitForShellAndComposer(realEngine, timeout: 120)
            try await simWait(timeout: 240, label: "same tool callId after restart") {
                let id = try await self.domBashCallID(realEngine,
                                                      callID: initialTrace.callID)
                return id == initialTrace.callID
            }
            let listAfter = try await transport.call("session/list", args: .object([:]))
            let idsAfter = (listAfter["items"]?.arrayValue ?? [])
                .compactMap { $0["sessionId"]?.stringValue }
            let logsAfter = try sessionLogIDs(workspace: workspace)
            let journalAfter = try loadSessionLog(workspace: workspace, sessionID: sessionID)
            let traceAfter = journalAfter.flatMap { bashTrace($0.events, turn: turn) }
            let pageAfter = try await sessionPageBashTrace(
                transport,
                sessionID: sessionID,
                throughSeq: traceAfter?.resultSeq ?? lastSeq,
                turn: turn)
            // The restart recreates the page against the same pinned
            // loopback origin; a changed port would lose the Web client's
            // localStorage session selection.
            let originAfterRestart = realEngine.configuration.origin
            let restartOriginFixed = originAfterRestart == servedConfiguration.origin
            let restored = idsAfter == nativeIDs
                && idsAfter.count == sessionCountBefore
                && logsAfter == expectedLogIDs
                && Self.isSameTrace(traceAfter, as: initialTrace, turn: turn)
                && Self.isSameTrace(pageAfter, as: initialTrace, turn: turn)
                && restartOriginFixed
            report.set("restart", [
                "session_id": sessionID,
                "native_session_ids_before": nativeIDs.joined(separator: ","),
                "native_session_ids_after": idsAfter.joined(separator: ","),
                "journal_session_ids_after": logsAfter.joined(separator: ","),
                "origin_before": servedConfiguration.origin.absoluteString,
                "origin_after": originAfterRestart.absoluteString,
                "origin_fixed": restartOriginFixed,
                "call_id": traceAfter?.callID ?? "",
                "call_seq": traceAfter?.callSeq ?? -1,
                "result_seq": traceAfter?.resultSeq ?? -1,
                "page_result": pageAfter?.resultText ?? "",
                "result_text_equal": pageAfter?.resultText == initialTrace.resultText,
            ])
            try require(report, "restart.same_session",
                        restored,
                        metrics: ["sessions_before": nativeIDs.count,
                                  "sessions_after": idsAfter.count,
                                  "origin_fixed": restartOriginFixed,
                                  "call_id": traceAfter?.callID ?? "",
                                  "call_seq": traceAfter?.callSeq ?? -1,
                                  "result_seq": traceAfter?.resultSeq ?? -1,
                                  "result_text_equal":
                                    pageAfter?.resultText == initialTrace.resultText],
                        detail: "the restarted host recovered the same Session id, history, callId, seq, "
                            + "tool result text and pinned page origin")

            // Explicit boundaries of this run.
            report.record("web.model.fixture", status: .pass, gating: true,
                          metrics: ["upstream": "MockModelUpstream",
                                    "tool_execution": "real Worker bash/VFS",
                                    "session": "real Worker session JSONL"],
                          threshold: simG1Threshold("g1_web_scripted_model_loop", measured: 1),
                          detail: "only the model response is scripted; files, shell, bridge, WAL and session are real")
            report.record("web.model.real_api", status: .info, gating: false,
                          metrics: ["status": "NOT_RUN"],
                          threshold: simInfoThreshold("web_real_model_api"),
                          detail: "NOT_RUN: no real model API key is used in this hostless suite")
            if !killRequested {
                report.record("web.restart.webcontent_kill", status: .info, gating: false,
                              metrics: ["status": "NOT_RUN",
                                        "used": "PhoneDSHHost.plannedRestart"],
                              threshold: simInfoThreshold("web_os_webcontent_kill"),
                              detail: "NOT_RUN: scripts/ci/sim.sh did not start the "
                                + "device-scoped WebContent watcher (expect-web-kill is absent); "
                                + "the planned host restart still ran")
            }
            report.set("host_errors", eventLog.hostErrors)
            report.set("harness_errors", eventLog.harnessErrors)
            report.finish(ok: true)
        } catch {
            failure = error
            report.finish(ok: false, failure: String(describing: error))
            report.record("web.failure", status: .fail, gating: true,
                          metrics: ["error": String(describing: error)],
                          threshold: simG1Threshold("g1_web_surface_completed", measured: 0),
                          detail: String(describing: error))
        }

        // MARK: - Teardown
        eventLog.stop()
        if let host {
            try? await host.stop()
        }
        engine?.shutdown()
        window?.shutdown()
        mock.stop()
        report.addConsole(lines: eventLog.tail(50))
        report.set("console_count", eventLog.console.count)
        if let failure {
            print("web-surface: FAILED: \(failure)")
            for line in eventLog.tail(50) { print("web-surface console: \(line)") }
        }
        do {
            try report.write()
        } catch {
            print("web-surface: cannot write web-surface-report.json: \(error)")
        }
        if let failure {
            let tail = eventLog.tail(50).joined(separator: "\n")
            XCTFail("iOS Simulator full-Web session E2E failed: \(failure)\n"
                    + "--- last 50 console lines ---\n\(tail)\n"
                    + "--- report: \(report.fileURL.path) ---")
        }
    }

    // MARK: - Controlled source input boundaries

    /// No explicit selection keeps the canonical pin contract: the actual,
    /// expected and canonical commit/version must agree and the override flag
    /// must be false.
    func testWorkerAssetMetadataCanonicalPinStillPasses() throws {
        let pinCommit = "7be5505b0be06009d74891c869063c9cf19a0df0"
        let version = "0.2.1-rc.2"
        let fixture = try Self.assetFixture(
            pinCommit: pinCommit, pinVersion: version,
            commit: pinCommit, version: version)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata = Self.workerAssetMetadata(fixture.bundle, environment: [:])
        XCTAssertTrue(metadata.passed, metadata.detail)
        XCTAssertEqual(metadata.metrics["source_selection"] as? String, "canonical")
        XCTAssertEqual(metadata.metrics["expected_commit"] as? String, pinCommit)
        XCTAssertEqual(metadata.metrics["expected_overridden"] as? Bool, false)
    }

    /// A controlled checkout selected by the runner is accepted when the Web
    /// page, image, `dsh_expected_*` fields and actual bytes all name it while
    /// the canonical pin stays 7be and the override flag is true.
    func testWorkerAssetMetadataExplicitSelectedSourcePasses() throws {
        let pinCommit = "7be5505b0be06009d74891c869063c9cf19a0df0"
        let selectedCommit = "c63e01d545cbc03f6b59b1f33679c501de590255"
        let version = "0.2.1-rc.2"
        let fixture = try Self.assetFixture(
            pinCommit: pinCommit, pinVersion: version,
            commit: selectedCommit, version: version)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let environment = [
            "TEST_RUNNER_PDSH_DSH_CANONICAL_COMMIT": pinCommit,
            "TEST_RUNNER_PDSH_DSH_CANONICAL_VERSION": version,
            "TEST_RUNNER_PDSH_DSH_SOURCE_COMMIT": selectedCommit,
            "TEST_RUNNER_PDSH_DSH_SOURCE_VERSION": version,
        ]
        let metadata = Self.workerAssetMetadata(fixture.bundle, environment: environment)
        XCTAssertTrue(metadata.passed, metadata.detail)
        XCTAssertEqual(metadata.metrics["source_selection"] as? String, "explicit")
        XCTAssertEqual(metadata.metrics["canonical_input"] as? String, "runner")
        XCTAssertEqual(metadata.metrics["pin_commit"] as? String, pinCommit)
        XCTAssertEqual(metadata.metrics["expected_commit"] as? String, selectedCommit)
        XCTAssertEqual(metadata.metrics["expected_overridden"] as? Bool, true)
        XCTAssertEqual(metadata.metrics["checkout_overridden_match"] as? Bool, true)
    }

    /// The bundle's own `dsh_expected_*` does not define the expected source:
    /// a controlled build naming a different commit than the runner's explicit
    /// selection must fail even though its metadata is internally consistent.
    func testWorkerAssetMetadataRejectsExplicitSourceMismatch() throws {
        let pinCommit = "7be5505b0be06009d74891c869063c9cf19a0df0"
        let selectedCommit = "c63e01d545cbc03f6b59b1f33679c501de590255"
        let otherCommit = String(repeating: "d", count: 40)
        let version = "0.2.1-rc.2"
        let fixture = try Self.assetFixture(
            pinCommit: pinCommit, pinVersion: version,
            commit: selectedCommit, version: version)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let environment = [
            "TEST_RUNNER_PDSH_DSH_CANONICAL_COMMIT": pinCommit,
            "TEST_RUNNER_PDSH_DSH_CANONICAL_VERSION": version,
            "TEST_RUNNER_PDSH_DSH_SOURCE_COMMIT": otherCommit,
            "TEST_RUNNER_PDSH_DSH_SOURCE_VERSION": version,
        ]
        let metadata = Self.workerAssetMetadata(fixture.bundle, environment: environment)
        XCTAssertFalse(metadata.passed, metadata.detail)
        XCTAssertEqual(metadata.metrics["actual_commits_match"] as? Bool, false)
    }

    /// An explicit selection is a commit/version pair. A lone commit must not
    /// fall back to the canonical version or to the bundle's expectation.
    func testWorkerAssetMetadataRejectsExplicitSourceWithoutVersion() throws {
        let pinCommit = "7be5505b0be06009d74891c869063c9cf19a0df0"
        let selectedCommit = "c63e01d545cbc03f6b59b1f33679c501de590255"
        let version = "0.2.1-rc.2"
        let fixture = try Self.assetFixture(
            pinCommit: pinCommit, pinVersion: version,
            commit: selectedCommit, version: version)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata = Self.workerAssetMetadata(
            fixture.bundle,
            environment: [
                "TEST_RUNNER_PDSH_DSH_SOURCE_COMMIT": selectedCommit,
            ])
        XCTAssertFalse(metadata.passed, metadata.detail)
        XCTAssertTrue((metadata.metrics["input_error"] as? String ?? "").contains("version"))
    }

    /// A controlled bundle is not accepted just because it says so: without an
    /// explicit runner selection the canonical pin remains the only expectation.
    func testWorkerAssetMetadataRejectsUndeclaredControlledSource() throws {
        let pinCommit = "7be5505b0be06009d74891c869063c9cf19a0df0"
        let selectedCommit = "c63e01d545cbc03f6b59b1f33679c501de590255"
        let version = "0.2.1-rc.2"
        let fixture = try Self.assetFixture(
            pinCommit: pinCommit, pinVersion: version,
            commit: selectedCommit, version: version)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata = Self.workerAssetMetadata(fixture.bundle, environment: [:])
        XCTAssertFalse(metadata.passed, metadata.detail)
        XCTAssertEqual(metadata.metrics["expected_commit"] as? String, pinCommit)
        XCTAssertEqual(metadata.metrics["checkout_overridden_match"] as? Bool, false)
    }

    // MARK: - DOM interaction

    private func waitForShellAndComposer(_ engine: WebEngine,
                                         timeout: TimeInterval) async throws {
        try await simWait(timeout: timeout, label: "page shell overlay") {
            try await self.evaluateBool(engine, "!!document.querySelector('[data-shell-overlay]')")
        }
        try await simWait(timeout: timeout, label: "page composer") {
            try await self.evaluateBool(engine, "!!document.querySelector('[data-composer-input]')")
        }
        // A reload restores the persisted session selection from localStorage,
        // so give that path time before falling back to New Session. Clicking
        // early would create an empty Session while the old one is restoring.
        do {
            try await simWait(timeout: 20, label: "editable composer after restore") {
                try await self.composerEditable(engine)
            }
            return
        } catch {
            // No restored/editable session: use the page's own New Session.
        }
        // The page may still be in its first-use workspace flow. A New Session
        // gesture is the page's own path; it creates no second session store.
        let clicked = try await clickNewSession(engine)
        if clicked {
            try await simWait(timeout: timeout, label: "editable composer after New Session") {
                try await self.composerEditable(engine)
            }
            return
        }
        try await simWait(timeout: timeout, label: "editable composer") {
            try await self.composerEditable(engine)
        }
    }

    /// The composer must be visible, editable and bound to a Session before it
    /// is ready for input. `waitForShellAndComposer` polls this instead of a
    /// single `contenteditable` sample, because the page can keep the resident
    /// surface editable while its seat is still hidden during settling.
    private func composerEditable(_ engine: WebEngine) async throws -> Bool {
        try await evaluateBool(engine, """
        (() => {
          const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
          const input = inputs.find(node => {
            if (node.getAttribute('contenteditable') !== 'true') return false;
            const rect = node.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          }) ?? inputs.find(node => node.getAttribute('contenteditable') === 'true') ?? null;
          if (input === null) return false;
          const rect = input.getBoundingClientRect();
          const style = window.getComputedStyle(input);
          const conversation = input.closest('[data-conversation-session]');
          const session = conversation === null
            ? ''
            : (conversation.getAttribute('data-conversation-session') || '');
          return input.getAttribute('contenteditable') === 'true'
            && input.isContentEditable === true
            && rect.width > 0 && rect.height > 0
            && style.display !== 'none' && style.visibility !== 'hidden'
            && session.length > 0;
        })()
        """)
    }

    private func clickNewSession(_ engine: WebEngine) async throws -> Bool {
        try await evaluateBool(engine, #"""
        (() => {
          const labels = ['New session', 'New conversation', '新建会话', '新建对话'];
          const buttons = Array.from(document.querySelectorAll('button'));
          const button = buttons.find(node => {
            const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
            return labels.includes(label) && !node.disabled;
          });
          if (!button) return false;
          button.click();
          return true;
        })()
        """#)
    }

    private func userRowVisible(_ engine: WebEngine, nonce: String) async throws -> Bool {
        let literal = try JSONEncoder().encode(nonce)
        let nonceLiteral = String(data: literal, encoding: .utf8) ?? "\"\""
        return try await evaluateBool(engine, """
        (() => {
          const nonce = \(nonceLiteral);
          return Array.from(document.querySelectorAll('[data-chat-flow-kind="user"]'))
            .some(node => (node.textContent || '').includes(nonce));
        })()
        """)
    }

    /// Waits for the page's own enabled Send control and clicks it. The page
    /// re-renders the draft on a later React task after the paste commit, so an
    /// immediate click could still hit the disabled button; polling the real
    /// control avoids both a false send and a synthetic submission.
    private func clickSend(_ engine: WebEngine, timeout: TimeInterval = 60) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let label = try await evaluateString(engine, #"""
            (() => {
              const labels = ['发送消息', 'Send message', '排队发送', 'Queue message',
                              '插话发送', 'Steer message'];
              const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
              const input = inputs.find(node =>
                node.getAttribute('contenteditable') === 'true'
                  && node.getClientRects().length > 0)
                ?? inputs.find(node => node.getAttribute('contenteditable') === 'true')
                ?? null;
              const card = input === null
                ? document.querySelector('[data-composer-card]')
                : input.closest('[data-composer-card]');
              if (card === null) return '';
              const send = Array.from(card.querySelectorAll('button')).find(button => {
                const label = (button.getAttribute('aria-label') || '').trim();
                return labels.includes(label) && !button.disabled;
              });
              if (!send) return '';
              send.click();
              return (send.getAttribute('aria-label') || '').trim();
            })()
            """#)
            if !label.isEmpty { return label }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return ""
    }

    /// Reads the exact bash row for this run's callId and Session. A standard
    /// DSH row is mounted in `preparing` before it becomes expandable, and a
    /// settled row starts collapsed with its output body lazily mounted; row
    /// presence alone is therefore not evidence that the body can be read.
    private func bashRowObservation(_ engine: WebEngine, callID: String,
                                    sessionID: String) async throws -> [String: Any] {
        let literal = try JSONEncoder().encode(callID)
        let callIDLiteral = String(data: literal, encoding: .utf8) ?? "\"\""
        let sessionLiteral = try JSONEncoder().encode(sessionID)
        let sessionIDLiteral = String(data: sessionLiteral, encoding: .utf8) ?? "\"\""
        return try await evaluateJSON(engine, """
        (() => {
          const callId = \(callIDLiteral);
          const expectedSession = \(sessionIDLiteral);
          // A keyed bash line is the ToolCallTree root carrying
          // data-chat-call-id; its only bash-specific marker is the inner
          // data-sample row. `data-tool` belongs to a different (generic)
          // row and is never present here.
          const rows = Array.from(document.querySelectorAll('[data-chat-call-id]'));
          const callRows = rows.filter(node =>
            (node.getAttribute('data-chat-call-id') || '') === callId);
          const row = callRows.find(node => node.querySelector('[data-sample="bash"]')) || null;
          const sample = row === null ? null : row.querySelector('[data-sample="bash"]');
          const conversation = row === null ? null : row.closest('[data-conversation-session]');
          const selected = conversation === null
            ? ''
            : (conversation.getAttribute('data-conversation-session') || '');
          const rect = sample === null ? null : sample.getBoundingClientRect();
          const style = sample === null ? null : window.getComputedStyle(sample);
          return {
            row_count: rows.length,
            call_id_rows: callRows.length,
            call_id_match: row !== null,
            sample_count: row === null ? 0 : row.querySelectorAll('[data-sample="bash"]').length,
            sample_type: sample === null ? '' : (sample.getAttribute('data-sample') || ''),
            state: sample === null ? '' : (sample.getAttribute('data-state') || ''),
            expandable: sample !== null && sample.getAttribute('data-expandable') === 'true',
            expanded: sample !== null && sample.getAttribute('aria-expanded') === 'true',
            visible: rect !== null && rect.width > 0 && rect.height > 0
              && style.display !== 'none' && style.visibility !== 'hidden',
            selected_session: selected,
            session_match: selected !== '' && selected === expectedSession
          };
        })()
        """)
    }

    /// Clicks the exact visible row's own aria disclosure control. Only an
    /// expandable, collapsed row in this run's Session is touched; the helper
    /// never writes `aria-expanded`, textContent or a React store directly.
    private func clickBashRow(_ engine: WebEngine, callID: String,
                              sessionID: String) async throws -> Bool {
        let literal = try JSONEncoder().encode(callID)
        let callIDLiteral = String(data: literal, encoding: .utf8) ?? "\"\""
        let sessionLiteral = try JSONEncoder().encode(sessionID)
        let sessionIDLiteral = String(data: sessionLiteral, encoding: .utf8) ?? "\"\""
        return try await evaluateBool(engine, """
        (() => {
          const callId = \(callIDLiteral);
          const expectedSession = \(sessionIDLiteral);
          const row = Array.from(document.querySelectorAll('[data-chat-call-id]'))
            .find(node => (node.getAttribute('data-chat-call-id') || '') === callId
              && node.querySelector('[data-sample="bash"]')
              && node.closest('[data-conversation-session]') !== null
              && (node.closest('[data-conversation-session]')
                    .getAttribute('data-conversation-session') || '') === expectedSession);
          if (row === null) return false;
          const sample = row.querySelector('[data-sample="bash"]');
          if (sample === null || sample.getAttribute('data-expandable') !== 'true'
              || sample.getAttribute('aria-expanded') === 'true') return false;
          const rect = sample.getBoundingClientRect();
          const style = window.getComputedStyle(sample);
          if (!(rect.width > 0 && rect.height > 0
                && style.display !== 'none' && style.visibility !== 'hidden')) return false;
          sample.click();
          return true;
        })()
        """)
    }

    private func domBashCallID(_ engine: WebEngine, callID: String) async throws -> String? {
        let literal = try JSONEncoder().encode(callID)
        let callIDLiteral = String(data: literal, encoding: .utf8) ?? "\"\""
        let value = try await evaluateString(engine, """
        (() => {
          const callId = \(callIDLiteral);
          const row = Array.from(document.querySelectorAll('[data-chat-call-id]'))
            .find(node => (node.getAttribute('data-chat-call-id') || '') === callId
                          && node.querySelector('[data-sample="bash"]'));
          return row ? (row.getAttribute('data-chat-call-id') || '') : '';
        })()
        """)
        return value.isEmpty ? nil : value
    }

    private func domBashToolText(_ engine: WebEngine, callID: String) async throws -> String {
        let literal = try JSONEncoder().encode(callID)
        let callIDLiteral = String(data: literal, encoding: .utf8) ?? "\"\""
        return try await evaluateString(engine, """
        (() => {
          const callId = \(callIDLiteral);
          const row = Array.from(document.querySelectorAll('[data-chat-call-id]'))
            .find(node => (node.getAttribute('data-chat-call-id') || '') === callId
                          && node.querySelector('[data-sample="bash"]'));
          return row ? (row.textContent || '') : '';
        })()
        """)
    }

    private func assistantText(_ engine: WebEngine) async throws -> String {
        try await evaluateString(engine, """
        (() => {
          return Array.from(document.querySelectorAll('[data-chat-flow-kind="assistant-step"]'))
            .map(node => node.textContent || '').join('\\n');
        })()
        """)
    }

    private func clickFileLink(_ engine: WebEngine, name: String) async throws -> Bool {
        let literal = try JSONEncoder().encode(name)
        let nameLiteral = String(data: literal, encoding: .utf8) ?? "\"\""
        return try await evaluateBool(engine, """
        (() => {
          const name = \(nameLiteral);
          const nodes = Array.from(document.querySelectorAll(
            '[data-chat-flow-kind="assistant-step"] button, ' +
            '[data-chat-flow-kind="assistant-step"] a'));
          const match = nodes.find(node => (node.textContent || '').trim() === name);
          if (!match) return false;
          match.click();
          return true;
        })()
        """)
    }

    private func imagePreview(_ engine: WebEngine) async throws -> [String: Any] {
        let value = try await evaluateJSON(engine, """
        (() => {
          const image = document.querySelector('[data-image-preview] img');
          if (!image) return { present: false };
          return {
            present: true,
            complete: image.complete === true,
            width: image.naturalWidth || 0,
            height: image.naturalHeight || 0,
            blob: (image.src || '').startsWith('blob:'),
            alt: image.alt || ''
          };
        })()
        """)
        return value
    }

    private func evaluateJSON(_ engine: WebEngine, _ script: String) async throws -> [String: Any] {
        let value = try await engine.view.evaluateJavaScript(script)
        return value as? [String: Any] ?? [:]
    }

    /// WKWebView bridges JS numbers as `NSNumber`; accept both spellings.
    private nonisolated static func anyInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private nonisolated static func anyBool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }

    private nonisolated static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        return object
    }

    /// Verifies that the staged Web page and Worker image both name the same
    /// DSH source selected for this build, and that the page's recorded hashes
    /// match the bytes actually inside this app bundle.
    ///
    /// The canonical `plugins/dsh-pin.json` pair and the explicitly selected
    /// controlled checkout pair are *inputs*, not facts read back from the
    /// bundle being inspected. `scripts/ci/sim.sh` supplies both sides through
    /// the XCTest runner environment after it has resolved the pin and, for a
    /// controlled run, checked the clean checkout HEAD/version. A direct
    /// `xcodebuild test` must pass the same variables (see `sim.sh`).
    ///
    /// With no explicit selection the canonical pin is accepted, but every
    /// recorded actual/expected commit and version must still equal it and the
    /// override flag must be false. With an explicit selection the expected
    /// actual/expected pair comes from the runner input; the canonical pin is
    /// still checked independently and `dsh_checkout_overridden` must be true
    /// exactly when the selected pair differs from it. A bundle cannot make a
    /// mismatched or undeclared override pass by naming its own expectation.
    private nonisolated static func workerAssetMetadata(
        _ bundle: PhoneDSHBundleLocation,
        environment: [String: String])
        -> (passed: Bool, metrics: [String: Any], detail: String) {
        let fileManager = FileManager.default
        let web = bundle.staticDirectory.appendingPathComponent("web", isDirectory: true)
        let webBuild = jsonObject(at: web.appendingPathComponent("web-build.json"))
        let sizes = jsonObject(at: bundle.staticDirectory.appendingPathComponent("sizes.json"))
        let probe = jsonObject(at: bundle.staticDirectory.appendingPathComponent("probe-bundle.json"))

        let webCommit = webBuild?["commit"] as? String ?? ""
        let webPackageVersion = webBuild?["version"] as? String ?? ""
        let webDshVersion = webBuild?["dsh_version"] as? String ?? ""
        let entryRel = webBuild?["entry"] as? String ?? ""
        let indexPathName = webBuild?["index"] as? String ?? "index.html"
        let entrySafe = !entryRel.isEmpty
            && !entryRel.hasPrefix("/")
            && !entryRel.split(separator: "/").contains(where: { String($0) == ".." })
        let indexSafe = !indexPathName.isEmpty
            && !indexPathName.hasPrefix("/")
            && !indexPathName.split(separator: "/").contains(where: { String($0) == ".." })
        let entryURL = web.appendingPathComponent(entryRel)
        let indexPath = web.appendingPathComponent(indexPathName)
        let indexSHA = (try? Data(contentsOf: indexPath)).map(sha256Hex) ?? ""
        let entrySHA = entrySafe
            ? ((try? Data(contentsOf: entryURL)).map(sha256Hex) ?? "")
            : ""

        let bundlePinCommit = sizes?["dsh_pin_commit"] as? String ?? ""
        let bundlePinVersion = sizes?["dsh_pin_version"] as? String ?? ""
        let workerCommit = sizes?["dsh_commit"] as? String ?? ""
        let workerVersion = sizes?["dsh_version"] as? String ?? ""
        let recordedExpectedCommit = sizes?["dsh_expected_commit"] as? String ?? ""
        let recordedExpectedVersion = sizes?["dsh_expected_version"] as? String ?? ""
        let webOverriddenInput = anyBool(webBuild?["dsh_checkout_overridden"])
        let imageOverriddenInput = anyBool(sizes?["dsh_checkout_overridden"])
        let recordedIndexSHA = webBuild?["index_sha256"] as? String ?? ""
        let recordedEntrySHA = webBuild?["entry_sha256"] as? String ?? ""
        let gzipBytes = (sizes?["gzip_bytes"] as? NSNumber)?.intValue ?? -1
        let imageSize = ((try? fileManager.attributesOfItem(
            atPath: bundle.imageArchive.path))?[.size] as? NSNumber)?.intValue ?? -1
        let probeSource = probe?["source"] as? String ?? ""
        let jscPrelude = anyBool(probe?["jsc_prelude"]) ?? false
        let probeWeb = probe?["web"] as? [String: Any] ?? [:]
        let probeImage = probe?["image"] as? [String: Any] ?? [:]

        // The canonical pin is an independent input when the runner supplies
        // it. A direct invocation without it falls back to the pin recorded in
        // sizes.json, which is still checked against web-build.json below.
        let runnerCanonicalCommit = inputValue("PDSH_DSH_CANONICAL_COMMIT",
                                               environment: environment)
        let runnerCanonicalVersion = inputValue("PDSH_DSH_CANONICAL_VERSION",
                                                environment: environment)
        let canonicalSelected = runnerCanonicalCommit != nil || runnerCanonicalVersion != nil
        let canonicalPairComplete = runnerCanonicalCommit != nil && runnerCanonicalVersion != nil
        let canonicalCommit = runnerCanonicalCommit ?? bundlePinCommit
        let canonicalVersion = runnerCanonicalVersion ?? bundlePinVersion
        let canonicalValid = isFullCommit(canonicalCommit) && !canonicalVersion.isEmpty
        let bundlePinMatches = bundlePinCommit == canonicalCommit
            && bundlePinVersion == canonicalVersion

        // An explicit controlled source is a pair. If either half is present,
        // the other is required; the bundle's own dsh_expected_* fields are
        // only compared against this runner input, never used as its source.
        let sourceCommitInput = inputValue("PDSH_DSH_SOURCE_COMMIT",
                                           environment: environment)
        let sourceVersionInput = inputValue("PDSH_DSH_SOURCE_VERSION",
                                            environment: environment)
        let explicitSelection = sourceCommitInput != nil || sourceVersionInput != nil
        let sourcePairComplete = sourceCommitInput != nil && sourceVersionInput != nil
        let expectedCommit = explicitSelection ? (sourceCommitInput ?? "") : canonicalCommit
        let expectedVersion = explicitSelection ? (sourceVersionInput ?? "") : canonicalVersion
        let expectedValid = isFullCommit(expectedCommit) && !expectedVersion.isEmpty
        let expectedOverridden = expectedCommit != canonicalCommit
            || expectedVersion != canonicalVersion

        let inputError: String
        if canonicalSelected && !canonicalPairComplete {
            inputError = "the canonical DSH source input must supply commit and version together"
        } else if !canonicalValid {
            inputError = "the canonical DSH source input needs a 40-character lowercase commit "
                + "and a non-empty version"
        } else if explicitSelection && !sourcePairComplete {
            inputError = "an explicitly selected DSH source needs both source commit and version"
        } else if !expectedValid {
            inputError = "the selected DSH source needs a 40-character lowercase commit "
                + "and a non-empty version"
        } else {
            inputError = ""
        }

        let webPinMatches = (webBuild?["dsh_pin_commit"] as? String ?? "") == canonicalCommit
            && (webBuild?["dsh_pin_version"] as? String ?? "") == canonicalVersion
        let workerPinMatches = (sizes?["dsh_pin_commit"] as? String ?? "") == canonicalCommit
            && (sizes?["dsh_pin_version"] as? String ?? "") == canonicalVersion
        let actualCommitsMatch = webCommit == expectedCommit
            && workerCommit == expectedCommit
            && recordedExpectedCommit == expectedCommit
        let versionsMatch = webPackageVersion == expectedVersion
            && webDshVersion == expectedVersion
            && workerVersion == expectedVersion
            && recordedExpectedVersion == expectedVersion
        let overrideMatches = webOverriddenInput == expectedOverridden
            && imageOverriddenInput == expectedOverridden
        let probeMatches = (probeWeb["commit"] as? String ?? "") == expectedCommit
            && (probeWeb["dsh_version"] as? String ?? "") == expectedVersion
            && (probeImage["commit"] as? String ?? "") == expectedCommit
            && (probeImage["dsh_version"] as? String ?? "") == expectedVersion
            && (probeImage["expected_commit"] as? String ?? "") == expectedCommit
            && (probeImage["expected_version"] as? String ?? "") == expectedVersion
            && (probeImage["pin_commit"] as? String ?? "") == canonicalCommit
            && (probeImage["pin_version"] as? String ?? "") == canonicalVersion
        let indexMatches = indexSafe
            && !recordedIndexSHA.isEmpty && recordedIndexSHA == indexSHA
        let entryMatches = entrySafe
            && !recordedEntrySHA.isEmpty && recordedEntrySHA == entrySHA
        let imageMatches = gzipBytes > 0 && imageSize == gzipBytes
        let sameSource = inputError.isEmpty
            && bundlePinMatches && webPinMatches && workerPinMatches
            && actualCommitsMatch && versionsMatch && overrideMatches
            && indexMatches && entryMatches && imageMatches
            && probeMatches
            && probeSource == "plugins/scripts/pack-image.mjs" && jscPrelude
        let metrics: [String: Any] = [
            "source_selection": explicitSelection ? "explicit" : "canonical",
            "source_input": explicitSelection ? "runner" : "bundle-pin",
            "canonical_input": canonicalSelected ? "runner" : "bundle-pin",
            "input_error": inputError,
            "web_commit": webCommit,
            "web_package_version": webPackageVersion,
            "web_version": webDshVersion,
            "worker_commit": workerCommit,
            "worker_version": workerVersion,
            "pin_commit": bundlePinCommit,
            "pin_version": bundlePinVersion,
            "canonical_commit": canonicalCommit,
            "canonical_version": canonicalVersion,
            "expected_commit": expectedCommit,
            "expected_version": expectedVersion,
            "expected_overridden": expectedOverridden,
            "checkout_overridden": imageOverriddenInput ?? false,
            "web_checkout_overridden": webOverriddenInput ?? false,
            "checkout_overridden_match": overrideMatches,
            "pin_matches": bundlePinMatches && webPinMatches && workerPinMatches,
            "actual_commits_match": actualCommitsMatch,
            "versions_match": versionsMatch,
            "probe_matches": probeMatches,
            "index_sha256": indexSHA,
            "recorded_index_sha256": recordedIndexSHA,
            "index_sha256_match": indexMatches,
            "entry": entryRel,
            "entry_sha256": entrySHA,
            "recorded_entry_sha256": recordedEntrySHA,
            "entry_sha256_match": entryMatches,
            "image_bytes": imageSize,
            "sizes_gzip_bytes": gzipBytes,
            "image_bytes_match": imageMatches,
            "probe_source": probeSource,
            "jsc_prelude": jscPrelude,
        ]
        let detail: String
        if !inputError.isEmpty {
            detail = "invalid DSH source input: \(inputError)"
        } else {
            detail = "the installed Web page and Worker image match the "
                + "\(explicitSelection ? "explicitly selected" : "canonical") DSH source "
                + "\(expectedCommit) (\(expectedVersion)), retain canonical pin "
                + "\(canonicalCommit) (\(canonicalVersion)), record override="
                + "\(expectedOverridden), and their index/entry sha256 and image bytes "
                + "match the staged files"
        }
        return (sameSource, metrics, detail)
    }

    /// Reads a runner input with or without the `TEST_RUNNER_` prefix. The
    /// simctl fallback exports the bare name through `SIMCTL_CHILD_`.
    private nonisolated static func inputValue(_ name: String,
                                               environment: [String: String]) -> String? {
        for key in ["TEST_RUNNER_\(name)", name] {
            if let value = environment[key], !value.isEmpty { return value }
        }
        return nil
    }

    private nonisolated static func isFullCommit(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    /// Small on-disk Web/image metadata fixture for the input-boundary tests.
    /// It hashes the same bytes it writes, so a successful case exercises the
    /// real `workerAssetMetadata` comparison instead of a stubbed boolean.
    private struct AssetFixture {
        let root: URL
        let bundle: PhoneDSHBundleLocation
    }

    private nonisolated static func assetFixture(
        pinCommit: String,
        pinVersion: String,
        commit: String,
        version: String,
        expectedCommit: String? = nil,
        expectedVersion: String? = nil,
        webOverridden: Bool? = nil,
        imageOverridden: Bool? = nil) throws -> AssetFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "pdsh-asset-source-\(UUID().uuidString)", isDirectory: true)
        let web = root.appendingPathComponent("web", isDirectory: true)
        let assets = web.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

        let indexData = Data("<html>fixture \(commit)</html>".utf8)
        let entryData = Data("console.log('fixture \(commit)')\n".utf8)
        let imageData = Data(repeating: 0x5a, count: 128)
        try indexData.write(to: web.appendingPathComponent("index.html"), options: .atomic)
        try entryData.write(to: assets.appendingPathComponent("entry.js"), options: .atomic)
        try imageData.write(to: root.appendingPathComponent("image.tar.gz"), options: .atomic)

        let indexSHA = sha256Hex(indexData)
        let entrySHA = sha256Hex(entryData)
        let recordedExpectedCommit = expectedCommit ?? commit
        let recordedExpectedVersion = expectedVersion ?? version
        let actualOverride = commit != pinCommit || version != pinVersion
        let recordedWebOverride = webOverridden ?? actualOverride
        let recordedImageOverride = imageOverridden ?? actualOverride

        let webBuild: [String: Any] = [
            "source": "apps/web/dist",
            "package": "@deepseek-ai/dsh-web-frontend",
            "version": version,
            "dsh_version": version,
            "commit": commit,
            "dsh_pin_commit": pinCommit,
            "dsh_pin_version": pinVersion,
            "dsh_checkout_overridden": recordedWebOverride,
            "command": "fixture",
            "entry": "assets/entry.js",
            "entry_sha256": entrySHA,
            "index": "index.html",
            "index_sha256": indexSHA,
            "vite_base": "./",
        ]
        let sizes: [String: Any] = [
            "raw_bytes": 256,
            "gzip_bytes": imageData.count,
            "files": 1,
            "dsh_commit": commit,
            "dsh_version": version,
            "dsh_pin_commit": pinCommit,
            "dsh_pin_version": pinVersion,
            "dsh_expected_commit": recordedExpectedCommit,
            "dsh_expected_version": recordedExpectedVersion,
            "dsh_checkout_overridden": recordedImageOverride,
            "dsh_checkout": "/fixture/checkout",
        ]
        let probe: [String: Any] = [
            "source": "plugins/scripts/pack-image.mjs",
            "jsc_prelude": true,
            "web": [
                "record": "web/web-build.json",
                "commit": commit,
                "dsh_version": version,
                "entry": "assets/entry.js",
                "entry_sha256": entrySHA,
                "index_sha256": indexSHA,
            ] as [String: Any],
            "image": [
                "record": "sizes.json",
                "commit": commit,
                "dsh_version": version,
                "pin_commit": pinCommit,
                "pin_version": pinVersion,
                "expected_commit": recordedExpectedCommit,
                "expected_version": recordedExpectedVersion,
                "checkout_overridden": recordedImageOverride,
            ] as [String: Any],
        ]
        try writeFixtureJSON(webBuild, to: web.appendingPathComponent("web-build.json"))
        try writeFixtureJSON(sizes, to: root.appendingPathComponent("sizes.json"))
        try writeFixtureJSON(probe, to: root.appendingPathComponent("probe-bundle.json"))
        return AssetFixture(
            root: root,
            bundle: PhoneDSHBundleLocation(staticDirectory: root))
    }

    private nonisolated static func writeFixtureJSON(_ object: [String: Any],
                                                      to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func evaluateString(_ engine: WebEngine, _ script: String) async throws -> String {
        let value = try await engine.view.evaluateJavaScript(script)
        return value as? String ?? ""
    }

    private func evaluateBool(_ engine: WebEngine, _ script: String) async throws -> Bool {
        let value = try await engine.view.evaluateJavaScript(script)
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// GETs one staged static asset through the same loopback origin the page
    /// uses and reports only its status/size (never the token-bearing URL).
    private nonisolated static func servedAsset(origin: URL, path: String,
                                                token: String) async throws
        -> (status: Int, bytes: Int) {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw SimError.environment("the loopback origin is not a URL: \(origin.absoluteString)")
        }
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw SimError.environment("cannot build the served-asset URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data.count)
    }

    /// Renders the live composer's real control state for the report. The
    /// page can keep a resident inert text surface for the no-workspace
    /// state, so read the actual tag/contenteditable/aria-disabled/visibility/
    /// focus/phase/placeholder plus the selected Session, workspace rows and
    /// menu chips instead of assuming a textarea or a `disabled` property.
    private func composerState(_ engine: WebEngine) async throws -> [String: Any] {
        let raw = try await evaluateString(engine, Self.composerStateScript())
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return ["parse_error": raw] }
        return object
    }

    private static func composerStateScript() -> String {
        """
        (() => {
          const describe = (input) => {
            const rect = input.getBoundingClientRect();
            const style = window.getComputedStyle(input);
            const conversation = input.closest('[data-conversation-session]');
            const session = conversation === null
              ? null
              : conversation.getAttribute('data-conversation-session');
            const draftText = input.textContent || '';
            let storedDraftLength = -1;
            if (session) {
              try {
                const raw = localStorage.getItem(`dsh.conversation.${session}`);
                if (raw !== null) {
                  const stored = JSON.parse(raw);
                  const draft = stored !== null && typeof stored === 'object' && 'draft' in stored
                    ? stored.draft
                    : stored;
                  const text = typeof draft === 'string'
                    ? draft
                    : (draft !== null && typeof draft === 'object'
                        && typeof draft.text === 'string' ? draft.text : '');
                  storedDraftLength = text.length;
                }
              } catch (_error) {
                storedDraftLength = -1;
              }
            }
            return {
              tag: input.tagName,
              contenteditable_attr: input.getAttribute('contenteditable'),
              is_content_editable: input.isContentEditable === true,
              aria_disabled: input.getAttribute('aria-disabled'),
              disabled_attr: input.hasAttribute('disabled'),
              native_disabled: input.disabled === true,
              role: input.getAttribute('role'),
              phase: input.getAttribute('data-phase'),
              placeholder: input.getAttribute('data-placeholder'),
              visible: rect.width > 0 && rect.height > 0
                && style.display !== 'none' && style.visibility !== 'hidden',
              focused: document.activeElement === input,
              document_has_focus: document.hasFocus(),
              draft_text: draftText,
              draft_length: draftText.length,
              stored_draft_length: storedDraftLength,
              session,
              card_present: input.closest('[data-composer-card]') !== null
            };
          };
          const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
          const described = inputs.map(describe);
          const active = described.find(item =>
            item.contenteditable_attr === 'true' && item.visible)
            ?? described.find(item => item.contenteditable_attr === 'true')
            ?? described[0]
            ?? null;
          const menuChips = Array.from(document.querySelectorAll('button[aria-haspopup="menu"]'))
            .slice(0, 12)
            .map(button => ({
              label: (button.getAttribute('aria-label') || '').trim(),
              title: (button.getAttribute('title') || '').trim(),
              text: (button.textContent || '').trim().slice(0, 80),
              disabled: button.disabled === true,
              expanded: button.getAttribute('aria-expanded') === 'true'
            }));
          const workspaceRows = Array.from(document.querySelectorAll('[data-row-key^="workspace:"]'))
            .slice(0, 12)
            .map(row => ({
              key: row.getAttribute('data-row-key') || '',
              label: (row.textContent || '').trim().slice(0, 120),
              expanded: row.getAttribute('aria-expanded') === 'true'
            }));
          const sessions = Array.from(document.querySelectorAll('[data-conversation-session]'))
            .slice(0, 12)
            .map(node => node.getAttribute('data-conversation-session') || '');
          return JSON.stringify({
            composer_count: described.length,
            active,
            composers: described,
            menu_chips: menuChips,
            workspace_rows: workspaceRows,
            conversation_sessions: sessions,
            document_has_focus: document.hasFocus(),
            active_element: document.activeElement === null
              ? null
              : document.activeElement.tagName
          });
        })()
        """
    }

    /// Whether the sampled composer state is ready for input. Visibility is
    /// part of the gate because the resident surface can be editable while its
    /// seat is still hidden during the page's settling frame.
    private func composerStateReady(_ state: [String: Any]) -> Bool {
        guard let active = state["active"] as? [String: Any] else { return false }
        let editableAttr = active["contenteditable_attr"] as? String ?? ""
        let contentEditable = active["is_content_editable"] as? Bool ?? false
        let ariaDisabled = active["aria_disabled"] as? String ?? ""
        let disabledAttr = active["disabled_attr"] as? Bool ?? false
        let nativeDisabled = active["native_disabled"] as? Bool ?? false
        let visible = active["visible"] as? Bool ?? false
        let session = active["session"] as? String ?? ""
        return visible
            && editableAttr == "true"
            && contentEditable
            && ariaDisabled != "true"
            && !disabledAttr
            && !nativeDisabled
            && !session.isEmpty
    }

    /// Reads the current rendered draft length. The paste commit is
    /// asynchronous, so this is polled instead of read in the dispatch task.
    private func composerDraftLength(_ engine: WebEngine) async throws -> Int {
        let state = try await composerState(engine)
        let active = state["active"] as? [String: Any] ?? [:]
        return (active["draft_length"] as? NSNumber)?.intValue ?? -1
    }

    /// Polls the composer's committed DOM text after a production paste. The
    /// Lexical update reconciles in a microtask, so the dispatch task cannot
    /// read `textContent` immediately. The editor must still be visible and
    /// editable when the exact text appears.
    private func composerDraftMatches(_ engine: WebEngine, text: String) async throws -> Bool {
        let data = (try? JSONEncoder().encode(text)) ?? Data()
        let literal = String(data: data, encoding: .utf8) ?? "\"\""
        return try await evaluateBool(engine, """
        (() => {
          const expected = \(literal);
          const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
          const input = inputs.find(node => {
            if (node.getAttribute('contenteditable') !== 'true') return false;
            const rect = node.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          }) ?? inputs.find(node => node.getAttribute('contenteditable') === 'true') ?? null;
          if (input === null) return false;
          const rect = input.getBoundingClientRect();
          const style = window.getComputedStyle(input);
          return input.getAttribute('contenteditable') === 'true'
            && input.isContentEditable === true
            && rect.width > 0 && rect.height > 0
            && style.display !== 'none' && style.visibility !== 'hidden'
            && (input.textContent || '') === expected;
        })()
        """)
    }

    /// Clears any restored draft through the editor's own deletion input path.
    /// The suite reuses `Documents/chat-host`; a previous interrupted paste can
    /// otherwise be prepended to this run's exact prompt. The DOM selection and
    /// `beforeinput` event are real editor input, not a `textContent` write.
    private func clearComposerDraft(_ engine: WebEngine) async throws -> [String: Any] {
        let raw = try await evaluateString(engine, Self.clearComposerDraftScript())
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return ["parse_error": raw] }
        return object
    }

    private static func clearComposerDraftScript() -> String {
        """
        (() => {
          const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
          const input = inputs.find(node => {
            if (node.getAttribute('contenteditable') !== 'true') return false;
            const rect = node.getBoundingClientRect();
            return rect.width > 0 && rect.height > 0;
          }) ?? inputs.find(node => node.getAttribute('contenteditable') === 'true') ?? null;
          if (input === null) {
            return JSON.stringify({dispatched: false, reason: 'no-editable-composer'});
          }
          const before = (input.textContent || '').length;
          if (before === 0) {
            return JSON.stringify({dispatched: false, before: 0, reason: 'already-empty'});
          }
          input.focus();
          const selection = window.getSelection();
          if (selection === null) {
            return JSON.stringify({dispatched: false, before, reason: 'no-dom-selection'});
          }
          const range = document.createRange();
          range.selectNodeContents(input);
          selection.removeAllRanges();
          selection.addRange(range);
          const event = new InputEvent('beforeinput', {
            bubbles: true,
            cancelable: true,
            composed: true,
            inputType: 'deleteContentBackward'
          });
          let dispatched = false;
          try {
            input.dispatchEvent(event);
            dispatched = true;
          } catch (_error) {
            dispatched = false;
          }
          return JSON.stringify({
            dispatched,
            before,
            default_prevented: event.defaultPrevented,
            after_dispatch: (input.textContent || '').length
          });
        })()
        """
    }

    /// Removes only the current Session's persisted conversation draft. This
    /// is a failed-clear cleanup, not an input path; it makes the next run
    /// repeatable if the real deletion event could not empty the editor.
    private func discardPersistedComposerDraft(_ engine: WebEngine) async throws -> [String: Any] {
        let raw = try await evaluateString(engine, Self.discardPersistedComposerDraftScript())
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any]
        else { return ["status": "parse_error", "raw": raw] }
        return object
    }

    private static func discardPersistedComposerDraftScript() -> String {
        """
        (() => {
          const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
          const input = inputs.find(node => node.getAttribute('contenteditable') === 'true')
            ?? inputs[0]
            ?? null;
          const conversation = input === null
            ? null
            : input.closest('[data-conversation-session]');
          const session = conversation === null
            ? null
            : conversation.getAttribute('data-conversation-session');
          if (!session) {
            return JSON.stringify({removed: false, reason: 'no-session'});
          }
          const key = `dsh.conversation.${session}`;
          try {
            const hadValue = localStorage.getItem(key) !== null;
            localStorage.removeItem(key);
            return JSON.stringify({removed: true, had_value: hadValue, key});
          } catch (error) {
            return JSON.stringify({removed: false, reason: String(error), key});
          }
        })()
        """
    }

    /// Reads the selected Session's native cwd/blank/agent-preset value.
    /// `agentPreset` is a string-or-null projection, not a `{currentValue}`
    /// object; recording it before the ready gate keeps diagnostics available
    /// when the composer is disabled or selected a different Workspace.
    private func composerSessionEvidence(_ transport: any DSHRemoteTransport,
                                         sessionID: String) async throws -> [String: Any] {
        let list = try await transport.call("session/list", args: .object([:]))
        let summary = (list["items"]?.arrayValue ?? []).first {
            $0["sessionId"]?.stringValue == sessionID
        }
        let cwd = summary?["cwd"]?.stringValue ?? ""
        let blank = summary?["blank"]?.boolValue ?? false
        var preset = ""
        if !sessionID.isEmpty {
            let projections = try await transport.call(
                "session/projections",
                args: .object(["request": .object(["sessionId": .string(sessionID)])]))
            preset = projections["values"]?["agentPreset"]?.stringValue ?? ""
        }
        return [
            "session_id": sessionID,
            "cwd": cwd,
            "blank": blank,
            "agent_preset": preset,
        ]
    }

    /// Dispatches the prompt through the production paste path. The composer
    /// is a Lexical contenteditable, not a textarea: `execCommand('insertText')`
    /// can silently no-op in a WKWebView whose window is not key. A real
    /// `paste` event with `text/plain` reaches the same `PASTE_COMMAND` the
    /// user clipboard uses; the editor commits the text and its own input
    /// machine publishes the draft. The commit is asynchronous, so this only
    /// reports that the event was dispatched; the caller polls the committed
    /// draft. Nothing writes `textContent` or calls `session/prompt` directly.
    private static func insertPromptScript(_ prompt: String) -> String {
        let data = (try? JSONEncoder().encode(prompt)) ?? Data()
        let literal = String(data: data, encoding: .utf8) ?? "\"\""
        return """
        (() => {
          const text = \(literal);
          const inputs = Array.from(document.querySelectorAll('[data-composer-input]'));
          const input = inputs.find(node =>
            node.getAttribute('contenteditable') === 'true'
              && node.getClientRects().length > 0)
            ?? inputs.find(node => node.getAttribute('contenteditable') === 'true')
            ?? null;
          if (input === null) return 'no-editable-composer';
          input.focus();
          let transfer = null;
          try {
            transfer = new DataTransfer();
            transfer.setData('text/plain', text);
          } catch (_error) {
            transfer = null;
          }
          const clipboard = transfer ?? {
            items: [],
            getData: type => type === 'text/plain' ? text : ''
          };
          const event = new Event('paste', { bubbles: true, cancelable: true });
          try {
            Object.defineProperty(event, 'clipboardData', { value: clipboard });
          } catch (_error) {
            event.clipboardData = clipboard;
          }
          try {
            input.dispatchEvent(event);
          } catch (_error) {
            return 'dispatch-error';
          }
          return 'dispatched';
        })()
        """
    }

    // MARK: - Session evidence

    private struct SessionEventRecord {
        let seq: Int
        let type: String
        let data: [String: JSONValue]
    }

    private struct ToolTrace {
        let callID: String
        let callSeq: Int
        let resultSeq: Int
        let arguments: String
        let resultText: String
    }

    private struct AssistantEvidence {
        let messageID: String
        let seq: Int
        let text: String
    }

    private struct SessionLog {
        let sessionID: String
        let url: URL
        let records: [JSONValue]

        var events: [SessionEventRecord] {
            PhoneDSHWebSurfaceTests.events(fromRecords: records)
        }
    }

    /// Pre-prompt high-water mark of one session journal. A reused session is
    /// only accepted when it grows past this mark.
    private struct SessionLogBaseline {
        let maxSeq: Int
        let byteCount: Int
        let modified: Date
    }

    /// Reads a session history page and the materialized JSONL through one
    /// parser.
    ///
    /// `session/page` records are `{"type":"event","event":{type,seq,data}}`
    /// envelopes (DSH `SessionHistoryRecord`); a session JSONL line is the bare
    /// event. Accepting both here keeps the evidence comparison on the event
    /// itself and cannot silently produce an empty page trace again.
    private nonisolated static func events(fromRecords records: [JSONValue]) -> [SessionEventRecord] {
        records.compactMap { record in
            let event = record["event"] ?? record
            guard let type = event["type"]?.stringValue,
                  let seq = event["seq"]?.intValue else { return nil }
            return SessionEventRecord(seq: seq, type: type,
                                      data: event["data"]?.objectValue ?? [:])
        }
    }

    private nonisolated func sessionPageBashTrace(_ transport: any DSHRemoteTransport,
                                                  sessionID: String,
                                                  throughSeq: Int,
                                                  turn: TurnExpectation) async throws
        -> ToolTrace? {
        let value = try await transport.call(
            "session/page",
            args: .object(["request": .object([
                "address": .object(["kind": .string("session"),
                                    "sessionId": .string(sessionID)]),
                "throughSeq": .number(Double(throughSeq)),
                "maxMessages": .number(200),
            ])]))
        return bashTrace(Self.events(fromRecords: value["records"]?.arrayValue ?? []),
                         turn: turn)
    }

    private nonisolated func sessionLogIDs(workspace: URL) throws -> [String] {
        try sessionLogFiles(workspace: workspace).compactMap { url in
            let records = try jsonlRecords(at: url)
            return records.first { $0["type"]?.stringValue == "session" }?["id"]?.stringValue
        }.sorted()
    }

    /// Records every journal's max seq, size and mtime before the prompt.
    private nonisolated func sessionLogBaselines(
        workspace: URL) throws -> [String: SessionLogBaseline] {
        var baseline: [String: SessionLogBaseline] = [:]
        for url in sessionLogFiles(workspace: workspace) {
            let records = try jsonlRecords(at: url)
            guard let id = records.first(where: { $0["type"]?.stringValue == "session" })?["id"]?.stringValue else {
                continue
            }
            let maxSeq = Self.events(fromRecords: records).map(\.seq).max() ?? 0
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            baseline[id] = SessionLogBaseline(
                maxSeq: maxSeq,
                byteCount: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? .distantPast)
        }
        return baseline
    }

    /// Selects a completed bash trace that did not exist before the prompt.
    ///
    /// A fresh Session has no baseline entry. A reused Session must both append
    /// a higher seq (call and result) and grow on disk; merely finding the same
    /// command in an older journal can no longer satisfy the wait.
    private nonisolated func loadNewBashLog(
        workspace: URL,
        baseline: [String: SessionLogBaseline],
        turn: TurnExpectation) throws
        -> (log: SessionLog, trace: ToolTrace)? {
        var candidates: [(log: SessionLog, trace: ToolTrace, modified: Date)] = []
        for url in sessionLogFiles(workspace: workspace) {
            let records = try jsonlRecords(at: url)
            guard let id = records.first(where: { $0["type"]?.stringValue == "session" })?["id"]?.stringValue else {
                continue
            }
            let sessionEvents = Self.events(fromRecords: records)
            guard let trace = bashTrace(sessionEvents, turn: turn) else { continue }
            let maxSeq = sessionEvents.map(\.seq).max() ?? 0
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let byteCount = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            if let before = baseline[id] {
                guard maxSeq > before.maxSeq,
                      trace.callSeq > before.maxSeq,
                      trace.resultSeq > before.maxSeq,
                      byteCount > before.byteCount || modified > before.modified else {
                    continue
                }
            } else {
                guard trace.resultSeq > 0 else { continue }
            }
            candidates.append((SessionLog(sessionID: id, url: url, records: records),
                               trace, modified))
        }
        guard let selected = candidates.max(by: { lhs, rhs in
            if lhs.trace.resultSeq != rhs.trace.resultSeq {
                return lhs.trace.resultSeq < rhs.trace.resultSeq
            }
            return lhs.modified < rhs.modified
        }) else { return nil }
        return (log: selected.log, trace: selected.trace)
    }

    private nonisolated func loadSessionLog(workspace: URL, sessionID: String?) throws -> SessionLog? {
        let fileManager = FileManager.default
        var candidates: [(URL, [JSONValue], String, Date)] = []
        for url in sessionLogFiles(workspace: workspace) {
            let records = try jsonlRecords(at: url)
            guard let id = records.first(where: { $0["type"]?.stringValue == "session" })?["id"]?.stringValue else {
                continue
            }
            if let sessionID, id != sessionID { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            candidates.append((url, records, id, modified))
        }
        guard let selected = candidates.max(by: { $0.3 < $1.3 }) else { return nil }
        return SessionLog(sessionID: selected.2, url: selected.0, records: selected.1)
    }

    private nonisolated func sessionLogFiles(workspace: URL) -> [URL] {
        let fileManager = FileManager.default
        let roots = [
            workspace.appendingPathComponent("materialized/home/sessions", isDirectory: true),
            workspace.appendingPathComponent("sessions", isDirectory: true),
        ]
        var files: [URL] = []
        var seen = Set<String>()
        for root in roots {
            guard fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
                continue
            }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name.hasPrefix("session."), name.hasSuffix(".jsonl") else { continue }
                if seen.insert(url.path).inserted { files.append(url) }
            }
        }
        return files
    }

    private nonisolated func jsonlRecords(at url: URL) throws -> [JSONValue] {
        let data = try Data(contentsOf: url)
        var records: [JSONValue] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let value = try? JSONValue.parse(Data(line)) {
                records.append(value)
            }
        }
        return records
    }

    /// Selects only this turn's bash call/result: the command arguments must
    /// name this run's nonce files and the result must carry the PNG-write
    /// marker. A previous run's identical-looking command can never match.
    private nonisolated func bashTrace(_ events: [SessionEventRecord],
                                       turn: TurnExpectation) -> ToolTrace? {
        var calls: [String: (seq: Int, arguments: String)] = [:]
        var traces: [ToolTrace] = []
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            switch event.type {
            case "tool/call":
                guard event.data["name"]?.stringValue == "bash",
                      let callID = event.data["callId"]?.stringValue else { continue }
                let arguments = event.data["arguments"]?.stringValue ?? ""
                if arguments.contains(turn.textName), arguments.contains(turn.imageName) {
                    calls[callID] = (seq: event.seq, arguments: arguments)
                }
            case "tool/result":
                guard let message = event.data["message"]?.objectValue,
                      let source = message["source"]?.objectValue,
                      let callID = source["callId"]?.stringValue,
                      let call = calls[callID] else { continue }
                let resultText = Self.textContent(message["content"])
                guard resultText.contains(turn.marker),
                      resultText.contains(turn.textContent) else { continue }
                traces.append(ToolTrace(callID: callID, callSeq: call.seq,
                                        resultSeq: event.seq, arguments: call.arguments,
                                        resultText: resultText))
            default:
                continue
            }
        }
        // The newest completed trace is the one this run just produced. Returning
        // the first match would keep pointing at a previous identical command
        // when the page resumes an existing Session.
        return traces.last
    }

    /// Selects the assistant message carrying this turn's nonce and records
    /// its durable `message.id`. The trailing final text is unique per run,
    /// so an older assistant answer cannot satisfy the wait.
    private nonisolated func assistantMessage(_ events: [SessionEventRecord],
                                              turn: TurnExpectation) -> AssistantEvidence? {
        for event in events.sorted(by: { $0.seq < $1.seq }).reversed() {
            guard event.type == "assistant/message",
                  let message = event.data["message"]?.objectValue else { continue }
            let text = Self.textContent(message["content"])
            guard text.contains("Done \(turn.nonce)"),
                  text.contains(turn.textName),
                  text.contains(turn.imageName) else { continue }
            let messageID = message["id"]?.stringValue ?? ""
            return AssistantEvidence(messageID: messageID, seq: event.seq, text: text)
        }
        return nil
    }

    /// Compares the whole observable tool trace, including the result text.
    /// CallId/seq agreement alone would let an empty or different
    /// `session/page` result pass.
    private nonisolated static func isSameTrace(_ trace: ToolTrace?,
                                                 as expected: ToolTrace,
                                                 turn: TurnExpectation) -> Bool {
        guard let trace else { return false }
        return trace.callID == expected.callID
            && trace.callSeq == expected.callSeq
            && trace.resultSeq == expected.resultSeq
            && trace.arguments == expected.arguments
            && trace.resultText == expected.resultText
            && trace.arguments.contains(turn.textName)
            && trace.arguments.contains(turn.imageName)
            && trace.resultText.contains(turn.textContent)
            && trace.resultText.contains(turn.marker)
            && trace.resultText.contains("writable roots")
    }

    private nonisolated static func textContent(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let text):
            return text
        case .array(let blocks):
            return blocks.map { textContent($0) }.joined(separator: "\n")
        case .object(let object):
            if let text = object["text"]?.stringValue { return text }
            if let content = object["content"] { return textContent(content) }
            return ""
        default:
            return ""
        }
    }

    // MARK: - Real WebContent kill handshake

    /// Hands this suite's live WebContent to the device-scoped watcher started
    /// by `scripts/ci/sim.sh`.
    ///
    /// The sandboxed test process cannot signal the simulator's WebContent
    /// itself. `scripts/ci/sim.sh` runs `webcontent-watch.sh web` with a
    /// baseline of already-live pids; the watcher creates `expect-web-kill` in
    /// the data container it currently resolves, so an xcodebuild reinstall that
    /// moves the container does not strand the expectation in the old path.
    /// This method writes `web-kill-ready.json` while the real WKWebView is
    /// alive and waits for the watcher's `web-kill-result.json`. The watcher only
    /// SIGKILLs pids whose environment carries this simulator's UDID and whose
    /// command is the simulator's WebKit WebContent. A direct test run with no
    /// watcher leaves no expectation; after a short grace period it returns
    /// `false` and reports the kill row as NOT_RUN.
    private func requestRealWebContentKill(report: SimSuiteReport,
                                           directory: URL) async throws -> Bool {
        let expect = directory.appendingPathComponent("expect-web-kill")
        // The watcher writes the expectation after resolving the container it
        // currently sees. Give a just-migrated container a bounded grace period
        // instead of treating "not yet visible" as "no watcher" and silently
        // skipping the real kill.
        let expectDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: expect.path) {
            if Date() >= expectDeadline { return false }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let ready = directory.appendingPathComponent("web-kill-ready.json")
        let result = directory.appendingPathComponent("web-kill-result.json")
        try? FileManager.default.removeItem(at: result)
        let request: [String: Any] = [
            "requested_at": ISO8601DateFormatter().string(from: Date()),
            "webcontent_live": true,
            "detail": "the full-Web suite's real WKWebView is alive; the shell "
                + "watcher may SIGKILL this simulator's WebContent",
        ]
        let data = try JSONSerialization.data(withJSONObject: request,
                                              options: [.sortedKeys])
        try data.write(to: ready, options: .atomic)
        let deadline = Date().addingTimeInterval(20)
        var outcome: [String: Any]?
        while Date() < deadline {
            if let data = try? Data(contentsOf: result),
               let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] {
                outcome = object
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let outcome else {
            throw SimError.assertion(
                "scripts/ci/sim.sh did not report the real WebContent kill within 20 s")
        }
        report.set("webcontent_kill_handshake", outcome)
        let status = outcome["status"] as? String ?? ""
        guard status.hasPrefix("attempted: SIGKILL sent") else {
            throw SimError.assertion(
                "the WebContent watcher did not send SIGKILL: \(status)")
        }
        return true
    }

    // MARK: - Report helpers

    @discardableResult
    private func require(_ report: SimSuiteReport,
                         _ probe: String,
                         _ passed: Bool,
                         metrics: [String: Any] = [:],
                         detail: String) throws -> Bool {
        report.record("web.\(probe)", status: passed ? .pass : .fail, gating: true,
                      metrics: metrics,
                      threshold: simG1Threshold("g1_web_\(probe)",
                                                measured: passed ? 1 : 0),
                      detail: detail)
        if !passed { throw SimError.assertion(detail) }
        return passed
    }

    private nonisolated static func ms(since start: Date) -> Double {
        (Date().timeIntervalSince(start) * 1000).rounded()
    }
}

/// Holds the engines the shared `WebHostConfiguration` factory creates. The
/// test must observe each construction instead of pre-creating a
/// placeholder-config engine; `created` is how the park/resume block proves
/// `resume()` really built a second WKWebView. All access is MainActor-isolated.
@MainActor
private final class EngineSlot {
    private(set) var created = 0
    var engine: WebEngine?

    func publish(_ engine: WebEngine) {
        created += 1
        self.engine = engine
    }
}
