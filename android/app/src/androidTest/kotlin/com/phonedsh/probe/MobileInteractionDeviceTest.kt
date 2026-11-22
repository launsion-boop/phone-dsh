// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.accessibilityservice.AccessibilityService
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MobileInteractionDeviceTest {
    private val ui get() = InstrumentationRegistry.getInstrumentation().uiAutomation
    private fun nodes(): List<AccessibilityNodeInfo> {
        val root = ui.rootInActiveWindow ?: return emptyList()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        val result = mutableListOf<AccessibilityNodeInfo>()
        queue.add(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (node.isVisibleToUser) result += node
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::addLast)
        }
        return result
    }
    private fun node(label: String) = nodes().firstOrNull { it.text?.toString() == label || it.contentDescription?.toString() == label }
    private fun click(label: String): Boolean {
        var target = node(label) ?: return false
        while (!target.isClickable) target = target.parent ?: return false
        return target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }
    private fun waitFor(label: String, predicate: () -> Boolean) {
        val start = SystemClock.uptimeMillis()
        while (SystemClock.uptimeMillis() - start < 12000) {
            if (predicate()) return
            SystemClock.sleep(120)
        }
        throw AssertionError(label)
    }
    @Test fun meChildInterceptsOneSystemBackAndRestoresClickableTabs() {
        ActivityScenario.launch(MainActivity::class.java).use {
            waitFor("Bot root") { node("打开 Bot 列表") != null }
            waitFor("open Me") { click("我的") }
            for (label in listOf("已归档会话", "关于 Phone DSH")) {
                waitFor("open $label") {
                    if (click(label)) true else {
                        nodes().firstOrNull { it.isScrollable }?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                        false
                    }
                }
                waitFor("hide root tabs on $label") { node("返回") != null && node("DSH") == null }
                assertTrue(ui.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK))
                waitFor("restore Me after $label") { node("DSH") != null && node("Tono 账号") != null }
            }
            waitFor("switch to Discover") { click("发现") }
            waitFor("Discover actually opened") { node("Gmail") != null }
        }
    }
}
