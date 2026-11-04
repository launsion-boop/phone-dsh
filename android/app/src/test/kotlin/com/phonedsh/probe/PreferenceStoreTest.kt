// The preference store: the baseline's keys, types, defaults, clamps and one
// round-trip per stored preference.
// SPDX-License-Identifier: MIT
//
// The acceptance this suite encodes is the lane's: "one preference, one proof it
// landed". Every write below goes through the public store, then a **second**
// store instance is built over the same file — the JVM shape of a process kill —
// and must read the value back. A preference that only lives in the first
// instance's `StateFlow` fails here.
//
// The keys are the iOS baseline's own spelling
// (`NativeChatPreferences.swift:135-152`, `ChatModel.swift:43`); the name guard
// at the end is what keeps a future key from being invented without a decision.
package com.phonedsh.probe

import com.phonedsh.ui.page.BusyEnterMode
import com.phonedsh.ui.page.CollapseTiming
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.PerformanceUsage
import com.phonedsh.ui.page.SettingsAppearance
import com.phonedsh.ui.page.SettingsLanguage
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.TranscriptViewMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.runBlocking

class PreferenceStoreTest {

    // -----------------------------------------------------------------------
    // Defaults: the baseline's, not the first menu option
    // -----------------------------------------------------------------------

    @Test
    fun aFreshFileResolvesToTheBaselinesDefaults() {
        val file = MapPreferenceFile()
        val store = PreferenceStore(file)

        assertEquals(16, store.snapshot().textFontSize)
        assertEquals(14, store.snapshot().codeFontSize)
        assertEquals(13, store.snapshot().terminalFontSize)
        assertEquals(SettingsAppearance.SYSTEM, store.snapshot().appearance)
        assertEquals(SettingsLanguage.SYSTEM, store.snapshot().language)
        assertEquals(TranscriptViewMode.DETAILED, store.snapshot().transcriptView)
        assertEquals(CollapseTiming.COMPLETION, store.snapshot().collapseTiming)
        assertTrue(store.snapshot().developerTools)
        assertEquals(PerformanceUsage.DETAILED, store.snapshot().performanceUsage)
        assertEquals(BusyEnterMode.QUEUE, store.snapshot().busyEnterMode)
        assertTrue(store.snapshot().backgroundKeepAlive)
        assertNull(store.snapshot().textFontFamily)
        assertNull(store.snapshot().collapsedWorkspaceFolders)
        assertTrue("resolving new-install defaults must not materialize preference values", file.values.isEmpty())
    }

    @Test
    fun anExplicitEmptyFontFamilyIsDistinctFromAnUnreadFamilyAndExistingChoicesStayUntouched() {
        val file = MapPreferenceFile(mapOf(
            PreferenceStore.TEXT_FONT_SIZE_KEY to 19,
            PreferenceStore.TEXT_FONT_FAMILY_KEY to "",
            PreferenceStore.LANGUAGE_KEY to SettingsLanguage.EN.id,
        ))
        val before = file.values.toMap()
        val store = PreferenceStore(file)
        assertEquals("", store.snapshot().textFontFamily)
        assertEquals(19, store.snapshot().textFontSize)
        assertEquals(SettingsLanguage.EN, store.snapshot().language)
        assertEquals(before, file.values)
    }

    // -----------------------------------------------------------------------
    // One round-trip per stored preference, across a store "restart"
    // -----------------------------------------------------------------------

    /** One stored key: how to write it, and how to read it back. */
    private data class RoundTrip(
        val key: String,
        val write: suspend (PreferenceStore) -> Unit,
        val read: (Preferences) -> Any?,
    )

    @Test
    fun everyStoredPreferenceSurvivesAStoreRestart() = runBlocking {
        fun confirmed(change: ConfirmedPreferenceChange): suspend (PreferenceStore) -> Unit = { store ->
            assertEquals(PreferenceWriteOutcome.Persisted,
                store.writeConfirmed(com.phonedsh.ui.state.StateRequestId(change.key), change).outcome)
        }
        val cases = listOf(
            RoundTrip(
                PreferenceStore.TEXT_FONT_SIZE_KEY,
                confirmed(ConfirmedPreferenceChange.FontSize(FontRole.TEXT, 20)),
                { it.textFontSize },
            ),
            RoundTrip(
                PreferenceStore.CODE_FONT_SIZE_KEY,
                confirmed(ConfirmedPreferenceChange.FontSize(FontRole.CODE, 12)),
                { it.codeFontSize },
            ),
            RoundTrip(
                PreferenceStore.TERMINAL_FONT_SIZE_KEY,
                confirmed(ConfirmedPreferenceChange.FontSize(FontRole.TERMINAL, 18)),
                { it.terminalFontSize },
            ),
            RoundTrip(
                PreferenceStore.APPEARANCE_KEY,
                confirmed(ConfirmedPreferenceChange.Appearance(SettingsAppearance.DARK)),
                { it.appearance },
            ),
            RoundTrip(
                PreferenceStore.LANGUAGE_KEY,
                confirmed(ConfirmedPreferenceChange.Language(SettingsLanguage.EN)),
                { it.language },
            ),
            RoundTrip(
                PreferenceStore.TRANSCRIPT_VIEW_KEY,
                confirmed(ConfirmedPreferenceChange.TranscriptView(TranscriptViewMode.COMPACT)),
                { it.transcriptView },
            ),
            RoundTrip(
                PreferenceStore.COLLAPSE_TIMING_KEY,
                confirmed(ConfirmedPreferenceChange.CollapseTiming(CollapseTiming.NEXT_INPUT)),
                { it.collapseTiming },
            ),
            RoundTrip(
                PreferenceStore.DEVELOPER_TOOLS_KEY,
                confirmed(ConfirmedPreferenceChange.DeveloperTools(false)),
                { it.developerTools },
            ),
            RoundTrip(
                PreferenceStore.PERFORMANCE_USAGE_KEY,
                confirmed(ConfirmedPreferenceChange.PerformanceUsage(PerformanceUsage.COMPACT)),
                { it.performanceUsage },
            ),
            RoundTrip(
                PreferenceStore.BUSY_ENTER_KEY,
                confirmed(ConfirmedPreferenceChange.BusyEnterMode(BusyEnterMode.STEER)),
                { it.busyEnterMode },
            ),
            RoundTrip(
                PreferenceStore.BACKGROUND_KEEP_ALIVE_KEY,
                confirmed(ConfirmedPreferenceChange.BackgroundKeepAlive(false)),
                { it.backgroundKeepAlive },
            ),
            RoundTrip(PreferenceStore.TEXT_FONT_FAMILY_KEY, confirmed(ConfirmedPreferenceChange.FontFamily(FontRole.TEXT, "")), { it.textFontFamily }),
            RoundTrip(PreferenceStore.CODE_FONT_FAMILY_KEY, confirmed(ConfirmedPreferenceChange.FontFamily(FontRole.CODE, "serif")), { it.codeFontFamily }),
            RoundTrip(PreferenceStore.TERMINAL_FONT_FAMILY_KEY, confirmed(ConfirmedPreferenceChange.FontFamily(FontRole.TERMINAL, "monospace")), { it.terminalFontFamily }),
            RoundTrip(PreferenceStore.COLLAPSED_WORKSPACE_FOLDERS_KEY, confirmed(ConfirmedPreferenceChange.CollapsedWorkspaceFolders(setOf("daily", "archive"))), { it.collapsedWorkspaceFolders }),
        )

        for (case in cases) {
            val file = MapPreferenceFile()
            val first = PreferenceStore(file)
            case.write(first)
            assertTrue(
                "${case.key} was not written to the file after its setter ran",
                file.values.containsKey(case.key),
            )
            // The kill: a second instance over the same bytes, which is exactly
            // what a cold start does with the same SharedPreferences file.
            val second = PreferenceStore(file)
            assertEquals(
                "${case.key} did not survive the store restart",
                case.read(first.snapshot()),
                case.read(second.snapshot()),
            )
        }
    }

    // -----------------------------------------------------------------------
    // Key names: the baseline's spelling, and nothing else
    // -----------------------------------------------------------------------

    @Test
    fun theStoredKeyNamesAreTheBaselinesOwnSpelling() {
        assertEquals(
            setOf(
                "textFontSize",
                "codeFontSize",
                "terminalFontSize",
                "appearance",
                "language",
                "transcriptView",
                "collapseTiming",
                "developerTools",
                "performanceUsage",
                "busyEnterMode",
                "chat.background.keepalive",
                "textFontFamily",
                "codeFontFamily",
                "terminalFontFamily",
                "phone-dsh.sidebar.collapsed-workspaces",
            ),
            PreferenceStore.ALL_KEYS,
        )
        // The file name is one constant; two features cannot drift to two files.
        assertEquals("phone-dsh.preferences", PreferenceStore.FILE_NAME)
        // The three font roles read the same keys the baseline does.
        assertEquals(
            setOf("textFontSize", "codeFontSize", "terminalFontSize"),
            FontRole.entries.map { it.key }.toSet(),
        )
    }

    // -----------------------------------------------------------------------
    // Range and fallback behaviour
    // -----------------------------------------------------------------------

    @Test
    fun aFontSizeIsClampedToTheBaselinesRange() {
        val store = PreferenceStore(MapPreferenceFile())

        store.setFontSize(FontRole.TEXT, 99)
        assertEquals(22, store.snapshot().textFontSize)

        store.setFontSize(FontRole.TEXT, 1)
        assertEquals(10, store.snapshot().textFontSize)

        store.setFontSize(FontRole.CODE, 99)
        assertEquals(16, store.snapshot().codeFontSize)

        store.setFontSize(FontRole.TERMINAL, 0)
        assertEquals(10, store.snapshot().terminalFontSize)
    }

    @Test
    fun aStoredSizeOutsideTheRangeIsClampedOnRead() {
        // Written by a build whose range was wider; the value is still "the
        // user's size", so it clamps instead of silently reverting to default.
        val store = PreferenceStore(
            MapPreferenceFile(mapOf(PreferenceStore.TEXT_FONT_SIZE_KEY to 40)),
        )

        assertEquals(22, store.snapshot().textFontSize)
    }

    @Test
    fun anUnknownEnumIdFallsBackToTheDefaultAndStaysOnDisk() {
        val file = MapPreferenceFile(
            mapOf(
                PreferenceStore.APPEARANCE_KEY to "solarized",
                PreferenceStore.LANGUAGE_KEY to "fr",
                PreferenceStore.BUSY_ENTER_KEY to "broadcast",
            ),
        )
        val store = PreferenceStore(file)

        assertEquals(SettingsAppearance.SYSTEM, store.snapshot().appearance)
        assertEquals(SettingsLanguage.SYSTEM, store.snapshot().language)
        assertEquals(BusyEnterMode.QUEUE, store.snapshot().busyEnterMode)
        // Not deleted: the build that understands the value still finds it.
        assertEquals("solarized", file.values[PreferenceStore.APPEARANCE_KEY])
    }

    @Test
    fun theLegacyBusyEnterKeyIsReadWithoutAnInitializationWrite() {
        val file = MapPreferenceFile(
            mapOf(PreferenceStore.LEGACY_BUSY_ENTER_KEY to BusyEnterMode.STEER.id),
        )

        val store = PreferenceStore(file)

        assertEquals(BusyEnterMode.STEER, store.snapshot().busyEnterMode)
        assertFalse(file.values.containsKey(PreferenceStore.BUSY_ENTER_KEY))
        assertEquals(BusyEnterMode.STEER.id, file.values[PreferenceStore.LEGACY_BUSY_ENTER_KEY])
    }

    @Test
    fun aStoredBusyEnterChoiceWinsOverTheLegacyKey() {
        val file = MapPreferenceFile(
            mapOf(
                PreferenceStore.LEGACY_BUSY_ENTER_KEY to BusyEnterMode.STEER.id,
                PreferenceStore.BUSY_ENTER_KEY to BusyEnterMode.QUEUE.id,
            ),
        )

        assertEquals(BusyEnterMode.QUEUE, PreferenceStore(file).snapshot().busyEnterMode)
    }

    @Test
    fun confirmedPreferenceReceiptUsesCommitAndReadbackBeforePublishing() = runBlocking {
        val file = MapPreferenceFile()
        val store = PreferenceStore(file)
        val receipt = store.writeConfirmed(
            com.phonedsh.ui.state.StateRequestId("appearance-1"),
            ConfirmedPreferenceChange.Appearance(SettingsAppearance.DARK),
        )
        assertEquals(PreferenceWriteOutcome.Persisted, receipt.outcome)
        assertEquals("dark", file.values[PreferenceStore.APPEARANCE_KEY])
        assertEquals(SettingsAppearance.DARK, PreferenceStore(file).snapshot().appearance)
        assertEquals(SettingsAppearance.DARK, store.snapshot().appearance)
    }

    @Test
    fun failedConfirmedCommitDoesNotPublishOptimisticState() = runBlocking {
        val file = MapPreferenceFile().apply { failCommits = true }
        val store = PreferenceStore(file)
        val receipt = store.writeConfirmed(
            com.phonedsh.ui.state.StateRequestId("appearance-fail"),
            ConfirmedPreferenceChange.Appearance(SettingsAppearance.DARK),
        )
        assertTrue(receipt.outcome is PreferenceWriteOutcome.Failed)
        assertEquals(SettingsAppearance.SYSTEM, store.snapshot().appearance)
    }

    // -----------------------------------------------------------------------
    // The write vocabulary the pages hand over
    // -----------------------------------------------------------------------

    /** One row the pages can write, with the option a test sends. */
    private data class ApplyCase(
        val rowId: String,
        val optionId: String,
        val read: (Preferences) -> Any?,
    )

    @Test
    fun everyWritableSettingsRowIdReachesTheStore() {
        val cases = listOf(
            ApplyCase(SettingsScreenState.LANGUAGE_ROW_ID, SettingsLanguage.EN.id) { it.language },
            ApplyCase(SettingsScreenState.APPEARANCE_ROW_ID, SettingsAppearance.DARK.id) { it.appearance },
            ApplyCase(
                SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID,
                TranscriptViewMode.STANDARD.id,
            ) { it.transcriptView },
            ApplyCase(
                SettingsScreenState.COLLAPSE_TIMING_ROW_ID,
                CollapseTiming.NEXT_INPUT.id,
            ) { it.collapseTiming },
            ApplyCase(
                SettingsScreenState.PERFORMANCE_ROW_ID,
                PerformanceUsage.COMPACT.id,
            ) { it.performanceUsage },
            ApplyCase(SettingsScreenState.TEXT_FONT_SIZE_ROW_ID, "20") { it.textFontSize },
            ApplyCase(SettingsScreenState.CODE_FONT_SIZE_ROW_ID, "12") { it.codeFontSize },
            ApplyCase(SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID, "18") { it.terminalFontSize },
        )

        for (case in cases) {
            val file = MapPreferenceFile()
            val store = PreferenceStore(file)
            assertTrue("${case.rowId} was refused by the store", store.apply(case.rowId, case.optionId))
            val restarted = PreferenceStore(file).snapshot()
            assertEquals(
                "${case.rowId} did not persist",
                case.read(store.snapshot()),
                case.read(restarted),
            )
        }
    }

    @Test
    fun anUnknownRowOrUnparsableOptionIsRefused() {
        val store = PreferenceStore(MapPreferenceFile())

        assertFalse(store.apply("preference.unknown", "x"))
        assertFalse(store.apply(SettingsScreenState.APPEARANCE_ROW_ID, "solarized"))
        assertFalse(store.apply(SettingsScreenState.CODE_FONT_SIZE_ROW_ID, "big"))
        assertEquals(SettingsAppearance.SYSTEM, store.snapshot().appearance)
        assertEquals(14, store.snapshot().codeFontSize)
    }

    // -----------------------------------------------------------------------
    // The facts mapping and the two behaviour helpers
    // -----------------------------------------------------------------------

    @Test
    fun theSettingsFactReportsEveryStoredValue() {
        val store = PreferenceStore(MapPreferenceFile())
        store.setLanguage(SettingsLanguage.EN)
        store.setAppearance(SettingsAppearance.LIGHT)
        store.setFontSize(FontRole.TEXT, 19)
        store.setFontSize(FontRole.CODE, 12)
        store.setFontSize(FontRole.TERMINAL, 15)
        store.setTranscriptView(TranscriptViewMode.VERBOSE)
        store.setCollapseTiming(CollapseTiming.NEXT_INPUT)
        store.setDeveloperTools(false)
        store.setPerformanceUsage(PerformanceUsage.COMPACT)

        val facts = store.snapshot().toSettingsPreferences()

        assertEquals(SettingsLanguage.EN, facts.language)
        assertEquals(SettingsAppearance.LIGHT, facts.appearance)
        assertEquals(19, facts.fontSizeConversation)
        assertEquals(12, facts.fontSizeCode)
        assertEquals(15, facts.fontSizeTerminal)
        assertEquals(TranscriptViewMode.VERBOSE, facts.transcriptView)
        assertEquals(CollapseTiming.NEXT_INPUT, facts.collapseTiming)
        assertEquals(FactState.NO, facts.developerTools)
        assertEquals(PerformanceUsage.COMPACT, facts.performanceUsage)
        // This app stores no shortcut overrides; the page renders the row's
        // 编辑 affordance from null rather than from an invented count.
        assertNull(facts.shortcutCount)
    }

    @Test
    fun darkThemeFollowsTheStoredChoiceAndTheSystemForSystem() {
        val store = PreferenceStore(MapPreferenceFile())

        store.setAppearance(SettingsAppearance.DARK)
        assertTrue(store.snapshot().darkTheme(systemDark = false))

        store.setAppearance(SettingsAppearance.LIGHT)
        assertFalse(store.snapshot().darkTheme(systemDark = true))

        store.setAppearance(SettingsAppearance.SYSTEM)
        assertTrue(store.snapshot().darkTheme(systemDark = true))
        assertFalse(store.snapshot().darkTheme(systemDark = false))
    }

    /**
     * The in-memory `PreferenceFile`: the same map survives both store instances,
     * which is this suite's stand-in for the process.
     */
    private class MapPreferenceFile(
        initial: Map<String, Any> = emptyMap(),
    ) : PreferenceFile {
        val values: MutableMap<String, Any> = LinkedHashMap(initial)
        var failCommits: Boolean = false

        override fun string(key: String): String? = values[key] as? String

        override fun integer(key: String): Int? = values[key] as? Int

        override fun boolean(key: String): Boolean? = values[key] as? Boolean

        override fun stringSet(key: String): Set<String>? = (values[key] as? Set<*>)?.filterIsInstance<String>()?.toSet()

        override fun putString(key: String, value: String): Boolean {
            values[key] = value
            return true
        }

        override fun putInt(key: String, value: Int): Boolean {
            values[key] = value
            return true
        }

        override fun putBoolean(key: String, value: Boolean): Boolean {
            values[key] = value
            return true
        }

        override fun putStringSet(key: String, value: Set<String>): Boolean {
            values[key] = value.toSet()
            return true
        }

        override fun commitString(key: String, value: String): Boolean = if (failCommits) false else putString(key, value)
        override fun commitInt(key: String, value: Int): Boolean = if (failCommits) false else putInt(key, value)
        override fun commitBoolean(key: String, value: Boolean): Boolean = if (failCommits) false else putBoolean(key, value)
        override fun commitStringSet(key: String, value: Set<String>): Boolean = if (failCommits) false else putStringSet(key, value)

        override fun remove(key: String) {
            values.remove(key)
        }
    }
}
