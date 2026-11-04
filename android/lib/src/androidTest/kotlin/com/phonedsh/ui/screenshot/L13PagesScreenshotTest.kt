// The three L13 pages, captured from frozen sample states.
// SPDX-License-Identifier: MIT
//
// Why this suite exists: `PageScreenshotTest` captures the pages that already
// had baselines, and the L13 pages landed afterwards. The states here are the
// pages' *reported* faces (a host that read values), which is what a human
// compares against the iOS shots; the read-only / unknown faces are covered by
// the JVM tests instead, so one PNG per page is enough for the evidence.
//
// The frame is the harness's gate profile (1080x2400 @ 420 dpi), asserted before
// every capture: the sample states are pure values, so a capture is reproducible.
package com.phonedsh.ui.screenshot

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.page.ChatPreferencesFacts
import com.phonedsh.ui.page.ChatPreferencesPage
import com.phonedsh.ui.page.ChatPreferencesScreenState
import com.phonedsh.ui.page.ChatShortcut
import com.phonedsh.ui.page.ChatShortcutAction
import com.phonedsh.ui.page.CollapseTiming
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.NativeSettingsDocumentPage
import com.phonedsh.ui.page.NativeShortcutsFacts
import com.phonedsh.ui.page.NativeShortcutsPage
import com.phonedsh.ui.page.NativeShortcutsScreenState
import com.phonedsh.ui.page.SettingsAppearance
import com.phonedsh.ui.page.SettingsDocumentFacts
import com.phonedsh.ui.page.SettingsDocumentScreenState
import com.phonedsh.ui.page.TranscriptViewMode
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class L13PagesScreenshotTest : ScreenshotTestBase() {

    /**
     * The gate frame is the sample frame; `android-only` is the same frame with its
     * own baseline directory (these pages have no iOS counterpart, so they must not
     * grow the 11 historical gate baselines).
     */
    override val allowedProfiles: Set<ScreenshotProfile> =
        setOf(ScreenshotProfile.GATE, ScreenshotProfile.ANDROID_ONLY)

    @Test
    fun chatPreferences() {
        setCapturedContent {
            ChatPreferencesPage(
                state = ChatPreferencesScreenState.from(
                    ChatPreferencesFacts(
                        appearance = SettingsAppearance.SYSTEM,
                        textFontSize = 17,
                        codeFontSize = 14,
                        collapseTiming = CollapseTiming.COMPLETION,
                        transcriptView = TranscriptViewMode.DETAILED,
                        writable = FactState.YES,
                    ),
                ),
                onSelectAppearance = {},
                onSelectCollapseTiming = {},
                onSelectTranscriptView = {},
                onSetTextFontSize = {},
                onSetCodeFontSize = {},
                onDone = {},
            )
        }
        capture("l13-chat-preferences")
    }

    @Test
    fun settingsDocument() {
        setCapturedContent {
            NativeSettingsDocumentPage(
                state = SettingsDocumentScreenState.from(
                    SettingsDocumentFacts(document = REDACTED_DOCUMENT),
                    shareAvailable = true,
                ),
                onShare = {},
                onDone = {},
            )
        }
        capture("l13-settings-document")
    }

    @Test
    fun shortcuts() {
        setCapturedContent {
            NativeShortcutsPage(
                state = NativeShortcutsScreenState.from(
                    NativeShortcutsFacts(
                        overrides = mapOf(
                            ChatShortcutAction.STOP to ChatShortcut(key = "escape", shift = true),
                        ),
                        writable = FactState.YES,
                    ),
                ),
                onResetAll = {},
                onBack = {},
            )
        }
        capture("l13-shortcuts")
    }

    private companion object {
        /**
         * The redacted document shape: namespace → field, plus the revision the
         * baseline's note promises. No secret and no local path appears, which is
         * the point of the copy above it.
         */
        val REDACTED_DOCUMENT: String = """
            {
              "revision": 7,
              "namespaces": {
                "agent-loop": { "maxTurns": 12, "autoContinue": false },
                "bash-sandbox": { "sandbox": "on", "network": "allowlist" },
                "subagent": { "enabled": true, "model": "default" },
                "web-search": { "enabled": false, "backend": "follow-model" }
              }
            }
        """.trimIndent()
    }
}
