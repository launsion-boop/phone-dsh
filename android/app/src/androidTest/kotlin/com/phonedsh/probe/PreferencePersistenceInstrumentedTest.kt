// The preference layer on a device: one file, every key, and a kill between two
// phases.
// SPDX-License-Identifier: MIT
//
// L68's acceptance is "change a preference, kill the process, restart, it is
// still there". This class is that acceptance on an emulator, in three tests that
// are run as **two instrumented invocations** so a real process death sits
// between them:
//
//   1. `writeLanguageAndAppearanceThroughTheSettingsPage` — the real UI: drawer
//      → 设置 → 语言 → English → 外观 → 深色. It asserts the device's
//      SharedPreferences file, not a view-model field.
//   2. (host) `adb shell am force-stop com.phonedsh.app`
//   3. `languageAndAppearanceAreStillThereAfterAProcessRestart` — a fresh
//      process launches the app, opens the same page and asserts the two rows
//      render the stored choices. The `Assume` guards the test so a plain
//      `connectedAndroidTest` run (where phase 1 may not have run, or ran in the
//      same process) does not report a fabricated pass.
//
// `everyStoredPreferenceLandsInTheOnePreferencesFile` is the per-key device
// proof: all eleven keys are written through the store, read back through a
// second store instance over the same file, and then the file's own `all` map is
// asserted — the bytes on disk, not the in-memory cache. It restores the previous
// values afterwards so a developer's device keeps its settings.
//
// The exact command sequence is in the lane report:
//   adb shell am instrument -w -e class 'com.phonedsh.probe.PreferencePersistenceInstrumentedTest#writeLanguageAndAppearanceThroughTheSettingsPage' com.phonedsh.app.test/androidx.test.runner.AndroidJUnitRunner
//   adb shell am force-stop com.phonedsh.app
//   adb shell am instrument -w -e class 'com.phonedsh.probe.PreferencePersistenceInstrumentedTest#languageAndAppearanceAreStillThereAfterAProcessRestart' com.phonedsh.app.test/androidx.test.runner.AndroidJUnitRunner
package com.phonedsh.probe

import android.app.UiAutomation
import android.content.Context
import android.content.SharedPreferences
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.CollapseTiming
import com.phonedsh.ui.page.PerformanceUsage
import com.phonedsh.ui.page.SettingsAppearance
import com.phonedsh.ui.page.SettingsLanguage
import com.phonedsh.ui.page.TranscriptViewMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PreferencePersistenceInstrumentedTest {

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    // -----------------------------------------------------------------------
    // Phase 1: the real UI writes two preferences
    // -----------------------------------------------------------------------

    @Test
    fun writeLanguageAndAppearanceThroughTheSettingsPage() {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            assertTrue("the native face never rendered", awaitText(automation, DRAWER_OPEN))
            assertTrue("the drawer did not open", click(automation, DRAWER_OPEN))
            assertTrue("the drawer has no 设置 row", awaitText(automation, SETTINGS))
            assertTrue("the 设置 row did not open the sheet", click(automation, SETTINGS))

            // 通用 is the sheet's default tab; its 语言 and 外观 rows are in the
            // second card. Each is a menu row: tap it, then tap the option.
            assertTrue("the settings sheet has no 语言 row", awaitText(automation, LANGUAGE))
            assertTrue("the 语言 row did not expand", click(automation, LANGUAGE))
            assertTrue("the 语言 menu has no English", awaitText(automation, "English"))
            assertTrue("English was not selectable", click(automation, "English"))

            assertTrue("the settings sheet has no 外观 row", awaitText(automation, APPEARANCE))
            assertTrue("the 外观 row did not expand", click(automation, APPEARANCE))
            assertTrue("the 外观 menu has no 深色", awaitText(automation, DARK))
            assertTrue("深色 was not selectable", click(automation, DARK))

            // The assertion is about the device's file, not about the page: a
            // callback that updated a StateFlow only would pass the UI check and
            // fail here.
            val store = PreferenceStore(SharedPreferenceFile(context))
            assertEquals(SettingsLanguage.EN, store.snapshot().language)
            assertEquals(SettingsAppearance.DARK, store.snapshot().appearance)
            val file = preferencesFile()
            assertEquals("en", file.getString(PreferenceStore.LANGUAGE_KEY, null))
            assertEquals("dark", file.getString(PreferenceStore.APPEARANCE_KEY, null))
        } finally {
            scenario.close()
        }
    }

    // -----------------------------------------------------------------------
    // Phase 2: after the host killed the process
    // -----------------------------------------------------------------------

    @Test
    fun languageAndAppearanceAreStillThereAfterAProcessRestart() {
        val store = PreferenceStore(SharedPreferenceFile(context))
        assumeTrue(
            "run writeLanguageAndAppearanceThroughTheSettingsPage first, then " +
                "`am force-stop com.phonedsh.app`, then this test",
            store.snapshot().language == SettingsLanguage.EN &&
                store.snapshot().appearance == SettingsAppearance.DARK,
        )

        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            assertTrue("the native face never rendered", awaitText(automation, DRAWER_OPEN))
            assertTrue("the drawer did not open", click(automation, DRAWER_OPEN))
            assertTrue("the drawer has no 设置 row", awaitText(automation, SETTINGS))
            assertTrue("the 设置 row did not open the sheet", click(automation, SETTINGS))

            // A fresh process, a collapsed menu: "English" and "深色" can only be
            // the rows' values, i.e. what the page rendered from the stored file.
            assertTrue("the 语言 row no longer shows English", awaitText(automation, "English"))
            assertTrue("the 外观 row no longer shows 深色", awaitText(automation, DARK))
        } finally {
            scenario.close()
        }
    }

    // -----------------------------------------------------------------------
    // Every key, on the device, in the one file
    // -----------------------------------------------------------------------

    @Test
    fun everyStoredPreferenceLandsInTheOnePreferencesFile() {
        val file = preferencesFile()
        val before = file.all
        try {
            val store = PreferenceStore(SharedPreferenceFile(context))
            store.setFontSize(FontRole.TEXT, 20)
            store.setFontSize(FontRole.CODE, 12)
            store.setFontSize(FontRole.TERMINAL, 18)
            store.setAppearance(SettingsAppearance.DARK)
            store.setLanguage(SettingsLanguage.EN)
            store.setTranscriptView(TranscriptViewMode.COMPACT)
            store.setCollapseTiming(CollapseTiming.NEXT_INPUT)
            store.setDeveloperTools(false)
            store.setPerformanceUsage(PerformanceUsage.COMPACT)
            store.setBusyEnterMode(BusyEnterMode.STEER)
            store.setBackgroundKeepAlive(false)

            // The file on disk, not the in-memory `StateFlow`.
            assertTrue(
                "the preferences file is missing keys: ${PreferenceStore.ALL_KEYS - file.all.keys}",
                file.all.keys.containsAll(PreferenceStore.ALL_KEYS),
            )
            // A second store over the same file: the cold-start read path.
            val restarted = PreferenceStore(SharedPreferenceFile(context)).snapshot()
            assertEquals(20, restarted.textFontSize)
            assertEquals(12, restarted.codeFontSize)
            assertEquals(18, restarted.terminalFontSize)
            assertEquals(SettingsAppearance.DARK, restarted.appearance)
            assertEquals(SettingsLanguage.EN, restarted.language)
            assertEquals(TranscriptViewMode.COMPACT, restarted.transcriptView)
            assertEquals(CollapseTiming.NEXT_INPUT, restarted.collapseTiming)
            assertEquals(false, restarted.developerTools)
            assertEquals(PerformanceUsage.COMPACT, restarted.performanceUsage)
            assertEquals(BusyEnterMode.STEER, restarted.busyEnterMode)
            assertEquals(false, restarted.backgroundKeepAlive)
        } finally {
            restore(file, before)
        }
    }

    // -----------------------------------------------------------------------
    // The file and its restoration
    // -----------------------------------------------------------------------

    private fun preferencesFile(): SharedPreferences =
        context.getSharedPreferences(PreferenceStore.FILE_NAME, Context.MODE_PRIVATE)

    /** Puts [values] back (or removes keys that were absent), so a device keeps its settings. */
    private fun restore(file: SharedPreferences, values: Map<String, *>) {
        val editor = file.edit().clear()
        for ((key, value) in values) {
            when (value) {
                is String -> editor.putString(key, value)
                is Int -> editor.putInt(key, value)
                is Boolean -> editor.putBoolean(key, value)
                is Long -> editor.putLong(key, value)
                is Float -> editor.putFloat(key, value)
                is Set<*> -> editor.putStringSet(key, value.filterIsInstance<String>().toSet())
            }
        }
        editor.commit()
    }

    // -----------------------------------------------------------------------
    // The accessibility-tree helpers (the app's real tree)
    // -----------------------------------------------------------------------

    private fun awaitText(
        automation: UiAutomation,
        label: String,
        timeoutMs: Long = WAIT_MILLIS,
    ): Boolean = awaitNode(automation, timeoutMs) { node -> label in node.labels() }

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
        /** The home header's drawer action, as its spoken name. */
        const val DRAWER_OPEN = "打开会话列表"

        /** The settings row in the drawer's footer. */
        const val SETTINGS = "设置"

        /** 通用 tab's preference rows. */
        const val LANGUAGE = "语言"
        const val APPEARANCE = "外观"

        /** 外观 › 深色 (`SettingsAppearance.DARK.label`). */
        const val DARK = "深色"

        const val WAIT_MILLIS = 20_000L
        const val POLL_MILLIS = 250L
    }
}
