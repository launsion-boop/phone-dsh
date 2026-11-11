// SPDX-License-Identifier: MIT

import Foundation

public actor BotMCPRuntime {
    public static let defaultRuntimeID = "phone-worker"
    /// Expired registrations are swept on this cadence in addition to the
    /// opportunistic prune in `registerIdentity`/`identityForApproval`.
    public static let registrationMaintenanceIntervalMilliseconds: Int64 = 30_000

    public let store: SQLiteDomainStore
    public let gateway: BotGateway
    public let grants: BotGrantStore
    public let authorizer: BotExecutionAuthorizer
    public let eventWriter: BotMCPEventWriter
    public let approvals: BotApprovalCoordinator
    public let volatileContext: BotVolatileContextProducer
    /// Compatibility view of the `"main"` executor. Task tools route through
    /// `taskExecutor(for:)`, never through this property.
    public private(set) var tasks: any BotTaskExecuting
    /// Compatibility view of `memory(for: "main")`.
    public let memory: BotMemory
    public let routineMachine: RoutineMachine

    private let now: @Sendable () -> Int64
    private let dataRoot: String
    private let memorySource: @Sendable (BotResolvedToolCall) -> BotMemorySourceKind
    private var taskExecutors: [String: any BotTaskExecuting] = [:]
    private var memories: [String: BotMemory] = [:]
    private var teamToolHandlers: [any BotTeamToolHandling] = []
    private var toolCatalogProvider: (@Sendable (String?) async -> [BotMCPToolDefinition]?)?
    private var registrations: [String: BotAttribution] = [:]
    private var registrationArguments: [String: BotJSONValue] = [:]
    /// Bumped by `workerRestarted()`. Every registration/claim/approval is
    /// scoped by it, so a call registered by the previous Worker generation
    /// can never be claimed or approved after the restart.
    private var registrationGeneration: UInt64 = 0
    private var suppressingTextSessions: Set<String> = []
    private var hiddenTextSessions: Set<String> = []
    private var heldMessageSessions: Set<String> = []
    /// Installed by the App composition while the Bot runtime is bound. The
    /// fail-closed egress fallback asks it whether a workbench turn is running;
    /// `nil` (no App host, unit test) means "no workbench turn" and therefore
    /// fails closed for an unattributed write.
    private var workbenchTurnProbe: (@Sendable () async -> Bool)?
    private var turnOrigins: [String: BotTurnOrigin] = [:]
    private var turnIDs: [String: String] = [:]

    public init(
        store: SQLiteDomainStore,
        gateway: BotGateway? = nil,
        volatileProvider: (any BotVolatileContextProviding)? = nil,
        taskExecutor: (any BotTaskExecuting)? = nil,
        routineStore: (any RoutineStore)? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        memorySource: (@Sendable (BotResolvedToolCall) -> BotMemorySourceKind)? = nil
    ) {
        self.store = store
        self.now = now
        let gateway = gateway ?? BotGateway(now: now)
        self.gateway = gateway
        let audit = BotAuditLog(eventLog: store)
        let grants = BotGrantStore(domainStore: store, now: now, audit: audit)
        self.grants = grants
        authorizer = BotExecutionAuthorizer(grants: grants)
        eventWriter = BotMCPEventWriter(eventLog: store, now: now)
        approvals = BotApprovalCoordinator(grants: grants, eventWriter: eventWriter, now: now)
        volatileContext = BotVolatileContextProducer(provider: volatileProvider ?? EmptyBotVolatileContextProvider())
        let mainExecutor = taskExecutor ?? UnimplementedBotTaskExecutor()
        tasks = mainExecutor
        taskExecutors = ["main": mainExecutor]
        let dataRoot = store.fileURL.deletingLastPathComponent().path
        self.dataRoot = dataRoot
        let mainMemory = BotMemory(
            store: SQLiteBotMemoryFactStore(eventLog: store, botID: "main", now: now),
            dataRoot: dataRoot, botID: "main", now: now)
        memory = mainMemory
        memories = ["main": mainMemory]
        routineMachine = RoutineMachine(store: routineStore ?? SQLiteRoutineStore(domainStore: store))
        self.memorySource = memorySource ?? { call in
            switch call.principal.kind {
            case .chat: return .userTurn
            case .task: return .task
            case .routine: return .routine
            case .team, .proactive, .watchdog: return .hiddenWake
            }
        }
        let interval = Self.registrationMaintenanceIntervalMilliseconds
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                _ = await self.pruneExpiredRegistrations()
            }
        }
    }

    /// Returns the cached memory authority for one Bot, creating it on first
    /// use. Agent-scope facts replay only events written by this Bot; user-scope
    /// facts are shared by every Bot. Historical events with no bot id belong
    /// to `"main"`.
    public func memory(for botID: String) -> BotMemory {
        if let existing = memories[botID] { return existing }
        let memory = BotMemory(
            store: SQLiteBotMemoryFactStore(eventLog: store, botID: botID, now: now),
            dataRoot: dataRoot, botID: botID, now: now)
        memories[botID] = memory
        return memory
    }

    /// Erases every agent-scope fact owned by `botID` and drops its cached
    /// memory authority. This is the deletion-cascade hook for the Bot roster:
    /// the shared user scope and every other Bot's agent facts are untouched.
    /// Tombstones are durable, so a later replay cannot resurrect the facts.
    ///
    /// - Returns: the erased count and ids. `count` is the remaining agent-scope
    ///   fact count observed at the end of the erase.
    @discardableResult
    public func deleteBotMemory(for botID: String) async throws -> BotMemoryEraseScopeResult {
        let result = try await memory(for: botID).eraseAll(scope: .agent)
        _ = forgetMemory(for: botID)
        return result
    }

    /// Drops the cached `BotMemory` authority for `botID` without touching
    /// durable memory. A later ``memory(for:)`` builds a fresh authority from
    /// the event log. Use ``deleteBotMemory(for:)`` when the Bot is deleted.
    ///
    /// The `memory` compatibility view is not invalidated; it keeps pointing at
    /// the authority it was created with.
    @discardableResult
    public func forgetMemory(for botID: String) -> Bool {
        memories.removeValue(forKey: botID) != nil
    }

    /// Routes Task/AwaitTask/StopSubagent for one Bot. Detaching the `"main"`
    /// executor falls back to the unimplemented executor; another Bot never
    /// borrows it.
    public func attachTaskExecutor(_ executor: any BotTaskExecuting, botID: String) {
        taskExecutors[botID] = executor
        if botID == "main" { tasks = executor }
    }

    /// Backward-compatible convenience: the Bot-less method always means the
    /// `"main"` Bot.
    public func attachTaskExecutor(_ executor: any BotTaskExecuting) {
        attachTaskExecutor(executor, botID: "main")
    }

    public func detachTaskExecutor(botID: String) {
        taskExecutors.removeValue(forKey: botID)
        if botID == "main" { tasks = UnimplementedBotTaskExecutor() }
    }

    /// Backward-compatible convenience: the Bot-less method always means the
    /// `"main"` Bot.
    public func detachTaskExecutor() {
        detachTaskExecutor(botID: "main")
    }

    /// True when a registered team-tool handler claims this bare name. The
    /// catalog itself is intentionally unchanged in this unit.
    func handlesTeamTool(_ name: String) -> Bool {
        guard !Self.isHostBuiltinToolName(name) else { return false }
        return teamToolHandlers.contains { $0.handles(name) }
    }

    /// Names the host/Worker already owns outside the Bot catalog (shell, VFS,
    /// native phone tools). A team handler may never divert them.
    private static func isHostBuiltinToolName(_ name: String) -> Bool {
        ["bash", "write", "edit", "phone"].contains(name)
            || BotDeviceToolProvider.tools.contains(name)
    }

    /// Registers a team tool surface. New names are routed after normal
    /// identity attribution and authorization; the existing tool catalog and
    /// tool list are not modified. When the handler also implements
    /// ``BotTeamToolCatalogProviding`` and no explicit provider was installed,
    /// its roster-aware catalog becomes the per-caller `tools/list` source.
    public func registerTeamTools(_ handler: any BotTeamToolHandling) {
        teamToolHandlers.append(handler)
        if toolCatalogProvider == nil, let catalog = handler as? any BotTeamToolCatalogProviding {
            toolCatalogProvider = { callerBotID in
                await catalog.toolDefinitions(callerBotID: callerBotID)
            }
        }
    }

    /// Replaces the roster-aware catalog provider. Pass `nil` to fall back to
    /// the static catalog. The App does not normally need this; registering
    /// `BotTeamTools` installs its provider automatically.
    public func setToolCatalogProvider(
        _ provider: (@Sendable (String?) async -> [BotMCPToolDefinition]?)?) {
        toolCatalogProvider = provider
    }

    /// Tool definitions for one caller. Without an identified caller (or when
    /// the provider declines), the historical static catalog is returned so
    /// standard MCP clients keep their current behaviour. The provider is
    /// installed by `registerTeamTools`; the App needs no extra wiring.
    public func toolDefinitions(callerBotID: String?) async -> [BotMCPToolDefinition] {
        guard let callerBotID, !callerBotID.isEmpty else {
            return BotToolCatalog.allDefinitions
        }
        if let provider = toolCatalogProvider,
           let definitions = await provider(callerBotID) {
            return definitions
        }
        return BotToolCatalog.allDefinitions
    }

    /// Resolves the caller Bot from the App-minted MCP session identity. This
    /// is the same session principal `tools/call` attribution uses; no tool
    /// arguments or model-supplied Bot id participate.
    public func callerBotID(forSession sessionID: String?) async -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return await gateway.tokens.lookupSession(sessionID)?.botId
    }

    private func teamToolHandler(for name: String) -> (any BotTeamToolHandling)? {
        teamToolHandlers.first { $0.handles(name) }
    }

    private func taskExecutor(for botID: String) throws -> any BotTaskExecuting {
        guard let executor = taskExecutors[botID] else {
            throw BotMCPError.unavailable(
                "No task executor is attached for bot \(botID); refusing to use another Bot's executor")
        }
        return executor
    }

    @discardableResult
    public func issueSession(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotGatewayPrincipal {
        try await gateway.issueSession(botId: botId, sessionId: sessionId, kind: kind)
    }

    /// Issues the principal and returns its registry token. The Bot host's
    /// session claim path uses this variant so it can hand the same token to
    /// the Worker; the token stays in host/Worker memory only.
    @discardableResult
    public func issueSessionToken(botId: String, sessionId: String,
                                  kind: BotSessionKind) async throws -> BotIssuedToken {
        try await gateway.issueSessionToken(botId: botId, sessionId: sessionId, kind: kind)
    }

    public func currentTurnID(sessionId: String) -> String? { turnIDs[sessionId] }

    public func beginTurn(sessionId: String, hidden: Bool, held: Bool = false,
                          origin: BotTurnOrigin? = nil) {
        suppressingTextSessions.remove(sessionId)
        turnIDs.removeValue(forKey: sessionId)
        if hidden { hiddenTextSessions.insert(sessionId) } else { hiddenTextSessions.remove(sessionId) }
        if held { heldMessageSessions.insert(sessionId) } else { heldMessageSessions.remove(sessionId) }
        if let origin { turnOrigins[sessionId] = origin } else { turnOrigins.removeValue(forKey: sessionId) }
    }

    public func updateTurn(sessionId: String, turnId: String) {
        turnIDs[sessionId] = turnId
    }

    public func endTurn(sessionId: String) {
        hiddenTextSessions.remove(sessionId)
        heldMessageSessions.remove(sessionId)
        turnOrigins.removeValue(forKey: sessionId)
        turnIDs.removeValue(forKey: sessionId)
    }

    public func suppressText(sessionId: String) {
        suppressingTextSessions.insert(sessionId)
    }

    /// The Worker-visible runtime identifier is the base name; every stored
    /// registration carries the current generation instead. The plugin keeps
    /// sending `phone-worker`, so a Worker restart needs no environment change.
    public func scopedRuntimeID(_ runtimeId: String) -> String {
        "\(runtimeId)@\(registrationGeneration)"
    }

    public func registerIdentity(runtimeId: String, sessionId: String, callId: String,
                                 name: String, arguments: BotJSONValue,
                                 argsDigest: String? = nil) async throws -> BotAttribution {
        _ = pruneExpiredRegistrationsSync()
        let bareName = bareToolName(name)
        guard BotToolCatalog.isRegistered(bareName)
                || ["bash", "write", "edit", "phone"].contains(bareName)
                || BotDeviceToolProvider.tools.contains(bareName)
                || handlesTeamTool(bareName) else {
            throw BotMCPError.unknownTool(name)
        }
        let scope = scopedRuntimeID(runtimeId)
        let key = key(scope, sessionId, callId)
        let digest = try (argsDigest ?? BotArgumentsDigest.string(for: arguments))
        if let existing = registrations[key] {
            let principal = await gateway.tokens.lookupSession(sessionId)
            if existing.sessionId == sessionId, existing.name == bareName,
               existing.argsDigest == digest, let principal,
               principal.incarnation == existing.incarnation {
                // A background job's heartbeat re-posts the same call. Extend
                // the existing attribution instead of publishing a duplicate;
                // if the host already pruned it, fall through and register a
                // fresh entry (the job's next write is then fail-closed until
                // this response arrives).
                if let refreshed = await gateway.refreshToolCall(id: existing.id) {
                    registrations[key] = refreshed
                    registrationArguments[key] = arguments
                    return refreshed
                }
            }
        }
        let attribution = try await gateway.registerToolCall(
            sessionId: sessionId, callId: callId, name: bareName,
            arguments: arguments, argsDigest: argsDigest, runtimeId: scope)
        registrations[key] = attribution
        registrationArguments[key] = arguments
        return attribution
    }

    /// Identity registration for the HTTP `/identity/register` route. The
    /// caller-supplied `sessionToken` resolves the principal; the body
    /// `sessionId` is only a consistency check. Missing, unknown, revoked,
    /// expired or mismatched credentials throw ``BotMCPError/unauthorized`` and
    /// register nothing.
    public func registerIdentity(runtimeId: String, sessionId: String, callId: String,
                                 name: String, arguments: BotJSONValue,
                                 argsDigest: String? = nil,
                                 sessionToken: String) async throws -> BotAttribution {
        _ = pruneExpiredRegistrationsSync()
        guard !sessionToken.isEmpty,
              let principal = await gateway.tokens.lookup(sessionToken),
              principal.sessionId == sessionId else {
            throw BotMCPError.unauthorized
        }
        let bareName = bareToolName(name)
        guard BotToolCatalog.isRegistered(bareName)
                || ["bash", "write", "edit", "phone"].contains(bareName)
                || BotDeviceToolProvider.tools.contains(bareName)
                || handlesTeamTool(bareName) else {
            throw BotMCPError.unknownTool(name)
        }
        let scope = scopedRuntimeID(runtimeId)
        let key = key(scope, sessionId, callId)
        let digest = try (argsDigest ?? BotArgumentsDigest.string(for: arguments))
        if let existing = registrations[key] {
            if existing.sessionId == sessionId, existing.name == bareName,
               existing.argsDigest == digest, principal.incarnation == existing.incarnation {
                if let refreshed = await gateway.refreshToolCall(id: existing.id) {
                    registrations[key] = refreshed
                    registrationArguments[key] = arguments
                    return refreshed
                }
            }
        }
        do {
            let attribution = try await gateway.registerToolCall(
                sessionToken: sessionToken, sessionId: sessionId, callId: callId,
                name: bareName, arguments: arguments, argsDigest: argsDigest, runtimeId: scope)
            registrations[key] = attribution
            registrationArguments[key] = arguments
            return attribution
        } catch BotGatewayError.unknownSession {
            throw BotMCPError.unauthorized
        }
    }

    @discardableResult
    public func cancelIdentity(id: String) async -> Bool {
        guard let match = registrations.first(where: { $0.value.id == id }) else { return false }
        registrations.removeValue(forKey: match.key)
        registrationArguments.removeValue(forKey: match.key)
        return await gateway.cancelToolCall(id: id)
    }

    /// Called before issuing an approval card. An expired registration and one
    /// from a previous Worker generation are both treated as unattributed.
    /// `sessionId` narrows the lookup when the same model call id exists in
    /// independent sessions.
    public func identityForApproval(runtimeId: String, sessionId: String? = nil,
                                    callId: String) async -> BotResolvedToolCall? {
        _ = pruneExpiredRegistrationsSync()
        let scope = scopedRuntimeID(runtimeId)
        let matches = registrations.filter { key, attribution in
            key.hasPrefix("\(scope)\u{0}") && attribution.callId == callId
                && (sessionId == nil || attribution.sessionId == sessionId)
                && attribution.expiresAt > now()
        }
        guard matches.count == 1, let attribution = matches.first?.value else { return nil }
        guard let principal = await gateway.tokens.lookupSession(attribution.sessionId),
              principal.incarnation == attribution.incarnation else { return nil }
        return BotResolvedToolCall(
            sessionId: attribution.sessionId, callId: attribution.callId,
            agentId: principal.botId, principal: principal, attribution: attribution)
    }

    /// Cancels every pending card, invalidates every registration and rotates
    /// the runtime generation. The composition calls this whenever the Host
    /// rebuilt or recovered the Worker; old registrations can never be claimed
    /// after it returns.
    @discardableResult
    public func workerRestarted() async -> Int {
        let previous = scopedRuntimeID(Self.defaultRuntimeID)
        let previousRegistrations = registrations
        registrationGeneration &+= 1
        registrations.removeAll()
        registrationArguments.removeAll()
        for attribution in previousRegistrations.values {
            _ = await gateway.cancelToolCall(id: attribution.id)
        }
        _ = await gateway.cancelToolCalls(runtimeId: previous)
        let cancelled = await approvals.cancelAll(reason: "worker_restarted")
        var restarted: Set<ObjectIdentifier> = []
        for executor in taskExecutors.values {
            guard restarted.insert(ObjectIdentifier(executor as AnyObject)).inserted else { continue }
            if let restarting = executor as? any BotTaskRestarting {
                await restarting.workerRestarted()
            }
        }
        return cancelled
    }

    /// Installs or clears the App's workbench-turn probe. This is only the
    /// fallback guard: an attributed background job never consults it.
    public func installWorkbenchTurnProbe(_ probe: (@Sendable () async -> Bool)?) {
        workbenchTurnProbe = probe
    }

    /// Session ids of every active Bot principal. The App uses this to exclude
    /// Bot sessions from the workbench-turn probe.
    public func activeSessionIDs() async -> Set<String> {
        await gateway.tokens.activeSessionIDs()
    }

    /// Removes registrations past their expiry and revokes their pending
    /// attributions. Public so a test and the maintenance task can force it.
    @discardableResult
    public func pruneExpiredRegistrations() async -> Int {
        let expired = pruneExpiredRegistrationsSync()
        for attribution in expired {
            _ = await gateway.cancelToolCall(id: attribution.id)
        }
        _ = await gateway.attribution.prune()
        return expired.count
    }

    private func pruneExpiredRegistrationsSync() -> [BotAttribution] {
        let timestamp = now()
        let expired = registrations.filter { $0.value.expiresAt <= timestamp }
        guard !expired.isEmpty else { return [] }
        for (key, _) in expired {
            registrations.removeValue(forKey: key)
            registrationArguments.removeValue(forKey: key)
        }
        return expired.map(\.value)
    }

    public func approve(runtimeId: String, sessionId: String? = nil, callId: String, name: String,
                        action: String, detail: String, command: String,
                        argsDigest: String, alwaysScope: String, askAction: String,
                        suppliedEffects: [BotToolEffect]? = nil) async -> BotApprovalOutcome {
        let scope = scopedRuntimeID(runtimeId)
        guard let call = await identityForApproval(runtimeId: runtimeId, sessionId: sessionId, callId: callId),
              bareToolName(call.attribution.name) == bareToolName(name),
              let arguments = registrationArguments[key(scope, call.sessionId, callId)] else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "unattributed")
        }
        guard let suppliedDigest = try? BotArgumentsDigest.validated(argsDigest),
              suppliedDigest == call.attribution.argsDigest,
              let registeredDigest = try? BotArgumentsDigest.string(for: arguments),
              registeredDigest == suppliedDigest else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:digest_mismatch")
        }
        let bareName = bareToolName(name)
        if bareName == "bash", arguments["command"]?.stringValue != command {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:command_mismatch")
        }
        let effects: [BotToolEffect]
        if askAction == "sandbox-escalation" {
            guard bareName == "bash", alwaysScope == "none",
                  let suppliedEffects, suppliedEffects.count == 1,
                  suppliedEffects[0].operation == "sandbox-escalation",
                  !BotResourceNormalizer.normalize(suppliedEffects[0].resource).isEmpty else {
                return BotApprovalOutcome(ok: false, allowed: false, message: "stale:sandbox_effect")
            }
            effects = [BotToolEffect(
                tool: "bash", operation: "sandbox-escalation",
                resource: suppliedEffects[0].resource, target: suppliedEffects[0].target,
                mutability: .write, policy: .ask, label: action, detail: detail)]
        } else {
            effects = await effectsForApproval(
                name: bareName, botID: call.principal.botId,
                arguments: bareName == "bash" ? .object(["command": .string(command)]) : arguments)
        }
        guard ["until", "session", "none"].contains(alwaysScope) else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:always_scope")
        }
        let expectedScope = !effects.isEmpty && effects.allSatisfy { !$0.known } ? "session" : "until"
        guard alwaysScope == expectedScope || alwaysScope == "none" else {
            return BotApprovalOutcome(ok: false, allowed: false, message: "stale:always_scope")
        }
        if effects.isEmpty { return BotApprovalOutcome(ok: true, allowed: true, message: "auto-policy") }
        return await approvals.request(
            call: call, effects: effects, action: action, detail: detail,
            command: command, alwaysScope: alwaysScope)
    }

    /// Host-side approval for one Bot network write at the `/v1/http` exit.
    ///
    /// Attribution follows the live `bash` identity registration. A normal
    /// shell call registers before the command body; a call the DSH job
    /// registry kept running after its tool result returned keeps that same
    /// registration alive (with a heartbeat) until the job settles. Several
    /// live registrations may belong to the same Bot (for example two
    /// background jobs or a chat and a task session); they are one owner. Only
    /// registrations from different Bots are ambiguous, and the outer command
    /// host text remains a tie-breaker.
    ///
    /// Inside a turn, registration is the authority. With no live
    /// registration at all the fail-closed fallback asks the App whether a
    /// workbench turn is running: if it is, this is workbench traffic
    /// (`notBot`); if not, the write can only be a Bot background task, so one
    /// active Bot owns the card and several Bots fail with
    /// `bot_egress_ambiguous`. No active Bot credential is
    /// `bot_egress_unattributed`.
    public func approveEgress(method: String, host: String, scheme: String,
                              port: Int?) async -> BotEgressApproval {
        let upper = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["POST", "PUT", "PATCH", "DELETE"].contains(upper) else { return .notBot }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty, !scheme.isEmpty else {
            return .denied(
                code: "egress_approval_denied",
                message: "the network write has no usable host")
        }
        let target = "\(scheme)://\(normalizedHost)\(port.map { ":\($0)" } ?? "")"
        let timestamp = now()
        var active: [(key: String, attribution: BotAttribution,
                      principal: BotGatewayPrincipal)] = []
        var hadLiveRegistration = false
        for (key, attribution) in registrations {
            guard attribution.name == "bash", attribution.expiresAt > timestamp else { continue }
            hadLiveRegistration = true
            guard let principal = await gateway.tokens.lookupSession(attribution.sessionId),
                  principal.incarnation == attribution.incarnation else { continue }
            active.append((key, attribution, principal))
        }
        if hadLiveRegistration && active.isEmpty {
            return .denied(
                code: "bot_egress_unattributed",
                message: "the active Bot session credential is no longer valid")
        }
        if !active.isEmpty {
            let chosen: (key: String, attribution: BotAttribution,
                         principal: BotGatewayPrincipal)
            let groups = Dictionary(grouping: active, by: { $0.principal.botId })
            if groups.count > 1 {
                // A python/git script may not name the host in the outer
                // command, so the host text is only a tie-breaker. Anything
                // still ambiguous fails closed instead of attributing one
                // Bot's write to another.
                let matches = active.filter { entry in
                    commandText(for: entry.key).range(
                        of: normalizedHost, options: [.caseInsensitive]) != nil
                }
                let matchingBots = Set(matches.map { $0.principal.botId })
                guard matchingBots.count == 1, let bot = matchingBots.first,
                      let match = matches.first(where: { $0.principal.botId == bot }) else {
                    return .denied(
                        code: "bot_egress_ambiguous",
                        message: "more than one Bot session is active; the network write is not attributable")
                }
                chosen = match
            } else {
                let candidates = groups.values.first ?? []
                chosen = candidates.first(where: {
                    commandText(for: $0.key).range(
                        of: normalizedHost, options: [.caseInsensitive]) != nil
                }) ?? candidates[0]
            }
            guard let call = BotResolvedToolCall(
                sessionId: chosen.attribution.sessionId, callId: chosen.attribution.callId,
                agentId: chosen.principal.botId, principal: chosen.principal,
                attribution: chosen.attribution) else {
                return .denied(
                    code: "bot_egress_unattributed",
                    message: "the active Bot registration does not resolve to one live principal")
            }
            let effect = BotEgressEffects.egressEffect(
                method: upper, host: normalizedHost, target: target)
            return await requestEgressApproval(
                call: call, effect: effect, command: commandText(for: chosen.key))
        }

        // Fail-closed fallback. It is deliberately consulted only when no live
        // registration attributes the write: an attributed job must never be
        // diverted to another Bot merely because the workbench is busy.
        if await (workbenchTurnProbe?() ?? false) { return .notBot }
        return await unattributedEgressApproval(
            host: normalizedHost, target: target, method: upper)
    }

    /// One active Bot and no live registration: ask that Bot's user. Several
    /// active Bots (or none) cannot be attributed safely.
    private func unattributedEgressApproval(
        host: String, target: String, method: String
    ) async -> BotEgressApproval {
        let principals = await gateway.tokens.activePrincipals()
        let bots = Set(principals.map(\.botId))
        guard !bots.isEmpty else {
            return .denied(
                code: "bot_egress_unattributed",
                message: "no live Bot session can own the network write")
        }
        guard bots.count == 1 else {
            return .denied(
                code: "bot_egress_ambiguous",
                message: "more than one Bot session is active; the network write is not attributable")
        }
        // A chat principal is the visible owner of the Bot; without one a task
        // or routine session still receives the card.
        let principal = principals.first(where: { $0.kind == .chat }) ?? principals[0]
        guard let call = syntheticEgressCall(principal: principal) else {
            return .denied(
                code: "bot_egress_unattributed",
                message: "the active Bot session has no valid principal")
        }
        let effect = BotEgressEffects.egressEffect(method: method, host: host, target: target)
        return await requestEgressApproval(
            call: call, effect: effect,
            command: "background network write with no live shell registration")
    }

    /// A card-bearing call for the fallback. It is never persisted as an
    /// attribution and never authorizes any tool other than this one egress
    /// effect; it only carries the Bot principal and a stable digest into the
    /// existing approval coordinator.
    private func syntheticEgressCall(principal: BotGatewayPrincipal) -> BotResolvedToolCall? {
        let timestamp = now()
        let callId = "egress-\(UUID().uuidString.lowercased())"
        let digest = (try? BotArgumentsDigest.string(
            for: .object(["command": .string("")])))
            ?? String(repeating: "0", count: 64)
        let attribution = BotAttribution(
            id: "egress-\(UUID().uuidString.lowercased())",
            sessionId: principal.sessionId, incarnation: principal.incarnation,
            callId: callId, name: "bash", argsDigest: digest, runtimeId: nil,
            createdAt: timestamp,
            expiresAt: timestamp + BotApprovalCoordinator.defaultTimeoutMilliseconds + 30_000)
        return BotResolvedToolCall(
            sessionId: principal.sessionId, callId: callId,
            agentId: principal.botId, principal: principal, attribution: attribution)
    }

    private func commandText(for key: String) -> String {
        if case .string(let text)? = registrationArguments[key]?["command"] { return text }
        return ""
    }

    /// Shared card wait/cancellation for an attributed call and the fallback.
    private func requestEgressApproval(
        call: BotResolvedToolCall, effect: BotToolEffect,
        command: String
    ) async -> BotEgressApproval {
        let cancellation = BotEgressApprovalCancellation(approvals: approvals)
        let outcome = await withTaskCancellationHandler {
            let result = await approvals.request(
                call: call, effects: [effect],
                action: effect.label, detail: effect.detail,
                command: command, alwaysScope: "until",
                onPending: { id in cancellation.set(approvalID: id) })
            cancellation.clear()
            return result
        } onCancel: {
            cancellation.cancel()
        }
        guard outcome.allowed else {
            return .denied(
                code: "egress_approval_denied",
                message: outcome.message ?? "approval denied")
        }
        return .allowed
    }

    public func execute(name: String, arguments: BotJSONValue,
                        context: BotMCPRequestContext) async -> BotMCPCallResult {
        let bareName = bareToolName(name)
        let catalogTool = BotToolCatalog.isRegistered(bareName)
        let teamHandler = catalogTool ? nil : teamToolHandler(for: bareName)
        guard catalogTool || teamHandler != nil else {
            return .failure("unknown_tool", "Unknown tool: \(name)")
        }
        let scope = scopedRuntimeID(context.runtimeId)
        guard let call = await gateway.resolveToolCall(
            runtimeId: scope, name: bareName, arguments: arguments) else {
            return .failure("unattributed", "The tool call could not be attributed to an active session")
        }
        // The per-caller catalog is not a display filter: `tools/call` must use
        // the same catalog `tools/list` returns for this principal before any
        // effect or handler runs. `CreateTeammate`'s main-Bot check below stays
        // a second, independent check.
        let callerCatalog = await toolDefinitions(callerBotID: call.principal.botId)
        guard callerCatalog.contains(where: { $0.name == bareName }) else {
            return .failure("permission_denied",
                            "The tool is not available to the caller's catalog")
        }
        let registrationKey = key(scope, call.sessionId, call.callId)
        registrations.removeValue(forKey: registrationKey)
        registrationArguments.removeValue(forKey: registrationKey)
        do {
            if bareName == BotToolCatalog.volatileContextName {
                let read = BotToolEffect(
                    tool: bareName, operation: "context.volatile", resource: "session=\(call.sessionId)",
                    mutability: .read, policy: .auto, label: "Read current volatile context")
                guard await authorize(call: call, effect: read) == nil else {
                    return .failure("permission_denied", "Volatile context authorization failed")
                }
                let snapshot = try await volatileContext.snapshot(request: arguments, principal: call.principal)
                return .success(snapshot.jsonValue)
            }
            let effect = BotToolEffectClassifier.effect(for: bareName, arguments: arguments)
            if let reason = await authorize(call: call, effect: effect) {
                return .failure("permission_denied", reason)
            }
            if let teamHandler {
                return await teamHandler.execute(
                    name: bareName, arguments: arguments,
                    principal: call.principal, context: context)
            }
            return try await dispatch(name: bareName, arguments: arguments, call: call)
        } catch let error as BotMCPError {
            return .failure(Self.code(error), Self.message(error))
        } catch let error as BotCardPayloadError {
            switch error {
            case .invalid(let message): return .failure("invalid_arguments", message)
            }
        } catch {
            return .failure("execution_failed", String(describing: error))
        }
    }

    private func authorize(call: BotResolvedToolCall, effect: BotToolEffect) async -> String? {
        let decision = await authorizer.authorizeExecution(
            principal: BotExecutionPrincipal(gateway: call.principal), effects: [effect],
            source: "app-mcp-execution", argsDigest: call.attribution.argsDigest)
        return decision.allowed ? nil : decision.reason
    }

    private func dispatch(name: String, arguments: BotJSONValue,
                          call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        if BotToolCatalog.cardToolNames.contains(name) {
            let built = try BotCardPayloads.build(tool: name, arguments: arguments)
            guard case .object(let result) = built, let card = result["card"] else {
                throw BotMCPError.invalidRequest("card builder returned no card")
            }
            var fields = card.objectValue ?? [:]
            fields["card"] = card
            fields["id"] = .string("card-\(UUID().uuidString.lowercased())")
            fields["tool"] = .string(name)
            fields["callId"] = .string(call.callId)
            _ = try await eventWriter.append(type: "card.presented", principal: call.principal, data: .object(fields))
            if name == "ask_user" || name == "show_next_steps" {
                suppressingTextSessions.insert(call.sessionId)
                let text = name == "ask_user"
                    ? "已显示提问卡；回合应在此结束，等待用户选择。"
                    : "已显示建议下一步卡片；回合应在此结束，等待用户选择。"
                return .success(built, text: text)
            }
            return .success(built)
        }
        switch name {
        case "UpdateMemory": return try await updateMemory(arguments, call: call)
        case "RecallMemory": return try await recallMemory(arguments, call: call)
        case "Task": return try await startTask(arguments, call: call)
        case "AwaitTask": return try await awaitTask(arguments, call: call)
        case "StopSubagent": return try await stopTask(arguments, call: call)
        case "UpdateRoutine": return try await updateRoutine(arguments, call: call)
        case "ListRoutines": return .success(try await BotRoutineTool.list(machine: routineMachine, principal: call.principal))
        case "RequestApproval": return try await requestApproval(arguments, call: call)
        case "SendToUser": return try await sendToUser(arguments, call: call)
        default: throw BotMCPError.unknownTool(name)
        }
    }

    /// Turn origin decides the memory trust. A turn without a registered
    /// origin is `unknown` and keeps the lowest trust (`agent-message`); the
    /// session kind is not a fallback. For a registered origin, `join` can only
    /// downgrade from `userTurn`, so a stale origin can never upgrade the
    /// session-derived source.
    private func memorySourceKind(for call: BotResolvedToolCall) -> BotMemorySourceKind {
        guard let origin = turnOrigins[call.sessionId] else { return .agentMessage }
        var state = BotMemorySourceState(kind: memorySource(call))
        state.join(origin.memorySource)
        return state.kind
    }

    private func updateMemory(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        let memory = memory(for: call.principal.botId)
        let action = string(args["action"]) ?? "write"
        let scope = BotMemoryScope(rawValue: string(args["scope"]) ?? "agent") ?? .agent
        switch action {
        case "write":
            guard let text = string(args["fact"]), !text.isEmpty else {
                throw BotMCPError.invalidRequest("UpdateMemory write requires fact")
            }
            let tier = BotMemoryTier(rawValue: string(args["tier"]) ?? "log") ?? .log
            let request = BotMemoryWriteRequest(
                text: text, tier: tier, scope: scope, key: string(args["key"]),
                source: BotMemorySource(
                    kind: memorySourceKind(for: call),
                    sessionID: call.principal.sessionId, turnID: turnIDs[call.sessionId],
                    role: call.principal.kind.rawValue))
            let result = try await memory.write(
                request, context: BotMemoryWriteContext(source: request.source))
            return .success(.object([
                "ok": .bool(result.ok), "fact_id": result.factID.map(BotJSONValue.string) ?? .null,
                "duplicated": .bool(result.duplicated), "tier": .string(result.tier.rawValue),
                "scope": .string(result.scope.rawValue), "count": .number(Double(result.count ?? 0)),
                "error": result.error.map(BotJSONValue.string) ?? .null,
            ]))
        case "forget":
            let result = try await memory.forget(text: string(args["fact"]), factID: string(args["fact_id"]), scope: scope)
            return .success(.object([
                "ok": .bool(result.ok), "removed": .number(Double(result.removed)),
                "removed_facts": .number(Double(result.removedFacts)),
                "fact_ids": .array(result.factIDs.map(BotJSONValue.string)),
                "count": .number(Double(result.count)), "scope": .string(result.scope.rawValue),
                "error": result.error.map(BotJSONValue.string) ?? .null,
            ]))
        default: throw BotMCPError.invalidRequest("UpdateMemory action must be write or forget")
        }
    }

    private func recallMemory(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        let memory = memory(for: call.principal.botId)
        let limit = try optionalInt(args["limit"]) ?? 40
        guard (1...50).contains(limit) else { throw BotMCPError.invalidRequest("RecallMemory limit must be 1…50") }
        let requestedScope = string(args["scope"]) ?? "all"
        guard ["agent", "user", "all"].contains(requestedScope) else {
            throw BotMCPError.invalidRequest("invalid memory scope")
        }
        // An explicit scope searches only that store with the full limit, as
        // upstream dshAgent.cjs does. Filtering the merged top-N afterwards
        // could return fewer hits than that scope actually has.
        let recallScope: BotMemoryScope?
        switch requestedScope {
        case "agent": recallScope = .agent
        case "user": recallScope = .user
        default: recallScope = nil
        }
        let hits = try await memory.recall(
            string(args["query"]) ?? "", limit: limit, scope: recallScope)
        return .success(.object([
            "ok": .bool(true), "facts": .array(try hits.map { try encode($0) }), "count": .number(Double(hits.count)),
        ]))
    }

    private func startTask(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard call.principal.kind == .chat || call.principal.kind == .task else {
            throw BotMCPError.invalidRequest("Task can only start from a chat or task session")
        }
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        guard args["task_id"] == nil, args["resume"] == nil else {
            throw BotMCPError.invalidRequest("Task resume is not implemented")
        }
        let title = firstNonEmpty(args["task_title"], args["description"]) ?? "Delegated task"
        guard let prompt = firstNonEmpty(args["prompt"], args["task_description"]), !prompt.isEmpty else {
            throw BotMCPError.invalidRequest("Task requires prompt or task_description")
        }
        let timeout = try optionalInt(args["timeout_ms"]) ?? 180_000
        guard (1_000...300_000).contains(timeout) else { throw BotMCPError.invalidRequest("Task timeout_ms must be 1000…300000") }
        let request = BotTaskRequest(
            parent: call, title: title, prompt: prompt,
            asynchronous: bool(args["async"]) ?? false, timeoutMs: timeout)
        let record = try await taskExecutor(for: call.principal.botId).start(request: request)
        // The production task executor persists `task.created` itself, before
        // it starts any work (BotDSHRemoteRuntime.start). Writing a second
        // event here would either race the durable snapshot or leave a crash
        // window with a running task that has no record.
        let taskPrincipal = BotGatewayPrincipal(
            botId: call.principal.botId, sessionId: record.sessionId, kind: .task,
            capabilities: call.principal.capabilities, expiresAt: call.principal.expiresAt)
        _ = try await eventWriter.append(type: "task.started", principal: taskPrincipal, data: record.jsonValue)
        if ["completed", "failed", "stopped"].contains(record.status) {
            _ = try await eventWriter.append(
                type: "task.settled", principal: taskPrincipal, data: record.jsonValue,
                eventId: "settled:\(record.taskId)")
        }
        return .success(record.jsonValue)
    }

    private func awaitTask(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments, let id = string(args["task_id"]), !id.isEmpty else {
            throw BotMCPError.invalidRequest("AwaitTask requires task_id")
        }
        let timeout = try optionalInt(args["timeout_ms"]) ?? 180_000
        guard (1_000...600_000).contains(timeout) else { throw BotMCPError.invalidRequest("AwaitTask timeout_ms must be 1000…600000") }
        let record = try await taskExecutor(for: call.principal.botId)
            .await(taskId: id, timeoutMs: timeout, parent: call)
        if ["completed", "failed", "stopped"].contains(record.status) {
            let principal = BotGatewayPrincipal(
                botId: call.principal.botId, sessionId: record.sessionId, kind: .task, expiresAt: Int64.max)
            _ = try await eventWriter.append(
                type: "task.settled", principal: principal, data: record.jsonValue,
                eventId: "settled:\(record.taskId)")
        }
        return .success(record.jsonValue)
    }

    private func stopTask(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments else { throw BotMCPError.invalidRequest("arguments must be an object") }
        guard let id = firstNonEmpty(args["task_id"], args["id"]), !id.isEmpty else {
            throw BotMCPError.invalidRequest("StopSubagent requires task_id")
        }
        let record = try await taskExecutor(for: call.principal.botId)
            .stop(taskId: id, parent: call)
        let principal = BotGatewayPrincipal(
            botId: call.principal.botId, sessionId: record.sessionId, kind: .task, expiresAt: Int64.max)
        _ = try await eventWriter.append(
            type: "task.stop_requested", principal: principal, data: record.jsonValue,
            eventId: "stop:\(record.taskId)")
        _ = try await eventWriter.append(
            type: "task.settled", principal: principal, data: record.jsonValue,
            eventId: "settled:\(record.taskId)")
        return .success(record.jsonValue)
    }

    private func updateRoutine(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        let result = try await BotRoutineTool.handle(
            machine: routineMachine, principal: call.principal, arguments: arguments, now: now())
        guard case .object(let args) = arguments, case .string(let action)? = args["action"] else {
            throw BotMCPError.invalidRequest("UpdateRoutine requires action")
        }
        if !["get", "list"].contains(action) {
            let type = action == "create" ? "routine.defined" : action == "delete" ? "routine.deleted" : "routine.updated"
            _ = try await eventWriter.append(type: type, principal: call.principal, data: result)
        }
        return .success(result)
    }

    private func requestApproval(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard case .object(let args) = arguments, let action = string(args["action"]), !action.isEmpty else {
            throw BotMCPError.invalidRequest("RequestApproval requires action")
        }
        let detail = string(args["detail"]) ?? ""
        let command = string(args["command"]) ?? ""
        let resource = BotResourceNormalizer.normalize("action=\(action)")
        var effects = command.isEmpty ? [] : BotApprovalPatternAnalyzer.effects(
            tool: "bash", arguments: .object(["command": .string(command)]),
            workspace: BotWorkspaceLayout.botRoot(botId: call.principal.botId))
        effects.append(BotToolEffect(
            tool: "RequestApproval", operation: "approval.weak-action", resource: resource,
            target: command.isEmpty ? resource : command, mutability: .destructive, policy: .ask,
            label: action, detail: detail, known: false, isMcp: true))
        let alwaysScope = effects.contains(where: \.known) ? "until" : "session"
        let outcome = await approvals.request(
            call: call, effects: effects, action: action, detail: detail,
            command: command, alwaysScope: alwaysScope)
        return .success(.object([
            "allowed": .bool(outcome.allowed), "decision": .string(outcome.allowed ? "allowed" : "denied"),
            "approvalId": outcome.approvalId.map(BotJSONValue.string) ?? .null,
            "message": outcome.message.map(BotJSONValue.string) ?? .null,
        ]))
    }

    private func sendToUser(_ arguments: BotJSONValue, call: BotResolvedToolCall) async throws -> BotMCPCallResult {
        guard call.principal.kind == .chat else { throw BotMCPError.invalidRequest("SendToUser is only available in the main chat") }
        guard !hiddenTextSessions.contains(call.sessionId), !suppressingTextSessions.contains(call.sessionId) else {
            throw BotMCPError.invalidRequest("Text output is suppressed for this turn")
        }
        guard case .object(let args) = arguments, let message = string(args["message"]), !message.isEmpty else {
            throw BotMCPError.invalidRequest("SendToUser requires message")
        }
        let rowId = "message-\(UUID().uuidString.lowercased())"
        _ = try await eventWriter.append(
            type: "ui.send_to_user", principal: call.principal,
            data: .object([
                "id": .string(rowId), "type": .string("text"), "role": .string("assistant"),
                "text": .string(message), "content": .string(message),
            ]))
        return .success(.object(["ok": .bool(true), "rowId": .string(rowId)]))
    }

    private func effectsForApproval(name: String, botID: String,
                                    arguments: BotJSONValue) async -> [BotToolEffect] {
        if name == BotToolCatalog.volatileContextName { return [] }
        let workspace = BotWorkspaceLayout.botRoot(botId: botID)
        if name == "bash" {
            return BotApprovalPatternAnalyzer.effects(
                tool: name, arguments: arguments, workspace: workspace)
        }
        if name == "write" || name == "edit" {
            // Inside the Bot workspace root the DSH file sandbox is the
            // boundary and no Bot approval card is needed. Outside it the
            // effect is the directory-granular `file.write`/`file.edit`.
            return BotEgressEffects.fileEffects(
                tool: name, arguments: arguments, workspaceRoot: workspace)
        }
        let effect = BotToolEffectClassifier.effect(for: name, arguments: arguments)
        return effect.mutability == .read || effect.ui || effect.policy == .auto ? [] : [effect]
    }

    private func encode<T: Encodable>(_ value: T) throws -> BotJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try BotJSONValue.parse(encoder.encode(value))
    }

    private func firstNonEmpty(_ values: BotJSONValue?...) -> String? {
        for value in values {
            if let text = string(value), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func bool(_ value: BotJSONValue?) -> Bool? {
        guard case .bool(let flag)? = value else { return nil }
        return flag
    }

    private func optionalInt(_ value: BotJSONValue?) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.isFinite, number.rounded() == number else {
            throw BotMCPError.invalidRequest("timeout/limit must be an integer")
        }
        return Int(number)
    }

    private func bareToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.components(separatedBy: "__").last ?? name
    }

    private func key(_ runtimeId: String, _ sessionId: String, _ callId: String) -> String {
        "\(runtimeId)\u{0}\(sessionId)\u{0}\(callId)"
    }

    private static func code(_ error: BotMCPError) -> String {
        switch error {
        case .invalidRequest: return "invalid_arguments"
        case .unauthorized: return "unauthorized"
        case .unknownTool: return "unknown_tool"
        case .unattributed: return "unattributed"
        case .crossSessionDenied: return "cross_session_read_denied"
        case .timeout: return "timeout"
        case .unavailable: return "unavailable"
        }
    }

    private static func message(_ error: BotMCPError) -> String {
        switch error {
        case .invalidRequest(let message), .unavailable(let message): return message
        case .unauthorized: return "Unauthorized"
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .unattributed: return "The call is not attributable"
        case .crossSessionDenied: return "The requested session is outside the caller's principal"
        case .timeout: return "The operation timed out"
        }
    }
}
