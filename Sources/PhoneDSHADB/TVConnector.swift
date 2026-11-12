// SPDX-License-Identifier: MIT
import Foundation

/// Identity and display information read from a connected Android TV.
public struct TVDeviceSummary: Hashable, Sendable {
    public let model: String
    public let release: String
    public let display: String
    public let serial: String
    public let mac: String?

    public init(model: String, release: String, display: String, serial: String, mac: String? = nil) {
        self.model = model
        self.release = release
        self.display = display
        self.serial = serial
        self.mac = mac
    }
}

/// Progress of one TV connection attempt, from probing through authorization
/// to the final identity.
public enum TVConnectPhase: Equatable, Sendable {
    case idle
    case probing
    case awaitingAuthorization(elapsed: Duration)
    case connected(String)
    case failed(kind: ADBFailureKind, message: String)
}

/// Reads device identity over a live ADB connection.
public protocol TVConnectionChecking: Sendable {
    func summary(host: String, port: UInt16) async throws -> TVDeviceSummary
}

/// Reads the TV's summary in one ADB shell round trip: serial, model, Android
/// release, panel size and the wlan0 MAC address.
public struct ADBShellTVChecker: TVConnectionChecking {
    /// `; true` keeps a TV without `wlan0` (or with a restricted `ip`) from
    /// failing the probe on exit status alone: the identity fields below decide
    /// whether this really is a readable ADB device.
    private static let command = "getprop ro.serialno; getprop ro.product.model; "
        + "getprop ro.build.version.release; wm size; ip link show wlan0 2>/dev/null; true"

    private let executor: any ADBCommandExecuting

    public init(executor: any ADBCommandExecuting = ADBClient()) {
        self.executor = executor
    }

    public func summary(host: String, port: UInt16) async throws -> TVDeviceSummary {
        let endpoint = try ADBEndpoint(host: host, port: port)
        let result = try await executor.shell(endpoint: endpoint, command: Self.command,
                                              timeout: 4, outputLimit: 65_536)
        // The exit status only covers the final command in the chain. A TV that
        // exposes no `wlan0`, or restricts `ip`, still answers the identity
        // properties, so the parsed identity decides instead of the status.
        let summary = Self.parse(result.stdout)
        guard !summary.serial.isEmpty || !summary.model.isEmpty else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "" : ": " + String(stderr.prefix(200))
            throw ADBFailure("Device information command returned no identity (exit \(result.exitCode))\(detail)",
                             kind: .device)
        }
        return summary
    }

    /// Line 1 is the serial, line 2 the model and line 3 the release. `wm size`
    /// and `ip link` are found by keyword because they print variable headers.
    /// Unreadable optional fields (display, MAC) become empty/nil rather than
    /// failing the whole connection.
    static func parse(_ stdout: Data) -> TVDeviceSummary {
        let normalized = String(decoding: stdout, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func line(at index: Int) -> String {
            index < lines.count ? lines[index] : ""
        }
        let display = lines.lazy.compactMap { self.physicalSize(in: $0) }.first ?? ""
        let mac = lines.lazy.compactMap { self.macAddress(in: $0) }.first
        return TVDeviceSummary(model: line(at: 1), release: line(at: 2), display: display,
                               serial: line(at: 0), mac: mac)
    }

    private static func physicalSize(in line: String) -> String? {
        guard let marker = line.range(of: "Physical size:", options: .caseInsensitive) else {
            return nil
        }
        let value = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func macAddress(in line: String) -> String? {
        guard let marker = line.range(of: "link/ether", options: .caseInsensitive),
              let token = line[marker.upperBound...].split(whereSeparator: { $0.isWhitespace }).first
        else { return nil }
        let octets = token.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6,
              octets.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isHexDigit } }) else {
            return nil
        }
        return String(token)
    }
}

/// Drives one connection attempt and waits for the TV's debugging authorization.
///
/// The checker is retried while ADB reports `.unauthorized`; every other failure
/// ends the attempt immediately. A successful attempt writes the identity to the
/// ``TVDeviceDirectory`` before reporting `.connected`.
public actor TVConnector {
    private nonisolated let checker: any TVConnectionChecking
    private nonisolated let directory: TVDeviceDirectory
    private nonisolated let authorizeTimeout: Duration
    private nonisolated let retryInterval: Duration

    public init(checker: any TVConnectionChecking = ADBShellTVChecker(),
                directory: TVDeviceDirectory = .shared,
                authorizeTimeout: Duration = .seconds(90),
                retryInterval: Duration = .seconds(2)) {
        self.checker = checker
        self.directory = directory
        self.authorizeTimeout = authorizeTimeout
        self.retryInterval = retryInterval
    }

    /// Starts a connection attempt. Cancelling the returned stream (or dropping
    /// it, which terminates the stream) cancels the internal task.
    public nonisolated func connect(host: String, port: UInt16) -> AsyncStream<TVConnectPhase> {
        let checker = self.checker
        let directory = self.directory
        let authorizeTimeout = self.authorizeTimeout
        let retryInterval = self.retryInterval
        return AsyncStream { continuation in
            let task = Task {
                await TVConnector.run(host: host, port: port, checker: checker,
                                      directory: directory, authorizeTimeout: authorizeTimeout,
                                      retryInterval: retryInterval, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(host: String, port: UInt16, checker: any TVConnectionChecking,
                            directory: TVDeviceDirectory, authorizeTimeout: Duration,
                            retryInterval: Duration,
                            continuation: AsyncStream<TVConnectPhase>.Continuation) async {
        continuation.yield(.probing)
        let endpoint: ADBEndpoint
        do {
            endpoint = try ADBEndpoint(host: host, port: port)
        } catch let failure as ADBFailure {
            continuation.yield(.failed(kind: failure.kind, message: failure.message))
            continuation.finish()
            return
        } catch {
            continuation.yield(.failed(kind: .device, message: error.localizedDescription))
            continuation.finish()
            return
        }

        let clock = ContinuousClock()
        let started = clock.now
        while !Task.isCancelled {
            do {
                let summary = try await checker.summary(host: endpoint.host, port: endpoint.port)
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                let record = TVDeviceRecord(serial: summary.serial, model: summary.model,
                                            host: endpoint.host, port: endpoint.port,
                                            mac: summary.mac, lastSeen: Date())
                directory.remember(record)
                continuation.yield(.connected(summary.model))
                continuation.finish()
                return
            } catch let failure as ADBFailure {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                guard failure.kind == .unauthorized else {
                    continuation.yield(.failed(kind: failure.kind, message: failure.message))
                    continuation.finish()
                    return
                }
                let elapsed = clock.now - started
                guard elapsed < authorizeTimeout else {
                    continuation.yield(.failed(kind: .unauthorized,
                                               message: Self.authorizationTimeoutMessage(authorizeTimeout)))
                    continuation.finish()
                    return
                }
                continuation.yield(.awaitingAuthorization(elapsed: elapsed))
                let delay = min(retryInterval, authorizeTimeout - elapsed)
                if delay > .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        continuation.finish()
                        return
                    }
                } else {
                    await Task.yield()
                }
            } catch {
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                continuation.yield(.failed(kind: .device, message: error.localizedDescription))
                continuation.finish()
                return
            }
        }
        continuation.finish()
    }

    private static func authorizationTimeoutMessage(_ timeout: Duration) -> String {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000
        let amount = seconds >= 1
            ? "\(Int(seconds.rounded())) seconds"
            : "\(Int((seconds * 1000).rounded())) milliseconds"
        return "No authorization after \(amount). On the TV open Settings > Developer options, "
            + "make sure USB debugging is on, then retry; if no prompt appears, "
            + "revoke USB debugging authorizations and reconnect."
    }
}
