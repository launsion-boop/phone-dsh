// phone-dsh — :engine / com.phonedsh.engine: the seam :app binds to.
// SPDX-License-Identifier: MIT
//
// :app compiles against this file and the createDemoEngine factory only: no
// android.webkit type, no WebView, no WebSettings. That keeps the single-WebView
// invariant of the plan (§6.3-5) enforceable inside :engine: a UI lane cannot
// construct a second WebView because it never sees the class. [DemoEngine.view]
// hands the one live page out as a plain android.view.View, which is all a host
// needs to attach it; [WebViewEngine] asserts the invariant where the view is
// actually created.
//
// ---- the value types are the :platform SPI, not copies ---------------------
// [EngineState], [ChannelStatus] and [HandshakeSummary] are type aliases for
// platform/EngineHost.kt, so :dsh can hold an EngineHost and read these values
// without linking this module. Kotlin type aliases cannot qualify nested types,
// so engine sources name the sealed variants (EngineHostState.Stopped, ...)
// directly; the aliases keep every type position — and :app's imports — working.

package com.phonedsh.engine

import android.view.View
import com.phonedsh.platform.EngineHost

/** The one WebView host lifecycle, exactly as the :platform EngineHost SPI defines it. */
typealias EngineState = com.phonedsh.platform.EngineHostState

/** The one channel's counters and safe last error, as the :platform SPI defines them. */
typealias ChannelStatus = com.phonedsh.platform.EngineChannelStatus

/** The merged HELLO summary, as the :platform SPI defines it. */
typealias HandshakeSummary = com.phonedsh.platform.EngineHandshake

/**
 * What the host may call.
 *
 * The lifecycle, channel and handshake members are exactly [EngineHost]; [view]
 * is the one Android-side read the demo screen needs to show the page.
 *
 * [start] and [stop] may be called from any thread, are safe to repeat and are
 * asynchronous: [state] is the only lifecycle truth. `start()` is ignored while
 * Starting, Running or Recovering; `stop()` is idempotent.
 */
interface DemoEngine : EngineHost {
    /**
     * The one live page as a plain [View], or null before `start()` and once
     * `stop()` has completed.
     *
     * The view is owned by the engine: attach it to exactly one parent (for
     * example `AndroidView`) and drop it when it returns null. A renderer death
     * or a `stop()` destroys the instance it came from, and a destroyed WebView
     * is never reloaded or reattached — the engine builds a fresh one instead.
     */
    fun view(): View?
    /**
     * The last measured WebView kernel (provider, engine version, runtime
     * features), or `null` before the first page finished.
     *
     * A host that renders "特性探测" must read this instead of comparing a
     * versionName: the report is the engine's own answer to what it supports
     * (see [WebViewKernelReport]). The default keeps hosts that predate the probe
     * compiling, and is honest: `null` means "not measured", never "supported".
     */
    fun kernelReport(): WebViewKernelReport? = null
}
