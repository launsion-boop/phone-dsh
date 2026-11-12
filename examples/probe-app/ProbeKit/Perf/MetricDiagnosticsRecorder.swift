// SPDX-License-Identifier: MIT
// MetricKit diagnostic capture.
//
// MetricKit reports hangs and crashes on the *next* launch. The payloads are
// written as their documented JSON representation into `Documents/diagnostics`
// (next to `chat-status.log`) so a device container can be pulled without a
// debugger. The directory keeps only the newest 20 payload files.

import Foundation
import MetricKit

public final class MetricDiagnosticsRecorder: NSObject, MXMetricManagerSubscriber {
    public static let shared = MetricDiagnosticsRecorder()
    public static let maxFiles = 20
    public static let filePrefix = "metric-diagnostics-"

    public static var defaultDirectory: URL {
        StatusLogWriter.defaultDiagnosticsDirectory
    }

    private let queue = DispatchQueue(label: "dev.phone-dsh.metric-diagnostics", qos: .utility)
    private let directory: URL
    private let lock = NSLock()
    private var started = false

    public init(directory: URL = MetricDiagnosticsRecorder.defaultDirectory) {
        self.directory = directory
    }

    /// Subscribes once. MXMetricManager holds the subscriber weakly on some
    /// OS versions, so `shared` is also the process-lifetime strong owner.
    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            let date = Date()
            queue.async { [weak self] in
                self?.store(data, at: date)
            }
        }
    }

    /// Writes one diagnostic JSON blob and prunes older files. Public so the
    /// simulator suite can exercise the bound without MetricKit delivery.
    public func record(_ data: Data, at date: Date = Date()) {
        queue.async { [weak self] in
            self?.store(data, at: date)
        }
    }

    public func waitForIdle() {
        queue.sync {}
    }

    private func store(_ data: Data, at date: Date) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let milliseconds = Int((date.timeIntervalSince1970 * 1_000).rounded())
        let suffix = UUID().uuidString.prefix(8)
        let name = "\(Self.filePrefix)\(milliseconds)-\(suffix).json"
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        prune()
    }

    private func prune() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])
        else { return }
        let ours = entries.filter {
            $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "json"
        }
        guard ours.count > Self.maxFiles else { return }
        // Fixed-width millisecond prefix: lexical order is oldest first. Do
        // not touch files another writer may have put in this directory.
        let ordered = ours.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in ordered.prefix(ours.count - Self.maxFiles) {
            try? manager.removeItem(at: url)
        }
    }
}
