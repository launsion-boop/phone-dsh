// The three device-connector pages (JVM + Robolectric): they bind state, never fake it.
// SPDX-License-Identifier: MIT
//
// Each page is asserted on semantics — the visible copy, the stable tags and the
// callbacks — never on a screenshot or a font measurement: Robolectric's metrics are
// not the device's, so a geometry assertion here would be a fake oracle. The pixels
// are the parity suite's job (`DeviceConnectorParityScreenshotTest`, on a device).
//
// The last three tests are the page-layer discipline this lane owes:
//
//  * the token inventory each page declares is exactly the tokens it reads (the same
//    rule `PageTokenReferenceTest` applies to the pages that landed earlier — this
//    lane's pages are not in that file's list, so the rule is re-applied here rather
//    than dropped);
//  * no page re-types a length or a colour;
//  * the session page has no write affordance at all: the transport seam has none,
//    and the page must not add one.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.domain.connector.ConnectorStatus
import com.phonedsh.domain.connector.DeviceConnectionEntry
import com.phonedsh.domain.connector.DeviceConnectionSnapshot
import com.phonedsh.domain.connector.DeviceContentBlock
import com.phonedsh.domain.connector.DeviceItemKind
import com.phonedsh.domain.connector.DeviceLiveEvent
import com.phonedsh.domain.connector.DeviceLiveState
import com.phonedsh.domain.connector.DeviceOpenFailure
import com.phonedsh.domain.connector.DeviceSessionSnapshot
import com.phonedsh.domain.connector.DeviceSessionFailure
import com.phonedsh.domain.connector.DeviceSessionStatus
import com.phonedsh.domain.connector.DeviceToolState
import com.phonedsh.domain.connector.DeviceTranscriptItem
import com.phonedsh.domain.connector.DeviceTranscriptProjector
import com.phonedsh.domain.connector.DeviceTranscriptRecord
import com.phonedsh.domain.connector.DeviceTransmission
import com.phonedsh.domain.connector.DeviceTransmissionRow
import com.phonedsh.domain.connector.Endpoint
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.tokenNames
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.UiTokenNames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.nio.file.Files
import java.nio.file.Path

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class DeviceConnectorPagesTest {
    @get:Rule
    val compose = createComposeRule()

    // ------------------------------------------------------------ 设备连接

    @Test
    fun `without a connector the connection page shows the baseline's unavailable body`() {
        val state = DeviceConnectionScreenState.from(
            DeviceConnectionSnapshot(
                connectorAvailable = false,
                connectorProtocol = null,
                status = ConnectorStatus.UNKNOWN,
            ),
        )
        compose.setContent {
            PdshTheme {
                NativeDeviceConnectionPage(state, onOpen = {}, onForgetMapping = {}, onDone = {})
            }
        }
        compose.onNodeWithTag(UiPageTags.DEVICE_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_CONNECTOR_UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_CONNECTOR_UNAVAILABLE_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_EMPTY).assertDoesNotExist()
        compose.onAllNodesWithTag(UiPageTags.DEVICE_ROW).assertCountEquals(0)
        // The two transport rows and their footer are there either way.
        compose.onNodeWithText(UiStrings.DEVICE_BLUETOOTH_CONNECTOR).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_LOCAL_NETWORK_CONNECTOR).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_TRANSPORT_FOOTER).assertIsDisplayed()
        assertEquals(
            "both transports read 未提供",
            2,
            compose.onAllNodesWithText(UiStrings.DEVICE_TRANSPORT_NOT_PROVIDED).fetchSemanticsNodes().size,
        )
    }

    @Test
    fun `a published device opens, and every row is disabled while one open is in flight`() {
        val device = DeviceConnectionEntry(DEVICE_ID, DISPLAY_NAME, Endpoint("devicews", "wss://d.invalid"))
        val base = DeviceConnectionSnapshot(
            connectorAvailable = true,
            connectorProtocol = "devicews",
            status = ConnectorStatus.READY,
            devices = listOf(device),
            transmissions = listOf(DeviceTransmissionRow(DeviceTransmission.BLUETOOTH, available = false)),
        )
        var opened: String? = null
        var local by mutableStateOf(DeviceConnectionLocalState())
        compose.setContent {
            PdshTheme {
                NativeDeviceConnectionPage(
                    state = DeviceConnectionScreenState.from(base, local),
                    onOpen = { opened = it.deviceId },
                    onForgetMapping = {},
                    onDone = {},
                )
            }
        }
        compose.onNodeWithText(DISPLAY_NAME).assertIsDisplayed()
        compose.onNodeWithText(DEVICE_ID).assertIsDisplayed()
        // The iOS screen has no connector-source diagnostic row; it starts with
        // the published device list beneath 真实连接设备.
        compose.onNodeWithTag(UiPageTags.DEVICE_SOURCE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.DEVICE_ROW).performClick()
        assertEquals(DEVICE_ID, opened)

        // An open in flight disables every row: two opens would race two mappings.
        local = DeviceConnectionLocalState(openingDeviceId = DEVICE_ID)
        compose.onNodeWithTag(UiPageTags.DEVICE_ROW).assertIsNotEnabled()
    }

    @Test
    fun `unreported per-device status stays unknown and host mapping is shown as a fact`() {
        val device = DeviceConnectionEntry(DEVICE_ID, DISPLAY_NAME, Endpoint("devicews", "wss://d.invalid"))
        val snapshot = DeviceConnectionSnapshot(
            connectorAvailable = true,
            connectorProtocol = "devicews",
            status = ConnectorStatus.READY,
            devices = listOf(device),
            forgettableDeviceIds = setOf(DEVICE_ID),
        )
        var state by mutableStateOf(DeviceConnectionScreenState.from(snapshot))
        compose.setContent {
            PdshTheme {
                NativeDeviceConnectionPage(
                    state = state,
                    onOpen = {},
                    onForgetMapping = {},
                    onDone = {},
                )
            }
        }
        compose.onNodeWithText("已有会话映射 · 连接状态未知").assertIsDisplayed()
        state = DeviceConnectionScreenState.from(snapshot, deviceOnline = mapOf(DEVICE_ID to true))
        compose.onNodeWithText("已有会话映射 · 在线").assertIsDisplayed()
    }

    @Test
    fun `workbench segments and pending preview refresh use host callbacks`() {
        val snapshot = WorkbenchSnapshot(
            files = emptyList(),
            commands = listOf(WorkbenchCommand(id = "cmd-1", command = "rg query src")),
        )
        var local = WorkbenchLocalState()
        var state by mutableStateOf(WorkbenchScreenState.from(snapshot, local))
        var refreshes = 0
        compose.setContent {
            PdshTheme {
                NativeWorkbenchPage(
                    state = state,
                    onSelectSection = { section ->
                        local = local.apply(WorkbenchUiEvent.SelectSection(section))
                        state = WorkbenchScreenState.from(snapshot, local)
                    },
                    onOpenFile = {},
                    onClosePreview = { local = local.apply(WorkbenchUiEvent.ClosePreview) },
                    onDone = {},
                    onRefreshPending = { refreshes += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.WORKBENCH_FILES_TAB).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_COMMANDS_TAB).performClick()
        compose.onNodeWithTag(UiPageTags.WORKBENCH_COMMANDS_LIST).assertIsDisplayed()

        local = WorkbenchLocalState(previewPath = "tool-output.txt")
        state = WorkbenchScreenState.from(snapshot, local)
        compose.onNodeWithText(UiStrings.WORKBENCH_PREVIEW_PENDING).assertIsDisplayed()
        compose.onNodeWithText("重新检查文件").performClick()
        assertEquals(1, refreshes)
    }

    @Test
    fun `a failed open shows its reason and the explicit way out of the mapping`() {
        var forgotten: String? = null
        val state = DeviceConnectionScreenState.from(
            DeviceConnectionSnapshot(
                connectorAvailable = true,
                connectorProtocol = "devicews",
                status = ConnectorStatus.FAILED,
                devices = listOf(
                    DeviceConnectionEntry(DEVICE_ID, DISPLAY_NAME, Endpoint("devicews", "wss://d.invalid")),
                ),
                openFailure = DeviceOpenFailure.Mismatch("session-a", "session-b"),
                failedDeviceId = DEVICE_ID,
                forgettableDeviceIds = setOf(DEVICE_ID),
            ),
        )
        compose.setContent {
            PdshTheme {
                NativeDeviceConnectionPage(
                    state = state,
                    onOpen = {},
                    onForgetMapping = { forgotten = it },
                    onDone = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.DEVICE_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(
            UiStrings.DEVICE_OPEN_FAILED_MISMATCH.format("session-a", "session-b"),
        ).assertIsDisplayed()
        // The way out is a visible verb, not only a tag: the failure line says what
        // happened, this row is the one explicit action that drops the mapping.
        compose.onNodeWithText(UiStrings.DEVICE_FORGET_MAPPING).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_FORGET).performClick()
        assertEquals(DEVICE_ID, forgotten)
    }

    @Test
    fun `the explicit way out appears only while a saved mapping exists`() {
        // `NativeDeviceConnectionPage.swift:91`-`:93`: the button is gated on
        // `coordinator.savedMapping(for: failedDeviceID) != nil`. A failed open with
        // no saved mapping therefore shows its reason and no forget row — there is
        // nothing to unbind, and the page never rebinds silently either.
        val state = DeviceConnectionScreenState.from(
            DeviceConnectionSnapshot(
                connectorAvailable = true,
                connectorProtocol = "devicews",
                status = ConnectorStatus.FAILED,
                devices = listOf(
                    DeviceConnectionEntry(DEVICE_ID, DISPLAY_NAME, Endpoint("devicews", "wss://d.invalid")),
                ),
                openFailure = DeviceOpenFailure.Unavailable(DEVICE_ID),
                failedDeviceId = DEVICE_ID,
                forgettableDeviceIds = emptySet(),
            ),
        )
        assertFalse(state.canForget)
        compose.setContent {
            PdshTheme {
                NativeDeviceConnectionPage(
                    state = state,
                    onOpen = {},
                    onForgetMapping = {},
                    onDone = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.DEVICE_FAILURE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_FORGET).assertDoesNotExist()
    }

    // ------------------------------------------------------------ 设备会话

    @Test
    fun `the session page renders the read-only strip, the transcript and the footer`() {
        val snapshot = sessionSnapshot()
        compose.setContent {
            PdshTheme {
                NativeDeviceSessionPage(
                    state = DeviceSessionScreenState.from(snapshot),
                    onLoadEarlier = {},
                    onToggleRow = {},
                    onBack = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_STRIP).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_TITLE).assertIsDisplayed()
        compose.onNodeWithText(DEMO_SESSION.take(8)).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_READ_ONLY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_READ_ONLY).assertIsDisplayed()
        // The transcript is a lazy, bottom-anchored list: a row is proven present by
        // scrolling to it, which is also what a reader does to reach it.
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_LIST)
            .performScrollToNode(hasText("把灯调暗"))
        compose.onNodeWithText("把灯调暗").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_LIST)
            .performScrollToNode(hasText("客厅现在是 23.5 度。"))
        compose.onNodeWithText("客厅现在是 23.5 度。").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_LIST).performScrollToNode(hasText("sensor.read"))
    }

    @Test
    fun `the session page offers 读取更早消息 only while the device says hasMore`() {
        var earlier = 0
        var state by mutableStateOf(DeviceSessionScreenState.from(sessionSnapshot(hasMore = true)))
        compose.setContent {
            PdshTheme {
                NativeDeviceSessionPage(
                    state = state,
                    onLoadEarlier = { earlier += 1 },
                    onToggleRow = {},
                    onBack = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.DEVICE_SESSION_READ_EARLIER))
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_READ_EARLIER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_READ_EARLIER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_READ_EARLIER).performClick()
        assertEquals(1, earlier)

        // The device answered hasMore = false: the action goes away rather than
        // offering a page that does not exist.
        state = DeviceSessionScreenState.from(sessionSnapshot(hasMore = false))
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_READ_EARLIER).assertDoesNotExist()
    }

    @Test
    fun `the paging action says 正在读取… while the older window is in flight`() {
        // `NativeDeviceSessionPage.swift:399`-`:400`: the loading branch draws the
        // in-flight placeholder, disables the button, and swaps back when the read
        // answers. `loadingEarlier` is the source's state (`DeviceSessionSource`),
        // not a page guess.
        var earlier = 0
        var state by mutableStateOf(
            DeviceSessionScreenState.from(sessionSnapshot(hasMore = true).copy(loadingEarlier = true)),
        )
        compose.setContent {
            PdshTheme {
                NativeDeviceSessionPage(
                    state = state,
                    onLoadEarlier = { earlier += 1 },
                    onToggleRow = {},
                    onBack = {},
                )
            }
        }
        assertTrue(state.loadingEarlier)
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.DEVICE_SESSION_READ_EARLIER))
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_READING_EARLIER).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_READ_EARLIER).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_READ_EARLIER).assertIsNotEnabled()

        // The window arrived: the same row offers the next one and takes the tap.
        state = DeviceSessionScreenState.from(sessionSnapshot(hasMore = true))
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_READING_EARLIER).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_READ_EARLIER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_READ_EARLIER).performClick()
        assertEquals(1, earlier)
    }

    @Test
    fun `a folded tool row shows its input and output only when opened`() {
        val snapshot = sessionSnapshot()
        val toolRowId = snapshot.items.single { it.kind == DeviceItemKind.TOOL_CALL }.id
        var local by mutableStateOf(DeviceSessionLocalState())
        compose.setContent {
            PdshTheme {
                NativeDeviceSessionPage(
                    state = DeviceSessionScreenState.from(snapshot, local),
                    onLoadEarlier = {},
                    onToggleRow = { local = local.toggle(it) },
                    onBack = {},
                )
            }
        }
        compose.onAllNodesWithText(UiStrings.DEVICE_TOOL_OUTPUT).assertCountEquals(0)
        compose.onNodeWithText("sensor.read").performClick()
        assertTrue("the row's own id is the fold key", local.expandedRowIds.contains(toolRowId))
        compose.onNodeWithText(UiStrings.DEVICE_TOOL_INPUT).assertExists()
        compose.onNodeWithText(UiStrings.DEVICE_TOOL_OUTPUT).assertExists()
        compose.onNodeWithText("{\"room\":\"living\"}").assertExists()
        compose.onNodeWithText("23.5").assertExists()
        // The fold is the only local event: closing it removes the body again.
        local = DeviceSessionLocalState()
        compose.onAllNodesWithText(UiStrings.DEVICE_TOOL_OUTPUT).assertCountEquals(0)
        compose.onAllNodesWithText(UiStrings.DEVICE_TOOL_INPUT).assertCountEquals(0)
    }

    @Test
    fun `a waiting session shows 正在读取设备会话 and a failed one shows the reason`() {
        val waiting = DeviceSessionSnapshot(
            deviceId = DEVICE_ID,
            sessionId = DEMO_SESSION,
            displayName = DISPLAY_NAME,
        )
        var snapshot by mutableStateOf(waiting)
        compose.setContent {
            PdshTheme {
                NativeDeviceSessionPage(
                    state = DeviceSessionScreenState.from(snapshot),
                    onLoadEarlier = {},
                    onToggleRow = {},
                    onBack = {},
                )
            }
        }
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_LOADING).assertIsDisplayed()

        // The read answered, but the older page could not advance the cursor.
        snapshot = waiting.copy(
            status = DeviceSessionStatus.READY,
            failure = DeviceSessionFailure.Stalled(41),
            durable = listOf(
                DeviceTranscriptItem(
                    id = "s:1",
                    kind = DeviceItemKind.USER,
                    title = "你",
                    text = "第 40 轮",
                ),
            ),
        )
        compose.onNodeWithTag(UiPageTags.DEVICE_SESSION_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DEVICE_SESSION_NO_PROGRESS.format(41)).assertIsDisplayed()
    }

    // ------------------------------------------------------- 本会话产物

    @Test
    fun `the artifacts page splits 本会话 from 未归属 and never merges them`() {
        val state = SessionArtifactsScreenState.from(
            artifacts = listOf(
                SessionArtifactRef("art_doc", "weekly-report.docx", 48_120),
                SessionArtifactRef("art_old", "旧草稿.pdf", 230_400),
            ),
            evidence = listOf(
                SessionArtifactEvidence(
                    toolName = "doc.write",
                    argumentsJson = "{}",
                    outputText = "{\"fileId\":\"art_doc\"}",
                    text = "",
                    state = DeviceToolState.OK,
                ),
            ),
        )
        compose.setContent {
            PdshTheme { SessionArtifactsPage(state, onOpen = {}, onDone = {}) }
        }
        compose.onNodeWithText(UiStrings.ARTIFACTS_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_SECTION_SESSION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_SESSION_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_UNASSIGNED_SECTION).assertIsDisplayed()
        compose.onNodeWithText("weekly-report.docx").assertIsDisplayed()
        compose.onNodeWithText("旧草稿.pdf").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_UNASSIGNED_FOOTER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_EMPTY).assertDoesNotExist()
    }

    @Test
    fun `an artifact no successful producing call names stays 未归属`() {
        val state = SessionArtifactsScreenState.from(
            artifacts = listOf(SessionArtifactRef("art_doc", "weekly-report.docx", 1)),
            evidence = listOf(
                SessionArtifactEvidence(
                    toolName = "doc.write",
                    argumentsJson = "{}",
                    outputText = "{\"fileId\":\"art_doc\"}",
                    text = "",
                    state = DeviceToolState.ERROR,
                ),
            ),
        )
        assertTrue("a failed write produced nothing", state.assigned.isEmpty())
        assertEquals(listOf("art_doc"), state.unassigned.map { it.artifactId })
    }

    @Test
    fun `an empty session shows the baseline's empty body and its retry`() {
        var retried = 0
        compose.setContent {
            PdshTheme {
                SessionArtifactsPage(
                    state = SessionArtifactsScreenState.from(emptyList(), emptyList()),
                    onOpen = {},
                    onDone = {},
                    onRetry = { retried += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_EMPTY_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_EMPTY_HINT).assertIsDisplayed()
    }

    @Test
    fun `a failed artifact read is on screen with a retry`() {
        var retried = 0
        compose.setContent {
            PdshTheme {
                SessionArtifactsPage(
                    state = SessionArtifactsScreenState.from(
                        artifacts = emptyList(),
                        evidence = emptyList(),
                        failure = UiStrings.ARTIFACTS_LOAD_FAILED.format("store unavailable"),
                    ),
                    onOpen = {},
                    onDone = {},
                    onRetry = { retried += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `an open failure is the baseline's alert with its single 好`() {
        var dismissed = 0
        val state = SessionArtifactsScreenState.from(
            artifacts = emptyList(),
            evidence = emptyList(),
        ).copy(openFailure = UiStrings.ARTIFACTS_MISSING_FILE)
        compose.setContent {
            PdshTheme {
                SessionArtifactsPage(
                    state = state,
                    onOpen = {},
                    onDone = {},
                    onDismissOpenFailure = { dismissed += 1 },
                )
            }
        }
        compose.onNode(isDialog()).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_OPEN_FAILED).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_MISSING_FILE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_OPEN_ALERT_ACTION).performClick()
        assertEquals(1, dismissed)
        compose.onNodeWithText(UiStrings.ARTIFACTS_ACKNOWLEDGE).assertIsDisplayed()
    }

    // --------------------------------------------------------- page discipline

    @Test
    fun `each device page declares exactly the tokens its source reads`() {
        val known = SpecFixtures.tokenNames()
        val pages = mapOf(
            "NativeDeviceConnectionPage.kt" to DeviceConnectionPageTokens.refs,
            "NativeDeviceSessionPage.kt" to NativeDeviceSessionPageTokens.refs,
            "SessionArtifactsPage.kt" to SessionArtifactsPageTokens.refs,
        )
        pages.forEach { (file, declared) ->
            (references(file) + declared.map(::canonicalToken)).forEach { reference ->
                assertTrue(
                    "$file reads '$reference', which is not a token in spec/ui/v1/tokens.json",
                    reference in known,
                )
            }
            assertEquals(
                "$file: the declared inventory must equal the tokens the file reads",
                references(file).sorted(),
                declared.map(::canonicalToken).toSet().sorted(),
            )
        }
        val sessionPage = source("NativeDeviceSessionPage.kt")
        assertTrue(
            "NativeDeviceSessionPage.kt: the loading mark must use its named measured metrics",
            sessionPage.contains("modifier = Modifier.size(DEVICE_SESSION_LOADING_MARK_SIZE_DP.dp)") &&
                sessionPage.contains("strokeWidth = DEVICE_SESSION_LOADING_MARK_STROKE_DP.dp"),
        )
    }

    @Test
    fun `no device page re-types a length or a colour, and every one has the license header`() {
        PAGES.forEach { file ->
            val source = source(file)
            assertTrue("$file re-types a length", LENGTH_LITERAL.findAll(source).none())
            assertTrue("$file re-types a colour", COLOUR_LITERAL.findAll(source).none())
            assertEquals("$file: line 2 must be the SPDX header", SPDX, Files.readAllLines(pageDir().resolve(file))[1])
            assertTrue(
                "$file must consume the insets through the shared page frame",
                source.contains("PageFrame("),
            )
        }
    }

    /**
     * The session page is a monitor: it renders the transcript and offers paging, and
     * nothing else. A composer, a send or an approval callback here would be a write
     * affordance the transport cannot honour.
     */
    @Test
    fun `the session page declares no write callback`() {
        val source = source("NativeDeviceSessionPage.kt")
        // The public composable's own parameter list; private row helpers may take a
        // fold callback, the page may not take a write one.
        val signature = source.substringAfter("public fun NativeDeviceSessionPage(")
            .substringBefore(") {")
        val callbacks = CALLBACK_LITERAL.findAll(signature).map { it.groupValues[1] }.toSet()
        assertEquals(setOf("onLoadEarlier", "onToggleRow", "onBack"), callbacks)
        writeVerbs().forEach { verb ->
            assertFalse(
                "NativeDeviceSessionPage.kt mentions '$verb': a monitor cannot write",
                source.contains(verb),
            )
        }
    }

    // -------------------------------------------------------------- fixtures

    private fun sessionSnapshot(hasMore: Boolean = true): DeviceSessionSnapshot {
        val records = listOf(
            DeviceTranscriptRecord.UserMessage(seq = 1, turn = 1, text = "把灯调暗"),
            DeviceTranscriptRecord.AssistantMessage(
                seq = 2,
                turn = 1,
                blocks = listOf(
                    DeviceContentBlock.Reasoning("先读传感器"),
                    DeviceContentBlock.Text("客厅现在是 23.5 度。"),
                ),
            ),
            DeviceTranscriptRecord.ToolCall(
                seq = 3,
                turn = 1,
                callId = "tool-1",
                name = "sensor.read",
                argumentsJson = "{\"room\":\"living\"}",
            ),
            DeviceTranscriptRecord.ToolResult(
                seq = 4,
                turn = 1,
                callId = "tool-1",
                isError = false,
                output = "23.5",
            ),
        )
        val live = DeviceLiveState()
            .apply(DeviceLiveEvent.UserMessage("客厅的灯好了", seq = 5), DEMO_SESSION)
        return DeviceSessionSnapshot(
            deviceId = DEVICE_ID,
            sessionId = DEMO_SESSION,
            displayName = DISPLAY_NAME,
            status = DeviceSessionStatus.READY,
            durable = DeviceTranscriptProjector.items(records, DEMO_SESSION),
            live = live.items,
            hasMore = hasMore,
            beforeSeq = 1,
            throughSeq = 4,
        )
    }

    private fun writeVerbs(): List<String> = listOf("onSend", "onStop", "onApprove", "onDeny", "onReply")

    private fun references(file: String): List<String> {
        val text = source(file)
        val direct = TOKEN_REF.findAll(text).map { canonicalToken("${it.groupValues[1]}.${it.groupValues[2]}") }
        val typography = TYPOGRAPHY_REF.findAll(text)
            .map { canonicalToken("typography.${it.groupValues[1]}") }
            .filter { it in SpecFixtures.tokenNames() }
        return (direct + typography).toSet().toList()
    }

    /** Compatibility names resolve through the same spec map as production. */
    private fun canonicalToken(token: String): String {
        val family = token.substringBefore('.')
        val leaf = token.substringAfter('.')
        val aliases = (SpecFixtures.tokens["aliases"] as? JsonObject)?.get(family) as? JsonObject
        return (aliases?.get(leaf) as? JsonString)?.value ?: token
    }

    private fun source(file: String): String =
        String(Files.readAllBytes(pageDir().resolve(file)), Charsets.UTF_8)

    private fun pageDir(): Path =
        SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page")

    private companion object {
        const val DEVICE_ID: String = "esp32-8c4f01"
        const val DISPLAY_NAME: String = "客厅网关"
        const val DEMO_SESSION: String = "device-session-demo"
        const val SPDX: String = "// SPDX-License-Identifier: MIT"

        val PAGES: List<String> = listOf(
            "NativeDeviceConnectionPage.kt",
            "NativeDeviceSessionPage.kt",
            "SessionArtifactsPage.kt",
        )

        val TOKEN_REF: Regex =
            Regex("""tokens\.(colors|spacing|radius|stroke|motion|geometry)\.([A-Za-z0-9_]+)""")
        val TYPOGRAPHY_REF: Regex = Regex("""(?:type|LocalUiType\.current)\.([A-Za-z0-9_]+)""")
        val LENGTH_LITERAL: Regex = Regex("""\b\d+(?:\.\d+)?\.(?:dp|sp)\b""")
        val COLOUR_LITERAL: Regex =
            Regex("""Color\(\s*0x|androidx\.compose\.ui\.graphics\.Color\.(White|Black|Red|Gray|Blue)""")

        /** A named callback parameter of the page composable (`onXxx: (...) -> Unit`). */
        val CALLBACK_LITERAL: Regex = Regex("""\b(on[A-Z][A-Za-z]*)\s*:\s*\(?""")
    }
}
