// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: Phase 0 probe suite (PLAN W3-APP / W3-PROBES).
//
// The suite is the same one `Tests/PhoneDSHProbeTests` runs on macOS,
// ported to the iOS UI actor:
//
//   * channel: the real LoopbackServer serves a page and Worker to a real
//     WKWebView; same-origin 1 KB and 1 MB POSTs go through `/v1/http`, the
//     NDJSON response is read chunk by chunk, 1000 sequential WebSocket
//     echoes measure p50/p95, and COOP/COEP is checked through
//     `crossOriginIsolated` with the origin's header switch both ways;
//   * throttling: a 10 ms page timer in a detached WKWebView vs a one-point
//     visible one;
//   * JIT baseline: the same MB-scale JSON + template script in a bare
//     JavaScriptCore JSContext and in a WKWebView;
//   * checkpoint: 100 files appended through WorkspaceLog (level 1 plus
//     materialization) and an epoch close.
//
// Every row is written to the shared ``ProbeReport`` with the G0 threshold
// where PLAN §2.5 / §3–§5 defines one; rows without a defined bound are INFO.
// NOT_VERIFIED on an iPhone until a device run records the numbers.

import Foundation
import JavaScriptCore
import UIKit
import WebKit
import PhoneDSHLog
import PhoneDSHWire

/// Runs the Phase 0 probes from the App UI.
@MainActor
public final class ProbeSuiteRunner {
    /// Report every probe appends to.
    public let report: ProbeReport

    public init(report: ProbeReport) {
        self.report = report
    }

    // MARK: - Entry points

    /// Runs the whole suite sequentially.
    public func runAll(anchor: UIView?) async {
        await runChannel(anchor: anchor)
        await runIsolationOff(anchor: anchor)
        await runThrottling(anchor: anchor)
        await runJIT(anchor: anchor)
        await runCheckpoint()
    }

    // MARK: - Channel probes

    /// Channel fetch/NDJSON/WebSocket/COOP-COEP probes in a real Worker.
    public func runChannel(anchor: UIView?) async {
        let outcome: (result: [String: Any], pageIsolated: Bool,
                      secureContext: Bool, coop: String?, coep: String?,
                      localhost: [String: Any])
        do {
            outcome = try await withServer(isolation: true) { server -> ([String: Any],
                                                                         Bool, Bool, String?,
                                                                         String?, [String: Any]) in
                let coop = await self.responseHeader(server.pageURL,
                                                     name: "Cross-Origin-Opener-Policy")
                let coep = await self.responseHeader(server.pageURL,
                                                     name: "Cross-Origin-Embedder-Policy")
                let webView = ProbeWebView(visible: anchor != nil, host: anchor)
                defer { webView.teardown() }
                try await webView.load(server.pageURL)
                let pageIsolated = (try? await webView.evaluateNumber(
                    "window.crossOriginIsolated ? 1 : 0")) == 1
                let secureContext = (try? await webView.evaluateNumber(
                    "window.isSecureContext ? 1 : 0")) == 1
                let result = try await webView.waitForProbeResult(timeout: 120)

                var localhost: [String: Any] = [:]
                let localhostView = ProbeWebView(visible: anchor != nil, host: anchor)
                do {
                    try await localhostView.load(server.localhostPageURL(mode: "isolation"),
                                                 timeout: 10)
                    let localhostPage = (try? await localhostView.evaluateNumber(
                        "window.crossOriginIsolated ? 1 : 0")) == 1
                    let localhostSecure = (try? await localhostView.evaluateNumber(
                        "window.isSecureContext ? 1 : 0")) == 1
                    let localhostWorker = (try? await localhostView.waitForProbeResult(
                        timeout: 30)) ?? [:]
                    localhost = [
                        "page_crossOriginIsolated": localhostPage,
                        "secure_context": localhostSecure,
                        "worker_crossOriginIsolated":
                            self.boolValue(localhostWorker["crossOriginIsolated"]) ?? false,
                    ]
                } catch {
                    localhost = ["error": String(describing: error)]
                }
                localhostView.teardown()
                return (result, pageIsolated, secureContext, coop, coep, localhost)
            }
        } catch {
            recordMissing("channel.worker", "probe server")
            report.record(probe: "channel.worker", kind: "channel", status: .fail,
                          gating: true, metrics: [:],
                          detail: "the probe Worker could not run: \(error)")
            return
        }

        if let error = outcome.result["error"] as? String {
            report.record(probe: "channel.worker", kind: "channel", status: .fail,
                          gating: true, metrics: [:],
                          detail: "the probe Worker failed: \(error)")
            return
        }

        let pageCrossOrigin = outcome.pageIsolated
        let workerCrossOrigin = boolValue(outcome.result["crossOriginIsolated"]) ?? false
        report.record(
            probe: "channel.loopback-ip-secure-context",
            kind: "channel", status: .info, gating: false,
            metrics: [
                "url_scheme": "http",
                "host": "127.0.0.1",
                "secure_context": outcome.secureContext,
                "crossOriginIsolated": pageCrossOrigin,
                "worker_crossOriginIsolated": workerCrossOrigin,
            ],
            detail: "records what this WebKit build reports for http://127.0.0.1; the probe does not assume a secure context")
        report.record(
            probe: "channel.coop-coep-headers-on",
            kind: "channel",
            status: probeStatus(correct: outcome.coop == "same-origin"
                                && outcome.coep == "require-corp"),
            gating: true,
            metrics: ["coop_header": outcome.coop ?? "absent",
                      "coep_header": outcome.coep ?? "absent"],
            detail: "the loopback serves COOP same-origin and COEP require-corp when configured on")
        report.record(
            probe: "channel.crossoriginisolated-localhost",
            kind: "channel", status: .info, gating: false,
            metrics: [
                "host": "localhost",
                "secure_context": boolValue(outcome.localhost["secure_context"]) ?? false,
                "crossOriginIsolated":
                    boolValue(outcome.localhost["page_crossOriginIsolated"]) ?? false,
                "worker_crossOriginIsolated":
                    boolValue(outcome.localhost["worker_crossOriginIsolated"]) ?? false,
                "error": outcome.localhost["error"] ?? "none",
            ],
            detail: "same loopback server through localhost; informational cross-check")
        report.record(
            probe: "channel.crossoriginisolated-on",
            kind: "channel", status: .info, gating: false,
            metrics: ["crossOriginIsolated": pageCrossOrigin,
                      "secure_context": outcome.secureContext,
                      "worker_crossOriginIsolated": workerCrossOrigin,
                      "coop_header": outcome.coop ?? "absent",
                      "coep_header": outcome.coep ?? "absent"],
            detail: "COOP/COEP are present; the crossOriginIsolated result is recorded as measured and is NOT_VERIFIED on a device")

        if let fetch = outcome.result["fetch1k"] as? [String: Any] {
            recordFetch(probe: "channel.fetch-post-1kb", fetch: fetch)
        } else {
            recordMissing("channel.fetch-post-1kb", "fetch1k")
        }
        if let fetch = outcome.result["fetch1m"] as? [String: Any] {
            recordFetch(probe: "channel.fetch-post-1mb", fetch: fetch)
        } else {
            recordMissing("channel.fetch-post-1mb", "fetch1m")
        }
        if let ndjson = outcome.result["ndjson"] as? [String: Any] {
            recordNDJSON(ndjson)
        } else {
            recordMissing("channel.ndjson-first-chunk", "ndjson")
        }
        if let websocket = outcome.result["ws"] as? [String: Any] {
            recordWebSocketEcho(websocket)
        } else {
            recordMissing("channel.ws-echo-1000", "ws")
        }
    }

    /// COOP/COEP off: the headers are absent and the page is not isolated.
    public func runIsolationOff(anchor: UIView?) async {
        let outcome: (result: [String: Any], coop: String?, coep: String?,
                      workerCoop: String?, workerCoep: String?, pageIsolated: Bool)
        do {
            outcome = try await withServer(isolation: false) { server -> ([String: Any],
                                                                          String?, String?,
                                                                          String?, String?,
                                                                          Bool) in
                let coop = await self.responseHeader(server.pageURL,
                                                     name: "Cross-Origin-Opener-Policy")
                let coep = await self.responseHeader(server.pageURL,
                                                     name: "Cross-Origin-Embedder-Policy")
                var workerComponents = URLComponents(url: server.pageURL,
                                                     resolvingAgainstBaseURL: false)!
                workerComponents.path = "/static/probe-worker.js"
                let workerURL = workerComponents.url!
                let workerCoop = await self.responseHeader(workerURL,
                                                           name: "Cross-Origin-Opener-Policy")
                let workerCoep = await self.responseHeader(workerURL,
                                                           name: "Cross-Origin-Embedder-Policy")
                let webView = ProbeWebView(visible: anchor != nil, host: anchor)
                defer { webView.teardown() }
                try await webView.load(server.pageURL(mode: "isolation"))
                let pageIsolated = (try? await webView.evaluateNumber(
                    "window.crossOriginIsolated ? 1 : 0")) == 1
                return (try await webView.waitForProbeResult(timeout: 60),
                        coop, coep, workerCoop, workerCoep, pageIsolated)
            }
        } catch {
            report.record(probe: "channel.crossoriginisolated-off", kind: "channel",
                          status: .fail, gating: true, metrics: [:],
                          detail: "the isolation-off probe could not run: \(error)")
            return
        }
        if let error = outcome.result["error"] as? String {
            report.record(probe: "channel.crossoriginisolated-off", kind: "channel",
                          status: .fail, gating: true, metrics: [:],
                          detail: "the isolation probe Worker failed: \(error)")
            return
        }
        let pageCrossOrigin = outcome.pageIsolated
        let workerCrossOrigin = boolValue(outcome.result["crossOriginIsolated"]) ?? true
        report.record(
            probe: "channel.coop-coep-headers-off",
            kind: "channel",
            status: probeStatus(correct: outcome.coop == nil && outcome.coep == nil),
            gating: true,
            metrics: ["coop_header": outcome.coop ?? "absent",
                      "coep_header": outcome.coep ?? "absent",
                      "worker_coop_header": outcome.workerCoop ?? "absent",
                      "worker_coep_header": outcome.workerCoep ?? "absent"],
            detail: "the loopback omits COOP/COEP when the isolation switch is off")
        report.record(
            probe: "channel.crossoriginisolated-off",
            kind: "channel",
            status: probeStatus(correct: pageCrossOrigin == false),
            gating: true,
            metrics: ["crossOriginIsolated": pageCrossOrigin,
                      "worker_crossOriginIsolated": workerCrossOrigin,
                      "cross_origin_isolation_header": false],
            detail: "COOP/COEP disabled: the page is not cross-origin isolated")
    }

    // MARK: - Timer throttling

    /// Detached vs one-point-visible timer throttling.
    public func runThrottling(anchor: UIView?) async {
        let windowSeconds = 2.0
        var measurements = (visible: -1.0, hidden: -1.0, offscreen: -1.0)
        do {
            measurements = try await withServer(isolation: true) { server -> (Double, Double, Double) in
                let visibleView = ProbeWebView(visible: anchor != nil, host: anchor)
                var visibleTicks = -1.0
                var hiddenTicks = -1.0
                do {
                    try await visibleView.load(server.timerURL)
                    _ = try await visibleView.evaluateString("window.__ticks = 0")
                    try await Task.sleep(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
                    visibleTicks = try await visibleView.evaluateNumber("window.__ticks") ?? -1

                    visibleView.view.isHidden = true
                    try await Task.sleep(nanoseconds: 500_000_000)
                    _ = try await visibleView.evaluateString("window.__ticks = 0")
                    try await Task.sleep(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
                    hiddenTicks = try await visibleView.evaluateNumber("window.__ticks") ?? -1
                } catch {
                    visibleView.teardown()
                    throw error
                }
                visibleView.teardown()

                let offscreenView = ProbeWebView(visible: false, host: nil)
                var offscreenTicks = -1.0
                do {
                    try await offscreenView.load(server.timerURL)
                    _ = try await offscreenView.evaluateString("window.__ticks = 0")
                    try await Task.sleep(nanoseconds: UInt64(windowSeconds * 1_000_000_000))
                    offscreenTicks = try await offscreenView.evaluateNumber("window.__ticks") ?? -1
                } catch {
                    offscreenView.teardown()
                    throw error
                }
                offscreenView.teardown()
                return (visibleTicks, hiddenTicks, offscreenTicks)
            }
        } catch {
            // No PLAN gate exists for this informational probe. An environment
            // that cannot run it must not produce a FAIL row: the simulator
            // gate (`scripts/ci/sim.sh`) treats every FAIL row as a gate
            // failure, so an unusable probe stays INFO with the reason in
            // `detail`.
            report.record(probe: "throttle.offscreen-vs-visible", kind: "throttle",
                          status: .info, gating: false,
                          metrics: ["measurement_valid": false],
                          detail: "the timer probe could not run (informational "
                            + "row, not a gate): \(error)")
            return
        }

        let correct = measurements.visible >= 0
            && measurements.hidden >= 0
            && measurements.offscreen >= 0
        let visibleRatio = measurements.hidden > 0
            ? measurements.visible / measurements.hidden : 0
        report.record(
            probe: "throttle.offscreen-vs-visible",
            kind: "throttle",
            status: .info,
            gating: false,
            metrics: [
                "interval_ms": 10,
                "window_seconds": windowSeconds,
                "visible_ticks": measurements.visible,
                "hidden_ticks": measurements.hidden,
                "offscreen_ticks": measurements.offscreen,
                "visible_vs_hidden_ratio": visibleRatio,
                "one_point_visible_kept_timers": visibleRatio >= 0.5,
                "measurement_valid": correct,
            ],
            detail: correct
                ? "10 ms setInterval: a one-point visible view, the same view hidden, and a detached WKWebView; a ratio near 1 means the one-point attachment did not avoid timer throttling in this process"
                : "the timer probe produced no usable measurement (informational "
                    + "row, not a gate)")
    }

    // MARK: - JIT baseline

    /// JavaScriptCore vs WKWebView MB-scale JSON/template benchmark.
    public func runJIT(anchor: UIView?) async {
        do {
            let site = try ProbeSite()
            defer { site.cleanup() }
            let script = try String(contentsOf: site.directory.appendingPathComponent("benchmark.js"),
                                    encoding: .utf8)
            let jsContext = try measureJSContext(script: script)
            let webViewResult = try await measureWebView(script: script, site: site,
                                                         anchor: anchor)
            let contextTotal = jsContext.totalMilliseconds
            let webViewTotal = webViewResult.totalMilliseconds
            let ratio = webViewTotal > 0 ? contextTotal / webViewTotal : 0
            let correct = contextTotal > 0 && webViewTotal > 0
            report.record(
                probe: "jit.wkwebview-vs-jscontext",
                kind: "jit",
                status: .info,
                gating: false,
                metrics: [
                    "benchmark_bytes": jsContext.bytes,
                    "jscontext_json_ms": jsContext.jsonMilliseconds,
                    "jscontext_template_ms": jsContext.templateMilliseconds,
                    "jscontext_total_ms": contextTotal,
                    "wkwebview_json_ms": webViewResult.jsonMilliseconds,
                    "wkwebview_template_ms": webViewResult.templateMilliseconds,
                    "wkwebview_total_ms": webViewTotal,
                    "speedup_ratio": ratio,
                    "interpreter_penalty_observed": ratio >= 2.0,
                    "measurement_valid": correct,
                ],
                detail: correct
                    ? "MB-scale JSON parse + template benchmark; JSContext is the non-WKWebView baseline the PLAN names (whether it compiles JIT here is not asserted)"
                    : "the JIT benchmark produced no usable measurement "
                        + "(informational row, not a gate)")
        } catch {
            report.record(probe: "jit.wkwebview-vs-jscontext", kind: "jit",
                          status: .info, gating: false,
                          metrics: ["measurement_valid": false],
                          detail: "the JIT benchmark could not run (informational "
                            + "row, not a gate): \(error)")
        }
    }

    private struct BenchmarkResult {
        var bytes: Int
        var jsonMilliseconds: Double
        var templateMilliseconds: Double
        var totalMilliseconds: Double
    }

    private func parseBenchmark(_ text: String) throws -> BenchmarkResult {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.unexpected("the benchmark returned no JSON object")
        }
        return BenchmarkResult(
            bytes: intValue(object["bytes"]) ?? 0,
            jsonMilliseconds: doubleValue(object["json_ms"]) ?? -1,
            templateMilliseconds: doubleValue(object["template_ms"]) ?? -1,
            totalMilliseconds: doubleValue(object["total_ms"]) ?? -1)
    }

    private func measureJSContext(script: String) throws -> BenchmarkResult {
        guard let context = JSContext() else {
            throw ProbeError.unexpected("JavaScriptCore could not create a JSContext")
        }
        var scriptError: String?
        context.exceptionHandler = { _, exception in
            scriptError = exception?.toString() ?? "unknown JavaScriptCore exception"
        }
        guard let value = context.evaluateScript(script), scriptError == nil else {
            throw ProbeError.unexpected(scriptError ?? "JavaScriptCore returned no result")
        }
        return try parseBenchmark(value.toString() ?? "")
    }

    private func measureWebView(script: String, site: ProbeSite,
                                anchor: UIView?) async throws -> BenchmarkResult {
        let server = try await ProbeServer.start(site: site, crossOriginIsolation: true)
        let webView = ProbeWebView(visible: anchor != nil, host: anchor)
        do {
            try await webView.load(server.timerURL)
            let value = try await webView.evaluate(script)
            let text: String
            if let string = value as? String {
                text = string
            } else {
                text = String(describing: value ?? "")
            }
            let result = try parseBenchmark(text)
            webView.teardown()
            await server.stop()
            return result
        } catch {
            webView.teardown()
            await server.stop()
            throw error
        }
    }

    // MARK: - WorkspaceLog checkpoint

    /// 100 one-KiB writes through WorkspaceLog and an epoch close.
    public func runCheckpoint() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-probes-checkpoint-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let configuration = WorkspaceLogConfiguration(root: root)
            let log = try WorkspaceLog(configuration: configuration,
                                       bootID: Data((0..<16).map { UInt8($0 + 1) }))
            let payload = Data(repeating: 0x5A, count: 1024)

            var appendMilliseconds = 0.0
            try await measure { elapsed in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<100 {
                        group.addTask {
                            _ = try await log.append(VfsMutationBody(
                                op: .write,
                                mode: 0o644,
                                mflags: [.entryChanged],
                                path: String(format: "/dsh/workspace/file-%03d.txt", index),
                                data: payload))
                        }
                    }
                    try await group.waitForAll()
                }
                appendMilliseconds = elapsed()
            }

            var materializeMilliseconds = 0.0
            let materialized = try await measure { elapsed in
                let watermark = try await log.materialize()
                materializeMilliseconds = elapsed()
                return watermark
            }

            var closeMilliseconds = 0.0
            let ack = try await measure { elapsed in
                let ack = try await log.closeEpoch()
                closeMilliseconds = elapsed()
                return ack
            }

            let positions = await log.positions()
            let directory = root.appendingPathComponent("materialized/workspace")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let correct = files.count == 100
                && materialized == 100
                && positions.ackedMseq >= 100
                && positions.durableMseq >= 100
            let threshold = ProbeThreshold(
                name: "checkpoint_100_files",
                value: .double(100),
                unit: "ms",
                source: "PLAN W1-LOG (informational materialization bound)",
                comparison: .lessThanOrEqual,
                measured: .double(appendMilliseconds),
                gating: false)

            report.record(
                probe: "log.checkpoint-100-files",
                kind: "log",
                status: probeStatus(correct: correct, threshold: threshold),
                gating: true,
                metrics: [
                    "files": files.count,
                    "append_100_ms": appendMilliseconds,
                    "materialize_ms": materializeMilliseconds,
                    "close_epoch_ms": closeMilliseconds,
                    "materialized_upto_mseq": materialized,
                    "acked_mseq": positions.ackedMseq,
                    "durable_mseq": ack.uptoMseq,
                ],
                threshold: threshold,
                detail: "100 one-KiB writes through WorkspaceLog (level-1 ack + D8 materialization); the bound is informational per W1-LOG")
        } catch {
            report.record(probe: "log.checkpoint-100-files", kind: "log", status: .fail,
                          gating: true, metrics: [:],
                          detail: "the checkpoint probe could not run: \(error)")
        }
    }

    // MARK: - Row helpers

    private func recordFetch(probe: String, fetch: [String: Any]) {
        let status = intValue(fetch["status"]) ?? 0
        let requestBytes = intValue(fetch["request_bytes"]) ?? 0
        let responseBytes = intValue(fetch["response_bytes"]) ?? 0
        let matches = boolValue(fetch["matches"]) ?? false
        let elapsed = doubleValue(fetch["elapsed_ms"]) ?? -1
        let correct = status == 200 && matches && responseBytes == requestBytes
        report.record(
            probe: probe,
            kind: "channel",
            status: probeStatus(correct: correct),
            gating: true,
            metrics: [
                "status": status,
                "request_bytes": requestBytes,
                "response_bytes": responseBytes,
                "matches": matches,
                "elapsed_ms": max(0, elapsed),
            ],
            detail: "same-origin fetch POST through the loopback /v1/http echo route")
    }

    private func recordNDJSON(_ ndjson: [String: Any]) {
        let status = intValue(ndjson["status"]) ?? 0
        let chunks = intValue(ndjson["chunks"]) ?? 0
        let lines = intValue(ndjson["lines"]) ?? 0
        let parsed = intValue(ndjson["parsed_lines"]) ?? 0
        let firstChunk = doubleValue(ndjson["first_chunk_ms"]) ?? -1
        let total = doubleValue(ndjson["total_ms"]) ?? -1
        let correct = status == 200 && lines == 3 && parsed == 3 && firstChunk >= 0
        report.record(
            probe: "channel.ndjson-first-chunk",
            kind: "channel",
            status: probeStatus(correct: correct),
            gating: true,
            metrics: [
                "status": status,
                "chunks": chunks,
                "lines": lines,
                "parsed_lines": parsed,
                "first_chunk_ms": max(0, firstChunk),
                "total_ms": max(0, total),
                "streamed_incrementally": chunks >= 2 && firstChunk < total,
            ],
            detail: "three JSON lines read from the chunked loopback response; the first-chunk latency is informational")
    }

    private func recordWebSocketEcho(_ websocket: [String: Any]) {
        let count = intValue(websocket["count"]) ?? 0
        let p50 = doubleValue(websocket["p50_ms"]) ?? -1
        let p95 = doubleValue(websocket["p95_ms"]) ?? -1
        let minimum = doubleValue(websocket["min_ms"]) ?? -1
        let maximum = doubleValue(websocket["max_ms"]) ?? -1
        let threshold = ProbeThreshold(
            name: "loopback_round_trip_p95",
            value: .double(5.0),
            unit: "ms",
            source: "PLAN §2.5 and spec/v1/budgets.md §4",
            comparison: .lessThanOrEqual,
            measured: p95 >= 0 ? .double(p95) : .null,
            gating: true)
        let correct = count == 1000 && p50 >= 0
        report.record(
            probe: "channel.ws-echo-1000",
            kind: "channel",
            status: probeStatus(correct: correct, threshold: threshold),
            gating: true,
            metrics: [
                "count": count,
                "p50_ms": max(0, p50),
                "p95_ms": max(0, p95),
                "min_ms": max(0, minimum),
                "max_ms": max(0, maximum),
            ],
            threshold: threshold,
            detail: "1000 sequential binary echoes over the real loopback WebSocket")
    }

    private func recordMissing(_ probe: String, _ key: String) {
        report.record(
            probe: probe,
            kind: "channel",
            status: .fail,
            gating: true,
            metrics: [:],
            detail: "the Worker result did not contain '\(key)'")
    }

    // MARK: - Test plumbing

    private func withServer<T>(isolation: Bool,
                               _ body: (ProbeServer) async throws -> T) async throws -> T {
        let site = try ProbeSite()
        let server = try await ProbeServer.start(site: site,
                                                 crossOriginIsolation: isolation)
        do {
            let value = try await body(server)
            await server.stop()
            site.cleanup()
            return value
        } catch {
            await server.stop()
            site.cleanup()
            throw error
        }
    }

    private func responseHeader(_ url: URL, name: String) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return nil
        }
        return http.value(forHTTPHeaderField: name)
    }

    /// Runs `body` and returns its value together with the elapsed milliseconds
    /// measured inside the body through the supplied closure.
    private func measure<T>(_ body: @escaping (() -> Double) async throws -> T) async throws -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await body {
            let duration = start.duration(to: clock.now)
            let components = duration.components
            return Double(components.seconds) * 1000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
        return result
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let boolean = value as? Bool { return boolean }
        return nil
    }
}
