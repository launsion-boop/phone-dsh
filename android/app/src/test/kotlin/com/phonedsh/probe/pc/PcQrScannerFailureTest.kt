// SPDX-License-Identifier: MIT
// A late CameraX provider/bind failure must end in the same page state as a
// camera that was never available: the scanner closes, 相机不可用或未授权 is
// shown, and 其他方式 still works. Robolectric + a JVM Activity is not a device
// test; no camera is opened here.
package com.phonedsh.probe.pc

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Looper
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.test.core.app.ApplicationProvider
import com.google.common.util.concurrent.ListenableFuture
import com.phonedsh.pclink.PclinkPresence
import com.phonedsh.probe.HostPcLinkWiring
import com.phonedsh.ui.page.PCPairingStage
import com.phonedsh.ui.page.PcLinkText
import java.io.File
import java.nio.file.Files
import java.time.Duration
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** A provider future that always fails where the production bind would run. */
private class FailingProviderFuture(
    private val failure: Exception,
) : ListenableFuture<ProcessCameraProvider> {
    override fun addListener(listener: Runnable, executor: Executor) {
        executor.execute(listener)
    }

    override fun cancel(mayInterruptIfRunning: Boolean): Boolean = false

    override fun isCancelled(): Boolean = false

    override fun isDone(): Boolean = true

    override fun get(): ProcessCameraProvider = throw failure

    override fun get(timeout: Long, unit: TimeUnit): ProcessCameraProvider = throw failure
}

private class TestLifecycleOwner : LifecycleOwner {
    private val registry = LifecycleRegistry(this)

    override val lifecycle: Lifecycle get() = registry
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PcQrScannerFailureTest {
    private lateinit var app: Application
    private lateinit var lifecycleOwner: LifecycleOwner

    @Before
    fun setUp() {
        app = ApplicationProvider.getApplicationContext()
        // The page only opens the scanner when its own pre-check said the device
        // has a camera and CAMERA is granted; the late failure is what follows.
        shadowOf(app.packageManager)
            .setSystemFeature(PackageManager.FEATURE_CAMERA_ANY, true)
        shadowOf(app).grantPermissions(Manifest.permission.CAMERA)
        lifecycleOwner = TestLifecycleOwner()
    }

    private fun idleMain() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun failingScanner(): PcQrScanner = PcQrScanner(
        context = app,
        lifecycleOwner = lifecycleOwner,
        providerFuture = { FailingProviderFuture(IllegalStateException("camera bind failed")) },
    )

    @Test
    fun `a failed bind reports unavailable once on the main thread and no decode`() {
        var unavailable = 0
        var onMain = false
        var decoded: String? = null
        val scanner = failingScanner()
        try {
            val availability = scanner.start(
                previewView = PreviewView(app),
                onDecoded = { decoded = it },
                onUnavailable = {
                    unavailable++
                    onMain = Looper.myLooper() == Looper.getMainLooper()
                },
            )
            assertEquals(PcCameraAvailability.AVAILABLE, availability)
            // The failure arrives from the asynchronous listener, not `start`.
            assertEquals(0, unavailable)
            idleMain()
            assertEquals(1, unavailable)
            assertTrue("the failure callback runs on the main executor", onMain)
            assertNull("a failed bind delivers no decode", decoded)
            // A second turn of the main looper must not report the same failure again.
            idleMain()
            assertEquals(1, unavailable)
        } finally {
            scanner.close()
        }
    }

    @Test
    fun `a stop before the provider settles suppresses the late failure`() {
        var unavailable = 0
        val scanner = failingScanner()
        try {
            val availability = scanner.start(
                previewView = PreviewView(app),
                onDecoded = { error("a stopped start must not decode") },
                onUnavailable = { unavailable++ },
            )
            assertEquals(PcCameraAvailability.AVAILABLE, availability)
            // 取消/close leaves the page before the provider future settles.
            scanner.stop()
            idleMain()
            assertEquals("a dismissed scanner is not reopened by a late failure", 0, unavailable)
        } finally {
            scanner.close()
        }
    }

    @Test
    fun `a failed bind replaces the scanner with the camera-unavailable page`() {
        Fixture().use { fixture ->
            var unavailable = 0
            val scanner = failingScanner()
            try {
                fixture.wiring.onScan()
                assertEquals(
                    PCPairingStage.SCANNING,
                    fixture.wiring.pairingState(fixture.controller.state.value).stage,
                )

                val availability = scanner.start(
                    previewView = PreviewView(app),
                    onDecoded = { error("a failed start must not decode") },
                    onUnavailable = {
                        unavailable++
                        // The same callback HostShell's PcQrScannerContent passes.
                        fixture.wiring.onCameraUnavailable()
                    },
                )
                assertEquals(PcCameraAvailability.AVAILABLE, availability)
                idleMain()

                assertEquals(1, unavailable)
                val state = fixture.controller.state.value
                val ui = fixture.wiring.pairingState(state)
                assertEquals(PCPairingStage.CAMERA_UNAVAILABLE, ui.stage)
                assertFalse("the scanner sheet is closed", ui.scanning)
                assertFalse(
                    "the controller no longer reports an available camera",
                    state.camera == PcCameraAvailability.AVAILABLE,
                )
                // The displayed sentence is the page contract's cameraDenied row,
                // not a second copy invented by this host.
                assertEquals(cameraDeniedLabel(), PcLinkText.CAMERA_UNAVAILABLE)

                // 其他方式 stays a usable path after the failure.
                fixture.wiring.onToggleOtherWays()
                assertEquals(
                    PCPairingStage.OTHER_WAYS,
                    fixture.wiring.pairingState(fixture.controller.state.value).stage,
                )
                fixture.wiring.onPairingLinkChange("pclink://pair?x=1")
                val other = fixture.wiring.pairingState(fixture.controller.state.value)
                assertEquals(PCPairingStage.PAIRING_LINK, other.stage)
                assertTrue(other.linkReady)
            } finally {
                scanner.close()
            }
        }
    }

    private class Fixture : AutoCloseable {
        private val directory = Files.createTempDirectory("pc-qr-bind-failure")
        private val client = FakePcLinkClient()
        private val transport = ScriptedDshCall()
        private val storage = PcWorkspaceStorage(
            MapPreferenceFile(),
            directory.resolve(PcWorkspaceStorage.ROSTER_DIRECTORY),
        )
        val controller = PcWorkspaceController(
            client = client,
            transport = transport,
            storage = storage,
            diagnostics = PcDiagnosticsLog(directory.toFile()),
            turnRunner = PcChatTurnRunner(transport),
            presence = PclinkPresence(reconnectGrace = Duration.ofMillis(25)),
            cameraAvailability = { PcCameraAvailability.AVAILABLE },
            onClose = {},
        )
        val wiring = HostPcLinkWiring(controller)

        override fun close() = controller.close()
    }

    companion object {
        /** Reads the label of the `cameraDenied` row from the page contract on disk. */
        private fun cameraDeniedLabel(): String {
            val root = File(System.getProperty("pdsh.repo.root") ?: ".").absoluteFile
            val page = JSONObject(
                File(root, "spec/ui/v1/pages/pc-pairing.json").readText(Charsets.UTF_8),
            )
            return requireNotNull(findCameraDenied(page)) {
                "pc-pairing.json has no cameraDenied label"
            }
        }

        private fun findCameraDenied(node: Any?): String? = when (node) {
            is JSONObject -> if (node.optString("condition") == "cameraDenied") {
                node.getString("label")
            } else {
                node.keys().asSequence()
                    .map { findCameraDenied(node.opt(it)) }
                    .firstOrNull { it != null }
            }
            is JSONArray -> (0 until node.length()).asSequence()
                .map { findCameraDenied(node.opt(it)) }
                .firstOrNull { it != null }
            else -> null
        }
    }
}
