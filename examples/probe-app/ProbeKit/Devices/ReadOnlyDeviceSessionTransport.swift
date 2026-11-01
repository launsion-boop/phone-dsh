// SPDX-License-Identifier: MIT

import PhoneDSHAgentCore

public struct ReadOnlyDeviceSessionTransport: DSHRemoteTransport {
    private let transport: any DSHRemoteTransport

    public init(transport: any DSHRemoteTransport) {
        self.transport = transport
    }

    public func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        guard endpoint == "session/page" else {
            throw ProviderError.unsupported("只读设备监视不允许调用 \(endpoint)")
        }
        return try await transport.call(endpoint, args: args)
    }

    public func openMux() async throws -> any DSHMuxConnection {
        ReadOnlyDeviceSessionMux(connection: try await transport.openMux())
    }

    public func authenticationFailed() async {
        await transport.authenticationFailed()
    }
}

private struct ReadOnlyDeviceSessionMux: DSHMuxConnection {
    private static let readableEndpoints: Set<String> = ["session/follow", "$events"]
    private let connection: any DSHMuxConnection

    init(connection: any DSHMuxConnection) {
        self.connection = connection
    }

    func send(_ frame: JSONValue) async throws {
        guard frame["type"]?.stringValue == "open",
              let endpoint = frame["endpoint"]?.stringValue,
              Self.readableEndpoints.contains(endpoint) else {
            throw ProviderError.unsupported("只读设备监视不允许发送这个 mux 帧")
        }
        try await connection.send(frame)
    }

    func receive() async throws -> JSONValue? {
        try await connection.receive()
    }

    func close() async {
        await connection.close()
    }
}
