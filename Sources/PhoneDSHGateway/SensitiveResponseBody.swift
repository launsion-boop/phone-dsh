// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: host-managed MCP response body privacy.
//
// A host-managed MCP credential (Credential.Kind.headers) is injected by the
// gateway itself. The upstream is the only party that sees the real value, so
// it can echo that value in a non-2xx body, a JSON-RPC `isError` result or an
// SSE event. Those bytes must not reach the Worker/ToolRuntime/Session.
//
// This file owns the response-side rewrite. It deliberately works on the
// exact values the credential router injected rather than guessing token
// shapes with a regex. JSON is rewritten through JSONSerialization so a short
// header value can never corrupt the JSON structure, and SSE is rewritten one
// event at a time so normal streaming is not held until the connection closes.

import Foundation
#if canImport(Darwin)
import CoreFoundation
#endif

/// How a host-managed (sensitive) response body is handled after the head has
/// been received.
enum SensitiveResponseMode {
    /// Non-sensitive response: preserve the existing pass-through behaviour.
    case ordinary
    /// The upstream status already describes the failure; replace the complete
    /// upstream body with one controlled diagnostic.
    case controlled(Data)
    /// A 2xx body whose JSON/text is buffered up to a fixed bound until the
    /// response ends. Oversized bodies fail closed with a controlled
    /// diagnostic.
    case buffered
    /// A 2xx `text/event-stream` body sanitized one event at a time.
    case eventStream(SensitiveSSESanitizer)
    /// A status with no response body (204/205/304/HEAD).
    case suppressed

    /// True when the upstream body is discarded, so a body transport error
    /// after the head does not invalidate the controlled response.
    var discardsUpstreamBody: Bool {
        switch self {
        case .controlled, .suppressed:
            return true
        case .ordinary, .buffered, .eventStream:
            return false
        }
    }
}

enum SensitiveResponseBody {
    /// JSON-RPC application error used for a withheld host-managed body.
    static let controlledErrorCode = -32000

    /// Upper bound of a buffered (non-SSE) 2xx host-managed body. The upstream
    /// is untrusted, so exceeding this limit fails closed with a controlled
    /// diagnostic instead of growing the App's memory without bound.
    static let maximumBufferedBodyBytes = 4 * 1024 * 1024

    /// Upper bound of one pending SSE event. An upstream can keep a `data:`
    /// line open forever, so the streaming path needs the same fail-closed
    /// bound as the buffered path; otherwise the App would accumulate bytes
    /// until the URLSession resource timeout.
    static let maximumEventStreamEventBytes = maximumBufferedBodyBytes

    /// A short, secret-free JSON-RPC error. The HTTP status is preserved so
    /// the MCP client still reports the real class (401/403/5xx/...).
    static func controlledDiagnostic(status: Int) -> Data {
        makeDiagnostic(message: "MCP upstream returned HTTP \(status); response body withheld")
    }

    /// The fail-closed diagnostic for a buffered 2xx body that exceeded
    /// ``maximumBufferedBodyBytes``. No upstream byte is included.
    static func controlledOversizeDiagnostic() -> Data {
        makeDiagnostic(message: "MCP upstream response exceeded the host-managed body limit; response body withheld")
    }

    /// The fail-closed diagnostic for an SSE event that exceeded
    /// ``maximumEventStreamEventBytes`` before its blank-line terminator.
    static func controlledEventStreamOversizeDiagnostic() -> Data {
        makeDiagnostic(message: "MCP upstream event stream exceeded the host-managed event limit; response body withheld")
    }

    /// Wraps the oversize diagnostic in an SSE event, because the response head
    /// has already told the Worker that this is `text/event-stream`.
    static func controlledEventStreamOversizeEvent() -> Data {
        var event = Data("data: ".utf8)
        event.append(controlledEventStreamOversizeDiagnostic())
        event.append(Data("\n\n".utf8))
        return event
    }

    private static func makeDiagnostic(message: String) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": [
                "code": controlledErrorCode,
                "message": message,
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object,
                                                  options: [.sortedKeys]) {
            return data
        }
        return Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"MCP upstream response body withheld"}}"#.utf8)
    }

    /// Statuses and methods whose response must not carry body bytes.
    static func statusForbidsBody(status: Int, method: String) -> Bool {
        if method.caseInsensitiveCompare("HEAD") == .orderedSame {
            return true
        }
        switch status {
        case 100..<200, 204, 205, 304:
            return true
        default:
            return false
        }
    }

    static func isEventStream(_ headers: [String: String]) -> Bool {
        contentType(headers).contains("text/event-stream")
    }

    static func contentType(_ headers: [String: String]) -> String {
        guard let header = headers.first(where: {
            $0.key.caseInsensitiveCompare("content-type") == .orderedSame
        }) else {
            return ""
        }
        return header.value.lowercased()
    }

    /// Sanitizes a complete non-SSE body. JSON is decoded and its string values
    /// are rewritten, preserving valid JSON and the JSON-RPC `id` value.
    static func sanitizeBufferedBody(_ data: Data, secrets: [String]) -> Data {
        let secrets = normalizedSecrets(secrets)
        guard !data.isEmpty, !secrets.isEmpty else { return data }
        if let object = try? JSONSerialization.jsonObject(with: data,
                                                          options: [.fragmentsAllowed]) {
            let (redacted, changed) = redactJSON(object, secrets: secrets)
            guard changed else { return data }
            if let encoded = try? JSONSerialization.data(withJSONObject: redacted,
                                                         options: [.fragmentsAllowed]) {
                return encoded
            }
            return controlledDiagnostic(status: 200)
        }
        // Not valid JSON: an exact text replacement cannot break a JSON
        // structure that does not exist. It is still scoped to the values the
        // host actually injected.
        return redactText(data, secrets: secrets)
    }

    /// Sanitizes one complete SSE event (including its terminating blank line).
    /// Events with no injected value are returned byte-for-byte unchanged.
    ///
    /// SSE allows LF, CRLF and CR line endings. Lines are split on any of the
    /// three and rebuilt with their original terminators, so a CR-only event
    /// keeps its real blank-line terminator instead of being merged into the
    /// next event.
    static func sanitizeEvent(_ event: Data, secrets: [String]) -> Data {
        let secrets = normalizedSecrets(secrets)
        guard !secrets.isEmpty else { return event }
        guard let text = String(data: event, encoding: .utf8) else {
            // A malformed event must not become a bypass. Replace the exact
            // injected byte sequences; there is no JSON framing left to keep
            // valid once the event itself is not UTF-8.
            return redactText(event, secrets: secrets)
        }
        let lines = splitSSELines(text)
        var dataIndexes: [Int] = []
        var payloads: [String] = []
        for (index, line) in lines.enumerated() {
            guard line.content.hasPrefix("data:") else { continue }
            dataIndexes.append(index)
            var value = String(line.content.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            payloads.append(value)
        }
        guard !dataIndexes.isEmpty else {
            // Malformed/comment-only event that still echoed a value: redact
            // the text, never the JSON framing of a data event.
            return Data(redactText(text, secrets: secrets).utf8)
        }
        let payload = payloads.joined(separator: "\n")
        let sanitized = sanitizePayload(payload, secrets: secrets)
        let sanitizedLines = sanitized.components(separatedBy: "\n")
        var changed = sanitized != payload
        var output = ""
        let firstDataIndex = dataIndexes[0]
        for (index, line) in lines.enumerated() {
            if dataIndexes.contains(index) {
                guard index == firstDataIndex else { continue }
                // A multi-line sanitized payload keeps the line ending of the
                // original data line. The last replacement uses the original
                // terminator too, so the following blank line still terminates
                // the event for CR-only streams.
                let separator = line.terminator.isEmpty ? "\n" : line.terminator
                for (offset, sanitizedLine) in sanitizedLines.enumerated() {
                    output += "data: " + sanitizedLine
                    let terminator = offset < sanitizedLines.count - 1
                        ? separator
                        : line.terminator
                    output += terminator
                }
            } else {
                let redactedLine = redactText(line.content, secrets: secrets)
                changed = changed || redactedLine != line.content
                output += redactedLine
                output += line.terminator
            }
        }
        guard changed else { return event }
        return Data(output.utf8)
    }

    private struct SSELine {
        var content: String
        var terminator: String
    }

    /// Splits an SSE event into content/terminator pairs. A final line without
    /// a terminator is returned with an empty terminator so it round-trips.
    ///
    /// The scan is over UTF-8 bytes, not Swift `Character`s: CRLF is a single
    /// grapheme cluster, so character-wise comparison would miss both `\r` and
    /// `\n` and leave the following blank line inside the previous event. The
    /// line terminators are ASCII, so scanning bytes cannot split a multi-byte
    /// UTF-8 scalar.
    private static func splitSSELines(_ text: String) -> [SSELine] {
        let bytes = Array(text.utf8)
        var lines: [SSELine] = []
        var contentStart = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x0D: // CR
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    lines.append(SSELine(
                        content: String(decoding: bytes[contentStart..<index], as: UTF8.self),
                        terminator: "\r\n"))
                    index += 2
                } else {
                    lines.append(SSELine(
                        content: String(decoding: bytes[contentStart..<index], as: UTF8.self),
                        terminator: "\r"))
                    index += 1
                }
                contentStart = index
            case 0x0A: // LF
                lines.append(SSELine(
                    content: String(decoding: bytes[contentStart..<index], as: UTF8.self),
                    terminator: "\n"))
                index += 1
                contentStart = index
            default:
                index += 1
            }
        }
        if contentStart < bytes.count {
            lines.append(SSELine(
                content: String(decoding: bytes[contentStart...], as: UTF8.self),
                terminator: ""))
        }
        return lines
    }

    private static func sanitizePayload(_ payload: String, secrets: [String]) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return redactText(payload, secrets: secrets)
        }
        let (redacted, changed) = redactJSON(object, secrets: secrets)
        guard changed,
              let encoded = try? JSONSerialization.data(withJSONObject: redacted,
                                                        options: [.fragmentsAllowed]),
              let text = String(data: encoded, encoding: .utf8) else {
            guard changed else { return payload }
            // The parsed JSON could not be re-encoded after redaction. Replace
            // the event with a valid controlled diagnostic instead of applying
            // a byte replacement that might break the JSON structure.
            if let fallback = String(data: controlledDiagnostic(status: 200),
                                     encoding: .utf8) {
                return fallback
            }
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"MCP upstream response body withheld"}}"#
        }
        return text
    }

    // MARK: - Exact-value helpers

    private static func normalizedSecrets(_ secrets: [String]) -> [String] {
        Array(Set(secrets.filter { !$0.isEmpty }))
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
    }

    private static func redactText(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return result
    }

    private static func redactText(_ data: Data, secrets: [String]) -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            // Binary bodies are not MCP JSON/SSE. Replace the exact injected
            // byte sequences without touching any JSON framing.
            var result = data
            for secret in secrets where !secret.isEmpty {
                result = replacingOccurrences(of: Data(secret.utf8),
                                              with: Data("[redacted]".utf8),
                                              in: result)
            }
            return result
        }
        return Data(redactText(text, secrets: secrets).utf8)
    }

    /// Exact byte replacement for a non-UTF-8 body. `Data` has no
    /// `replacingOccurrences(of:with:)`, and restarting the search at the
    /// beginning after each insertion would loop forever when a short injected
    /// value (for example `a`) appears inside `[redacted]`. This scans once per
    /// occurrence and resumes after the inserted replacement.
    private static func replacingOccurrences(of needle: Data,
                                             with replacement: Data,
                                             in data: Data) -> Data {
        guard !needle.isEmpty else { return data }
        var result = Data()
        result.reserveCapacity(data.count)
        var cursor = data.startIndex
        while cursor < data.endIndex,
              let range = data.range(of: needle, options: [], in: cursor..<data.endIndex) {
            result.append(data[cursor..<range.lowerBound])
            result.append(replacement)
            cursor = range.upperBound
        }
        result.append(data[cursor..<data.endIndex])
        return result
    }

    private static func redactJSON(_ value: Any,
                                   secrets: [String]) -> (Any, Bool) {
        if let string = value as? String {
            let redacted = redactText(string, secrets: secrets)
            return (redacted, redacted != string)
        }
        if let number = value as? NSNumber {
            // JSONSerialization represents both numbers and booleans as
            // NSNumber. A numeric credential (for example an API key of
            // "12345") can be echoed as a JSON number, so compare the exact
            // textual representation. A boolean is compared as its JSON token
            // ("true"/"false"), never as NSNumber's "1"/"0": a numeric secret
            // of "1" must not rewrite every boolean in a normal response.
            let text: String
            #if canImport(Darwin)
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                text = number.boolValue ? "true" : "false"
            } else {
                text = number.stringValue
            }
            #else
            text = number.stringValue
            #endif
            let redacted = redactText(text, secrets: secrets)
            guard redacted != text else { return (value, false) }
            return (redacted, true)
        }
        if let array = value as? [Any] {
            var changed = false
            var result: [Any] = []
            result.reserveCapacity(array.count)
            for element in array {
                let (redacted, elementChanged) = redactJSON(element, secrets: secrets)
                result.append(redacted)
                changed = changed || elementChanged
            }
            return (result, changed)
        }
        if let dictionary = value as? [String: Any] {
            var changed = false
            var result: [String: Any] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                // Field names are part of the bytes the Worker receives. Redact
                // them too, except for the JSON-RPC/MCP structural keys whose
                // names must survive for the client to parse the error and its
                // id. Exact-value replacement (not a byte scan) keeps the JSON
                // valid even when the injected value is short or escaped.
                var outputKey = key
                if !Self.protectedJSONKeys.contains(key) {
                    outputKey = redactText(key, secrets: secrets)
                    changed = changed || outputKey != key
                }
                let (redacted, elementChanged) = redactJSON(element, secrets: secrets)
                result[outputKey] = redacted
                changed = changed || elementChanged
            }
            return (result, changed)
        }
        return (value, false)
    }

    /// JSON-RPC and MCP field names that carry protocol meaning. These are not
    /// rewritten so a short injected value cannot destroy the JSON-RPC id or
    /// the error/result envelope. Every other key is redacted like a value.
    private static let protectedJSONKeys: Set<String> = [
        "jsonrpc", "id", "result", "error", "code", "message", "data", "content",
        "type", "text", "isError", "name", "description", "title", "uri",
        "mimeType", "blob", "resource", "structuredContent", "tools",
        "inputSchema", "outputSchema", "arguments", "params", "method", "_meta",
        "annotations", "audience", "priority", "lastModified", "nextCursor",
    ]
}

/// Incremental SSE event splitter and sanitizer. It holds at most one upstream
/// event, never the whole connection, so normal events still reach the Worker
/// as they arrive. A single event is bounded by
/// ``SensitiveResponseBody/maximumEventStreamEventBytes``: an upstream that
/// never sends a blank line is cancelled and failed closed instead of growing
/// the buffer until the URLSession resource timeout.
final class SensitiveSSESanitizer {
    private let secrets: [String]
    private let maximumEventBytes: Int
    private var buffer = Data()

    /// True once an event exceeded ``maximumEventBytes``. The caller must stop
    /// forwarding the stream, cancel the upstream attempt, and emit a
    /// controlled diagnostic event.
    private(set) var overflowed = false

    init(secrets: [String],
         maximumEventBytes: Int = SensitiveResponseBody.maximumEventStreamEventBytes) {
        self.secrets = secrets.filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
        self.maximumEventBytes = max(1, maximumEventBytes)
    }

    /// Appends an upstream chunk and returns every complete event now ready.
    /// Events completed before an oversized event are still returned; the
    /// caller checks ``overflowed`` after forwarding them.
    func consume(_ data: Data) -> [Data] {
        guard !overflowed else { return [] }
        buffer.append(data)
        var events: [Data] = []
        while let range = Self.nextEventRange(in: buffer) {
            let eventLength = buffer.distance(from: buffer.startIndex,
                                              to: range.upperBound)
            guard eventLength <= maximumEventBytes else {
                markOverflow()
                return events
            }
            let event = Data(buffer[buffer.startIndex..<range.upperBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            events.append(SensitiveResponseBody.sanitizeEvent(event, secrets: secrets))
        }
        // No blank line yet: the pending event itself must stay bounded.
        if buffer.count > maximumEventBytes {
            markOverflow()
        }
        return events
    }

    /// Flushes a trailing event that arrived without its blank-line terminator.
    func finish() -> Data? {
        guard !overflowed, !buffer.isEmpty else { return nil }
        let event = Data(buffer)
        buffer.removeAll(keepingCapacity: false)
        return SensitiveResponseBody.sanitizeEvent(event, secrets: secrets)
    }

    private func markOverflow() {
        overflowed = true
        buffer.removeAll(keepingCapacity: false)
    }

    /// Finds the first SSE event boundary: any line terminator immediately
    /// followed by another line terminator. CRLF is one terminator, so the
    /// scan consumes both bytes before looking for the blank-line terminator;
    /// this accepts LF/LF, LF/CRLF, CRLF/LF, CRLF/CRLF, CR/CR and every mixed
    /// combination while keeping normal event streaming incremental.
    private static func nextEventRange(in data: Data) -> Range<Data.Index>? {
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            guard byte == 0x0D || byte == 0x0A else {
                index = data.index(after: index)
                continue
            }
            var afterTerminator = data.index(after: index)
            if byte == 0x0D,
               afterTerminator < data.endIndex,
               data[afterTerminator] == 0x0A {
                afterTerminator = data.index(after: afterTerminator)
            }
            // A single line terminator ends a line, not an event; SSE needs
            // the next (empty) line's terminator as well.
            guard afterTerminator < data.endIndex else { return nil }
            let next = data[afterTerminator]
            guard next == 0x0D || next == 0x0A else {
                index = afterTerminator
                continue
            }
            var end = data.index(after: afterTerminator)
            if next == 0x0D, end < data.endIndex, data[end] == 0x0A {
                end = data.index(after: end)
            }
            return data.startIndex..<end
        }
        return nil
    }
}
