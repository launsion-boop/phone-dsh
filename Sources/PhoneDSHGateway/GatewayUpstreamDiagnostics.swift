// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHGateway: upstream timing diagnostics.
//
// A resumed Worker can spend a whole `host.start()` inside one model/egress
// request. The gateway already isolates that request behind one URLSession, so
// these lines answer the two questions the resume evidence needs: how long the
// request actually took, and whether URLSession was waiting for connectivity
// instead of using a live connection.
//
// Security: only the host (no path, no query, no headers, no body), the
// elapsed/first-byte milliseconds, the status and a URL error code are ever
// formatted. The gateway's credential never enters the line.

import Foundation
import PhoneDSHStandardError

private let gatewayStderrLock = NSLock()

/// One-shot latch: the first claim wins, later claims are ignored. Used for
/// diagnostics that describe a gateway-wide state instead of one attempt, so a
/// long session cannot turn a fact that never changes into a log flood.
final class GatewayOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Emits bounded upstream diagnostics for the model gateway.
public final class GatewayUpstreamDiagnostics: @unchecked Sendable {
    /// Receives one complete line (without the trailing newline).
    public typealias Sink = @Sendable (String) -> Void

    /// The process-wide default: the scenario runner tees stderr into its run
    /// log. The App injects the boot-timings sink instead.
    public static let standardError = GatewayUpstreamDiagnostics(sink: { line in
        gatewayStderrLock.lock()
        defer { gatewayStderrLock.unlock() }
        PhoneDSHStandardError.write(line)
    })

    /// A request at or above this duration emits one slow line.
    public let slowRequestMilliseconds: Double
    private let sink: Sink
    /// Monotonic seconds. Tests inject a manual clock.
    let now: @Sendable () -> TimeInterval

    public init(sink: @escaping Sink,
                now: @escaping @Sendable () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                slowRequestMilliseconds: Double = 2_000) {
        self.sink = sink
        self.now = now
        self.slowRequestMilliseconds = max(0, slowRequestMilliseconds)
    }

    // MARK: - Records

    /// Called once per upstream attempt at completion. A fast, successful
    /// request is deliberately silent; only the slow path and every error
    /// leave evidence.
    func recordCompletion(host: String,
                          elapsedMilliseconds: Double,
                          firstByteMilliseconds: Double?,
                          status: Int?,
                          error: Error?) {
        if let error {
            sink(Self.errorLine(host: host,
                                elapsedMilliseconds: elapsedMilliseconds,
                                firstByteMilliseconds: firstByteMilliseconds,
                                status: status,
                                error: error))
            return
        }
        guard elapsedMilliseconds >= slowRequestMilliseconds else { return }
        sink(Self.slowLine(host: host,
                           elapsedMilliseconds: elapsedMilliseconds,
                           firstByteMilliseconds: firstByteMilliseconds,
                           status: status))
    }

    /// Called from `urlSession(_:taskIsWaitingForConnectivity:)`. No path and
    /// no query: the host alone decides whether the mitigation is relevant.
    func recordWaitingForConnectivity(host: String) {
        sink(Self.waitingLine(host: host))
    }

    /// Called when the model-purpose execution point sees an exchange with no
    /// purpose evidence (P26 §2.10 absent branch,
    /// PC-20261113-p12-model-purpose-sink). This is a host diagnostic, not an
    /// error code: it never leaves the process, never appears on the wire and
    /// never changes the exchange. The gateway records it once (the absence is
    /// a property of the deployment, not of one request).
    func recordPurposeAbsent(host: String) {
        sink(Self.purposeAbsentLine(host: host))
    }

    // MARK: - Formatting (internal for the unit tests)

    static func slowLine(host: String,
                         elapsedMilliseconds: Double,
                         firstByteMilliseconds: Double?,
                         status: Int?) -> String {
        "gateway-upstream host=\(hostToken(host)) "
            + "elapsed_ms=\(milliseconds(elapsedMilliseconds)) "
            + "ttfb_ms=\(optionalMilliseconds(firstByteMilliseconds)) "
            + "status=\(status.map(String.init) ?? "none")"
    }

    static func errorLine(host: String,
                          elapsedMilliseconds: Double,
                          firstByteMilliseconds: Double?,
                          status: Int?,
                          error: Error) -> String {
        "gateway-upstream host=\(hostToken(host)) "
            + "elapsed_ms=\(milliseconds(elapsedMilliseconds)) "
            + "ttfb_ms=\(optionalMilliseconds(firstByteMilliseconds)) "
            + "status=\(status.map(String.init) ?? "none") "
            + "error=\(errorCode(error))"
    }

    static func waitingLine(host: String) -> String {
        "gateway waiting-for-connectivity host=\(hostToken(host))"
    }

    /// The frozen absent-branch token is `purpose_absent`. Only the host is
    /// formatted: no path, no query, no headers, no body.
    static func purposeAbsentLine(host: String) -> String {
        "gateway-purpose purpose_absent host=\(hostToken(host))"
    }

    static func hostToken(_ host: String) -> String {
        let lowered = host.lowercased()
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789.-_[]:")
        let filtered = lowered.unicodeScalars.filter { allowed.contains($0) }
        let token = String(String.UnicodeScalarView(filtered))
        return token.isEmpty ? "unknown" : String(token.prefix(100))
    }

    static func errorCode(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError:\(urlError.code.rawValue)"
        }
        let nsError = error as NSError
        let domain = hostToken(nsError.domain.replacingOccurrences(of: ".", with: "-"))
        return "\(domain):\(nsError.code)"
    }

    private static func milliseconds(_ value: Double) -> Int {
        Int(max(0, value).rounded())
    }

    private static func optionalMilliseconds(_ value: Double?) -> String {
        guard let value else { return "none" }
        return String(milliseconds(value))
    }
}
