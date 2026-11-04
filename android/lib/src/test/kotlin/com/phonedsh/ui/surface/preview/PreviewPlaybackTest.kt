// The player's three decisions, driven without a decoder, an audio HAL or a device.
// SPDX-License-Identifier: MIT
//
// `MediaPlayer` needs a `Context`, a `Looper` and a `Surface`, so the session in
// `PreviewPlayback.kt` cannot run in the JVM suite. What *can* run — and what the
// device test then only has to confirm rather than discover — is everything the
// session decides from a callback:
//
//   * the playhead's state machine (`preparing → ready → playing ⇄ paused → ended`,
//     plus the failure branch that becomes 无法预览's reason);
//   * the audio-focus table (`AudioManager.AUDIOFOCUS_*` → pause / duck / restore);
//   * the clock both bodies print, and the decoder error taxonomy in words.
//
// The two platform constants blocks below (`AudioManager.AUDIOFOCUS_*`,
// `MediaPlayer.MEDIA_ERROR_*`) are compile-time Java constants, so pinning them here
// needs no Android runtime — and pinning them is the point: a mis-mapped focus code
// would duck when it should stop.
package com.phonedsh.ui.surface.preview

import android.media.AudioManager
import android.media.MediaPlayer
import com.phonedsh.ui.UiStrings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewPlaybackTest {

    // ------------------------------------------------------------- the state machine

    @Test
    fun `a prepared player is ready but silent`() {
        val state = PreviewPlaybackState().prepared(durationMs = 32_000)
        assertEquals(PreviewPlaybackPhase.READY, state.phase)
        assertEquals(32_000L, state.durationMs)
        assertFalse(state.isPlaying)
        assertTrue("a tap can start it", state.canPlay)
        assertFalse("there is nothing to pause", state.canPause)
        assertNull(state.failure)
        assertFalse(state.focusPaused)
    }

    @Test
    fun `playing then pausing keeps the playhead`() {
        val state = PreviewPlaybackState()
            .prepared(durationMs = 32_000)
            .started()
            .positioned(7_000)
            .paused(7_000)
        assertEquals(PreviewPlaybackPhase.PAUSED, state.phase)
        assertEquals(7_000L, state.positionMs)
        assertTrue(state.canPlay)
        assertFalse(state.canPause)
        assertFalse("the user paused this one", state.focusPaused)
    }

    @Test
    fun `a focus pause says who took the sound, and playing clears it`() {
        val paused = PreviewPlaybackState()
            .prepared(durationMs = 1_000)
            .started()
            .paused(1_500, byFocus = true)
        assertTrue(paused.focusPaused)
        assertEquals(PreviewPlaybackPhase.PAUSED, paused.phase)

        val resumed = paused.started(positionMs = 1_500)
        assertFalse("the notice is about the current pause, not the last one", resumed.focusPaused)
        assertTrue(resumed.isPlaying)
    }

    @Test
    fun `the ticker moves the playhead only while playing`() {
        val prepared = PreviewPlaybackState().prepared(durationMs = 9_000)
        assertEquals("a prepared player has no playhead to move", prepared, prepared.positioned(4_000))

        val paused = prepared.started().paused(3_000)
        assertEquals(paused, paused.positioned(8_000))

        val playing = prepared.started().positioned(2_000)
        assertEquals(2_000L, playing.positionMs)
        // A platform that reports a negative position must not produce a negative clock.
        assertEquals(0L, playing.positioned(-5).positionMs)
    }

    @Test
    fun `completion parks the playhead at the end and re-offers play`() {
        val ended = PreviewPlaybackState()
            .prepared(durationMs = 2_000)
            .started()
            .positioned(1_900)
            .ended()
        assertEquals(PreviewPlaybackPhase.ENDED, ended.phase)
        assertEquals(2_000L, ended.positionMs)
        assertTrue("the track can be played again", ended.canPlay)
        assertFalse(ended.isPlaying)
    }

    @Test
    fun `a failure carries the reason and stops offering the transport`() {
        val failed = PreviewPlaybackState()
            .prepared(durationMs = 2_000)
            .started()
            .paused(500, byFocus = true)
            .failed(UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED)
        assertEquals(PreviewPlaybackPhase.FAILED, failed.phase)
        assertTrue(failed.isFailed)
        assertEquals(UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED, failed.failure)
        assertFalse(failed.focusPaused)
        assertFalse("no transport on a failed file", failed.canPlay)
        assertFalse(failed.canPause)
    }

    @Test
    fun `the transport verbs are offered exactly when a tap can act`() {
        val table = mapOf(
            PreviewPlaybackPhase.PREPARING to (false to false),
            PreviewPlaybackPhase.READY to (true to false),
            PreviewPlaybackPhase.PLAYING to (false to true),
            PreviewPlaybackPhase.PAUSED to (true to false),
            PreviewPlaybackPhase.ENDED to (true to false),
            PreviewPlaybackPhase.FAILED to (false to false),
        )
        table.forEach { (phase, expected) ->
            val state = PreviewPlaybackState(phase = phase)
            assertEquals("$phase canPlay", expected.first, state.canPlay)
            assertEquals("$phase canPause", expected.second, state.canPause)
        }
    }

    // --------------------------------------------------------------- audio focus

    @Test
    fun `the five focus callbacks map to the platform constants`() {
        assertEquals(
            PreviewFocusChange.GAIN,
            previewFocusChangeOf(AudioManager.AUDIOFOCUS_GAIN),
        )
        assertEquals(
            PreviewFocusChange.GAIN_TRANSIENT,
            previewFocusChangeOf(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT),
        )
        assertEquals(
            PreviewFocusChange.LOSS,
            previewFocusChangeOf(AudioManager.AUDIOFOCUS_LOSS),
        )
        assertEquals(
            PreviewFocusChange.LOSS_TRANSIENT,
            previewFocusChangeOf(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT),
        )
        assertEquals(
            PreviewFocusChange.LOSS_TRANSIENT_CAN_DUCK,
            previewFocusChangeOf(AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK),
        )
        // `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` is a request, never a callback, so a
        // value this build does not know must not be reinterpreted as a pause.
        assertEquals(PreviewFocusChange.UNKNOWN, previewFocusChangeOf(99))
    }

    @Test
    fun `a loss pauses, a duckable loss lowers the volume, a gain restores`() {
        // The mapping the session applies, as a table: this is the whole policy.
        assertEquals(PreviewFocusAction.PAUSE, previewFocusAction(PreviewFocusChange.LOSS))
        assertEquals(
            PreviewFocusAction.PAUSE,
            previewFocusAction(PreviewFocusChange.LOSS_TRANSIENT),
        )
        assertEquals(
            PreviewFocusAction.DUCK,
            previewFocusAction(PreviewFocusChange.LOSS_TRANSIENT_CAN_DUCK),
        )
        assertEquals(PreviewFocusAction.RESTORE, previewFocusAction(PreviewFocusChange.GAIN))
        assertEquals(
            PreviewFocusAction.RESTORE,
            previewFocusAction(PreviewFocusChange.GAIN_TRANSIENT),
        )
        assertEquals(PreviewFocusAction.NONE, previewFocusAction(PreviewFocusChange.UNKNOWN))
        // A duck is not a pause: the platform explicitly allowed the app to keep going.
        assertTrue(DUCK_VOLUME in 0f..FULL_VOLUME)
        assertTrue(DUCK_VOLUME < FULL_VOLUME)
    }

    // ------------------------------------------------------------------- the clock

    @Test
    fun `the clock reads m ss and grows to h mm ss`() {
        assertEquals("0:00", formatClock(0))
        assertEquals("0:00", formatClock(-1))
        assertEquals("0:07", formatClock(7_000))
        assertEquals("0:59", formatClock(59_999))
        assertEquals("1:05", formatClock(65_000))
        assertEquals("59:59", formatClock(3_599_000))
        assertEquals("1:01:01", formatClock(3_661_000))
    }

    @Test
    fun `the time line omits the total when the decoder never reported one`() {
        assertEquals("0:07 / 0:32", formatMediaTime(7_000, 32_000))
        // `MediaPlayer.duration` answers -1 for a stream or an unparsed container; a
        // made-up total would be the same lie as a made-up file size.
        assertEquals("0:07", formatMediaTime(7_000, null))
        assertEquals("0:07", formatMediaTime(7_000, -1))
        assertEquals("0:07", formatMediaTime(7_000, 0))
        assertEquals(UiStrings.PREVIEW_MEDIA_TIME, "%s / %s")
    }

    // ----------------------------------------------------------------- the failure

    @Test
    fun `a malformed file is told apart from a missing codec`() {
        assertEquals(
            UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED,
            playbackFailureReason(MediaPlayer.MEDIA_ERROR_UNKNOWN, MediaPlayer.MEDIA_ERROR_MALFORMED),
        )
        assertEquals(
            UiStrings.PREVIEW_PLAYBACK_FAILED_UNSUPPORTED,
            playbackFailureReason(
                MediaPlayer.MEDIA_ERROR_UNKNOWN,
                MediaPlayer.MEDIA_ERROR_UNSUPPORTED,
            ),
        )
        assertEquals(
            UiStrings.PREVIEW_PLAYBACK_FAILED_IO,
            playbackFailureReason(MediaPlayer.MEDIA_ERROR_UNKNOWN, MediaPlayer.MEDIA_ERROR_IO),
        )
        assertEquals(
            UiStrings.PREVIEW_PLAYBACK_FAILED_TIMED_OUT,
            playbackFailureReason(
                MediaPlayer.MEDIA_ERROR_UNKNOWN,
                MediaPlayer.MEDIA_ERROR_TIMED_OUT,
            ),
        )
        assertEquals(
            UiStrings.PREVIEW_PLAYBACK_FAILED_CRASHED,
            playbackFailureReason(MediaPlayer.MEDIA_ERROR_SERVER_DIED, 0),
        )
        assertEquals(
            UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED,
            playbackFailureReason(MediaPlayer.MEDIA_ERROR_NOT_VALID_FOR_PROGRESSIVE_PLAYBACK, 0),
        )
    }

    @Test
    fun `an unknown decoder error still says something true`() {
        val reason = playbackFailureReason(MediaPlayer.MEDIA_ERROR_UNKNOWN, 0)
        assertEquals(UiStrings.PREVIEW_PLAYBACK_FAILED_UNKNOWN, reason)
        // Never the old placeholder: a failure a person cannot act on is still better
        // than one that claims the cause is unknown *and* says nothing.
        assertFalse(reason.contains(UiStrings.FILES_PREVIEW_REASON_UNKNOWN))
        assertTrue(reason.isNotEmpty())
    }
}
