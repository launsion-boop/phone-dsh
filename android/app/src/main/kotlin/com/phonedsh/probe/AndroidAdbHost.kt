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
import com.phonedsh.adb.AdbClient
import com.phonedsh.adb.AdbConfiguration
import com.phonedsh.adb.AdbFailure
import com.phonedsh.adb.AdbIdentity
import com.phonedsh.adb.AdbMcpServer
import com.phonedsh.adb.AdbReceiptStore
import com.phonedsh.adb.AdbSettings
import com.phonedsh.adb.AdbSettingsStorage
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.AndroidAdbDraft
import com.phonedsh.ui.page.AndroidAdbFacts
import java.io.File
import java.io.IOException
import java.nio.file.Path
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
            PdshHostAction.AndroidAdbCancel -> server.cancel()
            else -> return
        }
    }

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

        @Volatile
        private var instance: AndroidAdbHost? = null

        fun get(context: Context): AndroidAdbHost =
            instance ?: synchronized(this) {
                instance ?: AndroidAdbHost(context.applicationContext).also { instance = it }
            }
    }
}
