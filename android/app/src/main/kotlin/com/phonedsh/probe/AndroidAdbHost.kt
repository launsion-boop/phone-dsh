// phone-dsh — :app: the process-owned Android ADB host (native android_* tools).
// SPDX-License-Identifier: MIT
//
// Composition root for `com.phonedsh.adb` (spec/v1/native-mcp.md, P05; persisted
// target and receipts, P18). One instance per process, like iOS
// `ADBMCPServer.shared`:
//   * the saved target is the iOS JSON under the iOS key, in app-private
//     SharedPreferences (`commit()`, so a save is durable when it returns);
//   * the RSA identity is PKCS#8 inside `AndroidSecureStore` (AndroidKeyStore
//     AES-GCM, `noBackupFilesDir`), never plaintext, never in the Worker;
//   * receipts live in `noBackupFilesDir/android-adb-receipts`, so a restored
//     backup cannot replay or forge a device action's outcome;
//   * the same [server] is the engine's `/mcp/native` and this page's 测试连接,
//     so the page and the tools share one serialized operation slot.

package com.phonedsh.probe

import android.content.Context
import android.os.SystemClock
import com.phonedsh.adb.AdbClient
import com.phonedsh.adb.AdbConfiguration
import com.phonedsh.adb.AdbFailure
import com.phonedsh.adb.AdbFailureKind
import com.phonedsh.adb.AdbIdentity
import com.phonedsh.adb.AdbMcpServer
import com.phonedsh.adb.AdbReceiptStore
import com.phonedsh.adb.AdbSettings
import com.phonedsh.adb.AdbSettingsStorage
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.AndroidAdbCandidate
import com.phonedsh.ui.page.AndroidAdbConnectPhase
import com.phonedsh.ui.page.AndroidAdbDraft
import com.phonedsh.ui.page.AndroidAdbFacts
import com.phonedsh.ui.page.inProgress
import java.io.File
import java.io.IOException
import java.nio.file.Path
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

internal class AndroidAdbHost private constructor(context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val storage = object : AdbSettingsStorage {
        override fun read(key: String): String? = preferences.getString(key, null)
        override fun write(key: String, value: String) {
            if (!preferences.edit().putString(key, value).commit()) throw IOException("Cannot save the Android ADB target")
        }
    }
    private val secureStore = AndroidSecureStore(context)
    private val settings = AdbSettings(storage)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val discovery = AndroidTvDiscovery(context)
    private var scanJob: Job? = null
    private var connectJob: Job? = null

    val server: AdbMcpServer = AdbMcpServer(
        settings = settings,
        executor = AdbClient(identity = { AdbIdentity.loadOrCreate(secureStore) }),
        receiptStore = AdbReceiptStore(File(context.noBackupFilesDir, RECEIPTS).toPath()),
    )

    private val state = MutableStateFlow(snapshot(AndroidAdbFacts(available = true)))
    val facts: StateFlow<AndroidAdbFacts> = state.asStateFlow()

    /** The materialized `/dsh/workspace` the workspace APK source reads from. */
    fun bindWorkspace(directory: Path) {
        scope.launch {
            try {
                server.setWorkspaceDirectory(directory)
            } catch (failure: AdbFailure) {
                state.update { it.copy(status = failure.message.orEmpty(), failed = true) }
            }
        }
    }

    /** Re-read the saved target (the model may have changed it with android_connect). */
    fun refresh() {
        state.update { snapshot(it) }
    }

    fun handle(action: PdshHostAction) {
        when (action) {
            is PdshHostAction.AndroidAdbSave -> perform("") {
                server.configure(configuration(action.draft))
                "已保存。"
            }
            is PdshHostAction.AndroidAdbCheck -> perform("请查看 Android 上的调试授权提示。") {
                server.checkConnection(configuration(action.draft))
            }
            is PdshHostAction.AndroidAdbScan -> scan()
            is PdshHostAction.AndroidAdbConnect -> connect(action.candidate)
            PdshHostAction.AndroidAdbCancel -> {
                // The only page-level stop verb: it also ends a foreground scan,
                // which is otherwise bounded only by its own 8 s budget.
                cancelScan()
                server.cancel()
                cancelConnection()
            }
            PdshHostAction.AndroidAdbCancelConnect -> cancelConnection()
            else -> return
        }
    }

    /** 扫描局域网: one foreground pass; the page reads [AndroidAdbFacts.scanning] and [AndroidAdbFacts.candidates]. */
    private fun scan() {
        if (state.value.scanning || state.value.busy ||
            state.value.connectionPhases.values.any { it.inProgress }
        ) {
            return
        }
        state.update { it.copy(scanning = true) }
        scanJob?.cancel()
        scanJob = scope.launch {
            val found = try {
                discovery.scan()
            } catch (cancelled: CancellationException) {
                state.update { it.copy(scanning = false) }
                throw cancelled
            } catch (_: Exception) {
                emptyList()
            }
            state.update { it.copy(scanning = false, candidates = found) }
        }
    }

    /**
     * 连接 one candidate through the existing ADB check/save path.
     *
     * ADB has no typed failure kind on this host, so "waiting for the TV's
     * authorization prompt" is recognized by the two messages the transport and
     * client use for it. Those are retried every [AUTHORIZE_RETRY_MS] until
     * [AUTHORIZE_TIMEOUT_MS]; every other failure ends the attempt immediately
     * with its message. Only a successful status command saves the target; a
     * cancelled or timed-out attempt never reports 已连接.
     */
    private fun connect(candidate: AndroidAdbCandidate) {
        val current = state.value
        if (!current.available || current.scanning || current.busy ||
            current.connectionPhases.values.any { it.inProgress }
        ) {
            return
        }
        val configuration = try {
            AdbConfiguration(enabled = true, host = candidate.host.trim(), port = candidate.port).also { it.endpoint() }
        } catch (failure: AdbFailure) {
            state.update {
                it.copy(
                    status = failure.message ?: "Android ADB 连接失败",
                    failed = true,
                    connectionPhases = it.connectionPhases + (candidate.id to AndroidAdbConnectPhase.Failed(
                        failure.message ?: "Android ADB 连接失败",
                    )),
                )
            }
            return
        }
        state.update {
            it.copy(
                busy = true,
                failed = false,
                connectionPhases = it.connectionPhases + (candidate.id to AndroidAdbConnectPhase.Probing),
            )
        }
        connectJob?.cancel()
        connectJob = scope.launch { runConnection(candidate.id, configuration) }
    }

    private suspend fun runConnection(id: String, configuration: AdbConfiguration) {
        val started = SystemClock.elapsedRealtime()
        try {
            while (true) {
                val elapsed = SystemClock.elapsedRealtime() - started
                if (elapsed >= AUTHORIZE_TIMEOUT_MS) {
                    publishConnectionFailure(id, authorizationTimeoutMessage())
                    return
                }
                try {
                    // Same 4 s per-attempt probe as the iOS checker, so the
                    // 2 s retry below actually ticks while the TV holds the
                    // socket open for its authorization prompt.
                    val status = server.checkConnection(configuration, AUTHORIZE_PROBE_TIMEOUT_MS)
                    val model = status.lineSequence()
                        .map { it.trim() }
                        .firstOrNull { it.isNotEmpty() }
                        .orEmpty()
                        .ifEmpty { configuration.host }
                    server.configure(configuration)
                    state.update { current ->
                        snapshot(current).copy(
                            status = "已连接：$model",
                            failed = false,
                            busy = false,
                            connectionPhases = current.connectionPhases + (
                                id to AndroidAdbConnectPhase.Connected(model)
                                ),
                        )
                    }
                    connectJob = null
                    return
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    val message = failure.message ?: "Android ADB 连接失败"
                    // Typed on the Android end exactly like iOS `ADBFailureKind`:
                    // never infer "waiting for the TV prompt" from message text.
                    if ((failure as? AdbFailure)?.kind != AdbFailureKind.UNAUTHORIZED) {
                        publishConnectionFailure(id, message)
                        return
                    }
                    val waited = SystemClock.elapsedRealtime() - started
                    if (waited >= AUTHORIZE_TIMEOUT_MS) {
                        publishConnectionFailure(id, authorizationTimeoutMessage())
                        return
                    }
                    state.update {
                        it.copy(
                            connectionPhases = it.connectionPhases + (
                                id to AndroidAdbConnectPhase.AwaitingAuthorization(((waited + 999) / 1_000).toInt())
                                ),
                        )
                    }
                    delay(minOf(AUTHORIZE_RETRY_MS, AUTHORIZE_TIMEOUT_MS - waited))
                }
            }
        } catch (cancelled: CancellationException) {
            // 取消 or 停止当前 Android 操作: clear the row without inventing a result.
            state.update {
                it.copy(busy = false, connectionPhases = it.connectionPhases - id)
            }
            throw cancelled
        }
    }

    /** Stop the foreground scan; a cancelled pass never publishes its partial list. */
    private fun cancelScan() {
        if (!state.value.scanning) return
        scanJob?.cancel()
        scanJob = null
        state.update { it.copy(scanning = false) }
    }

    /** 取消 the row's attempt; a canceled attempt is not a failure and not a success. */
    private fun cancelConnection() {
        val activeID = state.value.connectionPhases.entries
            .firstOrNull { it.value.inProgress }
            ?.key
        connectJob?.cancel()
        connectJob = null
        if (activeID == null) return
        server.cancel()
        state.update {
            it.copy(busy = false, connectionPhases = it.connectionPhases - activeID)
        }
    }

    private fun publishConnectionFailure(id: String, message: String) {
        state.update {
            it.copy(
                status = message,
                failed = true,
                busy = false,
                connectionPhases = it.connectionPhases + (id to AndroidAdbConnectPhase.Failed(message)),
            )
        }
    }

    private fun authorizationTimeoutMessage(): String =
        "等待调试授权超时（已等待 90 秒）。请在电视上确认显示“允许调试”的提示；若没有提示，" +
            "请在电视的开发者选项里撤销 USB 调试授权后重试。"

    private fun perform(pending: String, block: suspend () -> String) {
        if (state.value.busy) return
        state.update { it.copy(busy = true, failed = false, status = pending.ifEmpty { it.status }) }
        scope.launch {
            val (text, failed) = try {
                block() to false
            } catch (failure: CancellationException) {
                throw failure
            } catch (failure: Exception) {
                (failure.message ?: "Android ADB 操作失败") to true
            }
            state.update { snapshot(it).copy(status = text, failed = failed, busy = false) }
        }
    }

    private fun snapshot(current: AndroidAdbFacts): AndroidAdbFacts {
        val saved = settings.load()
        val changed = saved.enabled != current.enabled || saved.host != current.host || saved.port != current.port
        return current.copy(
            available = true,
            enabled = saved.enabled,
            host = saved.host,
            port = saved.port,
            revision = if (changed) current.revision + 1 else current.revision,
        )
    }

    private fun configuration(draft: AndroidAdbDraft): AdbConfiguration {
        val port = draft.port.trim().toIntOrNull()?.takeIf { it in 1..65535 } ?: throw AdbFailure("端口必须是 1–65535")
        return AdbConfiguration(draft.enabled, draft.host.trim(), port)
    }

    companion object {
        private const val PREFERENCES = "phone-dsh.android-adb"
        private const val RECEIPTS = "android-adb-receipts"

        /** iOS `TVConnector` waits 90 s for the TV's debugging authorization. */
        private const val AUTHORIZE_TIMEOUT_MS: Long = 90_000
        private const val AUTHORIZE_RETRY_MS: Long = 2_000

        /** Per-attempt probe; the iOS `ADBShellTVChecker` uses the same 4 s. */
        private const val AUTHORIZE_PROBE_TIMEOUT_MS: Long = 4_000

        @Volatile
        private var instance: AndroidAdbHost? = null

        fun get(context: Context): AndroidAdbHost =
            instance ?: synchronized(this) {
                instance ?: AndroidAdbHost(context.applicationContext).also { instance = it }
            }
    }
}
