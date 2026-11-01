// The host driver of the shared DomainStore contract.
// SPDX-License-Identifier: MIT
//
// Every case in DomainStoreContract runs here against the in-memory seam, with
// no Android API on the classpath. The instrumented SqliteDomainStoreTest runs
// the same cases against real SQLite.

package com.phonedsh.domain

import com.phonedsh.domain.testing.InMemoryConnectionFactory
import org.junit.runner.RunWith
import org.junit.runners.JUnit4

@RunWith(JUnit4::class)
class InMemoryDomainStoreTest : DomainStoreContract() {
    private val factory = InMemoryConnectionFactory()

    override fun connectionFactory(): ConnectionFactory = factory
}
