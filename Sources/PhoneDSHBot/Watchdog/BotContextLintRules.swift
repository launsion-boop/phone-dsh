// SPDX-License-Identifier: MIT

import Foundation

extension BotContextLint {
    static func lintSystemPrompt(
        events: [BotContextLintEvent],
        promptMount: BotJSONValue?,
        thresholds: BotContextLintThresholds,
        sessionId: String?,
        findings: inout [BotContextLintFinding]
    ) {
        let warn = positive(thresholds.personaCharsWarn, fallback: BotContextLintThresholds.default.personaCharsWarn)
        let error = max(warn, positive(thresholds.personaCharsError, fallback: warn))
        if let mountChars = BotContextLintSupport.promptMountChars(promptMount) {
            guard mountChars >= warn else { return }
            findings.append(BotContextLintFinding(
                rule: .systemPromptBloat,
                severity: mountChars >= error ? .error : .warn,
                evidence: "persona is \(mountChars) chars (warn \(warn), error \(error)) from prompt-mount.json",
                location: [
                    "sessionId": BotContextLintSupport.nullableString(sessionId),
                    "source": .string("prompt-mount"),
                    "chars": BotContextLintSupport.number(mountChars),
                ]))
            return
        }
        var systemChars = 0
        var firstSeq: Int?
        var firstTurn: Int?
        for event in events where event.type == "system/message" {
            let text = BotContextLintSupport.systemText(event)
            guard !text.isEmpty else { continue }
            systemChars += BotContextLintSupport.jsLength(text)
            if firstSeq == nil {
                firstSeq = event.seq
                firstTurn = BotContextLintSupport.turn(of: event)
            }
        }
        guard systemChars >= warn else { return }
        findings.append(BotContextLintFinding(
            rule: .systemPromptBloat,
            severity: systemChars >= error ? .error : .warn,
            evidence: "rendered system prompt is \(systemChars) chars (warn \(warn), error \(error)) from system/message",
            location: [
                "sessionId": BotContextLintSupport.nullableString(sessionId),
                "source": .string("system/message"),
                "turn": BotContextLintSupport.nullableInt(firstTurn),
                "seq": BotContextLintSupport.nullableInt(firstSeq),
                "chars": BotContextLintSupport.number(systemChars),
            ]))
    }

    static func lintToolResults(
        events: [BotContextLintEvent],
        thresholds: BotContextLintThresholds,
        sessionId: String?,
        callsById: [String: BotContextLintCall],
        findings: inout [BotContextLintFinding]
    ) {
        let defaults = BotContextLintThresholds.default
        let warn = positive(thresholds.toolResultTokensWarn, fallback: defaults.toolResultTokensWarn)
        let error = max(warn, positive(thresholds.toolResultTokensError, fallback: warn))
        var currentTurn: Int?
        for event in events {
            if event.type == "turn/start" {
                if let turn = BotContextLintSupport.turn(of: event) { currentTurn = turn }
                continue
            }
            guard event.type == "tool/result" else { continue }
            let text = BotContextLintSupport.toolResultText(event)
            guard !text.isEmpty else { continue }
            let tokens = estimateTokens(text)
            guard tokens >= warn, !BotContextLintSupport.hasSpillNotice(text) else { continue }
            let callId = BotContextLintSupport.toolResultCallId(event)
            let call = callId.isEmpty ? nil : callsById[callId]
            let resultKind = BotContextLintSupport.toolResultIsError(event) ? "error result" : "ok result"
            findings.append(BotContextLintFinding(
                rule: .toolResultBloat,
                severity: tokens >= error ? .error : .warn,
                evidence: "\(tokens) estimated tokens, no spill notice (warn \(warn), error \(error), \(resultKind))",
                location: [
                    "sessionId": BotContextLintSupport.nullableString(sessionId),
                    "turn": BotContextLintSupport.nullableInt(BotContextLintSupport.turn(of: event) ?? currentTurn),
                    "step": BotContextLintSupport.nullableInt(BotContextLintSupport.step(of: event)),
                    "seq": BotContextLintSupport.nullableInt(event.seq),
                    "callId": callId.isEmpty ? .null : .string(callId),
                    "tool": BotContextLintSupport.nullableString(call?.name),
                    "tokens": BotContextLintSupport.number(tokens),
                ]))
        }
    }

    static func lintDuplicateContext(
        messages: [BotContextLintMessage],
        thresholds: BotContextLintThresholds,
        sessionId: String?,
        seenSignatures: inout Set<String>,
        findings: inout [BotContextLintFinding]
    ) {
        let defaults = BotContextLintThresholds.default
        let minChars = max(1, positive(thresholds.repeatedTextChars, fallback: defaults.repeatedTextChars))
        let maxRuntime = max(1, positive(thresholds.maxRuntimeContextsPerTurn, fallback: defaults.maxRuntimeContextsPerTurn))
        let runtime = messages.filter { $0.sourceKind == "runtime-context" }
        var groups: [(turn: Int?, messages: [BotContextLintMessage])] = []
        var groupIndexes: [String: Int] = [:]
        for message in runtime {
            let key = message.turn.map(String.init) ?? "unknown"
            if let index = groupIndexes[key] {
                groups[index].messages.append(message)
            } else {
                groupIndexes[key] = groups.count
                groups.append((message.turn, [message]))
            }
        }
        for group in groups {
            if group.messages.count > maxRuntime {
                findings.append(BotContextLintFinding(
                    rule: .duplicateContext, severity: .warn,
                    evidence: "\(group.messages.count) runtime-context snapshots in one turn (max \(maxRuntime)); older snapshots accumulate",
                    location: [
                        "sessionId": BotContextLintSupport.nullableString(sessionId),
                        "turn": BotContextLintSupport.nullableInt(group.turn),
                        "seq": BotContextLintSupport.nullableInt(group.messages.last?.seq ?? nil),
                        "occurrences": BotContextLintSupport.number(group.messages.count),
                    ]))
            }
            var seen: [String: Int] = [:]
            for message in group.messages {
                let text = BotContextLintSupport.normalizeText(message.text)
                guard !text.isEmpty else { continue }
                if let firstSeq = seen[text] {
                    let signature = "duplicate-context\0runtime:\(text)"
                    if seenSignatures.insert(signature).inserted {
                        findings.append(BotContextLintFinding(
                            rule: .duplicateContext, severity: .warn,
                            evidence: "runtime-context snapshot repeated (\(BotContextLintSupport.jsLength(text)) chars, first seq \(firstSeq), again seq \(message.seq.map(String.init) ?? "null"))",
                            location: [
                                "sessionId": BotContextLintSupport.nullableString(sessionId),
                                "turn": BotContextLintSupport.nullableInt(group.turn),
                                "seq": BotContextLintSupport.nullableInt(message.seq),
                                "chars": BotContextLintSupport.number(BotContextLintSupport.jsLength(text)),
                            ]))
                    }
                } else {
                    seen[text] = message.seq ?? -1
                }
            }
            for earlierIndex in group.messages.indices {
                let earlier = BotContextLintSupport.normalizeText(group.messages[earlierIndex].text)
                guard !earlier.isEmpty else { continue }
                for laterIndex in (earlierIndex + 1)..<group.messages.count {
                    let later = BotContextLintSupport.normalizeText(group.messages[laterIndex].text)
                    guard BotContextLintSupport.jsLength(later) - BotContextLintSupport.jsLength(earlier) >= 200,
                          later.range(of: earlier, options: .literal) != nil else { continue }
                    let signature = "duplicate-context\0accumulated:\(earlier):\(BotContextLintSupport.jsLength(later))"
                    guard seenSignatures.insert(signature).inserted else { continue }
                    findings.append(BotContextLintFinding(
                        rule: .duplicateContext, severity: .warn,
                        evidence: "runtime-context snapshot seq \(group.messages[laterIndex].seq.map(String.init) ?? "null") embeds the earlier snapshot seq \(group.messages[earlierIndex].seq.map(String.init) ?? "null") (\(BotContextLintSupport.jsLength(earlier))→\(BotContextLintSupport.jsLength(later)) chars)",
                        location: [
                            "sessionId": BotContextLintSupport.nullableString(sessionId),
                            "turn": BotContextLintSupport.nullableInt(group.turn),
                            "seq": BotContextLintSupport.nullableInt(group.messages[laterIndex].seq),
                            "earlierSeq": BotContextLintSupport.nullableInt(group.messages[earlierIndex].seq),
                            "chars": BotContextLintSupport.number(BotContextLintSupport.jsLength(later)),
                        ]))
                    break
                }
            }
        }

        var byText: [String: [BotContextLintMessage]] = [:]
        var textOrder: [String] = []
        for message in messages where message.sourceKind != "runtime-context" {
            let text = BotContextLintSupport.normalizeText(message.text)
            guard BotContextLintSupport.jsLength(text) >= minChars else { continue }
            if byText[text] == nil { textOrder.append(text) }
            byText[text, default: []].append(message)
        }
        var reported = 0
        let limit = max(1, positive(thresholds.repeatedTextMaxFindings, fallback: defaults.repeatedTextMaxFindings))
        for text in textOrder {
            guard let occurrences = byText[text], occurrences.count >= 2, reported < limit else { continue }
            let signature = "duplicate-context\0repeat:\(text)"
            guard seenSignatures.insert(signature).inserted else { continue }
            reported += 1
            let sequences = occurrences.map { $0.seq.map(String.init) ?? "null" }.joined(separator: ", ")
            findings.append(BotContextLintFinding(
                rule: .duplicateContext, severity: .warn,
                evidence: "the same \(BotContextLintSupport.jsLength(text))-char block appears in \(occurrences.count) messages (seq \(sequences))",
                location: [
                    "sessionId": BotContextLintSupport.nullableString(sessionId),
                    "turn": BotContextLintSupport.nullableInt(occurrences[1].turn),
                    "seq": BotContextLintSupport.nullableInt(occurrences[1].seq),
                    "firstSeq": BotContextLintSupport.nullableInt(occurrences[0].seq),
                    "occurrences": BotContextLintSupport.number(occurrences.count),
                    "chars": BotContextLintSupport.number(BotContextLintSupport.jsLength(text)),
                ]))
        }
    }

    static func lintOrphans(
        callsById: [String: BotContextLintCall],
        resultsById: [String: BotContextLintResult],
        sessionId: String?,
        findings: inout [BotContextLintFinding]
    ) {
        let results = resultsById.sorted {
            ($0.value.seq ?? -1, $0.key) < ($1.value.seq ?? -1, $1.key)
        }.map(\.value)
        for result in results {
            if let callId = result.callId, callsById[callId] != nil { continue }
            findings.append(BotContextLintFinding(
                rule: .orphanToolResult, severity: .error,
                evidence: result.callId.map { "tool result callId \($0) has no matching tool/call" }
                    ?? "tool result has no callId",
                location: [
                    "sessionId": BotContextLintSupport.nullableString(sessionId),
                    "turn": BotContextLintSupport.nullableInt(result.turn),
                    "step": BotContextLintSupport.nullableInt(result.step),
                    "seq": BotContextLintSupport.nullableInt(result.seq),
                    "callId": BotContextLintSupport.nullableString(result.callId),
                ]))
        }
        let calls = callsById.sorted {
            ($0.value.seq ?? -1, $0.key) < ($1.value.seq ?? -1, $1.key)
        }.map(\.value)
        for call in calls {
            if resultsById[call.callId] != nil { continue }
            if results.contains(where: { $0.callId == call.callId }) { continue }
            findings.append(BotContextLintFinding(
                rule: .orphanToolCall, severity: .error,
                evidence: "tool/call \(call.callId)\(call.name.isEmpty ? "" : " (\(call.name))") has no matching tool/result",
                location: [
                    "sessionId": BotContextLintSupport.nullableString(sessionId),
                    "turn": BotContextLintSupport.nullableInt(call.turn),
                    "step": BotContextLintSupport.nullableInt(call.step),
                    "seq": BotContextLintSupport.nullableInt(call.seq),
                    "callId": .string(call.callId),
                    "tool": call.name.isEmpty ? .null : .string(call.name),
                ]))
        }
    }

    static func lintToolDefinitions(
        events: [BotContextLintEvent],
        tools: BotJSONValue?,
        thresholds: BotContextLintThresholds,
        sessionId: String?,
        findings: inout [BotContextLintFinding]
    ) {
        guard let list = BotContextLintSupport.tools(tools, events: events), !list.isEmpty else { return }
        let defaults = BotContextLintThresholds.default
        let warn = positive(thresholds.toolDefTokensWarn, fallback: defaults.toolDefTokensWarn)
        let error = max(warn, positive(thresholds.toolDefTokensError, fallback: warn))
        let countWarn = max(1, positive(thresholds.toolCountWarn, fallback: defaults.toolCountWarn))
        var tokens = 0
        var chars = 0
        for tool in list {
            let json = BotContextLintSupport.jsonString(tool)
            chars += BotContextLintSupport.jsLength(json)
            tokens += estimateTokens(json)
        }
        guard list.count >= countWarn || tokens >= warn else { return }
        let explicitTools = BotContextLintSupport.array(tools) != nil
            || BotContextLintSupport.array(BotContextLintSupport.object(tools)["tools"]) != nil
        findings.append(BotContextLintFinding(
            rule: .toolDefBloat,
            severity: tokens >= error ? .error : .warn,
            evidence: "\(list.count) tool definitions, ~\(tokens) tokens / \(chars) chars (token warn \(warn), error \(error); count warn \(countWarn))",
            location: [
                "sessionId": BotContextLintSupport.nullableString(sessionId),
                "source": .string(explicitTools ? "tools/list" : "request/header"),
                "count": BotContextLintSupport.number(list.count),
                "tokens": BotContextLintSupport.number(tokens),
                "chars": BotContextLintSupport.number(chars),
            ]))
    }
}
