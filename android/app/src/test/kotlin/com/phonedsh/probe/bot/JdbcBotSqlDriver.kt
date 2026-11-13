// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.bot.store.BotSqlDriver
import com.phonedsh.bot.store.SqlDriverException
import com.phonedsh.bot.store.SqlRow
import com.phonedsh.bot.store.SqlValue
import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.sql.ResultSet

/** The real P25 store over a throwaway JVM SQLite database. */
class JdbcBotSqlDriver private constructor(
    private val connection: Connection,
    private val file: File,
) : BotSqlDriver {
    override val isOpen: Boolean
        get() = !connection.isClosed

    override fun execute(sql: String, bindings: List<SqlValue>) {
        try {
            connection.prepareStatement(sql).use { statement ->
                bind(statement, bindings)
                statement.execute()
            }
        } catch (error: Throwable) {
            throw SqlDriverException(error.message ?: "execute failed", error)
        }
    }

    override fun query(sql: String, bindings: List<SqlValue>): List<SqlRow> {
        try {
            connection.prepareStatement(sql).use { statement ->
                bind(statement, bindings)
                statement.executeQuery().use { rows ->
                    val columns = (1..rows.metaData.columnCount).map(rows.metaData::getColumnName)
                    val result = ArrayList<SqlRow>()
                    while (rows.next()) {
                        result += SqlRow(columns, (1..rows.metaData.columnCount).map { index ->
                            valueAt(rows, index)
                        })
                    }
                    return result
                }
            }
        } catch (error: Throwable) {
            throw SqlDriverException(error.message ?: "query failed", error)
        }
    }

    override fun userVersion(): Int =
        query("PRAGMA user_version").firstOrNull()?.valuesAsText()?.firstOrNull()?.toIntOrNull() ?: 0

    override fun setUserVersion(version: Int) {
        execute("PRAGMA user_version=$version")
    }

    override fun beginImmediate() {
        connection.autoCommit = false
    }

    override fun commit() {
        connection.commit()
        connection.autoCommit = true
    }

    override fun rollback() {
        if (!connection.autoCommit) {
            connection.rollback()
            connection.autoCommit = true
        }
    }

    override fun close() {
        if (!connection.isClosed) connection.close()
        file.delete()
    }

    private fun bind(statement: java.sql.PreparedStatement, bindings: List<SqlValue>) {
        for ((index, value) in bindings.withIndex()) {
            val position = index + 1
            when (value) {
                SqlValue.Null -> statement.setObject(position, null)
                is SqlValue.Integer -> statement.setLong(position, value.value)
                is SqlValue.Real -> statement.setDouble(position, value.value)
                is SqlValue.Text -> statement.setString(position, value.value)
                is SqlValue.Blob -> statement.setBytes(position, value.bytes)
            }
        }
    }

    private fun valueAt(rows: ResultSet, index: Int): SqlValue = when (rows.getObject(index)) {
        null -> SqlValue.Null
        is Int, is Long, is Short, is Byte -> SqlValue.Integer(rows.getLong(index))
        is Double, is Float -> SqlValue.Real(rows.getDouble(index))
        is ByteArray -> SqlValue.Blob(rows.getBytes(index))
        else -> SqlValue.Text(rows.getString(index))
    }

    companion object {
        fun open(file: File): JdbcBotSqlDriver {
            val connection = DriverManager.getConnection("jdbc:sqlite:${file.absolutePath}")
            return JdbcBotSqlDriver(connection, file)
        }
    }
}
