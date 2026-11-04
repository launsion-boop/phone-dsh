// The three device-connector pages, captured at 402 x 874 @3 on a real renderer.
// SPDX-License-Identifier: MIT
//
// What these captures are: the pages rendered from **real `:domain` snapshots** — the
// connector source over the in-memory connector, the paging monitor over the in-memory
// read-only transport, and the artifact store double with evidence projected from the
// same transcript. Nothing here is a hand-built screen state, so a green capture also
// says the seam between `:domain` and the page works.
//
// What they are not: a pixel comparison with iOS. The three pages have no iOS baseline
// screenshot (see `DeviceParityStates`), so the claim these frames support is "the page
// renders at the same viewport, from the same tokens", never "it matches iOS pixel for
// pixel".
//
// The frame comes from `ScreenshotProfile.IOS_PARITY` (1206 x 2622 px @ 480 dpi, i.e.
// 402 x 874 pt @3), asserted before every capture by `ScreenshotTestBase`; the metrics
// this lane's layout reads (`UiMetrics.contentColumnWidth`, `flowGap`,
// `flowGapResponse`) come from `UiMetrics` and nowhere else.
package com.phonedsh.ui.screenshot

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.domain.connector.DeviceConnectionEntry
import com.phonedsh.domain.connector.DeviceConnectionSource
import com.phonedsh.domain.connector.DeviceHistoryPage
import com.phonedsh.domain.connector.DeviceHistoryRequest
import com.phonedsh.domain.connector.DeviceItemKind
import com.phonedsh.domain.connector.DeviceLiveEvent
import com.phonedsh.domain.connector.DeviceSessionSource
import com.phonedsh.domain.connector.DeviceTranscriptProjector
import com.phonedsh.domain.connector.Endpoint
import com.phonedsh.domain.connector.InMemoryConnector
import com.phonedsh.domain.connector.InMemoryDeviceSessionProvider
import com.phonedsh.domain.connector.InMemoryDeviceSessionTransport
import com.phonedsh.domain.connector.ReadOnlyDeviceSessionTransport
import com.phonedsh.domain.device.CapabilityValue
import com.phonedsh.domain.device.DeviceAuth
import com.phonedsh.domain.device.DeviceLimits
import com.phonedsh.domain.device.DeviceManifest
import com.phonedsh.domain.device.DeviceProtocol
import com.phonedsh.ui.page.DeviceConnectionScreenState
import com.phonedsh.ui.page.DeviceSessionScreenState
import com.phonedsh.ui.page.InMemorySessionArtifactSource
import com.phonedsh.ui.page.NativeDeviceConnectionPage
import com.phonedsh.ui.page.NativeDeviceSessionPage
import com.phonedsh.ui.page.SessionArtifactEvidence
import com.phonedsh.ui.page.SessionArtifactRef
import com.phonedsh.ui.page.SessionArtifactsLocalState
import com.phonedsh.ui.page.SessionArtifactsPage
import com.phonedsh.ui.page.SessionArtifactsScreenState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import java.io.File
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DeviceConnectorParityScreenshotTest : ScreenshotTestBase() {
    /** These captures are for the 402 pt viewport only. */
    override val allowedProfiles: Set<ScreenshotProfile> = setOf(ScreenshotProfile.IOS_PARITY)

    /** The scope the live tail is folded in; unconfined so `start` settles before capture. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    /**
     * Publishes this lane's own registry next to the PNGs.
     *
     * Written here rather than through `ScreenshotStore.writeRegistry`: that call is
     * the 27-state parity registry, and a second writer would either overwrite it or
     * have to change a file another lane owns.
     */
    @Before
    fun publishDeviceRegistry() {
        val dir = ScreenshotStore.outputDir(compose.activity, profile)
        check(dir.isDirectory || dir.mkdirs()) { "cannot create the capture directory $dir" }
        File(dir, DeviceParityState.REGISTRY_FILE).writeText(
            DeviceParityState.entries.joinToString("\n", postfix = "\n") { it.registryLine() },
        )
    }

    @After
    fun stopScope() {
        scope.cancel()
    }

    @Test
    fun deviceConnectionPage() {
        val source = connectionSource()
        source.refresh()
        setCapturedContent {
            NativeDeviceConnectionPage(
                state = DeviceConnectionScreenState.from(source.snapshot.value),
                onOpen = {},
                onForgetMapping = {},
                onDone = {},
            )
        }
        capture(DeviceParityState.PAGE_DEVICE_CONNECTION.androidName)
    }

    @Test
    fun deviceSessionPage() {
        val source = DeviceSessionSource(
            deviceId = DEVICE_ID,
            sessionId = InMemoryDeviceSessionTransport.DEMO_SESSION_ID,
            displayName = DISPLAY_NAME,
            transport = InMemoryDeviceSessionTransport.demo(),
        )
        runBlocking { source.start(scope) }
        setCapturedContent {
            NativeDeviceSessionPage(
                state = DeviceSessionScreenState.from(source.snapshot.value),
                onLoadEarlier = {},
                onToggleRow = {},
                onBack = {},
            )
        }
        capture(DeviceParityState.PAGE_DEVICE_SESSION.androidName)
    }

    /**
     * The paging state: a short window whose device still says `hasMore`.
     *
     * The bottom-anchored transcript puts 读取更早消息 above the fold on a full
     * window (the baseline does the same), so this capture is the one that shows the
     * affordance itself.
     */
    @Test
    fun deviceSessionPagingAction() {
        val shortWindow = object : ReadOnlyDeviceSessionTransport {
            override suspend fun readHistory(
                sessionId: String,
                request: DeviceHistoryRequest,
            ): DeviceHistoryPage = DeviceHistoryPage(
                records = InMemoryDeviceSessionTransport.demoRecords().takeLast(3),
                hasMore = true,
            )

            override fun liveEvents(sessionId: String, afterSeq: Long?): Flow<DeviceLiveEvent> =
                flow { }
        }
        val source = DeviceSessionSource(
            deviceId = DEVICE_ID,
            sessionId = InMemoryDeviceSessionTransport.DEMO_SESSION_ID,
            displayName = DISPLAY_NAME,
            transport = shortWindow,
        )
        runBlocking { source.start(scope) }
        setCapturedContent {
            NativeDeviceSessionPage(
                state = DeviceSessionScreenState.from(source.snapshot.value),
                onLoadEarlier = {},
                onToggleRow = {},
                onBack = {},
            )
        }
        capture(DeviceParityState.PAGE_DEVICE_SESSION_EARLIER.androidName)
    }

    @Test
    fun sessionArtifactsPage() {
        val store = InMemorySessionArtifactSource(
            artifacts = listOf(
                SessionArtifactRef("art_weekly_doc", "weekly-report.docx", 48_120),
                SessionArtifactRef("art_budget_sheet", "budget.xlsx", 12_800),
                SessionArtifactRef("art_old_draft", "旧草稿.pdf", 230_400),
            ),
            present = setOf("art_weekly_doc", "art_budget_sheet"),
        )
        val artifacts = runBlocking {
            val loaded = mutableListOf<SessionArtifactRef>()
            var cursor = 0
            while (true) {
                val page = store.list(cursor, 50)
                loaded += page.items
                val next = page.nextCursor ?: break
                cursor = next
            }
            loaded
        }
        val evidence = DeviceTranscriptProjector.items(
            InMemoryDeviceSessionTransport.demoRecords(),
            InMemoryDeviceSessionTransport.DEMO_SESSION_ID,
        ).filter { it.kind == DeviceItemKind.TOOL_CALL }.map { SessionArtifactEvidence.from(it) }
        setCapturedContent {
            SessionArtifactsPage(
                state = SessionArtifactsScreenState.from(
                    artifacts = artifacts,
                    evidence = evidence,
                    local = SessionArtifactsLocalState(),
                ),
                onOpen = {},
                onDone = {},
            )
        }
        capture(DeviceParityState.PAGE_SESSION_ARTIFACTS.androidName)
    }

    /** The shipped demo wiring, built here so the capture reads the same source as the app. */
    private fun connectionSource(): DeviceConnectionSource {
        val endpoint = Endpoint("devicews", "wss://device.invalid:443/channel")
        val manifest = DeviceManifest(
            deviceId = DEVICE_ID,
            protocol = DeviceProtocol("devicews", "1.0"),
            capabilities = linkedMapOf(
                "audio.tts" to CapabilityValue.of("codec" to "opus", "rate" to 24_000),
                "render.pixel" to CapabilityValue.of("w" to 64, "h" to 64, "format" to "rgb565"),
            ),
            limits = DeviceLimits(maxFrameBytes = 65_536, audioKbps = 32),
            auth = DeviceAuth(DeviceAuth.Pairing.BLE_PASSKEY),
        )
        return DeviceConnectionSource(
            connector = InMemoryConnector(mapOf(endpoint to manifest)),
            publishedDevices = listOf(
                DeviceConnectionEntry(
                    deviceId = manifest.deviceId,
                    displayName = DISPLAY_NAME,
                    endpoint = endpoint,
                    capabilityCount = manifest.capabilities.size,
                ),
            ),
            provider = InMemoryDeviceSessionProvider(
                assignments = mapOf(DEVICE_ID to InMemoryDeviceSessionTransport.DEMO_SESSION_ID),
            ),
        )
    }

    private companion object {
        const val DEVICE_ID: String = "esp32-8c4f01"
        const val DISPLAY_NAME: String = "客厅网关"
    }
}
