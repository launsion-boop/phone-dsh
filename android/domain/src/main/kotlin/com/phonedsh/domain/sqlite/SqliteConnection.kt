// The real SQLite backend: the only file that imports android.database.sqlite.
// SPDX-License-Identifier: MIT
//
// No Room, no SQLDelight: the framework helper and prepared statements are
// enough for one table, and the platform layer must not add a code generator or
// a second SQL dialect to the build (K3 brief). The plan's §8.2 SQLDelight +
// shared-SQL-contract decision is a deliberate, recorded deviation.
//
// Deliberately absent: WAL mode and any synchronous/durability knob. The domain
// store makes no power-loss claim (`wal.md` §5.2's epoch/ack ladder is for the
// host WAL only), so the backend stays on SQLite's defaults and this file never
// pretends to close an epoch. SQLite's transaction is used for atomicity and for
// recovering its own file after a process kill, nothing more.

package com.phonedsh.domain.sqlite

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.database.sqlite.SQLiteStatement
import com.phonedsh.domain.Connection
import com.phonedsh.domain.ConnectionFactory
import com.phonedsh.domain.KeyRange
import com.phonedsh.domain.StoredEntry
import com.phonedsh.domain.Transaction
import java.io.Closeable

/** The schema version. Bumping it requires a migration; there is none yet. */
private const val SCHEMA_VERSION = 1

private const val TABLE = "domain_entry"

private const val CREATE_TABLE = """
    CREATE TABLE $TABLE (
        domain TEXT NOT NULL,
        key TEXT NOT NULL,
        value BLOB NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (domain, key)
    )
"""

private const val INSERT_OR_REPLACE =
    "INSERT OR REPLACE INTO $TABLE (domain, key, value, updated_at) VALUES (?, ?, ?, ?)"

private const val DELETE_ROW = "DELETE FROM $TABLE WHERE domain = ? AND key = ?"

private const val READ_ROW = "SELECT value, updated_at FROM $TABLE WHERE domain = ? AND key = ?"

private const val SCAN_ORDERED =
    "SELECT key, value, updated_at FROM $TABLE WHERE domain = ? AND key >= ? ORDER BY key"

private const val SCAN_BOUNDED =
    "SELECT key, value, updated_at FROM $TABLE WHERE domain = ? AND key >= ? AND key < ? ORDER BY key"

private const val DOMAIN_USAGE = "SELECT COALESCE(SUM(LENGTH(value)), 0) FROM $TABLE WHERE domain = ?"

private const val LATEST_UPDATED_AT = "SELECT COALESCE(MAX(updated_at), 0) FROM $TABLE"

/**
 * A [ConnectionFactory] over the app's private SQLite database.
 *
 * `open()` is lazy: the helper does not touch the file until the store's first
 * operation, so constructing the factory in `Application.onCreate` is cheap.
 * Closing the returned connection closes the helper; opening again reopens the
 * same file.
 *
 * @param context any context; only `applicationContext` is retained.
 * @param databaseName the file name under `context.getDatabasePath`. `null`
 *   selects an in-memory database (used by tests).
 */
class SqliteConnectionFactory private constructor(
    private val helper: SQLiteOpenHelper,
) : ConnectionFactory {
    /** Opens the app-private database file [databaseName]. */
    constructor(
        context: Context,
        databaseName: String = DEFAULT_DATABASE_NAME,
    ) : this(DomainSqliteOpenHelper(context.applicationContext, databaseName))

    override fun open(): Connection = SqliteConnection(helper)

    companion object {
        /** The file the composition root gets by default. */
        const val DEFAULT_DATABASE_NAME = "phonedsh-domain.db"

        /** An in-memory database, for tests only: it dies with the connection. */
        fun inMemory(context: Context): SqliteConnectionFactory =
            SqliteConnectionFactory(DomainSqliteOpenHelper(context.applicationContext, null))
    }
}

/**
 * The framework helper. `onCreate` is the only place the schema is written, so a
 * table that differs from the K3 contract cannot be created by accident.
 */
private class DomainSqliteOpenHelper(
    context: Context,
    name: String?,
) : SQLiteOpenHelper(context, name, null, SCHEMA_VERSION) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(CREATE_TABLE)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Never drop domain data to "upgrade": a silent DELETE is exactly the
        // data loss budgets.md §5 forbids. A real migration is required first.
        throw IllegalStateException(
            "no migration from domain schema $oldVersion to $newVersion; " +
                "add an explicit migration before bumping SCHEMA_VERSION",
        )
    }
}

/**
 * One connection over the helper's database.
 *
 * Statements are prepared once and reused; they are owned by this connection and
 * closed with it. The store serialises transactions, so one set of statements is
 * never stepped by two threads at once.
 */
private class SqliteConnection(
    private val helper: SQLiteOpenHelper,
) : Connection {
    private var statements: Statements? = null

    override fun <T> transaction(body: (Transaction) -> T): T {
        val database = helper.writableDatabase
        val compiled = statements ?: Statements(database).also { statements = it }
        database.beginTransaction()
        try {
            val result = body(SqliteTransaction(database, compiled))
            database.setTransactionSuccessful()
            return result
        } finally {
            // endTransaction commits only when setTransactionSuccessful ran, so
            // every throw path (including the quota error) rolls back here.
            database.endTransaction()
        }
    }

    override fun close() {
        statements?.close()
        statements = null
        helper.close()
    }
}

/** The prepared write statements. Reads use `rawQuery`, which returns a cursor. */
private class Statements(database: SQLiteDatabase) : Closeable {
    val insert: SQLiteStatement = database.compileStatement(INSERT_OR_REPLACE)
    val delete: SQLiteStatement = database.compileStatement(DELETE_ROW)

    override fun close() {
        insert.close()
        delete.close()
    }
}

/** The typed statements of one transaction, implemented with SQLite. */
private class SqliteTransaction(
    private val database: SQLiteDatabase,
    private val statements: Statements,
) : Transaction {
    override fun read(domain: String, key: String): StoredEntry? =
        database.rawQuery(READ_ROW, arrayOf(domain, key)).use { cursor ->
            if (!cursor.moveToFirst()) return null
            StoredEntry(key, cursor.getBlob(0), cursor.getLong(1))
        }

    override fun write(domain: String, key: String, value: ByteArray, updatedAt: Long) {
        val statement = statements.insert
        statement.clearBindings()
        statement.bindString(1, domain)
        statement.bindString(2, key)
        statement.bindBlob(3, value)
        statement.bindLong(4, updatedAt)
        statement.executeInsert()
    }

    override fun delete(domain: String, key: String): Boolean {
        val statement = statements.delete
        statement.clearBindings()
        statement.bindString(1, domain)
        statement.bindString(2, key)
        return statement.executeUpdateDelete() > 0
    }

    override fun scan(domain: String, keyRange: KeyRange, limit: Int): List<StoredEntry> {
        val upper = keyRange.upper
        val sql = if (upper == null) SCAN_ORDERED else SCAN_BOUNDED
        val arguments =
            if (upper == null) {
                arrayOf(domain, keyRange.lower)
            } else {
                arrayOf(domain, keyRange.lower, upper)
            }
        // The limit is a validated Int (requireLimit runs above this layer), so
        // interpolating it cannot inject SQL; rawQuery has no integer binding.
        return database.rawQuery("$sql LIMIT $limit", arguments).use { cursor ->
            val entries = ArrayList<StoredEntry>(minOf(limit, 16))
            while (cursor.moveToNext()) {
                entries.add(StoredEntry(cursor.getString(0), cursor.getBlob(1), cursor.getLong(2)))
            }
            entries
        }
    }

    override fun usageBytes(domain: String): Long =
        database.rawQuery(DOMAIN_USAGE, arrayOf(domain)).use { cursor ->
            cursor.moveToFirst()
            cursor.getLong(0)
        }

    override fun latestUpdatedAt(): Long =
        database.rawQuery(LATEST_UPDATED_AT, null).use { cursor ->
            cursor.moveToFirst()
            cursor.getLong(0)
        }
}
