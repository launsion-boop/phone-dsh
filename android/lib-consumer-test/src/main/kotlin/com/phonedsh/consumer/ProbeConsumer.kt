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
import com.phonedsh.ui.nav.BackCoordinator
import com.phonedsh.ui.nav.HomeTab
import com.phonedsh.ui.nav.PdshBackLevel
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.nav.PushBackState
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenBackLayer
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
        // `interaction.md` §4: `PushBackState` owns the layered chain and the
        // per-tab depth; the route stack is the rendered half. They move as one
        // value here, exactly like the app shell does.
        var pushBack by remember { mutableStateOf(PushBackState()) }
        val facts: PdshNavFacts = remember { PdshNavFacts() }
        // The measurement is a projection, not a write: `measured` re-reads the
        // platform observation on every composition and returns the same value
        // when nothing new arrived.
        val shownFacts: PdshNavFacts = PredictiveBack.measured(facts)
        // The route's own inner level is the STACK delegate: it gets the first
        // refusal, and when it has nothing to leave the coordinator pops the
        // mirrored depth below. A second callback is never registered — the
        // coordinator's callback is the one system-back path.
        val backLevel = remember { PdshBackLevel() }
        val stackBackLayer = remember(backLevel) {
            observingBackLayer(TokenBackLayer.STACK) { backLevel.consume() }
        }

        fun mirrorDepth() {
            val depth = nav.stack.size - 1
            pushBack = pushBack.copy(
                selectedTab = HomeTab.TASKS,
                stackDepths = if (depth == 0) emptyMap() else mapOf(HomeTab.TASKS to depth),
            )
        }

        // At the root the coordinator registers nothing (no layer can consume),
        // so the platform's default finish and back-to-home animation stay in
        // charge — the documented "back at the start of the task" behaviour.
        BackCoordinator(
            state = pushBack,
            onStateChange = { next ->
                repeat((pushBack.depth - next.depth).coerceAtLeast(0)) { nav = nav.pop() }
                pushBack = next
            },
            layers = remember(stackBackLayer) { listOf(stackBackLayer) },
        )

        PdshNavHost(
            nav = nav,
            facts = shownFacts,
            onNavigate = { route ->
                nav = nav.push(route)
                mirrorDepth()
            },
            onBack = {
                nav = nav.pop()
                mirrorDepth()
            },
            onHome = {
                nav = nav.popToHome()
                pushBack = PushBackState()
            },
            // A gesture this host cannot complete. A real host performs the engine
            // stop/start here; a consumer with no engine must still compile and must
            // not pretend the write happened.
            onHostAction = { },
            // The inner-level back chain above; omit it (default null) and a
            // settings sub-page or a folder drill-down would lose its own back step.
            backLevel = backLevel,
            home = {
                HomeFace(onOpenSessions = {
                    nav = nav.push(PdshRoute.Sessions)
                    mirrorDepth()
                })
            },
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
