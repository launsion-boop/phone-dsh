// The `@` menu must re-read the workspace when the workspace changes.
// SPDX-License-Identifier: MIT
//
// The host effect that loads the candidates used to follow only chat/session/
// settings state. A 文件 page import (`filesImportReceipt`, `attachToChat = false`)
// and an agent turn's workspace writes change none of those, so the menu could
// keep showing the pre-change listing. These cases pin the effect's refresh key:
// it must change for an import, for a measured turn write, and when the trigger
// opens (the catch-all for a file changed while the menu was closed).
package com.phonedsh.probe

import com.phonedsh.ui.page.FilesImportReceipt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatMentionRefreshTest {
    @Test
    fun `a workspace import changes the mention refresh key`() {
        val before = chatMentionRefreshKey(chatId = "chat-1")

        val imported = chatMentionRefreshKey(
            chatId = "chat-1",
            importReceipt = "import-1" to FilesImportReceipt.IMPORTED,
        )

        assertNotEquals(
            "a 文件 page import is not an attachment; without this key the @ menu keeps stale candidates",
            before,
            imported,
        )
    }

    @Test
    fun `an agent workspace write changes the mention refresh key`() {
        val before = chatMentionRefreshKey(chatId = "chat-1")

        val afterTurn = chatMentionRefreshKey(
            chatId = "chat-1",
            artifactWrites = listOf("reports/ui-smoke.csv"),
        )

        assertNotEquals(
            "a turn that wrote a file changes no chat row; the write fact must refresh the @ menu",
            before,
            afterTurn,
        )
    }

    @Test
    fun `opening the reference trigger changes the mention refresh key once`() {
        val closed = chatMentionRefreshKey(chatId = "chat-1", referenceMenuOpen = false)
        val opened = chatMentionRefreshKey(chatId = "chat-1", referenceMenuOpen = true)
        val stillTyping = chatMentionRefreshKey(chatId = "chat-1", referenceMenuOpen = true)

        assertNotEquals("opening @ must re-read the workspace", closed, opened)
        assertEquals("typing inside the token must not repeat the walk", opened, stillTyping)
        assertEquals(
            "an unrelated recomposition must not repeat the walk",
            chatMentionRefreshKey(chatId = "chat-1"),
            chatMentionRefreshKey(chatId = "chat-1"),
        )
    }

    @Test
    fun `the trigger opens for the same drafts the page projects`() {
        assertTrue(isReferenceMenuOpen("@"))
        assertTrue(isReferenceMenuOpen("@ui-smoke"))
        assertTrue(isReferenceMenuOpen("  @ui-smoke  "))
        assertFalse("the menu is closed after a pick adds a space", isReferenceMenuOpen("@ui-smoke 报告"))
        assertFalse(isReferenceMenuOpen("你好 @"))
        assertFalse(isReferenceMenuOpen(""))
    }
}
