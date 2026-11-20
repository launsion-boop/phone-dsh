// SPDX-License-Identifier: MIT
//
// Engine-first-launch wake measurement: value types and evidence store.
//
// This is spike-only (BOT_RESIDENCY_SPIKE). It deliberately duplicates no
// production policy: the provisional thresholds below exist only to label the
// measurement and are replaced by the frozen spec/host/v1 values when the
// caller re-freezes them from the real-device result.
#if BOT_RESIDENCY_SPIKE

import Foundation

public enum EngineWakeScenarioID: String, CaseIterable, Codable, Sendable {
    case pushColdStart = "push-cold-start"
    case pushParkedResume = "push-parked-resume"
    case bgProcessingColdStart = "bgprocessing-cold-start"
    case boardWakeColdStart = "board-wake-cold-start"
    case lanResident = "lan-resident"
    case lanSuspended = "lan-suspended"

    /// Scenarios that require a process which was not already running.
    public var expectsColdProcess: Bool {
        switch self {
        case .pushColdStart, .bgProcessingColdStart, .boardWakeColdStart: return true
        case .pushParkedResume, .lanResident, .lanSuspended: return false
        }
    }
}

public struct EngineWakeThresholds: Codable, Sendable {
    public var minLeaseForColdBootMs: Int64
    public var minLeaseForResumeMs: Int64
    public var parkMarginMs: Int64
    public var source: String

    public init(minLeaseForColdBootMs: Int64 = 20_000,
                minLeaseForResumeMs: Int64 = 8_000,
                parkMarginMs: Int64 = 5_000,
                source: String = "provisional-plan") {
        self.minLeaseForColdBootMs = minLeaseForColdBootMs
        self.minLeaseForResumeMs = minLeaseForResumeMs
        self.parkMarginMs = parkMarginMs
        self.source = source
    }
}

public struct EngineWakeConfiguration: Codable, Sendable {
    public var runID: String
    public var scenarios: [String]
    public var iterations: Int
    public var lanPort: UInt16
    public var armOnly: Bool

    public init(runID: String, scenarios: [String], iterations: Int,
                lanPort: UInt16, armOnly: Bool) {
        self.runID = runID
        self.scenarios = scenarios
        self.iterations = iterations
        self.lanPort = lanPort
        self.armOnly = armOnly
    }

    public static func parse(_ arguments: [String]) throws -> Self {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        guard let runID = value("--run-id"),
              runID.range(of: #"^[a-zA-Z0-9-]{1,80}$"#, options: .regularExpression) != nil else {
            throw EngineWakeConfigurationError.invalid("run-id")
        }
        let rawScenarios = value("--scenarios") ?? EngineWakeScenarioID.allCases
            .map(\.rawValue).joined(separator: ",")
        let scenarios = rawScenarios.split(separator: ",").map(String.init)
        let known = Set(EngineWakeScenarioID.allCases.map(\.rawValue))
        guard !scenarios.isEmpty, scenarios.allSatisfy({ known.contains($0) }) else {
            throw EngineWakeConfigurationError.invalid("scenarios")
        }
        guard let iterations = Int(value("--iterations") ?? "5"), iterations > 0,
              iterations <= 50 else {
            throw EngineWakeConfigurationError.invalid("iterations")
        }
        let port = UInt16(value("--lan-port") ?? "0") ?? 0
        return Self(runID: runID, scenarios: scenarios, iterations: iterations,
                    lanPort: port, armOnly: arguments.contains("--arm-only"))
    }
}

public enum EngineWakeConfigurationError: Error, CustomStringConvertible {
    case invalid(String)
    case missingArmedConfiguration

    public var description: String {
        switch self {
        case .invalid(let name): return "invalid or missing launch argument --\(name)"
        case .missingArmedConfiguration: return "no armed engine-wake configuration for this launch"
        }
    }
}

/// The configuration survives a background relaunch, where iOS does not pass
/// the `devicectl` / `simctl` launch arguments again.
public enum EngineWakeArmedStore {
    public static func url() -> URL? {
        guard let documents = try? FileManager.default.url(for: .documentDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true) else { return nil }
        return documents.appendingPathComponent("BotResidencySpike", isDirectory: true)
            .appendingPathComponent("engine-wake-armed.json")
    }

    public static func exists() -> Bool {
        guard let url = url(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        // A stale armed file must not turn an ordinary launch into a spike run.
        guard Date().timeIntervalSince(modified) < 24 * 60 * 60 else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    public static func save(_ configuration: EngineWakeConfiguration) throws {
        guard let url = url() else { throw EngineWakeConfigurationError.missingArmedConfiguration }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }

    public static func load() -> EngineWakeConfiguration? {
        guard let url = url(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EngineWakeConfiguration.self, from: data)
    }

    public static func clear() {
        guard let url = url() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

public struct EngineWakeBackgroundSample: Codable, Sendable {
    public var atMs: Double
    public var remainingMs: Int64?

    public init(atMs: Double, remainingMs: Int64?) {
        self.atMs = atMs
        self.remainingMs = remainingMs
    }
}

public struct EngineWakeAttempt: Codable, Sendable {
    public var attempt: Int
    public var trigger: String
    public var triggeredAt: String
    public var hostStartReturnedAt: String?
    public var wakeToHostStartMs: Double?
    public var hostStateBefore: String
    public var decision: String
    public var processWasRunning: Bool
    public var sceneConnectedAtTrigger: Bool
    public var offscreenWindowUsed: Bool
    public var anchorInWindowAfterBoot: Bool
    public var residentAudio: Bool
    public var webContentPIDBefore: Int?
    public var webContentPIDAfter: Int?
    public var webContentTerminated: Bool
    public var leaseRemainingMsAtTrigger: Int64?
    public var backgroundTimeRemainingCurve: [EngineWakeBackgroundSample]
    public var userVisiblePrompt: Bool
    public var forcedForMeasurement: Bool
    public var error: String?

    public init(attempt: Int, trigger: String, triggeredAt: String,
                hostStateBefore: String, decision: String,
                processWasRunning: Bool, sceneConnectedAtTrigger: Bool,
                offscreenWindowUsed: Bool, residentAudio: Bool,
                leaseRemainingMsAtTrigger: Int64?) {
        self.attempt = attempt
        self.trigger = trigger
        self.triggeredAt = triggeredAt
        self.hostStateBefore = hostStateBefore
        self.decision = decision
        self.processWasRunning = processWasRunning
        self.sceneConnectedAtTrigger = sceneConnectedAtTrigger
        self.offscreenWindowUsed = offscreenWindowUsed
        self.residentAudio = residentAudio
        self.leaseRemainingMsAtTrigger = leaseRemainingMsAtTrigger
        self.backgroundTimeRemainingCurve = []
        self.userVisiblePrompt = false
        self.forcedForMeasurement = false
        self.webContentTerminated = false
        self.anchorInWindowAfterBoot = false
    }
}

public struct EngineWakeScenarioRecord: Codable, Sendable {
    public var id: String
    public var status: String
    public var attempts: [EngineWakeAttempt]
    public var notes: [String]

    public init(id: String) {
        self.id = id
        self.status = "not-started"
        self.attempts = []
        self.notes = []
    }
}

public struct EngineWakeReport: Codable, Sendable {
    public var schema = "phonedsh-engine-wake/1"
    public var runID: String
    public var generatedAt: String
    public var contractRevision: String
    public var deviceClass: String
    public var configuration: EngineWakeConfiguration
    public var thresholds: EngineWakeThresholds
    public var scenarios: [EngineWakeScenarioRecord]

    public init(runID: String, deviceClass: String, configuration: EngineWakeConfiguration,
                thresholds: EngineWakeThresholds, scenarios: [EngineWakeScenarioRecord],
                contractRevision: String = "PC-20261120-engine-first-launch") {
        self.runID = runID
        self.generatedAt = BotResidencyTime.string()
        self.deviceClass = deviceClass
        self.configuration = configuration
        self.thresholds = thresholds
        self.scenarios = scenarios
        self.contractRevision = contractRevision
    }
}

public struct EngineWakeState: Codable, Sendable {
    public var schema = "phonedsh-engine-wake-state/1"
    public var runID: String
    public var updatedAt: String
    public var phase: String
    public var currentScenario: String?
    public var detail: String?
    public var pendingTrigger: EngineWakePendingTrigger?
    public var pendingProbe: EngineWakePendingProbe?
    public var deviceClass: String
    public var deviceToken: String?
    public var lanPort: UInt16?

    public init(runID: String, deviceClass: String, phase: String) {
        self.runID = runID
        self.deviceClass = deviceClass
        self.phase = phase
        self.updatedAt = BotResidencyTime.string()
    }
}

public struct EngineWakePendingTrigger: Codable, Sendable {
    public var id: String
    public var kind: String
    public var instructions: String

    public init(id: String, kind: String, instructions: String) {
        self.id = id
        self.kind = kind
        self.instructions = instructions
    }
}

public struct EngineWakePendingProbe: Codable, Sendable {
    public var id: String
    public var scenario: String
    public var port: UInt16
    public var probeDelaySeconds: Double

    public init(id: String, scenario: String, port: UInt16, probeDelaySeconds: Double) {
        self.id = id
        self.scenario = scenario
        self.port = port
        self.probeDelaySeconds = probeDelaySeconds
    }
}

@MainActor
public final class EngineWakeEvidenceStore {
    public let root: URL
    private let encoder = JSONEncoder()

    public init(runID: String) throws {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true)
        root = documents.appendingPathComponent("BotResidencySpike", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.path)
    }

    public func writeState(_ state: EngineWakeState) {
        write(state, name: "engine-wake-state.json")
    }

    public func writeReport(_ report: EngineWakeReport) {
        write(report, name: "engine-wake-report.json")
    }

    public func appendEvent(kind: String, detail: String? = nil) {
        let entry: [String: Any] = [
            "at": BotResidencyTime.string(),
            "kind": kind,
            "detail": detail ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            return
        }
        let url = root.appendingPathComponent("engine-wake-events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
        try? handle.synchronize()
    }

    private func write<T: Encodable>(_ value: T, name: String) {
        do {
            let data = try encoder.encode(value)
            let url = root.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch {
            NSLog("engine-wake evidence write failed: %@", String(describing: error))
        }
    }
}

public enum EngineWakeDeviceClass {
    public static var current: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        return "physical"
        #endif
    }
}
#endif
