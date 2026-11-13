// SPDX-License-Identifier: MIT
package com.phonedsh.bot.store

/**
 * The small SQL seam the P25 store sits behind (`spec/bot/v1/store.md` §2).
 *
 * The normative DDL and every statement live in [BotDomainStore]; this
 * interface only binds values, runs statements and owns the SQLite transaction
 * boundary. The JVM tests use the `sqlite-jdbc` adapter under `src/test`; the
 * Android runtime uses `android.database.sqlite` from `:app`. Nothing here
 * imports an SQLite library.
 */
public sealed interface SqlValue {
    public data object Null : SqlValue

    public data class Integer(public val value: Long) : SqlValue

    public data class Real(public val value: Double) : SqlValue

    public data class Text(public val value: String) : SqlValue

    public class Blob(public val bytes: ByteArray) : SqlValue
}

/** One result row, addressable by column name or ordinal. */
public class SqlRow(
    public val columnNames: List<String>,
    public val values: List<SqlValue>,
) {
    public fun value(column: String): SqlValue? {
        val index = columnNames.indexOf(column)
        return if (index >= 0) values.getOrNull(index) else null
    }

    public fun text(column: String): String? = (value(column) as? SqlValue.Text)?.value

    public fun integer(column: String): Long? = (value(column) as? SqlValue.Integer)?.value

    public fun blob(column: String): ByteArray? = (value(column) as? SqlValue.Blob)?.bytes

    public fun valuesAsText(): List<String?> = values.map {
        when (it) {
            SqlValue.Null -> null
            is SqlValue.Integer -> it.value.toString()
            is SqlValue.Real -> it.value.toString()
            is SqlValue.Text -> it.value
            is SqlValue.Blob -> it.bytes.toString(Charsets.UTF_8)
        }
    }
}

public interface BotSqlDriver : AutoCloseable {
    public val isOpen: Boolean

    public fun execute(sql: String, bindings: List<SqlValue> = emptyList())

    public fun query(sql: String, bindings: List<SqlValue> = emptyList()): List<SqlRow>

    public fun userVersion(): Int

    public fun setUserVersion(version: Int)

    /** `BEGIN IMMEDIATE`, so two connections serialize on the write lock. */
    public fun beginImmediate()

    public fun commit()

    public fun rollback()

    override fun close()
}

public class SqlDriverException(message: String, cause: Throwable? = null) : Exception(message, cause)
