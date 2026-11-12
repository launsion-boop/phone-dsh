// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

import java.sql.Connection
import java.sql.DriverManager
import java.sql.PreparedStatement

/**
 * The JVM test adapter over `org.xerial:sqlite-jdbc` (approved as
 * `testImplementation` of `:bot` only, PC-20261112-android-bot-w4 §7). It owns
 * no P25 SQL; it binds the [BotSqlDriver] seam.
 */
class SqliteJdbcDriver(private val path: String) : BotSqlDriver {
    private val connection: Connection

    init {
        Class.forName("org.sqlite.JDBC")
        connection = DriverManager.getConnection("jdbc:sqlite:$path")
    }

    override val isOpen: Boolean
        get() = !connection.isClosed

    override fun execute(sql: String, bindings: List<SqlValue>) {
        connection.prepareStatement(sql).use { statement ->
            bind(statement, bindings)
            statement.execute()
        }
    }

    override fun query(sql: String, bindings: List<SqlValue>): List<SqlRow> {
        connection.prepareStatement(sql).use { statement ->
            bind(statement, bindings)
            statement.executeQuery().use { rows ->
                val metadata = rows.metaData
                val columns = (1..metadata.columnCount).map { metadata.getColumnName(it) }
                val result = ArrayList<SqlRow>()
                while (rows.next()) {
                    val values = (1..metadata.columnCount).map { index ->
                        when (val value = rows.getObject(index)) {
                            null -> SqlValue.Null
                            is Int -> SqlValue.Integer(value.toLong())
                            is Long -> SqlValue.Integer(value)
                            is Short -> SqlValue.Integer(value.toLong())
                            is Byte -> SqlValue.Integer(value.toLong())
                            is Float -> SqlValue.Real(value.toDouble())
                            is Double -> SqlValue.Real(value)
                            is ByteArray -> SqlValue.Blob(value)
                            is String -> SqlValue.Text(value)
                            else -> SqlValue.Text(value.toString())
                        }
                    }
                    result += SqlRow(columns, values)
                }
                return result
            }
        }
    }

    override fun userVersion(): Int =
        query("PRAGMA user_version").firstOrNull()?.valuesAsText()?.firstOrNull()?.toIntOrNull() ?: 0

    override fun setUserVersion(version: Int) {
        execute("PRAGMA user_version=$version")
    }

    override fun beginImmediate() {
        execute("BEGIN IMMEDIATE")
    }

    override fun commit() {
        execute("COMMIT")
    }

    override fun rollback() {
        execute("ROLLBACK")
    }

    override fun close() {
        if (!connection.isClosed) connection.close()
    }

    private fun bind(statement: PreparedStatement, bindings: List<SqlValue>) {
        for ((index, value) in bindings.withIndex()) {
            when (value) {
                SqlValue.Null -> statement.setObject(index + 1, null)
                is SqlValue.Integer -> statement.setLong(index + 1, value.value)
                is SqlValue.Real -> statement.setDouble(index + 1, value.value)
                is SqlValue.Text -> statement.setString(index + 1, value.value)
                is SqlValue.Blob -> statement.setBytes(index + 1, value.bytes)
            }
        }
    }
}
