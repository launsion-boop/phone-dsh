// phone-dsh — :engine / com.phonedsh.engine: shared JVM test seams.
// SPDX-License-Identifier: MIT
//
// No android.* here on purpose: every test in this source set runs on the plain
// JVM, which is also why the WebView half of :engine is verified by the
// instrumented test instead (see WebViewEngineInstrumentedTest).

package com.phonedsh.engine

import java.util.concurrent.CopyOnWriteArrayList

/** An [EngineLogger] that keeps every line, for assertions on evidence lines. */
class RecordingEngineLogger : EngineLogger {
    private val entries = CopyOnWriteArrayList<String>()

    val lines: List<String> get() = entries.toList()

    override fun log(level: EngineLogLevel, message: String) {
        entries += "[$level] $message"
    }

    fun contains(fragment: String): Boolean = lines.any { it.contains(fragment) }
}
