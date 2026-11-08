// phone-dsh — :app: the saved SSH connections and their Keystore credentials.
// SPDX-License-Identifier: MIT
//
// Android half of `SSHSettingsStore` in
// `examples/probe-app/PhoneDSHProbe/SSHSettingsPage.swift` (P18 persisted
// settings; PC-20261105-native-ssh-adb). Two stores, as on iOS:
//
//   * profiles (no secrets): `<noBackupFilesDir>/ssh/connections.v1.json`, a JSON
//     array with the iOS `SavedSSHConnection` member names (`id`, `alias`, `host`,
//     `port`, `username`, `usePrivateKey`, `trustedHostKey`). The `.v1` file name
//     is the version, like the iOS `phone-dsh.ssh.connections.v1` key; it is
//     written atomically (temp file + rename) and skipped by backup;
//   * credentials: one `SecureStore` entry per profile id (`ssh.<id>`), a JSON
//     object with the iOS `SSHSecrets` member names (`password`, `privateKey`,
//     `passphrase`), AES-GCM under an `AndroidKeyStore` key — the same envelope
//     as the model API key (`ApiKeyStore`, whitelist `platform.keychain-credential-store`).
//
// Security rules: a profile cannot be saved without a confirmed host key; moving
// a profile to another host or port drops its old key; the plaintext credential
// is read only by [resolve] for one connection attempt and never enters the
// facts, a log line or the Worker. Unknown files/entries from a newer version are
// not rewritten by this code except on an explicit save/delete.

package com.phonedsh.probe

import android.content.Context
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.ssh.SshCancellation
import com.phonedsh.ssh.SshConnection
import com.phonedsh.ssh.SshFailure
import com.phonedsh.ssh.SshTransport
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.SSHConnectionDraft
import com.phonedsh.ui.page.SSHConnectionFact
import com.phonedsh.ui.page.SSHFacts
import com.phonedsh.ui.page.SSHInspectionFact
import com.phonedsh.ui.page.SSHSaveResultFact
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject

/** One saved profile (no credential), field-for-field the iOS `SavedSSHConnection`. */
internal data class SavedSshConnection(
    val id: String,
    val alias: String,
    val host: String,
    val port: Int,
    val username: String,
    val usePrivateKey: Boolean,
    val trustedHostKey: String,
)

/** The credential blob; [toString] never prints it. */
internal class SshSecrets(val password: String = "", val privateKey: String = "", val passphrase: String = "") {
    override fun toString(): String = "SshSecrets(redacted)"
}

/**
 * @param directory where `connections.v1.json` lives (`noBackupFilesDir/ssh`).
 * @param secrets the credential envelope.
 * @param inspect the host-key observer; injectable so tests need no network.
 */
internal class SshSettingsStore(
    private val directory: File,
    private val secrets: SecureStore,
    private val inspect: (host: String, port: Int) -> String = { host, port ->
        SshTransport.inspectHostKey(host, port, cancellation = SshCancellation())
    },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val lock = Any()
    private val file = File(directory, FILE_NAME)
    private var connections: List<SavedSshConnection>
    private var loadError: String = ""
    private val state: MutableStateFlow<SSHFacts>

    init {
        connections = try {
            load()
        } catch (failure: Exception) {
            // Unreadable is not "empty": keep the file, report, refuse writes.
            loadError = "SSH 连接列表无法读取（${failure.javaClass.simpleName}）；未作修改。"
            emptyList()
        }
        state = MutableStateFlow(SSHFacts(available = loadError.isEmpty(), connections = facts(connections), error = loadError))
    }

    /** The page's facts; never carries a credential. */
    val facts: StateFlow<SSHFacts> get() = state

    /** `ssh --list`: alias, user, host and port per line (no secrets). */
    fun list(): String = synchronized(lock) {
        if (connections.isEmpty()) return "No saved SSH connections. Add a connection in Settings → SSH."
        connections.joinToString("\n") { "${it.alias}\t${it.username}@${it.host}:${it.port}" }
    }

    /**
     * Alias (or unique `host` / `user@host` / `[host]` / `user@[host]`) → connection with
     * its credential, exactly the iOS matching rule.
     */
    fun resolve(destination: String): SshConnection {
        val profile = synchronized(lock) {
            val matches = connections.filter {
                it.alias == destination || it.host == destination || "${it.username}@${it.host}" == destination ||
                    "${it.username}@[${it.host}]" == destination || "[${it.host}]" == destination
            }
            if (matches.size != 1) throw SshFailure("Unknown or ambiguous SSH connection. Use ssh --list and a saved alias.")
            matches.first()
        }
        val credential = readSecrets(profile.id)
        return SshConnection(
            host = profile.host,
            port = profile.port,
            username = profile.username,
            password = if (profile.usePrivateKey) "" else credential.password,
            privateKey = if (profile.usePrivateKey) credential.privateKey else "",
            passphrase = if (profile.usePrivateKey) credential.passphrase else "",
            trustedHostKey = profile.trustedHostKey,
        )
    }

    /** Dispatches one `ssh.*` page action; the work runs off the main thread. */
    fun handle(action: PdshHostAction) {
        when (action) {
            is PdshHostAction.SshSaveConnection -> scope.launch {
                val outcome = try {
                    save(action.draft)
                    SSHSaveResultFact(action.requestId, ok = true)
                } catch (failure: SshFailure) {
                    SSHSaveResultFact(action.requestId, ok = false, message = failure.message.orEmpty())
                } catch (failure: IOException) {
                    SSHSaveResultFact(action.requestId, ok = false, message = "保存失败：${failure.javaClass.simpleName}")
                }
                publish { it.copy(saveResult = outcome) }
            }
            is PdshHostAction.SshDeleteConnection -> scope.launch {
                val outcome = try {
                    remove(action.id)
                    SSHSaveResultFact(action.requestId, ok = true)
                } catch (failure: Exception) {
                    SSHSaveResultFact(action.requestId, ok = false, message = "删除失败：${failure.message ?: failure.javaClass.simpleName}")
                }
                publish { it.copy(saveResult = outcome) }
            }
            is PdshHostAction.SshInspectHostKey -> scope.launch {
                val outcome = try {
                    val key = inspect(action.host, action.port)
                    SSHInspectionFact(action.requestId, action.host, action.port, key, SshTransport.fingerprint(key))
                } catch (failure: SshFailure) {
                    SSHInspectionFact(action.requestId, action.host, action.port, error = failure.message.orEmpty())
                } catch (failure: Exception) {
                    SSHInspectionFact(
                        action.requestId, action.host, action.port,
                        error = "无法读取服务器指纹：${failure.message ?: failure.javaClass.simpleName}",
                    )
                }
                publish { it.copy(inspection = outcome) }
            }
            else -> Unit
        }
    }

    /**
     * Validates and persists one draft (iOS `save(_:credentials:)`).
     *
     * A blank secret keeps the stored one only for an existing profile with the
     * same authentication mode; the other mode's stored secret is cleared, so a
     * profile never holds both a password and a key.
     */
    fun save(draft: SSHConnectionDraft) {
        synchronized(lock) {
            if (loadError.isNotEmpty()) throw SshFailure(loadError)
            if (!ALIAS.matches(draft.alias) || draft.host.isEmpty() || draft.host.any { it.isWhitespace() } ||
                draft.username.isEmpty() || draft.port !in 1..65535 || draft.trustedHostKey.isEmpty()
            ) {
                throw SshFailure("请填写连接别名、地址、用户名，并确认服务器指纹。")
            }
            if (SshTransport.fingerprint(draft.trustedHostKey) == "Invalid key") throw SshFailure("服务器指纹无效，请重新读取。")
            val existing = draft.id?.let { id -> connections.firstOrNull { it.id == id } }
            if (draft.id != null && existing == null) throw SshFailure("该连接已不存在。")
            if (connections.any { it.id != draft.id && it.alias == draft.alias }) throw SshFailure("连接别名已存在。")
            // Defence in depth: the editor clears trust on a host/port edit; a
            // draft that moved endpoints but kept the old key is refused here.
            if (existing != null && (existing.host != draft.host || existing.port != draft.port) &&
                existing.trustedHostKey == draft.trustedHostKey
            ) {
                throw SshFailure("地址或端口已改变，请重新读取并确认服务器指纹。")
            }
            // Read the stored credential only when a blank field asks to keep it.
            val stored by lazy { existing?.let { readSecrets(it.id) } }
            val sameMode = existing != null && existing.usePrivateKey == draft.usePrivateKey
            val credential = if (draft.usePrivateKey) {
                val key = draft.privateKey.ifEmpty { if (sameMode) stored?.privateKey.orEmpty() else "" }
                val passphrase = if (draft.privateKey.isEmpty() && draft.passphrase.isEmpty() && sameMode) {
                    stored?.passphrase.orEmpty()
                } else {
                    draft.passphrase
                }
                SshSecrets(privateKey = key, passphrase = passphrase)
            } else {
                SshSecrets(password = draft.password.ifEmpty { if (sameMode) stored?.password.orEmpty() else "" })
            }
            if (if (draft.usePrivateKey) credential.privateKey.isEmpty() else credential.password.isEmpty()) {
                throw SshFailure("请填写密码或私钥。")
            }
            if (draft.usePrivateKey && credential.privateKey.length > MAX_KEY_CHARS) throw SshFailure("私钥过大。")
            val profile = SavedSshConnection(
                id = existing?.id ?: UUID.randomUUID().toString(),
                alias = draft.alias,
                host = draft.host,
                port = draft.port,
                username = draft.username,
                usePrivateKey = draft.usePrivateKey,
                trustedHostKey = draft.trustedHostKey,
            )
            val next = connections.filter { it.id != profile.id } + profile
            // Credential first, then the profile list: a crash in between leaves
            // an unreferenced credential, never a profile without its secret.
            runBlocking { secrets.put(SECRET_PREFIX + profile.id, encode(credential)) }
            write(next)
            connections = next
        }
        publish { it.copy(connections = facts(connections)) }
    }

    /** Removes the profile and its credential (iOS `remove(_:)`). */
    fun remove(id: String) {
        synchronized(lock) {
            if (loadError.isNotEmpty()) throw SshFailure(loadError)
            val next = connections.filter { it.id != id }
            write(next)
            connections = next
            runBlocking { secrets.delete(SECRET_PREFIX + id) }
        }
        publish { it.copy(connections = facts(connections)) }
    }

    private fun publish(change: (SSHFacts) -> SSHFacts) {
        synchronized(lock) { state.value = change(state.value) }
    }

    private fun readSecrets(id: String): SshSecrets {
        val lookup = try {
            runBlocking { secrets.get(SECRET_PREFIX + id) }
        } catch (failure: Exception) {
            throw SshFailure("SSH credential store is unavailable; open Settings → SSH and save the connection again.")
        }
        return when (lookup) {
            SecureLookup.Absent -> SshSecrets()
            is SecureLookup.Unreadable ->
                throw SshFailure("The saved SSH credential cannot be read (${lookup.reason}); save the connection again in Settings → SSH.")
            is SecureLookup.Found -> try {
                val json = JSONObject(String(lookup.value, Charsets.UTF_8))
                SshSecrets(
                    password = json.optString("password", ""),
                    privateKey = json.optString("privateKey", ""),
                    passphrase = json.optString("passphrase", ""),
                )
            } catch (failure: Exception) {
                throw SshFailure("The saved SSH credential is damaged; save the connection again in Settings → SSH.")
            }
        }
    }

    private fun encode(secrets: SshSecrets): ByteArray =
        JSONObject()
            .put("password", secrets.password)
            .put("privateKey", secrets.privateKey)
            .put("passphrase", secrets.passphrase)
            .toString()
            .toByteArray(Charsets.UTF_8)

    private fun load(): List<SavedSshConnection> {
        if (!file.isFile) return emptyList()
        val array = JSONArray(file.readText(Charsets.UTF_8))
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            SavedSshConnection(
                id = item.getString("id"),
                alias = item.getString("alias"),
                host = item.getString("host"),
                port = item.getInt("port"),
                username = item.getString("username"),
                usePrivateKey = item.optBoolean("usePrivateKey", false),
                trustedHostKey = item.optString("trustedHostKey", ""),
            )
        }
    }

    private fun write(list: List<SavedSshConnection>) {
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("cannot create the SSH settings directory")
        val array = JSONArray()
        for (item in list) {
            array.put(
                JSONObject()
                    .put("id", item.id)
                    .put("alias", item.alias)
                    .put("host", item.host)
                    .put("port", item.port)
                    .put("username", item.username)
                    .put("usePrivateKey", item.usePrivateKey)
                    .put("trustedHostKey", item.trustedHostKey),
            )
        }
        val temp = File(directory, "$FILE_NAME.tmp")
        java.io.FileOutputStream(temp).use { output ->
            output.write(array.toString().toByteArray(Charsets.UTF_8))
            output.fd.sync()
        }
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    private fun facts(list: List<SavedSshConnection>): List<SSHConnectionFact> = list.map {
        SSHConnectionFact(
            id = it.id,
            alias = it.alias,
            host = it.host,
            port = it.port,
            username = it.username,
            usePrivateKey = it.usePrivateKey,
            trustedHostKey = it.trustedHostKey,
            fingerprint = SshTransport.fingerprint(it.trustedHostKey),
        )
    }

    companion object {
        const val FILE_NAME: String = "connections.v1.json"
        const val SECRET_PREFIX: String = "ssh."
        private const val MAX_KEY_CHARS = 65_536
        private val ALIAS = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

        @Volatile
        private var shared: SshSettingsStore? = null

        /** The process-wide store, shared by the settings page and the exec tool. */
        fun get(context: Context): SshSettingsStore {
            shared?.let { return it }
            return synchronized(this) {
                shared ?: SshSettingsStore(
                    directory = File(context.applicationContext.noBackupFilesDir, "ssh"),
                    secrets = AndroidSecureStore(context.applicationContext),
                ).also { shared = it }
            }
        }
    }
}
