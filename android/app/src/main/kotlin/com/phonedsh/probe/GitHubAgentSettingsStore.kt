// phone-dsh — :app: the GitHub agent credential store.
// SPDX-License-Identifier: MIT
//
// Android half of `Sources/PhoneDSH/PhoneGitHubAgentSettings.swift` (P18
// `PC-20261112-github-agent-credential`):
//
//   * one fine-grained token in the platform `SecureStore` (the same
//     AndroidKeyStore AES-GCM envelope as the model key and the PCLink seed);
//     the record is keyed by the iOS service + account pair;
//   * one explicit write opt-in in the app's single `SharedPreferences` file,
//     under the frozen key `phone-dsh.github.agent.allow-writes`, default false.
//
// The token is independent of the read-only Discover connector: that connector
// has its own record and never grants agent writes.
//
// The token never crosses this class: `readToken` is only used to build the
// `/v1/http` bearer (through `GitHubAgentCredentialProvider`) and to answer
// `hasToken`; the facts handed to the page carry no value, and nothing here
// logs, formats or exposes it in `toString()`.
//
// The Worker sees only two non-secret environment facts, decided by
// `environment`: `PDSH_GITHUB_AUTH=1` when a readable token exists and
// `PDSH_GITHUB_WRITE=1` only when the opt-in is also on.

package com.phonedsh.probe

import android.content.Context
import com.phonedsh.engine.GitHubAgentEnvironment
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GitHubAgentCredentialProvider
import com.phonedsh.gateway.GitHubTokenSource
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.android.AndroidSecureStore
import com.phonedsh.ui.page.GitHubAgentFacts
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.runBlocking

/**
 * The GitHub agent token and the separate write opt-in.
 *
 * @param secure the device secret envelope (AndroidKeyStore AES-GCM under
 *   `noBackupFilesDir`).
 * @param preferences the app's one preferences file; the write key is the iOS
 *   `UserDefaults` key string verbatim.
 */
internal class GitHubAgentSettingsStore(
    private val secure: SecureStore,
    private val preferences: PreferenceFile,
) {
    private val state = MutableStateFlow(factsNow())

    /** What the settings page renders; never contains the token. */
    val facts: StateFlow<GitHubAgentFacts> = state.asStateFlow()

    /** True only when a non-empty, readable token exists. */
    fun hasToken(): Boolean = state.value.hasToken

    /** The explicit write opt-in, default false. */
    fun allowWrites(): Boolean = state.value.allowWrites

    /**
     * Stores one fine-grained token.
     *
     * Whitespace is trimmed exactly as the baseline does; an empty value or one
     * that spans lines is refused before the store is touched. The bytes are
     * zeroed after the write, and a write that cannot be read back is a
     * failure rather than a success the next engine start would contradict.
     *
     * @return true when the record exists after the write.
     */
    fun saveToken(raw: String): Boolean {
        val value = raw.trim()
        if (value.isEmpty() || value.any { it == '\n' || it == '\r' }) return false
        val bytes = value.toByteArray(Charsets.UTF_8)
        val written = try {
            runBlocking { secure.put(SECURE_KEY, bytes) }
            true
        } catch (failure: IOException) {
            false
        } catch (failure: Exception) {
            false
        } finally {
            bytes.fill(0)
        }
        refresh()
        return written && state.value.hasToken
    }

    /** Removes the stored record; succeeds when nothing was stored. */
    fun deleteToken(): Boolean {
        val removed = try {
            runBlocking { secure.delete(SECURE_KEY) }
            true
        } catch (failure: Exception) {
            false
        }
        refresh()
        return removed && !state.value.hasToken
    }

    /** Persists the write opt-in under the frozen key. */
    fun setAllowWrites(value: Boolean): Boolean {
        val written = preferences.commitBoolean(ALLOW_WRITES_KEY, value)
        refresh()
        return written
    }

    /**
     * The P16 fact pair. The token itself is not part of this value.
     *
     * `enabled` is true: this store only exists when the App supports the
     * feature, matching the Swift configuration's default.
     */
    fun environment(): GitHubAgentEnvironment = GitHubAgentEnvironment(
        enabled = true,
        tokenAvailable = state.value.hasToken,
        allowWrites = state.value.allowWrites,
    )

    /** The `/v1/http` bearer source; never logged or cached by the caller. */
    fun tokenSource(): GitHubTokenSource = GitHubTokenSource { readToken() }

    /**
     * Wraps the host's model/egress provider with the GitHub scope rule. The
     * base provider keeps every non-GitHub scope unchanged.
     */
    fun credentialProvider(base: GatewayCredentialProvider): GatewayCredentialProvider =
        GitHubAgentCredentialProvider(base = base, tokenSource = tokenSource())

    /**
     * Reads the token for the gateway only.
     *
     * An unreadable record is anonymous (`null`), exactly as the Swift
     * provider's `try?` — a broken KeyStore entry must not turn a public read
     * into a failed request or leak the model key.
     */
    private fun readToken(): String? {
        val lookup = try {
            runBlocking { secure.get(SECURE_KEY) }
        } catch (failure: Exception) {
            return null
        }
        return when (lookup) {
            is SecureLookup.Found -> {
                val bytes = lookup.value
                try {
                    String(bytes, Charsets.UTF_8).trim().ifEmpty { null }
                } finally {
                    bytes.fill(0)
                }
            }
            SecureLookup.Absent -> null
            is SecureLookup.Unreadable -> null
        }
    }

    private fun factsNow(): GitHubAgentFacts = GitHubAgentFacts(
        hasToken = readToken() != null,
        allowWrites = preferences.boolean(ALLOW_WRITES_KEY) ?: false,
    )

    private fun refresh() {
        state.value = factsNow()
    }

    companion object {
        /** The iOS Keychain service. */
        const val SERVICE: String = "dev.phone-dsh.github.agent"

        /** The iOS Keychain account. */
        const val ACCOUNT: String = "access-token"

        /** The one `SecureStore` key holding the token; it contains no secret. */
        const val SECURE_KEY: String = "$SERVICE/$ACCOUNT"

        /** The explicit write opt-in (the iOS `UserDefaults` key string). */
        const val ALLOW_WRITES_KEY: String = "phone-dsh.github.agent.allow-writes"

        private val installed = AtomicReference<GitHubAgentSettingsStore?>(null)

        /**
         * Binds the process-wide store to [context]'s encrypted envelope and
         * preference file. Idempotent, so a second Activity cannot replace the
         * store under a running engine.
         */
        fun install(context: Context): GitHubAgentSettingsStore {
            installed.get()?.let { return it }
            return synchronized(this) {
                installed.get() ?: GitHubAgentSettingsStore(
                    secure = AndroidSecureStore(context.applicationContext),
                    preferences = SharedPreferenceFile(context.applicationContext),
                ).also { installed.set(it) }
            }
        }

        /** The installed store, or `null` when the composition root has not run. */
        fun active(): GitHubAgentSettingsStore? = installed.get()

        /** The process-wide store, installing it if needed. */
        fun get(context: Context): GitHubAgentSettingsStore = install(context)
    }
}
