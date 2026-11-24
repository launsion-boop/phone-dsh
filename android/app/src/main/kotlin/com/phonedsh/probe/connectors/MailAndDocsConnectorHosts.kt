// phone-dsh — :app: 发现 › QQ 邮箱 / 网易邮箱 / Gmail 应用专用密码 and 发现 › 腾讯文档.
// SPDX-License-Identifier: MIT
//
// Kotlin ends of `MailConnectorPage.swift` (MailConnectorModel, MailSendApprover)
// and `MCPConnectorService.swift`. Codes and tokens live only in the Android
// Keystore-backed `AndroidSecureStore`; the account list (addresses only) is a
// private SharedPreferences entry. Unlike iOS, this host has no `phone/mcpUpsert`
// and no gateway injection for user MCP rows, so 腾讯文档 is served on
// `/mcp/native` by `McpConnectorNativeServer`, which calls the provider itself.

package com.phonedsh.probe.connectors

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.connectors.mcpoauth.McpConnectorCatalog
import com.phonedsh.connectors.mcpoauth.McpConnectorNativeServer
import com.phonedsh.connectors.mcpoauth.McpOAuthClient
import com.phonedsh.connectors.mcpoauth.McpOAuthException
import com.phonedsh.connectors.mcpoauth.McpOAuthRecord
import com.phonedsh.connectors.mcpoauth.McpOAuthStore
import com.phonedsh.connectors.mcpoauth.McpOAuthTokenSource
import com.phonedsh.connectors.mcpoauth.RemoteMcpClient
import com.phonedsh.loopback.NativeMcpServing
import com.phonedsh.mail.MailAccount
import com.phonedsh.mail.MailAccountStore
import com.phonedsh.mail.MailDraft
import com.phonedsh.mail.MailException
import com.phonedsh.mail.MailMcpServer
import com.phonedsh.mail.MailProvider
import com.phonedsh.mail.MailSendApproving
import com.phonedsh.mail.MailService
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.probe.AndroidAdbHost
import com.phonedsh.probe.MainActivity
import com.phonedsh.ui.page.MailAccountRow
import com.phonedsh.ui.page.MailConnectorAction
import com.phonedsh.ui.page.MailConnectorFacts
import com.phonedsh.ui.page.McpConnectorAction
import com.phonedsh.ui.page.McpConnectorFacts
import com.phonedsh.ui.page.McpConnectorPhase
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.io.File

// MARK: stores

/** Addresses in SharedPreferences, codes in the Keystore-backed store. */
internal class AppMailAccountStore(context: Context) : MailAccountStore {
    private val preferences = context.getSharedPreferences("pdsh_mail_accounts", Context.MODE_PRIVATE)
    private val secure = AndroidSecureStore(context)

    override fun accounts(): List<MailAccount> {
        val raw = preferences.getString(KEY, null) ?: return emptyList()
        val list = (runCatching { JsonValue.parse(raw) }.getOrNull() as? JsonArray)?.values ?: return emptyList()
        return list.mapNotNull { item ->
            val o = item as? JsonObject ?: return@mapNotNull null
            val address = (o["address"] as? JsonString)?.value ?: return@mapNotNull null
            val provider = (o["provider"] as? JsonString)?.value?.let(MailProvider::fromId) ?: return@mapNotNull null
            MailAccount(address, provider)
        }
    }

    override fun secret(account: MailAccount): String = runBlocking(Dispatchers.IO) {
        when (val found = secure.get(secretKey(account.address))) {
            is SecureLookup.Found -> String(found.value, Charsets.UTF_8).takeIf { it.isNotEmpty() } ?: throw MailException.store
            else -> throw MailException.store
        }
    }

    /** Secret first, then the list: a crash never lists an account without its code. */
    override fun save(account: MailAccount, secret: String) {
        runBlocking(Dispatchers.IO) { secure.put(secretKey(account.address), secret.toByteArray(Charsets.UTF_8)) }
        write(accounts().filter { it.address != account.address } + account)
    }

    /** List first, then the secret: a removed account is unusable at once. */
    override fun remove(address: String) {
        val key = address.trim().lowercase()
        write(accounts().filter { it.address != key })
        runBlocking(Dispatchers.IO) { secure.delete(secretKey(key)) }
    }

    private fun write(list: List<MailAccount>) {
        val json = JsonArray(list.sortedBy { it.address }.map {
            JsonObject(linkedMapOf("address" to JsonString(it.address), "provider" to JsonString(it.provider.id)))
        }).toJsonString()
        if (!preferences.edit().putString(KEY, json).commit()) throw MailException.store
    }

    private fun secretKey(address: String) = "mail.account.$address"

    private companion object { const val KEY = "accounts.v1" }
}

internal class AppMcpOAuthStore(context: Context) : McpOAuthStore {
    private val secure = AndroidSecureStore(context)

    override fun read(connectorId: String): McpOAuthRecord? = runBlocking(Dispatchers.IO) {
        (secure.get(key(connectorId)) as? SecureLookup.Found)?.let { McpOAuthRecord.decode(String(it.value, Charsets.UTF_8)) }
    }

    override fun write(connectorId: String, record: McpOAuthRecord) = runBlocking(Dispatchers.IO) {
        secure.put(key(connectorId), record.encode().toByteArray(Charsets.UTF_8))
    }

    override fun delete(connectorId: String) = runBlocking(Dispatchers.IO) { secure.delete(key(connectorId)) }

    private fun key(id: String) = "connector.$id.v1"
}

// MARK: mail

/** One send waiting for the user's answer in the app's dialog. */
internal class PendingMailSend(val account: MailAccount, val draft: MailDraft, val answer: CompletableDeferred<Boolean>)

internal class MailConnectorHost private constructor(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val store: MailAccountStore = AppMailAccountStore(context.applicationContext)
    private val service = MailService()
    private val state = MutableStateFlow(MailConnectorFacts(accounts = rows()))
    val facts: StateFlow<MailConnectorFacts> = state.asStateFlow()

    private val pendingState = MutableStateFlow<PendingMailSend?>(null)
    val pendingSend: StateFlow<PendingMailSend?> = pendingState.asStateFlow()

    /** Set by the shell while the app's window is resumed. */
    @Volatile var foreground: Boolean = false

    /** Without a visible window (background, Bot wake) the answer is "no". */
    val approver = MailSendApproving { account, draft ->
        if (!foreground) return@MailSendApproving false
        val answer = CompletableDeferred<Boolean>()
        pendingState.value = PendingMailSend(account, draft, answer)
        try {
            answer.await()
        } finally {
            if (pendingState.value?.answer === answer) pendingState.value = null
        }
    }

    fun answer(approved: Boolean) {
        pendingState.value?.answer?.complete(approved)
        pendingState.value = null
    }

    fun handle(action: MailConnectorAction) {
        when (action) {
            is MailConnectorAction.Add -> scope.launch { add(action) }
            is MailConnectorAction.Remove -> {
                try {
                    store.remove(action.address)
                    state.value = state.value.copy(accounts = rows(), error = null)
                } catch (failure: MailException) {
                    state.value = state.value.copy(error = failure.message)
                }
            }
        }
    }

    private suspend fun add(action: MailConnectorAction.Add) {
        val provider = MailProvider.fromId(action.providerId) ?: return
        val account = MailAccount.of(action.address, provider)
        // Codes are shown in groups; spaces are never part of them.
        val secret = action.secret.replace(" ", "").trim()
        if (provider.servers(account.address) == null) {
            state.value = state.value.copy(error = "请输入${provider.displayName}地址（${provider.domains.joinToString("、")}）。")
            return
        }
        if (secret.isEmpty()) {
            state.value = state.value.copy(error = "请填写${provider.secretName}。")
            return
        }
        state.value = state.value.copy(verifying = true, error = null)
        try {
            service.verify(account, secret)
            store.save(account, secret)
            state.value = MailConnectorFacts(accounts = rows())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            state.value = state.value.copy(verifying = false, error = failure.message ?: failure.javaClass.simpleName)
        }
    }

    private fun rows(): List<MailAccountRow> = store.accounts().map { MailAccountRow(it.address, it.provider.id) }

    companion object {
        @Volatile private var instance: MailConnectorHost? = null
        fun get(context: Context): MailConnectorHost =
            instance ?: synchronized(this) { instance ?: MailConnectorHost(context.applicationContext).also { instance = it } }
    }
}

// MARK: 腾讯文档

internal class TencentDocsConnectorHost private constructor(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val connector = McpConnectorCatalog.TENCENT_DOCS
    private val store: McpOAuthStore = AppMcpOAuthStore(context.applicationContext)
    private val client = McpOAuthClient(clientName = "Phone DSH")
    private val state = MutableStateFlow(McpConnectorFacts(phase = initialPhase()))
    val facts: StateFlow<McpConnectorFacts> = state.asStateFlow()

    private val tokens = McpOAuthTokenSource(connector, store, client, onReauthorizationRequired = {
        state.value = state.value.copy(phase = McpConnectorPhase.REAUTH)
    })
    private val remote = RemoteMcpClient(connector.url, { force -> tokens.bearer(force) })

    /** Wraps [fallback] with the 腾讯文档 tools while connected. */
    fun nativeServer(fallback: NativeMcpServing): McpConnectorNativeServer =
        McpConnectorNativeServer(fallback, connector, { state.value.phase == McpConnectorPhase.CONNECTED }, remote)
            .also { server = it }

    private var server: McpConnectorNativeServer? = null

    fun handle(action: McpConnectorAction) {
        when (action) {
            McpConnectorAction.Connect -> scope.launch { connect() }
            McpConnectorAction.Disconnect -> scope.launch {
                runCatching { store.delete(connector.id) }
                    .onSuccess { state.value = McpConnectorFacts(McpConnectorPhase.DISCONNECTED) }
                    .onFailure { state.value = state.value.copy(error = "无法删除本机保存的授权，请重试。") }
                server?.invalidate()
            }
        }
    }

    private suspend fun connect() {
        if (state.value.phase == McpConnectorPhase.CONNECTING) return
        val previous = state.value.phase
        state.value = McpConnectorFacts(McpConnectorPhase.CONNECTING)
        try {
            val redirect = McpConnectorCatalog.redirectUri(connector)
            // Reuse a stored client registration; rediscover only when absent.
            val registration = store.read(connector.id)?.registration?.takeIf { it.redirectUri == redirect }
                ?: client.register(client.discover(connector.url), redirect, connector.scope)
            val attempt = client.begin(registration, connector.scope)
            val callback = BrowserOAuthAuthorizer.authorize(attempt.url)
            store.write(connector.id, client.finish(attempt, callback))
            state.value = McpConnectorFacts(McpConnectorPhase.CONNECTED)
            server?.invalidate()
        } catch (cancelled: BrowserOAuthAuthorizer.Cancelled) {
            state.value = McpConnectorFacts(if (previous == McpConnectorPhase.REAUTH) McpConnectorPhase.REAUTH else initialPhase())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: McpOAuthException) {
            state.value = McpConnectorFacts(initialPhase(), failure.message)
        } catch (failure: Exception) {
            state.value = McpConnectorFacts(initialPhase(), "连接失败：${failure.message ?: failure.javaClass.simpleName}")
        }
    }

    private fun initialPhase(): McpConnectorPhase =
        if (runCatching { store.read(connector.id) }.getOrNull() != null) McpConnectorPhase.CONNECTED else McpConnectorPhase.DISCONNECTED

    companion object {
        @Volatile private var instance: TencentDocsConnectorHost? = null
        fun get(context: Context): TencentDocsConnectorHost =
            instance ?: synchronized(this) { instance ?: TencentDocsConnectorHost(context.applicationContext).also { instance = it } }
    }
}

/** Browser authorization for `phonedsh-oauth://callback/<connector>`; mirrors `BrowserGitHubWebAuthorizer`. */
internal object BrowserOAuthAuthorizer {
    class Cancelled : Exception("authorization cancelled")

    private val main = Handler(Looper.getMainLooper())
    private var pending: CompletableDeferred<String>? = null
    private var leftApp = false
    private val onResume: () -> Unit = {
        // The callback activity delivers before MainActivity resumes; a resume
        // with nothing delivered means the user came back without authorizing.
        if (leftApp) main.postDelayed({ pending?.completeExceptionally(Cancelled()) }, 600)
    }

    suspend fun authorize(url: String): String {
        pending?.completeExceptionally(Cancelled())
        val deferred = CompletableDeferred<String>()
        pending = deferred
        leftApp = false
        ConnectorActivityBridge.addResumeListener(onResume)
        try {
            if (!ConnectorActivityBridge.openInBrowser(url)) throw Cancelled()
            leftApp = true
            return deferred.await()
        } finally {
            ConnectorActivityBridge.removeResumeListener(onResume)
            if (pending === deferred) pending = null
        }
    }

    fun deliver(uri: String) {
        main.post { pending?.complete(uri) }
    }
}

/** Receives `phonedsh-oauth://callback/<connector>` and returns to the app. */
class McpOAuthCallbackActivity : android.app.Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.dataString?.let(BrowserOAuthAuthorizer::deliver)
        startActivity(
            Intent(this, MainActivity::class.java).addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
            ),
        )
        finish()
    }
}

// MARK: the /mcp/native chain

/** mail_* → tencent_docs__* → android_* (each answers its own tools and passes the rest on). */
internal object NativeMcpChain {
    @Volatile private var chain: NativeMcpServing? = null

    fun get(context: Context): NativeMcpServing = chain ?: synchronized(this) {
        chain ?: run {
            val app = context.applicationContext
            val docs = TencentDocsConnectorHost.get(app).nativeServer(AndroidAdbHost.get(app).server)
            val mail = MailConnectorHost.get(app)
            MailMcpServer(
                fallback = docs,
                store = mail.store,
                approver = mail.approver,
                receiptDirectory = File(app.noBackupFilesDir, "mail-send-receipts").toPath(),
            )
        }.also { chain = it }
    }
}
