// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — iOS Simulator smoke support (PLAN W3-SIM / W2-SMOKE).
//
// The evidence readers are the landed macOS smoke readers from the regular
// SwiftPM target `PhoneDSHHarness`, which this target links as a
// package product. The WAL replay semantics, the journal wire projection, the
// step-machine snapshot layout and the scripted model upstream therefore have
// one source of truth; the wrappers at the bottom only shorten the call sites.
//
// NOT_VERIFIED on an iPhone: this repository has no physical-device run.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHHarness
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLog
import PhoneDSHWire

// MARK: - Console / event log

/// One captured console line (level + text).
struct SimConsoleLine: Sendable {
    var level: String
    var text: String
}

/// Durable lifecycle evidence for one prompt, correlated by its unique user
/// message marker and the DSH turn ID carried by start/end events.
struct SimHarnessTurnReceipt: Equatable, Sendable {
    var turnID: String
    var startedSequence: UInt64
    var endedSequence: UInt64
    var reason: HarnessTurnEnd
    var toolErrors: [String]
}

/// Collects the host event stream and the harness streams for the report.
final class SimSmokeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var consoleStorage: [SimConsoleLine] = []
    private var hostErrorStorage: [String] = []
    private var helloStorage: [PhoneDSHWorkerHello] = []
    private var restartStorage: [WebEngineRestartReport] = []
    private var stateStorage: [String] = []
    private var harnessStorage: [HarnessEvent] = []
    private var harnessErrorStorage: [String] = []
    private var tasks: [Task<Void, Never>] = []

    /// Starts consuming the host's ordered event sequence.
    func attach(host: PhoneDSHHost) {
        let stream = host.eventStream()
        let task = Task { [weak self] in
            for await event in stream {
                self?.record(host: event)
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    /// Starts consuming one harness session stream.
    func attach(harness: any AgentHarness, sessionID: String) {
        let stream = harness.events(sessionID: sessionID, after: nil)
        let task = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.record(harness: event)
                }
            } catch {
                self?.record(harnessError: String(describing: error))
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    /// Stops every stream consumer. The host ends its own bus in `stop()`.
    func stop() {
        lock.lock()
        let running = tasks
        tasks.removeAll()
        lock.unlock()
        for task in running { task.cancel() }
    }

    private func record(host event: PhoneDSHEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .console(let payload):
            consoleStorage.append(SimConsoleLine(level: payload.level.rawValue,
                                                 text: payload.text))
        case .error(let message):
            hostErrorStorage.append(message)
        case .workerHello(let hello):
            helloStorage.append(hello)
        case .restarted(let report):
            restartStorage.append(report)
        case .stateChanged(let from, let to):
            stateStorage.append("\(from.rawValue)->\(to.rawValue)")
        default:
            break
        }
    }

    private func record(harness event: HarnessEvent) {
        lock.lock()
        defer { lock.unlock() }
        harnessStorage.append(event)
    }

    private func record(harnessError: String) {
        lock.lock()
        defer { lock.unlock() }
        harnessErrorStorage.append(harnessError)
    }

    var console: [SimConsoleLine] {
        lock.lock()
        defer { lock.unlock() }
        return consoleStorage
    }

    var hostErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hostErrorStorage
    }

    var hellos: [PhoneDSHWorkerHello] {
        lock.lock()
        defer { lock.unlock() }
        return helloStorage
    }

    var restarts: [WebEngineRestartReport] {
        lock.lock()
        defer { lock.unlock() }
        return restartStorage
    }

    var stateChanges: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stateStorage
    }

    var harnessEvents: [HarnessEvent] {
        lock.lock()
        defer { lock.unlock() }
        return harnessStorage
    }

    /// Highest durable event sequence currently observed. Callers capture this
    /// immediately before sending a prompt, then require its prompt marker and
    /// matching turn lifecycle to occur after the watermark. This excludes
    /// events replayed by a new `events(after: nil)` subscription.
    var harnessSequenceWatermark: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return harnessStorage.compactMap(\.seq).max() ?? 0
    }

    /// Returns a completed lifecycle only when a durable user message carrying
    /// `promptMarker` and a matching start/end pair all follow the captured
    /// sequence watermark.
    func completedHarnessTurn(after watermark: UInt64,
                              promptMarker: String) -> SimHarnessTurnReceipt? {
        lock.lock()
        defer { lock.unlock() }

        let events = harnessStorage.compactMap { event -> (UInt64, HarnessEvent.Kind)? in
            guard let sequence = event.seq, sequence > watermark else { return nil }
            return (sequence, event.kind)
        }.sorted { $0.0 < $1.0 }
        guard let promptSequence = events.first(where: {
            switch $0.1 {
            case .userMessage(let text, _):
                return text.contains(promptMarker)
            case .inboxSpliced(let messages):
                return messages.contains { $0.text.contains(promptMarker) }
            default:
                return false
            }
        })?.0 else {
            return nil
        }

        for (startedSequence, kind) in events where startedSequence > promptSequence {
            guard case .turnStarted(let turnID) = kind else { continue }
            guard let ended = events.first(where: { pair in
                let (sequence, kind) = pair
                guard sequence > startedSequence,
                      case .turnEnded(let endedTurnID, _) = kind,
                      endedTurnID == turnID else {
                    return false
                }
                return true
            }), case .turnEnded(_, let reason) = ended.1 else {
                continue
            }
            let toolErrors = events.compactMap { pair -> String? in
                let (sequence, kind) = pair
                guard sequence > startedSequence, sequence < ended.0,
                      case .toolResult(_, let isError, let summary) = kind,
                      isError else {
                    return nil
                }
                return summary
            }
            return SimHarnessTurnReceipt(turnID: turnID,
                                         startedSequence: startedSequence,
                                         endedSequence: ended.0,
                                         reason: reason,
                                         toolErrors: toolErrors)
        }
        return nil
    }

    var harnessErrors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return harnessErrorStorage
    }

    /// Console lines whose text mentions the runtime's not-implemented path.
    var notImplementedFailLines: [String] {
        console
            .filter { $0.text.range(of: "notImplementedFail", options: .caseInsensitive) != nil }
            .map { "\($0.level): \($0.text)" }
    }

    /// The last `count` console lines, formatted for a failure message.
    func tail(_ count: Int) -> [String] {
        console.suffix(max(0, count)).map { "\($0.level): \($0.text)" }
    }
}

// MARK: - Evidence readers

// The readers themselves are `readWALSummary` / `readJournalSummary` /
// `readStepSummary` in the `PhoneDSHHarness` package target (linked by
// this target through project.yml). The wrappers keep the simulator call sites
// explicit; no evidence format is parsed in this directory.

/// Reads and replays the current WAL against `targetPath` (D9 host semantics).
func simReadWALSummary(workspace: URL, targetPath: String) throws -> SmokeWALSummary {
    try readWALSummary(workspace: workspace, targetPath: targetPath)
}

/// Parses `journal.xljournal` and returns the dispatched/completed evidence.
func simReadJournalSummary(workspace: URL,
                           sessionID: String?) throws -> SmokeJournalSummary {
    try readJournalSummary(workspace: workspace, sessionID: sessionID)
}

/// Reads the step machine's persisted state for one session.
func simReadStepSummary(workspace: URL, sessionID: String) throws -> SmokeStepSummary {
    try readStepSummary(workspace: workspace, sessionID: sessionID)
}

// MARK: - Real-CPython `/v1/http` acceptance

/// The real Worker `urllib` acceptance used by the simulator smoke.
///
/// `scripts/ci/sim.sh` boots the packed image in a real `WKWebView`; the DSH
/// `bash` tool then runs this script with `python3 -c`. The script makes one
/// allow-listed POST to the local scripted model, one GET to a missing path
/// (404) and one request to a host the allow-list must refuse. It writes the
/// structured result into the VFS only after every assertion passed, so the
/// host's materialized-file assertion is the evidence; the scripted model's
/// fixed final text is never treated as success.
///
/// This mirrors the fixture sentinels in ``PhoneDSHSimSmokeTests`` without
/// carrying a credential: the guest checks only those static values, and the
/// result carries booleans, never the environment values themselves.
enum SimPythonHTTPAcceptance {
    static let successMarker = "PYTHON_HTTP_ACCEPTANCE_OK"
    /// Static fixture values from the smoke host configuration.
    static let sentinels = ["sim-launch-token", "sim-host-key"]

    /// One `python3 -c` command for the DSH bash tool.
    ///
    /// The Python source deliberately contains no single quote, so the shell
    /// can carry it in one single-quoted argument. Any other shell quoting
    /// would re-interpret the Python program.
    static func command(origin: URL, marker: String, resultPath: String) -> String {
        "python3 -c '" + script(origin: origin.absoluteString, marker: marker,
                                resultPath: resultPath) + "'"
    }

    static func script(origin: String, marker: String, resultPath: String) -> String {
        let sentinelList = sentinels.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        import json
        import os
        import sys
        import urllib.error
        import urllib.request

        MARKER = "\(marker)"
        BASE = "\(origin)"
        RESULT = "\(resultPath)"
        SENTINELS = [\(sentinelList)]

        assert sys.platform == "wasi", "expected the WASI interpreter, got " + sys.platform
        assert os.uname().machine == "wasm32", "expected wasm32, got " + os.uname().machine

        leaks = []
        for name, value in os.environ.items():
            for sentinel in SENTINELS:
                if sentinel in value:
                    leaks.append(name)
        leaks = sorted(set(leaks))

        post_body = json.dumps({"python_acceptance": MARKER, "messages": []}).encode("utf-8")
        post_request = urllib.request.Request(
            BASE + "/v1/messages",
            data=post_body,
            method="POST",
            headers={"Content-Type": "application/json", "X-Python-Acceptance": MARKER},
        )
        with urllib.request.urlopen(post_request, timeout=30) as response:
            post_status = response.status
            post_content_type = response.headers.get("Content-Type", "")
            post_bytes = response.read()
        assert post_status == 200, "POST status is " + str(post_status)
        assert len(post_bytes) > 0, "POST body is empty"
        assert b"event: message_start" in post_bytes, "POST body is not the Messages SSE"
        assert b"data:" in post_bytes, "POST body has no SSE data line"
        assert "text/event-stream" in post_content_type, "POST content type is " + post_content_type

        missing_path = "/missing-" + MARKER
        try:
            urllib.request.urlopen(BASE + missing_path, timeout=30)
            raise AssertionError("GET on a missing path did not raise HTTPError")
        except urllib.error.HTTPError as error:
            missing_status = error.code
            missing_bytes = error.read()
        assert missing_status == 404, "GET missing status is " + str(missing_status)
        assert len(missing_bytes) > 0, "GET missing body is empty"
        assert b"no route" in missing_bytes, "GET missing body is not the mock 404"

        try:
            urllib.request.urlopen("http://forbidden.invalid/v1/messages", timeout=30)
            raise AssertionError("the forbidden host was not rejected")
        except urllib.error.HTTPError as error:
            forbidden_status = error.code
            forbidden_bytes = error.read()
        assert forbidden_status == 403, "forbidden status is " + str(forbidden_status)
        assert b"host_not_allowed" in forbidden_bytes, "forbidden body has no host_not_allowed code"

        assert leaks == [], "guest environment contains a host sentinel: " + ",".join(leaks)
        assert os.environ.get("PDSH_CHANNEL_TOKEN", "") == "", "guest environment has PDSH_CHANNEL_TOKEN"
        assert os.environ.get("PDSH_PYTHON_HTTP", "") == "1", "the Python HTTP bridge flag is missing"

        result = {
            "schema": 1,
            "marker": MARKER,
            "python": sys.version.split()[0],
            "platform": sys.platform,
            "machine": os.uname().machine,
            "post": {
                "status": post_status,
                "body_bytes": len(post_bytes),
                "content_type": post_content_type,
                "sse_message_start": b"event: message_start" in post_bytes,
                "sse_data": b"data:" in post_bytes,
            },
            "get_missing": {
                "status": missing_status,
                "body_bytes": len(missing_bytes),
                "body_has_no_route": b"no route" in missing_bytes,
            },
            "forbidden": {
                "status": forbidden_status,
                "body_bytes": len(forbidden_bytes),
                "host_not_allowed": b"host_not_allowed" in forbidden_bytes,
            },
            "env": {
                "leaks": leaks,
                "has_channel_token": os.environ.get("PDSH_CHANNEL_TOKEN", "") != "",
                "has_channel_origin": os.environ.get("PDSH_CHANNEL_ORIGIN", "") != "",
                "python_http_flag": os.environ.get("PDSH_PYTHON_HTTP", ""),
            },
            "success": True,
        }
        with open(RESULT, "w", encoding="utf-8") as handle:
            json.dump(result, handle, sort_keys=True)
        print("PYTHON_HTTP_ACCEPTANCE_OK " + MARKER)
        """
    }

    static func readResult(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimError.artifact("the Python HTTP result is not a JSON object: \(url.path)")
        }
        return object
    }

    /// The Python POST is the only `/v1/messages` request whose top-level body
    /// names the acceptance marker. The DSH transcript also contains the
    /// command text, so a substring search would misidentify a model request.
    static func pythonRequest(in requests: [MockModelRequest],
                              marker: String) -> MockModelRequest? {
        requests.first { request in
            guard request.path.hasSuffix("/v1/messages"),
                  let object = try? JSONSerialization.jsonObject(with: request.body),
                  let dictionary = object as? [String: Any],
                  dictionary["python_acceptance"] as? String == marker else {
                return false
            }
            return true
        }
    }

    /// Whether the last transcript message contains a tool result whose text
    /// includes this run's unique success marker. This binds the model
    /// follow-up to the Python invocation instead of any older session result.
    static func lastMessageToolResultContains(_ body: Data, marker: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]],
              let last = messages.last,
              let content = last["content"] as? [[String: Any]] else {
            return false
        }
        for block in content where block["type"] as? String == "tool_result" {
            if let text = block["content"] as? String, text.contains(marker) {
                return true
            }
            if let textBlocks = block["content"] as? [[String: Any]],
               textBlocks.contains(where: {
                   ($0["text"] as? String)?.contains(marker) == true
               }) {
                return true
            }
        }
        return false
    }
}
