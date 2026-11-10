// phone-dsh — :app: the process-owned tono-account session (Tono 账号).
// SPDX-License-Identifier: MIT
//
// Composition root for `com.phonedsh.account` (spec/v1/tono-account.md, P05 and
// P18). One instance per process, like iOS `TonoAccountSession.shared`:
//   * the session record (refresh token, sign-in time, phone hint) is one item
//     `tono-account.session` inside `AndroidSecureStore` (AndroidKeyStore
//     AES-GCM, `noBackupFilesDir`); `put` replaces it in one write;
//   * the access token stays in this process's memory;
//   * the same [session] backs the page and the model / search key sources
//     (`TonoAccountKeySource.overlay`), so a sign-in applies to the next request.
// Nothing here logs: the phone number, code and tokens never leave the session.

package com.phonedsh.probe

import android.content.Context
import android.os.Build
import com.phonedsh.account.HttpUrlConnectionTonoAccountTransport
import com.phonedsh.account.TonoAccountChallenge
import com.phonedsh.account.TonoAccountClient
import com.phonedsh.account.TonoAccountException
import com.phonedsh.account.TonoAccountNotice
import com.phonedsh.account.TonoAccountSession
import com.phonedsh.account.TonoAccountState
import com.phonedsh.account.TonoAccountStore
import com.phonedsh.account.TonoDeviceInfo
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.TonoAccountFacts
import java.io.IOException
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/** The one `SecureStore` item holding the session record (§3). */
internal class SecureStoreTonoAccountStore(private val store: SecureStore) : TonoAccountStore {
    override fun load(): ByteArray? = when (val lookup = runBlocking { store.get(KEY) }) {
        is SecureLookup.Found -> lookup.value
        SecureLookup.Absent -> null
        // Unreadable is not "absent": the session stays unloaded and reads again later.
        is SecureLookup.Unreadable -> throw IOException("the tono account record cannot be read")
    }

    override fun save(bytes: ByteArray) = runBlocking { store.put(KEY, bytes) }

    override fun delete() = runBlocking { store.delete(KEY) }

    companion object {
        const val KEY: String = "tono-account.session"
    }
}

internal class TonoAccountHost private constructor(context: Context) {
    val session: TonoAccountSession = TonoAccountSession(
        client = TonoAccountClient(HttpUrlConnectionTonoAccountTransport()),
        store = SecureStoreTonoAccountStore(AndroidSecureStore(context)),
        device = TonoDeviceInfo(
            platform = "android",
            deviceName = "Android",
            appVersion = appVersion(context),
            osVersion = Build.VERSION.RELEASE ?: "",
        ),
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var challenge: TonoAccountChallenge? = null
    private val state = MutableStateFlow(TonoAccountFacts(available = true))
    val facts: StateFlow<TonoAccountFacts> = state.asStateFlow()

    init {
        scope.launch {
            val flow = withContext(Dispatchers.IO) { session.stateFlow }
            flow.collect { value -> state.update { project(value, it) } }
        }
    }

    fun handle(action: PdshHostAction) {
        when (action) {
            is PdshHostAction.TonoAccountRequestCode -> perform {
                challenge = session.requestCode(action.phone)
                session.clearNotice()
            }
            is PdshHostAction.TonoAccountSignIn -> perform {
                val pending = challenge ?: return@perform
                session.signIn(pending, action.code)
                // The number and the code are only needed for this step.
                challenge = null
            }
            PdshHostAction.TonoAccountSignOut -> perform { session.signOut() }
            else -> return
        }
    }

    private fun perform(block: () -> Unit) {
        if (state.value.busy) return
        state.update { it.copy(busy = true, failed = false) }
        scope.launch {
            val failure = try {
                withContext(Dispatchers.IO) { block() }
                null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: TonoAccountException) {
                failure.message
            } catch (_: Exception) {
                "账号操作失败，请稍后再试。"
            }
            state.update { current ->
                val projected = project(session.state, current)
                projected.copy(
                    busy = false,
                    failed = failure != null,
                    status = failure ?: projected.status,
                    revision = if (failure == null && projected.signedIn != current.signedIn) current.revision + 1 else current.revision,
                )
            }
        }
    }

    private fun project(value: TonoAccountState, current: TonoAccountFacts): TonoAccountFacts = when (value) {
        is TonoAccountState.SignedIn -> current.copy(
            available = true,
            signedIn = true,
            phoneHint = value.phoneHint,
            reverifyAt = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(value.reverifyAtMs)),
            codeSent = false,
            status = "",
            failed = false,
        )
        is TonoAccountState.SignedOut -> {
            val hint = challenge?.phoneHint
            current.copy(
                available = true,
                signedIn = false,
                phoneHint = null,
                reverifyAt = "",
                codeSent = challenge != null,
                status = when {
                    value.notice == TonoAccountNotice.REVERIFY_REQUIRED -> "登录已满 180 天，请重新验证手机号。"
                    value.notice == TonoAccountNotice.SESSION_ENDED -> "登录已失效，请重新登录。"
                    hint != null -> "验证码已发送到尾号 $hint 的手机。"
                    else -> "登录后，云端模型和网页搜索按账号使用；没登录时继续用粘贴的密钥。"
                },
                failed = false,
            )
        }
    }

    companion object {
        @Volatile
        private var instance: TonoAccountHost? = null

        fun get(context: Context): TonoAccountHost =
            instance ?: synchronized(this) {
                instance ?: TonoAccountHost(context.applicationContext).also { instance = it }
            }

        /** The installed session, or `null` before the composition root ran. */
        fun activeSession(): TonoAccountSession? = instance?.session

        private fun appVersion(context: Context): String = try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0"
        } catch (_: Exception) {
            "0"
        }
    }
}
