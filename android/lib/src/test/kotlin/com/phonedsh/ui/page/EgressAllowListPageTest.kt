// EgressAllowListPage: the four states and the baseline's six editing controls.
// SPDX-License-Identifier: MIT
//
// The deny-all test is the semantic guard this page exists for: an empty rule
// table is the effective policy "deny every host", not an empty list. It asserts
// both sides — the policy copy is on screen and the ordinary empty-state tag is
// not — because either assertion alone could pass for the wrong reason.
//
// The editing tests pin the two halves of the write contract this page follows:
// the baseline's actions and labels are always on screen (that is what the page
// contract names), and the page never mutates the rule list itself — the switch,
// the restore, 添加 and 删除 only call the host, and a host that did not declare a
// write command sees the same controls disabled with the host's reason.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class EgressAllowListPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun rulesFacts(): EgressAllowListFacts = EgressAllowListFacts(
        rules = listOf(
            EgressRule(id = "r1", host = "api.deepseek.com", scheme = "https"),
            EgressRule(id = "r2", host = "*.example.com", scheme = "https", port = 8443),
            EgressRule(id = "r3", host = "127.0.0.1", port = 7861),
            EgressRule(id = "r4", host = "*"),
        ),
    )

    /** Three named hosts and no `*`: the page may add to this list. */
    private fun hostsFacts(writable: FactState = FactState.YES): EgressAllowListFacts =
        EgressAllowListFacts(
            rules = listOf(
                EgressRule(id = "r1", host = "api.deepseek.com", scheme = "https"),
                EgressRule(id = "r2", host = "*.example.com", scheme = "https", port = 8443),
                EgressRule(id = "r3", host = "127.0.0.1", port = 7861),
            ),
            writable = writable,
        )

    private fun show(
        state: EgressAllowListScreenState,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
        onToggleAllowAll: ((Boolean) -> Unit)? = null,
        onRestoreDefaults: (() -> Unit)? = null,
        onAddRule: ((String) -> Unit)? = null,
        onRemoveRule: ((EgressRuleView) -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                EgressAllowListPage(
                    state = state,
                    onBack = {},
                    onToggleSection = {},
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                    onToggleAllowAll = onToggleAllowAll,
                    onRestoreDefaults = onRestoreDefaults,
                    onAddRule = onAddRule,
                    onRemoveRule = onRemoveRule,
                )
            }
        }
    }

    /** A host that applies the fold events, so the sequence moves the UI. */
    private fun showLive(
        facts: EgressAllowListFacts,
        initial: EgressAllowListLocalState = EgressAllowListLocalState(),
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(initial) }
            PdshTheme {
                EgressAllowListPage(
                    state = EgressAllowListScreenState.from(facts, local),
                    onBack = {},
                    onToggleSection = { id ->
                        local = local.apply(EgressAllowListUiEvent.ToggleSection(id))
                    },
                )
            }
        }
    }

    @Test
    fun `an empty rule table is 全部拒绝, not an ordinary empty list`() {
        val facts = EgressAllowListFacts(rules = emptyList())
        val state = EgressAllowListScreenState.from(facts)
        assertEquals(EgressStatus.DENY_ALL, state.status)
        assertTrue(state.denyAll)
        assertFalse(state.isUnknown)
        assertFalse(state.isFailed)
        assertEquals(0, state.ruleCount)
        assertTrue(state.rules.isEmpty())
        assertFalse(state.allowAll)
        show(state)

        // The policy is stated, in words and as an addressable row.
        compose.onNodeWithTag(UiPageTags.EGRESS_DENY_ALL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_POLICY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_DENY_ALL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_DENY_ALL_HINT).assertIsDisplayed()

        // It is not an empty state and not an unknown read.
        compose.onNodeWithTag(UiPageTags.EGRESS_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.EGRESS_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_UNKNOWN_STATE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_UNKNOWN_HINT).assertDoesNotExist()

        // It is also not a normal rule list: no rule row and no "0 个地址" claim.
        compose.onNodeWithTag(UiPageTags.EGRESS_RULE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_RULE_COUNT.format(0)).assertDoesNotExist()

        // The syntax section still explains the empty-table semantics below.
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST)
            .performScrollToNode(hasText(UiStrings.EGRESS_GRAMMAR_EMPTY))
        compose.onNodeWithText(UiStrings.EGRESS_GRAMMAR_EMPTY).assertIsDisplayed()
    }

    @Test
    fun `rules render their matching form, label and scope`() {
        val facts = rulesFacts()
        val state = EgressAllowListScreenState.from(facts)
        assertEquals(EgressStatus.READY, state.status)
        assertEquals(4, state.ruleCount)
        assertTrue(state.allowAll)
        show(state)

        compose.onNodeWithText("https://api.deepseek.com").assertIsDisplayed()
        compose.onNodeWithText("https://*.example.com:8443").assertIsDisplayed()
        compose.onNodeWithText("127.0.0.1:7861").assertIsDisplayed()
        compose.onNodeWithText("*").assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.EGRESS_FORM_EXACT).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.EGRESS_FORM_WILDCARD).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_FORM_ANY).assertIsDisplayed()
        // Under the allow-all switch the baseline replaces the count with its own
        // caption (`NativeShell.swift:527`-`:532`).
        compose.onNodeWithText(UiStrings.EGRESS_INACTIVE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_DETAIL_WILDCARD, substring = true).assertIsDisplayed()
        // The bare host and the `*` rule both say the scheme is unrestricted.
        compose.onAllNodesWithText(UiStrings.EGRESS_DETAIL_ANY_SCHEME, substring = true)
            .assertCountEquals(2)

        // A bare `*` is the allow-all pole and gets its own policy callout.
        compose.onNodeWithTag(UiPageTags.EGRESS_ALLOW_ALL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_ALLOW_ALL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_ALLOW_ALL_HINT).assertIsDisplayed()

        // The rules came from a host that did not declare a write command: the
        // page says so instead of offering a button that cannot save anything.
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.EGRESS_READ_ONLY))
        compose.onNodeWithText(UiStrings.HOST_READ_ONLY_HINT).assertIsDisplayed()
    }

    @Test
    fun `the baseline's editing controls are on screen and disabled when the host cannot write`() {
        val state = EgressAllowListScreenState.from(hostsFacts(writable = FactState.NO))
        assertFalse(state.canWrite)
        show(state)

        // `NativeShell.swift:466` / `:470`: the untitled first section.
        compose.onNodeWithText(UiStrings.EGRESS_ALLOW_ALL_TOGGLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_ALLOW_ALL_TOGGLE + ".switch").assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.EGRESS_ALLOW_ALL_FOOTER).assertIsDisplayed()

        // The host's own answer, visible before the tap.
        compose.onNodeWithTag(UiPageTags.EGRESS_READ_ONLY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.HOST_READ_ONLY_HINT).assertIsDisplayed()

        // `:512` and `:496`: the add row and the per-row delete affordance exist
        // and are disabled, not hidden — the baseline's structure is still here.
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.EGRESS_ADD))
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD).assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.EGRESS_ADD_ADDRESS).assertIsDisplayed()
        // Opening the confirmation is interaction, not a write: the dialog stays
        // reachable and its verb is what the host's answer disables.
        compose.onAllNodesWithTag(UiPageTags.EGRESS_RULE_DELETE)[0].performClick()
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_DIALOG).assertIsDisplayed()
        // The page's line and the dialog's copy: the reason travels with the verb.
        compose.onAllNodesWithText(UiStrings.HOST_READ_ONLY_HINT).assertCountEquals(2)
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_CONFIRM).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_CANCEL).performClick()
    }

    @Test
    fun `a writable host receives the toggle, add and remove callbacks`() {
        val toggled = mutableListOf<Boolean>()
        val added = mutableListOf<String>()
        val removed = mutableListOf<EgressRuleView>()
        val state = EgressAllowListScreenState.from(hostsFacts())
        assertTrue(state.canWrite)
        show(
            state,
            onToggleAllowAll = { toggled += it },
            onAddRule = { added += it },
            onRemoveRule = { removed += it },
        )

        // 允许连任何网站: the switch reports the request; the page never flips the
        // host's value itself (the facts still say "off").
        compose.onNodeWithTag(UiPageTags.EGRESS_ALLOW_ALL_TOGGLE + ".switch").performClick()
        assertEquals(listOf(true), toggled)
        compose.onNodeWithTag(UiPageTags.EGRESS_ALLOW_ALL_TOGGLE + ".switch").assertIsOff()

        // 添加地址 (`:512`) opens the overlay; 添加 (`:670`) hands the trimmed,
        // lower-cased value to the host and closes the overlay.
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.EGRESS_ADD))
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD).performClick()
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_OVERLAY).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_FIELD).performTextInput("  API.Example.com ")
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_CONFIRM).performClick()
        assertEquals(listOf("api.example.com"), added)
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_OVERLAY).assertDoesNotExist()

        // 删除这个地址 (`:496`): the row's affordance asks first, 取消 writes
        // nothing, the confirmation hands the row to the host.
        compose.onAllNodesWithTag(UiPageTags.EGRESS_RULE_DELETE)[0].performClick()
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_DIALOG).assertIsDisplayed()
        compose.onNode(isDialog()).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_DELETE_CONFIRM).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_DELETE_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_CANCEL).performClick()
        assertTrue(removed.isEmpty())
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_DIALOG).assertDoesNotExist()

        compose.onAllNodesWithTag(UiPageTags.EGRESS_RULE_DELETE)[0].performClick()
        compose.onNodeWithText(UiStrings.EGRESS_DELETE_ADDRESS).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_DELETE_CONFIRM).performClick()
        assertEquals(listOf("r1"), removed.map { it.id })
    }

    @Test
    fun `a writable host can restore the empty list to the defaults`() {
        var restored = 0
        val state = EgressAllowListScreenState.from(
            EgressAllowListFacts(rules = emptyList(), writable = FactState.YES),
        )
        assertTrue(state.canWrite)
        show(state, onRestoreDefaults = { restored += 1 })

        // `:482`: the empty table keeps the 恢复成默认的 escape hatch.
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.EGRESS_RESTORE))
        compose.onNodeWithTag(UiPageTags.EGRESS_RESTORE).performClick()
        assertEquals(1, restored)
    }

    @Test
    fun `an address that is not a bare host is refused before the host is called`() {
        val added = mutableListOf<String>()
        val state = EgressAllowListScreenState.from(hostsFacts())
        show(state, onAddRule = { added += it })
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.EGRESS_ADD))
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD).performClick()

        // `NativeShell.swift:678`-`:681`: a scheme, a path or a space is not a host.
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_FIELD).performTextInput("https://api.example.com")
        compose.onNodeWithText(UiStrings.EGRESS_ADD_PROBLEM).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_CONFIRM).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_CONFIRM).performClick()
        assertTrue(added.isEmpty())

        // A host already in the list is refused with its own sentence.
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_FIELD).performTextClearance()
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_FIELD).performTextInput("API.deepseek.com")
        compose.onNodeWithText(UiStrings.EGRESS_ADD_DUPLICATE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_ADD_CONFIRM).assertIsNotEnabled()
        assertTrue(added.isEmpty())
    }

    @Test
    fun `entry validation is pure and matches the baseline's host rule`() {
        assertEquals("api.example.com", egressEntryValue("  API.Example.COM  "))
        assertNull(validateEgressEntry("api.example.com", emptyList()))
        assertNull(validateEgressEntry("api.example.com", listOf("other.example.com")))
        assertEquals(
            EgressRuleProblem.NOT_A_HOST,
            validateEgressEntry("http://api.example.com", emptyList()),
        )
        assertEquals(EgressRuleProblem.NOT_A_HOST, validateEgressEntry("api.example.com/x", emptyList()))
        assertEquals(EgressRuleProblem.NOT_A_HOST, validateEgressEntry("api.example.com:8443", emptyList()))
        assertEquals(EgressRuleProblem.NOT_A_HOST, validateEgressEntry("user@api.example.com", emptyList()))
        assertEquals(EgressRuleProblem.NOT_A_HOST, validateEgressEntry("api example.com", emptyList()))
        assertEquals(EgressRuleProblem.NOT_A_HOST, validateEgressEntry("   ", emptyList()))
        assertEquals(
            EgressRuleProblem.DUPLICATE,
            validateEgressEntry(" API.deepseek.com ", listOf("api.deepseek.com")),
        )
        assertEquals(
            UiStrings.EGRESS_ADD_PROBLEM,
            egressRuleProblemText(EgressRuleProblem.NOT_A_HOST),
        )
        assertEquals(
            UiStrings.EGRESS_ADD_DUPLICATE,
            egressRuleProblemText(EgressRuleProblem.DUPLICATE),
        )
    }

    @Test
    fun `a failed read never claims deny-all`() {
        val state = EgressAllowListScreenState.from(
            EgressAllowListFacts(failure = "读取超时"),
        )
        assertEquals(EgressStatus.FAILED, state.status)
        assertTrue(state.isFailed)
        assertTrue(state.rules.isEmpty())
        assertNull(state.ruleCount)
        assertFalse(state.denyAll)
        var retried = 0
        var dismissed = 0
        show(
            state,
            onRetry = { retried += 1 },
            onDismissFailure = { dismissed += 1 },
        )
        compose.onNodeWithTag(UiPageTags.EGRESS_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_FAILED).assertIsDisplayed()
        compose.onNodeWithText("读取超时").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_DENY_ALL).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_DENY_ALL).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
        compose.onNodeWithText(UiStrings.DISMISS).performClick()
        assertEquals(1, dismissed)
    }

    @Test
    fun `an unreported list is unknown, not deny-all`() {
        val state = EgressAllowListScreenState.from(EgressAllowListFacts(rules = null))
        assertEquals(EgressStatus.UNKNOWN, state.status)
        assertTrue(state.isUnknown)
        assertFalse(state.denyAll)
        assertNull(state.ruleCount)
        show(state)
        compose.onNodeWithTag(UiPageTags.EGRESS_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.EGRESS_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_DENY_ALL).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_DENY_ALL).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.EGRESS_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.EGRESS_LIST).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_RULE_COUNT.format(0)).assertDoesNotExist()
    }

    @Test
    fun `the fold sequence is pure and never changes the effective policy`() {
        val facts = rulesFacts()
        val script = listOf(
            EgressAllowListUiEvent.ToggleSection(EgressAllowListScreenState.GRAMMAR_SECTION_ID),
            EgressAllowListUiEvent.ToggleSection(EgressAllowListScreenState.RULES_SECTION_ID),
            EgressAllowListUiEvent.ToggleSection(EgressAllowListScreenState.RULES_SECTION_ID),
            EgressAllowListUiEvent.ToggleSection(EgressAllowListScreenState.GRAMMAR_SECTION_ID),
        )

        fun run(source: EgressAllowListFacts): List<EgressAllowListScreenState> {
            var local = EgressAllowListLocalState()
            return buildList {
                add(EgressAllowListScreenState.from(source, local))
                script.forEach { event ->
                    local = local.apply(event)
                    add(EgressAllowListScreenState.from(source, local))
                }
            }
        }

        val states = run(facts)
        assertEquals(
            listOf(true, false, false, false, true),
            states.map { it.grammarExpanded },
        )
        assertEquals(
            listOf(true, true, false, true, true),
            states.map { it.rulesExpanded },
        )
        assertTrue(states.all { it.status == EgressStatus.READY })
        assertTrue(states.all { it.rules.size == 4 })
        assertEquals(states.map { it.signature() }, run(facts).map { it.signature() })

        // The empty table is deny-all under every fold point, and a fold can never
        // turn it into a READY list or an UNKNOWN read.
        val emptyStates = run(EgressAllowListFacts(rules = emptyList()))
        assertTrue(emptyStates.all { it.status == EgressStatus.DENY_ALL })
        assertTrue(emptyStates.all { it.denyAll })
        assertTrue(emptyStates.all { it.ruleCount == 0 })
        assertTrue(emptyStates.all { !it.allowAll })
        // A fold cannot change whether the host can write either.
        assertTrue(emptyStates.all { !it.canWrite })
    }

    @Test
    fun `folding the rules hides the rows but keeps their count`() {
        showLive(hostsFacts())
        compose.onNodeWithText("https://api.deepseek.com").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_RULES_SECTION).performClick()
        compose.onNodeWithText("https://api.deepseek.com").assertDoesNotExist()
        compose.onNodeWithText(UiStrings.EGRESS_RULE_COUNT.format(3)).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.EGRESS_RULES_SECTION).performClick()
        compose.onNodeWithText("https://api.deepseek.com").assertIsDisplayed()
    }
}
