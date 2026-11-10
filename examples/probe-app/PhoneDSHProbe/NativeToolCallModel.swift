// SPDX-License-Identifier: MIT

import ProbeKit
import Foundation
import PhoneDSHAgentCore
import ProbeKit

struct NativeToolCallModel {
    enum Variant {
        case search, read, bash, write, edit, code, others
    }

    let item: ChatItem
    let name: String
    let variant: Variant
    let state: NativeToolState

    /// Derived once at construction. These used to be computed properties, so
    /// every body pass rebuilt the model and re-split the output for a summary.
    let argumentsObject: [String: JSONValue]?
    let input: String?
    let output: String?
    let filePath: String?
    let askContent: NativeAskQuestionCardContent?
    let summary: String
    /// `可能较重` when the App's local heuristic recognises a typical heavy
    /// invocation (S1-E). Read-only: it never blocks or estimates a size.
    let heavyOperationHint: String?

    init(item: ChatItem) {
        self.item = item
        let resolvedName = item.toolName ?? item.title.replacingOccurrences(of: "Tool call: ", with: "")
        name = resolvedName
        let variant: Variant
        switch resolvedName {
        case "grep", "glob", "web_search": variant = .search
        case "read", "read_image", "web_fetch", "cordis_package_inspect", "cordis_runtime_inspect": variant = .read
        case "bash", "pwsh": variant = .bash
        case "write": variant = .write
        case "edit", "str_replace_editor": variant = .edit
        case "run_code": variant = .code
        default: variant = .others
        }
        self.variant = variant
        let state: NativeToolState
        if let explicit = item.toolState { state = explicit }
        else if case .toolResult(let isError) = item.kind { state = isError ? .error : .ok }
        else { state = .running }
        self.state = state

        let argumentsObject = item.arguments?.objectValue
        let input = Self.makeInput(item: item, variant: variant, argumentsObject: argumentsObject)
        let output = Self.makeOutput(item: item)
        let filePath = Self.makeFilePath(item: item, variant: variant, argumentsObject: argumentsObject)
        let askContent = Self.makeAskContent(item: item, name: resolvedName, state: state,
                                             output: output, argumentsObject: argumentsObject)
        self.argumentsObject = argumentsObject
        self.input = input
        self.output = output
        self.filePath = filePath
        self.askContent = askContent
        self.heavyOperationHint = HeavyOperationHint.isHeavy(
            toolName: resolvedName,
            arguments: Self.flattenedArguments(argumentsObject))
            ? HeavyOperationHint.badge : nil
        summary = NativeRowSummaryCache.shared.toolSummary(for: item) {
            Self.makeSummary(item: item, name: resolvedName, variant: variant, state: state,
                             argumentsObject: argumentsObject, output: output,
                             filePath: filePath, askContent: askContent)
        }
    }

    var icon: NativeChatIcon.Name {
        switch variant {
        case .search: .search
        case .read: .read
        case .bash: .terminal
        case .write, .edit: .edit
        case .code: .code
        case .others: .sparkle
        }
    }

    var title: String {
        // Official `tool.call.toolview` title table: 54 keys + lsp operation
        // switch + aliases. Unknown tools fall back to 「工具调用」.
        NativeToolTitleTable.title(for: name,
                                    operation: item.arguments?["operation"]?.stringValue)
    }

    /// The official details-card model for the 37 `details-row` keys. The
    /// first pass maps scalar args + recorded meta through the shape's field
    /// vocabulary and lifts todo/job lists; richer per-shape cards can refine
    /// this without changing the row API.
    /// The six subagent/teammate tools have a dedicated official row. This maps
    /// the call/result into that row's data; unknown payloads still render the
    /// collapsed summary and general details.
    var subagentRowData: NativeSubagentToolRowData? {
        guard let kind = NativeSubagentToolKind(rawValue: name) else { return nil }
        let phase: NativeSubagentToolPhase
        switch state {
        case .preparing: phase = .preparing
        case .running: phase = .running
        case .ok: phase = .ok
        case .error: phase = .error
        case .stopped: phase = .stopped
        }
        let args = argumentsObject
        var data = NativeSubagentToolRowData(
            id: item.callID ?? item.id,
            kind: kind,
            phase: phase,
            summary: summary)
        data.target = args?["agentId"]?.stringValue
            ?? args?["agent_id"]?.stringValue
            ?? args?["id"]?.stringValue
            ?? args?["target"]?.stringValue
        data.message = args?["prompt"]?.stringValue
            ?? args?["message"]?.stringValue
            ?? args?["task"]?.stringValue
        data.result = output
        data.statusText = phase.label
        if phase == .error, let output {
            data.errorSummary = output.components(separatedBy: .newlines).first
        }
        return data
    }

    var detailsModel: NativeToolDetailsModel? {
        guard NativeToolTitleTable.usesDetailsCard(for: name) else { return nil }
        let shape = NativeToolDetailsShape(toolKey: name)

        var pairs: [(String, String)] = []
        if let args = argumentsObject {
            for key in args.keys.sorted() {
                if let value = Self.scalar(args[key]) { pairs.append((key, value)) }
            }
        }
        if let meta = item.toolMetadata?.objectValue {
            for key in meta.keys.sorted() {
                if let value = Self.scalar(meta[key]) { pairs.append((key, value)) }
            }
        }

        var items: [NativeToolDetailsItem] = []
        if let todos = argumentsObject?["todos"]?.arrayValue {
            items = todos.compactMap { row in
                guard let content = row["content"]?.stringValue else { return nil }
                let status: NativeToolDetailsItemStatus?
                switch row["status"]?.stringValue {
                case "completed": status = .completed
                case "in_progress": status = .inProgress
                case "pending": status = .pending
                default: status = nil
                }
                return NativeToolDetailsItem(title: content, status: status)
            }
        } else if let jobs = argumentsObject?["jobs"]?.arrayValue
                    ?? item.toolMetadata?["jobs"]?.arrayValue {
            items = jobs.compactMap { row in
                let id = row["id"]?.stringValue ?? row["jobId"]?.stringValue
                let name = row["name"]?.stringValue ?? row["command"]?.stringValue
                guard id != nil || name != nil else { return nil }
                return NativeToolDetailsItem(title: name ?? id, subtitle: id)
            }
        }

        let status: NativeToolDetailsStatus?
        switch state {
        case .ok: status = .ok
        case .error: status = .error
        case .stopped: status = .stopped
        case .running: status = .running
        case .preparing: status = .preparing
        }

        return .make(toolKey: name, title: title, status: status, items: items,
                     fields: shape.fields(pairs), summary: summary)
    }

    private static func flattenedArguments(_ object: [String: JSONValue]?) -> [String: String] {
        guard let object else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let string = value.stringValue {
                result[key] = string
            } else if let number = value.numberValue {
                result[key] = String(describing: number)
            } else if let data = try? value.encoded(), let text = String(data: data, encoding: .utf8) {
                result[key] = text
            }
        }
        return result
    }

    var hasDetails: Bool { input != nil || output != nil || filePath != nil }

    private static func makeInput(item: ChatItem, variant: Variant,
                                  argumentsObject: [String: JSONValue]?) -> String? {
        guard let raw = item.argumentsRaw, !raw.isEmpty else {
            return item.text.isEmpty ? nil : item.text
        }
        if variant == .code, let code = argumentsObject?["code"]?.stringValue, !code.isEmpty {
            return code
        }
        return nativePrettyJSON(item.arguments ?? .string(raw))
    }

    private static func makeOutput(item: ChatItem) -> String? {
        if let value = item.toolOutput, !value.isEmpty { return value }
        if case .toolResult = item.kind, !item.text.isEmpty { return item.text }
        return nil
    }

    private static func makeFilePath(item: ChatItem, variant: Variant,
                                     argumentsObject: [String: JSONValue]?) -> String? {
        guard [.read, .write, .edit].contains(variant) else { return nil }
        return item.toolMetadata?["path"]?.stringValue
            ?? argumentsObject?["file_path"]?.stringValue
            ?? argumentsObject?["path"]?.stringValue
    }

    /// Parsed ask_user_question result, or the pending/cancelled verdict. This
    /// keeps the official question/answer definition list out of the generic
    /// JSON card. Returns nil when the payload is unreadable, so the caller can
    /// fall back to the normal tool body.
    private static func makeAskContent(item: ChatItem, name: String, state: NativeToolState,
                                       output: String?,
                                       argumentsObject: [String: JSONValue]?) -> NativeAskQuestionCardContent? {
        guard name == "ask_user_question" else { return nil }
        let questions = askQuestions(argumentsObject: argumentsObject)
        guard !questions.isEmpty else { return nil }

        if let answers = askAnswers(output: output) {
            return .answered(questions.map { question in
                NativeAskQuestionAnsweredItem(
                    id: question.id,
                    question: question.question,
                    answers: answers[question.id] ?? [])
            })
        }

        let unanswered = questions.map {
            NativeAskQuestionUnansweredItem(id: $0.id, question: $0.question)
        }
        if state == .running || state == .preparing {
            return .unanswered(verdict: NativeAskQuestionVerdict.pending, questions: unanswered)
        }
        if state == .stopped || item.toolErrorCode == "ASK_ABORTED" {
            return .unanswered(verdict: NativeAskQuestionVerdict.interrupted, questions: unanswered)
        }
        if item.toolErrorCode == "ASK_CANCELLED" {
            return .unanswered(verdict: NativeAskQuestionVerdict.cancelled, questions: unanswered)
        }
        if state == .error {
            return .unanswered(verdict: NativeAskQuestionVerdict.closed, questions: unanswered)
        }
        return nil
    }

    private static func askQuestions(argumentsObject: [String: JSONValue]?) -> [(id: String, question: String)] {
        if let rows = argumentsObject?["questions"]?.arrayValue, !rows.isEmpty {
            return rows.enumerated().compactMap { index, row in
                let question = row["question"]?.stringValue
                    ?? row["prompt"]?.stringValue
                    ?? row["header"]?.stringValue
                guard let question, !question.isEmpty else { return nil }
                return (row["id"]?.stringValue ?? "q\(index)", question)
            }
        }
        if let question = argumentsObject?["question"]?.stringValue, !question.isEmpty {
            return [("answer", question)]
        }
        return []
    }

    private static func askAnswers(output: String?) -> [String: [String]]? {
        guard let output, !output.isEmpty else { return nil }
        var parsed: JSONValue?
        if let data = output.data(using: .utf8) {
            parsed = try? JSONValue.parse(data)
        }
        if parsed == nil,
           let start = output.firstIndex(of: "{"),
           let end = output.lastIndex(of: "}") {
            let slice = String(output[start...end])
            if let data = slice.data(using: .utf8) {
                parsed = try? JSONValue.parse(data)
            }
        }
        guard let value = parsed else { return nil }

        var result: [String: [String]] = [:]
        if let rows = value["answers"]?.arrayValue {
            for row in rows {
                guard let id = row["id"]?.stringValue else { continue }
                var values = row["selected"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if let single = row["selected"]?.stringValue { values = [single] }
                if let custom = row["custom"]?.stringValue, !custom.isEmpty {
                    values.append(custom)
                }
                result[id] = values
            }
        } else if let map = value["answers"]?.objectValue {
            for (id, answer) in map {
                result[id] = answer.arrayValue?.compactMap(\.stringValue)
                    ?? answer.stringValue.map { [$0] }
                    ?? []
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func makeSummary(item: ChatItem, name: String, variant: Variant,
                                    state: NativeToolState,
                                    argumentsObject: [String: JSONValue]?,
                                    output: String?, filePath: String?,
                                    askContent: NativeAskQuestionCardContent?) -> String {
        if let askContent {
            switch askContent {
            case .answered:
                return askContent.answeredSummary ?? "已回答"
            case .unanswered(let verdict, _):
                return verdict == NativeAskQuestionVerdict.pending ? "等待回答" : "未提交回答"
            }
        }
        if state == .error, let output, let line = output.components(separatedBy: .newlines).first, !line.isEmpty {
            return line
        }
        if state == .stopped { return "已停止" }
        if let filePath { return filePath }
        if let args = argumentsObject {
            let keys: [String]
            switch variant {
            case .bash: keys = ["description", "command"]
            case .read: keys = ["path", "file_path", "url"]
            case .search: keys = ["query", "pattern", "url", "queries"]
            case .write, .edit: keys = ["path", "file_path"]
            case .code: keys = ["description"]
            case .others: keys = []
            }
            for key in keys {
                if let value = args[key]?.stringValue,
                   let line = value.components(separatedBy: .newlines).first, !line.isEmpty {
                    return line
                }
                if key == "queries", let values = args[key]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty {
                    return values.joined(separator: ", ")
                }
            }
            if variant == .others, let first = args.values.compactMap(\.stringValue).first { return first }
            if variant == .others { return name }
        }
        return item.text.components(separatedBy: .newlines).first ?? ""
    }

    private static func scalar(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value.numberValue {
            return number == number.rounded() ? String(Int(number)) : String(number)
        }
        if let flag = value.boolValue { return flag ? "是" : "否" }
        return nil
    }
}
