// Local workspace and scripted remote Markdown image states on the owned emulator.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.screenshot

import android.graphics.Bitmap
import android.view.KeyEvent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.surface.MARKDOWN_IMAGE_LOADING_TAG
import com.phonedsh.ui.surface.MARKDOWN_IMAGE_TAG
import com.phonedsh.ui.surface.MARKDOWN_IMAGE_VIEWER_TAG
import com.phonedsh.ui.surface.MARKDOWN_BODY_TAG
import com.phonedsh.ui.surface.LocalMarkdownRemoteImageLoader
import com.phonedsh.ui.surface.MarkdownBody
import com.phonedsh.ui.surface.MarkdownImageSource
import com.phonedsh.ui.surface.MarkdownRemoteImageLoader
import com.phonedsh.ui.surface.MarkdownVariant
import com.phonedsh.ui.surface.preview.WorkspacePreviewSource
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MarkdownImageDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    private lateinit var workspaceRoot: File
    private lateinit var screenshotDirectory: File

    @Before
    fun prepareWorkspace() {
        workspaceRoot = File(compose.activity.filesDir, "markdown-image-workspace")
        workspaceRoot.deleteRecursively()
        assertTrue(workspaceRoot.mkdirs())
        screenshotDirectory = File(compose.activity.getExternalFilesDir(null), "math-production-candidate").apply { mkdirs() }
    }

    @Test
    fun localWorkspaceImageLoadsFitsOpensBlackViewerAndDismisses() {
        val relative = "photos/large-landscape.png"
        val imageFile = File(workspaceRoot, relative).apply { parentFile?.mkdirs() }
        writeFixture(imageFile, width = 1800, height = 900, color = android.graphics.Color.MAGENTA)
        val imageSource = MarkdownImageSource(
            workspaceFiles = WorkspacePreviewSource(workspaceRoot.toPath()),
        )
        var source by mutableStateOf(relative)
        var markdownOverride by mutableStateOf<String?>(null)
        compose.setContent {
            PdshTheme(darkTheme = false) {
                MarkdownBody(
                    markdown = markdownOverride ?: "![local architecture image]($source \"architecture\")",
                    imageSource = imageSource,
                )
            }
        }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag(MARKDOWN_IMAGE_TAG).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).assertIsDisplayed()
        val thumbnail = compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).fetchSemanticsNode().boundsInRoot
        assertTrue("thumbnail exceeds 640 dp width", thumbnail.width <= 640f * compose.activity.resources.displayMetrics.density)
        assertTrue("thumbnail exceeds 360 dp height", thumbnail.height <= 360f * compose.activity.resources.displayMetrics.density)
        saveCapture("local-loaded.png", MARKDOWN_IMAGE_TAG)

        compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).performClick()
        compose.onNodeWithTag(MARKDOWN_IMAGE_VIEWER_TAG).assertIsDisplayed()
        saveCapture("local-viewer.png", MARKDOWN_IMAGE_VIEWER_TAG)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitForIdle()
        compose.onAllNodesWithTag(MARKDOWN_IMAGE_VIEWER_TAG).assertCountEquals(0)
        compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).assertIsDisplayed()

        source = "photos/missing.png"
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText("local architecture image").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("local architecture image").assertIsDisplayed()
        compose.onAllNodesWithTag(MARKDOWN_IMAGE_LOADING_TAG).assertCountEquals(0)
        saveCapture("local-unavailable-alt.png", MARKDOWN_IMAGE_TAG)

        markdownOverride = "- ![local list image]($relative)"
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag(MARKDOWN_IMAGE_TAG).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).assertIsDisplayed()
        saveCapture("local-list-image.png", MARKDOWN_IMAGE_TAG)
    }

    @Test
    fun scriptedRemoteImageShowsLoadingLoadedViewerDismissalAndErrorFallback() {
        val bytes = CompletableDeferred<Bitmap?>()
        val requested = mutableListOf<String>()
        val loader = MarkdownRemoteImageLoader { uri ->
            requested += uri.toString()
            when (uri.path) {
                "/delayed.png" -> bytes.await()
                "/missing.png" -> null
                else -> null
            }
        }
        var source by mutableStateOf("https://scripted.invalid/delayed.png")
        val imageSource = MarkdownImageSource()
        compose.setContent {
            CompositionLocalProvider(LocalMarkdownRemoteImageLoader provides loader) {
                PdshTheme(darkTheme = false) {
                    MarkdownBody(
                        markdown = "![scripted remote alt]($source)",
                        imageSource = imageSource,
                    )
                }
            }
        }
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(MARKDOWN_IMAGE_LOADING_TAG).fetchSemanticsNodes().isNotEmpty()
        }
        saveCapture("remote-loading.png", MARKDOWN_IMAGE_LOADING_TAG)

        bytes.complete(solidBitmap(width = 640, height = 360, color = android.graphics.Color.CYAN))
        compose.waitUntil(10_000) {
            compose.onAllNodesWithTag(MARKDOWN_IMAGE_TAG).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).assertIsDisplayed()
        saveCapture("remote-loaded.png", MARKDOWN_IMAGE_TAG)
        compose.onNodeWithTag(MARKDOWN_IMAGE_TAG).performClick()
        compose.onNodeWithTag(MARKDOWN_IMAGE_VIEWER_TAG).assertIsDisplayed()
        saveCapture("remote-viewer.png", MARKDOWN_IMAGE_VIEWER_TAG)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitForIdle()
        compose.onAllNodesWithTag(MARKDOWN_IMAGE_VIEWER_TAG).assertCountEquals(0)

        source = "https://scripted.invalid/missing.png"
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText("scripted remote alt").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("scripted remote alt").assertIsDisplayed()
        compose.onAllNodesWithTag(MARKDOWN_IMAGE_LOADING_TAG).assertCountEquals(0)
        saveCapture("remote-error-alt.png", MARKDOWN_IMAGE_TAG)
        assertEquals(
            listOf("https://scripted.invalid/delayed.png", "https://scripted.invalid/missing.png"),
            requested,
        )
    }

    @Test
    fun inlineImageKeepsAltTextAndDoesNotStartImageLoading() {
        var requests = 0
        val loader = MarkdownRemoteImageLoader { requests++; null }
        compose.setContent {
            CompositionLocalProvider(LocalMarkdownRemoteImageLoader provides loader) {
                PdshTheme(darkTheme = false) {
                    MarkdownBody(
                        markdown = "Inline ![inline-alt-remains](https://scripted.invalid/inline.png) stays prose.",
                        imageSource = MarkdownImageSource(),
                    )
                }
            }
        }
        compose.onNodeWithText("Inline inline-alt-remains stays prose.").assertIsDisplayed()
        compose.onAllNodesWithTag(MARKDOWN_IMAGE_LOADING_TAG).assertCountEquals(0)
        compose.onAllNodesWithTag(MARKDOWN_IMAGE_TAG).assertCountEquals(0)
        assertEquals(0, requests)
        saveCapture("inline-alt-unchanged.png", MARKDOWN_BODY_TAG)
    }

    private fun saveCapture(name: String, tag: String) {
        val bitmap = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        FileOutputStream(File(screenshotDirectory, name)).use { stream ->
            assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
    }

    private fun writeFixture(file: File, width: Int, height: Int, color: Int) {
        solidBitmap(width, height, color).useBitmap { bitmap ->
            FileOutputStream(file).use { stream ->
                assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
            }
        }
    }

    private fun solidBitmap(width: Int, height: Int, color: Int): Bitmap =
        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }

    private inline fun <T> T.useBitmap(block: (T) -> Unit) {
        try {
            block(this)
        } finally {
            if (this is Bitmap && !isRecycled) recycle()
        }
    }
}
