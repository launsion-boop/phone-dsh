// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import com.phonedsh.ui.nav.PdshHostAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/** The published 0.1.0 AAR descriptors used by existing compiled clients. */
class WebSearchAarCompatibilityTest {
    @Test fun existingWebSearchDescriptorsRemainAvailable() {
        val factsConstructor = WebSearchFacts::class.java.getConstructor(
            WebSearchMode::class.java, FactState::class.java, String::class.java,
            FactState::class.java, String::class.java, FactState::class.java,
            Boolean::class.javaPrimitiveType, WebSearchFailureReason::class.java,
            FactState::class.java, String::class.java,
        )
        val facts = factsConstructor.newInstance(WebSearchMode.SEARCH_API, FactState.NO, null,
            FactState.NO, null, FactState.NO, false, null, FactState.YES, null)
        assertEquals(FactState.NO, WebSearchFacts::class.java.getMethod("component2").invoke(facts))

        val screenConstructor = WebSearchScreenState::class.java.getConstructor(
            SettingsDataPhase::class.java, WebSearchMode::class.java, String::class.java,
            String::class.java, FactState::class.java, String::class.java, String::class.java,
            FactState::class.java, String::class.java, Boolean::class.javaPrimitiveType,
            Boolean::class.javaPrimitiveType, String::class.java, String::class.java,
        )
        val state = screenConstructor.newInstance(SettingsDataPhase.READY, WebSearchMode.SEARCH_API,
            "hint", "key", FactState.NO, null, "restart", FactState.NO, null, true, true, null, null)
        assertEquals(WebSearchMode.SEARCH_API, WebSearchScreenState::class.java.getMethod("component2").invoke(state))
        assertEquals("fixture-key", PdshHostAction.CommitWebSearchKey::class.java
            .getConstructor(String::class.java).newInstance("fixture-key").key)

        val page = Class.forName("com.phonedsh.ui.page.WebSearchSettingsPageKt")
            .declaredMethods.singleOrNull { it.name == "WebSearchSettingsPage" }
        assertNotNull(page)
        assertEquals("kotlin.jvm.functions.Function1", requireNotNull(page).parameterTypes[9].name)
    }
}
