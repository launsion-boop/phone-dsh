// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: events and probe results.
//
// PLAN §2.1/§2.5. The engine reports page lifecycle, Worker boot status,
// WebContent terminations, planned restarts and page console lines through one
// AsyncStream. Data frames never travel through this bridge: VFS mutations,
// exec events and journal records use the ordered WebSocket channel.

import Foundation

/// Boot state reported by the page's bootstrap script.
public struct WebEngineBootStatus: Equatable, Sendable {
    public enum State: String, CaseIterable, Codable, Sendable {
        case booting
        case ready
        case failed
    }

    public var state: State
    /// Boot id the page reports, when it knows it.
    public var bootID: String?
    /// Human-readable detail (the page's status text, or an error message).
    public var detail: String?

    public init(state: State, bootID: String? = nil, detail: String? = nil) {
        self.state = state
        self.bootID = bootID
        self.detail = detail
    }
}

/// One page console line captured by the engine's message bridge.
public struct WebEngineConsoleLine: Equatable, Sendable {
    public enum Level: String, CaseIterable, Codable, Sendable {
        case log
        case info
        case warning
        case error
        case debug
    }

    public var level: Level
    public var text: String

    public init(level: Level, text: String) {
        self.level = level
        self.text = text
    }
}

/// Capability flags the facade consults before starting the local harness.
public struct WebEngineCapabilities: Equatable, Sendable {
    /// The system-wide Lockdown Mode flag as WebKit reports it.
    public var lockdownModeEnabled: Bool
    /// Whether page content JavaScript is enabled for the boot page.
    public var contentJavaScriptEnabled: Bool
    /// Minimum visible attachment area this engine requires, in points.
    public var minimumVisibleAreaPoints: Double

    /// The local DSH harness needs a WebContent process with JIT; Lockdown
    /// Mode turns it off, so the facade must refuse the local path.
    public var isLocalHarnessAvailable: Bool { lockdownModeEnabled == false }

    public init(lockdownModeEnabled: Bool, contentJavaScriptEnabled: Bool = true,
                minimumVisibleAreaPoints: Double = WebEngineConfiguration.requiredVisibleAreaPoints) {
        self.lockdownModeEnabled = lockdownModeEnabled
        self.contentJavaScriptEnabled = contentJavaScriptEnabled
        self.minimumVisibleAreaPoints = minimumVisibleAreaPoints
    }
}

/// Why the controller asked for a planned restart.
///
/// The engine never restarts on its own: PLAN §2.5 places planned restarts at a
/// tool-call boundary owned by the controller.
public enum WebEngineRestartReason: String, CaseIterable, Codable, Sendable {
    /// The controller's scheduled restart or a tool-call boundary.
    case planned
    /// Recovery after `webViewWebContentProcessDidTerminate`.
    case webContentTerminated
    /// Memory-pressure pressure valve observed by the controller.
    case memoryPressure
    /// The controller drained before the app entered the background.
    case backgroundDrain
    /// The controller is recovering a previous failure.
    case failureRecovery
}

/// One completed cold start.
public struct WebEngineRestartReport: Equatable, Sendable {
    public var reason: WebEngineRestartReason
    public var bootID: String
    /// Elapsed time from starting the reload until the page reported ready.
    public var duration: Duration

    public var durationSeconds: Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    public init(reason: WebEngineRestartReason, bootID: String, duration: Duration) {
        self.reason = reason
        self.bootID = bootID
        self.duration = duration
    }
}

/// Informational JIT probe result (a page-side tight loop plus JSON work).
public struct WebEngineJITProbeResult: Equatable, Sendable {
    /// Duration the benchmark measured inside the page, in milliseconds.
    public var measuredMilliseconds: Double
    /// Baseline used for the ratio, or `nil` on the first measurement.
    public var baselineMilliseconds: Double?
    /// `baseline / measured`; above 1 means faster than the stored baseline.
    public var ratio: Double?
    /// Loop iterations the benchmark performed.
    public var iterations: Int

    public init(measuredMilliseconds: Double, baselineMilliseconds: Double? = nil,
                ratio: Double? = nil, iterations: Int = 0) {
        self.measuredMilliseconds = measuredMilliseconds
        self.baselineMilliseconds = baselineMilliseconds
        self.ratio = ratio
        self.iterations = iterations
    }
}

/// Event published by ``WebEngine/events``.
public enum WebEngineEvent: Equatable, Sendable {
    /// The main-frame page finished loading.
    case loaded(URL)
    /// The page's bootstrap script reported the Worker ready.
    case bootReady(WebEngineBootStatus)
    /// The WebContent process terminated; the value is the boot's count.
    case terminated(UInt64)
    /// A planned restart or a termination recovery finished.
    case restarted(WebEngineRestartReport)
    /// A page console line.
    case consoleLine(WebEngineConsoleLine)
}

/// An asynchronous sequence of ``WebEngineEvent`` values.
///
/// Each call to ``WebEngine/eventStream()`` creates a new subscription; the
/// convenience ``WebEngine/events`` property is one subscription made at
/// engine creation. Iteration is safe from any task.
public struct WebEngineEvents: AsyncSequence, Sendable {
    public typealias Element = WebEngineEvent
    public typealias AsyncIterator = AsyncStream<WebEngineEvent>.AsyncIterator

    private let stream: AsyncStream<WebEngineEvent>

    init(_ stream: AsyncStream<WebEngineEvent>) {
        self.stream = stream
    }

    public func makeAsyncIterator() -> AsyncStream<WebEngineEvent>.AsyncIterator {
        stream.makeAsyncIterator()
    }
}
