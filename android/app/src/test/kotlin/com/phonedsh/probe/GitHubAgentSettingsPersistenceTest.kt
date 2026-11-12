// GitHubAgentSettingsStore / SharedPreferences: the write opt-in really persists.
// SPDX-License-Identifier: MIT
//
// The pure-JVM store test uses an in-memory [PreferenceFile]. This one drives the
// production `SharedPreferenceFile` binding under Robolectric, recreates the
// store (as the next engine start would) and reads the same frozen key back, so
// "the toggle persists" is a real SharedPreferences round trip, not a fake's
// in-memory map.
package com.phonedsh.probe

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.phonedsh.platform.SecureLookup
import com.phonedsh.platform.SecureStore
import com.phonedsh.platform.SecurityLevel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class GitHubAgentSettingsPersistenceTest {
    private class EmptySecureStore : SecureStore {
        override val level: SecurityLevel = SecurityLevel.SOFTWARE
        override suspend fun put(key: String, value: ByteArray) = Unit
        override suspend fun get(key: String): SecureLookup = SecureLookup.Absent
        override suspend fun delete(key: String) = Unit
    }

    private fun store(context: Context) = GitHubAgentSettingsStore(
        secure = EmptySecureStore(),
        preferences = SharedPreferenceFile(context, PreferenceStore.FILE_NAME),
    )

    @Test
    fun `the write opt in survives a store recreation under the frozen key`() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        SharedPreferenceFile(context, PreferenceStore.FILE_NAME)
            .remove(GitHubAgentSettingsStore.ALLOW_WRITES_KEY)

        val first = store(context)
        assertFalse(first.allowWrites())
        assertTrue(first.setAllowWrites(true))

        val second = store(context)
        assertTrue("the next engine start reads the same SharedPreferences key", second.allowWrites())

        assertTrue(second.setAllowWrites(false))
        assertFalse(store(context).allowWrites())
        SharedPreferenceFile(context, PreferenceStore.FILE_NAME)
            .remove(GitHubAgentSettingsStore.ALLOW_WRITES_KEY)
    }
}
