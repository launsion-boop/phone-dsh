// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot.store

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteStatement
import com.phonedsh.bot.store.BotSqlDriver
import com.phonedsh.bot.store.SqlDriverException
import com.phonedsh.bot.store.SqlRow
import com.phonedsh.bot.store.SqlValue
import java.io.File

/**
 * The Android runtime adapter for the P25 store seam (`spec/bot/v1/store.md`
 * §1–§2). The logical path is `<Context.filesDir>/PhoneDSHBot/domain.sqlite`;
 * there is no shared or external storage and no per-Bot database.
 */
class AndroidBotSqlDriver private constructor(
    private val database: SQLiteDatabase,
    private val databaseFile: File,
) : BotSqlDriver {
    override val isOpen: Boolean
        get() = database.isOpen

    override fun execute(sql: String, bindings: List<SqlValue>) {
        try {
            if (bindings.isEmpty()) {
                database.execSQL(sql)
            } else {
                database.compileStatement(sql).use { statement ->
                    bind(statement, bindings)
                    statement.execute()
                }
            }
        } catch (error: Throwable) {
            throw SqlDriverException(error.message ?: "SQLite execute failed", error)
        }
    }

    override fun query(sql: String, bindings: List<SqlValue>): List<SqlRow> {
        val args = bindings.map { value ->
            when (value) {
                SqlValue.Null -> null
                is SqlValue.Integer -> value.value.toString()
                is SqlValue.Real -> value.value.toString()
                is SqlValue.Text -> value.value
                is SqlValue.Blob -> throw SqlDriverException(
                    "android.database.sqlite.rawQuery cannot bind a BLOB selection argument",
                )
            }
        }.toTypedArray()
        val cursor: Cursor = try {
            database.rawQuery(sql, args)
        } catch (error: Throwable) {
            throw SqlDriverException(error.message ?: "SQLite query failed", error)
        }
        cursor.use {
            val columns = it.columnNames.toList()
            val rows = ArrayList<SqlRow>()
            while (it.moveToNext()) {
                val values = (0 until it.columnCount).map { index ->
                    when (it.getType(index)) {
                        Cursor.FIELD_TYPE_NULL -> SqlValue.Null
                        Cursor.FIELD_TYPE_INTEGER -> SqlValue.Integer(it.getLong(index))
                        Cursor.FIELD_TYPE_FLOAT -> SqlValue.Real(it.getDouble(index))
                        Cursor.FIELD_TYPE_BLOB -> SqlValue.Blob(it.getBlob(index))
                        else -> SqlValue.Text(it.getString(index))
                    }
                }
                rows += SqlRow(columns, values)
            }
            return rows
        }
    }

    override fun userVersion(): Int {
        query("PRAGMA user_version").firstOrNull()?.valuesAsText()?.firstOrNull()?.let {
            return it.toIntOrNull() ?: 0
        }
        return 0
    }

    override fun setUserVersion(version: Int) {
        execute("PRAGMA user_version=$version")
    }

    override fun beginImmediate() {
        database.beginTransaction()
    }

    override fun commit() {
        database.setTransactionSuccessful()
        database.endTransaction()
    }

    override fun rollback() {
        if (database.inTransaction()) database.endTransaction()
    }

    override fun close() {
        restrictFiles()
        if (database.isOpen) database.close()
    }

    private fun bind(statement: SQLiteStatement, bindings: List<SqlValue>) {
        for ((index, value) in bindings.withIndex()) {
            val position = index + 1
            when (value) {
                SqlValue.Null -> statement.bindNull(position)
                is SqlValue.Integer -> statement.bindLong(position, value.value)
                is SqlValue.Real -> statement.bindDouble(position, value.value)
                is SqlValue.Text -> statement.bindString(position, value.value)
                is SqlValue.Blob -> statement.bindBlob(position, value.bytes)
            }
        }
    }

    private fun restrictFiles() {
        restrict(databaseFile, directory = false)
        for (suffix in listOf("-wal", "-shm")) {
            restrict(File(databaseFile.path + suffix), directory = false)
        }
        restrict(databaseFile.parentFile ?: return, directory = true)
    }

    companion object {
        private fun restrict(file: File, directory: Boolean) {
            if (!file.exists()) return
            file.setReadable(false, false)
            file.setWritable(false, false)
            if (directory) file.setExecutable(false, false)
            file.setReadable(true, true)
            file.setWritable(true, true)
            if (directory) file.setExecutable(true, true)
        }

        /** Opens (and on first use creates) the one App-private database. */
        fun open(context: Context): AndroidBotSqlDriver {
            val root = File(context.filesDir, "PhoneDSHBot")
            if (!root.isDirectory && !root.mkdirs()) {
                throw SqlDriverException("cannot create the Bot data directory: ${root.path}")
            }
            restrict(root, directory = true)
            val file = File(root, "domain.sqlite")
            val database = try {
                SQLiteDatabase.openDatabase(
                    file.absolutePath,
                    null,
                    SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY,
                )
            } catch (error: Throwable) {
                throw SqlDriverException(error.message ?: "cannot open ${file.path}", error)
            }
            val driver = AndroidBotSqlDriver(database, file)
            driver.restrictFiles()
            return driver
        }
    }
}
