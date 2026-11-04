// The playback state machine behind the video and audio bodies, as pure values.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:305` — PR #15 gives both kinds **one**
// player (`case .video, .audio: player = AVPlayer(url: url)`) and lets
// `VideoPlayer(player:)` draw the transport (`:384`). Android has neither an
// `AVPlayer` nor a free transport on a `TextureView`, so this lane owns three small
// decisions that a JVM test can pin without a decoder, an audio HAL or a device:
//
//   1. [PreviewPlaybackState] — preparing → ready → playing ⇄ paused → ended, plus
//      the failure branch whose reason becomes 无法预览's second line;
//   2. [previewFocusAction] — what an audio-focus change means for the player
//      (`AudioManager.requestAudioFocus`; L29 §10 Q4 asked for exactly this);
//   3. [formatMediaTime] — the one clock the audio card and the video transport
//      share, so the two bodies cannot disagree about what `0:07` means.
//
// The `MediaPlayer` itself lives in `PreviewPlayback.kt`: it needs a `Context`, a
// `Looper` and a `Surface`, none of which a JVM test has. Everything here is a
// function of its arguments, which is why the four-state matrix below can be
// asserted on the JVM instead of through an emulator.
package com.phonedsh.ui.surface.preview

import android.media.AudioManager
import android.media.MediaPlayer
import com.phonedsh.ui.UiStrings

/**
 * Where the player is in its own lifecycle.
 *
 * `MediaPlayer` has no public state query, so the session tracks this enum; the
 * names are the platform's own states (`prepareAsync` → Prepared → Started ⇄
 * Paused → PlaybackCompleted) plus the two Android-only ones a preview needs:
 * [FAILED] (the page turns into 无法预览 + 重试) and [PREPARING] (the baseline's
 * 「准备播放器…」, `:389`).
 */
internal enum class PreviewPlaybackPhase {
    /** `prepareAsync` is in flight; no duration, no frame, no sound yet. */
    PREPARING,

    /** Prepared and paused at the first frame: the surface can show it. */
    READY,

    /** Sound and picture are moving. */
    PLAYING,

    /** The user (or audio focus) paused it at [PreviewPlaybackState.positionMs]. */
    PAUSED,

    /** Playback completed; the playhead is parked at the duration. */
    ENDED,

    /** The decoder refused the file; [PreviewPlaybackState.failure] says why. */
    FAILED,
}

/**
 * One immutable snapshot of the player.
 *
 * @param phase the lifecycle position above.
 * @param durationMs the track length the decoder reported, or `null` when it never
 *   did (`MediaPlayer.duration` is `-1` for a stream or an unparsed container) — the
 *   body then says 时长未知 instead of inventing a number.
 * @param positionMs the playhead the transport prints; refreshed by the body's ticker
 *   while [phase] is [PreviewPlaybackPhase.PLAYING].
 * @param failure the reason 无法预览 prints after a decoder error; `null` otherwise.
 * @param focusPaused true when the pause was *not* the user's: another app owns the
 *   sound now (or denied the request), and the card says so.
 */
internal data class PreviewPlaybackState(
    val phase: PreviewPlaybackPhase = PreviewPlaybackPhase.PREPARING,
    val durationMs: Long? = null,
    val positionMs: Long = 0,
    val failure: String? = null,
    val focusPaused: Boolean = false,
) {
    /** The transport's 暂停 label is on screen exactly then. */
    val isPlaying: Boolean
        get() = phase == PreviewPlaybackPhase.PLAYING

    /** The baseline's 「准备播放器…」 (`:389`). */
    val isPreparing: Boolean
        get() = phase == PreviewPlaybackPhase.PREPARING

    /** The page is switching to 无法预览; the body draws nothing. */
    val isFailed: Boolean
        get() = phase == PreviewPlaybackPhase.FAILED

    /** A tap on 播放 would start or resume sound. */
    val canPlay: Boolean
        get() = phase == PreviewPlaybackPhase.READY ||
            phase == PreviewPlaybackPhase.PAUSED ||
            phase == PreviewPlaybackPhase.ENDED

    /** A tap on 暂停 would stop sound. */
    val canPause: Boolean
        get() = isPlaying

    /** `prepareAsync`'s answer: the surface may now paint the first frame. */
    fun prepared(durationMs: Long?): PreviewPlaybackState = copy(
        phase = PreviewPlaybackPhase.READY,
        durationMs = durationMs,
        failure = null,
    )

    /** `start()` returned: sound is moving. A replay from [PreviewPlaybackPhase.ENDED] restarts at 0. */
    fun started(positionMs: Long = 0): PreviewPlaybackState = copy(
        phase = PreviewPlaybackPhase.PLAYING,
        positionMs = positionMs,
        failure = null,
        focusPaused = false,
    )

    /** The ticker's sample while playing; every other phase keeps its playhead. */
    fun positioned(positionMs: Long): PreviewPlaybackState =
        if (isPlaying) copy(positionMs = positionMs.coerceAtLeast(0)) else this

    /** The user (or a focus loss) paused at [positionMs]. */
    fun paused(positionMs: Long, byFocus: Boolean = false): PreviewPlaybackState = copy(
        phase = PreviewPlaybackPhase.PAUSED,
        positionMs = positionMs.coerceAtLeast(0),
        focusPaused = byFocus,
    )

    /** `onCompletion`: the playhead parks at the end, the 播放 label returns. */
    fun ended(): PreviewPlaybackState = copy(
        phase = PreviewPlaybackPhase.ENDED,
        positionMs = durationMs ?: positionMs,
        focusPaused = false,
    )

    /** A decoder error, carrying the sentence 无法预览 will print. */
    fun failed(reason: String): PreviewPlaybackState = copy(
        phase = PreviewPlaybackPhase.FAILED,
        failure = reason,
        focusPaused = false,
    )
}

// ---------------------------------------------------------------- audio focus

/**
 * The five focus changes the platform can report to a player, named.
 *
 * The bare ints of `AudioManager.AUDIOFOCUS_*` are unreadable at the call site and
 * untestable without the platform jar; this enum is the mapping's single reader.
 */
internal enum class PreviewFocusChange {
    /** The app may play at full volume, permanently. */
    GAIN,

    /** Full volume for a short while (a call ended, a navigation prompt finished). */
    GAIN_TRANSIENT,

    /** The app lost the sound for good: stop, and give the request back. */
    LOSS,

    /** The app lost the sound briefly: pause, but keep the request for [GAIN]. */
    LOSS_TRANSIENT,

    /** Another app is audible: keep playing, but quieter. */
    LOSS_TRANSIENT_CAN_DUCK,

    /** A change this build does not know. */
    UNKNOWN,
}

/** Maps one `AudioManager.AUDIOFOCUS_*` constant to [PreviewFocusChange]. */
internal fun previewFocusChangeOf(change: Int): PreviewFocusChange = when (change) {
    AudioManager.AUDIOFOCUS_GAIN -> PreviewFocusChange.GAIN
    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT -> PreviewFocusChange.GAIN_TRANSIENT
    AudioManager.AUDIOFOCUS_LOSS -> PreviewFocusChange.LOSS
    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> PreviewFocusChange.LOSS_TRANSIENT
    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> PreviewFocusChange.LOSS_TRANSIENT_CAN_DUCK
    // `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` is a *request*, never a callback, so an
    // unknown value is a platform addition and is treated as "do nothing".
    else -> PreviewFocusChange.UNKNOWN
}

/** What the session does when the focus changes. */
internal enum class PreviewFocusAction {
    /** Stop the sound; a permanent loss also abandons the request. */
    PAUSE,

    /** Keep playing at [DUCK_VOLUME]. */
    DUCK,

    /** Restore full volume, and resume if the pause was a transient focus loss. */
    RESTORE,

    /** Nothing the app has to do. */
    NONE,
}

/**
 * The policy table: a focus change says one thing, and it is not the same thing
 * for a duckable loss as for a real one.
 *
 * `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` is deliberately *not* a pause: the platform
 * says the app may keep playing, and pausing under a navigation prompt would be as
 * wrong as talking over it. `AUDIOFOCUS_LOSS` and `_LOSS_TRANSIENT` both stop the
 * sound, and only the transient one keeps the request so [GAIN] can hand it back.
 */
internal fun previewFocusAction(change: PreviewFocusChange): PreviewFocusAction = when (change) {
    PreviewFocusChange.GAIN,
    PreviewFocusChange.GAIN_TRANSIENT,
    -> PreviewFocusAction.RESTORE

    PreviewFocusChange.LOSS,
    PreviewFocusChange.LOSS_TRANSIENT,
    -> PreviewFocusAction.PAUSE

    PreviewFocusChange.LOSS_TRANSIENT_CAN_DUCK -> PreviewFocusAction.DUCK

    PreviewFocusChange.UNKNOWN -> PreviewFocusAction.NONE
}

// ------------------------------------------------------------------ the clock

/**
 * `0:07 / 0:32`, or `0:07` when the decoder never reported a duration.
 *
 * The transport and the audio card both print this, so the two bodies cannot
 * disagree about whether the total is known.
 */
internal fun formatMediaTime(positionMs: Long, durationMs: Long?): String {
    val position = formatClock(positionMs)
    val total = durationMs?.takeIf { it > 0 } ?: return position
    return UiStrings.PREVIEW_MEDIA_TIME.format(position, formatClock(total))
}

/** `m:ss`, or `h:mm:ss` once the track is an hour long; negatives read as `0:00`. */
internal fun formatClock(milliseconds: Long): String {
    val totalSeconds = milliseconds.coerceAtLeast(0) / 1000
    val seconds = totalSeconds % 60
    val minutes = (totalSeconds / 60) % 60
    val hours = totalSeconds / 3600
    return if (hours > 0) {
        "%d:%02d:%02d".format(hours, minutes, seconds)
    } else {
        "%d:%02d".format(minutes, seconds)
    }
}

// ------------------------------------------------------------------- failure

/**
 * `MediaPlayer.setOnErrorListener`'s `(what, extra)` as a sentence a person can act
 * on, using the platform's own `MEDIA_ERROR_*` taxonomy.
 *
 * `what` is the coarse error (`MEDIA_ERROR_UNKNOWN`, `MEDIA_ERROR_SERVER_DIED`) and
 * `extra` carries the modern detail; a decoder that reports `UNKNOWN/MALFORMED` is
 * a corrupt file, while `UNKNOWN/UNSUPPORTED` is a missing codec — different fixes,
 * so they get different sentences. An unrecognised pair still says something true
 * instead of 原因未知.
 */
internal fun playbackFailureReason(what: Int, extra: Int): String = when {
    what == MediaPlayer.MEDIA_ERROR_SERVER_DIED -> UiStrings.PREVIEW_PLAYBACK_FAILED_CRASHED
    extra == MediaPlayer.MEDIA_ERROR_MALFORMED -> UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED
    extra == MediaPlayer.MEDIA_ERROR_UNSUPPORTED -> UiStrings.PREVIEW_PLAYBACK_FAILED_UNSUPPORTED
    extra == MediaPlayer.MEDIA_ERROR_IO -> UiStrings.PREVIEW_PLAYBACK_FAILED_IO
    extra == MediaPlayer.MEDIA_ERROR_TIMED_OUT -> UiStrings.PREVIEW_PLAYBACK_FAILED_TIMED_OUT
    what == MediaPlayer.MEDIA_ERROR_NOT_VALID_FOR_PROGRESSIVE_PLAYBACK ->
        UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED
    else -> UiStrings.PREVIEW_PLAYBACK_FAILED_UNKNOWN
}

/** The volume a ducked player keeps; a platform convention, not a UI token. */
internal const val DUCK_VOLUME: Float = 0.2f

/** What the player restores when the focus comes back. */
internal const val FULL_VOLUME: Float = 1f
