// Device-only evidence for the SQLite backend: schema shape and persistence.
// SPDX-License-Identifier: MIT
//
// The shared contract proves the store's semantics on SQLite; these cases pin the
// two things a fake cannot prove: the on-disk table really is the one the brief
// specifies, and the bytes survive closing and reopening the file.

package com.phonedsh.domain

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.domain.sqlite.SqliteConnectionFactory
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SqliteDomainStoreDeviceTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val databaseName = "domain-device.db"

    @Before
    fun resetDatabase() {
        context.deleteDatabase(databaseName)
    }

    @After
    fun removeDatabase() {
        context.deleteDatabase(databaseName)
    }

    @Test
    fun theOnDiskTableIsTheContractedShape() {
        openStore().use { store ->
            store.put(DomainNames.SESSION, "k", byteArrayOf(1))
        }

        val path = context.getDatabasePath(databaseName)
        SQLiteDatabase.openDatabase(path.path, null, SQLiteDatabase.OPEN_READONLY).use { database ->
            val columns = ArrayList<Column>()
            database.rawQuery("PRAGMA table_info(domain_entry)", null).use { cursor ->
                while (cursor.moveToNext()) {
                    columns.add(
                        Column(
                            name = cursor.getString(1),
                            type = cursor.getString(2),
                            notNull = cursor.getInt(3) != 0,
                            primaryKeyIndex = cursor.getInt(5),
                        ),
                    )
                }
            }

            assertEquals(
                listOf("domain", "key", "value", "updated_at"),
                columns.map { it.name },
            )
            assertEquals(listOf("TEXT", "TEXT", "BLOB", "INTEGER"), columns.map { it.type })
            assertTrue(columns.all { it.notNull })
            assertEquals(
                listOf("domain", "key"),
                columns.filter { it.primaryKeyIndex > 0 }
                    .sortedBy { it.primaryKeyIndex }
                    .map { it.name },
            )
            assertEquals(2, columns.count { it.primaryKeyIndex > 0 })
        }
    }

    @Test
    fun binaryValuesSurviveCloseAndReopen() {
        val payload = ByteArray(256) { it.toByte() }

        openStore().use { store ->
            store.put(DomainNames.MEMORY, "blob", payload)
        }

        openStore().use { store ->
            assertArrayEquals(payload, store.get(DomainNames.MEMORY, "blob"))
        }
    }

    private fun openStore(): DomainStore = DomainStoreCore(
        SqliteConnectionFactory(context, databaseName),
        QuotaPolicy.uniform(1L shl 20),
        FakeClock(1_000L),
    )

    private class Column(
        val name: String,
        val type: String,
        val notNull: Boolean,
        val primaryKeyIndex: Int,
    )
}
