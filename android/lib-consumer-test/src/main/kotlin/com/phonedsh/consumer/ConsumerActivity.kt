// SPDX-License-Identifier: MIT
// The consumer app's entry point: the lifecycle the AAR expects a host to own.
//
// The library is a Compose surface, not an Activity: it ships no
// `ComponentActivity`, no `setContent` and no system-back callback. A host that
// embeds it must provide all three, which is what this file is — and why it is
// short. See docs/design/android-aar-consumer-api-2026-11-02.md §3.
package com.phonedsh.consumer

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

/** The host Activity: one `setContent`, nothing else. */
public class ConsumerActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val showMathFixture = intent?.getBooleanExtra(EXTRA_RATEX_RELEASE_FIXTURE, false) == true
        setContent {
            if (showMathFixture) ReleaseMathProbe() else ProbeConsumer()
        }
    }

    private companion object {
        /** Private probe-only entry point; it is not a product app or library API. */
        const val EXTRA_RATEX_RELEASE_FIXTURE: String = "com.phonedsh.consumer.EXTRA_RATEX_RELEASE_FIXTURE"
    }
}
