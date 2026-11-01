// The sessions page really lists a stored session on a device.
// SPDX-License-Identifier: MIT
//
// The page is a pure function of host facts; the host half is what this test
// proves. It writes one session through the same `JournalStore` the host uses,
// launches the app, opens the drawer's 会话 row and asserts the row the page
// rendered. The accessibility tree is the app's real tree (the one a screen
// reader sees), so passing here means a stored session is on screen, not only in
// a state object.
//
// The workspace directory is the app's own `filesDir/xl`, the one path the view
// model builds every store over. The seeded session is removed afterwards; any
// session an earlier run stored stays untouched.
package com.phonedsh.probe

import android.app.UiAutomation
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.dsh.journal.JournalPaths
import com.phonedsh.dsh.journal.JournalStore
import com.phonedsh.platform.android.AndroidDurability
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionsHostWiringInstrumentedTest {

    @Test
    fun aStoredSessionRendersAsARow() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // One id per run: a second record at the same jseq is a torn tail to
        // recovery, so a rerun must not depend on what an earlier run left.
        val sessionId = "ses-ui-" + System.nanoTime()
        val paths = JournalPaths(File(context.filesDir, WORKSPACE_DIRECTORY).toPath())
        val store = JournalStore(paths = paths, durability = AndroidDurability())
        runBlocking {
            store.recover()
            store.append(sessionId, 1L, byteArrayOf(0x7B, 0x7D))
        }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            assertTrue("the native face never rendered", awaitText(automation, DRAWER_OPEN))
            assertTrue("the drawer did not open", click(automation, DRAWER_OPEN))
            assertTrue("the drawer has no 会话 row", awaitText(automation, "会话"))
            assertTrue("the 会话 row did not open the page", click(automation, "会话"))
            assertTrue("the sessions page never rendered", awaitText(automation, PAGE_TITLE))
            // The host has no title store, so every row takes the page's own
            // untitled name; 新建会话 is the longer action row and never matches.
            assertTrue("no stored session row on the page", awaitRow(automation))
        } finally {
            scenario.close()
            runCatching { Files.deleteIfExists(paths.sessionFile(sessionId)) }
        }
    }

    /** True when any text or description equals [label]. */
    private fun awaitText(
        automation: UiAutomation,
        label: String,
        timeoutMs: Long = WAIT_MILLIS,
    ): Boolean = awaitNode(automation, timeoutMs) { node -> label in node.labels() }

    /**
     * True when the page shows an untitled session row.
     *
     * The page numbers repeated untitled rows (`新会话 2`), so the exact first
     * name is only guaranteed on the first row; any row proves the host fed the
     * list. `新建会话` is excluded by requiring the exact name or its numbered
     * form, never a prefix.
     */
    private fun awaitRow(
        automation: UiAutomation,
        timeoutMs: Long = WAIT_MILLIS,
    ): Boolean = awaitNode(automation, timeoutMs) { node ->
        node.labels().any { label -> label == ROW_TITLE || label.startsWith("$ROW_TITLE ") }
    }

    private fun awaitNode(
        automation: UiAutomation,
        timeoutMs: Long,
        predicate: (AccessibilityNodeInfo) -> Boolean,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val root = automation.rootInActiveWindow
            if (root != null && find(root, predicate) != null) return true
            Thread.sleep(POLL_MILLIS)
        }
        return false
    }

    /** Clicks the first node whose text or description equals [label]. */
    private fun click(automation: UiAutomation, label: String): Boolean {
        val root = automation.rootInActiveWindow ?: return false
        val node = find(root) { candidate -> label in candidate.labels() } ?: return false
        var target: AccessibilityNodeInfo? = node
        while (target != null && !target.isClickable) target = target.parent
        return (target ?: node).performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    /** Breadth-first so the shallow, visible node wins over a deep duplicate. */
    private fun find(
        root: AccessibilityNodeInfo,
        predicate: (AccessibilityNodeInfo) -> Boolean,
    ): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (predicate(node)) return node
            for (index in 0 until node.childCount) {
                node.getChild(index)?.let(queue::addLast)
            }
        }
        return null
    }

    private fun AccessibilityNodeInfo.labels(): List<String> = listOfNotNull(
        text?.toString()?.trim(),
        contentDescription?.toString()?.trim(),
    ).filter { it.isNotEmpty() }

    private companion object {
        /** The app's workspace root under filesDir (the view model's one path). */
        const val WORKSPACE_DIRECTORY = "xl"

        /** The home header's drawer action, as its spoken name. */
        const val DRAWER_OPEN = "打开抽屉"

        /** The sessions page's own heading. */
        const val PAGE_TITLE = "会话列表"

        /** The page's untitled-session name (the host stores no title). */
        const val ROW_TITLE = "新会话"

        const val WAIT_MILLIS = 20_000L
        const val POLL_MILLIS = 250L
    }
}
