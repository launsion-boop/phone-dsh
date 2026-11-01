// The device driver of the shared DomainStore contract, on real SQLite.
// SPDX-License-Identifier: MIT
//
// This class adds no assertion of its own: the value of the run is that the
// exact same cases as InMemoryDomainStoreTest go through the
// `android.database.sqlite` implementation. If the seam ever stops matching
// SQLite's semantics (transaction visibility, prefix range, SUM, PK conflict),
// this suite is what fails.

package com.phonedsh.domain

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.domain.sqlite.SqliteConnectionFactory
import org.junit.After
import org.junit.Before
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SqliteDomainStoreTest : DomainStoreContract() {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val databaseName = "domain-contract.db"
    private val factory = SqliteConnectionFactory(context, databaseName)

    @Before
    fun resetDatabase() {
        context.deleteDatabase(databaseName)
    }

    @After
    fun removeDatabase() {
        context.deleteDatabase(databaseName)
    }

    override fun connectionFactory(): ConnectionFactory = factory
}
