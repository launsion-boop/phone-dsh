// Accessibility semantics for spec/ui/v1/interaction.md §7 and
// PC-20261112-ui-round3 R4: a disclosure's clickable header announces its state.
// SPDX-License-Identifier: MIT
//
// Drives the real `PdshDisclosure`/`PdshFolderGroup` composables (not a copy of
// their semantics) and toggles them through the same header a pointer taps. The
// default announcement must exist without the caller supplying anything, because
// iOS's `DisclosureGroup` supplies it for free and Android's custom rows must not
// regress to silence. The motion tests in `PdshDisclosureMotionTest` are left
// untouched.
package com.phonedsh.ui.disclosure

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshDisclosureSemanticsTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `body header announces collapsed and expanded before the caller passes anything`() {
        mountBody()
        val header = compose.onNodeWithTag(PdshDisclosureTags.header(TAG))

        header.assert(stateIs(UiStrings.COLLAPSED))
        compose.onNodeWithTag(PdshDisclosureTags.body(TAG)).assertDoesNotExist()

        header.performClick()
        compose.waitForIdle()

        header.assert(stateIs(UiStrings.EXPANDED))
        compose.onNodeWithTag(PdshDisclosureTags.body(TAG)).assertExists()

        header.performClick()
        compose.waitForIdle()

        header.assert(stateIs(UiStrings.COLLAPSED))
        compose.onNodeWithTag(PdshDisclosureTags.body(TAG)).assertDoesNotExist()
    }

    @Test
    fun `folder header announces collapsed and expanded too`() {
        mountFolder()
        val header = compose.onNodeWithTag(PdshDisclosureTags.header(TAG))

        header.assert(stateIs(UiStrings.COLLAPSED))
        header.performClick()
        compose.waitForIdle()
        header.assert(stateIs(UiStrings.EXPANDED))
        header.performClick()
        compose.waitForIdle()
        header.assert(stateIs(UiStrings.COLLAPSED))
    }

    @Test
    fun `caller can override the state description and supply an action label`() {
        mountBodyWithSemantics(stateDescription = CUSTOM_STATE, onClickLabel = CUSTOM_ACTION)
        val header = compose.onNodeWithTag(PdshDisclosureTags.header(TAG))

        header.assert(stateIs(CUSTOM_STATE))
        header.assert(SemanticsMatcher("has the caller's click action label") { node ->
            node.config.getOrNull(SemanticsActions.OnClick)?.label == CUSTOM_ACTION
        })
        header.performClick()
        compose.waitForIdle()

        // The override is fixed copy; toggling changes only the visible body.
        header.assert(stateIs(CUSTOM_STATE))
        compose.onNodeWithTag(PdshDisclosureTags.body(TAG)).assertExists()
    }

    @Test
    fun `null state description suppresses the announcement`() {
        mountBodyWithSemantics(stateDescription = null)
        val header = compose.onNodeWithTag(PdshDisclosureTags.header(TAG))

        header.assert(
            SemanticsMatcher("has no state description") { node ->
                node.config.getOrNull(SemanticsProperties.StateDescription) == null
            },
        )
    }

    /** Mounts the component with the header's default announcement and action label. */
    private fun mountBody() {
        compose.setContent {
            var expanded by remember { mutableStateOf(false) }
            PdshTheme {
                PdshDisclosure(
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    tag = TAG,
                    header = { headerContent("header") },
                    body = { bodyContent() },
                )
            }
        }
    }

    /** Mounts the component with the caller's explicit announcement/action overrides. */
    private fun mountBodyWithSemantics(
        stateDescription: String?,
        onClickLabel: String? = null,
    ) {
        compose.setContent {
            var expanded by remember { mutableStateOf(false) }
            PdshTheme {
                PdshDisclosure(
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    tag = TAG,
                    stateDescription = stateDescription,
                    onClickLabel = onClickLabel,
                    header = { headerContent("header") },
                    body = { bodyContent() },
                )
            }
        }
    }

    private fun mountFolder() {
        compose.setContent {
            var expanded by remember { mutableStateOf(false) }
            PdshTheme {
                PdshFolderGroup(
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    tag = TAG,
                    header = {
                        Box(modifier = Modifier.fillMaxWidth().height(ROW_HEIGHT_DP.dp)) {
                            PdshChevron(expanded = expanded)
                            Text("folder")
                        }
                    },
                    body = { bodyContent() },
                )
            }
        }
    }

    @Composable
    private fun headerContent(text: String) {
        Box(modifier = Modifier.fillMaxWidth().height(ROW_HEIGHT_DP.dp)) {
            Text(text)
        }
    }

    @Composable
    private fun bodyContent() {
        Box(modifier = Modifier.fillMaxWidth().height(BODY_HEIGHT_DP.dp)) {
            Text("body")
        }
    }

    private fun stateIs(expected: String): SemanticsMatcher =
        SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, expected)

    private companion object {
        const val TAG = "disclosure.semantics.test"
        const val ROW_HEIGHT_DP = 44
        const val BODY_HEIGHT_DP = 80f
        const val CUSTOM_STATE = "custom state"
        const val CUSTOM_ACTION = "custom action"
    }
}
