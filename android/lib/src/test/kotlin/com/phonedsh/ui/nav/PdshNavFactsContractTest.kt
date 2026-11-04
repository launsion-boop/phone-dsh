// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PdshNavFactsContractTest {
    @Test
    fun nullAndEmptyCollectionsRemainDifferentFacts() {
        val unread = PdshNavFacts()
        val readEmpty = PdshNavFacts(
            sessions = emptyList(),
            artifacts = emptyList(),
            licenses = emptyList(),
            providerOperations = emptyList(),
        )

        assertNull(unread.sessions)
        assertNull(unread.artifacts)
        assertNull(unread.licenses)
        assertNull(unread.providerOperations)
        assertEquals(emptyList<PdshSessionRecord>(), readEmpty.sessions)
        assertEquals(emptyList<PdshArtifactFact>(), readEmpty.artifacts)
        assertEquals(emptyList<PdshLicenseFact>(), readEmpty.licenses)
        assertEquals(emptyList<PdshProviderOperationFact>(), readEmpty.providerOperations)
    }

    @Test
    fun workspaceSelectionRetainsDailyDefaultUnassignedAndUnknown() {
        assertEquals(PdshWorkspaceSelection.DailyDefault, PdshNavFacts(
            workspaceSelection = PdshWorkspaceSelection.DailyDefault,
        ).workspaceSelection)
        assertEquals(PdshWorkspaceSelection.Unassigned, PdshNavFacts(
            workspaceSelection = PdshWorkspaceSelection.Unassigned,
        ).workspaceSelection)
        assertEquals(PdshWorkspaceSelection.Unknown, PdshNavFacts(
            workspaceSelection = PdshWorkspaceSelection.Unknown,
        ).workspaceSelection)
        assertNull(PdshNavFacts().workspaceSelection)
    }
}
