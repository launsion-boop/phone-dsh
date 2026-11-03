// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSH
import PhoneDSHAgentCore
import PhoneDSHGateway

public protocol AnthropicMessagesTransport: Sendable {
    func stream(_ request: AnthropicMessagesRequest) -> AsyncThrowingStream<AnthropicStreamEvent, Error>
}

public protocol MainModelClientResolving: Sendable {
    func resolveClient() throws -> (client: any AnthropicMessagesTransport, model: String, maxTokens: Int)
}

public enum AnthropicProviderSupport {
    public static func validate(_ profile: ProviderProfile) throws {
        let description = [profile.id, profile.displayName, profile.baseURL]
            .joined(separator: " ").lowercased()
        if description.contains("openai") || description.contains("chat/completions") {
            throw MainFailure.unsupportedProtocol("OpenAI-compatible Messages are not supported; use DSH")
        }
        if description.contains("gemini") || description.contains("azure-openai") {
            throw MainFailure.unsupportedProtocol("only Anthropic Messages is supported; use DSH")
        }
    }
}

public struct NativeMainGatewayClient: AnthropicMessagesTransport {
    private let baseURL: URL
    private let gateway: ModelGateway
    private let adapter = AnthropicMessagesAdapter()

    public init(profile: ProviderProfile, credentialProvider: any CredentialProvider,
                responseLogRoot: URL? = nil) throws {
        guard let baseURL = profile.endpointURL, let host = profile.allowedModelHost else {
            throw MainFailure.notConfigured
        }
        self.baseURL = baseURL
        let configuration = ModelGatewayConfiguration(
            allowedUpstreamHosts: [host],
            replaySafeModelEndpoints: ModelGatewayConfiguration.standardModelEndpoints(baseURL: baseURL))
        let responseLog = try responseLogRoot.map {
            try ModelGateway.makeResponseLog(configuration: configuration, workspaceRoot: $0)
        }
        self.gateway = ModelGateway(configuration: configuration,
                                    credentialProvider: credentialProvider,
                                    responseLog: responseLog)
    }

    public func shutdown() async {
        await gateway.shutdown()
    }

    public func stream(_ request: AnthropicMessagesRequest)
    -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = try adapter.messagesEndpoint(baseURL: baseURL)
                    let body = try request.bodyData()
                    let gatewayRequest = GatewayRequest(method: "POST", url: endpoint, headers: [
                        "accept": "text/event-stream",
                        "content-type": "application/json",
                        "anthropic-version": "2023-06-01",
                    ], body: body)
                    var parser = AnthropicSSEParser()
                    var status: Int?
                    var receivedFinal = false
                    for try await chunk in gateway.handle(gatewayRequest) {
                        try Task.checkCancellation()
                        if let chunkStatus = chunk.status {
                            status = chunkStatus
                            guard (200...299).contains(chunkStatus) else {
                                throw MainFailure.provider("model upstream returned HTTP \(chunkStatus)")
                            }
                        }
                        if !chunk.body.isEmpty {
                            for event in try parser.consume(chunk.body) {
                                continuation.yield(event)
                                if case .providerError(let message) = event {
                                    throw MainFailure.provider(message)
                                }
                            }
                        }
                        if chunk.isFinal {
                            receivedFinal = true
                            for event in try parser.finish() { continuation.yield(event) }
                        }
                    }
                    guard status != nil, receivedFinal else {
                        throw MainFailure.provider("recoverable upstream stream failure: response ended before its final chunk")
                    }
                    continuation.finish()
                } catch let failure as MainFailure {
                    continuation.finish(throwing: failure)
                } catch is CancellationError {
                    continuation.finish(throwing: MainFailure.cancelled)
                } catch let error as ModelGatewayError {
                    if case .credentialUnavailable = error {
                        continuation.finish(throwing: MainFailure.notConfigured)
                    } else if Task.isCancelled {
                        continuation.finish(throwing: MainFailure.cancelled)
                    } else {
                        continuation.finish(throwing: MainFailure.provider(
                            "recoverable model transport failure: \(MainRuntimeJSON.boundedString(error))"))
                    }
                } catch {
                    continuation.finish(throwing: MainFailure.provider(
                        "recoverable model transport failure: \(MainRuntimeJSON.boundedString(error))"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public final class NativeMainGatewayClientProvider: MainModelClientResolving, @unchecked Sendable {
    private let settings: PhoneModelProviderSettings
    private let responseLogRoot: URL?
    private let lock = NSLock()
    private var cached: (profile: ProviderProfile, client: NativeMainGatewayClient)?

    public init(settings: PhoneModelProviderSettings = .shared, responseLogRoot: URL? = NativeMainGatewayClientProvider.defaultResponseLogRoot()) {
        self.settings = settings
        self.responseLogRoot = responseLogRoot
    }

    public func resolveClient() throws -> (client: any AnthropicMessagesTransport, model: String, maxTokens: Int) {
        let snapshot = try settings.load()
        guard let profile = snapshot.selected else { throw MainFailure.notConfigured }
        try AnthropicProviderSupport.validate(profile)
        switch try settings.apiKeyStatus(for: profile.id) {
        case .present:
            break
        case .missing:
            throw MainFailure.notConfigured
        case .unreadable:
            throw MainFailure.provider("the configured model credential cannot be read")
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.profile == profile {
            let definition = profile.modelDefinitions.first { $0.id == profile.model }
            return (cached.client, profile.model, definition?.maxTokens ?? 2_048)
        }
        let credentialProvider = try settings.makeCredentialProvider()
        let client = try NativeMainGatewayClient(profile: profile,
                                                 credentialProvider: credentialProvider,
                                                 responseLogRoot: responseLogRoot)
        cached = (profile, client)
        let definition = profile.modelDefinitions.first { $0.id == profile.model }
        return (client, profile.model, definition?.maxTokens ?? 2_048)
    }

    public static func defaultResponseLogRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PersonalAgent/gateway-log", isDirectory: true)
    }
}
