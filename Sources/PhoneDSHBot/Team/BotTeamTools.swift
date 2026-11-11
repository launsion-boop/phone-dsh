// SPDX-License-Identifier: MIT

import Foundation

/// The two team tools exposed through the Bot MCP surface.
///
/// The implementation only depends on `BotTeamHost`; the App composition in
/// `bm-app` supplies the roster, per-Bot turn delivery, held inbox and row
/// persistence.
public actor BotTeamTools: BotTeamToolHandling, BotTeamToolCatalogProviding,
    BotTurnAuthorizedTeamToolHandling {
    public static let sendToAgentName = "SendToAgent"
    public static let createTeammateName = "CreateTeammate"
    public static let maximumHops = 2
    public static let defaultTimeoutMilliseconds = 300_000
    public static let heldTextLimit = 1_200

    public let host: any BotTeamHost
    public let timeoutMilliseconds: Int

    private let now: @Sendable () -> Int64
    private var sequence: UInt64 = 0

    public init(host: any BotTeamHost,
                timeoutMilliseconds: Int = BotTeamTools.defaultTimeoutMilliseconds,
                now: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1_000)
                }) {
        self.host = host
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
        self.now = now
    }

    public nonisolated func handles(_ toolName: String) -> Bool {
        toolName == Self.sendToAgentName || toolName == Self.createTeammateName
    }

    /// Roster-aware catalog for one identified caller. The runtime installs
    /// this automatically in `registerTeamTools`, so the App composition does
    /// not need to wire a separate catalog provider.
    public func toolDefinitions(callerBotID: String?) async -> [BotMCPToolDefinition]? {
        guard let roster = try? await host.roster() else { return nil }
        return BotToolCatalog.allDefinitions(roster: roster, callerBotID: callerBotID)
    }

    public func execute(name: String, arguments: BotJSONValue,
                        principal: BotGatewayPrincipal,
                        context: BotMCPRequestContext) async -> BotMCPCallResult {
        switch name {
        case Self.sendToAgentName:
            return await sendToAgent(arguments, principal: principal, context: context)
        case Self.createTeammateName:
            return await createTeammate(arguments, principal: principal, authority: nil)
        default:
            return .failure("unknown_tool", "Unknown tool: \(name)")
        }
    }

    /// Runtime path: `CreateTeammate` sees the frozen turn authority so a
    /// non-user creation can require and record the approval card.
    public func execute(name: String, arguments: BotJSONValue,
                        principal: BotGatewayPrincipal,
                        context: BotMCPRequestContext,
                        authority: BotTurnAuthority) async -> BotMCPCallResult {
        switch name {
        case Self.createTeammateName:
            return await createTeammate(arguments, principal: principal, authority: authority)
        default:
            return await execute(name: name, arguments: arguments,
                                 principal: principal, context: context)
        }
    }

    // MARK: - SendToAgent

    private func sendToAgent(_ arguments: BotJSONValue,
                             principal: BotGatewayPrincipal,
                             context: BotMCPRequestContext) async -> BotMCPCallResult {
        guard case .object(let args) = arguments else {
            return .failure("invalid_arguments", "SendToAgent arguments must be an object")
        }
        let delivery: String
        switch resolveDelivery(args) {
        case .success(let value): delivery = value
        case .failure(let message): return .failure("invalid_arguments", message)
        }
        let targetReference = firstString(args, ["agent_id", "target_id", "bot_name", "agentId"])
        guard let targetReference, !targetReference.isEmpty else {
            return .failure("invalid_arguments", "SendToAgent requires agent_id.")
        }
        guard let message = firstString(args, ["message", "text"]), !message.isEmpty else {
            return .failure("invalid_arguments", "SendToAgent requires a non-empty message.")
        }

        let roster: BotRoster
        do { roster = try await host.roster() }
        catch { return .failure("execution_failed", String(describing: error)) }
        let senderProfile = roster.bots.first { $0.id == principal.botId }
        let sender = BotAgentRef(id: principal.botId,
                                 name: senderProfile?.name ?? principal.botId,
                                 kind: "agent")
        guard let targetProfile = resolve(targetReference, in: roster) else {
            let available = BotToolCatalog.availableBotEntries(
                roster: roster, callerBotID: principal.botId)
            let list = available.isEmpty ? "(none)" : available.joined(separator: ", ")
            return .failure(
                "invalid_arguments",
                "agent not found: \"\(targetReference)\". Available bots: \(list).")
        }
        let target = BotAgentRef(id: targetProfile.id, name: targetProfile.name, kind: "agent")
        if target.id == principal.botId {
            return .failure(
                "invalid_arguments",
                "SendToAgent cannot target the same bot that is running; answer the request yourself.")
        }

        let commContext = await host.agentCommContext(for: principal.botId)
        let depth = commContext.depth + 1
        guard depth <= Self.maximumHops else {
            return .failure(
                "invalid_arguments",
                "delegation depth limit reached (max \(Self.maximumHops) hops). "
                    + "Do not hand this off again; answer with what you have.")
        }
        if commContext.chain.contains(target.id) {
            // The chain is a user-facing dead end: name the Bots, never the
            // internal `agent-…` ids. The sender must answer the current
            // request itself instead of bouncing it back.
            let names = commContext.chain.map { id in
                roster.bots.first { $0.id == id }?.name ?? "对方"
            }
            let path = (names + [target.name]).joined(separator: " → ")
            return .failure(
                "invalid_arguments",
                "转交链已经走过 \(path)，\(target.name) 在这条链上，不能再转回去。"
                    + "请直接回答当前请求。")
        }

        let callID = context.callId
        let requestID = BotTurnOrigin.agentRequestId(callId: callID)
        // Compatibility: pre-WP4 outbound agent.comm rows stored the bare
        // sender call id as their requestId. A replay of that same tool call
        // must find the old row and not write a second outbound row.
        var existingThread = await host.existingAgentCommThread(
            botID: principal.botId, requestID: requestID)
        if existingThread == nil {
            existingThread = await host.existingAgentCommThread(
                botID: principal.botId, requestID: callID)
        }
        if let existingThread {
            return sendToAgentSuccess(
                target: target, threadID: existingThread, requestID: requestID,
                delivery: delivery, duplicated: true, heldID: nil)
        }

        let title = firstString(args, ["title"])
        let seq = nextSequence()
        let rowID = BotAgentCommIdentity.outboundRowID(
            senderAgentID: sender.id, targetID: target.id, requestID: requestID, seq: seq)
        let threadID = BotAgentCommIdentity.threadID(rowID: rowID, seq: seq)
        var nextChain = commContext.chain
        if !nextChain.contains(sender.id) { nextChain.append(sender.id) }
        if !nextChain.contains(target.id) { nextChain.append(target.id) }

        let outbound = BotTeamAgentCommRecord(
            rowID: rowID, botID: sender.id, direction: .outbound, role: "assistant",
            text: message, toAgent: target, threadID: threadID, requestID: requestID,
            delivery: delivery, status: delivery == "queued" ? "held" : nil,
            title: title, hop: depth, callID: context.callId)
        do { try await host.recordAgentComm(outbound) }
        catch { return .failure("execution_failed", String(describing: error)) }

        if delivery == "queued" {
            let item: WakeInboxItem
            do {
                item = try WakeInboxItem(
                    id: heldID(createdAt: now()), kind: "agent-held",
                    fromAgentId: sender.id, fromAgentName: sender.name,
                    title: title, text: message, requestId: requestID,
                    threadId: threadID, createdAt: now())
            } catch {
                return .failure("execution_failed", String(describing: error))
            }
            do {
                let enqueued = try await host.enqueueHeld(
                    BotTeamHeldRequest(
                        botID: target.id, item: item,
                        handOff: BotAgentCommContext(depth: depth, chain: nextChain)))
                return sendToAgentSuccess(
                    target: target, threadID: threadID, requestID: requestID,
                    delivery: delivery, duplicated: enqueued.duplicate,
                    heldID: enqueued.item.id)
            } catch {
                return .failure(
                    "execution_failed",
                    "held inbox write failed: \(String(describing: error))")
            }
        }

        let titleSuffix = title.map { " — \($0)" } ?? ""
        let promptText = "[agent] \(sender.name) (id: \(sender.id))\(titleSuffix): \(message)"
        let request = BotAgentDeliveryRequest(
            sender: sender, target: target, promptText: promptText, message: message,
            title: title, threadId: threadID, requestId: requestID,
            delivery: "now", hop: depth, chain: nextChain)
        let reply: BotAgentDeliveryReply
        do {
            reply = try await deliver(request)
        } catch {
            let failure = failureMessage(error)
            let inbound = BotTeamAgentCommRecord(
                rowID: BotAgentCommIdentity.turnRowID(
                    turn: commContext.turn, existingIDs: commContext.existingRowIDs),
                botID: sender.id, direction: .inbound, role: "user", text: "",
                fromAgent: BotAgentRef(id: target.id, name: target.name),
                threadID: threadID, requestID: requestID, turn: commContext.turn,
                error: failure)
            try? await host.recordAgentComm(inbound)
            if isTimeout(error) {
                return .failure("timeout", BotTeamHostError.deliveryTimeout.description)
            }
            return .failure("execution_failed", "发送失败：\(failure)")
        }

        let inbound = BotTeamAgentCommRecord(
            rowID: BotAgentCommIdentity.turnRowID(
                turn: commContext.turn, existingIDs: commContext.existingRowIDs),
            botID: sender.id, direction: .inbound, role: "user", text: reply.text,
            fromAgent: BotAgentRef(id: target.id, name: target.name),
            threadID: threadID, requestID: requestID, turn: commContext.turn,
            replyEntryID: reply.replyEntryId)
        do { try await host.recordAgentComm(inbound) }
        catch { return .failure("execution_failed", String(describing: error)) }

        let replyText = String(reply.text.prefix(Self.heldTextLimit))
        let replyTitle: String
        if let title, !title.isEmpty {
            replyTitle = "回复：\(title)"
        } else {
            replyTitle = "回复"
        }
        let heldItem: WakeInboxItem
        do {
            heldItem = try WakeInboxItem(
                id: heldID(createdAt: now()), kind: "agent-held",
                fromAgentId: target.id, fromAgentName: target.name,
                title: replyTitle, text: replyText, requestId: "reply:\(requestID)",
                threadId: threadID, createdAt: now())
        } catch {
            return .failure("execution_failed", String(describing: error))
        }
        do {
            // A reply is the end of this hand-off, not a new hop. It must not
            // install a chain on the sender or the next send to this teammate
            // would be rejected as a cycle.
            _ = try await host.enqueueHeld(
                BotTeamHeldRequest(botID: sender.id, item: heldItem))
        } catch {
            return .failure(
                "execution_failed",
                "reply was received but the held inbox write failed: \(String(describing: error))")
        }
        return sendToAgentSuccess(
            target: target, threadID: threadID, requestID: requestID,
            delivery: delivery, duplicated: false, heldID: nil)
    }

    private func sendToAgentSuccess(target: BotAgentRef, threadID: String,
                                    requestID: String, delivery: String,
                                    duplicated: Bool, heldID: String?) -> BotMCPCallResult {
        var structured: [String: BotJSONValue] = [
            "ok": .bool(true),
            "threadId": .string(threadID),
            "requestId": .string(requestID),
            "target": .object(["id": .string(target.id), "name": .string(target.name)]),
            "delivery": .string(delivery),
        ]
        if let heldID { structured["heldId"] = .string(heldID) }
        if duplicated { structured["duplicated"] = .bool(true) }
        if delivery == "queued" { structured["status"] = .string("held") }
        let text = delivery == "queued"
            ? "已扣住给 \(target.name)：消息会在对方下一个回合开头交付，不会唤醒对方。"
            : "已发送给 \(target.name)，回复稍后以 agent-comm 消息送达。"
        return .success(.object(structured), text: text)
    }

    // MARK: - CreateTeammate

    private func createTeammate(_ arguments: BotJSONValue,
                                principal: BotGatewayPrincipal,
                                authority: BotTurnAuthority?) async -> BotMCPCallResult {
        guard case .object(let args) = arguments else {
            return .failure("invalid_arguments", "CreateTeammate arguments must be an object")
        }
        guard let rawName = args["name"].flatMap({ $0.stringValue }) else {
            return .failure("invalid_arguments", "CreateTeammate requires name.")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .failure("invalid_arguments", "CreateTeammate requires name.")
        }
        guard name.utf16.count <= 60 else {
            return .failure(
                "invalid_arguments",
                "CreateTeammate name is too long (\(name.utf16.count) > 60).")
        }
        let description = args["description"].flatMap { $0.stringValue }
            .map { truncated($0, toUTF16Units: 300) } ?? ""

        let color: BotFishColor?
        switch optionalEnum(args["color"], all: BotFishColor.allCases.map(\.rawValue),
                            label: "color") {
        case .success(let value): color = value.flatMap { BotFishColor(rawValue: $0) }
        case .failure(let message): return .failure("invalid_arguments", message)
        }
        let hairstyle: BotFishHairstyle?
        switch optionalEnum(args["hairstyle"], all: BotFishHairstyle.allCases.map(\.rawValue),
                            label: "hairstyle") {
        case .success(let value): hairstyle = value.flatMap { BotFishHairstyle(rawValue: $0) }
        case .failure(let message): return .failure("invalid_arguments", message)
        }

        let roster: BotRoster
        do { roster = try await host.roster() }
        catch { return .failure("execution_failed", String(describing: error)) }
        let senderName = roster.bots.first { $0.id == principal.botId }?.name ?? principal.botId
        guard roster.mainBotID == principal.botId else {
            return .failure(
                "permission_denied",
                "CreateTeammate 只能由主 Bot 调用；当前 Bot \(senderName)"
                    + "（id: \(principal.botId)）不是主 Bot。")
        }
        var author: BotTeammateAuthor?
        if let authority {
            guard let resolved = BotTeammateAuthor(authority: authority) else {
                return .failure(
                    "permission_denied",
                    "CreateTeammate requires user confirmation in this turn")
            }
            author = resolved
        }

        let created: BotProfile
        do {
            created = try await host.createBot(
                name: name, description: description, color: color, hairstyle: hairstyle,
                author: author)
        } catch {
            return .failure("execution_failed", "创建队友失败：\(String(describing: error))")
        }

        var text = "已创建队友「\(created.name)」（agent_id: \(created.id)）"
        if !description.isEmpty { text += " — \(description)" }
        if let color, let hairstyle {
            text += "；外观：颜色=\(color.rawValue)、发型=\(hairstyle.rawValue)"
        } else if let color {
            text += "；外观：颜色=\(color.rawValue)"
        } else if let hairstyle {
            text += "；外观：发型=\(hairstyle.rawValue)"
        } else {
            text += "；外观：按 Bot ID 自动组合"
        }
        text += "。"
        return .success(.object([
            "ok": .bool(true),
            "agent_id": .string(created.id),
            "name": .string(created.name),
        ]), text: text)
    }

    // MARK: - Delivery

    private func deliver(_ request: BotAgentDeliveryRequest) async throws -> BotAgentDeliveryReply {
        let host = self.host
        let timeout = timeoutMilliseconds
        return try await withThrowingTaskGroup(of: BotAgentDeliveryReply.self) { group in
            group.addTask { try await host.deliverToAgent(request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                throw BotTeamHostError.deliveryTimeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw BotTeamHostError.deliveryFailed("delivery produced no result")
            }
            return first
        }
    }

    private func failureMessage(_ error: Error) -> String {
        if let hostError = error as? BotTeamHostError { return hostError.description }
        if error is CancellationError { return BotTeamHostError.deliveryTimeout.description }
        return String(describing: error)
    }

    private func isTimeout(_ error: Error) -> Bool {
        if let hostError = error as? BotTeamHostError, hostError == .deliveryTimeout { return true }
        return error is CancellationError || Task.isCancelled
    }

    // MARK: - Argument parsing

    private enum DeliveryResolution {
        case success(String)
        case failure(String)
    }

    private func resolveDelivery(_ args: [String: BotJSONValue]) -> DeliveryResolution {
        let priorityValue = args["priority"]
        let deliveryValue = args["delivery"]
        let hasPriority = priorityValue.map { !isEmpty($0) } ?? false
        let hasDelivery = deliveryValue.map { !isEmpty($0) } ?? false

        var priority: Bool?
        if hasPriority {
            if case .bool(let value)? = priorityValue {
                priority = value
            } else if case .string(let value)? = priorityValue {
                switch value {
                case "true": priority = true
                case "false": priority = false
                default: priority = nil
                }
            }
            guard priority != nil else {
                return .failure(
                    "priority must be a boolean (true = wake now, false = hold for their next turn)")
            }
        }

        var delivery: String?
        if hasDelivery {
            guard case .string(let value)? = deliveryValue else {
                return .failure("delivery must be \"now\" or \"queued\"")
            }
            guard value == "now" || value == "queued" else {
                return .failure("delivery must be \"now\" or \"queued\"")
            }
            delivery = value
        }

        guard hasPriority || hasDelivery else {
            return .failure(
                "SendToAgent requires priority (true = wake now, false = hold for their next turn).")
        }
        if let priority {
            let implied = priority ? "now" : "queued"
            if let delivery, delivery != implied {
                return .failure(
                    "priority \(jsonLiteral(priorityValue)) implies delivery \"\(implied)\" "
                        + "but delivery \"\(delivery)\" was also given")
            }
            return .success(implied)
        }
        return .success(delivery ?? "now")
    }

    private func isEmpty(_ value: BotJSONValue) -> Bool {
        switch value {
        case .null, .array([]), .object([:]): return true
        case .string(let text): return text.isEmpty
        default: return false
        }
    }

    private func jsonLiteral(_ value: BotJSONValue?) -> String {
        guard let value else { return "undefined" }
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let text): return "\"\(text)\""
        default:
            return (try? value.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
    }

    private func firstString(_ args: [String: BotJSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if let value = args[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func resolve(_ reference: String, in roster: BotRoster) -> BotProfile? {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = roster.bots.first(where: { $0.id == needle }) { return exact }
        let lowered = needle.lowercased()
        if let byID = roster.bots.first(where: { $0.id.lowercased() == lowered }) { return byID }
        return roster.bots.first { $0.name.lowercased() == lowered }
    }

    private enum EnumResolution {
        case success(String?)
        case failure(String)
    }

    private func optionalEnum(_ value: BotJSONValue?, all: [String],
                              label: String) -> EnumResolution {
        guard let value, !isEmpty(value) else { return .success(nil) }
        guard case .string(let raw) = value else {
            return .failure("CreateTeammate \(label) must be one of \(all.joined(separator: ", "))")
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return .success(nil) }
        guard all.contains(normalized) else {
            return .failure("CreateTeammate \(label) must be one of \(all.joined(separator: ", "))")
        }
        return .success(normalized)
    }

    // MARK: - Identity

    private func nextSequence() -> Int64 {
        let (scaled, overflow) = now().multipliedReportingOverflow(by: 1_000)
        let base = overflow ? now() : scaled
        let value = base &+ Int64(sequence % 1_000)
        sequence &+= 1
        return value
    }

    private func heldID(createdAt: Int64) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "held-\(String(createdAt, radix: 36))-\(suffix)"
    }

    /// Upstream `String.slice(0, 300)` counts UTF-16 units. Stop on a grapheme
    /// boundary so a surrogate pair is never split.
    private func truncated(_ value: String, toUTF16Units limit: Int) -> String {
        guard value.utf16.count > limit else { return value }
        var result = ""
        var units = 0
        for character in value {
            let width = character.utf16.count
            if units + width > limit { break }
            result.append(character)
            units += width
        }
        return result
    }
}
