// GitHub Agent: the one write-capable GitHub credential this phone holds.
// SPDX-License-Identifier: MIT
//
// Contract: `spec/ui/v1/pages/git-hub-agent-settings.json` (the iOS baseline's
// `GitHubAgentSettingsPage.swift`). The Discover connector keeps its own
// read-only record; this token is deliberately separate because it can commit,
// create branches and open pull requests.
//
// The page is projection only. It never reads the secret store and never keeps
// the typed token beyond the save call: the host's `:app`
// `GitHubAgentSettingsStore` owns the Android Keystore record and the separate
// SharedPreferences write opt-in. The Worker only ever sees the two non-secret
// `PDSH_GITHUB_AUTH` / `PDSH_GITHUB_WRITE` facts, never this value.
package com.phonedsh.ui.page

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SecretVisualTransformation
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.SettingsSwitch
import com.phonedsh.ui.surface.secretInputSemantics
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens

/**
 * The host's GitHub agent facts.
 *
 * [hasToken] is true only when the stored record exists and is readable. A
 * record that cannot be read is reported as false, exactly as the iOS page's
 * `reload()` does, so the page never claims a credential it cannot inject.
 */
@Immutable
public data class GitHubAgentFacts(
    public val hasToken: Boolean = false,
    public val allowWrites: Boolean = false,
)

/**
 * The contract's three sections plus the restart affordance.
 *
 * @param onSaveToken stores the trimmed, single-line token and returns whether
 *   the write landed. The value is only held for the duration of this call.
 * @param onDeleteToken removes the stored record and returns whether it landed.
 * @param onAllowWritesChange persists the explicit write opt-in.
 * @param onRestartEngine restarts the local engine so the next page load reads
 *   the new `PDSH_GITHUB_AUTH` / `PDSH_GITHUB_WRITE` decision.
 */
@Composable
public fun GitHubAgentSettingsPage(
    facts: GitHubAgentFacts,
    onBack: () -> Unit,
    onSaveToken: (String) -> Boolean,
    onDeleteToken: () -> Boolean,
    onAllowWritesChange: (Boolean) -> Unit,
    onRestartEngine: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var token by remember { mutableStateOf("") }
    var hasToken by remember { mutableStateOf(facts.hasToken) }
    var allowWrites by remember { mutableStateOf(facts.allowWrites) }
    var message by remember { mutableStateOf<String?>(null) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    LaunchedEffect(facts.hasToken) { hasToken = facts.hasToken }
    LaunchedEffect(facts.allowWrites) { allowWrites = facts.allowWrites }

    val tokenDraft = token.trim()
    val saveEnabled = tokenDraft.isNotEmpty() && !saving

    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = UiStrings.GITHUB_AGENT_TITLE,
        onBack = onBack,
        rootTag = UiPageTags.GITHUB_AGENT_ROOT,
        modifier = modifier,
    ) {
        LazyColumn(modifier = Modifier.fillMaxSize().testTag(UiPageTags.GITHUB_AGENT_LIST)) {
            item(key = "token.header") {
                SettingsSectionLabel(UiStrings.GITHUB_AGENT_TOKEN_SECTION)
            }
            item(key = "token.input") {
                TokenField(
                    value = token,
                    onValueChange = { token = it },
                )
            }
            item(key = "token.save") {
                InfoRow(
                    title = UiStrings.GITHUB_AGENT_TOKEN_SAVE,
                    value = null,
                    enabled = saveEnabled,
                    modifier = Modifier.testTag(UiPageTags.GITHUB_AGENT_SAVE),
                    onClick = {
                        val value = token.trim()
                        if (value.isEmpty() || value.any { it == '\n' || it == '\r' }) {
                            errorText = UiStrings.GITHUB_AGENT_INVALID_TOKEN
                        } else {
                            saving = true
                            val saved = try {
                                onSaveToken(value)
                            } finally {
                                saving = false
                            }
                            if (saved) {
                                token = ""
                                hasToken = true
                                errorText = null
                                message = UiStrings.GITHUB_AGENT_SAVED
                            } else {
                                errorText = UiStrings.GITHUB_AGENT_WRITE_FAILED
                            }
                        }
                    },
                )
            }
            if (hasToken) {
                item(key = "token.delete") {
                    InfoRow(
                        title = UiStrings.GITHUB_AGENT_TOKEN_DELETE,
                        value = null,
                        modifier = Modifier.testTag(UiPageTags.GITHUB_AGENT_DELETE),
                        onClick = {
                            if (onDeleteToken()) {
                                hasToken = false
                                errorText = null
                                message = UiStrings.GITHUB_AGENT_DELETED
                            } else {
                                errorText = UiStrings.GITHUB_AGENT_DELETE_FAILED
                            }
                        },
                    )
                }
            }
            item(key = "token.footer") {
                SettingsFootnoteRow(text = UiStrings.GITHUB_AGENT_TOKEN_FOOTER)
            }
            item(key = "writes.toggle") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.GITHUB_AGENT_ALLOW_WRITES)
                        .clickable(role = Role.Switch) {
                            val next = !allowWrites
                            allowWrites = next
                            onAllowWritesChange(next)
                            message = UiStrings.GITHUB_AGENT_RESTART_REQUIRED
                        }
                        .heightIn(min = LocalUiTokens.current.geometry.pageRowMinHeight)
                        .padding(
                            start = LocalUiTokens.current.geometry.pageOuterMarginH,
                            end = LocalUiTokens.current.geometry.pageOuterMarginH,
                            top = LocalUiTokens.current.spacing.iconText,
                            bottom = LocalUiTokens.current.spacing.iconText,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicText(
                        text = UiStrings.GITHUB_AGENT_ALLOW_WRITES,
                        modifier = Modifier.weight(1f),
                        style = settingsValueStyle().copy(color = LocalUiTokens.current.colors.primary),
                    )
                    SettingsSwitch(checked = allowWrites)
                }
            }
            item(key = "writes.footer") {
                SettingsFootnoteRow(text = UiStrings.GITHUB_AGENT_ALLOW_WRITES_FOOTER)
            }
            item(key = "restart.action") {
                InfoRow(
                    title = UiStrings.GITHUB_AGENT_RESTART,
                    value = null,
                    modifier = Modifier.testTag(UiPageTags.GITHUB_AGENT_RESTART),
                    onClick = onRestartEngine,
                )
            }
            message?.let { text ->
                item(key = "restart.message") {
                    Column(modifier = Modifier.testTag(UiPageTags.GITHUB_AGENT_MESSAGE)) {
                        SettingsFootnoteRow(text = text)
                    }
                }
            }
            errorText?.let { text ->
                item(key = "restart.error") {
                    Column(modifier = Modifier.testTag(UiPageTags.GITHUB_AGENT_ERROR)) {
                        SettingsFootnoteRow(text = text)
                    }
                }
            }
        }
    }
}

/** The masked fine-grained-token input; the value never leaves this composition. */
@Composable
private fun TokenField(value: String, onValueChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            imeAction = ImeAction.Done,
        ),
        visualTransformation = SecretVisualTransformation,
        textStyle = settingsValueStyle().copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.GITHUB_AGENT_TOKEN_FIELD)
            .secretInputSemantics()
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        decorationBox = { inner ->
            if (value.isEmpty()) {
                BasicText(
                    text = UiStrings.GITHUB_AGENT_TOKEN_PLACEHOLDER,
                    style = settingsValueStyle().copy(color = tokens.colors.tertiary),
                )
            }
            inner()
        },
    )
}
