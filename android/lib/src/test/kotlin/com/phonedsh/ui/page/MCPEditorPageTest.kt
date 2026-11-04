// MCP editor: four states, in-place validation, and the draft never leaking.
// SPDX-License-Identifier: MIT
//
// The validation test drives the same contract the host must implement: the save
// tap applies `MCPEditorUiEvent.Submit`, the state re-projects, and every error
// is printed under its own field. A blank form that only closed the sheet would
// pass a weaker test; this one asserts the reason is on screen.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class MCPEditorPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val stored = MCPStoredServer(
        id = "s1",
        name = "files",
        transport = MCPTransport.HTTP,
        enabled = true,
        commandStored = FactState.NO,
        urlStored = FactState.YES,
    )

    /** The test harness: callbacks apply the matching local event and re-project. */
    private fun show(
        facts: MCPEditorFacts,
        onSubmit: (MCPServerDraft) -> Unit = {},
        onDelete: (() -> Unit)? = null,
    ) {
        compose.setContent {
            var local by remember { mutableStateOf(MCPEditorLocalState()) }
            PdshTheme {
                MCPEditorPage(
                    state = MCPEditorScreenState.from(facts, local),
                    onEditName = { local = local.apply(MCPEditorUiEvent.EditName(it), facts) },
                    onEditCommand = { local = local.apply(MCPEditorUiEvent.EditCommand(it), facts) },
                    onEditUrl = { local = local.apply(MCPEditorUiEvent.EditUrl(it), facts) },
                    onEditTimeout = {
                        local = local.apply(MCPEditorUiEvent.EditTimeout(it), facts)
                    },
                    onSelectTransport = {
                        local = local.apply(MCPEditorUiEvent.SelectTransport(it), facts)
                    },
                    onToggleEnabled = {
                        local = local.apply(MCPEditorUiEvent.ToggleEnabled(it), facts)
                    },
                    onAddHeader = { local = local.apply(MCPEditorUiEvent.AddHeader, facts) },
                    onRemoveHeader = { index ->
                        local = local.apply(MCPEditorUiEvent.RemoveHeader(index), facts)
                    },
                    onEditHeaderName = { index, value ->
                        local = local.apply(MCPEditorUiEvent.EditHeaderName(index, value), facts)
                    },
                    onEditHeaderEnv = { index, value ->
                        local = local.apply(MCPEditorUiEvent.EditHeaderEnv(index, value), facts)
                    },
                    onEditHeaderValue = { index, value ->
                        local = local.apply(MCPEditorUiEvent.EditHeaderValue(index, value), facts)
                    },
                    onSubmit = { draft ->
                        local = local.apply(MCPEditorUiEvent.Submit, facts)
                        onSubmit(draft)
                    },
                    onDeleteServer = onDelete,
                    onBack = {},
                )
            }
        }
    }

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_LIST).performScrollToNode(hasTestTag(tag))
    }

    private fun clickSave() {
        scrollTo(UiPageTags.MCP_EDITOR_SAVE)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_SAVE).performClick()
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `a new server starts as an empty form with both transports offered`() {
        show(MCPEditorFacts())
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ROOT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EDITOR_NEW).assertIsDisplayed()
        scrollTo(UiPageTags.MCP_EDITOR_NAME)
        compose.onNodeWithText(UiStrings.MCP_FIELD_NAME_PLACEHOLDER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_FIELD_NAME_HINT).assertIsDisplayed()
        scrollTo(UiPageTags.MCP_EDITOR_URL)
        compose.onNodeWithText(UiStrings.MCP_FIELD_URL_PLACEHOLDER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_FIELD_URL_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_ENABLED_ON).assertIsDisplayed()
        // Nothing was submitted and nothing was typed: no error is shown yet.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME_ERROR).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ERRORS).assertDoesNotExist()
        scrollTo(UiPageTags.MCP_EDITOR_SAVE)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_SAVE).assertIsDisplayed()
    }

    @Test
    fun `an existing server prefills only the non-secret fields`() {
        show(
            MCPEditorFacts(
                server = stored.copy(transport = MCPTransport.STDIO, commandStored = FactState.YES),
            ),
        )
        compose.onNodeWithText(UiStrings.MCP_EDITOR_EDIT).assertIsDisplayed()
        scrollTo(UiPageTags.MCP_EDITOR_NAME)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME).assertTextContains("files")
        scrollTo(UiPageTags.MCP_EDITOR_COMMAND)
        compose.onNodeWithText(UiStrings.MCP_FIELD_COMMAND_PLACEHOLDER).assertIsDisplayed()
        // The stored-value note sits below the field: locate it before asserting.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_LIST)
            .performScrollToNode(hasText(UiStrings.MCP_EDITOR_KEEP_COMMAND))
        compose.onNodeWithText(UiStrings.MCP_EDITOR_KEEP_COMMAND).assertIsDisplayed()
        // The network field is not part of a stdio server.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL).assertDoesNotExist()
    }

    @Test
    fun `the transport choice swaps the field in place`() {
        show(MCPEditorFacts())
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_TRANSPORT_STDIO).performClick()
        scrollTo(UiPageTags.MCP_EDITOR_COMMAND)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_COMMAND).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_TRANSPORT_HTTP).performClick()
        scrollTo(UiPageTags.MCP_EDITOR_URL)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_COMMAND).assertDoesNotExist()
    }

    @Test
    fun `a failed save keeps the form on screen and 保存 is the retry`() {
        var submitted: MCPServerDraft? = null
        show(
            MCPEditorFacts(server = stored, failure = MCPEditorFailureReason.SAVE_FAILED),
            onSubmit = { submitted = it },
        )
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EDITOR_FAILURE_SAVE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME).assertIsDisplayed()
        // The baseline's error block (`MCPSettingsPage.swift:233`) has no retry of
        // its own: the save row below it is the one verb that re-submits.
        compose.onAllNodesWithText(UiStrings.RETRY).assertCountEquals(0)
        clickSave()
        assertEquals("files", submitted?.name)
    }

    // -------------------------------------------------------- baseline groups

    @Test
    fun `the two groups the baseline declares are the page's groups`() {
        show(MCPEditorFacts(server = stored))
        compose.onNodeWithText(UiStrings.MCP_SECTION_SERVER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_SERVER_SECTION).assertIsDisplayed()
        scrollTo(UiPageTags.MCP_EDITOR_AUTH_SECTION)
        compose.onNodeWithText(UiStrings.MCP_SECTION_AUTH).assertIsDisplayed()
        // 添加认证头 is the group's own verb, and the value-only footer explains
        // where the secret goes once there is a row to explain it for.
        scrollTo(UiPageTags.MCP_EDITOR_ADD_HEADER)
        compose.onNodeWithText(UiStrings.MCP_ACTION_ADD_HEADER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_AUTH_FOOTER).assertIsDisplayed()
    }

    @Test
    fun `enabling is a labelled row whose tap toggles the draft`() {
        show(MCPEditorFacts())
        scrollTo(UiPageTags.MCP_EDITOR_ENABLED)
        compose.onNodeWithText(UiStrings.MCP_ENABLED_ON).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ENABLED).performClick()
        compose.onNodeWithText(UiStrings.MCP_ENABLED_OFF).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ENABLED).performClick()
        compose.onNodeWithText(UiStrings.MCP_ENABLED_ON).assertIsDisplayed()
    }

    @Test
    fun `添加认证头 appends an editable header row and its glyph drops it again`() {
        val secret = "Bearer " + "tok" + "en"
        show(MCPEditorFacts())
        scrollTo(UiPageTags.MCP_EDITOR_ADD_HEADER)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ADD_HEADER).performClick()
        val nameTag = UiPageTags.MCP_EDITOR_HEADER_PREFIX + 0 + UiPageTags.MCP_EDITOR_HEADER_NAME_SUFFIX
        val valueTag = UiPageTags.MCP_EDITOR_HEADER_PREFIX + 0 + UiPageTags.MCP_EDITOR_HEADER_VALUE_SUFFIX
        val removeTag = UiPageTags.MCP_EDITOR_HEADER_PREFIX + 0 + UiPageTags.MCP_EDITOR_HEADER_REMOVE_SUFFIX
        scrollTo(nameTag)
        compose.onNodeWithTag(nameTag).performTextInput("Authorization")
        compose.onNodeWithTag(nameTag).assertTextContains("Authorization")
        scrollTo(valueTag)
        // A fresh row has nothing stored: it must not claim "a value is kept".
        compose.onAllNodesWithText(UiStrings.MCP_FIELD_HEADER_VALUE_STORED).assertCountEquals(0)
        compose.onNodeWithTag(valueTag).performTextInput(secret)
        // The old contract pinned the plaintext into the composed tree. A secret
        // field must mask both the drawing and the semantics, so the plaintext
        // is now a failure, not an expectation.
        compose.onAllNodesWithText(secret, substring = true).assertCountEquals(0)
        compose.onNodeWithTag(valueTag)
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Password))
        compose.onNodeWithTag(nameTag)
            .assert(SemanticsMatcher.keyNotDefined(SemanticsProperties.Password))
        scrollTo(removeTag)
        compose.onNodeWithTag(removeTag).performClick()
        compose.onNodeWithTag(nameTag).assertDoesNotExist()
    }

    @Test
    fun `a stored header row says keep and never shows the stored value`() {
        show(
            MCPEditorFacts(
                server = stored.copy(
                    headers = listOf(
                        MCPStoredHeader(
                            name = "Authorization",
                            envName = "MCP_FILES_TOKEN",
                            hasStoredValue = FactState.YES,
                        ),
                    ),
                ),
            ),
        )
        val nameTag = UiPageTags.MCP_EDITOR_HEADER_PREFIX + 0 + UiPageTags.MCP_EDITOR_HEADER_NAME_SUFFIX
        scrollTo(nameTag)
        compose.onNodeWithTag(nameTag).assertTextContains("Authorization")
        val valueTag = UiPageTags.MCP_EDITOR_HEADER_PREFIX + 0 + UiPageTags.MCP_EDITOR_HEADER_VALUE_SUFFIX
        scrollTo(valueTag)
        // "已保存；留空保持不变" instead of the fresh-row placeholder: the field is
        // blank and the page says what a blank field means.
        compose.onNodeWithText(UiStrings.MCP_FIELD_HEADER_VALUE_STORED).assertIsDisplayed()
        // The value itself never reaches the page: there is nothing to show.
        compose.onNodeWithTag(valueTag).assertTextContains("")
    }

    @Test
    fun `删除并撤销授权与密钥 only exists for a registered server`() {
        var deleted = 0
        show(MCPEditorFacts(server = stored), onDelete = { deleted += 1 })
        scrollTo(UiPageTags.MCP_EDITOR_DELETE)
        compose.onNodeWithText(UiStrings.MCP_ACTION_DELETE_SERVER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_DELETE_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_DELETE).performClick()
        assertEquals(1, deleted)
    }

    @Test
    fun `a new server has no delete row at all`() {
        show(MCPEditorFacts(), onDelete = {})
        // Nothing is registered yet, so a delete would be a verb with no object.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_DELETE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.MCP_ACTION_DELETE_SERVER).assertDoesNotExist()
    }

    @Test
    fun `a host without a delete renders the row disabled instead of a silent tap`() {
        show(MCPEditorFacts(server = stored))
        scrollTo(UiPageTags.MCP_EDITOR_DELETE)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_DELETE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_DELETE).assertIsNotEnabled()
    }

    @Test
    fun `the timeout field is seeded from the stored server and editable`() {
        show(MCPEditorFacts(server = stored.copy(toolCallTimeoutMs = "5000")))
        scrollTo(UiPageTags.MCP_EDITOR_TIMEOUT)
        // The stored timeout is not a secret, so the field starts with it.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_TIMEOUT).assertTextContains("5000")
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_TIMEOUT).performTextReplacement("3000")
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_TIMEOUT).assertTextContains("3000")
    }

    @Test
    fun `an unreadable target is the unknown state, not a blank editor`() {
        show(MCPEditorFacts(targetUnreadable = true))
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EDITOR_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EDITOR_UNKNOWN_HINT).assertIsDisplayed()
        // It is an edit of something we could not read, not a new server.
        compose.onNodeWithText(UiStrings.MCP_EDITOR_EDIT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_SAVE).assertDoesNotExist()
    }

    @Test
    fun `an unreadable stored URL says keep, and is not a validation error`() {
        show(MCPEditorFacts(server = stored.copy(urlStored = FactState.UNKNOWN)))
        // The note is below the field: locate it in the lazy list before asserting.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_LIST)
            .performScrollToNode(hasText(UiStrings.MCP_EDITOR_STORED_UNKNOWN))
        compose.onNodeWithText(UiStrings.MCP_EDITOR_STORED_UNKNOWN).assertIsDisplayed()
        // Unknown is not "the host cleared it": an empty field is still "keep".
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR).assertDoesNotExist()
    }

    // --------------------------------------------------------------- validation

    @Test
    fun `a save with a blank URL prints the reason under the URL field`() {
        show(MCPEditorFacts())
        clickSave()
        scrollTo(UiPageTags.MCP_EDITOR_URL_ERROR)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR)
            .assertTextEquals(UiStrings.MCP_ERR_URL_REQUIRED)
        // Both fields are blank: the summary counts both, in place.
        scrollTo(UiPageTags.MCP_EDITOR_ERRORS)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ERRORS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.MCP_EDITOR_ERRORS.format(2)).assertIsDisplayed()
    }

    @Test
    fun `an invalid name reports as soon as it is typed`() {
        show(MCPEditorFacts())
        scrollTo(UiPageTags.MCP_EDITOR_NAME)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME).performTextInput("bad name!")
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME_ERROR).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME_ERROR)
            .assertTextEquals(UiStrings.MCP_ERR_NAME_INVALID)
        // A touched field reports on its own; the save summary only appears on save.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ERRORS).assertDoesNotExist()
    }

    @Test
    fun `a new stdio server without a command reports the missing command`() {
        show(MCPEditorFacts())
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_TRANSPORT_STDIO).performClick()
        clickSave()
        scrollTo(UiPageTags.MCP_EDITOR_COMMAND_ERROR)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_COMMAND_ERROR)
            .assertTextEquals(UiStrings.MCP_ERR_COMMAND_REQUIRED)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR).assertDoesNotExist()
    }

    @Test
    fun `a valid draft is submitted with its draft and no errors`() {
        var submitted: MCPServerDraft? = null
        val endpoint = "http://" + "localhost" + ":3000"
        show(MCPEditorFacts(), onSubmit = { submitted = it })
        scrollTo(UiPageTags.MCP_EDITOR_NAME)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME).performTextInput("files")
        scrollTo(UiPageTags.MCP_EDITOR_URL)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL).performTextInput(endpoint)
        clickSave()
        assertNotNull(submitted)
        assertEquals("files", submitted?.name)
        assertEquals(endpoint, submitted?.url)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME_ERROR).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_ERRORS).assertDoesNotExist()
    }

    /**
     * The draft URL is only ever the user's own input field. Every page-authored
     * string is checked: no error message echoes the URL or its token, so an
     * invalid URL cannot turn a validation line into a leak.
     */
    @Test
    fun `the draft URL never appears in page-authored copy`() {
        val token = "abc" + "123" + "secret"
        val invalidUrl = "ftp://" + "mcp.example.com" + "/mcp" + "?token=" + token
        show(MCPEditorFacts())
        scrollTo(UiPageTags.MCP_EDITOR_NAME)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_NAME).performTextInput("files")
        scrollTo(UiPageTags.MCP_EDITOR_URL)
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL).performTextInput(invalidUrl)
        clickSave()
        scrollTo(UiPageTags.MCP_EDITOR_URL_ERROR)
        // The error is the page-owned rule text, never the value.
        compose.onNodeWithTag(UiPageTags.MCP_EDITOR_URL_ERROR)
            .assertTextEquals(UiStrings.MCP_ERR_URL_INVALID)

        val local = MCPEditorLocalState()
            .apply(MCPEditorUiEvent.EditName("files"), MCPEditorFacts())
            .apply(MCPEditorUiEvent.EditUrl(invalidUrl), MCPEditorFacts())
            .apply(MCPEditorUiEvent.Submit, MCPEditorFacts())
        val state = MCPEditorScreenState.from(MCPEditorFacts(), local)
        val authored = state.visibleErrors.map { it.message } +
            listOfNotNull(state.title, state.failure, state.commandStoredLabel, state.urlStoredLabel)
        assertTrue("the token leaked into page-authored copy", authored.none { it.contains(token) })
        assertTrue("the URL leaked into page-authored copy", authored.none { it.contains(invalidUrl) })
        assertFalse(state.errors.isEmpty())
    }

    // ------------------------------------------------------------------ purity

    @Test
    fun `the validation sequence is a pure function of the script`() {
        val facts = MCPEditorFacts()
        val script = listOf(
            MCPEditorUiEvent.Submit,
            MCPEditorUiEvent.EditName("files"),
            MCPEditorUiEvent.SelectTransport(MCPTransport.STDIO),
            MCPEditorUiEvent.EditCommand(""),
            MCPEditorUiEvent.Submit,
            MCPEditorUiEvent.EditCommand("run --serve"),
            MCPEditorUiEvent.ToggleEnabled(false),
        )
        var local = MCPEditorLocalState()
        val states = buildList {
            add(MCPEditorScreenState.from(facts, local))
            script.forEach { event ->
                local = local.apply(event, facts)
                add(MCPEditorScreenState.from(facts, local))
            }
        }
        // Before save nothing is visible; save reveals both errors; fixing the
        // name leaves the URL; the transport swap validates the command instead.
        assertEquals(
            listOf(
                emptyList<MCPField>(),
                listOf(MCPField.NAME, MCPField.URL),
                listOf(MCPField.URL),
                listOf(MCPField.COMMAND),
                listOf(MCPField.COMMAND),
                listOf(MCPField.COMMAND),
                emptyList<MCPField>(),
                emptyList<MCPField>(),
            ),
            states.map { state -> state.visibleErrors.map { it.field } },
        )
        assertTrue(states.last().errors.isEmpty())
        assertEquals("run --serve", states.last().draft.command)
        assertFalse(states.last().draft.enabled)
        assertEquals(SettingsDataPhase.READY, states.last().phase)

        var replay = MCPEditorLocalState()
        val replayed = buildList {
            add(MCPEditorScreenState.from(facts, replay))
            script.forEach { event ->
                replay = replay.apply(event, facts)
                add(MCPEditorScreenState.from(facts, replay))
            }
        }
        assertEquals(states, replayed)
    }

    @Test
    fun `the validation helpers keep a stored value valid and reject credentials in a URL`() {
        val blankUrl = MCPServerDraft(name = "files", transport = MCPTransport.HTTP, url = "")
        assertEquals(listOf(MCPField.URL), validateServerDraft(blankUrl).map { it.field })
        // Editing an existing server: blank means keep, and that is valid.
        assertTrue(validateServerDraft(blankUrl, storedUrl = FactState.YES).isEmpty())
        assertTrue(validateServerDraft(blankUrl, storedUrl = FactState.UNKNOWN).isEmpty())
        assertTrue(
            validateServerDraft(
                MCPServerDraft(name = "files", transport = MCPTransport.STDIO, command = ""),
                storedCommand = FactState.YES,
            ).isEmpty(),
        )
        // A host that says nothing is stored makes the blank field an error.
        assertEquals(
            listOf(MCPField.COMMAND),
            validateServerDraft(
                MCPServerDraft(name = "files", transport = MCPTransport.STDIO, command = ""),
                storedCommand = FactState.NO,
            ).map { it.field },
        )

        val endpoint = "https://" + "mcp.example.com" + "/mcp"
        assertTrue(isValidHttpUrl(endpoint))
        assertTrue(isValidHttpUrl("http://" + "localhost" + ":3000"))
        assertFalse(isValidHttpUrl("ftp://" + "mcp.example.com"))
        assertFalse(isValidHttpUrl(""))
        assertFalse(isValidHttpUrl("http://"))
        assertFalse(isValidHttpUrl("http://" + "mcp.example.com" + " with space"))
        assertFalse(isValidHttpUrl("https://" + "user:pw@" + "mcp.example.com"))

        val credentials = "https://" + "user:pw@" + "mcp.example.com" + "/mcp"
        assertEquals(
            listOf(UiStrings.MCP_ERR_URL_CREDENTIALS),
            validateServerDraft(
                MCPServerDraft(name = "files", transport = MCPTransport.HTTP, url = credentials),
            ).map { it.message },
        )
        // The stored-URL fact is UNKNOWN, so a blank field is "keep", not an error.
        assertNull(
            MCPEditorScreenState
                .from(MCPEditorFacts(server = stored.copy(urlStored = FactState.UNKNOWN)))
                .errors
                .firstOrNull { it.field == MCPField.URL },
        )
    }
}
