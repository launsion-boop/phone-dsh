// Provider page facts keep persisted next-launch choice separate from the active process.
// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.ProviderKeyStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostNavFactsProviderTest {
    @Test
    fun `an empty store without a launch route stays authoritatively empty`() {
        val facts = modelProviderFactsFrom(
            ProviderStoreRead.Empty,
            ProbeLaunchConfig(),
            FactState.NO,
        )
        assertTrue(facts.profiles?.isEmpty() == true)
        assertEquals(FactState.YES, facts.writable)
    }

    @Test
    fun `launch-derived local row appears only for a real endpoint and is active only while running`() {
        val launch = ProbeLaunchConfig(
            deepseekBaseUrl = "https://launch.example.test/v1",
            modelName = "launch-model",
            credentialAccount = null,
        )
        val stopped = modelProviderFactsFrom(ProviderStoreRead.Empty, launch, FactState.NO)
        val row = requireNotNull(stopped.profiles).single()
        assertEquals("launch-model", row.model)
        assertFalse(row.selected)
        assertNull(row.active)
        assertEquals(ProviderKeyStatus.NOT_CONFIGURED, row.key.status)
        val running = modelProviderFactsFrom(ProviderStoreRead.Empty, launch, FactState.YES)
        assertTrue(requireNotNull(running.profiles).single().active == true)
        assertFalse(requireNotNull(running.profiles).single().selected)
    }

    @Test
    fun `next-process selection does not replace the provider captured by a running engine`() {
        val active = ProviderRecord(
            id = "provider-a", name = "A", model = "model-a", endpoint = "https://a.example.test/v1",
            credentialRef = "provider.provider-a",
        )
        val next = ProviderRecord(
            id = "provider-b", name = "B", model = "model-b", endpoint = "https://b.example.test/v1",
            credentialRef = "provider.provider-b",
        )
        val snapshot = ProviderSnapshot(listOf(active, next), selectedId = next.id)
        val facts = modelProviderFactsFrom(
            ProviderStoreRead.Stored(next, snapshot),
            ProbeLaunchConfig(
                deepseekBaseUrl = active.endpoint,
                modelName = active.model,
                credentialAccount = active.credentialAccount(),
                providerProfileId = active.id,
            ),
            FactState.YES,
        )
        val rows = requireNotNull(facts.profiles).associateBy { it.id }
        assertFalse(requireNotNull(rows[active.id]).selected)
        assertTrue(rows[active.id]?.active == true)
        assertTrue(requireNotNull(rows[next.id]).selected)
        assertFalse(rows[next.id]?.active == true)
    }
}
