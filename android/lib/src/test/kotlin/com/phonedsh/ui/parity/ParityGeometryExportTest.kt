// SPDX-License-Identifier: MIT
//
// W1-05 parity bench: export element geometry from the *real* Compose pages,
// driven by the shared JSON fixtures under scripts/parity/fixtures/.
//
// Why the JVM/Robolectric path and not an instrumented variant: the pages are
// pure composables whose ScreenState comes from a fixture (no engine, no host
// socket), and `:lib` already runs its Compose interaction tests this way
// (`createComposeRule` + Robolectric). Geometry is read from the Compose
// semantics tree, which is the same tree an instrumented test would read; the
// one thing Robolectric cannot measure is real glyph rasterisation, and this
// bench deliberately compares frames and line counts, not pixels. There is
// therefore no instrumented exporter in v0.
//
// Text layout is read through `SemanticsActions.GetTextLayoutResult`, not
// estimated from a frame height. A node that exposes no layout on one side is
// exported as `lines: null`; the comparator reports that instead of guessing.
package com.phonedsh.ui.parity

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performGesture
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.nav.HomeDrawer
import com.phonedsh.ui.nav.HomeDrawerEngineState
import com.phonedsh.ui.nav.HomeDrawerFacts
import com.phonedsh.ui.nav.HomeTab
import com.phonedsh.ui.nav.HomeTabBar
import com.phonedsh.ui.nav.HomeTabBarTags
import com.phonedsh.ui.page.ChatPage
import com.phonedsh.ui.page.SettingsPage
import com.phonedsh.ui.page.SettingsPageMode
import com.phonedsh.ui.page.SettingsScreenState
import com.phonedsh.ui.page.SettingsFacts
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.state.ChatHostFacts
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.EngineLifecycleFacts
import com.phonedsh.ui.theme.PdshTheme
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File
import java.time.OffsetDateTime

/** The iOS fixture's measured home-indicator band (`UiMetrics` records the same 34 pt bottom safe area). */
private const val PARITY_HOME_INDICATOR_BOTTOM_PT: Float = 34f

@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], qualifiers = "w402dp-h874dp")
class ParityGeometryExportTest {
    @get:Rule
    val compose = createComposeRule()

    private val repoRoot: File by lazy {
        val configured = System.getProperty("pdsh.repo.root")
        require(!configured.isNullOrBlank()) {
            "pdsh.repo.root is required; the Gradle test task supplies the repository root"
        }
        File(configured)
    }

    private val fixtureDir: File by lazy { File(repoRoot, "scripts/parity/fixtures") }

    private val outputDir: File by lazy {
        val configured = System.getenv("PDSH_PARITY_OUT")
        if (configured.isNullOrBlank()) File(repoRoot, "build/parity/android")
        else File(configured)
    }

    @Test
    fun `fixtures are the shared v0 format and cover the three bench screens`() {
        val fixtures = fixtureDir.listFiles { file -> file.isFile && file.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }
        assertEquals(
            "scripts/parity/fixtures must start with chat empty, drawer open and settings root",
            listOf("chat-empty.json", "session-drawer-open.json", "settings-root.json"),
            fixtures.map { it.name },
        )
        val ids = fixtures.map { readFixture(it).getString("id") }
        assertEquals(listOf("chat-empty", "session-drawer-open", "settings-root"), ids)
        fixtures.forEach { file ->
            val fixture = readFixture(file)
            assertEquals("pdsh.parity.fixture.v0", fixture.getString("schema"))
            assertEquals("pt", fixture.getString("unit"))
            assertTrue("${file.name}: origin is empty", fixture.getString("origin").isNotEmpty())
            assertTrue("${file.name}: no elements", fixture.getJSONArray("elements").length() > 0)
        }
    }

    @Test
    fun `chat empty capture frame reserves one status band and mounts shell chrome`() {
        val fixture = mountFixture("chat-empty")
        val title = compose.onNodeWithTag(UiPageTags.CHAT_HEADER_TITLE, useUnmergedTree = true)
            .getBoundsInRoot()
        assertEquals(
            "one status band: the page's own status bar plus the frame's top-up",
            SettingsMetrics.PARITY_SAFE_AREA_TOP_PT + HomeMetrics.NAV_TOP_PT,
            title.top.value,
            0.1f,
        )
        val bar = compose.onNodeWithTag(HomeTabBarTags.BAR, useUnmergedTree = true).getBoundsInRoot()
        val frameHeight = fixture.getJSONObject("frame").getInt("heightPt").toFloat()
        assertEquals(
            "the page ends on the shell menu, not at the screen bottom",
            frameHeight - PARITY_HOME_INDICATOR_BOTTOM_PT - HomeMetrics.TAB_BAR_HEIGHT_PT,
            bar.top.value,
            0.1f,
        )
        assertEquals(HomeMetrics.TAB_BAR_HEIGHT_PT, bar.bottom.value - bar.top.value, 0.1f)
        assertEquals(frameHeight - PARITY_HOME_INDICATOR_BOTTOM_PT, bar.bottom.value, 0.1f)
    }

    @Test
    fun `settings preview capture keeps the status band without the shell menu`() {
        mountFixture("settings-root")
        val done = compose.onNodeWithTag(UiPageTags.SETTINGS_DONE, useUnmergedTree = true)
            .getBoundsInRoot()
        assertEquals(SettingsMetrics.PARITY_SAFE_AREA_TOP_PT, done.top.value, 0.1f)
        assertTrue(
            "the settings fixture is iOS's full-screen -uiPreview cover, not a tab page",
            compose.onAllNodes(hasTestTag(HomeTabBarTags.BAR), useUnmergedTree = true)
                .fetchSemanticsNodes().isEmpty(),
        )
    }

    @Test
    fun `chat empty exports real Compose semantics`() {
        exportFixture("chat-empty")
    }

    @Test
    fun `session drawer open is driven by the real header button`() {
        exportFixture("session-drawer-open")
    }

    @Test
    fun `settings root exports real Compose semantics`() {
        exportFixture("settings-root")
    }

    private fun readFixture(file: File): JSONObject {
        assertTrue("missing fixture: ${file.path}", file.isFile)
        return JSONObject(file.readText(Charsets.UTF_8))
    }

    private fun fixturePath(id: String): File = File(fixtureDir, "$id.json")

    private fun exportFixture(id: String) {
        val fixture = mountFixture(id)
        val export = buildExport(fixture)
        outputDir.mkdirs()
        val target = File(outputDir, "${fixture.getString("id")}.json")
        target.writeText(export.toString(2) + "\n", Charsets.UTF_8)
        println("parity geometry: wrote ${target.path}")
    }

    private fun mountFixture(id: String): JSONObject {
        val fixture = readFixture(fixturePath(id))
        currentFixture = fixture
        val screen = fixture.getJSONObject("seed").getJSONObject("android").getString("screen")
        compose.setContent {
            PdshTheme {
                ParityCaptureFrame(showTabBar = fixture.getString("page") != "settings") {
                    ParityHost(screen)
                }
            }
        }
        compose.waitForIdle()

        val actions = fixture.getJSONArray("actions")
        for (index in 0 until actions.length()) {
            runAction(actions.getJSONObject(index))
        }
        // HomeDrawer animates 280 ms open; let the real animation settle before
        // reading frames. This is the production motion, not a test sleep.
        compose.mainClock.advanceTimeBy(400L)
        compose.waitForIdle()
        return fixture
    }

    /**
     * The iOS capture frame: exactly one measured 62 pt status band and the
     * shell's bottom chrome, not a second inset on top of the page's own one.
     *
     * iOS lays the page inside the status band (the page header adds its own
     * 8 pt nav top below it) and above the shell's bottom menu; the menu is
     * 50 pt of content plus the measured 34 pt home-indicator area of the
     * 402 x 874 fixture frame. Robolectric reports a 56 dp status bar and a
     * 0 dp navigation bar, so the frame supplies only the
     * missing 6 pt of the status band and the 34 pt home-indicator area. The
     * page keeps its production `statusBarsPadding()`; this frame never
     * reserves the full band a second time.
     *
     * `showTabBar` is false for the settings fixture because iOS exports that
     * page through `-uiPreview settings`, a full-screen cover with no bottom
     * menu. The tab bar is the shell's real [HomeTabBar].
     */
    @Composable
    private fun ParityCaptureFrame(
        showTabBar: Boolean,
        content: @Composable () -> Unit,
    ) {
        val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        val topUp = (SettingsMetrics.PARITY_SAFE_AREA_TOP_PT.dp - statusBarTop)
            .coerceAtLeast(0.dp)
        val navigationBarBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        val homeIndicator = (PARITY_HOME_INDICATOR_BOTTOM_PT.dp - navigationBarBottom)
            .coerceAtLeast(0.dp)
        Column(Modifier.fillMaxSize().background(Color.White)) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .background(Color.White)
                    // The bar paints the navigation-bar inset itself, so the
                    // page above it must not pad for it a second time. This is
                    // the production shell's consumeWindowInsets rule.
                    .then(
                        if (showTabBar) Modifier.consumeWindowInsets(WindowInsets.navigationBars)
                        else Modifier,
                    )
                    .padding(top = topUp),
            ) {
                content()
            }
            if (showTabBar) {
                HomeTabBar(selection = HomeTab.TASKS, onSelect = {})
            }
            Spacer(Modifier.fillMaxWidth().height(homeIndicator).background(Color.White))
        }
    }

    @Composable
    private fun ParityHost(screen: String) {
        var drawerOpen by remember { mutableStateOf(false) }
        val chatState = remember {
            ChatScreenState.from(
                emptyList(),
                host = ChatHostFacts(
                    engineStarted = false,
                    lifecycle = EngineLifecycleFacts(canStartBySending = true),
                ),
            )
        }
        when (screen) {
            "chat" -> ChatPage(
                state = chatState,
                onDraftChange = {},
                onSend = {},
                onStop = {},
                onToggleRow = {},
                onApprove = {},
                onDeny = {},
                onDismissBanner = {},
                onRetry = {},
                onOpenSessions = { drawerOpen = true },
            )
            "settings" -> SettingsPage(
                state = SettingsScreenState.from(SettingsFacts()),
                onNavigate = {},
                onToggleBackgroundKeepAlive = {},
                onSelectBusyEnterMode = {},
                onBack = {},
                mode = SettingsPageMode.SHEET,
            )
            else -> error("unknown fixture screen '$screen'")
        }
        if (drawerOpen) {
            HomeDrawer(
                facts = HomeDrawerFacts(
                    folders = emptyList(),
                    unassignedSessions = emptyList(),
                    engine = HomeDrawerEngineState.STOPPED,
                    newSessionBlockedReason = "引擎未启动",
                ),
                onClose = { drawerOpen = false },
                isOpen = true,
                onCreateSession = null,
            )
        }
    }

    private fun runAction(action: JSONObject) {
        val type = action.getString("action")
        val elementId = action.getString("element")
        val element = fixtureElement(elementId)
        val tag = element.getJSONObject("android").getString("testTag")
        when (type) {
            "tap" -> compose.onNodeWithTag(tag, useUnmergedTree = true).performClick()
            "type" -> compose.onNodeWithTag(tag, useUnmergedTree = true)
                .performTextInput(action.optString("text", ""))
            "long_press" -> compose.onNodeWithTag(tag, useUnmergedTree = true)
                .performGesture { longClick() }
            "wait" -> compose.waitUntil(timeoutMillis = action.optLong("timeoutMillis", 10_000)) {
                compose.onAllNodes(hasTestTag(tag), useUnmergedTree = true)
                    .fetchSemanticsNodes().isNotEmpty()
            }
            else -> error("unknown fixture action '$type'")
        }
        compose.waitForIdle()
    }

    private fun fixtureElement(elementId: String): JSONObject {
        val elements = currentFixture.getJSONArray("elements")
        for (index in 0 until elements.length()) {
            val element = elements.getJSONObject(index)
            if (element.getString("id") == elementId) return element
        }
        error("fixture action names an element that is not in elements: $elementId")
    }

    private var currentFixture: JSONObject = JSONObject()

    private fun buildExport(fixture: JSONObject): JSONObject {
        currentFixture = fixture
        val elements = fixture.getJSONArray("elements")
        val originId = fixture.getString("origin")
        val originNode = nodeForElement(elements, originId)
        val density = compose.density.density
        val originFrame = originNode?.let { frameOf(it, density) }

        val export = JSONObject()
        export.put("schema", "pdsh.parity.geometry-export.v0")
        export.put("fixture", fixture.getString("id"))
        export.put("platform", "android")
        export.put("unit", "pt")
        export.put("origin", originId)
        export.put("originMissing", originFrame == null)
        export.put("generatedAt", OffsetDateTime.now().toString())
        export.put(
            "source",
            "android/lib/src/test/kotlin/com/phonedsh/ui/parity/ParityGeometryExportTest.kt " +
                "(Robolectric Compose semantics, 402x874 dp)",
        )
        val frame = fixture.getJSONObject("frame")
        export.put(
            "frame",
            JSONObject()
                .put("width", frame.getInt("widthPt"))
                .put("height", frame.getInt("heightPt")),
        )

        val exported = JSONArray()
        for (index in 0 until elements.length()) {
            val element = elements.getJSONObject(index)
            val id = element.getString("id")
            val node = nodeForElement(elements, id)
            val record = JSONObject().put("id", id)
            val selector = element.optJSONObject("android")
            if (selector == null || !selector.has("testTag")) {
                record.put("found", false)
                record.put("identity", "no-android-selector")
                record.put("reason", "fixture has no android.testTag for this element")
                exported.put(record)
                continue
            }
            record.put("identity", "testTag")
            if (element.has("tolerance")) record.put("tolerance", element.get("tolerance"))
            if (element.has("gatedAxes")) record.put("gatedAxes", element.get("gatedAxes"))
            if (element.has("exemption")) record.put("exemption", element.get("exemption"))
            if (node == null) {
                record.put("found", false)
                record.put("reason", "no semantics node with testTag ${selector.getString("testTag")}")
                exported.put(record)
                continue
            }
            record.put("found", true)
            val absolute = frameOf(node, density)
            record.put("absoluteFrame", absolute)
            record.put("frame", relativeFrame(absolute, originFrame))
            if (element.optBoolean("text", false)) {
                val extracted = textOf(node)
                if (extracted == null) {
                    record.put("text", JSONObject.NULL)
                    record.put("lines", JSONObject.NULL)
                    record.put("wrapPoints", JSONObject.NULL)
                } else {
                    record.put("text", extracted.text)
                    record.put("lines", JSONArray(extracted.lines))
                    record.put("wrapPoints", JSONArray(extracted.wrapPoints))
                }
            }
            exported.put(record)
        }
        export.put("elements", exported)
        return export
    }

    private fun nodeForElement(elements: JSONArray, id: String): SemanticsNode? {
        for (index in 0 until elements.length()) {
            val element = elements.getJSONObject(index)
            if (element.getString("id") != id) continue
            val selector = element.optJSONObject("android") ?: return null
            val tag = selector.optString("testTag", "")
            if (tag.isEmpty()) return null
            return compose.onAllNodes(hasTestTag(tag), useUnmergedTree = true)
                .fetchSemanticsNodes().firstOrNull()
        }
        return null
    }

    private fun frameOf(node: SemanticsNode, density: Float): JSONObject {
        val bounds = node.boundsInRoot
        return JSONObject()
            .put("x", bounds.left / density)
            .put("y", bounds.top / density)
            .put("w", bounds.width / density)
            .put("h", bounds.height / density)
    }

    private fun relativeFrame(frame: JSONObject, origin: JSONObject?): JSONObject {
        if (origin == null) return frame
        return JSONObject()
            .put("x", frame.getDouble("x") - origin.getDouble("x"))
            .put("y", frame.getDouble("y") - origin.getDouble("y"))
            .put("w", frame.getDouble("w"))
            .put("h", frame.getDouble("h"))
    }

    private data class ExtractedText(
        val text: String,
        val lines: List<String>,
        val wrapPoints: List<Int>,
    )

    private fun textOf(node: SemanticsNode): ExtractedText? {
        val textNode = findTextNode(node) ?: return null
        val layouts = mutableListOf<TextLayoutResult>()
        textNode.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
        val layout = layouts.firstOrNull() ?: return null
        val text = layout.layoutInput.text.text
        if (text.isEmpty()) return null
        val starts = (0 until layout.lineCount).map { layout.getLineStart(it) }
        val ends = (0 until layout.lineCount).map { layout.getLineEnd(it) }
        val lines = starts.indices.map { index ->
            text.substring(starts[index].coerceAtMost(text.length), ends[index].coerceAtMost(text.length))
        }
        return ExtractedText(
            text = text,
            lines = lines,
            wrapPoints = starts.drop(1),
        )
    }

    private fun findTextNode(node: SemanticsNode): SemanticsNode? {
        val hasText = node.config.getOrNull(SemanticsProperties.Text) != null
        val hasLayout = node.config.getOrNull(SemanticsActions.GetTextLayoutResult) != null
        if (hasText && hasLayout) return node
        node.children.forEach { child ->
            val found = findTextNode(child)
            if (found != null) return found
        }
        return null
    }
}
