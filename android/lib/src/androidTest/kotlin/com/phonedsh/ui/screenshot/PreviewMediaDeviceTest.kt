// The video and audio bodies on a real device: a real decoder, a real audio track.
// SPDX-License-Identifier: MIT
//
// L29 left these two kinds as honest cards ("需要生命周期与音频焦点，本次没安排",
// `docs/receipts/l29-preview/README.md` §6). These tests mount the **real**
// `PreviewPage` over the **real** app-private workspace and assert what a person
// would see and hear:
//
//   1. an `.m4a` opens: the card shows the name and the decoder's own duration;
//   2. 播放 starts it — the transport flips to 暂停 and the clock advances (a
//      `MediaPlayer` that merely accepted `start()` but decoded nothing would leave
//      the playhead at 0:00);
//   3. leaving the page stops it: the audio card is gone and the system reports no
//      active music track, which is the "audio keeps playing under another screen"
//      bug this lane exists to prevent;
//   4. an `.mp4` opens and plays the same way, and the page captures the frame (a
//      `TextureView`, not a `SurfaceView`, so the screenshot is the picture);
//   5. a corrupt media file lands in the ordinary 无法预览 + 原因 + 重试 card, and
//      重试 re-opens the player once the bytes are actually a media file;
//   6. another app taking the audio focus pauses the player and the card says so.
//
// The two fixtures (`assets/preview/clip.mp4`, `tone.m4a`) are real H.264/AAC files
// generated once with ffmpeg; the test copies them into the workspace, so the codec
// path exercised here is the same one a user's file takes.
package com.phonedsh.ui.screenshot

import android.graphics.Bitmap
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.lifecycle.Lifecycle
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.surface.preview.PreviewWorkspace
import com.phonedsh.ui.theme.PdshTheme
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PreviewMediaDeviceTest {

    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    /** The workspace the app reads by default. */
    private lateinit var workspace: File

    /** The route on top of the stack; recomposing on change swaps the screen. */
    private var route by mutableStateOf<PdshRoute>(PdshRoute.Home)

    private val audio: AudioManager
        get() = compose.activity.getSystemService(AudioManager::class.java)

    @Before
    fun prepareWorkspace() {
        workspace = PreviewWorkspace.defaultRoot(compose.activity.filesDir).toFile()
        workspace.deleteRecursively()
        assertTrue("cannot create the workspace $workspace", workspace.mkdirs())
    }

    // ------------------------------------------------------------------- audio

    @Test
    fun anAudioFilePlaysAndLeavingThePageStopsIt() {
        copyAsset("preview/tone.m4a", "tone.m4a")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("tone.m4a"))))

        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_MEDIA_DURATION).fetchSemanticsNodes()
                .isNotEmpty()
        }
        // The card states the decoder's own duration, not a guess from the file size.
        compose.onNodeWithTag(UiPageTags.PREVIEW_AUDIO).assertExists()
        compose.onNodeWithText(UiStrings.PREVIEW_MEDIA_DURATION.format("0:06")).assertExists()
        compose.onNodeWithText(UiStrings.PREVIEW_PLAY).assertExists()
        record("audio duration=${textOf(UiPageTags.PREVIEW_MEDIA_DURATION)}")
        evidence("preview-audio-ready", UiPageTags.PREVIEW_ROOT)

        compose.onNodeWithTag(UiPageTags.PREVIEW_PLAY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_PAUSE).fetchSemanticsNodes().isNotEmpty()
        }
        // The playhead moving is the proof that sound is being decoded, not just
        // that `start()` returned without throwing.
        val atStart = textOf(UiPageTags.PREVIEW_MEDIA_TIME)
        compose.waitUntil(TIMEOUT_MS) { textOf(UiPageTags.PREVIEW_MEDIA_TIME) != atStart }
        record(
            "audio clock advanced $atStart -> ${textOf(UiPageTags.PREVIEW_MEDIA_TIME)} " +
                "isMusicActive=${audio.isMusicActive}",
        )
        assertTrue("no music track is registered while『暂停』is on screen", audio.isMusicActive)
        evidence("preview-audio-playing", UiPageTags.PREVIEW_ROOT)

        // Leave the page: one route pop. The card must disappear and the system must
        // report that no track is playing any more.
        swapTo(PdshRoute.Home)
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_ROOT).fetchSemanticsNodes().isEmpty()
        }
        compose.waitUntil(TIMEOUT_MS) { !audio.isMusicActive }
        record("audio isMusicActive after leaving=${audio.isMusicActive}")

        // Coming back builds a fresh session: paused at 0:00, never resuming on its own.
        swapTo(PdshRoute.Preview("tone.m4a"))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_AUDIO).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_PLAY).assertExists()
        compose.onNodeWithText(UiStrings.PREVIEW_PAUSE).assertDoesNotExist()
        record("audio after returning position=${textOf(UiPageTags.PREVIEW_MEDIA_TIME)}")
        evidence("preview-audio-returned", UiPageTags.PREVIEW_ROOT)
    }

    @Test
    fun anotherAppsFocusRequestPausesTheAudioAndSaysWhy() {
        copyAsset("preview/tone.m4a", "tone.m4a")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("tone.m4a"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_MEDIA_DURATION).fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_PLAY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_PAUSE).fetchSemanticsNodes().isNotEmpty()
        }

        // Another app takes the sound away. Two focus requests from one process are
        // still two clients, so the preview's listener gets AUDIOFOCUS_LOSS.
        val rival = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setOnAudioFocusChangeListener(
                AudioManager.OnAudioFocusChangeListener { },
                Handler(Looper.getMainLooper()),
            )
            .build()
        try {
            assertEquals(
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED,
                audio.requestAudioFocus(rival),
            )
            compose.waitUntil(TIMEOUT_MS) {
                compose.onAllNodesWithText(UiStrings.PREVIEW_PLAYBACK_FOCUS_PAUSED)
                    .fetchSemanticsNodes().isNotEmpty()
            }
            // The pause was not the user's: the transport offers 播放 again and the
            // card names the reason.
            compose.onNodeWithText(UiStrings.PREVIEW_PLAY).assertExists()
            compose.onNodeWithTag(UiPageTags.PREVIEW_NOTICE).assertExists()
            record("audio focus lost -> ${UiStrings.PREVIEW_PLAYBACK_FOCUS_PAUSED}")
            evidence("preview-audio-focus-lost", UiPageTags.PREVIEW_ROOT)
        } finally {
            audio.abandonAudioFocusRequest(rival)
        }
    }

    @Test
    fun backgroundingTheAppStopsTheSoundAndDoesNotResumeOnReturn() {
        copyAsset("preview/tone.m4a", "tone.m4a")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("tone.m4a"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_MEDIA_DURATION).fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_PLAY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_PAUSE).fetchSemanticsNodes().isNotEmpty()
        }
        // The track registers with the mixer a moment after `start()`: wait for the
        // system to agree that sound is being produced before pressing HOME.
        compose.waitUntil(TIMEOUT_MS) { audio.isMusicActive }
        record("audio isMusicActive before backgrounding=${audio.isMusicActive}")

        // HOME, not a route pop: the composition stays, so only ON_STOP can stop it.
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        compose.waitUntil(TIMEOUT_MS) { !audio.isMusicActive }
        record("audio isMusicActive in background=${audio.isMusicActive}")

        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.waitForIdle()
        // Coming back must not start talking on its own: the transport is 播放 again.
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_PLAY).fetchSemanticsNodes().isNotEmpty()
        }
        assertTrue("no sound after returning", !audio.isMusicActive)
        record("audio after returning from background=${UiStrings.PREVIEW_PLAY}")
    }

    // ------------------------------------------------------------------- video

    @Test
    fun aVideoFileDecodesPlaysAndShowsAFrame() {
        copyAsset("preview/clip.mp4", "clip.mp4")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("clip.mp4"))))

        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_MEDIA_TIME).fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_VIDEO).assertExists()
        // The total is the demuxer's answer: the container and its H.264 track were
        // accepted, and the transport prints the length it measured.
        val ready = textOf(UiPageTags.PREVIEW_MEDIA_TIME)
        assertEquals(UiStrings.PREVIEW_MEDIA_TIME.format("0:00", "0:04"), ready)
        record("video transport=$ready")
        // The poster frame is a decoder round-trip (seek → decode → SurfaceTexture
        // draw), so give it a beat before photographing it.
        Thread.sleep(POSTER_FRAME_MS)
        evidence("preview-video-ready", UiPageTags.PREVIEW_ROOT)

        val atStart = textOf(UiPageTags.PREVIEW_MEDIA_TIME)
        compose.onNodeWithTag(UiPageTags.PREVIEW_PLAY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_PAUSE).fetchSemanticsNodes().isNotEmpty()
        }
        compose.waitUntil(TIMEOUT_MS) { textOf(UiPageTags.PREVIEW_MEDIA_TIME) != atStart }
        record(
            "video clock advanced $atStart -> ${textOf(UiPageTags.PREVIEW_MEDIA_TIME)} " +
                "isMusicActive=${audio.isMusicActive}",
        )
        assertTrue("the video's audio track is playing", audio.isMusicActive)
        evidence("preview-video-playing", UiPageTags.PREVIEW_ROOT)

        // 暂停 gives the sound back: no track is active once the transport says 播放.
        compose.onNodeWithTag(UiPageTags.PREVIEW_PLAY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText(UiStrings.PREVIEW_PLAY).fetchSemanticsNodes().isNotEmpty()
        }
        compose.waitUntil(TIMEOUT_MS) { !audio.isMusicActive }
        record("video isMusicActive after pause=${audio.isMusicActive}")
        evidence("preview-video-paused", UiPageTags.PREVIEW_ROOT)
    }

    // ----------------------------------------------------------------- failure

    @Test
    fun aCorruptMediaFileEndsInCannotPreviewWithRetry() {
        // 4 KiB of 0x7f: a `.wav` extension the classifier believes and a decoder that
        // refuses it. The page must say 无法预览 + why + 重试 — never a black card.
        File(workspace, "broken.wav").writeBytes(ByteArray(4096) { 0x7f })
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("broken.wav"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_FAILED).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_UNAVAILABLE).assertExists()
        compose.onNodeWithTag(UiPageTags.PREVIEW_RETRY).assertExists()
        val reasons = listOf(
            UiStrings.PREVIEW_PLAYBACK_FAILED_IO,
            UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED,
            UiStrings.PREVIEW_PLAYBACK_FAILED_UNSUPPORTED,
            UiStrings.PREVIEW_PLAYBACK_FAILED_TIMED_OUT,
            UiStrings.PREVIEW_PLAYBACK_FAILED_CRASHED,
            UiStrings.PREVIEW_PLAYBACK_FAILED_UNKNOWN,
        )
        val printed = reasons.filter {
            compose.onAllNodesWithText(it).fetchSemanticsNodes().isNotEmpty()
        }
        assertTrue("the failure card must name the decoder's reason", printed.isNotEmpty())
        record("media failure reason=$printed")
        // The card is the honest one, not the unsupported card.
        compose.onNodeWithTag(UiPageTags.PREVIEW_UNSUPPORTED).assertDoesNotExist()
        evidence("preview-media-failed", UiPageTags.PREVIEW_ROOT)

        // 重试 is a fresh start: the same path now holds a real 16-bit PCM WAV.
        writeWav("broken.wav", seconds = 2)
        compose.onNodeWithTag(UiPageTags.PREVIEW_RETRY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_MEDIA_DURATION).fetchSemanticsNodes()
                .isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_PLAY).assertExists()
        compose.onNodeWithTag(UiPageTags.PREVIEW_FAILED).assertDoesNotExist()
        record("media retry recovered duration=${textOf(UiPageTags.PREVIEW_MEDIA_DURATION)}")
        evidence("preview-media-recovered", UiPageTags.PREVIEW_ROOT)
    }

    // --------------------------------------------------------------- harness

    private fun mount(nav: PdshNavState) {
        route = nav.current
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()
    }

    /** Swaps the top route of the already-composed host (one `setContent` per test). */
    private fun swapTo(next: PdshRoute) {
        route = next
        compose.waitForIdle()
    }

    /** The visible text of the node carrying [tag]. */
    private fun textOf(tag: String): String =
        compose.onNodeWithTag(tag).fetchSemanticsNode()
            .config[SemanticsProperties.Text]
            .joinToString(separator = "") { it.text }

    /** Captures the page and writes it (plus a fact line) off the device. */
    private fun evidence(name: String, tag: String) {
        val bitmap: Bitmap = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        val directory = compose.activity.getExternalFilesDir(null) ?: compose.activity.filesDir
        val out = File(directory, "l32-media").apply { mkdirs() }
        File(out, "$name.png").outputStream().use { stream ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                "failed to encode $name.png"
            }
        }
        record(
            "capture name=$name width=${bitmap.width} height=${bitmap.height} " +
                "file=${File(out, "$name.png").absolutePath}",
        )
    }

    /** One evidence line, appended to `l32-media/facts.txt` on the device. */
    private fun record(line: String) {
        val directory = compose.activity.getExternalFilesDir(null) ?: compose.activity.filesDir
        val out = File(directory, "l32-media").apply { mkdirs() }
        File(out, "facts.txt").appendText(line + "\n")
    }

    /** Copies a fixture from the test APK's assets into the workspace. */
    private fun copyAsset(assetPath: String, relative: String): File {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val target = File(workspace, relative)
        target.parentFile?.mkdirs()
        assets.open(assetPath).use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        assertTrue("fixture $assetPath is empty", target.length() > 0)
        return target
    }

    /** A real 16-bit PCM mono WAV, written by hand (44-byte header + samples). */
    private fun writeWav(relative: String, seconds: Int, sampleRate: Int = 8000): File {
        val samples = sampleRate * seconds
        val dataSize = samples * 2
        val bytes = ByteArrayOutputStream()
        fun le16(value: Int) {
            bytes.write(value and 0xFF)
            bytes.write((value shr 8) and 0xFF)
        }

        fun le32(value: Int) {
            le16(value and 0xFFFF)
            le16((value shr 16) and 0xFFFF)
        }

        bytes.write("RIFF".toByteArray())
        le32(36 + dataSize)
        bytes.write("WAVE".toByteArray())
        bytes.write("fmt ".toByteArray())
        le32(16)
        le16(1) // PCM
        le16(1) // mono
        le32(sampleRate)
        le32(sampleRate * 2) // byte rate
        le16(2) // block align
        le16(16) // bits per sample
        bytes.write("data".toByteArray())
        le32(dataSize)
        for (index in 0 until samples) {
            val sample = (sin(2 * PI * 440.0 * index / sampleRate) * 6000).toInt()
            le16(sample and 0xFFFF)
        }
        val target = File(workspace, relative)
        target.parentFile?.mkdirs()
        target.writeBytes(bytes.toByteArray())
        return target
    }

    private companion object {
        /** Generous: a cold emulator can take a few seconds for the first frame. */
        const val TIMEOUT_MS: Long = 20_000L

        /** How long the poster frame's seek + decode + draw is given before capture. */
        const val POSTER_FRAME_MS: Long = 900L
    }
}
