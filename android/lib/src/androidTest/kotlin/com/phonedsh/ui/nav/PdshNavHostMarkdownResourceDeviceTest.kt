// The chat route resolves scoped markdown resources only against the selected workspace.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.assertIsDisplayed
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.screenshot.ChatParitySamples
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.surface.MARKDOWN_MATH_TEXT_VIEW_TAG
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdshNavHostMarkdownResourceDeviceTest {
    private companion object {
        const val LOCAL_UI_SESSION_ID: String = "ui-chat-local-A"
        const val WORKER_SESSION_ID: String = "worker-session-A"
    }

    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    private lateinit var workspace: File

    @Before
    fun prepareWorkspace() {
        workspace = File(compose.activity.filesDir, "markdown-resource-workspace").apply {
            deleteRecursively()
            resolve("docs").mkdirs()
        }
        Files.write(workspace.toPath().resolve("docs/image.png"), byteArrayOf(1, 2, 3))
    }

    @Test
    fun currentSessionResourceLinkUsesTheVerifiedWorkspaceRoute() {
        val resource = "dsh-resource://file/session/$WORKER_SESSION_ID/dsh/workspace/docs/image.png"
        var pushed: PdshRoute? = null
        mount(markdown = "A formula ${'$'}x^2${'$'} and [open-resource-target]($resource)") { pushed = it }
        val textView = findTextView("open-resource-target")
        tapSpan(textView, "open-resource-target")
        compose.waitUntil(10_000) { pushed != null }
        assertEquals(PdshRoute.Preview("docs/image.png"), pushed)
    }

    @Test
    fun differentWorkerSessionResourceShowsAnUnavailableCardWithoutRouting() {
        val wrongSession = "dsh-resource://file/session/worker-session-B/dsh/workspace/docs/image.png"
        var pushed: PdshRoute? = null
        mount(markdown = "[unavailable-resource-target]($wrongSession)") { pushed = it }
        val textView = findTextView("unavailable-resource-target")
        tapSpan(textView, "unavailable-resource-target")
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_UNAVAILABLE).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(wrongSession).assertIsDisplayed()
        assertNull("a different session must not be previewed from the current root", pushed)
    }

    @Test
    fun absoluteResourceShowsAnUnavailableCardWithoutRouting() {
        val absoluteResource = "dsh-resource://file/absolute/etc/passwd"
        var pushed: PdshRoute? = null
        mount(markdown = "[absolute-resource-target]($absoluteResource)") { pushed = it }
        val textView = findTextView("absolute-resource-target")
        tapSpan(textView, "absolute-resource-target")
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_UNAVAILABLE).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(absoluteResource).assertIsDisplayed()
        assertNull("absolute resource must not be previewed", pushed)
    }

    @Test
    fun fileWorkspaceUriUsesPreviewResolutionBeforeNavigation() {
        val resource = "file:///dsh/workspace/docs/image.png"
        var pushed: PdshRoute? = null
        mount(markdown = "[workspace-file-target]($resource)") { pushed = it }
        val textView = findTextView("workspace-file-target")
        tapSpan(textView, "workspace-file-target")
        compose.waitUntil(10_000) { pushed != null }
        assertEquals(PdshRoute.Preview("docs/image.png"), pushed)
    }

    @Test
    fun sandboxWorkspaceUriUsesPreviewResolutionBeforeNavigation() {
        val resource = "sandbox:docs/image.png"
        var pushed: PdshRoute? = null
        mount(markdown = "[sandbox-file-target]($resource)") { pushed = it }
        val textView = findTextView("sandbox-file-target")
        tapSpan(textView, "sandbox-file-target")
        compose.waitUntil(10_000) { pushed != null }
        assertEquals(PdshRoute.Preview("docs/image.png"), pushed)
    }

    private fun mount(markdown: String, onNavigate: (PdshRoute) -> Unit) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.Chat)),
                    facts = PdshNavFacts(),
                    onNavigate = onNavigate,
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { androidx.compose.foundation.text.BasicText("home") },
                    webSurface = {},
                    workspaceRoot = workspace,
                    chat = ChatParitySamples.chatAssistant().copy(
                        sessionID = LOCAL_UI_SESSION_ID,
                        workerSessionID = WORKER_SESSION_ID,
                        rows = listOf(ChatRow.Assistant("resource-link-row", "Inline ${'$'}x^2${'$'} $markdown")),
                    ),
                )
            }
        }
        compose.waitForIdle()
    }

    private fun findTextView(label: String): TextView {
        val found = ArrayList<View>()
        (compose.activity.window.decorView as ViewGroup).findViewsWithText(found, label, View.FIND_VIEWS_WITH_TEXT)
        return found.filterIsInstance<TextView>().firstOrNull { it.text?.toString()?.contains(label) == true }
            ?: error("no markdown TextView containing $label")
    }

    private fun tapSpan(textView: TextView, label: String) {
        val start = textView.text.toString().indexOf(label)
        assertTrue("missing link label $label", start >= 0)
        val line = textView.layout.getLineForOffset(start)
        val x = (textView.layout.getPrimaryHorizontal(start) + textView.layout.getPrimaryHorizontal(start + label.length)) / 2f
        val y = (textView.layout.getLineTop(line) + textView.layout.getLineBottom(line)) / 2f
        compose.onNodeWithTag(MARKDOWN_MATH_TEXT_VIEW_TAG).performTouchInput { click(Offset(x, y)) }
    }
}
