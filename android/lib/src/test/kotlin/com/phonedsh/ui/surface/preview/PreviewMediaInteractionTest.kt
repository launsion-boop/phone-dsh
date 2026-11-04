// Native media interaction state: bounded zoom and PDF page navigation.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface.preview

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PreviewMediaInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `pdf pager moves one page at a time and stops at the ends`() {
        val bitmap = Bitmap.createBitmap(24, 32, Bitmap.Config.ARGB_8888).asImageBitmap()
        val pages = listOf(bitmap, bitmap, bitmap)
        var page by mutableIntStateOf(0)
        compose.setContent {
            PdshTheme {
                PdfPager(
                    pages = pages,
                    totalPages = 3,
                    pageIndex = page,
                    onPageChange = { page = it },
                )
            }
        }
        compose.onNodeWithTag(PREVIEW_PDF_PAGE_INDEX).assertTextEquals("1 / 3")
        compose.onNodeWithTag(PREVIEW_PDF_PREVIOUS).performClick()
        compose.onNodeWithTag(PREVIEW_PDF_PAGE_INDEX).assertTextEquals("1 / 3")
        compose.onNodeWithTag(PREVIEW_PDF_NEXT).performClick()
        compose.onNodeWithTag(PREVIEW_PDF_PAGE_INDEX).assertTextEquals("2 / 3")
        compose.onNodeWithTag(PREVIEW_PDF_NEXT).performClick()
        compose.onNodeWithTag(PREVIEW_PDF_PAGE_INDEX).assertTextEquals("3 / 3")
        compose.onNodeWithTag(PREVIEW_PDF_NEXT).performClick()
        compose.onNodeWithTag(PREVIEW_PDF_PAGE_INDEX).assertTextEquals("3 / 3")
    }

    @Test
    fun `pinch state is bounded and resets translation when scale returns to fit`() {
        val zoomed = PreviewZoomState().transformed(2f, Offset(14f, -8f))
        assertEquals(2f, zoomed.scale)
        assertEquals(Offset(14f, -8f), zoomed.translation)

        val capped = zoomed.transformed(20f, Offset.Zero)
        assertEquals(6f, capped.scale)

        val fitted = capped.transformed(0.01f, Offset.Zero)
        assertEquals(1f, fitted.scale)
        assertEquals(Offset.Zero, fitted.translation)
    }
}
