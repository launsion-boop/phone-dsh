// SPDX-License-Identifier: MIT
// Camera QR scanning for the pairing page (design §6 C5, P09 pc-pairing).
//
// :lib is the published AAR and stays camera-free, so both CameraX and ZXing
// live here. ZXing core is pure Java (no Play Services), and the decode path is
// a plain function over a luminance plane, which is what lets the JVM suite
// decode the golden `pclink://pair?...` payload from `spec/pclink/v1/**` without
// a camera or a device.
//
// The scanner does not own the permission UI. `PcWorkspaceController` reports
// [PcCameraAvailability] and MainActivity raises the one CAMERA runtime prompt;
// a denied/absent camera leaves the pairing page on its `相机不可用或未授权…`
// copy, while paste-link and manual-code pairing keep working.
package com.phonedsh.probe.pc

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.common.util.concurrent.ListenableFuture
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.Result
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** What the page may say about the camera; `UNKNOWN` is "not asked yet". */
internal enum class PcCameraAvailability {
    UNKNOWN,
    AVAILABLE,
    DENIED,
    UNAVAILABLE,
}

/**
 * The production CameraX scanner.
 *
 * [start] binds a preview + analysis use case to [lifecycleOwner]; [stop]
 * releases the analyzer and provider; [close] also shuts the single executor
 * down. Each terminal callback (decoded or unavailable) is invoked at most once
 * per [start].
 */
internal class PcQrScanner(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    /**
     * Resolves CameraX's process provider. Production is the process singleton;
     * the seam lets a JVM test fail the asynchronous resolution step that
     * precedes the bind, without a camera or a device.
     */
    private val providerFuture: (Context) -> ListenableFuture<ProcessCameraProvider> =
        { ProcessCameraProvider.getInstance(it) },
) : AutoCloseable {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val delivered = AtomicBoolean(false)
    private val unavailableReported = AtomicBoolean(false)
    private val active = AtomicBoolean(false)
    private var provider: ProcessCameraProvider? = null
    private var analysis: ImageAnalysis? = null

    /**
     * Starts the camera. Returns [PcCameraAvailability.UNAVAILABLE] when the
     * device has no camera, [PcCameraAvailability.DENIED] when CAMERA is not
     * granted, and [PcCameraAvailability.AVAILABLE] once the use cases bind.
     *
     * The bind is asynchronous. [onUnavailable] runs on the main thread exactly
     * once for a start that returned [PcCameraAvailability.AVAILABLE] when the
     * provider resolution or the bind throws; a synchronous non-AVAILABLE return
     * is the caller's fact instead. A [stop] before the listener settles
     * suppresses that late failure: the person already closed the scanner.
     * [onDecoded] runs on the analysis executor, so callers must post to their UI
     * thread themselves (the page does so through its state holder).
     */
    fun start(
        previewView: PreviewView,
        onDecoded: (String) -> Unit,
        onUnavailable: () -> Unit,
    ): PcCameraAvailability {
        val availability = availability(context)
        if (availability != PcCameraAvailability.AVAILABLE) return availability
        delivered.set(false)
        unavailableReported.set(false)
        active.set(true)
        val future = providerFuture(context)
        future.addListener(
            {
                try {
                    val cameraProvider = future.get()
                    provider = cameraProvider
                    val preview = Preview.Builder().build().also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                    val analyzer = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setTargetResolution(Size(1280, 720))
                        .build()
                    analyzer.setAnalyzer(executor) { image ->
                        try {
                            if (!delivered.get()) {
                                val text = decodeImage(image)
                                if (text != null && delivered.compareAndSet(false, true)) {
                                    onDecoded(text)
                                }
                            }
                        } finally {
                            image.close()
                        }
                    }
                    analysis = analyzer
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        analyzer,
                    )
                } catch (_: Exception) {
                    // A camera that disappears between the feature check and bind
                    // is the same user-visible state as no camera. Settle the
                    // decode gate first so a frame racing the failure cannot
                    // navigate the page after this failure is reported.
                    delivered.set(true)
                    // A cancel/close while the provider is still resolving has
                    // already left the page; its late failure must not reopen the
                    // unavailable state after the person dismissed the scanner.
                    val reportUnavailable = active.getAndSet(false)
                    try {
                        stop()
                    } finally {
                        if (reportUnavailable && unavailableReported.compareAndSet(false, true)) {
                            onUnavailable()
                        }
                    }
                }
            },
            ContextCompat.getMainExecutor(context),
        )
        return PcCameraAvailability.AVAILABLE
    }

    fun stop() {
        active.set(false)
        analysis?.clearAnalyzer()
        analysis = null
        provider?.unbindAll()
        provider = null
    }

    override fun close() {
        stop()
        executor.shutdownNow()
    }

    companion object {
        /**
         * The one camera fact the page reports. Feature absence is checked
         * separately from the runtime grant: an emulator without a camera must
         * say "no camera", not "permission denied".
         */
        fun availability(context: Context): PcCameraAvailability {
            val hasCamera = context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
            if (!hasCamera) return PcCameraAvailability.UNAVAILABLE
            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
            return if (granted) PcCameraAvailability.AVAILABLE else PcCameraAvailability.DENIED
        }

        /** CameraX `ImageProxy` -> ZXing, using only the Y (luminance) plane. */
        fun decodeImage(image: ImageProxy): String? {
            val plane = image.planes.firstOrNull() ?: return null
            val width = image.width
            val height = image.height
            if (width <= 0 || height <= 0) return null
            val buffer = plane.buffer.duplicate()
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            if (rowStride <= 0 || pixelStride <= 0) return null
            val needed = (height - 1) * rowStride + (width - 1) * pixelStride + 1
            if (buffer.remaining() < needed) return null
            val luminance = ByteArray(width * height)
            if (pixelStride == 1 && rowStride == width) {
                buffer.get(luminance, 0, minOf(buffer.remaining(), luminance.size))
            } else {
                for (row in 0 until height) {
                    val rowStart = row * rowStride
                    for (column in 0 until width) {
                        luminance[row * width + column] = buffer.get(rowStart + column * pixelStride)
                    }
                }
            }
            return decodeLuminance(luminance, width, height, image.imageInfo.rotationDegrees)
        }

        /**
         * Decodes a QR code from an 8-bit luminance plane. This is the testable
         * half of [decodeImage]; `rotationDegrees` is CameraX's clockwise
         * rotation, so the buffer is rotated clockwise before ZXing sees it.
         */
        fun decodeLuminance(
            luminance: ByteArray,
            width: Int,
            height: Int,
            rotationDegrees: Int = 0,
        ): String? {
            if (width <= 0 || height <= 0 || luminance.size < width * height) return null
            val (rotated, rotatedWidth, rotatedHeight) = rotate(luminance, width, height, rotationDegrees)
            val source = PlanarYUVLuminanceSource(
                rotated,
                rotatedWidth,
                rotatedHeight,
                0,
                0,
                rotatedWidth,
                rotatedHeight,
                false,
            )
            val hints = mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
                DecodeHintType.CHARACTER_SET to "UTF-8",
            )
            val reader = MultiFormatReader()
            return try {
                val result: Result = reader.decode(BinaryBitmap(HybridBinarizer(source)), hints)
                result.text
            } catch (_: NotFoundException) {
                null
            } catch (_: Exception) {
                null
            } finally {
                reader.reset()
            }
        }

        private fun rotate(
            luminance: ByteArray,
            width: Int,
            height: Int,
            rotationDegrees: Int,
        ): Triple<ByteArray, Int, Int> {
            val degrees = ((rotationDegrees % 360) + 360) % 360
            return when (degrees) {
                90 -> {
                    val out = ByteArray(width * height)
                    for (row in 0 until height) {
                        for (column in 0 until width) {
                            out[column * height + (height - 1 - row)] = luminance[row * width + column]
                        }
                    }
                    Triple(out, height, width)
                }
                180 -> {
                    val out = ByteArray(width * height)
                    for (index in 0 until width * height) {
                        out[width * height - 1 - index] = luminance[index]
                    }
                    Triple(out, width, height)
                }
                270 -> {
                    val out = ByteArray(width * height)
                    for (row in 0 until height) {
                        for (column in 0 until width) {
                            out[(width - 1 - column) * height + row] = luminance[row * width + column]
                        }
                    }
                    Triple(out, height, width)
                }
                else -> Triple(luminance, width, height)
            }
        }
    }
}
