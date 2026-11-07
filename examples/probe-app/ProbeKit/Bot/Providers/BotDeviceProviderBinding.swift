// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

public struct BotDeviceTransportFrame: Sendable {
    public let deviceID: String
    public let transport: BotDeviceTransport
    public let data: Data

    public init(deviceID: String, transport: BotDeviceTransport, data: Data) {
        self.deviceID = deviceID
        self.transport = transport
        self.data = data
    }
}

public protocol BotDeviceEnvelopeConnector: DeviceConnector {
    func envelopes() -> AsyncStream<BotDeviceTransportFrame>
    func nextOutboundSeq(deviceID: String, transport: BotDeviceTransport) -> Int64
    func send(_ envelope: BotDeviceEnvelope, transport: BotDeviceTransport) async throws -> String?
}

public enum BotDeviceProviderBindingError: LocalizedError {
    case unavailableTransport
    case unknownOnlineDevice
    case missingMapping
    case deviceMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailableTransport: return "当前连接器没有真实设备 envelope 传输。"
        case .unknownOnlineDevice: return "设备未由全局连接器发布为在线配对设备。"
        case .missingMapping: return "设备没有宿主分配的传输 Session 映射。"
        case .deviceMismatch: return "连接器帧的 device_id 与 envelope 不一致。"
        }
    }
}

@MainActor
public final class BotDeviceProviderBinding {
    public let ingress: BotDeviceIngress
    public let tools: BotDeviceToolProvider
    public let coordinator: DeviceSessionCoordinator

    /// Always read the *current* bridge: the Host recreates the bridge on every
    /// engine launch, and a captured old instance would bypass the new gate.
    private let bridgeProvider: @MainActor @Sendable () -> PhoneCapabilityBridge?
    private var envelopeTask: Task<Void, Never>?

    /// The composition root must pass a provider, not a captured instance:
    /// `bridgeProvider: { [weak chatModel] in chatModel?.phoneCapabilityBridge }`.
    /// The Host recreates the bridge on every engine launch.
    public init(domain: SQLiteDomainStore, runtime: BotMCPRuntime,
                bridgeProvider: @escaping @MainActor @Sendable () -> PhoneCapabilityBridge?,
                coordinator: DeviceSessionCoordinator? = nil,
                onWake: BotDeviceIngress.WakeHandler? = nil) async throws {
        let coordinator = coordinator ?? .shared
        guard coordinator.activeConnector != nil else {
            throw BotDeviceProviderBindingError.unavailableTransport
        }
        self.coordinator = coordinator
        self.bridgeProvider = bridgeProvider
        ingress = BotDeviceIngress(store: domain, inbox: WakeInbox(
            store: SQLiteWakeInboxStore(domainStore: domain, botId: "main")), onWake: onWake)
        let currentBridgeProvider = bridgeProvider
        tools = BotDeviceToolProvider(authorizer: await runtime.authorizer) { name, arguments, _ in
            guard let bridge = await currentBridgeProvider() else {
                throw BotMCPError.unavailable("PhoneCapabilityBridge is not available")
            }
            let data = try arguments.encoded()
            let text = String(decoding: data, as: UTF8.self)
            // PhoneCapabilityBridge requires the main thread; awaiting a
            // @MainActor helper keeps the call on the main actor.
            let result = try await BotDeviceProviderBinding.callBridge(bridge, name: name, arguments: text)
            return try BotJSONValue.parse(Data(result.utf8))
        }
    }

    public convenience init(domain: SQLiteDomainStore, runtime: BotMCPRuntime,
                            bridge: PhoneCapabilityBridge,
                            coordinator: DeviceSessionCoordinator? = nil,
                            onWake: BotDeviceIngress.WakeHandler? = nil) async throws {
        try await self.init(domain: domain, runtime: runtime, bridgeProvider: { bridge },
                            coordinator: coordinator, onWake: onWake)
    }

    public func attach(runtime: BotDSHRemoteRuntime) async throws {
        guard let transport = currentConnector() as? any BotDeviceEnvelopeConnector else {
            throw BotDeviceProviderBindingError.unavailableTransport
        }
        try await ingress.attach(runtime)
        startEnvelopeLoop(transport)
        await reconcileOnReconnect()
    }

    /// Re-reads the globally installed connector and restarts the envelope
    /// stream. A Host rebuild may replace the connector; a captured instance
    /// must not keep feeding the old one.
    public func refreshConnector() async throws {
        guard let transport = currentConnector() as? any BotDeviceEnvelopeConnector else {
            throw BotDeviceProviderBindingError.unavailableTransport
        }
        envelopeTask?.cancel()
        envelopeTask = nil
        startEnvelopeLoop(transport)
    }

    public func stop() async {
        envelopeTask?.cancel()
        envelopeTask = nil
        await ingress.detach()
    }

    @discardableResult
    public func receive(_ frame: BotDeviceTransportFrame) async throws -> BotDeviceIngressReceipt {
        guard coordinator.onlineDevices.contains(where: { $0.deviceID == frame.deviceID }) else {
            throw BotDeviceProviderBindingError.unknownOnlineDevice
        }
        guard let mapping = coordinator.savedMapping(for: frame.deviceID) else {
            throw BotDeviceProviderBindingError.missingMapping
        }
        let envelope = try BotDeviceEnvelope(data: frame.data, expectedSessionID: mapping.sessionID)
        guard envelope.deviceID == frame.deviceID else {
            throw BotDeviceProviderBindingError.deviceMismatch
        }
        return try await ingress.receive(
            envelope, transport: frame.transport,
            expectedSessionID: mapping.sessionID, displayName: displayName(for: frame.deviceID))
    }

    public func mappedReply(source: BotDeviceEnvelope, transport: BotDeviceTransport,
                            text: String) throws -> BotDeviceReply {
        guard let mapping = coordinator.savedMapping(for: source.deviceID) else {
            throw BotDeviceProviderBindingError.missingMapping
        }
        guard let liveTransport = currentConnector() as? any BotDeviceEnvelopeConnector else {
            throw BotDeviceProviderBindingError.unavailableTransport
        }
        return try BotDeviceReply(
            source: source, transport: transport, sessionID: mapping.sessionID, text: text,
            downSeq: liveTransport.nextOutboundSeq(deviceID: source.deviceID, transport: transport))
    }

    public func replyWriter() throws -> any BotDeviceReplyWriting {
        guard let transport = currentConnector() as? any BotDeviceEnvelopeConnector else {
            throw BotDeviceProviderBindingError.unavailableTransport
        }
        return BotDeviceConnectorReplyWriter(connector: transport)
    }

    /// Reconnect entry point for `needs_reconciliation` device replies. The
    /// composition root should call `refreshConnector()` and then this method
    /// on a device online transition or a Host rebuild; it never republishes an
    /// uncertain effect.
    @discardableResult
    public func reconcileOnReconnect() async -> BotDeviceReconciliationSummary? {
        guard let transport = currentConnector() as? any BotDeviceEnvelopeConnector else {
            return nil
        }
        let service = BotDeviceReplyService(
            store: ingress.store,
            writer: BotDeviceConnectorReplyWriter(connector: transport),
            reconciler: transport as? any BotDeviceReceiptQuerying)
        do {
            return try await service.reconcile()
        } catch {
            coordinator.reportBotIngressFailure(error)
            return nil
        }
    }

    private func currentConnector() -> (any DeviceConnector)? {
        coordinator.activeConnector
    }

    private func displayName(for deviceID: String) -> String {
        coordinator.onlineDevices.first(where: { $0.deviceID == deviceID })?.displayName ?? deviceID
    }

    private func startEnvelopeLoop(_ transport: any BotDeviceEnvelopeConnector) {
        envelopeTask?.cancel()
        envelopeTask = Task { @MainActor [weak self] in
            for await frame in transport.envelopes() {
                guard let self else { return }
                do {
                    _ = try await self.receive(frame)
                } catch {
                    self.coordinator.reportBotIngressFailure(error)
                }
            }
        }
    }

    @MainActor
    private static func callBridge(_ bridge: PhoneCapabilityBridge,
                                   name: String, arguments: String) async throws -> String {
        try await bridge.callTool(name: name, arguments: arguments)
    }
}

private struct BotDeviceConnectorReplyWriter: BotDeviceReplyWriting {
    let connector: any BotDeviceEnvelopeConnector

    func send(_ reply: BotDeviceReply) async throws -> String? {
        do {
            return try await connector.send(reply.envelope, transport: reply.transport)
        } catch let error as BotDeviceReplyWriteError {
            throw error
        }
    }
}
