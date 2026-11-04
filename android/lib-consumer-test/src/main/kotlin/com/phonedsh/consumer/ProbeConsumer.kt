// SPDX-License-Identifier: MIT
// The one consumer source: a Compose screen built only out of the AAR's public
// surface. It is compiled by `:lib-consumer-test:assembleDebug`, and its job is
// to be the smallest program that would break if the artifact stopped being
// consumable.
//
// It deliberately does *not* reach for `:dsh`, `:domain` or any other sibling
// module: those are separate Maven artifacts (transitive POM entries), not part
// of classes.jar, and a consumer that is handed only the AAR file must be able
// to compile against it. If a line below needs a class the AAR does not ship,
// that is the finding — not something to patch with a project dependency.
package com.phonedsh.consumer

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.verticalScroll
import com.phonedsh.ui.nav.PdshBackLevel
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.surface.MarkdownBody

/**
 * The consumer's whole integration: three public types, one theme wrapper and
 * one composable.
 *
 * `PdshTheme` is not decoration and not optional. Every page reads
 * `PdshThemeValues.tokens`, whose CompositionLocal default is
 * `error("PdshTheme is missing")`: a host that renders [PdshNavHost] outside the
 * wrapper compiles and then crashes on the first route. There is no default
 * theme, and the library deliberately does not wrap itself — the host decides
 * dark/light for its own chrome and the SDK must not fight it.
 *
 * `PdshNavFacts()` with no arguments is the "host read nothing" snapshot: every
 * field defaults to the honest 未知 / EMPTY value, so a host that has not wired
 * a read yet compiles today and renders honestly instead of fabricating a zero.
 * (There is no `PdshNavFacts.unknown()` factory; the default constructor is the
 * unknown entry point.)
 */
@Composable
public fun ProbeConsumer() {
    PdshTheme {
        var nav by remember { mutableStateOf(PdshNavState()) }
        val facts: PdshNavFacts = remember { PdshNavFacts() }
        // The measurement is a projection, not a write: `measured` re-reads the
        // platform observation on every composition and returns the same value
        // when nothing new arrived.
        val shownFacts: PdshNavFacts = PredictiveBack.measured(facts)
        // The back chain: the top route's own inner level first, then the route
        // stack. At the root no callback is registered, so the platform's default
        // (finish the Activity) runs — the documented "back at the start of the
        // task" behaviour, and the one the predictive back-to-home animation is
        // attached to. `PdshBackHandler` is the reference implementation from
        // docs/design/android-aar-consumer-api-2026-11-02.md §5.2 (compiled here
        // so the doc cannot drift); `:lib` itself ships only `PdshBackLevel`.
        val backLevel = remember { PdshBackLevel() }
        PdshBackHandler(enabled = backLevel.available || nav.canGoBack) {
            if (!backLevel.consume()) nav = nav.pop()
        }

        PdshNavHost(
            nav = nav,
            facts = shownFacts,
            onNavigate = { route -> nav = nav.push(route) },
            onBack = { nav = nav.pop() },
            onHome = { nav = nav.popToHome() },
            // A gesture this host cannot complete. A real host performs the engine
            // stop/start here; a consumer with no engine must still compile and must
            // not pretend the write happened.
            onHostAction = { },
            // The inner-level back chain above; omit it (default null) and a
            // settings sub-page or a folder drill-down would lose its own back step.
            backLevel = backLevel,
            home = { HomeFace(onOpenSessions = { nav = nav.push(PdshRoute.Sessions) }) },
            webSurface = { Text("the host owns the WebView; this is the fallback face") },
        )
    }
}

/**
 * Intent-driven fixture for the minified published-coordinate consumer. This
 * is probe-only: it uses synthetic math, makes no provider/model request and
 * exercises the SDK's public MarkdownBody through the release AAR.
 */
@Composable
internal fun ReleaseMathProbe() {
    val fraction = "\\frac{a_1+b}{\\sqrt{x+1}}"
    val root = "\\sqrt{a^2+b^2}"
    val inlineMatrix = "\\begin{bmatrix}a&b\\\\c&d\\end{bmatrix}"
    val displayMatrix = "\\begin{bmatrix}x_1&x_2\\\\y_1&y_2\\end{bmatrix}"
    val markdown = buildString {
        append("Synthetic minified release consumer fixture. No provider or model is contacted.\n\n")
        append("Inline fraction: $").append(fraction).append("$; root: $").append(root)
            .append("$; matrix: $").append(inlineMatrix).append("$.\n\n")
        append("Display matrix:\n\n$$\n").append(displayMatrix).append("\n$$")
    }
    PdshTheme(darkTheme = false) {
        Column(
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        ) {
            Text("Synthetic release math fixture")
            MarkdownBody(markdown = markdown)
        }
    }
}

/** The consumer's own root face, rendered for [PdshRoute.Home]. */
@Composable
private fun HomeFace(onOpenSessions: () -> Unit) {
    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Text("PDSH AAR consumer probe")
        Text("The routes below are rendered by the library, not by this app.")
        Button(onClick = onOpenSessions) { Text("Sessions") }
    }
}
