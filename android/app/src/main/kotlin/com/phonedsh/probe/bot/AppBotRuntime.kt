// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotApprovalDecision
import com.phonedsh.bot.authz.BotApprovalResolution
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.gateway.BotAttributionRegistry
import com.phonedsh.bot.gateway.BotIdentityRegistrationService
import com.phonedsh.bot.gateway.BotIdentityRegistrationRequest
import com.phonedsh.bot.gateway.BotTokenPrincipalPort
import com.phonedsh.bot.session.BotSessionTokenRegistry
import com.phonedsh.bot.mcp.BotAttributionPort
import com.phonedsh.bot.mcp.BotMCPHandler
import com.phonedsh.bot.mcp.BotNativeMCPForwarder
import com.phonedsh.bot.mcp.BotMCPToolRuntime
import com.phonedsh.bot.mcp.BotToolCatalog
import com.phonedsh.bot.mcp.BotVolatileContextProducer
import com.phonedsh.bot.mcp.BotDomainVolatileContextProvider
import com.phonedsh.bot.mcp.BotResolvedToolCall as McpResolvedToolCall
import com.phonedsh.bot.memory.BotMemory
import com.phonedsh.bot.memory.BotSqlMemoryDocumentStore
import com.phonedsh.bot.proactive.ProactiveSettings
import com.phonedsh.bot.proactive.ProactiveSettingsPersistence
import com.phonedsh.bot.proactive.ProactiveSettingsStore
import com.phonedsh.bot.routines.BotRoutineStore
import com.phonedsh.bot.routines.ImmediateRoutineRunner
import com.phonedsh.bot.routines.RoutineExecutionResult
import com.phonedsh.bot.routines.RoutineMachine
import com.phonedsh.bot.routines.RoutineQuietSettings
import com.phonedsh.bot.routines.RoutineResultSink
import com.phonedsh.bot.routines.RoutineScheduler
import com.phonedsh.bot.routines.RoutineAutomation
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.wake.BotWakeInboxStore
import com.phonedsh.bot.wake.WakeInbox
import com.phonedsh.engine.WorkerEnvironment
import com.phonedsh.loopback.BotMcpEndpoint
import com.phonedsh.loopback.BotMcpListener
import com.phonedsh.loopback.BotMcpRequest
import com.phonedsh.loopback.BotMcpRequestHandler
import com.phonedsh.loopback.BotMcpResponse
import com.phonedsh.loopback.BotMcpStartResult
import com.phonedsh.loopback.NativeMcpRequest
import com.phonedsh.loopback.NativeMcpServing
import com.phonedsh.probe.bot.store.AndroidBotSqlDriver
import com.phonedsh.ui.bot.driver.BotChatDriver
import com.phonedsh.ui.bot.state.BotDrawerIntent
import java.io.File
import java.nio.file.Path
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.atomic.AtomicBoolean

/** The small lifecycle seam the runtime test replaces with a fake server. */
interface AppBotMcpServer {
    val url: String?
    val endpoint: BotMcpEndpoint? get() = null
    fun start()
    fun stop()
}

/** The routine scheduler's foreground lifecycle, kept replaceable for tests. */
interface AppBotRoutineService {
    fun start()
    fun stop()
}

private class SchedulerRoutineService(
    private val scheduler: RoutineScheduler,
) : AppBotRoutineService {
    override fun start() = scheduler.start()
    override fun stop() = scheduler.stop()
}

/** Production Bot MCP listener, with failures logged and never thrown at the UI. */
class ListenerAppBotMcpServer(
    private val listener: BotMcpListener,
    private val logger: (String) -> Unit = { Log.i(TAG, it) },
) : AppBotMcpServer {
    @Volatile
    private var started = false

    override val endpoint: BotMcpEndpoint? get() = listener.endpoint()
    override val url: String? get() = endpoint?.mcpUrl()

    override fun start() {
        if (started) return
        when (val result = listener.start()) {
            is BotMcpStartResult.Started -> {
                started = true
                logger("bot mcp listening on ${result.endpoint.origin} (token redacted)")
            }
            is BotMcpStartResult.Failed -> {
                logger(
                    "bot mcp listener did not start on ${result.attemptedPorts}: " +
                        (result.cause.message ?: result.cause.javaClass.simpleName),
                )
            }
        }
    }

    override fun stop() {
        if (!started) return
        started = false
        listener.stop()
    }

    companion object {
        const val TAG: String = "AppBotRuntime"
    }
}

/** Android SharedPreferences implementation of P18's six-member settings blob. */
class SharedPreferencesProactiveSettingsStore(
    private val preferences: SharedPreferences,
    storageKey: String = "phone-dsh.bot.proactive-settings.v1",
) : ProactiveSettingsStore {
    override val key: String = storageKey

    override fun load(): ProactiveSettings {
        val raw = preferences.getString(key, null)
        val decoded = if (raw == null) null else runCatching { JsonValue.parse(raw) }.getOrNull()
        return ProactiveSettingsPersistence.decodeOrProductionDefault(decoded)
    }

    override fun save(settings: ProactiveSettings) {
        preferences.edit()
            .putString(key, ProactiveSettingsPersistence.encode(settings).toJsonString())
            .apply()
    }
}

/**
 * The App composition root for the Bot runtime: one P25 store, one memory
 * facade, one routine machine/scheduler, one token/grant/approval/attribution
 * stack and one MCP listener.
 *
 * Startup is best-effort by design. A store or listener failure is logged and
 * leaves the UI on the driver's durable rows; it never crashes the App. [start]
 * and [stop] are idempotent and follow the Activity's foreground/background.
 */
class AppBotRuntime internal constructor(
    val store: BotDomainStore,
    val driver: BotChatDriver,
    val roster: List<com.phonedsh.ui.bot.state.BotRosterEntry>,
    private val initialPlatform: BotPlatformConfig,
    val proactiveSettings: ProactiveSettingsStore,
    private val mcpServer: AppBotMcpServer,
    private val routines: AppBotRoutineService,
    private val logger: (String) -> Unit,
    private val rosterController: AppBotRosterController? = null,
) : AutoCloseable {
    private val running = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    val platformConfig: BotPlatformConfig get() = platformState?.value ?: initialPlatform
    val platformState: StateFlow<BotPlatformConfig>? get() = rosterController?.state

    fun handleDrawer(intent: BotDrawerIntent) {
        rosterController?.apply(intent)
    }

    val mcpUrl: String? get() = mcpServer.url
    val mcpEndpoint: BotMcpEndpoint? get() = mcpServer.endpoint

    /** The Worker env keys for this listener; empty until it publishes a URL. */
    fun workerEnvironment(): Map<String, String> {
        if (!running.get()) return emptyMap()
        val url = mcpServer.url ?: return emptyMap()
        return linkedMapOf(
            WorkerEnvironment.PHONE_MCP_URL to url,
            WorkerEnvironment.PHONE_MCP_TOKEN to WorkerEnvironment.BOT_MCP_TOKEN_PLACEHOLDER,
        )
    }

    fun start() {
        if (closed.get() || !running.compareAndSet(false, true)) return
        runCatching { mcpServer.start() }
            .onFailure { logger("bot mcp start failed: ${it.message}") }
        runCatching { routines.start() }
            .onFailure { logger("routine scheduler start failed: ${it.message}") }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { routines.stop() }
        runCatching { mcpServer.stop() }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        stop()
        runCatching { mcpServer.stop() }
        if (rosterController != null) runCatching(rosterController::close)
        else runCatching { (driver as? AutoCloseable)?.close() }
        runCatching { store.close() }
    }

    companion object {
        /**
         * Builds the production runtime. [transport] is the same ordered
         * HostChannel adapter the chat lane uses; a null transport still builds
         * the durable/MCP half, and the driver records a notice instead of a
         * turn. Any construction failure returns null (the Bot tab is absent).
         */
        fun create(
            context: Context,
            transport: BotSessionTransport,
            logger: (String) -> Unit = { Log.i(ListenerAppBotMcpServer.TAG, it) },
            clock: () -> Long = { System.currentTimeMillis() },
            nativeMcp: NativeMcpServing? = null,
            nativeAdmission: () -> Boolean = { true },
            materializedSessions: Path? = null,
        ): AppBotRuntime? = runCatching {
            build(context, transport, logger, clock, nativeMcp, nativeAdmission, materializedSessions)
        }.onFailure { error ->
            Log.w(
                ListenerAppBotMcpServer.TAG,
                "Bot runtime unavailable: ${error.javaClass.simpleName}: ${error.message}",
            )
        }.getOrNull()

        private fun build(
            context: Context,
            transport: BotSessionTransport,
            logger: (String) -> Unit,
            clock: () -> Long,
            nativeMcp: NativeMcpServing?,
            nativeAdmission: () -> Boolean,
            materializedSessions: Path?,
        ): AppBotRuntime {
            val store = BotDomainStore(AndroidBotSqlDriver.open(context))
            val botId = AppBotRoster.DEFAULT_BOT_ID
            val profileStore = AppBotProfileStore(File(context.filesDir, "PhoneDSHBot"), clock)
            val preferences = context.getSharedPreferences("phone-dsh-bot", Context.MODE_PRIVATE)
            val proactiveSettings = SharedPreferencesProactiveSettingsStore(preferences)
            runCatching { proactiveSettings.load() }
                .onFailure { logger("proactive settings load failed: ${it.message}") }
            val memory = BotMemory(
                store = BotSqlMemoryDocumentStore.forDomainStore(store, botId, clock),
                botId = botId,
                now = clock,
            )
            val routineStore = BotRoutineStore(store, clock)
            val routineMachine = RoutineMachine(routineStore)
            val wakeInbox = WakeInbox(BotWakeInboxStore(store, clock), botId)
            val scheduler = RoutineScheduler(
                botId = botId,
                machine = routineMachine,
                inbox = wakeInbox,
                sink = object : RoutineResultSink {
                    override fun deliver(automation: RoutineAutomation): Boolean = false
                },
                runner = ImmediateRoutineRunner {
                    RoutineExecutionResult.failure(
                        "routine execution runner is not connected in this build",
                    )
                },
                settingsProvider = {
                    val settings = proactiveSettings.load().normalized()
                    RoutineQuietSettings(
                        mode = settings.mode.wire,
                        dnd = settings.dnd,
                        quietStart = settings.quietStart,
                        quietEnd = settings.quietEnd,
                        routineQuietWeekends = settings.routineQuietWeekends,
                        timeZone = settings.timeZone,
                    )
                },
                clock = clock,
            )

            val memoryLookup = AppBotMemoryLookup(memory, clock)
            val routineLookup = AppBotRoutineLookup(routineMachine, clock)
            val sessionTokens = BotSessionTokenRegistry(now = clock)
            val tokens: BotTokenPrincipalPort = AppBotSessionPrincipals(sessionTokens)
            val storeLock = Any()
            val grantLog = AppBotAuthzEventLog(store, AppBotAuthzEventLog.GRANT_TYPES, clock, storeLock)
            var notifyBotChanged: (String?) -> Unit = {}
            val approvalLog = AppBotAuthzEventLog(store, AppBotAuthzEventLog.APPROVAL_TYPES, clock, storeLock) {
                notifyBotChanged(it)
            }
            val grantStore = BotGrantStore(grantLog, clock)
            runCatching { grantStore.recover() }
                .onFailure { logger("bot grant recovery failed: ${it.message}") }
            val attribution = BotAttributionRegistry(clock)
            val approvals = BotApprovalCoordinator(grantStore, approvalLog, clock)
            val identity = BotIdentityRegistrationService(
                tokens = tokens,
                attributions = attribution,
                approvals = approvals,
                now = clock,
            )
            val tokenPort = AppBotTokenPrincipalPort(tokens)
            val attributionPort = object : BotAttributionPort {
                override suspend fun claim(
                    runtimeId: String,
                    name: String,
                    arguments: JsonValue,
                ): McpResolvedToolCall? {
                    val call = identity.claim(runtimeId, name, arguments) ?: return null
                    return McpResolvedToolCall(
                        principal = call.principal.toMcp(),
                        callId = call.callId,
                        attributionId = call.attribution.id,
                    )
                }
            }
            val events = AppBotMCPEventSink(store, clock)
            val userMessages = AppBotUserMessagePort(store, events, clock)
            val volatile = BotVolatileContextProducer(
                BotDomainVolatileContextProvider(
                    memory = memoryLookup,
                    routines = routineLookup,
                    persona = { id, _, _ ->
                        val name = profileStore.read().bots.firstOrNull { it.id == id }?.name
                            ?: AppBotRoster.DEFAULT_BOT_NAME
                        "你的名字是${name}。用户问起名字时如实回答。"
                    },
                    now = clock,
                ),
            )
            val catalog = loadCatalog(context, logger)
            val toolRuntime = BotMCPToolRuntime(
                catalogProvider = catalog,
                attribution = attributionPort,
                volatileContext = volatile,
                memory = memoryLookup,
                routines = routineLookup,
                tasks = AppBotTaskPort,
                userMessages = userMessages,
                grants = AppBotGrantPort(grantStore, clock),
                modelImageReader = AppBotModelImageReader(context),
                team = AppBotTeamStub(),
                events = events,
                runtimeId = BotMCPProtocolRuntimeId,
                now = clock,
            )
            val mcpHandler = BotMCPHandler(
                catalog = catalog,
                tools = toolRuntime,
                tokens = tokenPort,
            )
            if (nativeMcp != null) mcpHandler.attachNativeMCP(object : BotNativeMCPForwarder {
                override suspend fun handle(request: JsonValue, headers: Map<String, String>): JsonValue? {
                    val rpc = request as? JsonObject
                    if (rpc?.get("method") == JsonString("tools/call") && !nativeAdmission()) {
                        return BotJson.objectOf(
                            "jsonrpc" to JsonString("2.0"),
                            "id" to (rpc["id"] ?: com.phonedsh.agentcore.JsonNull),
                            "error" to BotJson.objectOf(
                                "code" to com.phonedsh.agentcore.JsonNumber("-32000"),
                                "message" to JsonString("phone tool admission is closed"),
                            ),
                        )
                    }
                    val result = nativeMcp.handle(NativeMcpRequest(
                        "POST", headers, request.toJsonString().toByteArray(Charsets.UTF_8),
                    ))
                    return result.body.takeIf { it.isNotEmpty() }
                        ?.let { JsonValue.parse(it.toString(Charsets.UTF_8)) }
                }
            })
            val httpHandler = AppBotMcpHttpHandler(
                handler = mcpHandler,
                identity = identity,
                approvals = approvals,
                runtimeId = BotMCPProtocolRuntimeId,
            )
            val listener = BotMcpListener(httpHandler)
            val mcpServer = ListenerAppBotMcpServer(listener, logger)
            val rosterController = AppBotRosterController(profileStore, clock, preferences) { selectedId ->
                AppBotChatDriver(
                    store = store,
                    transport = transport,
                    botId = selectedId,
                    clock = clock,
                    tokens = sessionTokens,
                    storeLock = storeLock,
                    materializedSessions = materializedSessions,
                    resolveApproval = { action ->
                        val id = checkNotNull(action.approvalID)
                        val decision = checkNotNull(BotApprovalDecision.fromWire(checkNotNull(action.decision).wire))
                        when (val result = approvals.resolve(id, decision, action.digest.orEmpty())) {
                            BotApprovalResolution.Resolved -> BotActionResult.Accepted(id)
                            is BotApprovalResolution.Stale -> BotActionResult.Rejected(result.reason)
                        }
                    },
                    onTurnBoundary = { id, starting ->
                        if (starting) toolRuntime.beginTurn(id) else toolRuntime.endTurn(id)
                    },
                )
            }
            notifyBotChanged = rosterController::domainChanged
            val platform = rosterController.state.value
            return AppBotRuntime(
                store = store,
                driver = platform.driver,
                roster = platform.roster,
                initialPlatform = platform,
                proactiveSettings = proactiveSettings,
                mcpServer = mcpServer,
                routines = SchedulerRoutineService(scheduler),
                logger = logger,
                rosterController = rosterController,
            )
        }

        private const val BotMCPProtocolRuntimeId: String = "phone-worker"

        private fun loadCatalog(context: Context, logger: (String) -> Unit): BotToolCatalog = try {
            val upstream = readAsset(context, "bot/tool-catalog.json")
            val phone = readAsset(context, "bot/tool-catalog.phone.json")
            BotToolCatalog.fromGolden(upstream, phone)
        } catch (error: Exception) {
            logger("bot tool catalog unavailable: ${error.message}")
            BotToolCatalog.fromDefinitions(emptyList())
        }

        private fun readAsset(context: Context, name: String): JsonValue =
            context.assets.open(name).bufferedReader(Charsets.UTF_8).use { reader ->
                JsonValue.parse(reader.readText())
            }
    }
}

/** The App's HTTP/report handler over the B5a1 dispatcher and the authz stack. */
class AppBotMcpHttpHandler(
    private val handler: BotMCPHandler,
    private val identity: BotIdentityRegistrationService,
    private val approvals: BotApprovalCoordinator,
    private val runtimeId: String,
) : BotMcpRequestHandler {
    override val mcpSessionId: String get() = handler.mcpSessionId

    override suspend fun handle(request: BotMcpRequest): BotMcpResponse {
        val body = runCatching { JsonValue.parse(request.bodyText()) }.getOrNull()
        return when (request.path) {
            "/mcp" -> {
                if (body == null) return json(400, BotJson.objectOf(
                    "error" to JsonString("invalid JSON"),
                ))
                val result = handler.dispatch(body)
                val value = result.body
                if (value == null) {
                    BotMcpResponse.Json(status = result.status, body = ByteArray(0))
                } else {
                    json(result.status, value)
                }
            }
            "/identity/register" -> {
                val objectBody = body as? JsonObject
                val parsed = objectBody?.let { BotIdentityRegistrationRequest.fromJson(it) }
                if (parsed == null) {
                    json(200, BotJson.objectOf(
                        "ok" to JsonBool(false),
                        "error" to JsonString("invalid identity registration"),
                    ))
                } else {
                    json(200, identity.register(parsed).toJson())
                }
            }
            "/identity/cancel" -> {
                val id = ((body as? JsonObject)?.members?.get("id") as? JsonString)?.value.orEmpty()
                json(200, BotJson.objectOf(
                    "ok" to JsonBool(identity.cancel(id)),
                ))
            }
            "/approval" -> {
                val objectBody = body as? JsonObject
                    ?: return json(200, BotJson.objectOf(
                        "ok" to JsonBool(false),
                        "allowed" to JsonBool(false),
                        "pending" to JsonBool(false),
                    ))
                val parsed = com.phonedsh.bot.authz.BotApprovalRequest.parse(objectBody)
                val outcome = if (parsed == null) {
                    com.phonedsh.bot.authz.BotApprovalOutcome(
                        ok = false,
                        allowed = false,
                        pending = false,
                        message = "invalid approval request",
                    )
                } else {
                    approvals.approve(parsed, runtimeId, identity)
                }
                json(200, outcome.toJson())
            }
            else -> json(404, BotJson.objectOf(
                "error" to JsonString("not found"),
            ))
        }
    }

    private fun json(status: Int, value: JsonValue): BotMcpResponse =
        BotMcpResponse.Json(status, value.toJsonString().toByteArray(Charsets.UTF_8))
}
