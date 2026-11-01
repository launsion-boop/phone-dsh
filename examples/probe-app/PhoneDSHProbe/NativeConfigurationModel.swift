// SPDX-License-Identifier: MIT
// Native DSH plugin, settings, and agent configuration backed by DSH Remote.

import Foundation
import Observation
import PhoneDSHAgentCore

struct NativePluginEntry: Identifiable, Equatable {
    let id: String
    let module: String
    let enabled: Bool
    let phase: String?
}

struct NativeExperimentalPlugin: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let loaded: Bool
}

struct NativeModelRoute: Identifiable, Hashable {
    let provider: String
    let providerName: String
    let model: String
    let modelName: String
    var available = true
    var id: String { "\(provider)/\(model)" }
}

struct NativePermissionMode: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String?
}

struct NativeSettingsField: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let kind: Kind
    let value: JSONValue
    let base: JSONValue?
    let user: JSONValue?

    enum Kind: Equatable { case number, toggle, text, readOnly }
    var overridden: Bool { user != nil && user != base }
    var inputText: String {
        switch value {
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, let integer = Int(exactly: value) { return String(integer) }
            return String(value)
        case .string(let value): return value
        case .array, .object, .null:
            guard let data = try? value.encoded() else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

struct NativeSettingsGroup: Identifiable, Equatable {
    let namespace: String
    let title: String
    let detail: String
    let revision: Int
    let writable: Bool
    let fields: [NativeSettingsField]
    var id: String { namespace }
}

@MainActor
@Observable
final class NativeConfigurationModel {
    static let shared = NativeConfigurationModel()

    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var settingsError: String?
    private(set) var inventoryError: String?
    private(set) var modelCatalogError: String?
    private(set) var permissionCatalogError: String?
    private(set) var namespaceErrors: [String: String] = [:]
    private(set) var pluginEntries: [NativePluginEntry] = []
    private(set) var settingsGroups: [NativeSettingsGroup] = []
    private(set) var modelRoutes: [NativeModelRoute] = []
    private(set) var defaultPermissionModes: [NativePermissionMode] = []
    private(set) var defaultPermissionMode: String?
    private(set) var defaultPermissionDraft: String?
    private(set) var settingsWritable = false
    private var namespaceValues: [String: JSONValue] = [:]
    private var namespaceRevisions: [String: Int] = [:]
    private var drafts: [String: [String: JSONValue]] = [:]
    private var transport: (any DSHRemoteTransport)?

    var canManagePlugins: Bool { false }
    var hasDrafts: Bool { drafts.values.contains(where: { !$0.isEmpty }) || defaultPermissionDraft != nil }
    var stagedDefaultPermissionMode: String { defaultPermissionDraft ?? defaultPermissionMode ?? "" }
    var hasDefaultPermissionDraft: Bool { defaultPermissionDraft != nil && defaultPermissionDraft != defaultPermissionMode }
    var pluginManagementMessage: String {
        "此 iPhone Worker 没有 pnpm、execa 或子进程安装环境。插件与组合包可查看，安装、启用和停用需在桌面 DSH 管理。"
    }
    var experimentalPlugins: [NativeExperimentalPlugin] {
        let definitions: [(String, String, String)] = [
            ("agent-team", "智能体团队", "@deepseek-ai/dsh-experimental-agent-team-profile"),
            ("voice-input", "语音输入", "@deepseek-ai/dsh-experimental-voice-input-bundle"),
            ("auto-review", "自动授权审查", "@deepseek-ai/dsh-experimental-auto-review"),
            ("developer-tools", "开发者工具", "@deepseek-ai/dsh-client-ui-settings-general"),
        ]
        return definitions.map { id, title, module in
            let entry = pluginEntries.first { $0.module == module || $0.module.hasPrefix(module + "/") }
            let loaded = entry?.enabled == true && entry?.phase == "active"
            let status = loaded
                ? "Worker 当前已加载 · \(entry?.phase ?? "active")"
                : "Worker 未加载；安装/启用不能从此 iPhone 页面执行。"
            return NativeExperimentalPlugin(id: id, title: title, status: status, loaded: loaded)
        }
    }
    var canEditDefaultPermission: Bool { settingsWritable && namespaceValues["permission"] != nil }

    func group(_ namespace: String) -> NativeSettingsGroup? {
        settingsGroups.first { $0.namespace == namespace }
    }

    func settingsDocument() -> String {
        guard let data = try? JSONValue.object(namespaceValues).encoded(),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: pretty, encoding: .utf8) ?? "{}"
    }

    func refresh() async {
        guard !isLoading else { return }
        guard !hasDrafts else {
            error = "请先保存或撤销未提交的设置，再刷新。"
            return
        }
        guard ChatModel.shared.isStarted else {
            error = "请先启动 DSH 主机，再读取插件和设置。"
            pluginEntries = []
            settingsGroups = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await ChatModel.shared.transportForManagement()
            transport = client
            async let settingsCall = client.call("settings/describe", args: .object([:]))
            async let inventoryCall = client.call("pluginInventory/list", args: .object([:]))
            async let catalogCall = client.call("session/modelCatalog", args: .object([:]))
            async let permissionsCall = client.call("permissionPresets/catalog", args: .object([:]))

            do {
                let settings = try await settingsCall
                settingsWritable = settings["writable"]?.boolValue ?? false
                let namespaces = settings["namespaces"]?.arrayValue ?? []
                namespaceValues = Dictionary(uniqueKeysWithValues: namespaces.compactMap { descriptor in
                    guard let ns = descriptor["ns"]?.stringValue else { return nil }
                    return (ns, descriptor)
                })
                namespaceRevisions = Dictionary(uniqueKeysWithValues: namespaces.compactMap { descriptor in
                    guard let ns = descriptor["ns"]?.stringValue,
                          let revision = descriptor["revision"]?.intValue else { return nil }
                    return (ns, revision)
                })
                drafts = [:]
                settingsGroups = Self.buildSettingsGroups(namespaces: namespaces, writable: settingsWritable)
                settingsError = nil
                namespaceErrors = [:]
            } catch {
                settingsError = error.localizedDescription
                settingsGroups = []
                namespaceValues = [:]
                namespaceRevisions = [:]
            }

            do {
                let inventory = try await inventoryCall
                pluginEntries = (inventory["entries"]?.arrayValue ?? []).compactMap { entry in
                    guard let id = entry["entryId"]?.stringValue,
                          let module = entry["moduleName"]?.stringValue else { return nil }
                    return NativePluginEntry(id: id, module: module,
                                             enabled: entry["enabled"]?.boolValue ?? false,
                                             phase: entry["fiberPhase"]?.stringValue)
                }
                inventoryError = nil
            } catch {
                inventoryError = error.localizedDescription
                pluginEntries = []
            }

            do {
                let catalog = try await catalogCall
                let availableRoutes: [NativeModelRoute] = (catalog["groups"]?.arrayValue ?? []).flatMap { group -> [NativeModelRoute] in
                    (group["models"]?.arrayValue ?? []).compactMap { model -> NativeModelRoute? in
                        guard let provider = group["id"]?.stringValue,
                              let modelID = model["id"]?.stringValue else { return nil }
                        return NativeModelRoute(provider: provider,
                                                providerName: group["name"]?.stringValue ?? provider,
                                                model: modelID,
                                                modelName: model["name"]?.stringValue ?? modelID,
                                                available: true)
                    }
                }
                let availableIDs = Set<String>(availableRoutes.map { $0.id })
                let savedRows = namespaceValues["subagent-model-selection-settings"]?["value"]?["allowedModels"]?.arrayValue ?? []
                let unavailableRoutes = savedRows.compactMap { row -> NativeModelRoute? in
                    guard let provider = row["provider"]?.stringValue,
                          let model = row["model"]?.stringValue,
                          !availableIDs.contains("\(provider)/\(model)") else { return nil }
                    return NativeModelRoute(provider: provider, providerName: provider,
                                            model: model, modelName: model, available: false)
                }
                modelRoutes = availableRoutes + unavailableRoutes
                modelCatalogError = nil
            } catch {
                modelCatalogError = error.localizedDescription
                modelRoutes = []
            }

            do {
                let permissions = try await permissionsCall
                defaultPermissionModes = (permissions["defaultOptions"]?.arrayValue ?? []).compactMap { option in
                    guard let id = option["value"]?.stringValue,
                          let name = option["name"]?.stringValue else { return nil }
                    return NativePermissionMode(id: id, name: name, detail: option["description"]?.stringValue)
                }
                defaultPermissionMode = permissions["defaultPreset"]?.stringValue
                defaultPermissionDraft = nil
                permissionCatalogError = nil
            } catch {
                permissionCatalogError = error.localizedDescription
                defaultPermissionModes = []
                defaultPermissionMode = nil
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func fields(in namespace: String) -> [NativeSettingsField] {
        guard let descriptor = namespaceValues[namespace] else { return [] }
        let value = descriptor["value"] ?? .object([:])
        let base = descriptor["base"] ?? .object([:])
        let user = descriptor["user"] ?? .object([:])
        let properties = descriptor["schema"]?["properties"] ?? .object([:])
        return Self.fieldNames[namespace, default: []].compactMap { key in
            guard let current = value[key] else { return nil }
            let schema = properties[key] ?? .null
            let kind: NativeSettingsField.Kind
            switch schema["type"]?.stringValue {
            case "boolean": kind = .toggle
            case "number", "integer": kind = .number
            case "string": kind = .text
            default: kind = .readOnly
            }
            return NativeSettingsField(id: key,
                                       title: Self.fieldTitles[key] ?? key,
                                       detail: schema["description"]?.stringValue,
                                       kind: kind,
                                       value: drafts[namespace]?[key] ?? current,
                                       base: base[key], user: user[key])
        }
    }

    func isDirty(_ namespace: String) -> Bool { !(drafts[namespace]?.isEmpty ?? true) }

    func edit(_ field: NativeSettingsField, in namespace: String, text: String) {
        switch field.kind {
        case .number:
            guard let number = Double(text), number.isFinite else {
                drafts[namespace, default: [:]][field.id] = .string(text)
                return
            }
            drafts[namespace, default: [:]][field.id] = .number(number)
        case .text:
            drafts[namespace, default: [:]][field.id] = .string(text)
        default: break
        }
        rebuildGroups()
    }

    func toggle(_ field: NativeSettingsField, in namespace: String, value: Bool) {
        guard field.kind == .toggle else { return }
        drafts[namespace, default: [:]][field.id] = .bool(value)
        rebuildGroups()
    }

    func edit(_ field: NativeSettingsField, in namespace: String, value: Bool) {
        toggle(field, in: namespace, value: value)
    }

    func reset(_ field: NativeSettingsField, in namespace: String) async -> Bool {
        guard settingsWritable, let transport,
              let revision = namespaceRevisions[namespace], !isDirty(namespace) else { return false }
        do {
            let updated = try await transport.call("settings/mutate", args: .object([
                "ns": .string(namespace),
                "ops": .array([.object(["op": .string("unset"), "path": .array([.string(field.id)])])]),
                "expectedRevision": .number(Double(revision)),
            ]))
            applyNamespace(updated, as: namespace)
            rebuildGroups()
            notice = "已恢复 DSH 默认值"
            error = nil
            return true
        } catch let caught { self.error = caught.localizedDescription; return false }
    }

    func save(_ namespace: String) async -> Bool {
        guard settingsWritable, let patch = drafts[namespace], !patch.isEmpty,
              let transport, let revision = namespaceRevisions[namespace] else { return false }
        let numericFields = Set(fields(in: namespace).filter { $0.kind == .number }.map(\.id))
        guard !numericFields.contains(where: { key in
            if case .string? = patch[key] { return true }
            return false
        }) else {
            namespaceErrors[namespace] = "请修正无效的设置值后再保存。"
            return false
        }
        do {
            let updated = try await transport.call("settings/update", args: .object([
                "ns": .string(namespace), "patch": .object(patch),
                "expectedRevision": .number(Double(revision)),
            ]))
            applyNamespace(updated, as: namespace)
            drafts[namespace] = nil
            namespaceErrors[namespace] = nil
            rebuildGroups()
            notice = "DSH 设置已保存"
            error = nil
            return true
        } catch { namespaceErrors[namespace] = error.localizedDescription; return false }
    }

    func discard(_ namespace: String) { drafts[namespace] = nil; namespaceErrors[namespace] = nil; rebuildGroups() }

    func defaultPermissionDescription(_ id: String) -> String? {
        defaultPermissionModes.first(where: { $0.id == id })?.detail
    }

    func stageDefaultPermissionMode(_ id: String) {
        guard defaultPermissionModes.contains(where: { $0.id == id }) else { return }
        defaultPermissionDraft = id == defaultPermissionMode ? nil : id
    }

    func discardDefaultPermissionMode() { defaultPermissionDraft = nil }

    func setDefaultPermissionMode(_ id: String) async -> Bool {
        guard let mode = defaultPermissionModes.first(where: { $0.id == id }),
              namespaceValues["permission"] != nil,
              let revision = namespaceRevisions["permission"],
              let transport, settingsWritable else {
            error = "DSH 未提供可写的未来会话权限默认值。"
            return false
        }
        guard defaultPermissionMode != mode.id else { return true }
        do {
            let updated = try await transport.call("settings/update", args: .object([
                "ns": .string("permission"),
                "patch": .object(["defaultPreset": .string(mode.id)]),
                "expectedRevision": .number(Double(revision)),
            ]))
            applyNamespace(updated, as: "permission")
            defaultPermissionMode = id
            notice = "新会话默认权限已更新"
            error = nil
            return true
        } catch let caught { self.error = caught.localizedDescription; return false }
    }

    func saveDefaultPermissionMode() async -> Bool {
        guard let draft = defaultPermissionDraft else { return true }
        let saved = await setDefaultPermissionMode(draft)
        if saved {
            defaultPermissionMode = draft
            defaultPermissionDraft = nil
        }
        return saved
    }

    func activeSubagentModels() -> Set<String> {
        let routes = draftValue("subagent-model-selection-settings", "allowedModels")
            ?? namespaceValues["subagent-model-selection-settings"]?["value"]?["allowedModels"]
        return Set((routes?.arrayValue ?? []).compactMap { row in
            guard let provider = row["provider"]?.stringValue,
                  let model = row["model"]?.stringValue else { return nil }
            return "\(provider)/\(model)"
        })
    }

    func subagentModelsEnabled() -> Bool {
        let value = draftValue("subagent-model-selection-settings", "enabled")
            ?? namespaceValues["subagent-model-selection-settings"]?["value"]?["enabled"]
        return value?.boolValue ?? false
    }

    func toggleSubagentModel(_ route: NativeModelRoute) {
        let namespace = "subagent-model-selection-settings"
        var routes = activeSubagentModels()
        if routes.contains(route.id) { routes.remove(route.id) } else { routes.insert(route.id) }
        let values = routes.sorted().compactMap { value -> JSONValue? in
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return .object(["provider": .string(parts[0]), "model": .string(parts[1])])
        }
        drafts[namespace, default: [:]]["allowedModels"] = .array(values)
        rebuildGroups()
    }

    func setSubagentModelsEnabled(_ enabled: Bool) {
        drafts["subagent-model-selection-settings", default: [:]]["enabled"] = .bool(enabled)
        rebuildGroups()
    }

    func setSubagentModel(_ route: NativeModelRoute, enabled: Bool) {
        let namespace = "subagent-model-selection-settings"
        var routes = activeSubagentModels()
        if enabled { routes.insert(route.id) } else { routes.remove(route.id) }
        let values = routes.sorted().compactMap { value -> JSONValue? in
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return .object(["provider": .string(parts[0]), "model": .string(parts[1])])
        }
        drafts[namespace, default: [:]]["allowedModels"] = .array(values)
        rebuildGroups()
    }

    private func draftValue(_ namespace: String, _ key: String) -> JSONValue? { drafts[namespace]?[key] }

    private func applyNamespace(_ descriptor: JSONValue, as namespace: String) {
        namespaceValues[namespace] = descriptor
        if let revision = descriptor["revision"]?.intValue { namespaceRevisions[namespace] = revision }
    }

    private static let fieldNames: [String: [String]] = [
        "subagent": ["maxDepth", "maxActiveSubagents"],
        "subagent-model-selection-settings": ["enabled", "allowedModels"],
        "agent-loop": ["maxParallelToolCalls"],
        "bash-sandbox": ["timeoutMs", "maxOutputBytes"],
    ]

    private static let fieldTitles: [String: String] = [
        "maxDepth": "最大递归层级", "maxActiveSubagents": "最大并发子 Agent",
        "enabled": "允许子 Agent 选择模型", "allowedModels": "允许的子 Agent 模型",
        "maxParallelToolCalls": "并行工具调用上限", "timeoutMs": "单条命令时限（毫秒）",
        "maxOutputBytes": "每路输出上限（字节）",
    ]

    private func rebuildGroups() {
        guard !namespaceValues.isEmpty else { return }
        settingsGroups = Self.groupOrder.compactMap { namespace, title, detail in
            guard let revision = namespaceRevisions[namespace] else { return nil }
            let fields = fields(in: namespace)
            guard !fields.isEmpty else { return nil }
            return NativeSettingsGroup(namespace: namespace, title: title, detail: detail,
                                       revision: revision, writable: settingsWritable,
                                       fields: fields)
        }
    }

    private static let groupOrder: [(String, String, String)] = [
        ("subagent", "子 Agent", "控制 DSH 子 Agent 的递归深度和并发容量。"),
        ("subagent-model-selection-settings", "子 Agent 模型", "设置子 Agent 可使用的模型路由。"),
        ("agent-loop", "Agent 循环", "限制单步并行执行的安全工具调用数。"),
        ("bash-sandbox", "终端", "调整 DSH Bash 执行器的时限和输出预算。"),
    ]

    private static func buildSettingsGroups(namespaces: [JSONValue], writable: Bool) -> [NativeSettingsGroup] {
        var byName: [String: JSONValue] = [:]
        for value in namespaces {
            if let ns = value["ns"]?.stringValue { byName[ns] = value }
        }
        return groupOrder.compactMap { ns, title, detail in
            guard let descriptor = byName[ns], let revision = descriptor["revision"]?.intValue else { return nil }
            let values = descriptor["value"] ?? .object([:])
            let base = descriptor["base"] ?? .object([:])
            let user = descriptor["user"] ?? .object([:])
            let properties = descriptor["schema"]?["properties"] ?? .object([:])
            let fields = fieldNames[ns, default: []].compactMap { key -> NativeSettingsField? in
                guard let current = values[key] else { return nil }
                let schema = properties[key] ?? .null
                let kind: NativeSettingsField.Kind
                switch schema["type"]?.stringValue {
                case "boolean": kind = .toggle
                case "number", "integer": kind = .number
                case "string": kind = .text
                default: kind = .readOnly
                }
                return NativeSettingsField(id: key, title: fieldTitles[key] ?? key,
                                           detail: schema["description"]?.stringValue,
                                           kind: kind, value: current, base: base[key], user: user[key])
            }
            guard !fields.isEmpty else { return nil }
            return NativeSettingsGroup(namespace: ns, title: title, detail: detail,
                                       revision: revision, writable: writable, fields: fields)
        }
    }
}
