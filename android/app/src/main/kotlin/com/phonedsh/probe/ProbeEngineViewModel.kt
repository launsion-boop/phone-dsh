// The composition root: the one place :app names both the engine and the host.
// SPDX-License-Identifier: MIT
// It constructs DefaultPhoneDshHost, hands its channelHandler to createDemoEngine
// and forwards start/stop. The screen stays a pure function of the engine's flows.
package com.phonedsh.probe

import com.phonedsh.account.TonoAccountKeySource
import android.app.Application
import android.net.Uri
import android.os.PowerManager
import android.provider.OpenableColumns
import android.util.Log
import android.view.View
import android.webkit.WebView
import androidx.lifecycle.AndroidViewModel
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.controller.Admission
import com.phonedsh.controller.ControllerBudgets
import com.phonedsh.controller.ControllerFailure
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.exec.FileRequestLedger
import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecRequest
import com.phonedsh.dsh.exec.ExecTier
import com.phonedsh.dsh.exec.StdinSpec
import com.phonedsh.dsh.host.DefaultPhoneDshHost
import com.phonedsh.dsh.host.HostApiException
import com.phonedsh.dsh.host.HostBudgetTier
import com.phonedsh.dsh.host.HostExec
import com.phonedsh.dsh.host.ShellAcceleratorTool
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.HostStateStore
import com.phonedsh.dsh.host.ModelRoute
import com.phonedsh.dsh.host.ModelRouteFact
import com.phonedsh.dsh.host.asHostWal
import com.phonedsh.dsh.localexec.UbuntuSessionFactory
import com.phonedsh.domain.DomainStore
import com.phonedsh.domain.DomainStoreCore
import com.phonedsh.domain.QuotaPolicy
import com.phonedsh.domain.device.AndroidDeviceCapabilities
import com.phonedsh.domain.device.AndroidHostPermissions
import com.phonedsh.domain.session.ArchivedCommand
import com.phonedsh.domain.session.ArchivedTurn
import com.phonedsh.domain.session.ArchivedWrite
import com.phonedsh.domain.session.SessionArchive
import com.phonedsh.domain.sqlite.SqliteConnectionFactory
import com.phonedsh.dsh.journal.JournalException
import com.phonedsh.dsh.journal.JournalPaths
import com.phonedsh.dsh.journal.JournalStore
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.engine.AndroidEngineLogger
import com.phonedsh.engine.ApkWorkerAssetSource
import com.phonedsh.engine.BootOverlaySource
import com.phonedsh.engine.ChannelStatus
import com.phonedsh.engine.DemoEngine
import com.phonedsh.engine.EngineLogger
import com.phonedsh.engine.EngineState
import com.phonedsh.engine.HandshakeSummary
import com.phonedsh.engine.MaterializedBootOverlaySource
import com.phonedsh.engine.WorkerAssets
import com.phonedsh.engine.WebViewKernelReport
import com.phonedsh.engine.createDemoEngine
import com.phonedsh.engine.info
import com.phonedsh.gateway.AllowListEgressPolicy
import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.CredentialUnavailableException
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayHttpEgress
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.gateway.HttpUrlConnectionGatewayTransport
import com.phonedsh.gateway.ModelKeySource
import com.phonedsh.gateway.IndependentSearchWebToolsEgress
import com.phonedsh.gateway.OfficialDeepSeekWebToolsEgress
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import com.phonedsh.log.MutationBody
import com.phonedsh.log.VfsOp
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.surface.preview.WorkspacePreviewSource
import com.phonedsh.ui.nav.confirms
import com.phonedsh.ui.state.ChatAttachment
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.CommandOutcome
import com.phonedsh.ui.state.ManagedQueueItemState
import com.phonedsh.ui.state.QueueAction
import com.phonedsh.ui.state.QueueActionReceipt
import com.phonedsh.ui.state.QueueItemId
import com.phonedsh.ui.state.QueueItemStatus
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.retireQueuePromptsPresentIn
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackModelProxy
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.NotificationAction
import com.phonedsh.platform.Notifier
import com.phonedsh.platform.NotifierAvailability
import com.phonedsh.platform.android.AndroidClock
import com.phonedsh.platform.android.AndroidDurability
import com.phonedsh.platform.android.AndroidLifecycleSignals
import com.phonedsh.platform.android.ProotRuntime
import com.phonedsh.platform.android.UbuntuRootfsStore
import com.phonedsh.probe.bot.AppBotRuntime
import com.phonedsh.probe.bot.BotPlatformConfig
import com.phonedsh.probe.bot.DshBotSessionTransport
import com.phonedsh.probe.pc.PcLinkWorkspace
import com.phonedsh.probe.pc.PcWorkspaceController
import com.phonedsh.shell.AcceleratorMount
import com.phonedsh.shell.AcceleratorLimits
import com.phonedsh.ui.page.ShellLimits
import com.phonedsh.ui.page.ShellRun
import com.phonedsh.ui.page.ShellSnapshot
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.ChatSubagentEntry
import com.phonedsh.ui.page.AgentPresetReadOutcome
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.ConfigurationFacts
import com.phonedsh.ui.page.ConfigurationFieldKind
import com.phonedsh.ui.page.ConfigurationWriteReceipt
import com.phonedsh.ui.page.FactState
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.util.UUID

private data class SubagentHistoryPage(
    val nodes: List<UiStateNode>,
    val window: SubagentTranscriptWindow,
)

private class SubagentHistoryReadFailure(message: String, val terminalPagination: Boolean = false) : Exception(message)

private fun mergeSubagentHistory(
    existing: List<UiStateNode>,
    refreshed: List<UiStateNode>,
): List<UiStateNode> = (existing + refreshed)
    .distinctBy(UiStateNode::nodeID)
    .sortedWith(compareBy<UiStateNode> { it.seq }.thenBy { it.nodeID })

/**
 * The stop transaction: one atomic state update and one call to the App's
 * existing `persistChat` writer.
 *
 * The writer is injected so the JVM suite can drive this production object with
 * a real [ChatSessionStore], while the ViewModel passes its one `persistChat`
 * method. There is deliberately no second persistence implementation here: the
 * other chat lane's metadata fixes must reach stop as well.
 *
 * Resetting `turnRunning` is what lets the very next send pass `submitChat`'s
 * in-flight check; the worker session id is left untouched.
 */
internal class ChatStopWiring(
    private val chat: MutableStateFlow<ChatUiState>,
    private val turnRunning: AtomicBoolean,
    private val persist: (String) -> Unit,
) {
    fun stop(chatId: String, atMs: Long): ChatUiState {
        chat.update { live ->
            if (live.chatId != chatId) {
                live
            } else {
                turnRunning.set(false)
                if (live.running) live.markStopped(atMs) else live
            }
        }
        val stopped = chat.value
        persist(chatId)
        return stopped
    }
}

/**
 * The stored-record repair shared by `openChatSession` and
 * `restoreChatSessions`.
 *
 * The repair is synchronous and touches disk, so callers run it on their IO
 * dispatcher. [restore] keeps one bad row from discarding the rest of the list.
 */
internal class ChatRecordRepair(private val store: ChatSessionStore) {
    fun open(record: ChatRecord, liveChatId: String, turnRunning: Boolean): ChatRecord =
        store.repairStaleChatTurns(record, liveTurn = turnRunning && liveChatId == record.id)

    fun restore(
        records: List<ChatRecord>,
        liveChatId: String,
        turnRunning: Boolean,
        onFailure: (ChatRecord, Throwable) -> Unit = { _, _ -> },
    ): List<ChatRecord> = records.map { record ->
        try {
            open(record, liveChatId, turnRunning)
        } catch (failure: Throwable) {
            onFailure(record, failure)
            record
        }
    }
}

/** The prompt the Worker receives: the typed text plus the workspace paths. */
internal fun composeChatPrompt(typed: String, attachments: List<ChatAttachment>): String {
    val references = attachments.mapNotNull { it.path }
    if (references.isEmpty()) return typed
    val block = buildString {
        append("已附加的文件（工作区路径，可用工具读取）：")
        references.forEach { append('\n').append("- ").append(it) }
    }
    return listOf(typed, block).filter { it.isNotBlank() }.joinToString("\n\n")
}

/**
 * The durable queue RPC seam behind [ChatQueueActions].
 *
 * Production binds one [DshTurnClient]; tests bind a scripted inbox so every
 * assertion can be made against the real state transition rather than a mock
 * invocation.
 */
internal interface ChatQueueTransport {
    suspend fun updateQueue(
        workerSessionId: String,
        itemId: String,
        action: QueueAction,
        replacement: String?,
    )

    suspend fun readQueue(workerSessionId: String): List<ManagedQueueItemState>

    suspend fun prompt(workerSessionId: String, text: String, requestId: String, mode: String)
}

private const val QUEUE_ITEM_NOT_FOUND = "session/queue-item-not-found"
private const val QUEUE_STEER_UNAVAILABLE = "session/steer-unavailable"

/** The action RPC failed; [rows] is the fresh inbox when the read-back succeeded. */
private class QueueActionFailure(
    val error: Exception,
    val rows: List<ManagedQueueItemState>?,
) : Exception(error)

private val STEER_SILENT_FAILURES = setOf(QUEUE_STEER_UNAVAILABLE, QUEUE_ITEM_NOT_FOUND)

/**
 * The queue half of the chat ViewModel: the one place that owns the optimistic
 * action marker, the `session/updateQueue` transaction, its projection read-back
 * and the local SENDING echo.
 *
 * It is a plain object over the same [MutableStateFlow] the ViewModel publishes
 * so the JVM suite drives the production transitions through
 * [ChatQueueTransport]; the ViewModel methods are thin bindings to this class.
 */
internal class ChatQueueActions(
    private val chat: MutableStateFlow<ChatUiState>,
    private val scope: CoroutineScope,
    private val transport: ChatQueueTransport,
    private val refresh: () -> Unit = {},
    private val log: (String) -> Unit = {},
) {
    /** Mutate one durable DSH queue item, then read the projection back before publishing success. */
    fun updateQueueItem(
        item: ManagedQueueItemState,
        action: QueueAction,
        requestId: StateRequestId,
        replacement: String? = null,
    ): Boolean {
        val current = chat.value
        val worker = current.workerSessionId ?: return false
        val itemId = (item.id as? QueueItemId.Durable)?.value ?: return false
        if (action == QueueAction.QUEUE) return false
        if (current.chatId.isBlank() || item.actionRequestId != null && item.busy == true) return false
        if (item.canEdit != true && action == QueueAction.EDIT) return false
        if (item.canRemove != true && action == QueueAction.REMOVE) return false
        if (item.canSteer != true && action == QueueAction.STEER) return false
        if (action == QueueAction.EDIT && replacement.isNullOrBlank()) return false
        val appChatId = current.chatId
        val activeItems = current.sessionSnapshot.queueItems ?: return false
        if (activeItems.none { (it.id as? QueueItemId.Durable)?.value == itemId }) return false

        chat.update { live ->
            if (live.chatId != appChatId || live.workerSessionId != worker) live else live.copy(
                sessionSnapshot = live.sessionSnapshot.copy(
                    queueItems = activeItems.map { row ->
                        if ((row.id as? QueueItemId.Durable)?.value == itemId) {
                            row.copy(busy = true, actionRequestId = requestId, receipt = null)
                        } else row
                    },
                ),
            )
        }
        scope.launch {
            val outcome = try {
                Result.success(run {
                    transport.updateQueue(worker, itemId, action, replacement)
                    val rows = transport.readQueue(worker)
                    val updated = rows.firstOrNull { (it.id as? QueueItemId.Durable)?.value == itemId }
                    val confirmed = when (action) {
                        QueueAction.QUEUE -> false
                        QueueAction.EDIT -> updated?.text == replacement
                        QueueAction.REMOVE -> updated == null
                        QueueAction.STEER -> updated == null || updated.lane != item.lane
                    }
                    check(confirmed) { "queue action was not reflected by the refreshed inbox" }
                    rows
                })
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                // A failed mutation is not a reason to republish the snapshot
                // captured before the RPC: rows may have been claimed, removed or
                // added while it ran. Read the inbox again and fall back to the
                // *current* state only when that read also fails.
                val freshRows = try {
                    transport.readQueue(worker)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (readFailure: Exception) {
                    log("CHAT_QUEUE_READBACK_FAILED reason=${readFailure.message?.substringBefore('\n')}")
                    null
                }
                Result.failure(QueueActionFailure(failure, freshRows))
            }
            chat.update { live ->
                if (live.chatId != appChatId || live.workerSessionId != worker) return@update live
                val rows = outcome.getOrNull()
                if (rows != null) {
                    val successReceipt = QueueActionReceipt(
                        requestId = requestId,
                        action = action,
                        outcome = CommandOutcome.SUCCEEDED,
                        sessionId = worker,
                        itemId = itemId,
                    )
                    live.copy(sessionSnapshot = live.sessionSnapshot.copy(
                        queueItems = when (action) {
                            QueueAction.QUEUE -> rows
                            QueueAction.REMOVE -> rows
                            else -> rows.map { row ->
                                if ((row.id as? QueueItemId.Durable)?.value == itemId) {
                                    row.copy(busy = false, actionRequestId = requestId, receipt = successReceipt)
                                } else row
                            }
                        },
                    ))
                } else {
                    val failed = outcome.exceptionOrNull()
                    val failure = (failed as? QueueActionFailure)?.error ?: failed
                    val code = (failure as? DshTurnException)?.code
                    val stillThere = live.sessionSnapshot.queueItems
                    val measured = (failed as? QueueActionFailure)?.rows ?: stillThere
                    if (measured == null) return@update live
                    val targetGone = code == QUEUE_ITEM_NOT_FOUND
                    // DSH's client silently converges steer-unavailable and
                    // queue-item-not-found; only a real edit/remove failure keeps
                    // a visible receipt on a row that is still in the inbox.
                    val silentSteerFailure = action == QueueAction.STEER &&
                        code in STEER_SILENT_FAILURES
                    if (!silentSteerFailure && !targetGone) {
                        log("CHAT_QUEUE_ACTION_FAILED action=$action code=${code ?: "-"}")
                    }
                    val failureReceipt = QueueActionReceipt(
                        requestId = requestId,
                        action = action,
                        outcome = CommandOutcome.FAILED,
                        message = failure?.message?.substringBefore('\n')?.take(180) ?: "队列操作未确认",
                        sessionId = worker,
                        itemId = itemId,
                    )
                    val nextRows = when {
                        targetGone -> measured.filterNot {
                            (it.id as? QueueItemId.Durable)?.value == itemId
                        }
                        silentSteerFailure -> measured.map { row ->
                            if ((row.id as? QueueItemId.Durable)?.value == itemId) {
                                row.copy(busy = false, actionRequestId = null, receipt = null)
                            } else row
                        }
                        else -> measured.map { row ->
                            if ((row.id as? QueueItemId.Durable)?.value == itemId) {
                                row.copy(busy = false, actionRequestId = requestId, receipt = failureReceipt)
                            } else row
                        }
                    }
                    live.copy(sessionSnapshot = live.sessionSnapshot.copy(queueItems = nextRows))
                }
            }
        }
        return true
    }

    /** Queue or steer a new user submission to the exact live Worker session. */
    fun submitWhileRunning(
        workerSessionId: String,
        requestId: StateRequestId,
        text: String,
        mode: com.phonedsh.ui.state.EnterMode,
    ): Boolean {
        val current = chat.value
        val trimmed = text.trim()
        if (workerSessionId.isBlank() || current.workerSessionId != workerSessionId || !current.running ||
            trimmed.isEmpty() || (mode == com.phonedsh.ui.state.EnterMode.STEER && current.attachments.isNotEmpty())
        ) return false
        // A retry of an ambiguous busy submission reuses its own backend prompt
        // identity. Matching by text would conflate duplicate messages.
        val promptRequestId = current.retryBusyPromptRequestId
            ?: StateRequestId("pdsh-prompt-" + java.util.UUID.randomUUID().toString())
        val existing = current.localQueueItems.firstOrNull { it.promptRequestId == promptRequestId }
        val localId = existing?.id ?: QueueItemId.Local(promptRequestId.value)
        val localItemId = (localId as? QueueItemId.Local)?.value ?: return false
        val queueAction = if (mode == com.phonedsh.ui.state.EnterMode.STEER) QueueAction.STEER else QueueAction.QUEUE
        val localItem = ManagedQueueItemState(
            id = localId,
            text = trimmed,
            sessionId = workerSessionId,
            lane = if (mode == com.phonedsh.ui.state.EnterMode.STEER) "steered" else "next-turn",
            state = if (mode == com.phonedsh.ui.state.EnterMode.STEER) QueueItemStatus.STEERED else QueueItemStatus.SENDING,
            canEdit = false,
            canRemove = false,
            canSteer = false,
            busy = true,
            actionRequestId = requestId,
            promptRequestId = promptRequestId,
        )
        val attachments = current.attachments
        val prompt = composeChatPrompt(trimmed, attachments)
        chat.update { live ->
            if (live.chatId != current.chatId || live.workerSessionId != workerSessionId || !live.running) live else {
                live.copy(
                    localQueueItems = live.localQueueItems.filterNot { it.id == localId } + localItem,
                    retryBusyPromptRequestId = null,
                )
            }
        }
        scope.launch {
            try {
                transport.prompt(
                    workerSessionId = workerSessionId,
                    text = prompt,
                    requestId = promptRequestId.value,
                    mode = if (mode == com.phonedsh.ui.state.EnterMode.STEER) "steer" else "queue",
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                // The prompt did not return success. Keep the echo visible as a
                // failed row (not a SENDING spinner), and retain its identity so a
                // retry reuses the same rpcId instead of posting a duplicate.
                log("CHAT_QUEUE_PROMPT_FAILED reason=${failure.message?.substringBefore('\n')}")
                chat.update { live ->
                    if (live.chatId != current.chatId || live.workerSessionId != workerSessionId) live else live.copy(
                        localQueueItems = live.localQueueItems.map { item ->
                            if (item.id == localId && item.actionRequestId == requestId) item.copy(
                                // SENDING rows live in the spinner-only slot; a
                                // failed submission must move to the actionable dock
                                // where its receipt is rendered.
                                state = if (item.state == QueueItemStatus.SENDING) {
                                    QueueItemStatus.QUEUED
                                } else {
                                    item.state
                                },
                                busy = false,
                                receipt = QueueActionReceipt(
                                    requestId = requestId,
                                    action = queueAction,
                                    outcome = CommandOutcome.FAILED,
                                    message = failure.message?.substringBefore('\n')?.take(180) ?: "请求结果未确认",
                                    sessionId = workerSessionId,
                                    itemId = localItemId,
                                ),
                            ) else item
                        },
                        retryBusyPromptRequestId = promptRequestId.takeIf {
                            live.draft.trim() == trimmed && live.attachments == attachments
                        },
                    )
                }
                // The prompt may have been accepted before the response was lost.
                // A fresh projection then supplies the durable row whose
                // source.rpcId retires this echo at the page boundary.
                refresh()
                return@launch
            }

            // The successful prompt RPC acknowledges this exact request ID. Retire
            // the local echo now: a projection read-back is a separate, best-effort
            // refresh and must never turn an accepted prompt into a spinner.
            chat.update { live ->
                if (live.chatId != current.chatId || live.workerSessionId != workerSessionId) live else {
                    live.copy(
                        draft = if (live.draft.trim() == trimmed) "" else live.draft,
                        attachments = if (live.attachments == attachments) emptyList() else live.attachments,
                        lastSubmission = trimmed,
                        lastAttachments = attachments,
                        localQueueItems = com.phonedsh.ui.state.retireAcceptedQueuePrompt(
                            live.localQueueItems,
                            promptRequestId,
                        ),
                        retryBusyPromptRequestId = null,
                    )
                }
            }
            val after = try {
                transport.readQueue(workerSessionId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                log("CHAT_QUEUE_PROMPT_READBACK_FAILED reason=${failure.message?.substringBefore('\n')}")
                null
            }
            if (after != null) {
                chat.update { live ->
                    if (live.chatId != current.chatId || live.workerSessionId != workerSessionId) live else {
                        live.copy(
                            sessionSnapshot = live.sessionSnapshot.copy(queueItems = after),
                            localQueueItems = retireQueuePromptsPresentIn(live.localQueueItems, after),
                        )
                    }
                }
            }
            refresh()
        }
        return true
    }
}

/** Production binding of [ChatQueueTransport] to the one live Worker channel. */
private class DshChatQueueTransport(
    channel: com.phonedsh.dsh.host.HostChannel,
    log: (String) -> Unit,
) : ChatQueueTransport {
    private val client = DshTurnClient(channel, log)

    override suspend fun updateQueue(
        workerSessionId: String,
        itemId: String,
        action: QueueAction,
        replacement: String?,
    ) {
        val actionValue = when (action) {
            QueueAction.QUEUE -> error("new queue submissions use session/prompt")
            QueueAction.EDIT -> JsonObject(linkedMapOf(
                "kind" to JsonString("edit"),
                "content" to JsonArray(listOf(JsonObject(mapOf(
                    "type" to JsonString("text"),
                    "text" to JsonString(requireNotNull(replacement)),
                )))),
            ))
            QueueAction.REMOVE -> JsonObject(mapOf("kind" to JsonString("remove")))
            QueueAction.STEER -> JsonObject(mapOf("kind" to JsonString("steer")))
        }
        client.call("session/updateQueue", JsonObject(mapOf("request" to JsonObject(mapOf(
            "sessionId" to JsonString(workerSessionId),
            "itemId" to JsonString(itemId),
            "action" to actionValue,
        )))))
    }

    override suspend fun readQueue(workerSessionId: String): List<ManagedQueueItemState> =
        sessionSnapshotOf(
            client.call("session/projections", JsonObject(mapOf(
                "request" to JsonObject(mapOf("sessionId" to JsonString(workerSessionId))),
            ))),
            catalog = null,
            commandCatalog = null,
            sessionId = workerSessionId,
        ).queueItems ?: error("inbox projection unavailable")

    override suspend fun prompt(workerSessionId: String, text: String, requestId: String, mode: String) {
        client.prompt(sessionId = workerSessionId, text = text, requestId = requestId, mode = mode)
    }
}

/**
 * Permission preset catalog and write capability measured from the DSH host.
 *
 * [writable] is this **field's** capability, not `settings/describe.writable`:
 * the phone image pins `permission.defaultPreset` in its startup home patch, so
 * the provider-wide flag is not evidence that this value can be written.
 * [startupLocked] distinguishes that startup overlay from a plain provider
 * refusal so the page can name the source and the restart requirement.
 */
internal data class PermissionDefaultsHostState(
    val currentModeId: String? = null,
    val availableModeIds: Set<String>? = null,
    val writable: Boolean = false,
    val busy: Boolean = false,
    val failure: String? = null,
    val startupLocked: Boolean = true,
    val readOnlyReason: String? = com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON,
) {
    val currentTier: com.phonedsh.ui.page.PermissionTier? get() = tierForPermissionMode(currentModeId)
    val availableTiers: Set<com.phonedsh.ui.page.PermissionTier>? get() = availableModeIds?.mapNotNull(::tierForPermissionMode)?.toSet()
}

private fun tierForPermissionMode(id: String?): com.phonedsh.ui.page.PermissionTier? = when (id) {
    "read-only", "phone-read-only" -> com.phonedsh.ui.page.PermissionTier.VIEW_ONLY
    "workspace-write", "phone" -> com.phonedsh.ui.page.PermissionTier.WORKSPACE_WRITE
    "danger-full-access", "bypassPermissions" -> com.phonedsh.ui.page.PermissionTier.FULL_ACCESS
    else -> null
}

/** One measured answer about writing the new-session default permission. */
internal data class DefaultPermissionAccess(
    val writable: Boolean,
    val startupLocked: Boolean = false,
    val readOnlyReason: String? = null,
)

/**
 * Keys a future engine may add to report this one field's writability or the
 * layer that owns it. Nothing here is invented by the UI: when none of these
 * facts is present, the phone image's startup home patch is the known owner and
 * the field is treated as locked rather than trusting the provider-wide flag.
 */
private val DEFAULT_PERMISSION_WRITABLE_KEYS: List<String> = listOf(
    "defaultPermissionWritable",
    "permissionDefaultWritable",
    "defaultPresetWritable",
    "permissionWritable",
)

private val DEFAULT_PERMISSION_OVERRIDE_KEYS: List<String> = listOf(
    "defaultPermissionOverrideSource",
    "permissionDefaultOverrideSource",
    "defaultPresetOverrideSource",
    "overrideSource",
    "lockedBy",
)

/**
 * Reads the engine's per-field write signal for the permission default.
 *
 * Precedence:
 *  1. an explicit per-field writable/lock fact on the describe root or the
 *     `permission` namespace (a future engine, used verbatim);
 *  2. an explicit override/lock source names the startup layer;
 *  3. no per-field fact: the phone image's home patch owns this value, so it is
 *     locked. The provider-wide `writable` is deliberately not consulted for
 *     this decision.
 *
 * @param described the `settings/describe` value, or `null` when unread.
 * @return the measured access, always carrying a reason when not writable.
 */
internal fun defaultPermissionAccess(described: JsonObject?): DefaultPermissionAccess {
    val fallback = com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON
    if (described == null) {
        return DefaultPermissionAccess(writable = false, startupLocked = false, readOnlyReason = fallback)
    }
    if ((described["writable"] as? JsonBool)?.value != true) {
        return DefaultPermissionAccess(writable = false, startupLocked = false, readOnlyReason = fallback)
    }
    val namespace = permissionNamespaceIn(described)
        ?: return DefaultPermissionAccess(writable = false, startupLocked = false, readOnlyReason = fallback)
    if ((namespace["revision"] as? JsonNumber)?.asLongOrNull() == null) {
        return DefaultPermissionAccess(writable = false, startupLocked = false, readOnlyReason = fallback)
    }
    val ownField = described.boolField(DEFAULT_PERMISSION_WRITABLE_KEYS)
        ?: namespace.boolField(DEFAULT_PERMISSION_WRITABLE_KEYS)
    val source = described.stringField(DEFAULT_PERMISSION_OVERRIDE_KEYS)
        ?: namespace.stringField(DEFAULT_PERMISSION_OVERRIDE_KEYS)
        ?: namespace.startupSource()
    if (ownField != null) {
        return if (ownField) {
            DefaultPermissionAccess(writable = true)
        } else {
            DefaultPermissionAccess(
                writable = false,
                startupLocked = true,
                readOnlyReason = startupLockReason(source),
            )
        }
    }
    if (source != null) {
        return DefaultPermissionAccess(
            writable = false,
            startupLocked = true,
            readOnlyReason = startupLockReason(source),
        )
    }
    // No engine-provided per-field provenance. The phone image's startup layer
    // is the known owner of this value; writing through it is refused by the
    // engine, so the honest answer is read-only.
    return DefaultPermissionAccess(
        writable = false,
        startupLocked = true,
        readOnlyReason = com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON,
    )
}

private fun JsonObject.boolField(names: List<String>): Boolean? =
    names.firstNotNullOfOrNull { name -> (this[name] as? JsonBool)?.value }

private fun JsonObject.stringField(names: List<String>): String? =
    names.firstNotNullOfOrNull { name -> (this[name] as? JsonString)?.value?.takeIf(String::isNotBlank) }

/** A startup-layer marker: explicit flag, startup object, or a base-layer value. */
private fun JsonObject.startupSource(): String? {
    if ((this["startupLocked"] as? JsonBool)?.value == true ||
        (this["locked"] as? JsonBool)?.value == true
    ) {
        return "启动配置（home patch / PDSH_SANDBOX_MODE）"
    }
    (this["startupOverride"] as? JsonObject)?.stringField(listOf("source", "lockedBy"))?.let { return it }
    (this["startupOverride"] as? JsonString)?.value?.takeIf(String::isNotBlank)?.let { return it }
    val base = this["base"] as? JsonObject
    if (base?.get("defaultPreset") != null) return "启动配置（home patch）"
    return null
}

private fun startupLockReason(source: String?): String {
    val normalized = source?.trim().orEmpty()
    if (normalized.isEmpty() ||
        normalized.contains("home patch", ignoreCase = true) ||
        normalized.contains("PDSH_SANDBOX_MODE", ignoreCase = true)
    ) {
        return com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_STARTUP_LOCKED_REASON
    }
    return "只读：新会话默认权限由${normalized}锁定。请修改启动配置并重启本地引擎；现有会话的权限不受影响。"
}

internal fun permissionNamespaceIn(described: JsonObject): JsonObject? =
    (described["namespaces"] as? JsonArray)?.values.orEmpty()
        .mapNotNull { it as? JsonObject }
        .firstOrNull { (it["ns"] as? JsonString)?.value == "permission" }

/** The `/api` calls this one field needs, kept injectable for the JVM tests. */
internal interface DefaultPermissionApi {
    suspend fun call(
        endpoint: String,
        args: JsonObject = JsonObject(emptyMap()),
        timeoutMillis: Long = 5_000,
    ): JsonValue
}

/**
 * The real read/write state machine behind the two view-model entry points.
 *
 * It owns the published [PermissionDefaultsHostState] so the settings page and
 * the plugin configuration page read the same measured answer. A locked state
 * is refused before the first call, which is what keeps a dead `settings/update`
 * off the wire; a writable state still writes and confirms by catalog readback.
 */
internal class DefaultPermissionGateway(
    private val state: MutableStateFlow<PermissionDefaultsHostState>,
) {
    suspend fun refresh(api: DefaultPermissionApi): String? = try {
        val catalog = api.call("permissionPresets/catalog") as? JsonObject
            ?: error("permission preset catalog was unreadable")
        val described = api.call("settings/describe") as? JsonObject
            ?: error("settings description was unreadable")
        val access = defaultPermissionAccess(described)
        state.value = PermissionDefaultsHostState(
            currentModeId = (catalog["defaultPreset"] as? JsonString)?.value,
            availableModeIds = permissionModeIds(catalog),
            writable = access.writable,
            startupLocked = access.startupLocked,
            readOnlyReason = access.readOnlyReason,
        )
        null
    } catch (failure: Exception) {
        val message = failure.message?.substringBefore('\n')?.take(180) ?: "权限默认值读取失败"
        state.value = state.value.copy(
            busy = false,
            writable = false,
            startupLocked = true,
            readOnlyReason = message,
            failure = message,
        )
        message
    }

    suspend fun write(api: DefaultPermissionApi, tier: com.phonedsh.ui.page.PermissionTier) {
        val locked = state.value
        if (!locked.writable) {
            throw IllegalStateException(
                locked.readOnlyReason
                    ?: com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON,
            )
        }
        state.value = locked.copy(busy = true, failure = null)
        try {
            val catalog = api.call("permissionPresets/catalog") as? JsonObject
                ?: error("permission preset catalog was unreadable")
            val candidates = when (tier) {
                com.phonedsh.ui.page.PermissionTier.VIEW_ONLY -> setOf("read-only", "phone-read-only")
                com.phonedsh.ui.page.PermissionTier.WORKSPACE_WRITE -> setOf("workspace-write", "phone")
                com.phonedsh.ui.page.PermissionTier.FULL_ACCESS -> setOf("danger-full-access", "bypassPermissions")
            }
            val mode = ((catalog["defaultOptions"] as? JsonArray)?.values.orEmpty())
                .mapNotNull { (it as? JsonObject)?.get("value") as? JsonString }
                .firstOrNull { it.value in candidates }?.value
                ?: error("this host does not offer the selected default permission")
            val before = api.call("settings/describe") as? JsonObject
                ?: error("settings description was unreadable")
            val access = defaultPermissionAccess(before)
            if (!access.writable) {
                val reason = access.readOnlyReason
                    ?: com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON
                state.value = state.value.copy(
                    busy = false,
                    writable = false,
                    startupLocked = access.startupLocked,
                    readOnlyReason = access.readOnlyReason,
                    failure = reason,
                )
                error(reason)
            }
            val namespace = permissionNamespaceIn(before)
                ?: error("the permission settings namespace is unavailable")
            val revision = ((namespace["revision"] as? JsonNumber)?.asLongOrNull())
                ?: error("the permission settings revision is unknown")
            api.call(
                "settings/update",
                JsonObject(
                    mapOf(
                        "ns" to JsonString("permission"),
                        "patch" to JsonObject(mapOf("defaultPreset" to JsonString(mode))),
                        "expectedRevision" to JsonNumber(revision.toString()),
                    ),
                ),
            )
            val after = api.call("permissionPresets/catalog") as? JsonObject
                ?: error("permission preset readback was unreadable")
            check((after["defaultPreset"] as? JsonString)?.value == mode) {
                "permission default was not confirmed by permission catalog readback"
            }
            state.value = PermissionDefaultsHostState(
                currentModeId = mode,
                availableModeIds = permissionModeIds(after),
                writable = true,
                startupLocked = false,
                readOnlyReason = null,
            )
        } catch (failure: Exception) {
            val message = failure.message?.substringBefore('\n')?.take(180) ?: "权限默认值保存失败"
            state.value = state.value.copy(busy = false, failure = message)
            throw failure
        }
    }

    private fun permissionModeIds(catalog: JsonObject): Set<String> =
        (catalog["defaultOptions"] as? JsonArray)?.values.orEmpty().mapNotNull { raw ->
            ((raw as? JsonObject)?.get("value") as? JsonString)?.value
        }.toSet()
}

/**
 * Owns the one engine **and** the one host across configuration changes.
 *
 * Before K5 this view model constructed the engine with a do-nothing channel
 * handler, so the page's HELLO was never answered and the screen showed
 * `hostCaps=[]`. It now builds the real [DefaultPhoneDshHost] and passes
 * `host.channelHandler` to the engine: the host HELLO, its caps and its
 * watermark are produced by `:dsh` from the recovered workspace log and the real
 * `phone` accelerator, not by this file.
 *
 * [start] is the host's asynchronous `start()`: it returns immediately, runs
 * recovery on the host's own scope and starts the engine only after the HELLO
 * is final. Nothing here blocks the UI thread.
 *
 * [runTurn] is the App's own `/api` path: the real [DshTurnClient] sends
 * `session/create`, `session/follow` and `session/prompt` over the channel the
 * Worker opened. The model behind the Worker is scripted by the acceptance
 * runner; this class makes no claim about inference.
 *
 * One view model per process, constructed only through [sharedHost]. The class
 * owns the App's one `WorkspaceLog` writer (P02), so a second instance is not a
 * second screen — it is a second writer over the same WAL directory. Android
 * can create a second `MainActivity` while this one still has a live view model,
 * so this lifetime is process-scoped rather than Activity-scoped: every Activity
 * gets the same host, engine and stores. The 2026-11-03 emulator evidence shows
 * what Activity-scoped ownership produced: two `DefaultPhoneDshHost` instances,
 * two `boot_id`s and two live WebViews in one process.
 */
class ProbeEngineViewModel private constructor(application: Application) : AndroidViewModel(application) {
    private val logger: EngineLogger = AndroidEngineLogger()

    /** The launch values read before this view model was constructed. */
    private val launchConfig: ProbeLaunchConfig = ProbeLaunchConfig.active()

    /**
     * budgets.md §4's device tier for this boot, selected from the physical
     * memory ceiling.
     *
     * This is the one place the App reads `ActivityManager.MemoryInfo.totalMem`
     * (`HostBudgetTier.forDevice`); §4 says the tier is selected **once per
     * boot**, so the value is a `val` and a later memory-pressure reading cannot
     * re-tier the host. The same object feeds the two surfaces the limit needs:
     * the Worker environment (so its write surfaces refuse with `EFBIG` before
     * publishing) and [DefaultPhoneDshHost] (so the host VFS sink answers
     * `VFS_REFUSED` as the backstop).
     *
     * Before this existed the App never measured anything: a 2 GiB device kept
     * the Worker's 8 GiB default of 128 MiB and accepted a file its §4 row caps
     * at 16 MiB.
     */
    private val deviceBudgets: ControllerBudgets = HostBudgetTier.forDevice(application)

    /**
     * The host credential provider for this launch, or `null` when there is no
     * model endpoint or no installed key store.
     *
     * One object serves both the `/v1/http` gateway and the model edge: a second
     * provider would mean a second `ModelEndpoint` and a second writer of the
     * same invariant (`gateway-security.md` §2 — the Worker never holds the key).
     */
    private val modelCredential: GatewayCredentialProvider? = launchConfig.modelCredentialProvider()

    /**
     * The model-protocol edge, or `null` when this launch cannot host one.
     *
     * It is built from the **real** upstream base (`launchConfig.deepseekBaseUrl`)
     * and the key-store provider, and handed to the engine; the engine binds it
     * to the loopback origin and rewrites the Worker's `DEEPSEEK_BASE_URL` to
     * that origin. When this is non-null the launch has declared **real model
     * traffic**: the Worker's model requests are answered only by the host edge,
     * and a stored key that is absent or unreadable is a fail-closed
     * `502 credential_unavailable` from that edge — never a silent fallback to an
     * anonymous or scripted upstream. "Credential broken" must look like a
     * broken credential, not like a model that answers strangely.
     *
     * `null` has three causes, and all three keep the pre-M2 path where the
     * Worker's env is passed through unchanged:
     *   * no base URL in the launch;
     *   * no installed key store ([ProbeLaunchConfig.modelCredentialProvider]);
     *   * the launch itself asked for no edge (`pdsh.model.proxy=false`), which
     *     is how a scripted upstream run keeps a real device key away from the
     *     test fixture.
     *
     * The base URL is not re-parsed here: [ProbeLaunchConfig.modelCredentialProvider]
     * already returned non-null only for a base URL that `ModelEndpoint.parse`
     * accepted, so this string is exactly the one the credential scope uses.
     */
    private val modelProxy: LoopbackModelProxy? = run {
        val base = launchConfig.deepseekBaseUrl
        val provider = modelCredential
        // Three ways to have no edge: no base, no credential, or a launch that asked for
        // none. The third one is what keeps a scripted upstream from ever receiving a real
        // key — see ProbeLaunchConfig.EXTRA_MODEL_PROXY.
        if (base == null || provider == null || !launchConfig.modelProxy) {
            if (!launchConfig.modelProxy) {
                // The one line a scripted run needs: no edge was mounted, so the
                // Worker env keeps its base URL and no host credential can reach
                // that upstream. No key and no real base appears here.
                logger.info("model edge disabled by launch (pdsh.model.proxy=false); the Worker env keeps its base URL")
            }
            null
        } else {
            LoopbackModelProxy(baseUrl = base, credentialProvider = provider)
        }
    }

    /**
     * The one upstream session, or `null` when the launch named no egress grant.
     *
     * The transport is the production `HttpURLConnection` hop. The credential comes
     * from the launch's model endpoint when it names one — the same object the model
     * proxy uses — and falls back to anonymous otherwise. Anonymous is not a silent
     * downgrade: [ProbeLaunchConfig.modelCredentialProvider] only returns non-null by
     * the time this runs, and its own resolve is fail-closed for the model origin.
     */
    private val gateway: GatewaySession? = launchConfig.egressGrant()?.let { grant ->
        GatewaySession(
            transport = HttpUrlConnectionGatewayTransport(),
            credentialProvider = modelCredential ?: AnonymousCredentialProvider,
            egress = AllowListEgressPolicy(listOf(grant)),
        )
    }

    private val diagnosticHttpEgress = gateway?.let { GatewayHttpEgress(it) }

    /**
     * Which web-search grant this launch mounts (`spec/v1/gateway-independent-search.md`
     * §3). The independent mode replaces the official grant; an incomplete or
     * unreadable independent setup mounts neither, never the model key.
     */
    private val webSearchPlan: WebSearchLaunchPlan = run {
        val settings = WebSearchSettingsStore.active()
        WebSearchLaunchPlan.resolve(
            settings = settings?.read() ?: WebSearchSettingsRead.Absent,
            independentKey = { settings?.keyState() ?: ApiKeyState.Absent },
            accountCovers = { base -> TonoAccountKeySource.usesAccount(base, TonoAccountHost.activeSession()) },
            proxyRequested = launchConfig.modelProxy,
            official = {
                OfficialWebSearchLaunch.resolve(
                    baseUrl = launchConfig.deepseekBaseUrl,
                    proxyRequested = modelProxy != null,
                    credentialAccount = launchConfig.credentialAccount,
                    keyState = launchConfig.credentialAccount?.let { ApiKeyStore.activeState(it) },
                )
            },
        )
    }

    private val webSearchEgress: LoopbackHttpEgress? = when (val plan = webSearchPlan) {
        is WebSearchLaunchPlan.Official -> OfficialDeepSeekWebToolsEgress(
            keys = ModelKeySource {
                val store = ApiKeyStore.active() ?: throw CredentialUnavailableException()
                store.readKey(plan.launch.credentialAccount)
            },
            transport = HttpUrlConnectionGatewayTransport(),
            fallback = diagnosticHttpEgress,
        )
        is WebSearchLaunchPlan.Independent -> IndependentSearchWebToolsEgress(
            base = plan.base,
            keys = ModelKeySource {
                val store = WebSearchSettingsStore.active() ?: throw CredentialUnavailableException()
                store.readKey()
            }.let { stored ->
                TonoAccountHost.activeSession()?.let { TonoAccountKeySource.overlay(plan.base, it, stored) } ?: stored
            },
            transport = HttpUrlConnectionGatewayTransport(),
            fallback = diagnosticHttpEgress,
        )
        is WebSearchLaunchPlan.Off -> null
    }

    /** The `/v1/http` policy the engine serves; `null` keeps the route at 503. */
    private val httpEgress: LoopbackHttpEgress? = webSearchEgress ?: diagnosticHttpEgress

    /**
     * What this launch can honestly say about model traffic (P27).
     *
     * The Worker env publishes the key's *state* and a non-secret placeholder
     * credential even when the launch named no endpoint (P25), which is correct:
     * those are facts about the device. It did **not** publish whether a model
     * route exists, and that absence was not neutral — with no
     * `DEEPSEEK_BASE_URL` the Worker's pinned `llm-deepseek` resolver falls back
     * to its public base (`packages/llm/llm-deepseek/src/config.ts:300`), so a
     * launch that mounted no edge sent the placeholder to
     * `https://api.deepseek.com/anthropic` and produced a real 401 (measured
     * 2026-11-01). This fact is published through
     * [ModelRouteFact.workerEnvironment] and the Worker refuses a model request
     * on `none` (`plugins/worker-entry/src/model-route.ts`), so the
     * misconfiguration produces no external traffic and names the missing input.
     *
     * It is computed once and read by the env, the start log and the sentence a
     * failed turn carries. One fact, one answer.
     */
    private val modelRoute: ModelRouteFact = ModelRouteFact.forLaunch(
        baseUrl = launchConfig.deepseekBaseUrl,
        proxyRequested = launchConfig.modelProxy,
        credentialAvailable = modelCredential != null,
    )

    /**
     * The `pageParams` this launch hands the engine (the engine's own parameter
     * is `pageParams`; this property is the value it is given).
     *
     * The route members are added **after** `ProbeLaunchConfig.workerEnvironment()`
     * (which P25 owns) so this lane does not reopen that method's contract: the
     * key members stay exactly where P25 put them, and the route is one more
     * fact of the same env object. The engine re-parses this JSON and adds
     * `PDSH_DSH_LAUNCH_TOKEN` (`WorkerEnvironment.pageParam`).
     *
     * No value here is a credential or an endpoint: `host-edge` / `direct` /
     * `none` plus a missing-input code. Nothing is logged.
     */
    private val workerPageParams: Map<String, String> = run {
        val hostEnv = launchConfig.workerEnvironment(
            modelProxyMounted = modelProxy != null,
            // The selected tier's `single_file_limit`, published where the Worker
            // reads it (channel.md §4.1 has no HELLO member for it). This is what
            // makes an over-limit write an `EFBIG` from the write surface instead
            // of a WAL record that only recovery can refuse.
            singleFileLimitBytes = deviceBudgets.singleFileBytes,
        )
        val env = if (hostEnv == null) JSONObject() else JSONObject(hostEnv)
        for ((name, value) in modelRoute.workerEnvironment()) env.put(name, value)
        for ((name, value) in webSearchPlan.environment) env.put(name, value)
        mapOf("env" to env.toString())
    }

    /** The per-start token source; also authenticates the App's egress probe. */
    private val launchToken = SecureLaunchToken()

    /**
     * The App's one PC workspace seam (C5): the real `PclinkClient`, its RPC,
     * the DSH transport and the P18 store. The controller is built here and
     * released in [onCleared]; no page in `:lib` sees a `:pclink` type.
     *
     * Construction performs no network dial and no Keystore read: the client
     * loads/generates its identity and starts a connection job only after
     * [start]. A failure to build the workspace (for example a device whose
     * Keystore cannot create the store) leaves the phone backend usable and
     * the PC page reporting unavailable.
     */
    internal val pcWorkspace: PcWorkspaceController? = runCatching {
        PcLinkWorkspace.create(application).controller()
    }.onFailure { error ->
        Log.w(TAG_TURN, "PC workspace unavailable: ${error.javaClass.simpleName}")
    }.getOrNull()

    // ---- construction order: engine first, then the host --------------------
    // The host needs the engine, and the engine needs the host's frame consumer.
    // [HostChannelSeam] breaks that cycle; it is attached in `init` before
    // `host.start()`, so no frame can ever reach an unattached seam.
    private val channelSeam = HostChannelSeam()

    private val engine: DemoEngine = createDemoEngine(
        context = application,
        channelHandler = channelSeam,
        logger = logger,
        // `workerAssets` is named on purpose: the factory's `logger` has a default
        // value before it, so a positional call would not compile.
        workerAssets = WorkerAssets(
            source = ApkWorkerAssetSource(application),
            filesDir = application.filesDir,
            logger = logger,
        ),
        // One fresh 32-byte secret per start: the loopback gate/cookie token and
        // the worker's PDSH_DSH_LAUNCH_TOKEN. Never logged or persisted; the
        // resident phone surface refuses to provide `connection` without it.
        launchToken = launchToken,
        // The base URL travels through the same `env` object as the launch
        // token; it is not a page query parameter of its own and is not logged.
        // With a mounted edge the env omits `DEEPSEEK_BASE_URL` entirely: the
        // engine fills in the loopback origin once the port is known, so the real
        // upstream base never enters the page parameter. The model route travels
        // in the same object (see [workerPageParams]).
        pageParams = workerPageParams,
        // The Worker's only outbound path; null when no exact grant was supplied.
        httpEgress = httpEgress,
        // M2: the model edge. It holds the real upstream base and the key-store
        // provider; the engine mounts it on the loopback origin and points the
        // Worker's DEEPSEEK_BASE_URL there. Null keeps the scripted-upstream path.
        modelProxy = modelProxy,
        // P22: the channel-reopen lane reloads the page only while D14's admission
        // is open. `controller` is initialized after this engine on purpose (the
        // host takes the engine), and the lambda is read at reload time, never
        // during construction.
        writesAllowed = { controller.admission == Admission.OPEN },
        // P28 / wal.md §8: the Worker is seeded from the recovered materialized
        // tree. The delegate reads the log when `pack()` runs — always after
        // `host.start()` finished recovery and tail replay — because the engine is
        // built before the WAL here, exactly like `writesAllowed` above reads
        // `controller` later. `null` (the diagnostic launch) reproduces the
        // pre-P28 shape: no `?overlay=`, an empty Worker view.
        bootOverlaySource = if (launchConfig.bootOverlay) {
            BootOverlaySource { bootOverlayProducer.pack() }
        } else {
            null
        },
        // spec/v1/native-mcp.md: the android_* tools on `/mcp/native`, the same
        // process-owned server the Android ADB settings page tests with (iOS sets
        // `configuration.nativeMCP` unconditionally too).
        nativeMcp = AndroidAdbHost.get(application).server,
        // spec/bot/v1/mcp-endpoint.md §1: when the Bot listener is live, the
        // Worker gets its loopback URL and the non-secret placeholder token;
        // the provider is read again on every page load, so a recovered port is
        // never a stale URL.
        botMcpEnvironment = {
            appBotRuntime?.mcpUrl?.let { url -> com.phonedsh.engine.BotMcpEnvironment(url) }
        },
    )

    private val clock = AndroidClock()
    private val durability = AndroidDurability()
    private val signals = AndroidLifecycleSignals(application)

    /**
     * The `wal.md` §8 boot overlay producer (P28).
     *
     * `wal.md` §8 says the overlay is packed from the materialized tree "after
     * recovery, reconcile and tail replay" and is rebuilt for each boot; the engine
     * therefore calls [MaterializedBootOverlaySource.pack] before **every** page
     * load. This property is `by lazy` on purpose: it reads [walPaths] and
     * [workspaceLog], which are constructed after the engine.
     *
     * The cap is the tier's `vfsLogicalBytes` (budgets.md §4). That is the memory
     * this tree becomes in the Worker's `MemoryVfs`, so a tree above it cannot be
     * booted by this device at all; the producer then refuses loudly instead of
     * truncating (see BootOverlay.kt).
     */
    private val bootOverlayProducer: MaterializedBootOverlaySource by lazy {
        MaterializedBootOverlaySource(
            materializedDirectory = walPaths.materializedDirectory,
            outputDirectory = walPaths.root.resolve(BOOT_OVERLAY_DIRECTORY),
            maxArchiveBytes = deviceBudgets.vfsLogicalBytes,
            logger = logger,
            // `materializedUptoMseq` is the watermark the snapshot must be taken
            // at: a pack that straddles a materialization is discarded and retried,
            // so the Worker always mounts one consistent mseq.
            watermark = { workspaceLog.materializedUptoMseq },
        )
    }

    // wal.md §1 places the workspace under `Library/xl/`; on Android the app's
    // private filesDir is the equivalent root. This one path is the root every
    // durable store is built over — the WAL's `wal/`, the journal's `journal/`
    // and the exec dedup table's `exec/` — so no store carries an absolute path
    // of its own and none of them can drift to a second directory.
    private val workspaceRoot: Path = File(application.filesDir, WORKSPACE_DIRECTORY).toPath()

    /**
     * The real seal behind the `ubuntu` lane: `BuildSeal` + `BuildSealTripwire`.
     *
     * Design §3 layers 3 and 4 are "the core countermeasure", and until this
     * property existed the production path ran `MockUbuntuSeal`, which opens and
     * closes nothing — so `chmod 000` never happened for any job the Agent ran.
     * The adapter lives in `:platform-android` (`BuildSealUbuntu`); `:dsh` only
     * sees the `UbuntuSeal` seam, which is why the injection point is here.
     *
     * The sealed roots are `materialized/home/{sessions,storages,tool-journal}`
     * under this same [workspaceRoot], i.e. the tree the WAL materializes and the
     * accelerators are mounted on — not a second copy.
     */
    private val ubuntuSeal: UbuntuWorkspaceSeal = UbuntuWorkspaceSeal.forWorkspace(
        xlRoot = workspaceRoot,
        log = { line -> LogcatHostLog.info(line) },
    )

    /**
     * The boot repair — **must run before `host.start()` opens the workspace**.
     *
     * A process killed inside a job's window leaves every root under
     * `materialized/home` at
     * `chmod 000` *and* leaves the seal marker, so a boot that skipped this would
     * fail its first reconcile of that tree and could not resume its own stores.
     * `BuildSeal.recoverIfNeeded()` (reached through `BuildSealUbuntu.repair()`)
     * is idempotent and reads one file that normally does not exist, so the cost
     * on a healthy boot is one failed `exists` check — the same synchronous,
     * small, composition-time read this class already makes for
     * `hostStateStore.load()` two properties below.
     *
     * The outcome is logged, never swallowed: a `false` means the marker is still
     * there (the next boot retries) and the workspace is not healthy.
     */
    private val ubuntuSealRepaired: Boolean = runBlocking {
        ubuntuSeal.repair()
    }.also { repaired ->
        if (repaired) {
            LogcatHostLog.info("ubuntu seal: boot repair found nothing to undo")
        } else {
            LogcatHostLog.warn(
                "ubuntu seal: boot repair FAILED; the seal marker is still on disk " +
                    "and the internal roots may still be 000",
            )
        }
    }

    /**
     * `host-state.json`, the file `PERSIST_HOST_STATE` writes (P15).
     *
     * Until this existed the boot below passed a literal `persistedState = null`
     * and every start was `COLD_START`: budgets.md §3's boot mapping (persisted
     * `Parked` -> `Parked`, persisted `Backoff` -> `Backoff`, persisted
     * `HandingOff` -> `Failed`) had no file to read, so a host killed while
     * `Parked` came back cold and `PARKED_RESUME` was unreachable.
     */
    private val hostStateStore = HostStateStore(
        file = workspaceRoot.resolve(HostStateStore.FILE_NAME),
        durability = durability,
        clock = clock,
        logger = LogcatHostLog,
    )

    /**
     * The state this boot restores, or `null` when there is none to trust.
     *
     * Read once, before the machine is built: the D14 boot mapping is a pure
     * function of the persisted state, and a second read later could see a
     * record this process itself wrote.
     */
    private val persistedHostState = hostStateStore.load()

    // The boot mapping of budgets.md §3: a persisted `Parked` host resumes as
    // `Parked` (its resume waits for an active scene), a persisted `Running`,
    // `Draining` or `Recovering` host boots back into `Recovering`, a persisted
    // `HandingOff` is `Failed`, and no record at all is the empty workspace.
    // `workspaceHasState` stays false: whether the WAL holds history is the
    // WAL's answer, not this file's.
    private val controller = ControllerStateMachine.boot(
        persistedState = persistedHostState?.state,
        // `host-state.json` stores the closed-vocabulary code. Without it a
        // cold boot rendered the real device failure as `UNRECORDED`
        // (22:03:13.258 in the WAL evidence).
        persistedFailure = ControllerFailure.fromCode(persistedHostState?.reason),
    )

    // One path object for every consumer of the workspace layout: the WAL, the
    // journal and the exec accelerators' mounts all derive from it, so no store
    // can drift to a second directory.
    private val walPaths = WalPaths(workspaceRoot)

    // The directory is relative to filesDir (no absolute path is committed or
    // logged) and `recover()` is run by the host's asynchronous boot, never here.
    private val workspaceLog = WorkspaceLog(
        paths = walPaths,
        durability = durability,
        clock = clock,
        // wal.md section 10 step 2 requires a torn-tail truncation to be logged.
        // The library default drops every event, so the composition root supplies
        // the sink that both logs it and raises the banner.
        sink = ProbeRecovery.walSink,
    )

    /** The one WAL seam, shared by the HELLO and the exec bridge. */
    private val hostWal = workspaceLog.asHostWal()

    /**
     * The journal lane's directory layout, shared by the store and the session
     * read, so a row's file is named by the same object that wrote it.
     */
    private val journalPaths = JournalPaths(workspaceRoot)

    /**
     * The 本 session 产物 fact: which workspace files this session's turns wrote.
     *
     * One instance per process, over the same materialized tree the files page and
     * the preview read (`WalPaths.materializedWorkspace`). It measures the tree
     * around each chat turn rather than parsing tool arguments or scanning the
     * folder — see [HostSessionArtifacts] for why neither of those can answer the
     * page's question. Nothing is persisted: after a cold start the host has
     * measured no turn, so it claims nothing and the page lists every file as 未归属.
     */
    private val sessionArtifacts = HostSessionArtifacts(walPaths.materializedWorkspace)

    /** `android_install_apk source=workspace` reads the materialized `/dsh/workspace` (iOS ChatModel does the same). */
    private val adbWorkspaceBound: Unit = AndroidAdbHost.get(application).bindWorkspace(walPaths.materializedWorkspace)

    /** The artifact fact the shell collects; one value per turn measurement. */
    internal val artifactFacts: kotlinx.coroutines.flow.StateFlow<com.phonedsh.ui.page.SessionArtifactsFacts> =
        sessionArtifacts.facts

    /**
     * The journal lane behind `JOURNAL` (`0x30`).
     *
     * The store is recovered inside `host.start()`, before the HELLO is final:
     * only a store that recovered leaves the sink open, and only an open sink
     * acks a record. Constructing it here does no I/O. Without it the host logs
     * `journal: off` and the Worker's level-1 durability wait expires after
     * 30 s, which reopens the connection in the middle of a turn.
     */
    private val journalStore = JournalStore(
        paths = journalPaths,
        durability = durability,
        logger = LogcatHostLog,
    )

    /**
     * exec.md §2's durable dedup table (`exec/` under the workspace root).
     *
     * One file per `idem_key`, written through the same `Durability` SPI as the
     * WAL and the journal. A repeated key replays the recorded events after a
     * process restart instead of running the accelerator twice.
     *
     * Constructing it creates `exec/` and scans the retained entries: a
     * one-time, small IO at composition time, bounded by the ledger's
     * `DEFAULT_MAX_ENTRIES`. If a future workload makes that scan visible at
     * startup, the fix is a lazy-load seam in the ledger, not a larger default.
     */
    private val execLedger = FileRequestLedger(
        workspaceRoot = workspaceRoot,
        durability = durability,
        clock = clock,
    )

    /**
     * The local Ubuntu environment's on-demand rootfs.
     *
     * `<filesDir>/ubuntu/{downloads,rootfs/<version>}` — outside the WAL's
     * workspace root on purpose: the rootfs is a tool cache, not workspace
     * state, and a WAL restore must never try to reconcile 100 MB of guest
     * binaries. The download starts inside the first admitted job, after the
     * approval gate and the seal, never at boot.
     */
    private val ubuntuRootfsStore = UbuntuRootfsStore(
        filesDir = File(application.filesDir, "ubuntu").toPath(),
        logger = { line -> LogcatHostLog.info(line) },
    )

    /** The four Termux binaries PackageManager extracted into nativeLibraryDir. */
    private val ubuntuProot = ProotRuntime(
        nativeLibraryDir = File(application.applicationInfo.nativeLibraryDir).toPath(),
        prootTmpDir = File(application.cacheDir, "proot-tmp").toPath(),
    )

    /** Durable job records and per-job stdout/stderr/artifact directories. */
    private val ubuntuJobsDir = File(application.filesDir, "ubuntu/jobs").toPath()

    /**
     * The real environment the host tool asks for: proot adapter, durable store,
     * the real seal and `backend=proot`.
     *
     * A factory, not a constructed session: the first `run` builds it, so a
     * host that never uses `ubuntu` downloads nothing, starts no process and
     * pays no recovery cost. `available` is answered by the three binaries'
     * presence, so a build whose generated jniLibs are missing reports
     * `available=false` instead of registering a command that cannot start.
     */
    private val ubuntuSessionFactory: UbuntuSessionFactory = UbuntuSessionFactory(
        backend = ProotUbuntuSession.BACKEND,
    ) {
        ProotUbuntuSession(
            clock = clock,
            adapter = ProotUbuntuAdapter(
                rootfs = ubuntuRootfsStore,
                runtime = ubuntuProot,
                hostWorkspace = walPaths.materializedWorkspace,
                jobsRoot = ubuntuJobsDir,
                clock = clock,
                logger = { line -> LogcatHostLog.info(line) },
            ),
            seal = ubuntuSeal,
            storeRoot = ubuntuJobsDir,
            durability = durability,
            admissionOpen = { controller.admission == Admission.OPEN },
            budgets = deviceBudgets,
            logger = LogcatHostLog,
        )
    }

    /** The one registered read-only accelerator bridge shared by Worker and shell-page runs. */
    private val execBridge = HostExec.defaultTools(
        clock = clock,
        controller = controller,
        wal = hostWal,
        logger = LogcatHostLog,
        ledger = execLedger,
        shellMounts = listOf(
            AcceleratorMount(AcceleratorMount.WORKSPACE, walPaths.materializedWorkspace.toString()),
            AcceleratorMount(AcceleratorMount.HOME, walPaths.materializedHome.toString()),
        ),
        seal = ubuntuSeal,
        // Native `ssh` / `scp` (docs/native-ssh.md): saved aliases, pinned host
        // keys and Keystore credentials; uploads read the same two mounts.
        nativeTools = com.phonedsh.ssh.SshExecTool(
            mounts = mapOf(
                "/dsh/workspace" to walPaths.materializedWorkspace,
                "/dsh/home" to walPaths.materializedHome,
            ),
            byteLimit = deviceBudgets.singleFileBytes,
            clock = clock,
            connections = { SshSettingsStore.get(application).list() },
            resolve = { destination -> SshSettingsStore.get(application).resolve(destination) },
        ).registeredTools(),
        ubuntuSessionFactory = ubuntuSessionFactory,
    )

    /**
     * The local DomainStore (`PRD.md:169`), constructed here and nowhere else.
     *
     * `:domain` owns the contract and the two backends; this root is the one
     * place allowed to pick one, which is why `:dsh` has no edge to `:domain`.
     * Opening is lazy — [DomainStoreCore] touches the file on first use — so
     * constructing it at composition time costs nothing.
     *
     * It is deliberately **not** a third writer of the session record. The
     * authoritative event log stays the WAL and the journal (fields above); this
     * store holds only the projection cache described in [sessionArchive].
     */
    private val domainStore: DomainStore = DomainStoreCore(
        connections = SqliteConnectionFactory(application, SessionArchive.DATABASE_NAME),
        quotas = QuotaPolicy.perDomain(
            mapOf(SessionArchive.DOMAIN to SessionArchive.QUOTA_BYTES),
        ),
        clock = clock,
    )

    /**
     * The transcript cache: the Android half of the iOS baseline's
     * `transcript-snapshots/<sessionID>.json` plus its
     * `currentSessionDefaultsKey`.
     *
     * iOS keeps a JSON file per session so a cold start can paint the last
     * screen before the host is up (`ChatModel.swift:2512-2599`:
     * `persistTranscriptSnapshot` / `restoreCachedTranscriptIfAvailable`) and
     * remembers the session it last opened in `UserDefaults`. Android had
     * neither: [mutableTurn] started at [AppTurnState.Idle] on every launch and
     * [mutableSessions] learned the current session only from a turn this
     * process ran, so a kill erased both. This is the consumer the `:domain`
     * store was missing — see [sessionArchive]'s own file header for why the
     * payload lives in the domain store and not in a third JSON file.
     */
    private val sessionArchive = SessionArchive(domainStore)

    /**
     * The user preferences (`UserDefaults` parity), constructed here and nowhere
     * else.
     *
     * One `SharedPreferences` file behind one store — the settings index's five
     * pickers, the chat-appearance page's pickers and steppers, the 后台运行
     * switch and the 繁忙时的发送行为 menu all read and write this object, so two
     * pages cannot disagree about a value. It is constructed at composition time
     * and reads the file once; a write is published through [preferenceState] and
     * the shell rebuilds the facts on the next frame.
     */
    private val preferenceStore = PreferenceStore(SharedPreferenceFile(application))

    /** The resolved preferences; a write publishes a new value. */
    internal val preferenceState: StateFlow<Preferences> = preferenceStore.state
    private val mutablePermissionDefaults = MutableStateFlow(PermissionDefaultsHostState())
    internal val permissionDefaults: StateFlow<PermissionDefaultsHostState> = mutablePermissionDefaults.asStateFlow()
    private val defaultPermissionGateway = DefaultPermissionGateway(mutablePermissionDefaults)

    /** The live settings/plugin/model/permission read behind 本会话设置. */
    private val mutableConfiguration = MutableStateFlow(ConfigurationFacts())
    internal val configuration: StateFlow<ConfigurationFacts> = mutableConfiguration.asStateFlow()
    private val configurationRefreshMutex = Mutex()

    /**
     * `agentPresets/list`'s last reading behind the 预设 page.
     *
     * `presets == null` is "not reported" (the page's 未知 line), while an empty
     * list is a real "the engine has no presets". An error keeps the presets that
     * were already read, exactly like iOS's `refresh()` catch.
     */
    private val mutableAgentPresets = MutableStateFlow(NativeAgentPresetsFacts())
    internal val agentPresets: StateFlow<NativeAgentPresetsFacts> = mutableAgentPresets.asStateFlow()
    private val agentPresetsRefreshMutex = Mutex()
    private val agentPresetLauncher: AgentPresetSessionLauncher by lazy {
        AgentPresetSessionLauncher(
            readPresets = {
                val failure = refreshAgentPresets()
                mutableAgentPresets.value.copy(
                    error = failure ?: mutableAgentPresets.value.error,
                )
            },
            createWorkerSession = { presetId ->
                DshTurnClient(host.channel, ::logTurn).createSessionWhenReady(
                    agentPreset = presetId,
                    totalTimeoutMillis = AGENT_PRESET_SESSION_TIMEOUT_MILLIS,
                    perAttemptMillis = AGENT_PRESET_SESSION_ATTEMPT_TIMEOUT_MILLIS,
                )
            },
            createChatSession = { requestId, workerSessionId ->
                newChatSessionConfirmed(
                    requestId = requestId,
                    workerSessionId = workerSessionId,
                )
            },
        )
    }

    private val host: DefaultPhoneDshHost = DefaultPhoneDshHost(
        engine = engine,
        controller = controller,
        clock = clock,
        signals = signals,
        // :dsh ships no production Notifier and :app has no notification channel
        // or POST_NOTIFICATIONS flow, so the honest value is DISABLED: on a
        // crash-recovery boot the host logs "not user-visible" instead of
        // pretending a notification reached the user.
        notifier = DisabledNotifier,
        // `wal/1` is advertised only when this log's recovery succeeds inside
        // `host.start()`; the HELLO's caps and watermark are built from that
        // outcome, never from a value written in this file.
        wal = hostWal,
        // The journal store is recovered in `host.start()` too, so `0x30` is
        // dispatched and acknowledged (durably) for the whole boot instead of
        // being logged and ignored.
        journal = journalStore,
        // `exec/1` and every `accelerator:*` entry come from the bridge's
        // capability set, never a capability string in this file. The durable
        // ledger and the mounts are injected here: this is the composition root
        // that owns the workspace root and the durability SPI.
        //
        // The mounts point at the WAL's *materialized* copies, exactly the tree
        // the accelerators are promised (exec.md §2.1): `rg`/`jaq` must never
        // read the journal or an unmaterialized mutation. `WalPaths` only joins
        // names; `WorkspaceLog.recover()` creates the directories inside
        // `host.start()`, before admission opens, so a dispatched EXEC_REQ always
        // finds them. With no workspace the list would be empty and :shell would
        // advertise no accelerator at all.
        exec = execBridge,
        logger = LogcatHostLog,
        // The one upstream session; no longer a null placeholder.
        gateway = gateway,
        // The Worker's `XL_DSH_READY` announcement arrives on CONSOLE.
        onWorkerConsole = ::onWorkerConsole,
        // P15: `PERSIST_HOST_STATE` and the `Backoff` retry schedule have an
        // owner. The store is the same file this boot read, so a `Parked` host
        // survives a kill and a `Backoff` host restores the rest of its window.
        stateStore = hostStateStore,
        // budgets.md §4: the one measured row for this boot. The host's VFS sink
        // answers a mutation that would grow a file past this row's
        // `single_file_limit` with `VFS_REFUSED` (channel.md §4.8/§8); the same
        // value went into the Worker env above, so the two surfaces cannot
        // disagree.
        deviceBudgets = deviceBudgets,
        // gateway/loopback/lease/sessionEpoch/scope keep their documented
        // defaults: :engine binds the origin, the lease is LocalOnly, and no
        // persisted session counter exists (0 = none).
    )

    val state: StateFlow<EngineState> = engine.state

    /**
     * The D14 host state, which is what actually decides whether this app is
     * usable right now: admission is open only in `Running`.
     *
     * The screen needs both facts. The engine can be `Running` while the host is
     * `Draining`/`Parked`/`Recovering`, and rendering that as 「运行中 / 已连接」
     * is the lie P10 measured (12:01:19, API 35: every write refused while the
     * panel said 运行中).
     */
    val hostState: StateFlow<com.phonedsh.controller.HostState> = host.state
    val channel: StateFlow<ChannelStatus> = engine.channel

    /**
     * The Bot runtime composition (P25 store, memory/routines, authz and MCP
     * listener). Construction is lazy and failure is honest: the rest of the
     * App keeps working and the log names the reason.
     */
    private val appBotRuntimeDelegate = lazy<AppBotRuntime?> {
        runCatching {
            AppBotRuntime.create(
                context = getApplication(),
                transport = DshBotSessionTransport(host.channel, ::logTurn),
                logger = { line -> Log.i("AppBotRuntime", line) },
            )
        }.onFailure { error ->
            Log.w(TAG_TURN, "Bot platform unavailable: ${error.javaClass.simpleName}: ${error.message}")
        }.getOrNull()
    }
    internal val appBotRuntime: AppBotRuntime? by appBotRuntimeDelegate

    /** The Bot tab's one composition seam; the driver/store are the runtime's. */
    internal val botPlatformConfig: BotPlatformConfig? by lazy {
        appBotRuntime?.platformConfig
    }

    /** Foreground lifecycle hooks; both are no-ops before the lazy creation. */
    internal fun startBotRuntime() {
        if (appBotRuntimeDelegate.isInitialized()) appBotRuntime?.start()
    }

    internal fun stopBotRuntime() {
        if (appBotRuntimeDelegate.isInitialized()) appBotRuntime?.stop()
    }
    val handshake: StateFlow<HandshakeSummary?> = engine.handshake

    /**
     * The installed WebView provider, read once at construction.
     *
     * `null` when the framework could not answer; the runtime page then renders
     * 未知 instead of a package name the host never saw.
     */
    private val webViewPackage: android.content.pm.PackageInfo? =
        runCatching { WebView.getCurrentWebViewPackage() }.getOrNull()

    /**
     * Whether the app is exempt from battery optimisation, read once.
     *
     * The settings page owns the wording; this file only reports the platform
     * answer, and 未知 when the service refused to answer.
     */
    private val batteryExemption: FactState = runCatching {
        val app = getApplication<Application>()
        val manager = app.getSystemService(PowerManager::class.java)
        when (manager?.isIgnoringBatteryOptimizations(app.packageName)) {
            true -> FactState.YES
            false -> FactState.NO
            null -> FactState.UNKNOWN
        }
    }.getOrDefault(FactState.UNKNOWN)

    /** Monotonic start of the current Running spell; `null` when not running. */
    @Volatile
    private var runningSinceMillis: Long? = null

    /**
     * What the merged APK declares for the background lane, read once.
     *
     * The declaration cannot change without a reinstall, so it is cached instead
     * of paying four `PackageManager` reads on every facts build. The notification
     * capability is *not* cached: the user can revoke it between two reads.
     */
    private val backgroundDeclaration: BackgroundDeclaration by lazy {
        HostBackground.declaration(getApplication())
    }

    /**
     * The engine's one view, or `null`.
     *
     * UI thread only: the Web surface attaches this exact instance and never
     * creates a second one (the single-WebView invariant).
     */
    fun currentWebView(): View? = engine.view()

    /**
     * The engine's last WebView kernel measurement (provider, real Chromium
     * version, runtime features), or `null` before the first page finished.
     *
     * Read synchronously like [currentWebView]: both are host facts of the one
     * engine, not UI state of their own. `null` means "not measured".
     */
    fun kernelReport(): WebViewKernelReport? = engine.kernelReport()

    /** True when the launch asked the Web surface to be the engine-ready face. */
    fun webFaceOnLaunch(): Boolean = launchConfig.webFace

    /**
     * True when the launch asked for the engine probe as the start face.
     *
     * L62 made the product home the session list; the device scripts that tap
     * 跑一轮 right after launch pass `--ez pdsh.face.probe true` and land on the
     * probe instead (see [ProbeLaunchConfig.EXTRA_PROBE_FACE]).
     */
    fun probeFaceOnLaunch(): Boolean = launchConfig.probeFace

    /**
     * One walk over every value the navigation facts are built from.
     *
     * Measured: the engine's view, the running duration (monotonic), the WebView
     * provider/version, the launch egress grant, the battery-exemption fact, the
     * background lane's declaration and notification capability, whether the
     * materialized workspace tree exists, and the app's own permission/hardware
     * state (`HostPermissionReadings`). Everything not measured stays `null`; no
     * field defaults to a fake value.
     */
    internal fun hostReadings(): HostReadings = HostReadings(
        webView = engine.view(),
        uptimeMs = runningSinceMillis?.let { since ->
            (clock.monotonicMillis() - since).coerceAtLeast(0L)
        },
        webViewProvider = webViewPackage?.packageName,
        webViewVersion = webViewPackage?.versionName,
        // The engine's own measurement, taken when the page finished: provider
        // identity plus the real Chromium version and the runtime features. It
        // is null until then, and the page renders 未知 — never "supported".
        webViewKernel = engine.kernelReport(),
        egressGrant = launchConfig.egressGrant(),
        officialWebSearchEnabled = webSearchPlan is WebSearchLaunchPlan.Official,
        independentWebSearchEnabled = webSearchPlan is WebSearchLaunchPlan.Independent,
        batteryExemption = batteryExemption,
        background = HostBackground.readings(getApplication(), backgroundDeclaration),
        // The one workspace this app owns is `workspaceRoot`; its files page reads
        // the materialized mirror (`WalPaths.materializedWorkspace`). The directory's
        // existence is the measurement the folder row is built from: before the WAL
        // ever recovered there is no tree on disk, and the folder list must stay 未知
        // rather than show a folder that opens nothing.
        workspacePresent = Files.isDirectory(walPaths.materializedWorkspace),
        // The phone-permission matrix's device read: the platform snapshot comes from
        // `:domain`'s `AndroidDeviceCapabilities`, the permission state from
        // `AndroidHostPermissions` over it. Both are application-context reads; the
        // walk itself requests no permission and writes nothing — the request is the
        // Activity's (`MainActivity.phonePermission`), and what it leaves behind is
        // read back here as the ask log and the in-flight row.
        permissions = AndroidHostPermissions(
            getApplication<Application>(),
            AndroidDeviceCapabilities.platformFacts(getApplication<Application>()),
        ).read(),
        permissionAsks = PhonePermissionAsks.asked(),
        permissionInFlight = PhonePermissionAsks.inFlight,
        // The runtime page's 最近出錯 must read the host's own failure, not
        // only the chat turn state (HostNavFacts.kt's runtimeLastError).
        hostFailure = controller.lastFailure?.let { failure ->
            HostFailureReading(code = failure.code, detail = controller.lastFailureDetail)
        },
    )

    /** The facts every routed page reads, rebuilt from one host walk. */
    internal fun navFacts(
        state: EngineState,
        handshake: HandshakeSummary?,
        turn: AppTurnState,
    ): PdshNavFacts {
        // The first snapshot after the transition may beat the state collector;
        // starting the spell here keeps the uptime from reading 未知 for it.
        if (state is EngineHostState.Running && runningSinceMillis == null) {
            runningSinceMillis = clock.monotonicMillis()
        }
        val measured = buildNavFacts(hostReadings(), state, handshake, turn, preferenceStore.snapshot())
        return measured.copy(settings = measured.settings.copy(engineLifecycle = nativeEngineLifecycle()))
    }

    /**
     * Performs one settings-page picker or stepper choice.
     *
     * The shell hands the row and option ids over unchanged; the store owns the
     * vocabulary and answers `false` for a row it does not write, so the caller
     * can say 「宿主未实现」 instead of showing a change that never landed.
     *
     * @param rowId `SettingsScreenState`'s row id (or a `preference.fontSize.*` id).
     * @param optionId the picker's option id, or a size as decimal text.
     */
    internal fun applyPreference(rowId: String, optionId: String): Boolean =
        preferenceStore.apply(rowId, optionId)

    internal suspend fun writePreferenceConfirmed(
        requestId: com.phonedsh.ui.state.StateRequestId,
        change: ConfirmedPreferenceChange,
    ): PreferenceWriteReceipt = preferenceStore.writeConfirmed(requestId, change)

    internal fun confirmedPreferenceChange(rowId: String, optionId: String): ConfirmedPreferenceChange? =
        preferenceStore.confirmedChange(rowId, optionId)

    /** Refreshes the source-backed permission namespace for SettingsRoute. */
    internal suspend fun refreshDefaultPermissionTier(): String? = withContext(Dispatchers.IO) {
        defaultPermissionGateway.refresh(defaultPermissionApi())
    }

    /**
     * The live `/api` adapter for the default-permission reads and its one
     * confirmed write. It is a method (not a field) so a channel reopen is
     * picked up by the next refresh instead of holding a closed connection.
     */
    private fun defaultPermissionApi(): DefaultPermissionApi = DshDefaultPermissionApi(
        DshTurnClient(host.channel, ::logTurn),
    )

    /** The production wrapper around [DshTurnClient.call]. */
    private class DshDefaultPermissionApi(
        private val client: DshTurnClient,
    ) : DefaultPermissionApi {
        override suspend fun call(
            endpoint: String,
            args: JsonObject,
            timeoutMillis: Long,
        ): JsonValue = client.call(endpoint, args, timeoutMillis)
    }

    /**
     * Reads the four DSH configuration sources and publishes them. Each source
     * keeps its own failure; a failed source clears only its section.
     *
     * @return the first partial failure, or `null` when all four reads succeeded.
     */
    internal suspend fun refreshConfiguration(): String? = withContext(Dispatchers.IO) {
        configurationRefreshMutex.withLock {
            mutableConfiguration.update { it.copy(loading = true) }
            try {
                val facts = readConfigurationFacts(DshTurnClient(host.channel, ::logTurn))
                mutableConfiguration.value = facts.copy(loading = false)
                val snapshot = facts.snapshot ?: return@withLock "本会话设置读取失败"
                listOfNotNull(
                    snapshot.settingsFailure,
                    snapshot.inventoryFailure,
                    snapshot.permissionFailure,
                    snapshot.modelCatalogFailure,
                ).firstOrNull()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                mutableConfiguration.update {
                    it.copy(
                        loading = false,
                        failure = failure.message?.substringBefore('\n')?.take(180)
                            ?: "本会话设置读取失败",
                    )
                }
                failure.message?.substringBefore('\n')?.take(180) ?: "本会话设置读取失败"
            } finally {
                mutableConfiguration.update { if (it.loading) it.copy(loading = false) else it }
            }
        }
    }

    /**
     * Re-reads `agentPresets/list` and publishes the roster behind 预设.
     *
     * Runs on the IO lane; the page only ever sees the resulting facts. A failed
     * re-read keeps the roster that was already read (iOS `refresh()`'s catch)
     * and sets only `error`, so a transient channel loss cannot turn a known
     * roster into "unknown".
     *
     * @return the `code: message` failure, or `null` when the read succeeded.
     */
    internal suspend fun refreshAgentPresets(): String? = withContext(Dispatchers.IO) {
        agentPresetsRefreshMutex.withLock {
            val previous = mutableAgentPresets.value
            mutableAgentPresets.update { it.copy(isLoading = true) }
            try {
                val read = readAgentPresets(DshTurnClient(host.channel, ::logTurn))
                val merged = read.copy(
                    presets = read.presets ?: previous.presets,
                    isLoading = false,
                )
                mutableAgentPresets.value = merged
                merged.error
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val message = presetErrorText(failure)
                mutableAgentPresets.value = previous.copy(isLoading = false, error = message)
                message
            } finally {
                mutableAgentPresets.update { if (it.isLoading) it.copy(isLoading = false) else it }
            }
        }
    }

    /**
     * 查看配置: `agentPresets/read` for one id, on the IO lane.
     *
     * The page gets either the document or the Worker's `code: message`; the
     * static 引擎没有返回… sentence is now only the empty-content answer.
     */
    internal suspend fun readAgentPresetDocument(presetId: String): AgentPresetReadOutcome =
        withContext(Dispatchers.IO) {
            val title = mutableAgentPresets.value.presets
                ?.firstOrNull { it.id == presetId }?.title
                ?: presetId
            readPresetDocument(
                client = DshTurnClient(host.channel, ::logTurn),
                presetId = presetId,
                title = title,
            )
        }

    /**
     * 使用预设: re-read the roster, then create a Worker session with
     * `session/create.request.agentPreset` and the durable App chat that owns it.
     *
     * The host shell closes the settings sheet only on `null`; a failure leaves the
     * page open with the same text returned here and stored in [agentPresets].
     */
    internal suspend fun useAgentPreset(
        presetId: String,
        requestId: com.phonedsh.ui.state.StateRequestId,
    ): String? = withContext(Dispatchers.IO) {
        mutableAgentPresets.update { it.copy(isLoading = true) }
        try {
            val result = agentPresetLauncher.use(presetId, requestId)
            if (result.failure != null) {
                mutableAgentPresets.update { it.copy(error = result.failure) }
            }
            result.failure
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            val message = presetErrorText(failure)
            mutableAgentPresets.update { it.copy(error = message) }
            message
        } finally {
            mutableAgentPresets.update {
                if (it.isLoading) it.copy(isLoading = false) else it
            }
        }
    }

    /** Legacy host-action adapter; the settings page uses the request receipt below. */
    internal suspend fun saveConfigurationGroup(namespace: String, patch: Map<String, String>): String? {
        val revision = mutableConfiguration.value.snapshot?.groups
            ?.firstOrNull { it.namespace == namespace }?.revision
            ?: return "配置分组版本未知，请刷新后重试。"
        val receipt = saveConfigurationGroupConfirmed(
            namespace, patch, revision, java.util.UUID.randomUUID().toString(),
        )
        return if (receipt.success) null else receipt.message
    }

    internal suspend fun saveConfigurationGroupConfirmed(
        namespace: String,
        patch: Map<String, String>,
        expectedRevision: Int,
        requestId: String,
    ): ConfigurationWriteReceipt = withContext(Dispatchers.IO) {
        fun failed(message: String) = ConfigurationWriteReceipt(requestId, false, message)
        val snapshot = mutableConfiguration.value.snapshot ?: return@withContext failed("本会话设置尚未读取")
        if (mutableConfiguration.value.loading) return@withContext failed("设置仍在读取，请稍后重试。")
        val group = snapshot.groups?.firstOrNull { it.namespace == namespace }
            ?: return@withContext failed("配置分组不存在")
        if (group.writable != FactState.YES) return@withContext failed("DSH 当前不允许修改这个设置分组。")
        val fields = group.fields ?: return@withContext failed("设置字段尚未读取")
        if (patch.isEmpty() || patch.keys.any { key -> fields.none { it.id == key } }) {
            return@withContext failed("配置草稿为空或包含不支持的字段。")
        }
        val kinds = fields.associate { it.id to it.kind }
        if (patch.any { (key, raw) -> configurationPatchValue(kinds[key] ?: return@any true, raw) == null }) {
            return@withContext failed("配置值格式不正确，草稿仍保留。")
        }
        patch["allowedModels"]?.let { raw ->
            val requested = configurationPatchModelIds(raw)
                ?: return@withContext failed("子 Agent 模型选择格式不正确。")
            val offered = snapshot.modelRoutes?.map { it.id }?.toSet()
                ?: return@withContext failed("模型列表未知，请刷新后重试。")
            if (!offered.containsAll(requested)) return@withContext failed("模型目录已变化，请刷新后重试。")
        }
        if (group.revision != expectedRevision) return@withContext failed("设置已被其他更改推进到新版本；草稿保留，请先撤销再编辑。")
        val client = DshTurnClient(host.channel, ::logTurn)
        val error = com.phonedsh.probe.saveConfigurationGroup(client, namespace, patch, expectedRevision, kinds)
        if (error != null) return@withContext failed(error)

        refreshConfiguration()
        val readback = mutableConfiguration.value.snapshot
        val readbackGroup = readback?.groups?.firstOrNull { it.namespace == namespace }
        if (readback?.settingsFailure != null ||
            !configurationPatchMatches(readbackGroup, patch, kinds)
        ) {
            failed("设置写入后没有在 DSH 读回中确认，草稿仍保留。")
        } else {
            ConfigurationWriteReceipt(requestId, true)
        }
    }

    /** Resets one overridden field through settings/mutate with the read revision. */
    internal suspend fun resetConfigurationField(namespace: String, field: String): String? {
        val revision = mutableConfiguration.value.snapshot?.groups
            ?.firstOrNull { it.namespace == namespace }?.revision
            ?: return "配置分组版本未知，请刷新后重试。"
        val receipt = resetConfigurationFieldConfirmed(
            namespace, field, revision, java.util.UUID.randomUUID().toString(),
        )
        return if (receipt.success) null else receipt.message
    }

    internal suspend fun resetConfigurationFieldConfirmed(
        namespace: String,
        field: String,
        expectedRevision: Int,
        requestId: String,
    ): ConfigurationWriteReceipt = withContext(Dispatchers.IO) {
        fun failed(message: String) = ConfigurationWriteReceipt(requestId, false, message)
        val snapshot = mutableConfiguration.value.snapshot ?: return@withContext failed("本会话设置尚未读取")
        if (mutableConfiguration.value.loading) return@withContext failed("设置仍在读取，请稍后重试。")
        val group = snapshot.groups?.firstOrNull { it.namespace == namespace }
            ?: return@withContext failed("配置分组不存在")
        if (group.writable != FactState.YES) return@withContext failed("DSH 当前不允许修改这个设置分组。")
        val target = group.fields?.firstOrNull { it.id == field }
            ?: return@withContext failed("设置字段不存在")
        if (!target.overridden || target.kind == ConfigurationFieldKind.MODEL_SELECTION) {
            return@withContext failed("此字段没有可恢复的覆盖值。")
        }
        if (group.revision != expectedRevision) return@withContext failed("设置已被其他更改推进到新版本；请刷新后重试。")
        val error = resetConfigurationField(
            DshTurnClient(host.channel, ::logTurn), namespace, field, expectedRevision,
        )
        if (error != null) return@withContext failed(error)
        refreshConfiguration()
        val readbackField = mutableConfiguration.value.snapshot?.groups
            ?.firstOrNull { it.namespace == namespace }?.fields?.firstOrNull { it.id == field }
        if (mutableConfiguration.value.snapshot?.settingsFailure != null || readbackField == null || readbackField.overridden) {
            failed("默认值恢复后没有在 DSH 读回中确认，页面仍保留草稿。")
        } else {
            ConfigurationWriteReceipt(requestId, true)
        }
    }

    /** Saves the new-session permission preset through the permission namespace CAS. */
    internal suspend fun saveDefaultPermission(modeId: String): String? {
        val access = mutablePermissionDefaults.value
        if (!access.writable) {
            return access.readOnlyReason
                ?: com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON
        }
        val revision = mutableConfiguration.value.snapshot?.permissionRevision
            ?: return "权限预设版本未知，请刷新后重试。"
        val receipt = saveDefaultPermissionConfirmed(modeId, revision, java.util.UUID.randomUUID().toString())
        return if (receipt.success) null else receipt.message
    }

    internal suspend fun saveDefaultPermissionConfirmed(
        modeId: String,
        expectedRevision: Int,
        requestId: String,
    ): ConfigurationWriteReceipt = withContext(Dispatchers.IO) {
        fun failed(message: String) = ConfigurationWriteReceipt(requestId, false, message)
        val permissionAccess = mutablePermissionDefaults.value
        if (!permissionAccess.writable) {
            return@withContext failed(
                permissionAccess.readOnlyReason
                    ?: com.phonedsh.ui.UiStrings.DEFAULT_PERMISSION_READ_ONLY_FALLBACK_REASON,
            )
        }
        val snapshot = mutableConfiguration.value.snapshot ?: return@withContext failed("本会话设置尚未读取")
        if (mutableConfiguration.value.loading) return@withContext failed("设置仍在读取，请稍后重试。")
        if (snapshot.permissionModes?.any { it.id == modeId } != true) {
            return@withContext failed("这个权限预设不在当前 DSH 目录中。")
        }
        if (snapshot.permissionRevision != expectedRevision) {
            return@withContext failed("新会话默认权限已被其他更改推进到新版本；草稿保留，请刷新后重试。")
        }
        val error = com.phonedsh.probe.saveDefaultPermissionMode(
            DshTurnClient(host.channel, ::logTurn), modeId, expectedRevision,
        )
        if (error != null) return@withContext failed(error)
        refreshConfiguration()
        val readback = mutableConfiguration.value.snapshot
        if (readback?.permissionFailure != null || readback?.defaultPermissionModeId != modeId) {
            failed("新会话默认权限写入后没有在 DSH 读回中确认，草稿仍保留。")
        } else {
            ConfigurationWriteReceipt(requestId, true)
        }
    }

    /**
     * Writes the same DSH permission namespace used by iOS and confirms by readback.
     *
     * The locked check happens inside [DefaultPermissionGateway.write] before
     * the first `/api` call, so a startup-locked phone never emits the
     * `settings/update` the engine would refuse.
     */
    internal suspend fun writeDefaultPermissionTier(tier: com.phonedsh.ui.page.PermissionTier) {
        defaultPermissionGateway.write(defaultPermissionApi(), tier)
    }

    /** 显示代码工作视图. */
    internal fun setDeveloperTools(value: Boolean) {
        preferenceStore.setDeveloperTools(value)
    }

    /** 繁忙时的发送行为. */
    internal fun setBusyEnterMode(mode: BusyEnterMode) {
        preferenceStore.setBusyEnterMode(mode)
    }

    /** 后台运行: whether the next turn should open a background window. */
    internal fun setBackgroundKeepAlive(value: Boolean) {
        preferenceStore.setBackgroundKeepAlive(value)
    }

    /** The host's wall reading for the sessions page's relative-time labels. */
    internal fun nowMillis(): Long = clock.nowMillis()

    /**
     * Re-reads the sessions the journal lane stored.
     *
     * The journal is this host's only durable per-session store, so it is the
     * only honest source for a session list.
     *
     * **Known cost, and the fix.** This is a second `recover()` scan of the
     * journal (the host already ran one during `start()`). It is correct today:
     * [JournalStore.recover] is documented as idempotent, and the store's mutex
     * serialises this scan with the host's own recovery and with any in-flight
     * append, so no torn read or lost record can result. It is **not the
     * designed end state**: the right fix is for `:dsh` to expose a read-only
     * journal-watermarks accessor, and this method should then read that API
     * instead of scanning the store a second time.
     *
     * The scan runs off the main thread, and the rows change only when it
     * returns, never on the gesture that asked for it.
     */
    internal fun refreshSessions() {
        if (!sessionScanInFlight.compareAndSet(false, true)) return
        mutableSessions.update { it.copy(scanInFlight = true) }
        turnScope.launch {
            try {
                val scan = withContext(Dispatchers.IO) { readJournalSessions() }
                // A journal row a chat already owns must not also list as its own
                // conversation: the chat's row (with its title) is the one row.
                val claimed = chatWorkerClaims
                mutableSessions.update { snapshot ->
                    snapshot.copy(
                        waiting = false,
                        failure = scan.failure,
                        sessions = mergeSessions(
                            scan.sessions.filterNot { it.id in claimed },
                            snapshot.sessions,
                        ),
                    )
                }
            } finally {
                sessionScanInFlight.set(false)
                mutableSessions.update { it.copy(scanInFlight = false) }
            }
        }
    }

    /** Hides the last read failure; the rows from the last good read stay. */
    internal fun clearSessionsFailure() {
        mutableSessions.update { it.copy(failure = null) }
    }

    private val turnRunning = AtomicBoolean(false)
    private val mutableTurn = MutableStateFlow<AppTurnState>(AppTurnState.Idle)

    /** The one turn's UI state; [runTurn] is the only writer. */
    internal val turn: StateFlow<AppTurnState> = mutableTurn.asStateFlow()

    private val mutableSessions = MutableStateFlow(HostSessionSnapshot())

    /** The host's session read; [refreshSessions] and a completed turn write it. */
    internal val sessions: StateFlow<HostSessionSnapshot> = mutableSessions.asStateFlow()

    /** One journal scan at a time; a second request while one runs is ignored. */
    private val sessionScanInFlight = AtomicBoolean(false)

    // ---------------------------------------------------------------- chat lane

    /**
     * The chat transcript cache: the App's own stable conversation records.
     *
     * `SessionArchive` (the L65 lane) keeps the settled tail's *kinds*, which is
     * enough for the probe's summary but not for painting a conversation after a
     * cold start. This store keeps the rendered node sequence (see
     * `ChatSessionStore`); neither is the authority for the events — the journal is.
     */
    internal val chatStore = ChatSessionStore(domainStore)

    private val mutableChat = MutableStateFlow(ChatUiState())

    /**
     * 停止's one state+persist path. The writer is this ViewModel's existing
     * `persistChat`, so metadata fixes in that method apply to stop too.
     */
    private val chatStop = ChatStopWiring(mutableChat, turnRunning) { persistChat(it) }

    /** The chat screen's host state; the App's one writer is this view model. */
    internal val chat: StateFlow<ChatUiState> = mutableChat.asStateFlow()
    internal val currentChatId: String get() = mutableChat.value.chatId

    /** One request-bound child-session open at a time; never retarget a late history read. */
    private var activeSubagentOpenRequestId: String? = null

    /**
     * The Worker session ids a chat record has claimed.
     *
     * The journal lists Worker sessions; a chat owns one or more of them across
     * restarts (each restart creates a new Worker session in the same chat), so
     * the list must not also show them as separate conversations.
     */
    @Volatile
    private var chatWorkerClaims: Set<String> = emptySet()

    /** The running chat turn, or `null`; cancelling it is 停止. */
    private var chatTurnJob: kotlinx.coroutines.Job? = null

    /** The turn's runner, kept so 停止 can reach the Worker's cancel endpoint. */
    @Volatile
    private var chatRunner: ChatTurnRunner? = null
    private var activeRetryRequestId: String? = null

    /** A monotonic counter for node ordinals; never reset, so ids stay unique. */
    private var chatOrdinal: Int = 0

    /**
     * Identifies the current chat turn's cleanup.
     *
     * 停止 invalidates the cancelled job's generation before starting a new one,
     * so that job's `finally` cannot clear the new turn's live state when the
     * next send starts immediately.
     */
    private val chatTurnGeneration = AtomicLong(0L)

    @Volatile
    private var sealedBusyGeneration = -1L
    private val busySubmissionVersion = AtomicLong(0L)

    private val turnScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** The ViewModel's queue transaction, bound to the same state and Worker channel. */
    private val chatQueueActions: ChatQueueActions by lazy {
        ChatQueueActions(
            chat = mutableChat,
            scope = turnScope,
            transport = DshChatQueueTransport(host.channel, ::logTurn),
            refresh = { refreshChatSession() },
            log = ::logTurn,
        )
    }

    init {
        // budgets.md §4 evidence: the raw ceiling and the row it selects. The
        // host prints the row it was given (its `budget tier:` line); this one
        // names the measurement the row came from, so a device that reports
        // 2 GiB cannot be mistaken for one that reported 8 GiB.
        HostBudgetTier.readTotalMemoryBytes(application)?.let { totalMem ->
            LogcatHostLog.info(
                "device memory: totalMem=$totalMem bytes; budget tier: " +
                    "${deviceBudgets.tier.displayName}; single_file_limit: " +
                    "${deviceBudgets.singleFileBytes} bytes " +
                    "(${deviceBudgets.singleFileBytes / ControllerBudgets.MIB} MiB); " +
                    "Worker env ${HostBudgetTier.SINGLE_FILE_LIMIT_ENV}=" +
                    "${deviceBudgets.singleFileBytes}",
            )
        } ?: LogcatHostLog.warn(
            "device memory: totalMem unavailable; budget tier " +
                "${deviceBudgets.tier.displayName} (the smallest row) applies",
        )
        // P27 evidence: the route this launch published to the Worker, printed
        // before the first turn so a reader can tell "the model was refused
        // because this launch had no route" from "the model refused the
        // credential". No endpoint and no key appears here.
        LogcatHostLog.info(modelRouteLine())
        channelSeam.attach(host.channelHandler)
        // The Bot listener must be live before the first page load: the engine
        // reads its URL into the Worker env at launch time. The Activity's
        // onStart/onStop then keep these services on the foreground lifecycle.
        runCatching { appBotRuntime?.start() }
            .onFailure { error ->
                Log.w(TAG_TURN, "Bot runtime start failed: ${error.javaClass.simpleName}")
            }
        restoreSessionArchive()
        restoreChatSessions()
        // Asynchronous by contract: recovery, the final HELLO and engine.start()
        // run on the host's scope. Observe engine.state for the outcome.
        host.start()
        // C5: observe the PC client and load the identity/record in the
        // background. With no record this only creates the first-run identity;
        // it never dials the relay.
        pcWorkspace?.start()
        // The runtime page's uptime is the length of the current Running spell,
        // measured on the monotonic clock so a wall-clock change cannot move it.
        // A host that could not recover its WAL advertises no `wal/1`; the worker
        // then refuses to boot and the screen would otherwise keep saying
        // 「运行中」. Raising it here is the only surface that reaches the user.
        turnScope.launch {
            engine.handshake.collect { summary ->
                val caps = summary?.hostCapabilities ?: return@collect
                // The engine publishes a worker-only summary with empty host caps
                // before the host caps merge. Only a non-empty list can prove the
                // host omission; reading the empty one as "wal/1 missing" raises a
                // false banner on every healthy boot (measured 2026-11-01).
                if (caps.isEmpty()) return@collect
                if ("wal/1" in caps) {
                    ProbeRecovery.clearWalUnavailable()
                } else {
                    ProbeRecovery.raiseWalUnavailable(caps)
                }
            }
        }
        turnScope.launch {
            engine.state.collect { next ->
                when (next) {
                    is EngineHostState.Running -> if (runningSinceMillis == null) {
                        runningSinceMillis = clock.monotonicMillis()
                    }

                    EngineHostState.Stopped, is EngineHostState.Failed ->
                        runningSinceMillis = null

                    EngineHostState.Starting, EngineHostState.Recovering -> Unit
                }
            }
        }
        if (launchConfig.egressProbe) {
            turnScope.launch { runEgressProbe() }
        }
    }

    fun start() = host.start()

    fun stop() = host.stop()

    private val nativeLaunchStarted = AtomicBoolean(false)
    private val sendStartupInFlight = AtomicBoolean(false)

    internal fun startNativeSurface() {
        if (!nativeLaunchStarted.compareAndSet(false, true)) return
        if (host.state.value == com.phonedsh.controller.HostState.FAILED) restartChatEngine() else start()
    }

    internal fun nativeEngineLifecycle(): com.phonedsh.ui.state.EngineLifecycleFacts {
        val failed = host.state.value == com.phonedsh.controller.HostState.FAILED || state.value is EngineHostState.Failed
        val status = if (failed) com.phonedsh.ui.state.EngineLifecycleStatus.FAILED else when (state.value) {
            EngineHostState.Stopped -> com.phonedsh.ui.state.EngineLifecycleStatus.STOPPED
            EngineHostState.Starting -> com.phonedsh.ui.state.EngineLifecycleStatus.STARTING
            EngineHostState.Recovering -> com.phonedsh.ui.state.EngineLifecycleStatus.RECOVERING
            is EngineHostState.Running -> com.phonedsh.ui.state.EngineLifecycleStatus.RUNNING
            is EngineHostState.Failed -> com.phonedsh.ui.state.EngineLifecycleStatus.FAILED
        }
        return com.phonedsh.ui.state.EngineLifecycleFacts(status, needsReset = failed,
            canStartBySending = status == com.phonedsh.ui.state.EngineLifecycleStatus.STOPPED &&
                modelRoute.route != ModelRoute.NONE && !sendStartupInFlight.get())
    }

    internal fun restartChatEngine() {
        stopChat()
        chatPreparationJob?.cancel()
        turnScope.launch {
            try {
                host.stop()
                host.start()
                withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
                host.resetFailure()
                withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                    host.state.first { it == com.phonedsh.controller.HostState.RUNNING }
                    engine.state.first { it is EngineHostState.Running }
                }
                mutableChat.update { it.copy(error = null, bannerDismissed = false) }
                prepareChatSession()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                mutableChat.update { it.copy(error = "引擎还没恢复，请查看运行状态后重试。", bannerDismissed = false) }
            }
        }
    }

    /**
     * The one line that records this launch's model route.
     *
     * Its counterpart is the Worker's refusal (`plugins/worker-entry/src/model-route.ts`):
     * the host publishes `PDSH_MODEL_ROUTE`, the Worker refuses on `none`, and
     * this line is what makes the two halves verifiable in one logcat capture.
     */
    private fun modelRouteLine(): String = buildString {
        append("model route: ").append(modelRoute.route.wire)
        append(" (Worker env ").append(ModelRouteFact.ENV).append('=')
        append(modelRoute.route.wire)
        modelRoute.missing?.let {
            append(", ").append(ModelRouteFact.MISSING_ENV).append('=').append(it.wire)
        }
        append("); ")
        when (modelRoute.route) {
            ModelRoute.HOST_EDGE -> append("model requests are answered by the host edge")
            ModelRoute.DIRECT -> append("the Worker talks to the launch's base URL directly")
            ModelRoute.NONE -> append(modelRoute.missing!!.sentence)
                .append(": the Worker refuses model requests locally instead of ")
                .append("falling back to the public DeepSeek API")
        }
    }

    /**
     * The turn-failure text, with this launch's route fact appended when it has none.
     *
     * The appended sentence states a fact about the **launch**, not a claim about
     * the cause: on a routeless launch the Worker refused the model request
     * locally, which is why the turn's end reason is `error`, and the reader must
     * not be sent to look for a wrong key.
     */
    private fun failureText(reason: String): String {
        val diagnosis = modelRoute.diagnosis() ?: return reason
        return "$reason; $diagnosis"
    }

    /**
     * Starts one turn through the App's own `/api` path.
     *
     * Idempotent while a turn is in flight. The prompt is the launch-configured
     * text, not a model call: the acceptance upstream is scripted.
     *
     * A launch with no model route still runs the turn: the refusal belongs to
     * the Worker (the only layer that can keep `llm-deepseek` from falling back
     * to its public base), and running it is what proves the refusal happens
     * before any request leaves the device. [failureText] then names the missing
     * input in the App's own line.
     */
    fun runTurn(prompt: String = launchConfig.prompt) {
        if (!turnRunning.compareAndSet(false, true)) {
            Log.i(TAG_TURN, "turn ignored: one is already running")
            return
        }
        Log.i(TAG_TURN, "APP_TURN_BUTTON prompt=${prompt.length} chars")
        // Durable tombstone before the first await: a process killed during the
        // turn leaves it behind, and the next launch reports "interrupted at step
        // N" instead of silently showing a half session.
        val epoch = ProbeRecovery.beginTurn(getApplication<Application>())
        // The background window opens *before* the first await, while this button
        // gesture still counts as visible: UIDT cannot be scheduled from a
        // backgrounded app (plan §7.10-B2) and a foreground service cannot be
        // started from the background on Android 12+. The result is the platform's
        // answer, not an assumption; a foreground-only answer is logged as such.
        //
        // 后台运行 is the one preference that changes a turn's behaviour: off
        // means no window is opened at all and the turn runs foreground-only
        // (`ChatModel.swift:43-49` is the baseline's switch; on Android the
        // equivalent of the silent-audio session is this foreground-service
        // window). The tombstone above is still written either way: a turn can
        // die without a window, and the next launch must still report it.
        if (preferenceStore.snapshot().backgroundKeepAlive) {
            HostBackground.startTurn(
                getApplication<Application>(),
                epoch,
                backgroundDeclaration,
            )
        } else {
            Log.i(TAG_TURN, "BG_TURN_SKIPPED reason=preference backgroundKeepAlive=false")
        }
        mutableTurn.value = AppTurnState.Running
        turnScope.launch {
            try {
                withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
                withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                    engine.state.first { it is EngineHostState.Running }
                }
                val client = DshTurnClient(host.channel, ::logTurn)
                // The prompt is the caller's (the composer's in the chat lane); the
                // launch extra is only the default for the probe's own button.
                val result = client.runTurn(prompt)
                for (event in result.events) logTurn("host event: ${event.describe()}")
                // Completion is the Worker's own edge, not the shape of its tool
                // use: a turn that answered without calling a tool is still a
                // completed turn. Gating on the tool edges reported a plain Q&A
                // turn as `incomplete` while its `turn/end` said `completed`
                // (measured 2026-11-01), which is the one thing this screen may
                // not do. `sawTheFourEdges` is kept as a separate observation of
                // the tool lane and logged next to the OK line.
                val answered = result.events.any { it.kind == HostEventKind.ASSISTANT_MESSAGE }
                val complete = result.turnEndReason == "completed" && answered
                if (complete) {
                    logTurn(
                        "APP_TURN_OK session=${result.sessionId} " +
                            "kinds=${result.kinds.joinToString(",")} reason=completed " +
                            "tool_edges=${result.sawTheFourEdges}",
                    )
                    ProbeRecovery.endTurn(getApplication<Application>())
                    val completed = AppTurnState.Completed(
                        sessionId = result.sessionId,
                        kinds = result.kinds,
                        commands = toolCommands(result.events),
                        writes = toolWrites(result.events),
                    )
                    mutableTurn.value = completed
                    recordCompletedTurn(result.sessionId)
                    // After the screen already has the turn: a store refusal
                    // must not turn a completed turn into a failed one.
                    archiveCompletedTurn(completed, clock.nowMillis())
                } else {
                    failTurn(
                        failureText(
                            "incomplete: kinds=${result.kinds.joinToString(",")} " +
                                "reason=${result.turnEndReason ?: "-"}",
                        ),
                    )
                }
            } catch (timeout: TimeoutCancellationException) {
                failTurn(failureText("timeout"))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                failTurn(failureText(reasonOf(failure)))
            } finally {
                turnRunning.set(false)
                // A cancelled scope (ViewModel cleared, host stopped) is not an
                // explicit end above, so the window and the marker are closed here:
                // a background window left open holds a notification nothing owns.
                // Every other path already ended the turn, and ending it twice is a
                // no-op (the marker is gone and no window is running).
                if (mutableTurn.value is AppTurnState.Running) {
                    ProbeRecovery.endTurn(getApplication<Application>())
                }
            }
        }
    }

    /**
     * The commands the turn's `tool_call` events named.
     *
     * `tool_call.arguments` is the contract's one arbitrary-JSON member, and the
     * worker encodes it as a JSON *string* (the trajectory goldens carry
     * `"arguments":"{\"cmd\":\"ls\"}"`), so both a string and an object are
     * accepted. Non-JSON or argument-less calls yield no row: a tool name alone is
     * never rendered as a command.
     */
    private fun toolCommands(events: List<HostEvent>): List<TurnToolCommand> =
        events.mapNotNull { event ->
            if (event.kind != HostEventKind.TOOL_CALL) return@mapNotNull null
            val data = event.data ?: return@mapNotNull null
            val arguments = argumentsOf(data) ?: return@mapNotNull null
            val command = (arguments["command"] as? JsonString)?.value
                ?: (arguments["cmd"] as? JsonString)?.value
                ?: return@mapNotNull null
            val id = (data["callId"] as? JsonString)?.value
                ?: (data["call_id"] as? JsonString)?.value
                ?: command
            TurnToolCommand(id = id, command = command)
        }

    /**
     * The paths the turn's write tools named.
     *
     * Only the three tool names §2 folds into the changed-files card are
     * recognised; any other tool yields no row, because this host has not
     * measured whether it wrote a file.
     */
    private fun toolWrites(events: List<HostEvent>): List<TurnWrite> =
        events.mapNotNull { event ->
            if (event.kind != HostEventKind.TOOL_CALL) return@mapNotNull null
            val data = event.data ?: return@mapNotNull null
            val toolName = (data["name"] as? JsonString)?.value ?: return@mapNotNull null
            if (toolName !in WRITE_TOOLS) return@mapNotNull null
            val arguments = argumentsOf(data)
            val path = (arguments?.get("path") as? JsonString)?.value
                ?: (arguments?.get("file_path") as? JsonString)?.value
                ?: (arguments?.get("filePath") as? JsonString)?.value
                ?: (data["path"] as? JsonString)?.value
                ?: return@mapNotNull null
            TurnWrite(path = path, toolName = toolName)
        }

    /**
     * The `arguments` object of a `tool_call`, decoded from either encoding.
     *
     * Returns `null` when the member is absent, is not JSON, or does not decode to
     * an object: the caller then renders no row rather than a guessed one.
     */
    private fun argumentsOf(data: JsonObject): JsonObject? =
        when (val raw = data["arguments"] ?: data["input"]) {
            is JsonObject -> raw
            is JsonString -> runCatching { JsonValue.parse(raw.value) as? JsonObject }.getOrNull()
            else -> null
        }

    /**
     * Exercises the App's own `/v1/http` route with two requests: one to the
     * exact launch origin (must be 200) and one to an unlisted origin (must be
     * 403 without upstream contact). Diagnostic only; it is started when the
     * launch asked for it, and it logs status codes and stable codes only.
     */    private suspend fun runEgressProbe() {
        try {
            withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
            withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                engine.state.first { it is EngineHostState.Running }
            }
            val running = engine.state.value as? EngineHostState.Running ?: return
            val base = launchConfig.deepseekBaseUrl ?: return
            val token = launchToken.current() ?: return
            val allowed = probeEgress(running.origin, token, base.trimEnd('/') + "/health")
            if (allowed == 200) {
                Log.i(TAG_TURN, "APP_EGRESS_OK status=$allowed")
            } else {
                Log.e(TAG_TURN, "APP_EGRESS_FAILED status=$allowed")
            }
            val denied = probeEgress(running.origin, token, "https://unlisted.example/")
            if (denied == 403) {
                Log.i(TAG_TURN, "APP_EGRESS_DENIED status=$denied")
            } else {
                Log.e(TAG_TURN, "APP_EGRESS_NOT_DENIED status=$denied")
            }
        } catch (timeout: TimeoutCancellationException) {
            Log.e(TAG_TURN, "APP_EGRESS_FAILED reason=timeout")
        } catch (failure: Exception) {
            Log.e(TAG_TURN, "APP_EGRESS_FAILED reason=${failure.javaClass.simpleName}")
        }
    }

    /** One POST to the App's own `/v1/http`; returns the status, never a body. */
    private suspend fun probeEgress(origin: String, token: String, target: String): Int =
        withContext(Dispatchers.IO) {
            val connection = URI("$origin/v1/http").toURL().openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 5_000
                connection.readTimeout = 15_000
                connection.setRequestProperty("Authorization", "Bearer $token")
                connection.setRequestProperty("X-PDSH-Target-URL", target)
                connection.setRequestProperty("X-PDSH-Target-Method", "GET")
                connection.doOutput = true
                connection.outputStream.use { it.write(ByteArray(0)) }
                val status = connection.responseCode
                runCatching { connection.errorStream?.use { stream -> stream.readBytes() } }
                runCatching { connection.inputStream?.use { stream -> stream.readBytes() } }
                status
            } finally {
                runCatching { connection.disconnect() }
            }
        }

    // ---------------------------------------------------------------- chat lane
    //
    // The three calls of a chat turn are the same ones 跑一轮 uses (`session/create`,
    // `session/follow`, `session/prompt`); the difference is that this path takes the
    // prompt from the composer, keeps one stable conversation across turns and cold
    // starts, renders the live text, and can stop the turn.
    //
    // Persistence is serialised on one IO thread: every write of a chat record is
    // submitted in the order the screen produced it, so a later save can never be
    // overtaken by an earlier one.

    private val chatIo = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))

    /**
     * The `@` menu's candidates, read on the IO lane.
     *
     * The files are the same materialized workspace the files page and the preview
     * read; the titles come from the durable session store and exclude the
     * conversation already on screen. The composition root calls this from a
     * `LaunchedEffect`, never from `chatSurfaceState()` itself, so a frame never
     * walks the workspace.
     */
    internal suspend fun chatMentionFacts(
        currentChatId: String = mutableChat.value.chatId,
    ): ChatMentionFacts = withContext(Dispatchers.IO) {
        val files = try {
            WorkspacePreviewSource(walPaths.materializedWorkspace).files()
                .orEmpty()
                .map { it.relativePath }
                .take(CHAT_MENTION_FILE_LIMIT)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            emptyList()
        }
        val records = try {
            chatStore.loadAll()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            emptyList()
        }
        ChatMentionFacts(
            files = files,
            sessionTitles = chatMentionSessionTitles(records, currentChatId),
        )
    }

    /** The page's state, assembled from the host's own readings. */
    internal fun chatSurfaceState(
        files: List<String> = emptyList(),
        sessionTitles: List<String> = emptyList(),
    ): ChatScreenState = chatScreenState(
        ui = mutableChat.value,
        engineStarted = state.value is EngineHostState.Running && host.state.value != com.phonedsh.controller.HostState.FAILED,
        providerNeedsKey = modelRoute.route == ModelRoute.NONE,
        canSend = state.value is EngineHostState.Running && host.state.value != com.phonedsh.controller.HostState.FAILED,
        canSteer = state.value is EngineHostState.Running && mutableChat.value.workerSessionId != null,
        enterMode = when (preferenceStore.snapshot().busyEnterMode) {
            BusyEnterMode.QUEUE -> com.phonedsh.ui.state.EnterMode.QUEUE
            BusyEnterMode.STEER -> com.phonedsh.ui.state.EnterMode.STEER
        },
        lifecycle = nativeEngineLifecycle(),
        performanceUsage = preferenceStore.snapshot().performanceUsage,
        files = files,
        sessionTitles = sessionTitles,
    )

    /** What the person typed. Local state; the page never stores it. */
    internal fun chatDraftChanged(text: String) {
        mutableChat.update { current ->
            if (current.draft == text) current else current.copy(draft = text, retryBusyPromptRequestId = null)
        }
    }

    internal fun chatWorkspaceSnapshot(): Pair<Boolean, String?> =
        Files.isDirectory(walPaths.materializedWorkspace) to "/dsh/workspace"

    /** Shell capabilities and limits come from this boot's real ExecBridge and accelerators. */
    internal fun shellSnapshot(run: ShellRun = ShellRun()): ShellSnapshot {
        val commands = host.readOnlyAcceleratorNames()
        val mounts = listOf(walPaths.materializedWorkspace, walPaths.materializedHome).count(Files::isDirectory)
        return ShellSnapshot(
            commands = commands,
            environment = if (commands.isEmpty()) "pdsh-shell unavailable" else "pdsh-shell via DSH exec/1",
            mounts = mounts,
            limits = ShellLimits(
                timeoutMilliseconds = AcceleratorLimits.DEFAULT_TIMEOUT_MS,
                maxOutputBytes = ShellAcceleratorTool.MAX_OUTPUT_BYTES,
                maxFiles = AcceleratorLimits.DEFAULT_MAX_FILES.toInt(),
                maxFileBytes = AcceleratorLimits.DEFAULT_MAX_FILE_BYTES,
            ),
            run = run,
        )
    }

    /** Creates one source-shaped interactive EXEC_REQ through the registered read-only bridge. */
    internal fun shellExecRequest(
        command: String,
        workingDirectory: String,
        arguments: String,
        requestId: com.phonedsh.ui.state.StateRequestId,
    ): ExecRequest? = ShellExecRequestFactory.create(
        command = command,
        workingDirectory = workingDirectory,
        arguments = arguments,
        requestId = requestId,
        availableCommands = host.readOnlyAcceleratorNames(),
        mountedRoots = buildList {
            if (Files.isDirectory(walPaths.materializedWorkspace)) add("/dsh/workspace")
            if (Files.isDirectory(walPaths.materializedHome)) add("/dsh/home")
        },
        requiresMseq = host.appliedWorkspaceMseq(),
        deadline = clock.nowMillis() + AcceleratorLimits.DEFAULT_TIMEOUT_MS,
    )

    internal fun runShellRequest(request: ExecRequest): Flow<ExecEvent> = host.runReadOnlyAccelerator(request)

    internal fun cancelShellRequest(execId: String) = host.cancelReadOnlyAccelerator(execId)


    internal fun chatImeChanged(visible: Boolean) {
        mutableChat.update { it.copy(imeVisible = visible) }
    }

    internal fun expandChatPending() {
        mutableChat.update { it.copy(pendingExpanded = true) }
    }

    internal fun toggleChatRow(id: String) {
        mutableChat.update { it.copy(expandedRowIds = if (id in it.expandedRowIds) {
            it.expandedRowIds - id
        } else it.expandedRowIds + id) }
    }

    internal fun archiveChatSession(chatId: String): Boolean = updateChatMetadata(chatId) {
        chatStore.setArchived(chatId, true)
    }

    internal fun restoreChatSession(chatId: String): Boolean = updateChatMetadata(chatId) {
        chatStore.setArchived(chatId, false)
    }

    internal fun setChatSessionPinned(chatId: String, pinned: Boolean): Boolean = updateChatMetadata(chatId) {
        chatStore.setPinned(chatId, pinned)
    }

    private fun updateChatMetadata(chatId: String, write: () -> Boolean): Boolean {
        if (mutableChat.value.chatId == chatId && mutableChat.value.running) return false
        if ((mutableSessions.value.sessions + mutableSessions.value.archivedSessions).none { it.id == chatId }) return false
        chatIo.launch {
            runCatching {
                check(write()) { "会话不存在，修改没有保存" }
                applyChatRecords(chatStore.loadAll())
            }.onFailure {
                mutableSessions.update { snapshot -> snapshot.copy(failure = "会话修改没有保存，请重试。") }
            }
        }
        return true
    }

    private fun applyChatRecords(records: List<ChatRecord>) {
        applyChatRecordsTo(records, mutableSessions, mutableChat, syncCurrentTitle = false)
    }

    /**
     * Re-reads chat metadata after a HostShell session command wrote [chatStore].
     *
     * The HostShell rename/archive/restore paths write the store directly, so the
     * in-memory session rows and the open conversation keep the values they had
     * before that write. Applying the store's own readback makes the archived
     * list, the settings count and the drawer agree at once; mirroring the open
     * conversation's title here is what stops the next [persistChat] from writing
     * the old name back over a rename.
     */
    internal suspend fun reloadChatMetadata() {
        runCatching {
            reloadChatMetadataInto(chatStore, mutableSessions, mutableChat)
        }.onFailure {
            mutableSessions.update { snapshot -> snapshot.copy(failure = "会话列表刷新失败，请重试。") }
        }
    }

    private data class ChatResponder(
        val request: com.phonedsh.dsh.turn.PendingRemoteRequest,
        val answer: suspend (JsonValue) -> Unit,
    )
    private val chatResponders = java.util.concurrent.ConcurrentHashMap<String, ChatResponder>()
    private val answeringRequests = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private val snapshotRefreshInFlight = AtomicBoolean(false)
    private val snapshotFullRefreshQueued = AtomicBoolean(false)
    /**
     * Automatic permission-read retries for one Worker session (iOS
     * `ChatModel.refreshAccessModes`): a fresh session's permission fold can
     * lag its open, so a failed read is retried on a short backoff instead of
     * showing a banner with a retry button.
     */
    private val accessRetryAttempt = java.util.concurrent.atomic.AtomicInteger(0)
    @Volatile private var accessRetryWorker: String? = null
    private var chatSnapshotJob: kotlinx.coroutines.Job? = null
    private var chatPreparationJob: kotlinx.coroutines.Job? = null
    private val hostAutomation by lazy {
        HostAutomation({ endpoint, args -> DshTurnClient(host.channel, ::logTurn).call(endpoint, args) },
            { mutableChat.value.workerSessionId }, turnScope)
    }
    internal val automation: StateFlow<com.phonedsh.ui.page.AutomationFacts> get() = hostAutomation.facts
    internal fun refreshAutomation() = hostAutomation.refresh()
    internal fun handleAutomationAction(action: com.phonedsh.ui.nav.PdshHostAction): Boolean {
        when (action) {
            com.phonedsh.ui.nav.PdshHostAction.RefreshAutomation -> hostAutomation.refresh()
            is com.phonedsh.ui.nav.PdshHostAction.SaveAutomationSchedule -> hostAutomation.save(action.draft, action.submissionID)
            is com.phonedsh.ui.nav.PdshHostAction.DeleteAutomationSchedule -> hostAutomation.delete(action.id)
            is com.phonedsh.ui.nav.PdshHostAction.LoadAutomationHistory -> hostAutomation.history(action.id, action.before)
            else -> return false
        }
        return true
    }

    internal fun prepareChatSession() {
        val current = mutableChat.value
        if (current.chatId.isEmpty() || state.value !is EngineHostState.Running || host.state.value == com.phonedsh.controller.HostState.FAILED) return
        if (current.workerSessionId != null) { refreshChatSession(); return }
        if (chatPreparationJob?.isActive == true) return
        chatPreparationJob = turnScope.launch(Dispatchers.IO) {
            try {
                withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
                val worker = DshTurnClient(host.channel, ::logTurn).createSessionWhenReady(cwd = "/dsh/workspace")
                if (mutableChat.value.chatId == current.chatId) claimWorkerSession(current.chatId, worker)
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                mutableChat.update { if (it.chatId != current.chatId) it else it.copy(
                    notice = "会话还没准备好，发送时会重试。",
                ) }
            }
        }
    }

    private fun receiveChatRequest(
        chatId: String,
        request: com.phonedsh.dsh.turn.PendingRemoteRequest,
        responder: suspend (JsonValue) -> Unit,
    ) {
        if (mutableChat.value.chatId != chatId) return
        chatResponders[request.eventID] = ChatResponder(request, responder)
        val node = pendingRequestNode(chatId, request)
        mutableChat.update { current ->
            if (current.chatId != chatId) current else current.copy(
                pendingNodes = current.pendingNodes.filterNot { it.nodeID == node.nodeID } + node,
            )
        }
    }

    private fun removeChatRequest(requestId: String) {
        chatResponders.remove(requestId)
        answeringRequests.remove(requestId)
        mutableChat.update { current -> current.copy(pendingNodes = current.pendingNodes.filterNot {
            (it.props["requestId"] as? JsonString)?.value == requestId
        }) }
    }

    internal fun answerChatQuestion(pending: com.phonedsh.ui.state.PendingAnswer, answer: String) {
        val responder = chatResponders[pending.requestId] ?: return
        submitChatAnswer(pending.requestId, questionOutcome(responder.request, answer))
    }

    internal fun answerChatPermission(pending: com.phonedsh.ui.state.PendingAnswer, allowed: Boolean) {
        submitChatAnswer(pending.requestId, JsonObject(mapOf(
            "kind" to JsonString("result"),
            "value" to JsonString(if (allowed) "allowed-once" else "rejected"),
        )))
    }

    internal fun dismissChatQuestion(pending: com.phonedsh.ui.state.PendingAnswer) {
        // iOS dismissQuestion only hides this seat; it never answers the waterfall.
        // Keep the responder until the Worker resolves or re-delivers the request.
        mutableChat.update { current -> current.copy(pendingNodes = current.pendingNodes.filterNot {
            (it.props["requestId"] as? JsonString)?.value == pending.requestId
        }) }
    }

    private fun submitChatAnswer(requestId: String, outcome: JsonValue) {
        val responder = chatResponders[requestId] ?: return
        if (!answeringRequests.add(requestId)) return
        fun updateRequest(submitting: Boolean, error: String? = null) {
            mutableChat.update { current -> current.copy(pendingNodes = current.pendingNodes.map { node ->
                if ((node.props["requestId"] as? JsonString)?.value != requestId) node else node.copy(
                    props = JsonObject(node.props.members + mapOf(
                        "submitting" to com.phonedsh.agentcore.JsonBool(submitting),
                        "submissionError" to (error?.let(::JsonString) ?: com.phonedsh.agentcore.JsonNull),
                    )),
                )
            }) }
        }
        updateRequest(true)
        turnScope.launch {
            try {
                responder.answer(outcome)
                removeChatRequest(requestId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                updateRequest(false, "回答没有提交成功，请重试。")
            } finally {
                answeringRequests.remove(requestId)
            }
        }
    }

    /** Refresh the same live catalogs and projection used by the iOS dock. */
    internal fun refreshChatSession(full: Boolean = true) {
        val current = mutableChat.value
        val worker = current.workerSessionId ?: return
        if (!snapshotRefreshInFlight.compareAndSet(false, true)) {
            if (full) snapshotFullRefreshQueued.set(true)
            return
        }
        turnScope.launch(Dispatchers.IO) {
            val client = DshTurnClient(host.channel, ::logTurn)
            try {
                val modes = if (full) runCatching { client.call("permissionPresets/catalog", timeoutMillis = 5_000) }.getOrNull() else null
                val commands = if (full) runCatching { client.call("commands/list", JsonObject(mapOf(
                    "agentId" to JsonString(worker),
                )), timeoutMillis = 5_000) }.getOrNull() else null
                val models = if (full) runCatching { client.call("session/modelCatalog", timeoutMillis = 5_000) }.getOrNull() else null
                // DSHManagementModel reads session/list beside this exact
                // projection. Its rows supply the subagent activity and the
                // verified Worker identities the catalog may open.
                val sessions = runCatching { client.call("session/list", timeoutMillis = 5_000) }.getOrNull()
                // Read the changing projection last. Slow catalog reads must not
                // let an older goal/model/permission overwrite a later refresh.
                val projections = client.call("session/projections", JsonObject(mapOf(
                    "request" to JsonObject(mapOf("sessionId" to JsonString(worker))),
                )), timeoutMillis = 5_000)
                val read = sessionSnapshotOf(
                    projections, modes, commands, models, sessionId = worker, sessionList = sessions,
                )
                if (accessRetryWorker != worker) {
                    accessRetryWorker = worker
                    accessRetryAttempt.set(0)
                }
                val retryDelayMs = if (full && read.accessError != null) {
                    ACCESS_RETRY_DELAYS_MS.getOrNull(accessRetryAttempt.getAndIncrement())
                } else {
                    if (full) accessRetryAttempt.set(0)
                    null
                }
                // While retries remain the read is "loading", not failed.
                val measured = if (retryDelayMs != null) {
                    read.copy(accessError = null, accessLoading = true)
                } else {
                    read
                }
                if (retryDelayMs != null) {
                    turnScope.launch {
                        delay(retryDelayMs)
                        val live = mutableChat.value
                        if (live.chatId == current.chatId && live.workerSessionId == worker) {
                            refreshChatSession(full = true)
                        }
                    }
                }
                mutableChat.update { live ->
                    if (live.chatId != current.chatId || live.workerSessionId != worker) {
                        live
                    } else {
                        val snapshot = if (full) measured else live.sessionSnapshot.withProjectionUpdate(measured)
                        live.copy(
                            sessionSnapshot = snapshot,
                            // A projection that shows this rpcId is durable proof
                            // the prompt was accepted; drop the local echo so it
                            // cannot resurface as a ghost after consumption.
                            localQueueItems = retireQueuePromptsPresentIn(
                                live.localQueueItems,
                                snapshot.queueItems.orEmpty(),
                            ),
                        )
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logTurn("CHAT_SNAPSHOT_REFRESH_FAILED reason=${reasonOf(failure)}")
                // A failed session/projection read is not evidence that the
                // independently read permission/command catalogs disappeared.
                // Keep their last good values, and never attach a stale error to
                // another Worker session that became current while this read ran.
                if (mutableChat.value.chatId != current.chatId ||
                    mutableChat.value.workerSessionId != worker
                ) return@launch
            } finally {
                snapshotRefreshInFlight.set(false)
                if (snapshotFullRefreshQueued.getAndSet(false)) refreshChatSession(full = true)
            }
        }
    }

    /** Mutate one durable DSH queue item, then read the projection back before publishing success. */
    internal fun updateChatQueueItem(
        item: com.phonedsh.ui.state.ManagedQueueItemState,
        action: com.phonedsh.ui.state.QueueAction,
        requestId: com.phonedsh.ui.state.StateRequestId,
        replacement: String? = null,
    ): Boolean = chatQueueActions.updateQueueItem(item, action, requestId, replacement)

    internal fun runChatCommand(line: String, showResult: Boolean = true) {
        val current = mutableChat.value
        val worker = current.workerSessionId ?: return
        turnScope.launch(Dispatchers.IO) {
            try {
                val response = DshTurnClient(host.channel, ::logTurn).call("commands/execute", JsonObject(mapOf(
                    "agentId" to JsonString(worker), "line" to JsonString(line),
                    "submittedAttachments" to com.phonedsh.agentcore.JsonArray(emptyList()),
                )))
                val result = (response as? JsonObject)?.get("result") as? JsonObject
                val kind = (result?.get("kind") as? JsonString)?.value
                if (kind == null || kind == "error") throw IllegalStateException("command not accepted")
                mutableChat.update { if (it.chatId != current.chatId) it else it.copy(
                    draft = if (it.draft.trim() == line) "" else it.draft,
                    notice = (result["text"] as? JsonString)?.value,
                    commandExecution = if (!showResult) it.commandExecution else com.phonedsh.ui.page.ChatCommandExecution(
                        id = (response["commandId"] as? JsonString)?.value ?: java.util.UUID.randomUUID().toString(),
                        name = line.removePrefix("/").substringBefore(' '), line = line, kind = kind,
                        text = (result["text"] as? JsonString)?.value,
                    ),
                ) }
                refreshChatSession()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                mutableChat.update { if (it.chatId != current.chatId) it else it.copy(
                    notice = "命令没有执行成功，请重试。",
                ) }
            }
        }
    }

    internal fun selectChatAccessMode(id: String) {
        if (mutableChat.value.sessionSnapshot.accessModes.none { it.id == id }) return
        runChatCommand("/permission $id", showResult = false)
    }

    internal fun selectChatModel(model: String, effort: String?) {
        val current = mutableChat.value
        val worker = current.workerSessionId ?: return
        val route = current.sessionSnapshot.modelRoutes.firstOrNull {
            it.model == model && it.provider == current.sessionSnapshot.currentProvider
        } ?: current.sessionSnapshot.modelRoutes.firstOrNull { it.model == model } ?: return
        val keptEffort = effort ?: current.sessionSnapshot.currentEffort?.takeIf { existing ->
            model != current.sessionSnapshot.currentModel && route.efforts.any { it.id == existing }
        }
        if (keptEffort != null && route.efforts.none { it.id == keptEffort }) return
        turnScope.launch(Dispatchers.IO) {
            try {
                val request = linkedMapOf<String, JsonValue>("sessionId" to JsonString(worker),
                    "provider" to JsonString(route.provider), "model" to JsonString(route.model))
                keptEffort?.let { request["reasoningEffort"] = JsonString(it) }
                DshTurnClient(host.channel, ::logTurn).call("session/selectModel", JsonObject(mapOf("request" to JsonObject(request))))
                refreshChatSession()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (failure: Exception) {
                mutableChat.update { if (it.chatId != current.chatId) it else it.copy(notice = "模型没有切换成功，请重试。") }
            }
        }
    }

    /** 新建会话: a real record the session list shows immediately. */
    internal fun newChatSession(): String {
        val at = clock.nowMillis()
        val id = "chat-$at-${++chatOrdinal}"
        // A new conversation is a new session: it must not inherit the previous
        // one's 本 session 产物 attribution.
        sessionArtifacts.clear()
        chatIo.launch {
            runCatching {
                val expectedCurrentId = chatStore.currentSessionId()
                val record = ChatRecord(id, "", at, emptyList(), emptyList())
                chatStore.save(record)
                val stored = chatStore.load(id)
                check(stored == record.copy(revision = stored?.revision ?: 0L)) { "new session readback mismatch" }
                check(chatStore.selectCurrentSession(
                    id,
                    com.phonedsh.ui.state.StateRequestId("current-session:$id"),
                    expectedCurrentId = expectedCurrentId,
                ).outcome is ChatWriteOutcome.Persisted) { "current session selection not confirmed" }
            }.onFailure { failure ->
                LogcatHostLog.warn("chat: new session persistence failed session=$id (${reasonOf(failure as? Exception ?: Exception(failure))})")
            }
        }
        mutableSessions.update { snapshot ->
            snapshot.copy(
                waiting = false,
                currentSessionID = id,
                sessions = mergeSessions(emptyList(), snapshot.sessions + HostSessionRecord(id, at, workspaceID = "/dsh/workspace")),
            )
        }
        mutableChat.value = ChatUiState(chatId = id, updatedAtMs = at)
        prepareChatSession()
        LogcatHostLog.info("chat: new session $id")
        return id
    }

    /**
     * Create a conversation only after its durable record has been read back.
     *
     * @param workerSessionId a Worker session that was already created for this
     *   conversation (使用预设's `session/create` with `agentPreset`), or `null`
     *   to let [prepareChatSession] create one lazily as before. Passing it avoids
     *   a second, preset-less `session/create` racing the one the preset path
     *   just made.
     */
    internal suspend fun newChatSessionConfirmed(
        requestId: com.phonedsh.ui.state.StateRequestId,
        workspaceGroupId: String? = ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID,
        workerSessionId: String? = null,
    ):
        com.phonedsh.ui.nav.PdshActionReceipt {
        val at = clock.nowMillis()
        val id = "chat-$at-${++chatOrdinal}"
        val receipt = withContext(Dispatchers.IO) {
            createHostChatSession(chatStore, id, at, workspaceGroupId, requestId)
        }
        if (!receipt.confirms(requestId, id, null)) return receipt
        sessionArtifacts.clear()
        mutableSessions.update { snapshot ->
            snapshot.copy(
                waiting = false,
                currentSessionID = id,
                sessions = mergeSessions(emptyList(), snapshot.sessions + HostSessionRecord(id, at, workspaceID = "/dsh/workspace")),
            )
        }
        mutableChat.value = ChatUiState(chatId = id, updatedAtMs = at)
        if (workerSessionId != null) claimWorkerSession(id, workerSessionId) else prepareChatSession()
        LogcatHostLog.info("chat: new session confirmed $id")
        return receipt
    }

    /**
     * Switches to [chatId], painting its stored transcript.
     *
     * A row that the journal knows but this App never opened (a session the Worker
     * ran before the chat lane existed) is adopted as an empty conversation with
     * that Worker session id, so selecting it still opens a chat rather than
     * nothing.
     */
    internal fun openChatSession(chatId: String) {
        if (mutableChat.value.running) return
        if (mutableChat.value.chatId == chatId) return
        val originalChatId = mutableChat.value.chatId
        turnScope.launch {
            val selected = withContext(Dispatchers.IO) {
                runCatching {
                    val stored = chatStore.load(chatId)
                    val persistedCurrentId = chatStore.currentSessionId()
                    val known = mutableSessions.value.sessions.any { it.id == chatId }
                    val at = clock.nowMillis()
                    val record = (stored ?: ChatRecord(
                        id = chatId,
                        title = "",
                        updatedAtMs = at,
                        workerSessionIds = if (known) listOf(chatId) else emptyList(),
                        nodes = emptyList(),
                        // A journal-only row did not report App folder ownership;
                        // preserve it as unassigned instead of inventing 日常.
                        workspaceGroupId = null,
                    ).also { newRecord ->
                        chatStore.save(newRecord)
                        check(chatStore.load(chatId)?.id == chatId) { "adopted session readback failed" }
                    }).let { opened ->
                        // A row stored by the old stop path can still contain an
                        // open TURN. This conversation is not running here, so close
                        // it and persist before the screen paints it.
                        runCatching {
                            ChatRecordRepair(chatStore).open(
                                record = opened,
                                liveChatId = mutableChat.value.chatId,
                                turnRunning = mutableChat.value.running,
                            )
                        }.onFailure {
                            LogcatHostLog.warn("chat: stale turn repair failed session=$chatId (${reasonOf(it as? Exception ?: Exception(it))})")
                        }.getOrDefault(opened)
                    }
                    check(mutableChat.value.chatId == originalChatId || mutableChat.value.chatId == chatId) {
                        "session selection was superseded"
                    }
                    val receipt = chatStore.selectCurrentSession(
                        chatId,
                        com.phonedsh.ui.state.StateRequestId("select-session:${UUID.randomUUID()}"),
                        expectedCurrentId = persistedCurrentId,
                    )
                    check(receipt.outcome is ChatWriteOutcome.Persisted) { "session selection was not confirmed" }
                    record
                }.getOrNull()
            } ?: return@launch
            if (mutableChat.value.running || mutableChat.value.chatId != originalChatId) return@launch
            val record = selected
            chatWorkerClaims = chatWorkerClaims + record.workerSessionIds
            mutableChat.value = record.toUiState()
            refreshChatSession()
            mutableSessions.update { it.copy(currentSessionID = chatId) }
            LogcatHostLog.info(
                "chat: opened session=$chatId rows=${record.nodes.size} " +
                    "worker=${record.workerSessionId ?: "-"}",
            )
        }
    }

    /**
     * Opens one Worker id from the current subagent projection. The full history
     * page is read before changing the current chat, so a missing/malformed Worker
     * response leaves the parent conversation in place instead of opening a blank
     * app session.
     *
     * @return null only after the existing Worker identity and transcript page
     *   were read, persisted to the app's existing chat record, and selected by CAS.
     */
    internal suspend fun openSubagentSession(entry: ChatSubagentEntry): String? {
        val parent = mutableChat.value
        val parentChatId = parent.chatId
        val parentWorkerId = parent.workerSessionId
        val projected = parent.sessionSnapshot.subagents?.firstOrNull {
            it.workerSessionId == entry.workerSessionId
        }
        if (parentChatId.isBlank() || parentWorkerId.isNullOrBlank()) {
            return "当前会话没有已确认的 Worker 身份，未打开子会话。"
        }
        if (parent.running || parent.pendingNodes.isNotEmpty()) {
            return "请先结束当前任务并处理待回复请求，再打开子会话。"
        }
        if (projected == null || projected != entry || !entry.canOpen) {
            return "子会话未在当前 Worker 目录中确认，或仍在运行；未打开。"
        }

        val requestId = UUID.randomUUID().toString()
        activeSubagentOpenRequestId = requestId
        fun stillOnParent(): Boolean =
            activeSubagentOpenRequestId == requestId &&
                mutableChat.value.chatId == parentChatId &&
                mutableChat.value.workerSessionId == parentWorkerId &&
                mutableChat.value.sessionSnapshot.subagents?.any {
                    it.workerSessionId == entry.workerSessionId && it.canOpen
                } == true

        try {
            val records = withContext(Dispatchers.IO) { chatStore.loadAll() }
            val target = resolveSubagentSessionTarget(entry, records)
                ?: return "子会话身份与本机记录不一致，未切换当前会话。"
            val existing = when (target) {
                is SubagentSessionTarget.CachedRecord -> target.record
                is SubagentSessionTarget.AdoptKnownWorker -> target.existingRecord
            }
            val targetChatId = existing?.id ?: entry.workerSessionId
            // Reopening an App-owned record still follows the current Worker cursor
            // and reads its durable page, matching iOS `openManagedSession`. The
            // cached transcript is merged below so a bounded page never drops older
            // rows already saved on this device.
            val history = withContext(Dispatchers.IO) {
                readSubagentHistoryPage(entry.workerSessionId, targetChatId)
            }
            if (!stillOnParent()) return "当前会话已切换，未打开子会话。"

            val expectedCurrentId = withContext(Dispatchers.IO) { chatStore.currentSessionId() }
            if (expectedCurrentId != parentChatId) {
                return "当前会话选择已变化，子会话未打开。"
            }
            val record = withContext(Dispatchers.IO) {
                when {
                    existing != null -> {
                        check(!existing.archived) { "archived subagent record cannot become current" }
                        val title = existing.title.ifBlank { entry.sessionTitle.orEmpty() }
                        val updatedAt = maxOf(existing.updatedAtMs, entry.updatedAtMs ?: existing.updatedAtMs)
                        val receipt = chatStore.updateContent(
                            id = existing.id,
                            title = title,
                            updatedAtMs = updatedAt,
                            workerSessionIds = (existing.workerSessionIds + entry.workerSessionId).distinct(),
                            nodes = mergeSubagentHistory(existing.nodes, history.nodes),
                            requestId = com.phonedsh.ui.state.StateRequestId("subagent-history:$requestId"),
                            expectedRevision = com.phonedsh.ui.state.StateRevision(existing.revision),
                        )
                        check(receipt.outcome is ChatWriteOutcome.Persisted) { "subagent transcript write was not confirmed" }
                        chatStore.load(existing.id)?.also { readback ->
                            check(readback.workerSessionId == entry.workerSessionId &&
                                readback.nodes == mergeSubagentHistory(existing.nodes, history.nodes) &&
                                readback.workspaceGroupId == existing.workspaceGroupId &&
                                readback.unknownFields == existing.unknownFields
                            ) { "subagent transcript readback mismatch" }
                        } ?: error("subagent chat record disappeared after its write")
                    }
                    else -> {
                        val created = ChatRecord(
                            id = entry.workerSessionId,
                            title = entry.sessionTitle.orEmpty(),
                            updatedAtMs = entry.updatedAtMs ?: 0L,
                            workerSessionIds = listOf(entry.workerSessionId),
                            nodes = history.nodes,
                            workspaceID = null,
                            workspaceGroupId = null,
                        )
                        chatStore.save(created)
                        chatStore.load(created.id)?.also { readback ->
                            check(readback.workerSessionId == entry.workerSessionId &&
                                readback.nodes == created.nodes &&
                                readback.workspaceGroupId == null
                            ) { "adopted Worker transcript readback mismatch" }
                        } ?: error("adopted Worker record disappeared after its write")
                    }
                }
            }
            if (!stillOnParent()) return "当前会话已切换，子会话未打开。"
            val selection = withContext(Dispatchers.IO) {
                chatStore.selectCurrentSession(
                    record.id,
                    com.phonedsh.ui.state.StateRequestId("subagent-select:$requestId"),
                    expectedCurrentId = parentChatId,
                )
            }
            if (selection.outcome !is ChatWriteOutcome.Persisted) {
                return "子会话已读取，但当前会话选择没有确认。"
            }
            if (!stillOnParent()) {
                withContext(Dispatchers.IO) {
                    chatStore.selectCurrentSession(
                        parentChatId,
                        com.phonedsh.ui.state.StateRequestId("subagent-restore:$requestId"),
                        expectedCurrentId = record.id,
                    )
                }
                return "当前会话已变化，子会话没有切换到屏幕。"
            }

            chatWorkerClaims = chatWorkerClaims + record.workerSessionIds
            mutableChat.value = record.toUiState().copy(
                sessionSnapshot = ChatSessionSnapshot(),
                subagentTranscript = history.window,
            )
            val listing = HostSessionRecord(
                id = record.id,
                lastActivityMs = entry.updatedAtMs,
                title = record.title,
                workspaceID = record.workspaceID,
                pinned = record.pinned,
            )
            mutableSessions.update { snapshot ->
                snapshot.copy(
                    waiting = false,
                    sessions = mergeSessions(emptyList(), snapshot.sessions + listing),
                    currentSessionID = record.id,
                )
            }
            refreshChatSession(full = true)
            return null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            LogcatHostLog.warn("subagent: history open refused worker=${entry.workerSessionId} (${reasonOf(failure)})")
            return if (failure is SubagentHistoryReadFailure) failure.message
                else "未能读取并确认这个子会话的历史，本次没有切换。"
        } finally {
            if (activeSubagentOpenRequestId == requestId) activeSubagentOpenRequestId = null
        }
    }

    /** Read the latest bounded page, following the source's durable Worker cursor first. */
    private suspend fun readSubagentHistoryPage(
        workerSessionId: String,
        chatId: String,
        throughSeq: Long? = null,
        beforeSeq: Long? = null,
    ): SubagentHistoryPage {
        val client = DshTurnClient(host.channel, ::logTurn)
        val cursor = throughSeq ?: readSubagentHistoryCursor(client, workerSessionId)
        if (cursor < 0) {
            return SubagentHistoryPage(
                nodes = emptyList(),
                window = SubagentTranscriptWindow(workerSessionId, null, null, hasMore = false),
            )
        }
        val request = linkedMapOf<String, JsonValue>(
            "address" to JsonObject(mapOf(
                "kind" to JsonString("session"),
                "sessionId" to JsonString(workerSessionId),
            )),
            "throughSeq" to JsonNumber(cursor.toString()),
            "maxMessages" to JsonNumber(SUBAGENT_HISTORY_PAGE_SIZE.toString()),
        )
        beforeSeq?.let { request["beforeSeq"] = JsonNumber(it.toString()) }
        val response = client.call(
            "session/page",
            JsonObject(mapOf("request" to JsonObject(request))),
            timeoutMillis = SUBAGENT_HISTORY_TIMEOUT_MILLIS,
        ) as? JsonObject ?: throw SubagentHistoryReadFailure("子会话没有返回可读的历史页。")
        val records = (response["records"] as? JsonArray)?.values
            ?: throw SubagentHistoryReadFailure("子会话没有返回历史记录集合。")
        val rawEvents = records.mapNotNull { value ->
            (value as? JsonObject)?.get("event") as? JsonObject
        }
        val projected = projectSubagentHistory(chatId, rawEvents)
        projected.unsupportedReason?.let { throw SubagentHistoryReadFailure(it) }
        val firstSequence = rawEvents.mapNotNull { raw ->
            (raw["seq"] as? JsonNumber)?.asLongOrNull()
        }.minOrNull()
        val hasMore = (response["hasMore"] as? JsonBool)?.value ?: false
        if (hasMore && firstSequence == null) {
            throw SubagentHistoryReadFailure("子会话的历史还有更早记录，但没有可用的分页游标；未打开。", terminalPagination = true)
        }
        return SubagentHistoryPage(
            nodes = projected.nodes,
            window = SubagentTranscriptWindow(
                workerSessionId = workerSessionId,
                throughSeq = cursor,
                beforeSeq = firstSequence,
                hasMore = hasMore,
            ),
        )
    }

    private suspend fun readSubagentHistoryCursor(client: DshTurnClient, workerSessionId: String): Long {
        val follow = client.follow(workerSessionId, maxMessages = 1)
        try {
            return withTimeout(SUBAGENT_HISTORY_TIMEOUT_MILLIS) {
                while (true) {
                    val item = follow.next(timeoutMillis = SUBAGENT_HISTORY_TIMEOUT_MILLIS)
                        ?: throw SubagentHistoryReadFailure("子会话没有返回历史游标。")
                    when ((item["type"] as? JsonString)?.value) {
                        "error" -> throw SubagentHistoryReadFailure("子会话历史读取失败。")
                        "end" -> throw SubagentHistoryReadFailure("子会话历史流在游标前结束。")
                        "item" -> {
                            val value = item["value"] as? JsonObject ?: continue
                            if ((value["type"] as? JsonString)?.value == "snapshot") {
                                return@withTimeout (value["cursor"] as? JsonNumber)?.asLongOrNull()
                                    ?: throw SubagentHistoryReadFailure("子会话历史没有提供游标。")
                            }
                        }
                    }
                }
                @Suppress("UNREACHABLE_CODE")
                -1L
            }
        } finally {
            follow.close()
        }
    }

    /** Load one earlier Worker page; the page keeps the same throughSeq snapshot. */
    internal fun loadEarlierSubagentTranscript() {
        val current = mutableChat.value
        val window = current.subagentTranscript ?: return
        val before = window.beforeSeq ?: return
        val through = window.throughSeq ?: return
        if (!window.hasMore || window.loadingEarlier || current.workerSessionId != window.workerSessionId) return
        mutableChat.update { live ->
            if (live.chatId != current.chatId || live.workerSessionId != window.workerSessionId) live
            else live.copy(subagentTranscript = window.copy(loadingEarlier = true, error = null))
        }
        turnScope.launch(Dispatchers.IO) {
            val result = runCatching {
                readSubagentHistoryPage(
                    workerSessionId = window.workerSessionId,
                    chatId = current.chatId,
                    throughSeq = through,
                    beforeSeq = before,
                ).also { page ->
                    if (!subagentHistoryCursorAdvanced(before, page.window.beforeSeq)) {
                        throw SubagentHistoryReadFailure("更早的子会话历史没有推进分页游标；请稍后重试。", terminalPagination = true)
                    }
                }
            }
            mutableChat.update { live ->
                val liveWindow = live.subagentTranscript
                if (live.chatId != current.chatId || live.workerSessionId != window.workerSessionId ||
                    liveWindow?.beforeSeq != before || liveWindow.throughSeq != through
                ) return@update live
                result.fold(
                    onSuccess = { page ->
                        val merged = (page.nodes + live.nodes).distinctBy { it.nodeID }.sortedBy { it.seq }
                        live.copy(
                            nodes = merged,
                            subagentTranscript = page.window,
                        )
                    },
                    onFailure = { failure ->
                        live.copy(subagentTranscript = transcriptAfterSubagentPageFailure(
                            window = liveWindow,
                            message = (failure as? SubagentHistoryReadFailure)?.message
                                ?: "未能读取更早的子会话历史。",
                            terminalPagination = (failure as? SubagentHistoryReadFailure)?.terminalPagination == true,
                        ))
                    },
                )
            }
        }
    }

    /** 重命名: writes the title to the record; `true` when it really landed there. */
    internal fun renameChatSession(chatId: String, title: String): Boolean {
        val trimmed = title.trim()
        if (trimmed.isEmpty() || chatId.isEmpty()) return false
        val at = clock.nowMillis()
        chatIo.launch {
            val existing = chatStore.load(chatId)
            if (existing == null) {
                val journalRowKnown = mutableSessions.value.sessions.any { it.id == chatId }
                if (!journalRowKnown) {
                    mutableSessions.update { it.copy(failure = "会话不存在，名称没有保存。") }
                    return@launch
                }
                val adopted = ChatRecord(
                    id = chatId,
                    title = trimmed,
                    updatedAtMs = at,
                    workerSessionIds = listOf(chatId),
                    nodes = emptyList(),
                    workspaceGroupId = null,
                )
                val outcome = runCatching {
                    chatStore.save(adopted)
                    val readback = chatStore.load(chatId)
                    check(readback == adopted.copy(revision = readback?.revision ?: 0L)) {
                        "adopted session rename readback failed"
                    }
                    readback
                }.getOrNull()
                if (outcome != null) mutableSessions.update { snapshot ->
                    snapshot.copy(
                        sessions = snapshot.sessions.map {
                            if (it.id == chatId) it.copy(title = trimmed, lastActivityMs = outcome.updatedAtMs) else it
                        }.sortedByDescending { it.lastActivityMs ?: Long.MIN_VALUE },
                        failure = null,
                    )
                } else mutableSessions.update { it.copy(failure = "会话名称没有保存；请刷新列表后重试。") }
                return@launch
            }
            val live = mutableChat.value.takeIf { it.chatId == chatId }
            val receipt = chatStore.updateContent(
                id = chatId,
                title = trimmed,
                updatedAtMs = maxOf(at, existing.updatedAtMs),
                workerSessionIds = existing.workerSessionIds + listOfNotNull(live?.workerSessionId),
                nodes = live?.nodes ?: existing.nodes,
                requestId = com.phonedsh.ui.state.StateRequestId("session-rename:${UUID.randomUUID()}"),
                expectedRevision = com.phonedsh.ui.state.StateRevision(existing.revision),
            )
            if (receipt.outcome is ChatWriteOutcome.Persisted) {
                if (mutableChat.value.chatId == chatId) {
                    mutableChat.update { it.copy(title = trimmed, updatedAtMs = maxOf(at, existing.updatedAtMs)) }
                }
                val readback = chatStore.load(chatId)
                if (readback?.title == trimmed && readback.workspaceGroupId == existing.workspaceGroupId &&
                    readback.unknownFields == existing.unknownFields
                ) mutableSessions.update { snapshot ->
                    snapshot.copy(
                        sessions = snapshot.sessions.map {
                            if (it.id == chatId) it.copy(title = trimmed, lastActivityMs = readback.updatedAtMs) else it
                        }.sortedByDescending { it.lastActivityMs ?: Long.MIN_VALUE },
                        failure = null,
                    )
                } else mutableSessions.update { it.copy(failure = "会话名称已写入，但读取确认失败；请刷新列表。") }
            } else if (receipt.outcome is ChatWriteOutcome.Stale) {
                refreshSessions()
            } else {
                mutableSessions.update { it.copy(failure = "会话名称没有保存；请刷新列表后重试。") }
            }
        }
        LogcatHostLog.info("chat: renamed session=$chatId title_chars=${trimmed.length}")
        return true
    }

    /** The page-head 重命名 of the open conversation. */
    internal fun renameCurrentChat(title: String): Boolean {
        val chatId = mutableChat.value.chatId
        if (chatId.isEmpty()) return false
        return renameChatSession(chatId, title)
    }

    /** Removes one pending import. */
    internal fun removeChatAttachment(index: Int) {
        mutableChat.update { current ->
            if (index !in current.attachments.indices) {
                current
            } else {
                current.copy(attachments = current.attachments.filterIndexed { i, _ -> i != index })
            }
        }
    }

    /** Closes the import status line and the send-failure banner. */
    internal fun dismissChatNotice() {
        mutableChat.update { it.copy(notice = null, error = null, attachmentError = null, bannerDismissed = true) }
    }

    /**
     * 添加文件/图片: copies the picked document into the workspace.
     *
     * The bytes go through the WAL's mutation lane (`WorkspaceLog.appendMutation`),
     * not into the App's private directory: the workspace is what the files page
     * lists, what the model's host-exec tools mount at `/dsh/workspace`, and what the
     * next boot's overlay is packed from. A copy beside the stores would be a second
     * workspace nothing reads.
     */
    internal fun importIntoWorkspace(
        uri: Uri,
        image: Boolean,
        attachToChat: Boolean = true,
        expectedChatId: String? = null,
        onCompleted: ((Boolean) -> Unit)? = null,
    ) {
        val targetChatId = if (attachToChat) expectedChatId ?: mutableChat.value.chatId else null
        turnScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    importLocked(uri, image)
                }
            }
            outcome.fold(
                onSuccess = { imported ->
                    if (attachToChat) {
                        mutableChat.update { current ->
                            if (current.chatId != targetChatId) current else current.copy(
                                    attachments = current.attachments + imported.attachment,
                                    notice = "已写入工作区：${imported.attachment.name}（${imported.bytes} 字节）",
                                    attachmentError = null,
                                    // No restart happens here (see the note above `workspaceFileName`),
                                    // and a stored id would only be a guess; the next send opens a
                                    // fresh Worker session.
                                )
                        }
                    }
                    LogcatHostLog.info(
                        "CHAT_IMPORT path=${imported.attachment.path} bytes=${imported.bytes} " +
                            "image=$image",
                    )
                    onCompleted?.invoke(true)
                },
                onFailure = { failure ->
                    val reason = when (failure) {
                        is IllegalArgumentException -> failure.message ?: "无法读取所选文件"
                        is Exception -> reasonOf(failure)
                        else -> failure.javaClass.simpleName
                    }
                    if (attachToChat) mutableChat.update { current ->
                        if (current.chatId != targetChatId) current else current.copy(attachmentError = "导入失败：$reason")
                    }
                    LogcatHostLog.warn("CHAT_IMPORT_FAILED reason=$reason")
                    onCompleted?.invoke(false)
                },
            )
        }
    }

    private class Imported(val attachment: ChatAttachment, val bytes: Int)

    private fun importLocked(uri: Uri, image: Boolean): Imported {
        val resolver = getApplication<Application>().contentResolver
        val declared = resolver.getType(uri)
        var displayName: String? = null
        var declaredBytes: Long? = null
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex >= 0) displayName = cursor.getString(nameIndex)
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) declaredBytes = cursor.getLong(sizeIndex)
                    }
                }
        }
        val limit = deviceBudgets.singleFileBytes
        declaredBytes?.let {
            require(it <= limit) { "文件超过本机单文件上限（$limit 字节）" }
        }
        val bytes = resolver.openInputStream(uri)?.use { stream ->
            val buffer = java.io.ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = stream.read(chunk)
                if (read < 0) break
                total += read
                require(total <= limit) { "文件超过本机单文件上限（$limit 字节）" }
                buffer.write(chunk, 0, read)
            }
            buffer.toByteArray()
        } ?: throw IllegalArgumentException("无法打开所选文件")
        require(bytes.isNotEmpty()) { "所选文件是空的" }
        val safeName = workspaceFileName(displayName ?: "attachment", image)
        val vfsPath = "/dsh/workspace/$safeName"
        kotlinx.coroutines.runBlocking {
            workspaceLog.appendMutation(
                MutationBody(
                    op = VfsOp.WRITE,
                    mode = FILE_MODE,
                    path = vfsPath,
                    data = bytes,
                ),
            )
        }
        return Imported(
            attachment = ChatAttachment(
                name = safeName,
                mimeType = declared,
                image = image || declared?.startsWith("image/") == true,
                path = vfsPath,
            ),
            bytes = bytes.size,
        )
    }

    /**
     * Nothing is restarted here, and that is a measured decision.
     *
     * `WorkspaceLog.appendMutation` is the VFS mutation lane: the record is
     * durable and materialized, which is what makes the file part of the
     * workspace rather than a copy beside the stores. It has one host-side
     * consequence this App cannot repair: the `VfsSink` numbers the Worker's
     * mutations from its own counter, seeded once from `WorkspaceLog.recover()`,
     * and `recover()` caches its outcome — so an App-side append makes the log one
     * mseq ahead of the sink, and the Worker's first later `VFS_MUT` closes the
     * channel with `WAL allocated mseq N+1 for the worker's N` (measured on this
     * lane, API 35). Restarting the host does not reseed that counter (the cached
     * recovery is reused), so this class deliberately does not try; the durable
     * fix belongs in `:dsh` (`VfsSink` should reseed from the log, or
     * `WorkspaceLog.recover()` should report the live watermark).
     *
     * This note is documentation of the constraint, not a plan: nothing in this
     * class restarts the host, because a restart cannot reseed the counter.
     */
    /** A workspace file name that cannot escape `/dsh/workspace` and does not collide. */
    private fun workspaceFileName(raw: String, image: Boolean): String {
        val base = raw.substringAfterLast('/').substringAfterLast('\\')
        val cleaned = base.replace(FILE_NAME_DISALLOWED, "_").ifBlank { "attachment" }
        val withExtension = if (cleaned.contains('.')) {
            cleaned
        } else {
            cleaned + if (image) ".png" else ".txt"
        }
        var candidate = withExtension
        var suffix = 1
        val directory = walPaths.materializedWorkspace
        while (Files.exists(directory.resolve(candidate)) ||
            mutableChat.value.attachments.any { it.name == candidate }
        ) {
            val dot = withExtension.lastIndexOf('.')
            candidate = if (dot > 0) {
                "${withExtension.substring(0, dot)}-$suffix${withExtension.substring(dot)}"
            } else {
                "$withExtension-$suffix"
            }
            suffix++
        }
        return candidate
    }

    /**
     * Sends the draft (and every pending import) as one turn.
     *
     * The conversation is created on demand: 新建会话 writes the record, and the
     * Worker's `session/create` happens here, on the first message that needs it.
     */
    internal fun sendChat() {
        val current = mutableChat.value
        if (current.running) {
            val mode = when (preferenceStore.snapshot().busyEnterMode) {
                BusyEnterMode.QUEUE -> com.phonedsh.ui.state.EnterMode.QUEUE
                BusyEnterMode.STEER -> com.phonedsh.ui.state.EnterMode.STEER
            }
            submitWhileRunning(
                current.workerSessionId.orEmpty(),
                com.phonedsh.ui.state.StateRequestId("ui.prompt." + java.util.UUID.randomUUID().toString()),
                current.draft,
                mode,
            )
            return
        }
        submitChat(retryOriginalSubmission = false, retryRequestId = null)
    }

    /** Queue or steer a new user submission to the exact live Worker session. */
    internal fun submitWhileRunning(
        workerSessionId: String,
        requestId: com.phonedsh.ui.state.StateRequestId,
        text: String,
        mode: com.phonedsh.ui.state.EnterMode,
    ): Boolean {
        if (sealedBusyGeneration == chatTurnGeneration.get()) return false
        busySubmissionVersion.incrementAndGet()
        return chatQueueActions.submitWhileRunning(workerSessionId, requestId, text, mode)
    }

    /** Retry the original failed input in its existing session without adding a second user row. */
    internal fun retryFailedChat(sessionId: String, requestId: com.phonedsh.ui.state.StateRequestId): Boolean {
        val current = mutableChat.value
        if (sessionId.isBlank() || current.chatId != sessionId || current.running || current.error == null ||
            (current.lastSubmission.isBlank() && current.lastAttachments.isEmpty()) ||
            current.lastPromptRequestId.isNullOrBlank() ||
            state.value !is EngineHostState.Running || turnRunning.get() || activeRetryRequestId != null
        ) return false
        activeRetryRequestId = requestId.value
        mutableChat.update {
            if (it.chatId != sessionId) it else it.copy(
                draft = it.lastSubmission,
                attachments = it.lastAttachments,
            )
        }
        submitChat(retryOriginalSubmission = true, retryRequestId = requestId.value)
        return true
    }

    private fun submitChat(retryOriginalSubmission: Boolean, retryRequestId: String?) {
        val current = mutableChat.value
        if (current.running) return
        val typed = current.draft.trim()
        val attachments = current.attachments
        if (typed.isEmpty() && attachments.isEmpty()) return
        val promptRequestId = if (retryOriginalSubmission) {
            current.lastPromptRequestId ?: return
        } else {
            "pdsh-prompt-${java.util.UUID.randomUUID()}"
        }
        val commandName = typed.removePrefix("/").substringBefore(' ')
        if (typed.startsWith('/') && attachments.isEmpty() &&
            current.sessionSnapshot.commands.any { it.name == commandName }) {
            runChatCommand(typed)
            return
        }
        if (state.value !is EngineHostState.Running || host.state.value == com.phonedsh.controller.HostState.FAILED) {
            if (nativeEngineLifecycle().canStartBySending && sendStartupInFlight.compareAndSet(false, true)) {
                turnScope.launch {
                    try {
                        start()
                        withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                            host.ready.first { it }
                            engine.state.first { it is EngineHostState.Running }
                        }
                        sendStartupInFlight.set(false)
                        if (mutableChat.value.draft == current.draft) submitChat(retryOriginalSubmission, retryRequestId)
                        else mutableChat.update { it.copy(notice = "引擎已就绪，点发送继续。") }
                    } catch (cancelled: CancellationException) { throw cancelled
                    } catch (failure: Exception) {
                        mutableChat.update { it.copy(error = "引擎没有启动成功，输入已保留。", bannerDismissed = false) }
                    } finally { sendStartupInFlight.set(false) }
                }
                return
            }
            mutableChat.update {
                it.copy(error = "本地引擎还没就绪，消息没有发出", bannerDismissed = false)
            }
            return
        }
        if (!turnRunning.compareAndSet(false, true)) {
            mutableChat.update {
                it.copy(error = "上一个回合还在运行，这条消息没有发出", bannerDismissed = false)
            }
            return
        }
        // `newChatSession` replaces the state, so it runs before the send snapshot
        // is taken again.
        val chatId = current.chatId.ifEmpty { newChatSession() }
        val sending = mutableChat.value
        val prompt = composeChatPrompt(typed, attachments)
        val ordinal = ++chatOrdinal
        // Every send gets its own turn-id prefix: a replacement Worker session
        // numbers its turns from 0001 again.
        // Wall-clock prefix, not just the process-local ordinal: the node ids of a
        // previous process must never collide with this one's, or the transcript's
        // duplicate-id guard would drop a legitimate new row (measured: the answer
        // of the newest turn was not drawn while an older turn's row was).
        val turnToken = "t${clock.nowMillis()}-$ordinal"
        val userNode = userNodeOf(
            chatId,
            turnToken,
            typed.ifEmpty { attachments.joinToString(", ") { it.name } },
            ordinal,
        )
        val at = clock.nowMillis()
        mutableChat.update {
            it.copy(
                chatId = chatId,
                nodes = if (retryOriginalSubmission) it.nodes else it.nodes + userNode,
                draft = "",
                lastSubmission = if (retryOriginalSubmission) current.lastSubmission else current.draft,
                lastAttachments = if (retryOriginalSubmission) current.lastAttachments else attachments,
                lastPromptRequestId = promptRequestId,
                attachments = emptyList(),
                running = true,
                streaming = "",
                reasoningStreaming = "",
                error = null,
                bannerDismissed = false,
                notice = null,
                attachmentError = null,
                activeTurnNodeId = null,
                turnToken = turnToken,
                updatedAtMs = at,
            )
        }
        persistChat(chatId)
        LogcatHostLog.info(
            "APP_CHAT_SEND session=$chatId chars=${prompt.length} " +
                "attachments=${attachments.size} worker=${sending.workerSessionId ?: "-"}",
        )
        val turnGeneration = chatTurnGeneration.incrementAndGet()
        chatTurnJob = turnScope.launch(Dispatchers.IO) {
            var outcome: ChatTurnOutcome? = null
            // The 本 session 产物 fact's baseline: every workspace file the person
            // already had is *not* this turn's output. Taken after the awaits and
            // before the prompt, on this IO thread (see HostSessionArtifacts).
            sessionArtifacts.beginTurn()
            try {
                withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
                withTimeout(ENGINE_READY_TIMEOUT_MILLIS) {
                    engine.state.first { it is EngineHostState.Running }
                }
                val runner = ChatTurnRunner(host.channel, DshTurnClient(host.channel, ::logTurn), ::logTurn)
                chatRunner = runner
                chatPreparationJob?.join()
                outcome = runner.run(
                    // The conversation's own Worker session, persisted in the chat
                    // record. It survives a Worker page reload and a cold start:
                    // `session/prompt` resumes it from the Worker's JSONL log
                    // (`/dsh/home/sessions`, repacked into every boot overlay), so
                    // the model keeps the earlier turns instead of starting blind.
                    workerSessionId = mutableChat.value.takeIf { it.chatId == chatId }?.workerSessionId,
                    prompt = prompt,
                    promptRequestId = promptRequestId,
                    onSession = { workerSessionId ->
                        if (turnGeneration == chatTurnGeneration.get()) claimWorkerSession(chatId, workerSessionId)
                    },
                    onEvent = { event ->
                        onChatEvent(chatId, event, turnGeneration)
                    },
                    onDelta = { text ->
                        mutableChat.update { live ->
                            if (turnGeneration != chatTurnGeneration.get() || live.chatId != chatId) live
                            else live.copy(streaming = live.streaming + text)
                        }
                    },
                    onContextLost = { message ->
                        if (turnGeneration == chatTurnGeneration.get()) recordContextLost(chatId, message)
                    },
                    onInteractiveRequest = { request, responder ->
                        if (turnGeneration == chatTurnGeneration.get()) receiveChatRequest(chatId, request, responder)
                    },
                    onInteractiveCancel = { id ->
                        if (turnGeneration == chatTurnGeneration.get()) removeChatRequest(id)
                    },
                    onReasoningDelta = { text ->
                        mutableChat.update { live ->
                            if (turnGeneration != chatTurnGeneration.get() || live.chatId != chatId) live
                            else live.copy(reasoningStreaming = live.reasoningStreaming + text)
                        }
                    },
                    busySubmissionVersion = {
                        withContext(Dispatchers.Main.immediate) {
                            busySubmissionVersion.get().takeIf { mutableChat.value.localQueueItems.none { it.busy == true } }
                        }
                    },
                    sealBusySubmissions = { readVersion ->
                        withContext(Dispatchers.Main.immediate) {
                            val live = mutableChat.value
                            if (turnGeneration != chatTurnGeneration.get() || live.chatId != chatId) {
                                true
                            } else if (busySubmissionVersion.get() != readVersion || live.localQueueItems.any { it.busy == true }) {
                                false
                            } else {
                                sealedBusyGeneration = turnGeneration
                                true
                            }
                        }
                    },
                )
                if (turnGeneration == chatTurnGeneration.get()) finishChatTurn(chatId, outcome)
            } catch (timeout: TimeoutCancellationException) {
                if (turnGeneration == chatTurnGeneration.get()) failChatTurn(chatId, "timeout")
            } catch (cancelled: CancellationException) {
                // 停止: the job was cancelled from the main thread. 停止 itself
                // already closed the turn synchronously; this branch remains for a
                // scope cancellation that did not go through `stopChat`.
                if (turnGeneration == chatTurnGeneration.get()) markChatTurnStopped(chatId)
                throw cancelled
            } catch (failure: Exception) {
                if (turnGeneration == chatTurnGeneration.get()) failChatTurn(chatId, reasonOf(failure))
            } finally {
                if (turnGeneration == chatTurnGeneration.get()) {
                    chatRunner = null
                    if (activeRetryRequestId == retryRequestId) activeRetryRequestId = null
                    chatSnapshotJob?.cancel()
                    chatResponders.clear()
                    answeringRequests.clear()
                    turnRunning.set(false)
                    // Close the measurement even on a failed or stopped turn: a file a
                    // tool really wrote is on disk whether or not the answer settled, and
                    // the page must list it rather than losing it with the error path.
                    sessionArtifacts.endTurn()
                    mutableChat.update {
                        it.copy(running = false, streaming = "", reasoningStreaming = "", activeTurnNodeId = null, pendingNodes = emptyList())
                    }
                    refreshChatSession()
                    persistChat(chatId)
                }
            }
        }
    }

    /**
     * 停止: tells the Worker to cancel, then stops reading its stream here.
     *
     * The cancel receipt is what makes the Worker's own turn end `interrupted`
     * instead of leaving it generating for a phone that stopped listening. It is
     * sent from a scope that outlives the cancelled turn job.
     */
    internal fun stopChat() {
        val current = mutableChat.value
        if (!current.running) return
        val runner = chatRunner
        val workerSessionId = current.workerSessionId
        LogcatHostLog.info("APP_CHAT_STOP session=${current.chatId}")
        // The cancelled job must not clean up a turn this stop did not own: a new
        // send may start before its cancellation reaches the IO dispatcher.
        chatTurnGeneration.incrementAndGet()
        chatTurnJob?.cancel()
        chatTurnJob = null
        chatRunner = null
        if (runner != null && workerSessionId != null) {
            turnScope.launch {
                val failure = runner.cancel(workerSessionId)
                if (failure != null) {
                    LogcatHostLog.warn("APP_CHAT_STOP cancel not accepted ($failure)")
                }
            }
        }
        activeRetryRequestId = null
        chatSnapshotJob?.cancel()
        chatResponders.clear()
        answeringRequests.clear()
        sessionArtifacts.endTurn()
        // Close the *real* open turn(s), not a synthetic `stopped` id: the open
        // TURN node is what keeps the composer in RUNNING across restarts. The
        // fallback row is used only when TURN_STARTED never reached us.
        val at = clock.nowMillis()
        // This transaction also clears `turnRunning` and invokes the shared
        // `persistChat` writer, so the closed turn is stored without a second
        // metadata-writing implementation.
        chatStop.stop(current.chatId, at)
        refreshChatSession()
        LogcatHostLog.info("APP_CHAT_TURN_STOPPED session=${current.chatId}")
    }

    /** Appends the node(s) one Worker event produces. */
    private fun onChatEvent(chatId: String, event: HostEvent, generation: Long) {
        // The 本 session 产物 fact's corroborating signal (a named write tool's path).
        // The bytes are the evidence; this only catches a same-size rewrite.
        sessionArtifacts.observe(event)
        if (event.kind == HostEventKind.TURN_STARTED) {
            mutableChat.update { current ->
                applyChatEventIfCurrent(
                    current = current,
                    chatId = chatId,
                    event = event,
                    ordinal = chatOrdinal,
                    eventGeneration = generation,
                    currentGeneration = chatTurnGeneration.get(),
                )
            }
        } else {
            val ordinal = ++chatOrdinal
            mutableChat.update { current ->
                applyChatEventIfCurrent(
                    current = current,
                    chatId = chatId,
                    event = event,
                    ordinal = ordinal,
                    eventGeneration = generation,
                    currentGeneration = chatTurnGeneration.get(),
                )
            }
        }
    }

    /**
     * Records the Worker session a turn opened, so the journal row belongs to this
     * conversation and the list does not show it twice.
     */
    private fun claimWorkerSession(chatId: String, workerSessionId: String) {
        chatWorkerClaims = chatWorkerClaims + workerSessionId
        mutableChat.update {
            if (it.chatId == chatId) it.copy(workerSessionId = workerSessionId) else it
        }
        refreshChatSession()
        chatSnapshotJob?.cancel()
        chatSnapshotJob = turnScope.launch {
            while (mutableChat.value.chatId == chatId && mutableChat.value.running) {
                delay(2_000)
                refreshChatSession(full = false)
            }
        }
        persistChat(chatId)
        mutableSessions.update { snapshot ->
            snapshot.copy(sessions = mergeSessions(emptyList(), snapshot.sessions))
        }
        LogcatHostLog.info("chat: session=$chatId claimed worker=$workerSessionId")
    }

    private fun finishChatTurn(chatId: String, outcome: ChatTurnOutcome) {
        val at = clock.nowMillis()
        val kinds = outcome.events.joinToString(",") { it.kind.wire }
        if (outcome.completed) {
            LogcatHostLog.info(
                "APP_CHAT_TURN_OK session=$chatId worker=${mutableChat.value.workerSessionId ?: "-"} " +
                    "kinds=$kinds reason=completed streamed=${outcome.liveText.length} chars " +
                    "text=${outcome.assistantText.length} chars context_reset=${outcome.contextReset}",
            )
        } else if (outcome.endReason == null) {
            failChatTurn(chatId, "the turn ended without a turn_ended edge (kinds=$kinds)")
            return
        } else {
            // interrupted / aborted / blocked: the row says so, and the turn is not
            // reported as a failure the person has to dismiss.
            LogcatHostLog.info(
                "APP_CHAT_TURN_ENDED session=$chatId kinds=$kinds reason=${outcome.endReason}",
            )
        }
        mutableChat.update { it.copy(updatedAtMs = at, activeTurnNodeId = null) }
        mutableSessions.update { snapshot ->
            snapshot.copy(
                currentSessionID = chatId,
                sessions = mergeSessions(emptyList(), snapshot.sessions),
            )
        }
        persistChat(chatId)
        logJournalEvidence(chatId)
    }

    private fun markChatTurnStopped(chatId: String) {
        val at = clock.nowMillis()
        // 停止 already closed the real turn; this is the fallback for a scope
        // cancellation that did not pass through `stopChat`. No synthetic
        // `stopped` id here: an open TURN must be closed under its own id.
        mutableChat.update {
            if (it.chatId != chatId) {
                it
            } else {
                it.copy(
                    running = false,
                    streaming = "",
                    activeTurnNodeId = null,
                    nodes = closeOpenTurns(
                        chatId = chatId,
                        nodes = it.nodes,
                        activeTurnNodeId = it.activeTurnNodeId,
                        fallbackTurnId = null,
                        atMs = at,
                    ),
                    updatedAtMs = at,
                )
            }
        }
        persistChat(chatId)
        LogcatHostLog.info("APP_CHAT_TURN_STOPPED session=$chatId")
    }

    private fun failChatTurn(chatId: String, reason: String) {
        val safe = reason.substringBefore('\n').take(240)
        LogcatHostLog.error("APP_CHAT_TURN_FAILED session=$chatId reason=$safe")
        mutableChat.update {
            it.copy(
                running = false,
                streaming = "",
                activeTurnNodeId = null,
                error = "消息发送失败（$safe）",
                bannerDismissed = false,
                draft = it.draft.ifEmpty { it.lastSubmission },
                attachments = if (it.attachments.isEmpty()) it.lastAttachments else it.attachments,
            )
        }
        persistChat(chatId)
    }

    /**
     * Tells the person that this conversation lost the model's earlier context.
     *
     * The send itself can still succeed — a new Worker session is the only way to
     * send at all once the old one is gone — but the transcript now shows bubbles
     * the model can no longer see. This writes that fact **into the transcript**
     * (a durable `status` row, so reopening the chat cannot present the earlier
     * messages as shared context) and raises the transient banner so it is visible
     * the moment it happens. Never a log-only path: `budgets.md` §5 / the lane's
     * rule is that the UI record and the model context must not disagree silently.
     */
    private fun recordContextLost(chatId: String, message: String) {
        val at = clock.nowMillis()
        val scopeTurn = mutableChat.value.turnToken.ifEmpty { "t$at" }
        val node = contextLostNode(chatId, scopeTurn, message)
        mutableChat.update {
            if (it.chatId != chatId) {
                it
            } else {
                it.copy(
                    nodes = it.nodes + node,
                    error = message,
                    bannerDismissed = false,
                    updatedAtMs = at,
                )
            }
        }
        persistChat(chatId)
        LogcatHostLog.warn("APP_CHAT_CONTEXT_LOST session=$chatId")
    }

    /**
     * Prints whether the journal really holds the turn's Worker session.
     *
     * This is the evidence line for "a session that exists", read from the store
     * itself (`JournalStore.recover` is public and idempotent) rather than assumed
     * from a successful reply.
     */
    private fun logJournalEvidence(chatId: String) {
        val workerSessionId = mutableChat.value.workerSessionId ?: return
        try {
            val recovery = kotlinx.coroutines.runBlocking { journalStore.recover() }
            val highest = recovery.highestJseq[workerSessionId]
            LogcatHostLog.info(
                "CHAT_JOURNAL_SESSION present=${highest != null} jseq=${highest ?: "-"} " +
                    "chat=$chatId worker=$workerSessionId sessions=${recovery.highestJseq.size}",
            )
        } catch (failure: Exception) {
            LogcatHostLog.warn("CHAT_JOURNAL_SESSION present=unknown reason=${reasonOf(failure)}")
        }
    }

    /**
     * Copies the current conversation into the store.
     *
     * Only durable nodes are written: the streaming text is not a row, and the
     * running turn's node is transient. A later `openChatSession` paints exactly
     * what was on screen when the turn settled.
     */
    private fun persistChat(chatId: String) {
        val ui = mutableChat.value
        if (ui.chatId != chatId) return
        val nodes = ui.nodes
        val title = ui.title
        val workerSessionId = ui.workerSessionId
        val at = ui.updatedAtMs
        chatIo.launch {
            val existing = runCatching { chatStore.load(chatId) }.getOrNull()
            if (existing == null) {
                LogcatHostLog.warn("chat: content update refused session=$chatId (record_missing)")
                mutableChat.update { live ->
                    chatWriteFailureState(live, chatId, existing = null, outcome = null)
                }
                return@launch
            }
            runCatching {
                val receipt = chatStore.updateContent(
                    id = chatId,
                    title = title,
                    updatedAtMs = at,
                    workerSessionIds = existing.workerSessionIds + listOfNotNull(workerSessionId),
                    nodes = nodes,
                    requestId = com.phonedsh.ui.state.StateRequestId("chat-content:${UUID.randomUUID()}"),
                    expectedRevision = com.phonedsh.ui.state.StateRevision(existing.revision),
                )
                if (receipt.outcome !is ChatWriteOutcome.Persisted) {
                    val code = (receipt.outcome as? ChatWriteOutcome.Failed)?.code ?: "stale"
                    LogcatHostLog.warn("chat: content update refused session=$chatId ($code)")
                    // A refused transcript write must be visible, not log-only.
                    mutableChat.update { live ->
                        chatWriteFailureState(live, chatId, existing, receipt.outcome)
                    }
                    return@runCatching
                }
                val readback = chatStore.load(chatId)
                check(readback?.nodes == nodes && readback.workspaceGroupId == existing.workspaceGroupId &&
                    readback.unknownFields == existing.unknownFields
                ) { "chat metadata did not survive content update" }
            }.onFailure {
                LogcatHostLog.warn("chat: save refused session=$chatId (${reasonOf(it as? Exception ?: Exception(it))})")
                mutableChat.update { live ->
                    chatWriteFailureState(live, chatId, existing, outcome = null)
                }
            }
        }
    }

    /**
     * Paints the conversation selected before the previous process exited.
     *
     * `ChatSessionStore.currentSessionId` mirrors iOS's `chat.dsh.currentSessionID`.
     * The newest active session is only a fallback when the selected id is absent,
     * archived, or no longer readable.
     */
    private fun restoreChatSessions() {
        val chatIdAtStart = mutableChat.value.chatId
        turnScope.launch {
            val (records, persistedCurrentId) = withContext(Dispatchers.IO) {
                runCatching {
                    val liveChatId = mutableChat.value.chatId
                    val live = turnRunning.get()
                    // Every stored conversation but the one really running here is
                    // safe to repair: the old stop path persisted its open TURN, so
                    // a cold start would otherwise reopen it as RUNNING forever.
                    val loaded = ChatRecordRepair(chatStore).restore(
                        records = chatStore.loadAll(),
                        liveChatId = liveChatId,
                        turnRunning = live,
                        onFailure = { record, failure ->
                            LogcatHostLog.warn("chat: stale turn repair failed session=${record.id} (${reasonOf(failure as? Exception ?: Exception(failure))})")
                        },
                    )
                    loaded to chatStore.currentSessionId()
                }
                    .onFailure { LogcatHostLog.warn("chat: store not restored (${reasonOf(it as? Exception ?: Exception(it))})") }
                    .getOrDefault(emptyList<ChatRecord>() to null)
            }
            if (mutableChat.value.chatId != chatIdAtStart) return@launch
            val selected = selectRestoredChatSession(records, persistedCurrentId)
            if (selected == null) {
                if (persistedCurrentId != null) withContext(Dispatchers.IO) {
                    chatStore.clearCurrentSession(
                        persistedCurrentId,
                        com.phonedsh.ui.state.StateRequestId("clear-current-session:${UUID.randomUUID()}"),
                    )
                }
                mutableSessions.update { it.copy(waiting = false, currentSessionID = null) }
                LogcatHostLog.info("chat: no active stored conversation")
                return@launch
            }
            if (mutableChat.value.chatId != chatIdAtStart && mutableChat.value.chatId != selected.id) return@launch
            val selectedReceipt = withContext(Dispatchers.IO) {
                chatStore.selectCurrentSession(
                    selected.id,
                    com.phonedsh.ui.state.StateRequestId("restore-current-session:${UUID.randomUUID()}"),
                    expectedCurrentId = persistedCurrentId,
                )
            }
            if (selectedReceipt.outcome !is ChatWriteOutcome.Persisted) {
                LogcatHostLog.warn("chat: selected conversation readback failed session=${selected.id}")
                return@launch
            }
            if (mutableChat.value.chatId != chatIdAtStart && mutableChat.value.chatId != selected.id) return@launch
            chatWorkerClaims = records.flatMap { it.workerSessionIds }.toSet()
            applyChatRecords(records)
            mutableSessions.update { snapshot ->
                snapshot.copy(
                    waiting = false,
                    sessions = mergeSessions(
                        emptyList(),
                        snapshot.sessions + records.filterNot { it.archived }.map {
                            HostSessionRecord(it.id, it.updatedAtMs, it.title, it.workspaceID, it.pinned)
                        },
                    ),
                    currentSessionID = selected.id,
                )
            }
            if (!turnRunning.get() && mutableChat.value.chatId.isEmpty()) {
                mutableChat.value = selected.toUiState()
            }
            LogcatHostLog.info(
                "chat: restored ${records.size} conversation(s) open=${selected.id} " +
                    "rows=${selected.nodes.size} worker=${selected.workerSessionId ?: "-"}",
            )
        }
    }

    override fun onCleared() {
        turnScope.cancel()
        if (appBotRuntimeDelegate.isInitialized()) appBotRuntime?.close()
        pcWorkspace?.close()
        chatIo.cancel()
        host.stop()
        // The App's process scope normally makes this unreachable (the view
        // model is not registered in any Activity's ViewModelStore). If a test
        // or a future owner does clear it, release the process singleton only
        // after the host stopped, so a later construction cannot overlap two
        // writers.
        processHost.clear(this)
        super.onCleared()
    }

    private fun failTurn(reason: String) {
        val safe = reason.substringBefore('\n').take(240)
        Log.e(TAG_TURN, "APP_TURN_FAILED reason=$safe")
        // A failure is an explicit end: the marker is removed so the next launch
        // does not report this turn as a process death too.
        ProbeRecovery.endTurn(getApplication<Application>())
        mutableTurn.value = AppTurnState.Failed(safe)
    }

    /**
     * One cold scan of the journal lane, with the failure kept as a page label.
     *
     * The session ids are the store's own recovery watermarks; the timestamp is
     * the file's last write, which is the last moment the host durably touched
     * that session. Nothing is inferred from a file name.
     */
    private suspend fun readJournalSessions(): SessionScan = try {
        val recovery = journalStore.recover()
        SessionScan(
            sessions = recovery.highestJseq.keys
                .map { sessionId -> HostSessionRecord(sessionId, journalLastWriteMs(sessionId)) }
                .sortedByDescending { it.lastActivityMs ?: Long.MIN_VALUE },
        )
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        SessionScan(failure = sessionFailureLabel(failure))
    }

    /**
     * The session file's last write, or `null` when it disappeared.
     *
     * A row whose file vanished between recovery and this read keeps its id and
     * shows no time, rather than a time the host did not read.
     */
    private fun journalLastWriteMs(sessionId: String): Long? = runCatching {
        Files.getLastModifiedTime(journalPaths.sessionFile(sessionId)).toMillis()
    }.getOrNull()

    /**
     * Records the session a completed turn opened.
     *
     * This is the one session the host knows without a store scan: the client
     * returned it with the completed turn. It becomes the current session (the
     * page's check mark) and a row, with the host's own completion reading as
     * its last activity.
     */
    private fun recordCompletedTurn(sessionId: String) {
        val at = clock.nowMillis()
        mutableSessions.update { snapshot ->
            snapshot.copy(
                currentSessionID = sessionId,
                sessions = mergeSessions(
                    emptyList(),
                    snapshot.sessions + HostSessionRecord(sessionId, at),
                ),
            )
        }
    }

    /**
     * Paints the last completed turn and the last session this app opened.
     *
     * The Android half of `ChatModel.restoreCachedTranscriptIfAvailable()`: a
     * cold start shows what the previous process rendered instead of 未开始, and
     * the sessions page marks the session it last opened instead of forgetting
     * it. Both come from one row, read on [Dispatchers.IO] because
     * `DomainStore`'s contract forbids a main-thread call.
     *
     * Three rules keep this honest:
     *
     *  * a store that cannot be read leaves the screen at [AppTurnState.Idle] —
     *    the cache is an optimisation, and a cache failure must never look like
     *    "the last turn is still running" or like a fabricated one;
     *  * the restore only applies while the process has not started a turn of its
     *    own ([turnRunning] false and still [AppTurnState.Idle]), so a slow restore
     *    can never overwrite a turn this process really ran;
     *  * nothing is deleted on failure. A damaged row stays for the next save to
     *    replace, because silently dropping data is what `budgets.md` §5 forbids.
     */
    private fun restoreSessionArchive() {
        turnScope.launch {
            val restored = withContext(Dispatchers.IO) {
                runCatching {
                    sessionArchive.currentSessionId() to sessionArchive.latest()
                }
            }
            val (sessionId, archived) = restored.getOrElse { failure ->
                // Recovery evidence, not an error path: a fresh install has no
                // row, and this line is how a reader tells "nothing was saved"
                // from "the store refused to open".
                LogcatHostLog.warn("session archive: not restored (${archiveReasonOf(failure)})")
                return@launch
            }
            if (sessionId == null) {
                LogcatHostLog.info("session archive: empty (no session recorded yet)")
                return@launch
            }
            // The current-session mark is a separate fact from the payload: a
            // session whose turn row is gone still names the session this app
            // opened, exactly as `currentSessionDefaultsKey` survives on iOS.
            //
            // Guarded by `currentSessionID == null` for the same reason the turn
            // restore is guarded by `Idle`: a turn this process completed before
            // the read landed has already marked its own session, and the stored
            // one is older by definition. Letting the restore win would move the
            // check mark backwards.
            mutableSessions.update { snapshot ->
                if (turnRunning.get() || snapshot.currentSessionID != null) {
                    snapshot
                } else {
                    snapshot.copy(
                        currentSessionID = sessionId,
                        sessions = mergeSessions(
                            emptyList(),
                            snapshot.sessions + HostSessionRecord(sessionId, archived?.completedAtMs),
                        ),
                    )
                }
            }
            if (archived == null) {
                LogcatHostLog.warn(
                    "session archive: session=$sessionId restored without a readable turn; " +
                        "the screen keeps 未开始",
                )
                return@launch
            }
            var applied = false
            mutableTurn.update { current ->
                if (turnRunning.get() || current !is AppTurnState.Idle) {
                    current
                } else {
                    applied = true
                    archived.toRestoredCompleted()
                }
            }
            if (!applied) return@launch
            LogcatHostLog.info(
                "session archive: restored session=${archived.sessionId} " +
                    "completed_at=${archived.completedAtMs} kinds=${archived.kinds.size} " +
                    "commands=${archived.commands.size} writes=${archived.writes.size} " +
                    "restored=true",
            )
        }
    }

    /**
     * Writes the turn [runTurn] just completed, so the next launch can paint it.
     *
     * Called after the UI already shows the completed turn: a store write must
     * never turn a completed turn into a failed one, so a refusal is logged and
     * swallowed. The one case worth naming is the quota
     * (`QuotaExceededException`): it means the cache is full, and the write is
     * refused rather than silently trimming older sessions — the same rule the
     * WAL and the journal follow.
     */
    private suspend fun archiveCompletedTurn(completed: AppTurnState.Completed, atMillis: Long) {
        val turn = ArchivedTurn(
            sessionId = completed.sessionId,
            completedAtMs = atMillis,
            // The iOS baseline keeps the settled tail (`suffix(400)`); the same
            // bound here means a restored screen holds the same tail on both
            // platforms. `kinds` is the projection the screen already drew.
            kinds = completed.kinds.takeLast(SessionArchive.CAPACITY),
            commands = completed.commands
                .takeLast(SessionArchive.CAPACITY)
                .map { ArchivedCommand(it.id, it.command) },
            writes = completed.writes
                .takeLast(SessionArchive.CAPACITY)
                .map { ArchivedWrite(it.path, it.toolName) },
        )
        val outcome = withContext(Dispatchers.IO) { runCatching { sessionArchive.save(turn) } }
        outcome.fold(
            onSuccess = {
                LogcatHostLog.info(
                    "session archive: saved session=${turn.sessionId} " +
                        "commands=${turn.commands.size} writes=${turn.writes.size}",
                )
            },
            onFailure = { failure ->
                LogcatHostLog.warn(
                    "session archive: save refused session=${turn.sessionId} " +
                        "(${archiveReasonOf(failure)})",
                )
            },
        )
    }

    /**
     * The page's failure line, with a stable store code and no path.
     *
     * The journal's own codes name why the read failed; anything else is a class
     * name, which is still token-free.
     */
    private fun sessionFailureLabel(failure: Exception): String = when (failure) {
        is JournalException -> "会话记录读取失败（${failure.failure.code}）"
        else -> "会话记录读取失败（${failure.javaClass.simpleName}）"
    }

    private fun logTurn(message: String) {
        Log.i(TAG_TURN, message)
    }

    private fun archiveReasonOf(failure: Throwable): String = when (failure) {
        is com.phonedsh.domain.QuotaExceededException -> "quota_exceeded(${failure.domain})"
        is Exception -> reasonOf(failure)
        else -> failure.javaClass.simpleName
    }

    private fun reasonOf(failure: Exception): String = when (failure) {
        is DshTurnException -> failure.code
        is HostApiException -> failure.code
        else -> failure.javaClass.simpleName
    }

    /**
     * The Worker's CONSOLE text: only the announce marker is logged, never the
     * line itself (a Worker console line can quote user content).
     */
    private fun onWorkerConsole(text: String) {
        if (text.contains("XL_DSH_READY")) {
            Log.i(TAG_TURN, "APP_WORKER_READY")
            // A cold restore may try the projection before the Worker has
            // registered its channel. Once this exact Worker announces ready,
            // re-read the current session's facts; no new Worker/session is made.
            refreshChatSession(full = true)
        }
    }

    internal companion object {
        private val ACCESS_RETRY_DELAYS_MS = longArrayOf(500, 1_000, 2_000, 4_000, 8_000).toList()

        /**
         * The one process-wide owner of the host composition.
         *
         * The view model owns the only `WorkspaceLog` writer (P02). Android can
         * put a second `MainActivity` on screen while the first view model is
         * still alive, and before this holder existed that second Activity
         * constructed a second host, engine and WAL writer over the same
         * `files/xl` directory. The factory below is the only constructor
         * (the primary constructor is private), so a second writer cannot be
         * created even by accident.
         */
        private val processHost = ProcessSingleton<ProbeEngineViewModel>()

        /**
         * The process's one view model, created on first use.
         *
         * Every Activity asks for this rather than `by viewModels()`: an
         * Activity-scoped store is exactly what produced two hosts when a
         * launcher start created a second Activity instead of reusing the first.
         * The process is the release point; [onCleared] is the defensive path.
         */
        internal fun sharedHost(application: Application): ProbeEngineViewModel {
            processHost.peek()?.let { existing ->
                LogcatHostLog.info(
                    "host owner: reusing the process-wide host composition; " +
                        "no second host/WAL writer is constructed",
                )
                return existing
            }
            return processHost.obtain {
                LogcatHostLog.info(
                    "host owner: constructing the process-wide host composition " +
                        "(the only WorkspaceLog writer in this process)",
                )
                ProbeEngineViewModel(application)
            }
        }

        /** Subdirectory of filesDir that owns the WAL (wal.md §1's `xl`). */
        const val WORKSPACE_DIRECTORY = "xl"

        /**
         * Per-boot overlay members beside the WAL (`files/xl/boot-overlay/`).
         *
         * Not part of the VFS, the WAL or §8's own entry set: it is the host's
         * scratch for the bytes it serves the Worker, exactly like iOS's
         * `overlay-<boot_id>.tar` under its workspace root. Recovery ignores it.
         */
        const val BOOT_OVERLAY_DIRECTORY = "boot-overlay"

        /** The App turn's own logcat tag; the acceptance script greps it. */
        const val TAG_TURN = "PDSHAppTurn"

        /** The tool names §2 folds into the changed-files card (write/edit/str_replace_editor). */
        val WRITE_TOOLS: Set<String> = setOf("write", "edit", "str_replace_editor")

        /** `0644` for a workspace file the person imported. */
        const val FILE_MODE: Int = 0b110100100

        /** Characters a workspace file name may not carry; everything else is kept. */
        val FILE_NAME_DISALLOWED: Regex = Regex("[^A-Za-z0-9._-]")

        const val HOST_READY_TIMEOUT_MILLIS = 180_000L
        const val ENGINE_READY_TIMEOUT_MILLIS = 180_000L
        /** 使用预设: one bounded `session/create`, not the 3-minute generic wait. */
        const val AGENT_PRESET_SESSION_TIMEOUT_MILLIS = 30_000L
        const val AGENT_PRESET_SESSION_ATTEMPT_TIMEOUT_MILLIS = 10_000L
        /** One source-aligned Worker page; older pages remain explicitly loadable. */
        const val SUBAGENT_HISTORY_PAGE_SIZE = 60
        /** A stalled cursor/page read leaves the currently selected conversation intact. */
        const val SUBAGENT_HISTORY_TIMEOUT_MILLIS = 10_000L

    }
}

/**
 * Re-reads the durable chat store and applies it to [sessions] and the open [chat].
 *
 * This is the load half of [ProbeEngineViewModel.reloadChatMetadata], kept at file
 * scope so the JVM suite can drive the same read over a real [ChatSessionStore]
 * without constructing an Android `Application`.
 */
internal suspend fun reloadChatMetadataInto(
    store: ChatSessionStore,
    sessions: MutableStateFlow<HostSessionSnapshot>,
    chat: MutableStateFlow<ChatUiState>,
) {
    val records = withContext(Dispatchers.IO) { store.loadAll() }
    applyChatRecordsTo(records, sessions, chat, syncCurrentTitle = true)
}

/**
 * Projects one chat-store read into the host's session rows and the open chat.
 *
 * [syncCurrentTitle] is off for the existing background refresh paths and on for
 * [reloadChatMetadataInto]: only a HostShell metadata command needs the open
 * conversation's title mirror, and doing it on every background read would make
 * an in-flight rename race with unrelated refreshes.
 */
internal fun applyChatRecordsTo(
    records: List<ChatRecord>,
    sessions: MutableStateFlow<HostSessionSnapshot>,
    chat: MutableStateFlow<ChatUiState>,
    syncCurrentTitle: Boolean,
) {
    fun ChatRecord.listing() = HostSessionRecord(id, updatedAtMs, title, workspaceID, pinned)
    val ids = records.map { it.id }.toSet()
    val claims = records.flatMap { it.workerSessionIds }.toSet()
    val active = records.filterNot { it.archived }
    sessions.update { snapshot -> snapshot.copy(
        waiting = false,
        sessions = mergeSessions(snapshot.sessions.filterNot { it.id in ids || it.id in claims }, active.map { it.listing() }),
        archivedSessions = records.filter { it.archived }.map { it.listing() },
        pinnedSessionIDs = active.filter { it.pinned }.map { it.id }.toSet(),
        currentSessionID = snapshot.currentSessionID?.takeUnless { id -> records.any { it.id == id && it.archived } },
    ) }
    if (!syncCurrentTitle) return
    val live = chat.value
    val stored = records.firstOrNull { it.id == live.chatId } ?: return
    if (stored.title != live.title) {
        chat.update { current -> if (current.chatId == live.chatId) current.copy(title = stored.title) else current }
    }
}

/**
 * Merges two session reads without losing the newer timestamp of either.
 *
 * The store scan and the turn observation can name the same session; the
 * merged row carries the max of the two readings and the list stays ordered
 * by that reading (newest first). Host order is the sessions page's input
 * order, so this is the order the rows appear in.
 *
 * Ordering caveat: newest-first by the host's one measured time. The iOS
 * baseline orders by its management model, not by a per-session timestamp,
 * and the UI contract does not specify a session order, so the two platforms
 * can list the same sessions in different orders. This is a known difference,
 * not a hidden choice; a contract-level order would replace this rule.
 */
internal fun mergeSessions(
    fromStore: List<HostSessionRecord>,
    observed: List<HostSessionRecord>,
): List<HostSessionRecord> {
    val merged = LinkedHashMap<String, HostSessionRecord>()
    for (record in fromStore + observed) {
        val previous = merged[record.id]
        merged[record.id] = if (previous == null) {
            record
        } else {
            HostSessionRecord(
                id = record.id,
                lastActivityMs = newer(previous.lastActivityMs, record.lastActivityMs),
                // An empty title is "this source has no name", never "the name is
                // empty": the chat record's name must survive a journal merge.
                title = previous.title.ifEmpty { record.title },
            )
        }
    }
    return merged.values.sortedByDescending { it.lastActivityMs ?: Long.MIN_VALUE }
}

private fun newer(previous: Long?, next: Long?): Long? = when {
    previous == null -> next
    next == null -> previous
    else -> maxOf(previous, next)
}

/**
 * The chat state after a refused transcript write.
 *
 * [existing] is the row read before the attempt (`null` when it is missing);
 * [outcome] is the store receipt when one came back. The page's existing error
 * banner is the only surface, so neither a missing row nor a non-`Persisted`
 * receipt can stay log-only.
 */
internal fun chatWriteFailureState(
    current: ChatUiState,
    chatId: String,
    existing: ChatRecord?,
    outcome: ChatWriteOutcome?,
): ChatUiState {
    if (current.chatId != chatId) return current
    val message = when {
        existing == null -> "聊天记录不存在，本次内容没有保存。"
        outcome is ChatWriteOutcome.Stale -> "聊天记录已在别处更新，本次内容没有保存；请重试。"
        else -> "聊天记录没有保存，请重试。"
    }
    return current.copy(error = message, bannerDismissed = false)
}

/**
 * One journal scan's outcome.
 *
 * @param sessions the session rows the store recovered.
 * @param failure the token-free page label when the scan failed; non-null means
 *   [sessions] is empty because nothing was read, not because nothing exists.
 */
private data class SessionScan(
    val sessions: List<HostSessionRecord> = emptyList(),
    val failure: String? = null,
)

/**
 * The engine's frame consumer, forwarded to the host once it exists.
 *
 * The engine is constructed before the host because the host takes the engine;
 * this seam is the other half of that cycle. [attach] happens in the view
 * model's `init` before `host.start()`, and `@Volatile` publishes the target to
 * the origin's threads.
 */
private class HostChannelSeam : LoopbackChannelHandler {
    @Volatile
    private var delegate: LoopbackChannelHandler? = null

    fun attach(delegate: LoopbackChannelHandler) {
        this.delegate = delegate
    }

    private fun target(): LoopbackChannelHandler =
        delegate ?: error("the host channel handler was not attached before the engine started")

    override suspend fun onOpen(connection: LoopbackConnection) {
        target().onOpen(connection)
    }

    override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
        target().onBinary(connection, payload)
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
        target().onClosed(connection, cause)
    }
}

/**
 * The `:net` anonymous credential for the demo's scripted upstream.
 *
 * No key is stored in this build; the gateway still strips the Worker's
 * authorization and applies "nothing", which is the honest value for an
 * anonymous exact-origin grant. A production host replaces this provider.
 */
private object AnonymousCredentialProvider : GatewayCredentialProvider {
    override fun resolve(scope: CredentialScope): GatewayCredential = GatewayCredential.None
}

/**
 * The facade's tokens-free log, routed to logcat under its own tag.
 *
 * `:dsh` defaults to `HostLog.Println`; a tagged adapter keeps the host's
 * `host boot`, `wal/1` and `host HELLO sent` provenance greppable next to the
 * engine's `PDSHEngine` lines.
 */
private object LogcatHostLog : HostLog {
    private const val TAG = "PDSHHost"

    override fun debug(message: String) {
        Log.d(TAG, message)
    }

    override fun info(message: String) {
        Log.i(TAG, message)
    }

    override fun warn(message: String) {
        Log.w(TAG, message)
    }

    override fun error(message: String) {
        Log.e(TAG, message)
    }
}

/**
 * The `:platform` empty Notifier for a build with no notification surface.
 *
 * `:dsh` has no production `Notifier` implementation (its background lane owns
 * the foreground-service notifications, not this facade's recovery notice), and
 * :app never creates a notification channel or asks for POST_NOTIFICATIONS.
 * Reporting [NotifierAvailability.DISABLED] is what makes that visible: the host
 * logs the degraded presentation path instead of silently dropping a notice.
 */
private object DisabledNotifier : Notifier {
    override val availability: NotifierAvailability = NotifierAvailability.DISABLED

    override fun notify(
        id: Int,
        title: String,
        body: String,
        ongoing: Boolean,
        action: NotificationAction?,
    ) = Unit

    override fun cancel(id: Int) = Unit
}
