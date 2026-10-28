// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the App's chat host assembly, shared with the
// simulator/device E2E suites.
//
// The Chat page (and the full-Web surface it hosts) must use one host
// configuration and one persistent workspace. Keeping the path and the
// gateway/model environment here means a suite exercises the same
// `Documents/chat-host` tree and the same `PhoneDSHConfiguration` values the
// installed App uses; it does not construct a parallel host for the test.

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHEngine

/// Host assembly shared by the App and the simulator E2E suites.
public enum ChatHostConfiguration {
    /// Persistent workspace directory below the App's Documents directory.
    public static let workspaceDirectoryName = "chat-host"
    /// Worker-side placeholder key. The real credential stays in the host
    /// gateway and never reaches the Worker.
    public static let workerPlaceholderKey = "phone-host-injects-key"
    public static let defaultDrainDeadline: TimeInterval = 20
    public static let defaultHelloTimeout: TimeInterval = 240
    public static let defaultBootTimeout: TimeInterval = 240

    /// `Documents/chat-host` for the App, or below the caller's Documents
    /// directory in a hostless test process (the suite passes the installed
    /// App container explicitly).
    public static func workspaceRoot(documents: URL? = nil) -> URL {
        let documents = documents
            ?? FileManager.default.urls(for: .documentDirectory,
                                        in: .userDomainMask)[0]
        return documents.appendingPathComponent(workspaceDirectoryName,
                                                isDirectory: true)
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
                            helloTimeout: TimeInterval = ChatHostConfiguration.defaultHelloTimeout)
        -> PhoneDSHConfiguration {
        let hostRule = modelHostRule(for: modelBaseURL) ?? modelBaseURL.absoluteString
        var configuration = PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            token: "",
            origin: URL(string: "http://127.0.0.1:1")!,
            bundle: bundle,
            allowedModelHosts: [hostRule],
            egressAllowHosts: egressHosts,
            credentialProvider: credentialProvider,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout)
        configuration.engine.bootTimeout = defaultBootTimeout
        configuration.engine.environment = [
            "DEEPSEEK_BASE_URL": modelBaseURL.absoluteString,
            // The host gateway injects the real key; the Worker never holds it.
            "DEEPSEEK_API_KEY": workerPlaceholderKey,
            "DSH_TELEMETRY_DISABLED": "1",
            "PDSH_MODEL_NAME": modelName,
        ]
        return configuration
    }
}
