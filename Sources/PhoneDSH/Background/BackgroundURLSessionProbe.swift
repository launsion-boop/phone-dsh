// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSH: background URLSession probe.
//
// PLAN W6-BACKGROUND: a flag-gated Phase 0 probe. It submits one non-streaming
// model request as a background URLSession upload task and records whether the
// App was woken to deliver the session events. It is a probe only: it writes a
// report, makes no product promise and is never on the task execution path.
//
// Enable with the configuration flag or the `PDSH_BACKGROUND_URLSESSION_PROBE=1`
// environment variable. The App must also forward
// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to
// the platform transport; without that forward the wake signal is not
// deliverable. NOT_VERIFIED: real background upload/wake behaviour on a device.

import Foundation
import PhoneDSHController

/// One non-streaming model request submitted as a background upload.
public struct BackgroundProbeRequest: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String = "POST",
                headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// Terminal outcome of one background upload task.
public struct BackgroundProbeOutcome: Equatable, Sendable {
    public var statusCode: Int?
    public var errorDescription: String?
    public var completedAt: Date

    public init(statusCode: Int?, errorDescription: String?,
                completedAt: Date = Date()) {
        self.statusCode = statusCode
        self.errorDescription = errorDescription
        self.completedAt = completedAt
    }
}

/// Platform background URLSession transport.
///
/// `onWake` is called when the system wakes the App to finish the background
/// session's events; the probe records that in `woken`.
public protocol BackgroundProbeTransport: Sendable {
    func submit(_ request: BackgroundProbeRequest,
                sessionIdentifier: String,
                onWake: @escaping @Sendable () -> Void) async
        -> BackgroundProbeOutcome
}

/// Used on macOS and any host without background URLSession support.
public struct UnsupportedBackgroundProbeTransport: BackgroundProbeTransport {
    public init() {}

    public func submit(_ request: BackgroundProbeRequest,
                       sessionIdentifier: String,
                       onWake: @escaping @Sendable () -> Void) async
        -> BackgroundProbeOutcome {
        BackgroundProbeOutcome(
            statusCode: nil,
            errorDescription: "background URLSession is not supported on this platform")
    }
}

/// Probe configuration.
public struct BackgroundURLSessionProbeConfiguration: Equatable, Sendable {
    /// Master flag; disabled by default and never enabled by a product path.
    public var isEnabled: Bool
    /// `URLSessionConfiguration.background(withIdentifier:)` identifier.
    public var sessionIdentifier: String
    /// The non-streaming model request to upload.
    public var request: BackgroundProbeRequest
    /// Optional JSON report file (for example under the App's diagnostics
    /// directory). `nil` keeps the report in memory only.
    public var reportURL: URL?

    public init(isEnabled: Bool = BackgroundURLSessionProbe.isEnabledByEnvironment,
                sessionIdentifier: String = "dev.phone-dsh.probe",
                request: BackgroundProbeRequest,
                reportURL: URL? = nil) {
        self.isEnabled = isEnabled
        self.sessionIdentifier = sessionIdentifier
        self.request = request
        self.reportURL = reportURL
    }
}

/// Written report of one probe run.
public struct BackgroundURLSessionProbeReport: Codable, Equatable, Sendable {
    /// Marker so a report can never be mistaken for a product measurement.
    public var probe: String
    public var enabled: Bool
    public var submitted: Bool
    public var sessionIdentifier: String
    public var submittedAtMilliseconds: Int64
    public var completedAtMilliseconds: Int64?
    /// `true` when the App was woken to deliver background session events.
    public var woken: Bool
    public var statusCode: Int?
    public var error: String?
    /// Constant disclaimer.
    public var note: String
}

/// Flag-gated background URLSession probe.
public actor BackgroundURLSessionProbe {
    /// Environment flag that enables the probe.
    public static let environmentFlag = "PDSH_BACKGROUND_URLSESSION_PROBE"
    /// Constant report disclaimer.
    public static let disclaimer =
        "Phase 0 probe only; no product promise and never on the task execution path."

    public let configuration: BackgroundURLSessionProbeConfiguration
    private let transport: any BackgroundProbeTransport
    private let clock: any HostClock
    private var storedReport: BackgroundURLSessionProbeReport?

    /// Creates the probe.
    ///
    /// - Parameters:
    ///   - configuration: Enable flag, request and report destination.
    ///   - transport: Background URLSession transport; the platform transport
    ///     by default, a recording double in tests.
    ///   - clock: Injected clock for the report timestamps.
    public init(configuration: BackgroundURLSessionProbeConfiguration,
                transport: (any BackgroundProbeTransport)? = nil,
                clock: any HostClock = SystemHostClock()) {
        self.configuration = configuration
        #if canImport(UIKit) && os(iOS) && !targetEnvironment(macCatalyst)
        self.transport = transport
            ?? PlatformBackgroundURLSessionProbeTransport()
        #else
        self.transport = transport
            ?? UnsupportedBackgroundProbeTransport()
        #endif
        self.clock = clock
    }

    /// `true` when the probe flag is present in the process environment.
    public static var isEnabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment[environmentFlag] == "1"
    }

    /// The latest report, if the probe has run.
    public func currentReport() -> BackgroundURLSessionProbeReport? {
        storedReport
    }

    /// Runs the probe when enabled. Returns `nil` when the flag is off (no
    /// request is submitted and no report is written).
    @discardableResult
    public func submitIfEnabled() async -> BackgroundURLSessionProbeReport? {
        guard configuration.isEnabled else { return nil }
        let started = clock.now
        var report = BackgroundURLSessionProbeReport(
            probe: "background-urlsession-upload",
            enabled: true,
            submitted: true,
            sessionIdentifier: configuration.sessionIdentifier,
            submittedAtMilliseconds: Self.milliseconds(started),
            completedAtMilliseconds: nil,
            woken: false,
            statusCode: nil,
            error: nil,
            note: Self.disclaimer)
        storedReport = report
        write(report)

        let outcome = await transport.submit(
            configuration.request,
            sessionIdentifier: configuration.sessionIdentifier,
            onWake: { [weak self] in
                Task { await self?.recordWake() }
            })
        // A wake callback may have landed while the upload was in flight; keep
        // it instead of overwriting the flag.
        if let current = storedReport {
            report.woken = current.woken
        }
        report.completedAtMilliseconds = Self.milliseconds(outcome.completedAt)
        report.statusCode = outcome.statusCode
        report.error = outcome.errorDescription
        storedReport = report
        write(report)
        return report
    }

    /// Records that the App was woken for the background session.
    @discardableResult
    public func recordWake() -> BackgroundURLSessionProbeReport? {
        guard var report = storedReport else { return nil }
        guard !report.woken else { return report }
        report.woken = true
        storedReport = report
        write(report)
        return report
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func write(_ report: BackgroundURLSessionProbeReport) {
        guard let url = configuration.reportURL else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
