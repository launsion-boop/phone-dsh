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
import PhoneDSHLoopback

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
    /// Resume-only budgets. A cold start keeps the 600 s ceiling (measured
    /// 1–2 s on the phone); a foreground resume must fail inside a bound the
    /// App can recover from. 30 s is 15–30× the observed cold-boot time.
    public static let defaultResumeBootReadyTimeout: TimeInterval = 30
    public static let defaultResumeHelloTimeout: TimeInterval = 30
    public static let defaultResumeVisibilityTimeout: TimeInterval = 5
    /// Matches the host resume budgets plus 10 s of teardown/rebuild slack. The
    /// App watchdog only releases the marker when the host's own bounds failed.
    public static let defaultResumeWatchdogTimeout: TimeInterval =
        defaultResumeBootReadyTimeout + defaultResumeHelloTimeout
            + defaultResumeVisibilityTimeout + 10
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
                            githubAgent: GitHubAgentConfiguration = .disabled,
                            workerPlaceholderKey: String = ChatHostConfiguration.workerPlaceholderKey,
                            drainDeadline: TimeInterval = ChatHostConfiguration.defaultDrainDeadline,
                            helloTimeout: TimeInterval = ChatHostConfiguration.defaultHelloTimeout,
                            resumeBootReadyTimeout: TimeInterval = ChatHostConfiguration.defaultResumeBootReadyTimeout,
                            resumeHelloTimeout: TimeInterval = ChatHostConfiguration.defaultResumeHelloTimeout,
                            resumeVisibilityTimeout: TimeInterval = ChatHostConfiguration.defaultResumeVisibilityTimeout,
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
            githubAgent: githubAgent,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout,
            resumeBootReadyTimeout: resumeBootReadyTimeout,
            resumeHelloTimeout: resumeHelloTimeout,
            resumeVisibilityTimeout: resumeVisibilityTimeout)
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

    /// The production Chat/Worker host values the App and the Bot E2E share.
    ///
    /// This is the one function that decides `nativeMCP`, the Worker
    /// environment, boot/inactivity timeouts and the gateway inputs for a
    /// production-shaped host. App-only services (shell/SSH/ADB exec
    /// providers, web search and the Bot MCP grant) are layered on the
    /// returned value so the E2E exercises the same assembly instead of
    /// hand-copying it.
    public static func makeProduction(
        workspaceRoot: URL,
        bundle: PhoneDSHBundleLocation,
        deviceTier: DeviceTier = .forPhysicalMemory(ProcessInfo.processInfo.physicalMemory),
        allowedModelHosts: Set<String>,
        egressAllowHosts: Set<String>,
        replaySafeModelEndpoints: Set<String> = [],
        credentialProvider: any CredentialProvider,
        githubAgent: GitHubAgentConfiguration = .disabled,
        egressAuthorizer: (any EgressHostAuthorizing)? = nil,
        workerEnvironment: [String: String],
        nativeMCP: (any NativeMCPServing)? = nil,
        drainDeadline: TimeInterval = ChatHostConfiguration.defaultDrainDeadline,
        helloTimeout: TimeInterval = ChatHostConfiguration.defaultHelloTimeout,
        resumeBootReadyTimeout: TimeInterval = ChatHostConfiguration.defaultResumeBootReadyTimeout,
        resumeHelloTimeout: TimeInterval = ChatHostConfiguration.defaultResumeHelloTimeout,
        resumeVisibilityTimeout: TimeInterval = ChatHostConfiguration.defaultResumeVisibilityTimeout
    ) -> PhoneDSHConfiguration {
        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            token: "",
            origin: URL(string: "http://127.0.0.1:1")!,
            deviceTier: deviceTier,
            bundle: bundle,
            allowedModelHosts: allowedModelHosts,
            egressAllowHosts: egressAllowHosts,
            replaySafeModelEndpoints: replaySafeModelEndpoints,
            credentialProvider: credentialProvider,
            githubAgent: githubAgent,
            egressAuthorizer: egressAuthorizer,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout,
            resumeBootReadyTimeout: resumeBootReadyTimeout,
            resumeHelloTimeout: resumeHelloTimeout,
            resumeVisibilityTimeout: resumeVisibilityTimeout)
        configuration.turnInactivityTimeout = defaultTurnInactivityTimeout
        configuration.nativeMCP = nativeMCP
        configuration.engine.bootTimeout = defaultBootTimeout
        configuration.engine.environment = workerEnvironment
        return configuration
    }
}
