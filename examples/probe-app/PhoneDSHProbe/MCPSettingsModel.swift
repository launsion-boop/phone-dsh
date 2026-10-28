// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — native MCP settings model shared with the simulator
// suite. It edits the Worker's existing `/dsh/home/mcp.json` registry through
// the same `phone/mcpList` / `phone/mcpUpsert` / `phone/mcpRemove` Remote
// methods the Web tab uses, plus the host-only exact-origin/path grant and
// dedicated MCP Keychain. It is not a second registry and real header values
// never enter the Worker or UserDefaults.
//
// Host-specific lookups are injected by `MCPSettingsPage`, so this file has no
// SwiftUI/app-global dependency and the same model runs under the hostless
// simulator tests.

import Foundation
import Observation
import PhoneDSH
import PhoneDSHAgentCore
import ProbeKit

/// Which one local host owns the shared registry and policy.
enum MCPConfigurationHost {
    case native
    case web
}

struct MCPServerSummary: Identifiable, Equatable {
    let serverName: String
    let url: String
    let enabled: Bool
    let toolCallTimeoutMs: Int
    let headers: [MCPHeaderSummary]
    let status: String
    let error: String?
    let tools: [String]
    let grant: PhoneMCPAccessGrant?

    var id: String { serverName }
    var authorizedURL: String? { grant?.url }
}

struct MCPHeaderSummary: Identifiable, Equatable {
    let name: String
    let envName: String
    let hasStoredValue: Bool
    var id: String { name }
}

struct MCPHeaderDraft: Identifiable, Equatable {
    let id: UUID
    var name: String
    var envName: String
    var value: String
    var hasStoredValue: Bool

    init(id: UUID = UUID(),
         name: String = "Authorization",
         envName: String = "",
         value: String = "",
         hasStoredValue: Bool = false) {
        self.id = id
        self.name = name
        self.envName = envName
        self.value = value
        self.hasStoredValue = hasStoredValue
    }
}

struct MCPServerDraft: Equatable {
    var serverName: String
    var url: String
    var enabled: Bool
    var toolCallTimeoutMs: String
    var headers: [MCPHeaderDraft]

    static func new() -> MCPServerDraft {
        MCPServerDraft(serverName: "",
                       url: "",
                       enabled: true,
                       toolCallTimeoutMs: "60000",
                       headers: [])
    }

    init(server: MCPServerSummary) {
        serverName = server.serverName
        url = server.url
        enabled = server.enabled
        toolCallTimeoutMs = String(server.toolCallTimeoutMs)
        headers = server.headers.map {
            MCPHeaderDraft(name: $0.name,
                           envName: $0.envName,
                           value: "",
                           hasStoredValue: $0.hasStoredValue)
        }
    }

    init(controlDraft: MCPControlDraft) {
        serverName = controlDraft.serverName
        url = controlDraft.url
        enabled = controlDraft.enabled
        toolCallTimeoutMs = String(controlDraft.toolCallTimeoutMs)
        headers = controlDraft.headers.map {
            MCPHeaderDraft(name: $0.name,
                           envName: $0.envName,
                           value: "",
                           hasStoredValue: false)
        }
    }

    init(serverName: String, url: String, enabled: Bool,
         toolCallTimeoutMs: String, headers: [MCPHeaderDraft]) {
        self.serverName = serverName
        self.url = url
        self.enabled = enabled
        self.toolCallTimeoutMs = toolCallTimeoutMs
        self.headers = headers
    }
}

@MainActor
@Observable
final class MCPSettingsModel {
    let host: MCPConfigurationHost
    private let settings: PhoneMCPAccessSettings
    private let isHostRunning: @MainActor () -> Bool
    private let makeTransport: @MainActor () async throws -> any DSHRemoteTransport
    private let refreshPolicyAction: @MainActor () -> Void
    /// Server names whose durable staging could not be marked ownerless yet.
    /// Keeping them in the model (instead of `try?`-dropping the failure) lets
    /// the next refresh retry, so a transient document-store error cannot leave
    /// an unresolved stage protected from the authoritative registry forever.
    private var pendingAbandonNames: Set<String> = []

    private(set) var rows: [MCPServerSummary] = []
    private(set) var loading = false
    private(set) var errorText: String?
    private(set) var notice: String?

    init(host: MCPConfigurationHost,
         settings: PhoneMCPAccessSettings,
         isHostRunning: @escaping @MainActor () -> Bool,
         makeTransport: @escaping @MainActor () async throws -> any DSHRemoteTransport,
         refreshPolicy: @escaping @MainActor () -> Void) {
        self.host = host
        self.settings = settings
        self.isHostRunning = isHostRunning
        self.makeTransport = makeTransport
        self.refreshPolicyAction = refreshPolicy
    }

    var hostRunning: Bool {
        isHostRunning()
    }

    var hostLabel: String {
        switch host {
        case .native: return "原生恢复主机"
        case .web: return "完整 Web 主机"
        }
    }

    func refresh() async {
        guard !loading else { return }
        retryPendingAbandons()
        guard hostRunning else {
            rows = []
            errorText = "请先启动\(hostLabel)，再读取 MCP 注册表。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let snapshot = try await transport().call("phone/mcpList", args: .object([:]))
            let loadedGrants = (try? settings.load())?.grants ?? []
            let grants = Dictionary(uniqueKeysWithValues: loadedGrants.map { ($0.serverName, $0) })
            let servers = (snapshot["servers"]?.arrayValue ?? []).compactMap { value -> MCPServerSummary? in
                self.row(value, grants: grants)
            }
            // A successful list is the authority: a grant/key whose row no
            // longer exists is revoked immediately, including after a removal
            // made from the Web tab. A corrupt registry (`error`) is not an
            // empty registry and must never mass-revoke credentials.
            if snapshot["error"] == nil {
                let existing = Dictionary(uniqueKeysWithValues:
                    servers.map { ($0.serverName, $0.url) })
                _ = try? settings.reconcile(existingServers: existing,
                                            protecting: pendingAbandonNames)
                refreshHostPolicy()
            }
            let freshGrants = Dictionary(uniqueKeysWithValues:
                ((try? settings.load())?.grants ?? []).map { ($0.serverName, $0) })
            rows = servers.map { server in
                MCPServerSummary(serverName: server.serverName,
                                 url: server.url,
                                 enabled: server.enabled,
                                 toolCallTimeoutMs: server.toolCallTimeoutMs,
                                 headers: server.headers,
                                 status: server.status,
                                 error: server.error,
                                 tools: server.tools,
                                 grant: freshGrants[server.serverName])
            }
            errorText = snapshot["error"]?.stringValue
        } catch {
            rows = []
            errorText = error.localizedDescription
        }
    }

    /// Persist the "no verdict" state so a later successful `phone/mcpList`
    /// (or materialized-registry start) can decide commit/rollback. When the
    /// write fails, keep the names for a retry instead of discarding the error.
    @discardableResult
    private func keepStagingOwnerless(_ names: Set<String>) -> Bool {
        guard !names.isEmpty else { return true }
        do {
            try settings.markStagedGrantsAbandoned(serverNames: names)
            pendingAbandonNames.subtract(names)
            return true
        } catch {
            pendingAbandonNames.formUnion(names)
            return false
        }
    }

    private func retryPendingAbandons() {
        guard !pendingAbandonNames.isEmpty else { return }
        if (try? settings.markStagedGrantsAbandoned(serverNames: pendingAbandonNames)) != nil {
            pendingAbandonNames.removeAll()
        }
    }

    private func unknownStagingSuffix(serverName: String) -> String {
        if let staged = try? settings.hasStagedGrant(serverName: serverName),
           !staged {
            return "已恢复该服务器的配置。"
        }
        return pendingAbandonNames.isEmpty
            ? "请刷新 MCP 列表，确认后再试。"
            : "请稍后刷新 MCP 列表再试。"
    }

    func save(_ draft: MCPServerDraft) async {
        errorText = nil
        notice = nil
        let trimmedName = draft.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            errorText = "请填写服务器名称和 MCP 地址。"
            return
        }
        let timeout = Int(draft.toolCallTimeoutMs) ?? 0
        guard timeout > 0 else {
            errorText = "工具调用超时必须是正整数毫秒。"
            return
        }
        let normalizedURL: URL
        do {
            _ = try PhoneMCPAccessSettings.validatedServerName(trimmedName)
            normalizedURL = try PhoneMCPAccessSettings.normalizedURL(trimmedURL)
        } catch {
            errorText = error.localizedDescription
            return
        }
        var headerNames: [String] = []
        var envNames: [String: String] = [:]
        var values: [String: String] = [:]
        var index = 1
        for header in draft.headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            let env = header.envName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedEnv = env.isEmpty ? "PDSH_MCP_HEADER_\(index)" : env
            index += 1
            headerNames.append(name)
            envNames[name] = resolvedEnv
            if !header.value.isEmpty { values[name] = header.value }
        }
        guard (try? PhoneMCPAccessSettings.validatedHeaders(headerNames)) != nil else {
            errorText = "MCP 认证头名称无效。"
            return
        }
        do {
            let grant = try settings.grant(serverName: trimmedName,
                                           url: normalizedURL.absoluteString,
                                           headers: headerNames,
                                           values: values)
            refreshHostPolicy()
            do {
                _ = try await transport().call(
                    "phone/mcpUpsert",
                    args: .object(["request": .object([
                        "serverName": .string(trimmedName),
                        "url": .string(grant.url),
                        "headersFromEnv": .object(envNames.mapValues { JSONValue.string($0) }),
                        "hostManagedHeaders": .array(headerNames.map { JSONValue.string($0) }),
                        "enabled": .bool(draft.enabled),
                        "toolCallTimeoutMs": .number(Double(timeout)),
                    ])]))
                // The Worker row is committed; now the previous Keychain
                // account may be removed. A failed cleanup is a visible
                // commit-pending status, never a reason to roll the row back;
                // the durable staging is retried by the next load/reconcile.
                var cleanupPending = false
                do {
                    let committed = try settings.commitGrant(serverName: grant.serverName,
                                                              expectedURL: grant.url,
                                                              expectedHeaders: grant.headers)
                    cleanupPending = !committed
                    if !committed {
                        // No cleanup proof: make the stage ownerless so the
                        // next real registry read can finish it.
                        _ = keepStagingOwnerless([grant.serverName])
                    }
                } catch {
                    cleanupPending = true
                    // The Worker row is committed; make the durable stage
                    // ownerless so the next real registry read may finish the
                    // cleanup instead of protecting it until host restart.
                    _ = keepStagingOwnerless([grant.serverName])
                }
                refreshHostPolicy()
                notice = cleanupPending
                    ? "已保存“\(trimmedName)”；旧密钥清理暂未完成，已保留可恢复记录并在下次读取时重试。"
                    : "已保存“\(trimmedName)”；网络授权与密钥只作用于这个精确 URL。"
            } catch {
                // A lost reply is not proof that the Worker write failed. Query
                // the real registry first: if it already names this exact URL
                // the upsert committed, so commit the grant instead of turning
                // the row into an unauthorized orphan. Only a confirmed old or
                // absent row is rolled back; an unreadable registry keeps the
                // persisted staging for the next reconcile/host start.
                _ = await resolveUpsertFailure(serverName: trimmedName,
                                               grant: grant,
                                               originalError: error)
                return
            }
            await refresh()
        } catch {
            let message = error.localizedDescription
            await refresh()
            errorText = message
        }
    }

    /// Resolve one failed `phone/mcpUpsert` by consulting the authoritative
    /// registry, and keep the document staging when the result is unknown.
    /// Returns true when the registry proves the write already committed.
    private func resolveUpsertFailure(serverName: String,
                                      grant: PhoneMCPAccessGrant,
                                      originalError: Error) async -> Bool {
        let snapshot: JSONValue
        do {
            snapshot = try await transport().call("phone/mcpList", args: .object([:]))
        } catch {
            keepStagingOwnerless([serverName])
            await refresh()
            errorText = "MCP 保存结果未确认。\(unknownStagingSuffix(serverName: serverName))"
            return false
        }
        guard snapshot["error"] == nil else {
            keepStagingOwnerless([serverName])
            await refresh()
            errorText = "暂时无法读取 MCP 列表，现有配置未改动。\(unknownStagingSuffix(serverName: serverName))"
            return false
        }
        let registryURL = (snapshot["servers"]?.arrayValue ?? [])
            .first { $0["serverName"]?.stringValue == serverName }?["url"]?.stringValue
        let registryKey = registryURL.flatMap { PhoneMCPAccessSettings.canonicalEndpointKey($0) }
        let grantKey = PhoneMCPAccessSettings.canonicalEndpointKey(grant.url)
        if let registryKey, let grantKey, registryKey == grantKey {
            var cleanupPending = false
            do {
                let committed = try settings.commitGrant(serverName: grant.serverName,
                                                          expectedURL: grant.url,
                                                          expectedHeaders: grant.headers)
                cleanupPending = !committed
                if !committed {
                    _ = keepStagingOwnerless([serverName])
                }
            } catch {
                cleanupPending = true
                _ = keepStagingOwnerless([serverName])
            }
            refreshHostPolicy()
            notice = cleanupPending
                ? "MCP 保存已在 Worker 生效；旧密钥清理暂未完成，已保留可恢复记录并在下次读取时重试。"
                : "MCP 保存已在 Worker 生效；已提交精确授权与设备密钥。"
            await refresh()
            return true
        }
        // Rollback needs positive proof: the registry still names the grant
        // that `rollbackGrant` will actually restore, or this was a new row
        // and the registry confirms no row exists. An absent old row or an
        // unexpected URL is unknown, so keep the durable staging instead of
        // blindly rolling back a possibly committed Worker row.
        let previousGrant: PhoneMCPAccessGrant?
        do {
            previousGrant = try settings.stagedPreviousGrant(serverName: serverName)
        } catch {
            keepStagingOwnerless([serverName])
            await refresh()
            errorText = "暂时无法读取本地保存记录，现有配置未改动。\(unknownStagingSuffix(serverName: serverName))"
            return false
        }
        let previousKey = previousGrant.flatMap {
            PhoneMCPAccessSettings.canonicalEndpointKey($0.url)
        }
        let confirmedPrevious = previousKey != nil && registryKey == previousKey
        let confirmedAbsentNewRow = previousKey == nil && registryURL == nil
        guard confirmedPrevious || confirmedAbsentNewRow else {
            keepStagingOwnerless([serverName])
            await refresh()
            errorText = "还未确认上次保存是否生效，现有配置未改动。\(unknownStagingSuffix(serverName: serverName))"
            return false
        }
        do {
            let rolledBack = try settings.rollbackGrant(serverName: grant.serverName,
                                                        expectedURL: grant.url,
                                                        expectedHeaders: grant.headers)
            guard rolledBack else {
                // `false` means nothing was restored (for example a newer edit
                // owns the slot). Never report that as a successful rollback.
                keepStagingOwnerless([serverName])
                refreshHostPolicy()
                await refresh()
                errorText = "未能确认已恢复旧配置。\(unknownStagingSuffix(serverName: serverName))"
                return false
            }
        } catch {
            keepStagingOwnerless([serverName])
            refreshHostPolicy()
            await refresh()
            errorText = "恢复旧配置失败：\(error.localizedDescription) \(unknownStagingSuffix(serverName: serverName))"
            return false
        }
        refreshHostPolicy()
        if previousGrant != nil {
            _ = try? await transport().call(
                "phone/mcpReconnect",
                args: .object(["request": .object([
                    "serverName": .string(serverName),
                ])]))
        }
        await refresh()
        errorText = originalError.localizedDescription
        return false
    }

    func remove(_ server: MCPServerSummary) async {
        errorText = nil
        notice = nil
        do {
            _ = try await transport().call(
                "phone/mcpRemove",
                args: .object(["request": .object(["serverName": .string(server.serverName)])]))
            try settings.revoke(serverName: server.serverName)
            refreshHostPolicy()
            notice = "已删除“\(server.serverName)”，并撤销其网络授权与设备密钥。"
            await refresh()
        } catch {
            let message = error.localizedDescription
            await refresh()
            errorText = message
        }
    }

    private func refreshHostPolicy() {
        refreshPolicyAction()
    }

    private func transport() async throws -> any DSHRemoteTransport {
        try await makeTransport()
    }

    private func row(_ value: JSONValue,
                     grants: [String: PhoneMCPAccessGrant]) -> MCPServerSummary? {
        guard let serverName = value["serverName"]?.stringValue,
              let url = value["url"]?.stringValue else { return nil }
        let headersFromEnv = value["headersFromEnv"]?.objectValue ?? [:]
        let stored = settings.storedHeaderNames(serverName: serverName)
        let headers = headersFromEnv.keys.sorted().map { name in
            MCPHeaderSummary(name: name,
                             envName: headersFromEnv[name]?.stringValue ?? "",
                             hasStoredValue: stored.contains(name))
        }
        return MCPServerSummary(
            serverName: serverName,
            url: url,
            enabled: value["enabled"]?.boolValue ?? true,
            toolCallTimeoutMs: value["toolCallTimeoutMs"]?.intValue ?? 60_000,
            headers: headers,
            status: value["status"]?.stringValue ?? "connecting",
            error: value["error"]?.stringValue,
            tools: (value["tools"]?.arrayValue ?? []).compactMap(\.stringValue),
            grant: grants[serverName])
    }
}
