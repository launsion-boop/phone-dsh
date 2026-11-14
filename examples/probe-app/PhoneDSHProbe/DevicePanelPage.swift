// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — device panel (device-panel.md §2–§4).
//
// A native panel for one connected device that negotiated PDSH Link Tools v1.
// Two hard rules are enforced here, not only in the copy:
//
// * Nothing is called unless the user taps. Opening the page, refreshing it and
//   reading the adopted descriptor are local reads; they never invoke a tool,
//   not even a tool that looks read-only (`light.get`).
// * Editors are parameter inputs, not device state. They start unset; an
//   accepted call is shown as that call's result, never as the device's
//   current value.
//
// Every device- and descriptor-provided string is rendered with
// `Text(verbatim:)` and a line limit. No LocalizedStringKey, Markdown,
// AttributedString or link detection is applied to it.
//
// Test seam: `DevicePanelSource` is injected. The live source uses
// `BLEDeviceStore` / `callLinkTool` / `queryLinkTool` / `DevicePanelStore`;
// `FakeDevicePanelSource` scripts tools, descriptor bytes and outcomes so the
// simulator suite never touches Bluetooth or Application Support.

import Foundation
import Observation
import SwiftUI
import PhoneDSHAgentCore
import PhoneDSHBLE

// MARK: - Values shared with the view and the fake

/// One advertised ordinary Link tool. `raw` keeps the exact `tools/list`
/// entry so the live source can hand the device's own JSON to the frozen
/// descriptor evaluator (WP1) without re-serializing it.
struct DevicePanelTool: Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let inputSchema: JSONValue
    let render: DevicePanelRender
    let raw: JSONValue
    /// Display names from the schema's `title`s (device-panel.md §2); requests use the argument names.
    let titles: [String: String]

    var id: String { name }

    init(name: String, description: String? = nil, inputSchema: JSONValue = .object([:]),
         render: DevicePanelRender, raw: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.render = render
        self.titles = devicePanelEditorTitles(inputSchema: inputSchema)
        if let raw {
            self.raw = raw
        } else {
            var fields: [String: JSONValue] = ["name": .string(name), "inputSchema": inputSchema]
            if let description { fields["description"] = .string(description) }
            self.raw = .object(fields)
        }
    }

    /// Parses one `tools/list` entry and classifies it with the real §2
    /// classifier. Only the live source uses this; the fake supplies renders.
    init?(advertised raw: JSONValue) {
        guard case .object(let fields) = raw,
              case .string(let name) = fields["name"], !name.isEmpty else { return nil }
        let description = fields["description"]?.stringValue
        let schema = fields["inputSchema"] ?? .object([:])
        self.init(name: name, description: description, inputSchema: schema,
                  render: classifyDevicePanelTool(inputSchema: schema), raw: raw)
    }
}

/// The result of evaluating descriptor bytes. `descriptor` is only non-nil for
/// `.ok` (device-panel.md §4.2).
struct DevicePanelDescriptorReview: Equatable, Sendable {
    let result: DevicePanelDescriptorResult
    let descriptor: DevicePanelDescriptor?

    var isOK: Bool { result == .ok && descriptor != nil }
}

struct DevicePanelEditorKey: Hashable, Sendable {
    let tool: String
    let argument: String
}

/// A local parameter value. It exists only inside this panel session and is
/// not evidence of what the device currently is.
enum DevicePanelEditorValue: Equatable, Sendable {
    case toggle(Bool)
    case slider(Double)
    case picker(String)

    var jsonValue: JSONValue {
        switch self {
        case .toggle(let value): return .bool(value)
        case .slider(let value): return .number(value)
        case .picker(let value): return .string(value)
        }
    }
}

struct DevicePanelResultRecord: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case completed(text: String)
        case running
        case notExecuted(stage: String, status: String)
        case outcomeUnknown(message: String)
    }

    let requestID: UUID
    let state: State
    let at: Date
    /// What the device answered, as plain text rows. Only for `.completed`.
    var summary: DevicePanelResultSummary? = nil

    /// Only an unfinished/unclear request may be queried. A completed call and
    /// a `not_executed` refusal are terminal; the latter is re-sent by a new
    /// call, never queried (device-panel.md §3).
    var canQuery: Bool {
        switch state {
        case .running, .outcomeUnknown: return true
        case .completed, .notExecuted: return false
        }
    }

    /// device-panel.md §3: after `outcome_unknown` or while the device is still
    /// running, the only offered action is a query. `not_executed` explicitly
    /// allows a new call, and a completed/timed-out result may be re-sent.
    var permitsNewCall: Bool {
        switch state {
        case .running, .outcomeUnknown: return false
        case .completed, .notExecuted: return true
        }
    }
}

/// A device reply reduced to what a person reads first: did the device say it
/// worked, and the scalar members of its `result`. Everything is plain text
/// produced from untrusted JSON; nothing here is interpreted as device state
/// beyond "this is what that one call returned" (device-panel.md §2).
struct DevicePanelResultSummary: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let name: String
        let value: String
    }

    /// The device's own `status` was `completed`.
    let succeeded: Bool
    /// The device's error text when it reported a failure, if it gave one.
    let failure: String?
    let rows: [Row]

    static let maxRows = 8

    init(reply: JSONValue) {
        let status = reply["status"]?.stringValue
        succeeded = status == "completed"
        if succeeded {
            failure = nil
        } else if let text = reply["error"]?.stringValue {
            failure = text
        } else if let text = reply["error"]?["message"]?.stringValue ?? reply["error"]?["code"]?.stringValue {
            failure = text
        } else {
            failure = status
        }
        var rows: [Row] = []
        if case .object(let result)? = reply["result"] {
            for name in result.keys.sorted() {
                guard rows.count < Self.maxRows, let text = Self.scalarText(result[name]) else { continue }
                rows.append(Row(name: name, value: text))
            }
        }
        self.rows = rows
    }

    private static func scalarText(_ value: JSONValue?) -> String? {
        switch value {
        case .bool(let flag)?: return flag ? "是" : "否"
        case .number(let number)?:
            if number.isFinite, number == number.rounded(), abs(number) <= 9_007_199_254_740_991 {
                return String(Int64(number))
            }
            return String(number)
        case .string(let text)?: return text
        default: return nil
        }
    }
}

struct DevicePanelFlash: Equatable, Sendable {
    let tool: String
    let preset: JSONValue?
    let succeeded: Bool
}

/// Descriptor controls bucketed by `group`, in first-seen order. `nil` is the
/// ungrouped bucket; it keeps its first-seen position too.
struct DevicePanelGroup: Identifiable, Equatable {
    let id: Int
    let title: String?
    var controls: [DevicePanelControl]
}

private extension DevicePanelEditor {
    var panelArgument: String {
        switch self {
        case .toggle(let arg, _): return arg
        case .slider(let arg, _, _, _, _): return arg
        case .picker(let arg, _, _): return arg
        }
    }

    var panelIsRequired: Bool {
        switch self {
        case .toggle(_, let required): return required
        case .slider(_, let required, _, _, _): return required
        case .picker(_, let required, _): return required
        }
    }
}

// MARK: - Injected source

/// Everything the panel needs from the host. The model never touches
/// `BLEDeviceStore` or the filesystem directly, which is what makes the
/// simulator tests exercise the real panel state machine without BLE, without
/// `callLinkTool` and without Application Support.
@MainActor
protocol DevicePanelSource: AnyObject {
    /// The Link device ID exactly as the device returned it. Never lowercased.
    var linkDeviceID: String { get }

    func loadTools() -> [DevicePanelTool]
    func loadGrantedTools() -> Set<String>

    /// `nil` means nothing was adopted. A non-`nil` non-`.ok` result means a
    /// copy exists but the current tools reject it (device-panel.md §4.1).
    func activeDescriptor(tools: [DevicePanelTool]) -> DevicePanelDescriptorReview?

    /// Pure local evaluation of workspace bytes. Never calls the device.
    func reviewDescriptor(_ bytes: Data, tools: [DevicePanelTool]) -> DevicePanelDescriptorReview

    func adoptDescriptor(_ bytes: Data, tools: [DevicePanelTool]) throws -> DevicePanelDescriptorResult
    func removeDescriptor() throws

    /// The only device-facing calls. The live source maps these to
    /// `callLinkTool(origin: .user)` / `queryLinkTool(origin: .user)`.
    func invoke(tool: String, arguments: JSONValue, idempotencyKey: String) async throws -> LinkCallOutcome
    func query(requestID: UUID) async throws -> LinkCallOutcome
}

// MARK: - Result records that outlive one page

/// The last panel result per tool for one peripheral. It lives for the app
/// process, not for one page instance: leaving the panel after `outcome_unknown`
/// (or while the device is still running) must not drop the request UUID,
/// because the only action allowed afterwards is a query (device-panel.md §3).
/// Memory only on purpose: persisting it would add a P18 surface. After an app
/// restart the request stays in the Link journal but the panel no longer
/// offers its query.
@MainActor
final class DevicePanelResultCache {
    private static var live: [UUID: DevicePanelResultCache] = [:]

    /// The process-wide cache for one peripheral.
    static func shared(for peripheralID: UUID) -> DevicePanelResultCache {
        if let cache = live[peripheralID] { return cache }
        let cache = DevicePanelResultCache()
        live[peripheralID] = cache
        return cache
    }

    var records: [String: DevicePanelResultRecord] = [:]
}

// MARK: - Panel model

/// UI-free state machine for one device panel. The view is a pure projection
/// of this object; the simulator tests drive the same object with a fake.
@MainActor
@Observable
final class DevicePanelModel {
    private let source: any DevicePanelSource
    private let results: DevicePanelResultCache

    private(set) var tools: [DevicePanelTool] = []
    private(set) var grantedTools: Set<String> = []
    /// Non-nil only while an adopted descriptor currently evaluates to `.ok`.
    private(set) var descriptor: DevicePanelDescriptor?
    /// Why an adopted descriptor is currently not in effect, if one exists.
    private(set) var adoptedDescriptorResult: DevicePanelDescriptorResult?
    /// True when a host-private copy exists, even if it is currently rejected.
    private(set) var hasAdoptedDescriptor = false
    /// Last result of a panel call per tool. Memory only; mirrored into
    /// `results` so a reopened panel still knows an unsettled request.
    private(set) var lastResults: [String: DevicePanelResultRecord]
    private(set) var inFlightTool: String?
    /// The preset being sent, so only the tapped button shows progress.
    private(set) var inFlightPreset: JSONValue?
    /// The control whose call just came back, for a short tick on that button.
    /// It acknowledges the call; it is not a claim about the device's state.
    private(set) var flash: DevicePanelFlash?
    private var flashGeneration = 0
    private(set) var queryingTool: String?
    private(set) var errorText: String?
    private var editorValues: [DevicePanelEditorKey: DevicePanelEditorValue] = [:]

    /// `results` nil means a private cache: the records then live only as long
    /// as this model (tests and the injected-model page).
    init(source: any DevicePanelSource, results: DevicePanelResultCache? = nil) {
        let cache = results ?? DevicePanelResultCache()
        self.source = source
        self.results = cache
        self.lastResults = cache.records
    }

    var linkDeviceID: String { source.linkDeviceID }

    /// False once the device dropped its Link: there is no Link device ID to
    /// address, so the panel says so instead of showing an empty tool list.
    var isConnected: Bool { !source.linkDeviceID.isEmpty }

    /// Tools that have a result to show, newest first.
    var toolsWithResults: [String] {
        lastResults.sorted { $0.value.at > $1.value.at }.map(\.key)
    }

    /// Busy counts a result query too: the panel never overlaps two Link
    /// operations on one device (device-panel.md §3 concurrency row).
    var isBusy: Bool { inFlightTool != nil || queryingTool != nil }

    /// Local reads only: advertised tools, grants, and the adopted descriptor.
    /// This is safe to call on open and on refresh; it never invokes a tool.
    func refresh() {
        let currentTools = source.loadTools()
        tools = currentTools
        grantedTools = source.loadGrantedTools()
        if let active = source.activeDescriptor(tools: currentTools) {
            hasAdoptedDescriptor = true
            if active.result == .ok, let activeDescriptor = active.descriptor {
                descriptor = activeDescriptor
                adoptedDescriptorResult = nil
            } else {
                // §4.1: re-evaluation is not ok, so the descriptor is not in
                // effect. Keep the copy (tools may come back) and fall back to
                // the §2 tool list with the reason.
                descriptor = nil
                adoptedDescriptorResult = active.result == .ok ? .schema : active.result
            }
        } else {
            descriptor = nil
            adoptedDescriptorResult = nil
            hasAdoptedDescriptor = false
        }
        pruneEditorValues()
    }

    func tool(named name: String) -> DevicePanelTool? {
        tools.first { $0.name == name }
    }

    func isAuthorized(_ toolName: String) -> Bool {
        grantedTools.contains(toolName)
    }

    /// Controls in descriptor array order, bucketed by group in first-seen
    /// order (device-panel.md §4).
    var controlGroups: [DevicePanelGroup] {
        guard let descriptor else { return [] }
        var groups: [DevicePanelGroup] = []
        for control in descriptor.controls {
            if let index = groups.firstIndex(where: { $0.title == control.group }) {
                groups[index].controls.append(control)
            } else {
                groups.append(DevicePanelGroup(id: groups.count, title: control.group, controls: [control]))
            }
        }
        return groups
    }

    // MARK: Editor state (parameter inputs, never device state)

    func editorValue(tool: String, argument: String) -> DevicePanelEditorValue? {
        editorValues[DevicePanelEditorKey(tool: tool, argument: argument)]
    }

    func setEditorValue(_ value: DevicePanelEditorValue, tool: String, argument: String) {
        editorValues[DevicePanelEditorKey(tool: tool, argument: argument)] = value
    }

    func clearEditorValue(tool: String, argument: String) {
        editorValues.removeValue(forKey: DevicePanelEditorKey(tool: tool, argument: argument))
    }

    /// The value a slider displays while its parameter is unset. The row still
    /// says "未设置" and the value is not sent until the user moves the slider.
    func sliderDisplayValue(tool: String, argument: String, min: Double, max: Double, integer: Bool) -> Double {
        if case .slider(let value)? = editorValue(tool: tool, argument: argument) { return value }
        return integer ? min : (min + max) / 2
    }

    func missingRequiredArguments(for toolName: String) -> [String] {
        guard let tool = tool(named: toolName), case .editors(let editors) = tool.render else { return [] }
        return editors.compactMap { editor in
            guard editor.panelIsRequired,
                  editorValue(tool: toolName, argument: editor.panelArgument) == nil else { return nil }
            return editor.panelArgument
        }
    }

    /// The exact `args` object a non-preset control would send. Optional unset
    /// parameters are omitted; a missing required parameter returns `nil`.
    func argumentObject(for toolName: String) -> [String: JSONValue]? {
        guard let tool = tool(named: toolName), case .editors(let editors) = tool.render else { return nil }
        var arguments: [String: JSONValue] = [:]
        for editor in editors {
            let argument = editor.panelArgument
            if let value = editorValue(tool: toolName, argument: argument) {
                arguments[argument] = value.jsonValue
            } else if editor.panelIsRequired {
                return nil
            }
        }
        return arguments
    }

    // MARK: Sending

    /// A preset is sent verbatim; a non-preset control sends only the editors
    /// that are set. Every tap generates a new idempotency key.
    func canSend(toolName: String, preset: JSONValue?) -> Bool {
        !isBusy && isSendable(toolName: toolName, preset: preset)
    }

    /// Everything that decides whether a control may be sent, except "another
    /// call is in flight". The view dims a control only for these lasting
    /// reasons; while one call runs the others just ignore taps, so one tap
    /// does not make every button flicker.
    func isSendable(toolName: String, preset: JSONValue?) -> Bool {
        guard isAuthorized(toolName) else { return false }
        // device-panel.md §3: outcome_unknown is query-only, and a still-running
        // request is not replayed. not_executed and completed may be re-sent.
        if let record = lastResults[toolName], !record.permitsNewCall { return false }
        if preset != nil { return true }
        return argumentObject(for: toolName) != nil
    }

    func send(toolName: String, preset: JSONValue?) async {
        guard !isBusy else { return }
        guard isAuthorized(toolName) else {
            errorText = "这个工具尚未授权，没有发送。请先到蓝牙设备页授权。"
            return
        }
        if let record = lastResults[toolName], !record.permitsNewCall {
            errorText = "这一次调用的结果还未确定：请先查询，不能重新发送。"
            return
        }
        let arguments: JSONValue
        if let preset {
            arguments = preset
        } else if let object = argumentObject(for: toolName) {
            arguments = .object(object)
        } else {
            errorText = "请先填好全部必填参数。"
            return
        }
        errorText = nil
        let idempotencyKey = UUID().uuidString.lowercased()
        inFlightTool = toolName
        inFlightPreset = preset
        do {
            let outcome = try await source.invoke(tool: toolName, arguments: arguments,
                                                  idempotencyKey: idempotencyKey)
            apply(outcome, tool: toolName)
            if case .completed? = lastResults[toolName]?.state {
                showFlash(DevicePanelFlash(tool: toolName, preset: preset,
                                           succeeded: lastResults[toolName]?.summary?.succeeded ?? true))
            }
        } catch is LinkBusy {
            // Admission rejected before any journal write: nothing was sent and
            // there is no request UUID to query. The user may send again.
            errorText = "设备正忙：本次没有发出，也没有记录。请等当前操作结束后重新发送。"
        } catch {
            errorText = "调用未完成：\(error.localizedDescription)"
        }
        inFlightTool = nil
        inFlightPreset = nil
    }

    private func showFlash(_ value: DevicePanelFlash) {
        flash = value
        flashGeneration += 1
        let generation = flashGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard let self, self.flashGeneration == generation else { return }
            self.flash = nil
        }
    }

    func canQuery(toolName: String) -> Bool {
        guard !isBusy, isAuthorized(toolName), let record = lastResults[toolName] else { return false }
        return record.canQuery
    }

    /// A result query through the same admission point. Never invokes the tool
    /// again: `outcome_unknown` is query-only (device-panel.md §3).
    func query(toolName: String) async {
        guard !isBusy, let record = lastResults[toolName], record.canQuery else { return }
        guard isAuthorized(toolName) else {
            errorText = "这个工具尚未授权，无法查询。"
            return
        }
        errorText = nil
        queryingTool = toolName
        do {
            let outcome = try await source.query(requestID: record.requestID)
            apply(outcome, tool: toolName)
        } catch is LinkBusy {
            errorText = "设备正忙：请等当前操作结束后再查询。"
        } catch {
            errorText = "查询未完成：\(error.localizedDescription)"
        }
        queryingTool = nil
    }

    private func apply(_ outcome: LinkCallOutcome, tool toolName: String) {
        let record: DevicePanelResultRecord
        switch outcome {
        case .completed(let requestID, let reply):
            record = DevicePanelResultRecord(requestID: requestID,
                                             state: .completed(text: DevicePanelJSONText.pretty(reply)),
                                             at: Date(),
                                             summary: DevicePanelResultSummary(reply: reply))
        case .running(let requestID):
            record = DevicePanelResultRecord(requestID: requestID, state: .running, at: Date())
        case .notExecuted(let requestID, let stage, let status):
            record = DevicePanelResultRecord(requestID: requestID,
                                             state: .notExecuted(stage: stage, status: status), at: Date())
        case .outcomeUnknown(let requestID, let message):
            record = DevicePanelResultRecord(requestID: requestID,
                                             state: .outcomeUnknown(message: message), at: Date())
        }
        lastResults[toolName] = record
        results.records[toolName] = record
    }

    // MARK: Descriptor adoption (local files only)

    func reviewDescriptor(_ bytes: Data) -> DevicePanelDescriptorReview {
        source.reviewDescriptor(bytes, tools: tools)
    }

    /// Evaluate-before-write lives in the store (device-panel.md §4.1); this
    /// wrapper re-reads the active copy afterwards so the panel reflects it
    /// immediately, including a rejection that leaves the old copy intact.
    @discardableResult
    func adoptDescriptor(_ bytes: Data) async -> DevicePanelDescriptorResult? {
        do {
            let result = try source.adoptDescriptor(bytes, tools: tools)
            refresh()
            return result
        } catch {
            errorText = "采用描述失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func removeDescriptor() async -> Bool {
        do {
            try source.removeDescriptor()
            refresh()
            return true
        } catch {
            errorText = "移除描述失败：\(error.localizedDescription)"
            return false
        }
    }

    private func pruneEditorValues() {
        var valid = Set<DevicePanelEditorKey>()
        for tool in tools {
            guard case .editors(let editors) = tool.render else { continue }
            for editor in editors {
                valid.insert(DevicePanelEditorKey(tool: tool.name, argument: editor.panelArgument))
            }
        }
        editorValues = editorValues.filter { valid.contains($0.key) }
    }
}

// MARK: - Scripted source for the simulator suite

/// Fake for `PhoneDSHSimTests`. It provides the advertised tools, registered
/// descriptor bytes/evaluations and queued call outcomes; it never imports
/// BLE, `DevicePanelStore` or Application Support and deliberately does not
/// call the real evaluator, so a test can script a deterministic result for
/// the exact bytes and tools it passes.
@MainActor
final class FakeDevicePanelSource: DevicePanelSource {
    struct Invocation: Equatable {
        let tool: String
        let arguments: JSONValue
        let idempotencyKey: String
    }

    struct AdoptionAttempt: Equatable {
        let bytes: Data
        let result: DevicePanelDescriptorResult
    }

    var linkDeviceID: String
    var tools: [DevicePanelTool]
    var grantedTools: Set<String>

    /// Queued invoke/query outcomes. When empty a generic completed reply is
    /// returned so a test that only cares about calls stays simple.
    var invokeOutcomes: [LinkCallOutcome] = []
    var queryOutcomes: [LinkCallOutcome] = []
    var invokeError: Error?
    var queryError: Error?

    private(set) var invocations: [Invocation] = []
    private(set) var queryCalls: [UUID] = []
    private(set) var adoptionAttempts: [AdoptionAttempt] = []
    private(set) var removalCount = 0
    private(set) var activeBytes: Data?

    private var evaluations: [Data: DevicePanelDescriptorReview] = [:]

    /// Optional scripted re-evaluation used by `activeDescriptor`. The
    /// refresh/observation test makes the fake's answer depend on the tools it
    /// receives, so a tools-table change deterministically flips an adopted
    /// descriptor back to a failure. The real evaluator is never called here.
    var activeDescriptorProvider: ((Data, [DevicePanelTool]) -> DevicePanelDescriptorReview?)?

    init(linkDeviceID: String = "fake-device-id", tools: [DevicePanelTool] = [],
         grantedTools: Set<String> = []) {
        self.linkDeviceID = linkDeviceID
        self.tools = tools
        self.grantedTools = grantedTools
    }

    func registerDescriptor(_ bytes: Data, result: DevicePanelDescriptorResult,
                            descriptor: DevicePanelDescriptor? = nil) {
        evaluations[bytes] = DevicePanelDescriptorReview(result: result, descriptor: descriptor)
    }

    func loadTools() -> [DevicePanelTool] { tools }

    func loadGrantedTools() -> Set<String> { grantedTools }

    func activeDescriptor(tools: [DevicePanelTool]) -> DevicePanelDescriptorReview? {
        guard let activeBytes else { return nil }
        if let activeDescriptorProvider { return activeDescriptorProvider(activeBytes, tools) }
        return evaluation(for: activeBytes)
    }

    func reviewDescriptor(_ bytes: Data, tools: [DevicePanelTool]) -> DevicePanelDescriptorReview {
        evaluation(for: bytes)
    }

    func adoptDescriptor(_ bytes: Data, tools: [DevicePanelTool]) throws -> DevicePanelDescriptorResult {
        let review = evaluation(for: bytes)
        let result: DevicePanelDescriptorResult
        if review.result == .ok && review.descriptor != nil {
            result = .ok
            activeBytes = bytes
        } else {
            result = review.result == .ok ? .schema : review.result
        }
        adoptionAttempts.append(AdoptionAttempt(bytes: bytes, result: result))
        return result
    }

    func removeDescriptor() throws {
        activeBytes = nil
        removalCount += 1
    }

    func invoke(tool: String, arguments: JSONValue, idempotencyKey: String) async throws -> LinkCallOutcome {
        invocations.append(Invocation(tool: tool, arguments: arguments, idempotencyKey: idempotencyKey))
        if let invokeError { throw invokeError }
        if !invokeOutcomes.isEmpty { return invokeOutcomes.removeFirst() }
        return .completed(requestID: UUID(),
                          reply: .object(["status": .string("completed"), "result": .object([:])]))
    }

    func query(requestID: UUID) async throws -> LinkCallOutcome {
        queryCalls.append(requestID)
        if let queryError { throw queryError }
        if !queryOutcomes.isEmpty { return queryOutcomes.removeFirst() }
        return .outcomeUnknown(requestID: requestID, message: "still unknown")
    }

    private func evaluation(for bytes: Data) -> DevicePanelDescriptorReview {
        evaluations[bytes] ?? DevicePanelDescriptorReview(result: .invalid_json, descriptor: nil)
    }
}

// MARK: - Live source

/// The only production binding. Everything device-facing goes through
/// `callLinkTool` / `queryLinkTool`; descriptor copies go through
/// `DevicePanelStore.shared`. No session write, model turn or host event is
/// reachable from here.
@MainActor
final class LiveDevicePanelSource: DevicePanelSource {
    private let deviceID: UUID
    private let store: BLEDeviceStore
    private let snapshot: BLEDeviceStore.Device

    init(device: BLEDeviceStore.Device, store: BLEDeviceStore? = nil) {
        self.deviceID = device.id
        self.store = store ?? .shared
        self.snapshot = device
    }

    /// The current device record, or the snapshot the panel was opened with if
    /// it disconnected meanwhile. Reading it is local; it never calls the
    /// device.
    private var device: BLEDeviceStore.Device {
        store.devices.first(where: { $0.id == deviceID }) ?? snapshot
    }

    /// Verbatim: `device-panel.md` §4 compares `device_id` as an exact string
    /// and WP2 populates this field from `tools/list` without lowercasing.
    var linkDeviceID: String { device.linkDeviceID }

    func loadTools() -> [DevicePanelTool] {
        let current = device
        var rawByName: [String: JSONValue] = [:]
        for raw in current.linkToolDescriptors {
            guard let name = raw["name"]?.stringValue else { continue }
            rawByName[name] = raw
        }
        // `linkTools` is the negotiated ordinary tool list in `tools/list`
        // order; descriptors supply the schema for the same names.
        return current.linkTools.compactMap { name in
            rawByName[name].flatMap(DevicePanelTool.init(advertised:))
        }
    }

    func loadGrantedTools() -> Set<String> { device.grantedTools }

    func activeDescriptor(tools: [DevicePanelTool]) -> DevicePanelDescriptorReview? {
        guard let active = DevicePanelStore.shared.active(
            linkDeviceID: linkDeviceID,
            tools: tools.map(\.raw)
        ) else { return nil }
        return DevicePanelDescriptorReview(result: active.0, descriptor: active.1)
    }

    func reviewDescriptor(_ bytes: Data, tools: [DevicePanelTool]) -> DevicePanelDescriptorReview {
        let result = evaluateDevicePanelDescriptor(bytes, linkDeviceID: linkDeviceID,
                                                   tools: tools.map(\.raw))
        return DevicePanelDescriptorReview(result: result.0, descriptor: result.1)
    }

    func adoptDescriptor(_ bytes: Data, tools: [DevicePanelTool]) throws -> DevicePanelDescriptorResult {
        try DevicePanelStore.shared.adopt(bytes, linkDeviceID: linkDeviceID, tools: tools.map(\.raw))
    }

    func removeDescriptor() throws {
        try DevicePanelStore.shared.remove(linkDeviceID: linkDeviceID)
    }

    func invoke(tool: String, arguments: JSONValue, idempotencyKey: String) async throws -> LinkCallOutcome {
        try await callLinkTool(deviceID: deviceID, name: tool, arguments: arguments,
                               idempotencyKey: idempotencyKey, origin: .user)
    }

    func query(requestID: UUID) async throws -> LinkCallOutcome {
        try await queryLinkTool(deviceID: deviceID, requestID: requestID, origin: .user)
    }
}

// MARK: - Plain-text rendering

/// Minimal deterministic JSON pretty-printer for untrusted JSON. The output is
/// shown as plain text only; it is never handed to a Markdown/attributed-text
/// renderer.
enum DevicePanelJSONText {
    static func pretty(_ value: JSONValue) -> String {
        render(value, indent: 0)
    }

    /// One line, sorted keys: the exact arguments a preset sends.
    static func compact(_ value: JSONValue) -> String {
        switch value {
        case .array(let items):
            return "[" + items.map(compact).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { quoted($0) + ":" + compact(fields[$0] ?? .null) }
                .joined(separator: ",") + "}"
        default:
            return render(value, indent: 0)
        }
    }

    private static func render(_ value: JSONValue, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.isFinite, value == value.rounded(), abs(value) <= 9_007_199_254_740_991 {
                return String(Int64(value))
            }
            return String(value)
        case .string(let value):
            return quoted(value)
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let childPad = pad + "  "
            let body = items.map { childPad + render($0, indent: indent + 1) }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            let childPad = pad + "  "
            let body = fields.keys.sorted().map { key in
                childPad + quoted(key) + ": " + render(fields[key] ?? .null, indent: indent + 1)
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }

    private static func quoted(_ string: String) -> String {
        guard let data = try? JSONValue.string(string).encoded(),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }
}

// MARK: - Page

@MainActor
struct DevicePanelPage: View {
    @State private var model: DevicePanelModel
    @State private var showingAdoption = false
    /// The observable device record this page follows. `nil` only on the
    /// injected-model initializer used by tests.
    private let store: BLEDeviceStore?
    private let peripheralID: UUID?
    private let deviceName: String?

    init(model: DevicePanelModel, deviceName: String? = nil) {
        self.store = nil
        self.peripheralID = nil
        self.deviceName = deviceName
        _model = State(initialValue: model)
    }

    init(device: BLEDeviceStore.Device, store: BLEDeviceStore? = nil) {
        let resolvedStore = store ?? .shared
        self.store = resolvedStore
        self.peripheralID = device.id
        self.deviceName = device.name
        _model = State(initialValue: DevicePanelModel(
            source: LiveDevicePanelSource(device: device, store: resolvedStore),
            results: .shared(for: device.id)))
    }

    var body: some View {
        // Read the observed record inside `body`: this registers the page as a
        // dependent of `BLEDeviceStore.devices`, so a new `tools/list` or grant
        // re-renders the page. The `onChange` hooks then re-read the adopted
        // descriptor and the current tool table through the live source. This
        // is local state only; no hook calls a device tool.
        let device = currentDevice
        observedStoreContent
            .onChange(of: device?.linkTools) { _, _ in model.refresh() }
            .onChange(of: device?.linkToolDescriptors) { _, _ in model.refresh() }
            .onChange(of: device?.grantedTools) { _, _ in model.refresh() }
            .onChange(of: device?.linkDeviceID) { _, _ in model.refresh() }
    }

    /// Current record for the peripheral this page was opened for. A missing
    /// record (disconnect/forget) yields nil instead of crashing; the live
    /// source then keeps serving the snapshot the panel was opened with.
    private var currentDevice: BLEDeviceStore.Device? {
        guard let store, let peripheralID else { return nil }
        return store.devices.first(where: { $0.id == peripheralID })
    }

    @ViewBuilder
    private var observedStoreContent: some View {
        #if PDSH_PROBE_HOSTLESS_TESTS
        // Test-only compilation: the app-only adoption sheet is ChatModel-bound
        // and this module does not compile ChatModel.swift. The panel model and
        // its fake are still the exact production types the UI uses.
        listContent
        #else
        listContent
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdoption = true
                    } label: {
                        Label("采用描述…", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("device-panel-adopt")
                }
            }
            .sheet(isPresented: $showingAdoption) {
                adoptionSheet
            }
        #endif
    }

    private var listContent: some View {
        List {
            if let reason = model.adoptedDescriptorResult {
                Section {
                    Text("已采用的描述当前不生效：\(Self.descriptorReason(reason))")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Text("面板已回到设备自报的工具列表。描述副本仍保留；工具表恢复后重新打开或刷新会重新求值。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("描述失效")
                }
            }

            if let error = model.errorText {
                Section("提示") {
                    Text(verbatim: error).font(.footnote).foregroundStyle(.red).lineLimit(4)
                }
            }

            if let descriptor = model.descriptor {
                descriptorContent(descriptor)
            } else {
                toolListContent
            }

            Section {
            } footer: {
                Text("只有你点按时才会调用设备。显示的是每次调用返回的结果，不是实时状态。")
            }
        }
        .homeGroupedList()
        .navigationTitle(Text(verbatim: model.descriptor?.title ?? deviceName ?? "设备面板"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { model.refresh() }
        .task { model.refresh() }
    }

    @ViewBuilder
    private func descriptorContent(_ descriptor: DevicePanelDescriptor) -> some View {
        ForEach(Array(model.controlGroups.enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(Array(DevicePanelRun.runs(group.controls).enumerated()), id: \.offset) { _, run in
                    switch run {
                    case .presets(let controls):
                        DevicePanelPresetGrid(model: model, controls: controls)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    case .editors(let control):
                        DevicePanelControlRow(model: model, control: control)
                    }
                }
            } header: {
                if let title = group.title {
                    Text(verbatim: title).lineLimit(1)
                }
            }
        }
        if descriptor.controls.isEmpty {
            Section {
                Text("描述没有控件。")
            }
        }
        let resultTools = model.toolsWithResults
        if !resultTools.isEmpty {
            Section("设备返回") {
                ForEach(resultTools, id: \.self) { toolName in
                    if let record = model.lastResults[toolName] {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: toolName)
                                .font(.footnote)
                                .foregroundStyle(HomeSpec.textSecondary)
                                .lineLimit(1)
                            DevicePanelResultView(model: model, toolName: toolName, record: record)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var toolListContent: some View {
        if model.tools.isEmpty {
            Section {
                Text(model.isConnected ? "设备没有自报可显示的工具。" : "设备已断开。回到蓝牙设备页重新连接后再打开面板。")
                    .foregroundStyle(.secondary)
                #if !PDSH_PROBE_HOSTLESS_TESTS
                Button("采用描述…") { showingAdoption = true }
                #endif
            }
        } else {
            ForEach(model.tools) { tool in
                Section {
                    DevicePanelToolRow(model: model, tool: tool)
                } header: {
                    Text(verbatim: tool.name).lineLimit(1)
                }
            }
        }
    }

    #if !PDSH_PROBE_HOSTLESS_TESTS
    private var adoptionSheet: some View {
        NavigationStack {
            DevicePanelAdoptionSheet(model: model)
                .navigationTitle("采用设备面板描述")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showingAdoption = false }
                    }
                }
        }
        .homeSheetChrome()
    }
    #endif

    /// The user-facing words for an evaluation result. These describe the
    /// host's local evaluation; no device text is involved.
    static func descriptorReason(_ result: DevicePanelDescriptorResult) -> String {
        switch result {
        case .ok: return "可用。"
        case .too_large: return "文件超过 16384 字节。"
        case .invalid_json: return "不是单个合法的 UTF-8 JSON 值，或嵌套超过 16 层。"
        case .duplicate_key: return "JSON 对象里有重复的成员名。"
        case .schema: return "不符合描述 v1 的格式（含缺少 v，或未知成员）。"
        case .unsupported_version: return "不支持的描述版本；当前只支持整数 v = 1。"
        case .device_mismatch: return "描述里的 device_id 与这台设备不符（逐字比较）。"
        case .tool_not_advertised: return "描述引用了设备当前没有自报的工具。"
        case .tool_not_supported: return "描述引用的工具参数形式不受支持。"
        case .preset_invalid: return "预设参数不满足该工具当前的参数 schema。"
        }
    }
}

// MARK: - Tool row (no descriptor)

@MainActor
private struct DevicePanelToolRow: View {
    let model: DevicePanelModel
    let tool: DevicePanelTool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tool.render {
            case .agentOnly:
                // device-panel.md §2: an agent_only tool shows only its name
                // (already the Section header) and this line. Its device
                // description is not rendered.
                Text("仅 Agent 可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .editors(let editors):
                if let description = tool.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                DevicePanelEditorFields(model: model, toolName: tool.name, editors: editors)
                DevicePanelSendButton(model: model, toolName: tool.name, preset: nil,
                                      title: editors.isEmpty ? "执行" : "发送",
                                      identifier: "device-panel-tool-send")
            }
            if let record = model.lastResults[tool.name] {
                DevicePanelResultView(model: model, toolName: tool.name, record: record)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Send button

/// The one way a panel control calls the device. The black capsule carries the
/// label itself (a descriptor preset's own words, or 发送／执行), so a preset is
/// one tap. The reason a button is disabled is always spelled out under it.
@MainActor
private struct DevicePanelSendButton: View {
    let model: DevicePanelModel
    let toolName: String
    let preset: JSONValue?
    let title: String
    let identifier: String

    private var inFlight: Bool {
        model.inFlightTool == toolName && model.inFlightPreset == preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await model.send(toolName: toolName, preset: preset) }
            } label: {
                if inFlight {
                    ProgressView().tint(HomeSpec.primaryButtonInk)
                } else {
                    Text(verbatim: title).lineLimit(1)
                }
            }
            .buttonStyle(HomePrimaryButtonStyle())
            .disabled(!model.isSendable(toolName: toolName, preset: preset))
            .allowsHitTesting(!model.isBusy)
            .accessibilityIdentifier(identifier)
            if let hint {
                Text(verbatim: hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String? {
        if !model.isAuthorized(toolName) {
            return "未授权：到蓝牙设备页允许这个工具后才能使用。"
        }
        if let record = model.lastResults[toolName], !record.permitsNewCall {
            return "上一次调用的结果还没确定，请先在结果里查询。"
        }
        if preset == nil, !model.missingRequiredArguments(for: toolName).isEmpty {
            return "先选好上面的参数。"
        }
        return nil
    }
}

// MARK: - Preset tiles

/// Descriptor controls in array order, with each run of consecutive preset
/// buttons kept together so it can be laid out as one grid.
enum DevicePanelRun {
    case presets([DevicePanelControl])
    case editors(DevicePanelControl)

    static func runs(_ controls: [DevicePanelControl]) -> [DevicePanelRun] {
        var runs: [DevicePanelRun] = []
        for control in controls {
            if control.preset == nil {
                runs.append(.editors(control))
            } else if case .presets(let current)? = runs.last {
                runs[runs.count - 1] = .presets(current + [control])
            } else {
                runs.append(.presets([control]))
            }
        }
        return runs
    }
}

/// One-tap preset buttons as a two-column grid of tiles. Only the tapped tile
/// reacts: it shows progress, then a short tick when the device answers.
@MainActor
private struct DevicePanelPresetGrid: View {
    let model: DevicePanelModel
    let controls: [DevicePanelControl]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: controls.count == 1 ? 1 : 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                    DevicePanelPresetTile(model: model, control: control)
                }
            }
            if let hint {
                Text(verbatim: hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var hint: String? {
        for control in controls {
            if !model.isAuthorized(control.tool) {
                return "有工具未授权：到蓝牙设备页允许后才能使用。"
            }
            if let record = model.lastResults[control.tool], !record.permitsNewCall {
                return "上一次调用的结果还没确定，请先在下面查询。"
            }
        }
        return nil
    }
}

@MainActor
private struct DevicePanelPresetTile: View {
    let model: DevicePanelModel
    let control: DevicePanelControl

    private var inFlight: Bool {
        model.inFlightTool == control.tool && model.inFlightPreset == control.preset
    }

    private var flash: DevicePanelFlash? {
        guard let flash = model.flash, flash.tool == control.tool, flash.preset == control.preset else { return nil }
        return flash
    }

    var body: some View {
        Button {
            Task { await model.send(toolName: control.tool, preset: control.preset) }
        } label: {
            HStack(spacing: 6) {
                if inFlight {
                    ProgressView()
                } else if let flash {
                    Image(systemName: flash.succeeded ? "checkmark" : "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(verbatim: control.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(DevicePanelTileStyle(highlighted: flash != nil))
        .disabled(!model.isSendable(toolName: control.tool, preset: control.preset))
        .allowsHitTesting(!model.isBusy)
        .sensoryFeedback(.impact(weight: .light), trigger: inFlight) { _, now in now }
        .sensoryFeedback(trigger: flash) { _, now in
            now.map { $0.succeeded ? .success : .error }
        }
        .accessibilityIdentifier("device-panel-preset-send")
        .accessibilityHint(Text(verbatim: "\(control.tool) \(control.preset.map(DevicePanelJSONText.compact) ?? "")"))
    }
}

/// A soft gray tile that turns solid for a moment when its call comes back.
struct DevicePanelTileStyle: ButtonStyle {
    var highlighted = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: HomeSpec.bodySize, weight: .semibold))
            .foregroundStyle(highlighted ? HomeSpec.primaryButtonInk : HomeSpec.textPrimary)
            .tint(highlighted ? HomeSpec.primaryButtonInk : HomeSpec.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(highlighted ? HomeSpec.primaryButton : HomeSpec.page,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(HomeSpec.borderList, lineWidth: highlighted ? 0 : 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: highlighted)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Descriptor control row

@MainActor
private struct DevicePanelControlRow: View {
    let model: DevicePanelModel
    let control: DevicePanelControl

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                Text(verbatim: control.label)
                    .font(.system(size: HomeSpec.bodySize, weight: .semibold))
                    .lineLimit(2)
                if let tool = model.tool(named: control.tool),
                   case .editors(let editors) = tool.render {
                    DevicePanelEditorFields(model: model, toolName: control.tool, editors: editors)
                    DevicePanelSendButton(model: model, toolName: control.tool, preset: nil,
                                          title: editors.isEmpty ? "执行" : "发送",
                                          identifier: "device-panel-control-send")
                    Text(verbatim: control.tool)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("这个工具当前不可用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Editors

@MainActor
private struct DevicePanelEditorFields: View {
    let model: DevicePanelModel
    let toolName: String
    let editors: [DevicePanelEditor]

    var body: some View {
        ForEach(Array(editors.enumerated()), id: \.offset) { _, editor in
            DevicePanelEditorRow(model: model, toolName: toolName, editor: editor)
        }
    }
}

@MainActor
private struct DevicePanelEditorRow: View {
    let model: DevicePanelModel
    let toolName: String
    let editor: DevicePanelEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch editor {
            case .toggle(let argument, _):
                toggleEditor(argument)
            case .slider(let argument, _, let integer, let min, let max):
                sliderEditor(argument, integer: integer, min: min, max: max)
            case .picker(let argument, _, let options):
                pickerEditor(argument, options: options)
            }
        }
    }

    /// The schema's `title` for this argument, else its name.
    private func label(_ argument: String) -> String {
        model.tool(named: toolName)?.titles[argument] ?? argument
    }

    private func toggleEditor(_ argument: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: label(argument)).lineLimit(1)
                Spacer()
                if model.editorValue(tool: toolName, argument: argument) == nil {
                    Text("未设置").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: toggleBinding(argument)) {
                Text("开").tag(Optional(true))
                Text("关").tag(Optional(false))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: label(argument)))
        }
    }

    private func sliderEditor(_ argument: String, integer: Bool, min: Double, max: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: label(argument)).lineLimit(1)
                Spacer()
                if let value = currentSliderValue(argument) {
                    Text(verbatim: Self.numberText(value, integer: integer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未设置").font(.caption).foregroundStyle(.secondary)
                }
            }
            Slider(value: sliderBinding(argument, min: min, max: max, integer: integer), in: min...max)
                .accessibilityLabel(Text(verbatim: label(argument)))
            Text(verbatim: "范围 \(Self.numberText(min, integer: integer))…\(Self.numberText(max, integer: integer))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func pickerEditor(_ argument: String, options: [String]) -> some View {
        Picker(selection: pickerBinding(argument)) {
            Text("未设置").tag(Optional<String>.none)
            ForEach(options, id: \.self) { option in
                Text(verbatim: option).lineLimit(1).tag(Optional(option))
            }
        } label: {
            HStack {
                Text(verbatim: label(argument)).lineLimit(1)
                Spacer()
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(Text(verbatim: label(argument)))
    }

    private func toggleBinding(_ argument: String) -> Binding<Bool?> {
        Binding(
            get: {
                if case .toggle(let value)? = model.editorValue(tool: toolName, argument: argument) {
                    return value
                }
                return nil
            },
            set: { newValue in
                if let newValue {
                    model.setEditorValue(.toggle(newValue), tool: toolName, argument: argument)
                } else {
                    model.clearEditorValue(tool: toolName, argument: argument)
                }
            }
        )
    }

    private func pickerBinding(_ argument: String) -> Binding<String?> {
        Binding(
            get: {
                if case .picker(let value)? = model.editorValue(tool: toolName, argument: argument) {
                    return value
                }
                return nil
            },
            set: { newValue in
                if let newValue {
                    model.setEditorValue(.picker(newValue), tool: toolName, argument: argument)
                } else {
                    model.clearEditorValue(tool: toolName, argument: argument)
                }
            }
        )
    }

    private func sliderBinding(_ argument: String, min: Double, max: Double, integer: Bool) -> Binding<Double> {
        Binding(
            get: {
                model.sliderDisplayValue(tool: toolName, argument: argument,
                                         min: min, max: max, integer: integer)
            },
            set: { newValue in
                let value = integer ? newValue.rounded() : newValue
                model.setEditorValue(.slider(value), tool: toolName, argument: argument)
            }
        )
    }

    private func currentSliderValue(_ argument: String) -> Double? {
        guard case .slider(let value)? = model.editorValue(tool: toolName, argument: argument) else {
            return nil
        }
        return value
    }

    static func numberText(_ value: Double, integer: Bool) -> String {
        if value.isFinite, value == value.rounded(), abs(value) <= 9_007_199_254_740_991 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - Results

@MainActor
private struct DevicePanelResultView: View {
    let model: DevicePanelModel
    let toolName: String
    let record: DevicePanelResultRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch record.state {
            case .completed(let text):
                let succeeded = record.summary?.succeeded ?? true
                HStack(spacing: 6) {
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(succeeded ? HomeSpec.success : Color.red)
                    Text(succeeded ? "设备已完成" : "设备报告失败")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text(verbatim: Self.timeText(record.at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let failure = record.summary?.failure {
                    Text(verbatim: failure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                ForEach(Array((record.summary?.rows ?? []).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: row.name)
                            .foregroundStyle(HomeSpec.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(verbatim: row.value)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.footnote)
                }
                DisclosureGroup("原始结果") {
                    Text(verbatim: text)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(24)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(HomeSpec.textSecondary)
            case .running:
                Text("设备仍在执行。只有查询能取得后续状态，不会自动重发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                queryButton
                Text(verbatim: Self.timeText(record.at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .notExecuted(_, let status):
                Text(verbatim: "未执行（\(status)）：设备在运行前拒绝了这次调用，可以重新发送。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(verbatim: Self.timeText(record.at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .outcomeUnknown(let message):
                Text("结果未知")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("结果未知时只能查询，不能重新发送。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                queryButton
                Text(verbatim: Self.timeText(record.at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private var queryButton: some View {
        Button {
            Task { await model.query(toolName: toolName) }
        } label: {
            if model.queryingTool == toolName {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("正在查询…")
                }
            } else {
                Text("查询结果")
            }
        }
        .font(.footnote)
        .disabled(!model.canQuery(toolName: toolName))
        .accessibilityIdentifier("device-panel-query")
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
