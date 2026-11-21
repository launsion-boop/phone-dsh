// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.accessibilityservice.AccessibilityService
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.platform.android.AndroidSecureStore
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Uses synthetic settings on the dedicated test emulator; restores its original document. */
@RunWith(AndroidJUnit4::class)
class WebSearchAddressProductDeviceTest {
    private val automation get() = InstrumentationRegistry.getInstrumentation().uiAutomation
    private fun await(condition: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + 25_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return true
            SystemClock.sleep(100)
        }
        return false
    }
    private fun nodes(): List<AccessibilityNodeInfo> {
        val root = automation.rootInActiveWindow ?: return emptyList()
        val queue = ArrayDeque<AccessibilityNodeInfo>(); val all = mutableListOf<AccessibilityNodeInfo>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst(); all.add(node)
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::addLast)
        }
        return all
    }
    private fun find(vararg labels: String): AccessibilityNodeInfo? = nodes().firstOrNull { node ->
        node.isVisibleToUser && labels.any { it == node.text?.toString() || it == node.contentDescription?.toString() }
    }
    private fun tap(vararg labels: String): Boolean {
        var node = find(*labels) ?: return false
        while (!node.isClickable) node = node.parent ?: return false
        return node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }
    private fun tapAfterScroll(label: String, forward: Boolean): Boolean {
        if (tap(label)) return true
        val list = nodes().firstOrNull { it.isScrollable } ?: return false
        list.performAction(if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
        return false
    }
    @Test fun addressIsCommittedOnLeavingAndShownOnReturn() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.filesDir, WebSearchSettingsStore.FILE_NAME)
        val original = if (file.exists()) file.readBytes() else null
        val store = WebSearchSettingsStore.install(context, ApiKeyStore(AndroidSecureStore(context)))
        assertEquals("This task emulator must have no stored search key", ApiKeyState.Absent, store.keyState())
        fun openSearch() {
            assertTrue(await { tap("Web search", "网页搜索") })
            assertTrue(await { tap("Set up web search", "设置网页搜索") })
            assertTrue(await { find("网页搜索") != null && find("自己填一个") != null })
        }
        try {
            store.remove()
            ActivityScenario.launch(MainActivity::class.java).use {
                assertTrue(await { tap("发现", "Discover") })
                openSearch()
                assertTrue(await { tap("自己填一个") })
                assertTrue(await { tap("api.deepseek.com") })
                assertTrue(await {
                    val editor = nodes().firstOrNull { it.className == "android.widget.EditText" && it.isFocused }
                    val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "example.invalid") }
                    editor?.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args) == true
                })
                assertTrue(await { find("example.invalid") != null })
                assertTrue(await { tap("返回", "Back") })
                assertTrue("navigation did not return to Discover", await { find("Gmail") != null })
                assertTrue("the edited address was not stored after leaving: ${store.read()}",
                    await { (store.read() as? WebSearchSettingsRead.Stored)?.settings?.baseUrl == "https://example.invalid" })
                openSearch()
                assertTrue(await { find("https://example.invalid") != null })
                SystemClock.sleep(2_000)
                val screenshot = requireNotNull(automation.takeScreenshot())
                File(context.getExternalFilesDir(null), "web-search-address.png").outputStream().use {
                    screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                screenshot.recycle()
                assertTrue(await { tap("https://example.invalid") })
                assertTrue(await {
                    val editor = nodes().firstOrNull { it.className == "android.widget.EditText" && it.isFocused }
                    val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "blur.example.invalid") }
                    editor?.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args) == true
                })
                val keyTapped = await { tapAfterScroll("粘贴密钥", forward = true) }
                if (!keyTapped) {
                    val diagnostics = nodes().filter { it.isScrollable || it.className == "android.widget.EditText" || it.text?.toString() == "粘贴密钥" }
                        .joinToString { node ->
                            val rect = android.graphics.Rect(); node.getBoundsInScreen(rect)
                            "class=${node.className} visible=${node.isVisibleToUser} scroll=${node.isScrollable} bounds=$rect"
                        }
                    throw AssertionError("key field not reachable: $diagnostics")
                }
                assertTrue("blur did not commit", await {
                    (store.read() as? WebSearchSettingsRead.Stored)?.settings?.baseUrl == "https://blur.example.invalid"
                })
                assertTrue(await { tapAfterScroll("https://blur.example.invalid", forward = false) })
                assertTrue(await {
                    val editor = nodes().firstOrNull {
                        it.className == "android.widget.EditText" && it.text?.toString() == "https://blur.example.invalid"
                    }
                    val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "system.example.invalid") }
                    editor?.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args) == true
                })
                assertTrue("the second address was not entered in the address field", await { find("system.example.invalid") != null })
                assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK))
                SystemClock.sleep(500)
                if (find("Gmail") == null) assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK))
                assertTrue(await { find("Gmail") != null })
                assertTrue("system back did not commit", await {
                    (store.read() as? WebSearchSettingsRead.Stored)?.settings?.baseUrl == "https://system.example.invalid"
                })
                assertEquals(ApiKeyState.Absent, store.keyState())
            }
        } finally {
            if (original == null) file.delete() else {
                file.parentFile?.mkdirs()
                file.writeBytes(original)
            }
        }
    }
}
