// SPDX-License-Identifier: MIT
// phone-dsh — :app: what the phone task queue keeps, on the app's own stores.
//
// spec/v1/cloud-tasks.md §2, §3, §7: the device id and the enable flag live in
// the app's one preferences file under the contract's key names; each private
// key record is one `SecureStore` item `cloud-tasks.key.<key_id>`
// (AndroidKeyStore-wrapped, `noBackupFilesDir`). The signed-in user id is read
// from the tono-account session record at the moment of use. No new persisted
// format is introduced here.
package com.phonedsh.probe.cloudtasks

import com.phonedsh.account.TonoAccountProtocol
import com.phonedsh.cloudtasks.CloudTaskKeyStore
import com.phonedsh.cloudtasks.CloudTaskPreferences
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.probe.PreferenceFile
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking

/** The contract's two preference keys in the app's preferences file; writes are committed. */
internal class PreferenceFileCloudTaskPreferences(private val file: PreferenceFile) : CloudTaskPreferences {
    override fun string(key: String): String? = file.string(key)

    override fun putString(key: String, value: String) {
        file.commitString(key, value)
    }

    override fun boolean(key: String): Boolean? = file.boolean(key)

    override fun putBoolean(key: String, value: Boolean) {
        file.commitBoolean(key, value)
    }
}

/**
 * One `SecureStore` item per `key_id`. A store that cannot be read or written
 * now (locked, invalidated key, I/O) is an [IOException] — never "no key": the
 * coordinator then sends no ack and creates no replacement key.
 */
internal class SecureStoreCloudTaskKeyStore(private val store: SecureStore) : CloudTaskKeyStore {
    override fun load(keyId: String): ByteArray? =
        when (val lookup = guarded("read") { store.get(CloudTaskKeyStore.storageKey(keyId)) }) {
            is SecureLookup.Found -> lookup.value
            SecureLookup.Absent -> null
            is SecureLookup.Unreadable -> throw IOException("the cloud task key cannot be read")
        }

    override fun save(keyId: String, record: ByteArray) {
        guarded("write") { store.put(CloudTaskKeyStore.storageKey(keyId), record) }
    }

    override fun delete(keyId: String) {
        guarded("delete") { store.delete(CloudTaskKeyStore.storageKey(keyId)) }
    }

    private fun <T> guarded(what: String, block: suspend () -> T): T = try {
        runBlocking { block() }
    } catch (failure: IOException) {
        throw failure
    } catch (cancelled: CancellationException) {
        throw IOException("the cloud task key store $what was interrupted")
    } catch (failure: Exception) {
        // Keystore failures arrive as runtime exceptions; none of them means "absent".
        throw IOException("the cloud task key store cannot $what now (${failure.javaClass.simpleName})")
    }
}

/**
 * The signed-in tono account, from the stored session record and the live
 * session. Three answers on purpose: an unreadable store or a record without a
 * user id is "cannot tell", which neither admits nor cancels anything.
 */
internal class TonoCloudTaskAccountReader(
    /** The stored session record bytes, `null` when absent; throws when the store is unreadable. */
    private val loadRecord: () -> ByteArray?,
    /** Whether the live session reports a signed-in account. */
    private val sessionSignedIn: () -> Boolean,
) : () -> CloudTaskAccount {
    override fun invoke(): CloudTaskAccount {
        val bytes = try {
            loadRecord()
        } catch (_: Exception) {
            return CloudTaskAccount.Unknown
        }
        val live = try {
            sessionSignedIn()
        } catch (_: Exception) {
            return CloudTaskAccount.Unknown
        }
        val record = bytes?.let { TonoAccountProtocol.decodeRecord(it) }
        return when {
            // A record the session could not delete at sign-out is not a sign-in.
            !live -> CloudTaskAccount.SignedOut
            // Signed in, but the record is not stored yet or carries no user id.
            record == null -> CloudTaskAccount.Unknown
            else -> record.userId?.let { CloudTaskAccount.SignedIn(it) } ?: CloudTaskAccount.Unknown
        }
    }
}
