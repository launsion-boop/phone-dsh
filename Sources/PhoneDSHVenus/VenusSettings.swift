// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSH

public struct VenusConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public init(baseURL: String = "", model: String = "ui-venus-2-9b") { self.baseURL = baseURL; self.model = model }
    public func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.isEmpty, model.utf8.count <= 200, !model.contains(where: { $0.isNewline }) else {
            throw VenusFailure("venus_configuration", "请配置 UI-Venus 的 HTTPS OpenAI 接口和模型名称")
        }
        return url.appendingPathComponent(path)
    }
}

/// Dedicated credentials: never forward the cloud team key to a custom service.
public final class VenusSettings: @unchecked Sendable {
    public static let shared = VenusSettings()
    private let defaults: UserDefaults
    private let secrets: any ModelProviderSecretStore
    private let lock = NSLock()
    private let reference = "ui-venus-key"
    private let preference = "phone-dsh.ui-venus.configuration.v1"
    public init(defaults: UserDefaults = .standard, secrets: any ModelProviderSecretStore = KeychainModelProviderSecretStore(service: "dev.phone-dsh.ui-venus")) { self.defaults = defaults; self.secrets = secrets }
    public func load() -> VenusConfiguration {
        lock.withLock {
            guard let data = defaults.data(forKey: preference), let value = try? JSONDecoder().decode(VenusConfiguration.self, from: data) else { return VenusConfiguration() }
            return value
        }
    }
    public func save(_ configuration: VenusConfiguration, key: String?) throws {
        _ = try configuration.endpoint("models")
        try lock.withLock {
            let prior = defaults.data(forKey: preference).flatMap { try? JSONDecoder().decode(VenusConfiguration.self, from: $0) }
            if prior?.baseURL != configuration.baseURL && key?.isEmpty != false { throw VenusFailure("venus_key", "更换接口需要重新填写该服务的密钥") }
            if let key {
                guard !key.isEmpty, key.utf8.count <= 4096, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw VenusFailure("venus_key", "UI-Venus 密钥格式无效") }
                try secrets.setSecret(key, for: reference)
            }
            defaults.set(try JSONEncoder().encode(configuration), forKey: preference)
        }
    }
    public func key() throws -> String {
        guard let key = try secrets.secret(for: reference), !key.isEmpty else { throw VenusFailure("venus_key", "尚未配置 UI-Venus 服务密钥") }
        return key
    }
}
