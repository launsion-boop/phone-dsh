// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the App's chat host assembly, shared with the
// simulator/device E2E suites.
//
// The Chat page uses one host configuration and persistent workspace. Tests use
// the same App container and configuration, with an isolated root when preservation
// is requested; they do not construct a parallel host or clear user sessions.

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import enum PhoneDSHController.DeviceTier
import PhoneDSHEngine

/// Host assembly shared by the App and the simulator E2E suites.
public enum ChatHostConfiguration {
    /// Persistent workspace directory below the App's Documents directory.
    public static let workspaceDirectoryName = "chat-host"
    /// Worker-side placeholder key. The real credential stays in the host
    /// gateway and never reaches the Worker.
    public static let workerPlaceholderKey = "phone-host-injects-key"
    public static let defaultDrainDeadline: TimeInterval = 20
    public static let defaultHelloTimeout: TimeInterval = 600
    public static let defaultBootTimeout: TimeInterval = 600
    public static let defaultTurnInactivityTimeout: TimeInterval = 1_800
    public static let defaultShellTimeoutMs: UInt64 = 600_000
    public static let defaultOfficeInteractionTimeout: TimeInterval = 600

    /// Resolves the persistent root below the App's Documents directory, or
    /// below the caller's directory in a hostless test. DEBUG can select a
    /// sibling test root without clearing the App's sessions.
    public static func workspaceRoot(documents: URL? = nil) -> URL {
        let documents = documents
            ?? FileManager.default.urls(for: .documentDirectory,
                                        in: .userDomainMask)[0]
        var name = workspaceDirectoryName
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PDSH_SIM_WORKSPACE_NAME"], !raw.isEmpty {
            let suffix = String(raw.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }.prefix(80))
            if !suffix.isEmpty { name += "-sim-\(suffix)" }
        } else if let raw = ProcessInfo.processInfo.environment["PDSH_OFFICE_WORKSPACE_NAME"], !raw.isEmpty {
            let suffix = String(raw.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }.prefix(80))
            if !suffix.isEmpty { name += "-office-\(suffix)" }
        }
        #endif
        return documents.appendingPathComponent(name, isDirectory: true)
    }

    /// `scheme://host[:port]` rule the gateway uses for the model host.
    public static func modelHostRule(for modelURL: URL) -> String? {
        guard let scheme = modelURL.scheme?.lowercased(),
              let host = modelURL.host,
              scheme.isEmpty == false, host.isEmpty == false else {
            return nil
        }
        var rule = "\(scheme)://\(host)"
        if let port = modelURL.port { rule += ":\(port)" }
        return rule
    }

    /// Builds the same configuration the App's Chat page boots: one loopback
    /// origin, the packed Worker bundle, the host-side credential gateway and
    /// the Worker environment. The real key is only in `credentialProvider`.
    public static func make(workspaceRoot: URL,
                            bundle: PhoneDSHBundleLocation,
                            modelBaseURL: URL,
                            modelName: String,
                            credentialProvider: any CredentialProvider,
                            egressHosts: Set<String>,
                            workerPlaceholderKey: String = ChatHostConfiguration.workerPlaceholderKey,
                            drainDeadline: TimeInterval = ChatHostConfiguration.defaultDrainDeadline,
                            helloTimeout: TimeInterval = ChatHostConfiguration.defaultHelloTimeout,
                            deviceTier: DeviceTier = .default)
        -> PhoneDSHConfiguration {
        let hostRule = modelHostRule(for: modelBaseURL) ?? modelBaseURL.absoluteString
        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            token: "",
            origin: URL(string: "http://127.0.0.1:1")!,
            deviceTier: deviceTier,
            bundle: bundle,
            allowedModelHosts: [hostRule],
            egressAllowHosts: egressHosts,
            credentialProvider: credentialProvider,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout)
        configuration.turnInactivityTimeout = defaultTurnInactivityTimeout
        configuration.engine.bootTimeout = defaultBootTimeout
        configuration.engine.environment = [
            "DEEPSEEK_BASE_URL": modelBaseURL.absoluteString,
            // The host gateway injects the real key; the Worker never holds it.
            "DEEPSEEK_API_KEY": workerPlaceholderKey,
            "DSH_TELEMETRY_DISABLED": "1",
            "PDSH_MODEL_NAME": modelName,
            "PDSH_SHELL_TIMEOUT_MS": String(defaultShellTimeoutMs),
        ]
        return configuration
    }
}
