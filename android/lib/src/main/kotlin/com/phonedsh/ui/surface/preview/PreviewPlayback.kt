// The video and audio bodies: one `MediaPlayer`, one audio-focus request, one release.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:305` (`case .video, .audio: player =
// AVPlayer(url: url)`) and `:384` (`VideoPlayer(player:)`). PR #15 uses **one**
// player for both kinds; this file keeps that shape and pays the two costs iOS gets
// for free:
//
//   * **lifecycle.** An `AVPlayer` stops when the view that feeds it is torn down; a
//     `MediaPlayer` keeps decoding and keeps making sound until `release()`. Every
//     session here is created *and released* in a `DisposableEffect` keyed on the
//     file, so leaving the page — a route pop, another file, the failure card — stops
//     the audio. That is the bug this lane exists to prevent: sound that keeps
//     playing under a screen the user left. `ON_STOP` pauses too, because a preview
//     is not a background music player.
//   * **transport.** `VideoPlayer` brings its own play/pause chrome; a `TextureView`
//     brings none, so the body draws one 播放 / 暂停 action and a clock, and the audio
//     card reuses the same two pieces ([MediaTransport]).
//
// `TextureView`, not `SurfaceView`: a `SurfaceView`'s pixels live in a SurfaceFlinger
// layer outside the view hierarchy, so `captureToImage` — the gate this repo's
// screenshots go through — would photograph a black rectangle. A `TextureView`
// composites into the window and is captured like every other pixel, which is also
// what makes the device evidence for this lane a picture of an actual frame.
//
// Audio focus: `requestAudioFocus(AUDIOFOCUS_GAIN)` on play, `abandonAudioFocusRequest`
// on a user pause or on release, and the three loss flavours of [PreviewFocusAction]
// (pause, duck, restore). A transient loss is a loan and resumes on `GAIN`; a
// permanent one does not, and the card says who took the sound.
//
// No dependency was added. `android.media.MediaPlayer` is the platform decoder and it
// already handles every extension PR #15 lists for these two kinds — mp4/mov/m4v are
// ISO-BMFF containers whose H.264/H.265/MPEG-4 streams the platform demuxes, and
// mp3/m4a/wav/aac/flac all have platform decoders since API 26 (the module's
// `minSdk`). ExoPlayer would add a megabyte and a second lifecycle to own for one
// screen; `:lib` has never carried it (L29 §10 Q4 left the choice open).
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.HomeMetrics
import android.content.Context
import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.TextureView
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import java.io.File
import java.io.IOException
import java.nio.file.Path
import kotlinx.coroutines.delay

/**
 * The video body: a `TextureView` fed by `MediaPlayer`, with the shared transport.
 *
 * @param file the resolved file, or `null` while the route has not resolved it yet.
 * @param onFailure hands the decoder's reason to the page, which turns it into the
 *   ordinary 无法预览 + 原因 + 重试 card. The body does not draw a second failure card:
 *   one file, one honest state, one place to retry.
 */
@Composable
internal fun VideoBody(file: Path?, onFailure: (String) -> Unit) {
    if (file == null) {
        PreviewCenteredLine(UiStrings.PREVIEW_VIDEO_PREPARING, UiPageTags.PREVIEW_VIDEO)
        return
    }
    val tokens = LocalUiTokens.current
    val session = playbackSession(file, PreviewKind.VIDEO, onFailure)
    // Until the codec reports a size, a 16:9 box is the neutral shape every phone
    // video fits inside; once it does, the box follows the stream instead of
    // stretching it into whatever the screen happens to be.
    val aspect = session.videoAspect ?: DEFAULT_VIDEO_ASPECT
    Column(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .background(tokens.colors.surface),
            contentAlignment = Alignment.Center,
        ) {
            if (session.state.isPreparing) {
                PreviewCenteredLine(UiStrings.PREVIEW_VIDEO_PREPARING, UiPageTags.PREVIEW_VIDEO)
            } else {
                AndroidView(
                    factory = { context -> TextureView(context).also { it.attach(session) } },
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(aspect)
                        .testTag(UiPageTags.PREVIEW_VIDEO),
                    onRelease = { view ->
                        view.surfaceTextureListener = null
                        session.setSurface(null)
                    },
                )
            }
        }
        MediaTransport(state = session.state, onToggle = session::toggle)
    }
}

/**
 * The audio card: the file's name, its duration, the transport and — when another
 * app has the sound — the reason it is not playing.
 *
 * iOS renders audio through the same `VideoPlayer` as video (a black rectangle with
 * chrome); a phone has no business drawing a video surface for a file that has no
 * picture, so the card states what it knows instead.
 *
 * @param file the resolved file, or `null` while the route has not resolved it yet.
 * @param fileName the last path component, printed above the duration.
 * @param onFailure the decoder's reason, handed to the page's 无法预览 card.
 */
@Composable
internal fun AudioBody(file: Path?, fileName: String, onFailure: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    if (file == null) {
        PreviewCenteredLine(UiStrings.PREVIEW_VIDEO_PREPARING, UiPageTags.PREVIEW_AUDIO)
        return
    }
    val session = playbackSession(file, PreviewKind.AUDIO, onFailure)
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.PREVIEW_AUDIO)
            .padding(horizontal = HomeMetrics.contentInset),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(
            tokens.spacing.iconText,
            Alignment.CenterVertically,
        ),
    ) {
        BasicText(
            text = fileName,
            style = type.pageTitle.copy(color = tokens.colors.textPrimary, textAlign = TextAlign.Center),
            modifier = Modifier.testTag(UiPageTags.PREVIEW_MEDIA_NAME),
        )
        if (session.state.isPreparing) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                CircularProgressIndicator(
                    color = tokens.colors.textTertiary,
                    strokeWidth = tokens.stroke.hairline,
                    modifier = Modifier.size(tokens.geometry.composerControlSize),
                )
                BasicText(
                    text = UiStrings.PREVIEW_VIDEO_PREPARING,
                    style = type.listItem.copy(color = tokens.colors.textSecondary),
                )
            }
        } else {
            BasicText(
                text = session.state.durationMs?.let { duration ->
                    UiStrings.PREVIEW_MEDIA_DURATION.format(formatClock(duration))
                } ?: UiStrings.PREVIEW_MEDIA_DURATION_UNKNOWN,
                style = type.listItem.copy(color = tokens.colors.textTertiary),
                modifier = Modifier.testTag(UiPageTags.PREVIEW_MEDIA_DURATION),
            )
            MediaTransport(state = session.state, onToggle = session::toggle)
        }
    }
}

/**
 * One `MediaPlayer` and the audio-focus request it holds.
 *
 * Owned by the composition and disposed by it: [release] is the only way to stop the
 * sound, and it is called from the `DisposableEffect` in [playbackSession]. The
 * class is `internal` and takes a `Context`, so it is deliberately not JVM-testable;
 * the decisions it makes are in `PreviewPlaybackState.kt` where they are.
 */
internal class PreviewMediaSession(context: Context) {

    private val audioManager: AudioManager? =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private var player: MediaPlayer? = null
    private var focusRequest: AudioFocusRequest? = null
    private var surface: Surface? = null
    private var prepared = false
    private var resumeOnGain = false
    private var released = false
    private var contentType = AudioAttributes.CONTENT_TYPE_MUSIC
    private var kind = PreviewKind.AUDIO

    /** The transport's whole picture of the player. */
    var state by mutableStateOf(PreviewPlaybackState())
        private set

    /** The stream's width / height once the codec reports it; `null` before that. */
    var videoAspect by mutableStateOf<Float?>(null)
        private set

    /** True after [release]: the ticker and late platform callbacks stop caring. */
    val isReleased: Boolean
        get() = released

    /**
     * Opens [file] on a fresh player and starts `prepareAsync`.
     *
     * Every failure below — a source the platform refuses, a decoder that gives up —
     * becomes [PreviewPlaybackState.failure], which the page renders as its ordinary
     * 无法预览 + 原因 + 重试. Nothing here invents a success.
     */
    fun open(file: File, kind: PreviewKind) {
        if (released || player != null) return
        this.kind = kind
        contentType = if (kind == PreviewKind.VIDEO) {
            AudioAttributes.CONTENT_TYPE_MOVIE
        } else {
            AudioAttributes.CONTENT_TYPE_MUSIC
        }
        val created = MediaPlayer()
        player = created
        created.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(contentType)
                .build(),
        )
        created.setOnPreparedListener { preparedPlayer ->
            if (released) return@setOnPreparedListener
            prepared = true
            val duration = preparedPlayer.duration.takeIf { it > 0 }?.toLong()
            if (preparedPlayer.videoWidth > 0 && preparedPlayer.videoHeight > 0) {
                videoAspect = preparedPlayer.videoWidth.toFloat() / preparedPlayer.videoHeight
            }
            state = state.prepared(duration)
            // A TextureView can be ready before or after the codec; whichever arrives
            // second attaches the surface, so both orders end in the same place.
            surface?.let { preparedPlayer.setSurface(it) }
            // The first frame is asked for after the surface is attached (a paused
            // player paints nothing on its own) — see [showFirstFrame].
            showFirstFrame(preparedPlayer)
            Log.i(TAG, "prepared kind=$kind durationMs=${duration ?: -1} aspect=$videoAspect")
        }
        created.setOnCompletionListener {
            if (released) return@setOnCompletionListener
            state = state.ended()
            abandonFocus()
            Log.i(TAG, "completed")
        }
        created.setOnErrorListener { _, what, extra ->
            if (!released) fail(playbackFailureReason(what, extra))
            // Consumed: the listener's `true` keeps the platform from firing its own
            // onCompletion, and the page owns the failure card from here.
            true
        }
        try {
            created.setDataSource(file.absolutePath)
            created.prepareAsync()
            Log.i(TAG, "prepare kind=$kind file=${file.name}")
        } catch (_: IOException) {
            fail(UiStrings.PREVIEW_PLAYBACK_FAILED_IO)
        } catch (_: SecurityException) {
            fail(UiStrings.PREVIEW_PLAYBACK_FAILED_IO)
        } catch (_: IllegalArgumentException) {
            fail(UiStrings.PREVIEW_PLAYBACK_FAILED_MALFORMED)
        }
    }

    /**
     * Attaches (or detaches) the `TextureView`'s surface.
     *
     * A `MediaPlayer` accepts a surface from Initialized onwards; the session keeps
     * the latest one so the prepared listener can attach it when it arrives late.
     * Attaching a surface to a *paused* video paints nothing until a frame is asked
     * for, so the attach is also where the poster frame is requested — the usual
     * order here is "prepared, then the body draws the TextureView".
     */
    fun setSurface(next: Surface?) {
        surface = next
        val current = player ?: return
        if (released) return
        try {
            if (next == null) {
                current.setSurface(null)
            } else if (prepared) {
                current.setSurface(next)
                showFirstFrame(current)
            }
        } catch (_: IllegalStateException) {
            // The player was reset between the callback and this call; the next
            // prepared/surface pair re-attaches. Not worth a failure card.
            Log.i(TAG, "surface not attached: player not in a surface state")
        }
    }

    /**
     * Asks a paused video for its first frame, so the body shows the opening shot
     * instead of a blank box until 播放 is tapped.
     *
     * A seek in the Prepared/Paused state renders the target frame onto the surface;
     * that is the only way a `MediaPlayer` paints without starting playback (playing
     * for one frame would take the audio focus and make a click).
     */
    private fun showFirstFrame(current: MediaPlayer) {
        if (kind != PreviewKind.VIDEO || state.isPlaying) return
        if ((state.durationMs ?: 0) <= FIRST_FRAME_MS) return
        try {
            current.seekTo(FIRST_FRAME_MS.toInt())
        } catch (_: IllegalStateException) {
            // A codec that refuses the seek still plays; the frame arrives on 播放.
        }
    }

    /** 播放 / 暂停: the only transport gesture the body offers. */
    fun toggle() {
        val current = player ?: return
        if (released) return
        when (state.phase) {
            PreviewPlaybackPhase.PLAYING -> pause(byFocus = false)
            PreviewPlaybackPhase.READY,
            PreviewPlaybackPhase.PAUSED,
            PreviewPlaybackPhase.ENDED,
            -> play(current)
            // A tap while preparing or failed is not offered by the UI (the action is
            // disabled), but a stale gesture must not throw.
            PreviewPlaybackPhase.PREPARING,
            PreviewPlaybackPhase.FAILED,
            -> Unit
        }
    }

    /** Samples the playhead for the clock; called by the body's ticker. */
    fun refreshPosition() {
        val current = player ?: return
        if (released || !state.isPlaying) return
        val position = try {
            current.currentPosition.toLong()
        } catch (_: IllegalStateException) {
            return
        }
        state = state.positioned(position)
    }

    /**
     * `ON_STOP`: the app is no longer in front, so the preview stops making sound.
     *
     * It does not resume on `ON_START` — a preview that starts talking when the user
     * comes back is worse than one that waits for a tap.
     */
    fun pauseForBackground() {
        if (released || !state.isPlaying) return
        resumeOnGain = false
        pause(byFocus = false)
        Log.i(TAG, "pause for background")
    }

    /**
     * Stops the sound and gives the platform back everything this session holds.
     *
     * Idempotent, and safe to call from either disposal path (`DisposableEffect` or
     * the `TextureView` release); no callback below is allowed to throw into the
     * composition.
     */
    fun release() {
        if (released) return
        released = true
        abandonFocus()
        surface = null
        prepared = false
        val current = player
        player = null
        if (current != null) {
            try {
                current.setSurface(null)
            } catch (_: IllegalStateException) {
                // The player was already reset; the release below is what matters.
            }
            try {
                current.reset()
            } catch (_: IllegalStateException) {
                // Same: a player that cannot reset is still released.
            }
            current.release()
        }
        Log.i(TAG, "release")
    }

    // ---------------------------------------------------------------- internals

    private fun play(current: MediaPlayer) {
        if (!requestFocus()) {
            // The platform said no: claim the pause and say who has the sound.
            state = state.paused(state.positionMs, byFocus = true)
            Log.i(TAG, "play refused: audio focus not granted")
            return
        }
        try {
            current.start()
        } catch (_: IllegalStateException) {
            fail(UiStrings.PREVIEW_PLAYBACK_FAILED_UNKNOWN)
            return
        }
        resumeOnGain = false
        // A replay from PlaybackCompleted restarts the track, so the clock does too.
        val position = if (state.phase == PreviewPlaybackPhase.ENDED) 0L else state.positionMs
        state = state.started(position)
        Log.i(TAG, "start positionMs=$position")
    }

    private fun pause(byFocus: Boolean) {
        val current = player ?: return
        if (released) return
        val position = try {
            current.currentPosition.toLong()
        } catch (_: IllegalStateException) {
            state.positionMs
        }
        try {
            current.pause()
        } catch (_: IllegalStateException) {
            return
        }
        state = state.paused(position, byFocus = byFocus)
        if (!byFocus) abandonFocus()
        Log.i(TAG, "pause byFocus=$byFocus positionMs=$position")
    }

    private fun fail(reason: String) {
        state = state.failed(reason)
        Log.i(TAG, "failed reason=$reason")
    }

    /**
     * Asks for exclusive media focus.
     *
     * `AUDIOFOCUS_GAIN` (not `_GAIN_TRANSIENT`): a file preview takes the sound the
     * way a video player does, and pauses the music behind it. The listener is bound
     * to the main looper because the callbacks mutate Compose state.
     */
    private fun requestFocus(): Boolean {
        val manager = audioManager ?: return true
        // Reuse the live request instead of building a second one: a transient loss
        // keeps its request so GAIN can hand the sound back, and a fresh request per
        // play would leave the old client registered for the app's lifetime.
        val request = focusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(contentType)
                    .build(),
            )
            .setAcceptsDelayedFocusGain(false)
            // The card can pause; it never needs the platform to duck for it.
            .setWillPauseWhenDucked(false)
            .setOnAudioFocusChangeListener(
                { change -> onFocusChange(change) },
                Handler(Looper.getMainLooper()),
            )
            .build()
            .also { focusRequest = it }
        val granted =
            manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        Log.i(TAG, "audio focus requested granted=$granted")
        return granted
    }

    private fun abandonFocus() {
        val manager = audioManager ?: return
        val request = focusRequest ?: return
        focusRequest = null
        Log.i(TAG, "audio focus abandoned")
        manager.abandonAudioFocusRequest(request)
    }

    /** Applies [previewFocusAction] to the player, which is the whole focus policy. */
    private fun onFocusChange(change: Int) {
        if (released) return
        val current = player ?: return
        when (previewFocusAction(previewFocusChangeOf(change))) {
            PreviewFocusAction.PAUSE -> {
                // A transient loss is a loan: keep the request so GAIN can hand the
                // sound back; a permanent loss gives it away.
                resumeOnGain =
                    state.isPlaying && change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
                if (state.isPlaying) pause(byFocus = true)
                if (change == AudioManager.AUDIOFOCUS_LOSS) abandonFocus()
                Log.i(TAG, "focus change=$change pause resumeOnGain=$resumeOnGain")
            }

            PreviewFocusAction.DUCK -> {
                current.setVolume(DUCK_VOLUME, DUCK_VOLUME)
                Log.i(TAG, "focus change=$change duck")
            }

            PreviewFocusAction.RESTORE -> {
                current.setVolume(FULL_VOLUME, FULL_VOLUME)
                if (resumeOnGain) {
                    resumeOnGain = false
                    play(current)
                }
                Log.i(TAG, "focus change=$change restore")
            }

            PreviewFocusAction.NONE -> Unit
        }
    }

    private companion object {
        const val TAG: String = "PdshPreview"
    }
}

// --------------------------------------------------------------------- pieces

/**
 * The shared transport: 播放 / 暂停, the clock, and the focus notice.
 *
 * One composable for both kinds, so the video body and the audio card can never
 * label the same state differently.
 */
@Composable
private fun MediaTransport(state: PreviewPlaybackState, onToggle: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
    ) {
        Row(
            modifier = Modifier.padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
        ) {
            PlayToggle(state = state, onToggle = onToggle)
            BasicText(
                text = formatMediaTime(state.positionMs, state.durationMs),
                style = type.listItem.copy(color = tokens.colors.textSecondary),
                modifier = Modifier.testTag(UiPageTags.PREVIEW_MEDIA_TIME),
            )
        }
        if (state.focusPaused) {
            // The source of the pause, not a generic "paused": the user did not do it.
            BasicText(
                text = UiStrings.PREVIEW_PLAYBACK_FOCUS_PAUSED,
                style = type.listItem.copy(
                    color = tokens.colors.textSecondary,
                    textAlign = TextAlign.Center,
                ),
                modifier = Modifier.testTag(UiPageTags.PREVIEW_NOTICE),
            )
        }
    }
}

/**
 * The one transport verb: 播放 while a tap would start or resume, 暂停 while sound is
 * moving, and an honest disabled state while the codec is still opening the file.
 */
@Composable
private fun PlayToggle(state: PreviewPlaybackState, onToggle: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val enabled = state.canPlay || state.canPause
    val label = if (state.isPlaying) UiStrings.PREVIEW_PAUSE else UiStrings.PREVIEW_PLAY
    BasicText(
        text = label,
        style = type.listItem.copy(
            color = if (enabled) tokens.colors.primaryButtonInk else tokens.colors.textTertiary,
        ),
        modifier = Modifier
            .testTag(UiPageTags.PREVIEW_PLAY)
            .clip(RoundedCornerShape(tokens.radius.card))
            .background(if (enabled) tokens.colors.pageAccent else tokens.colors.surface)
            .clickable(role = Role.Button, enabled = enabled, onClick = onToggle)
            .defaultMinSize(minHeight = tokens.geometry.primaryButtonHeight)
            .padding(
                horizontal = tokens.spacing.cardInset,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics { contentDescription = label },
    )
}

/**
 * Creates the session for [file], opens it, and guarantees the release.
 *
 * This is the lifecycle contract of the whole lane in one place: the `onDispose`
 * below runs when the body leaves the composition (route popped, file swapped, the
 * failure card replacing the body) and [PreviewMediaSession.release] stops the sound.
 */
@Composable
private fun playbackSession(
    file: Path,
    kind: PreviewKind,
    onFailure: (String) -> Unit,
): PreviewMediaSession {
    val context = LocalContext.current
    val session = remember(file) { PreviewMediaSession(context) }
    DisposableEffect(session) {
        session.open(file.toFile(), kind)
        onDispose { session.release() }
    }
    // A preview is not a background player: ON_STOP pauses it.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, session) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) session.pauseForBackground()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    // The clock: sampled while the body is on screen, a no-op while paused.
    LaunchedEffect(session) {
        while (!session.isReleased) {
            session.refreshPosition()
            delay(POSITION_TICK_MS)
        }
    }
    // The decoder's answer becomes the page's failure state, never a silent stop.
    val failure = session.state.failure
    LaunchedEffect(failure) {
        if (failure != null) onFailure(failure)
    }
    return session
}

/**
 * Gives the `TextureView` the session's surface and takes it away again.
 *
 * The `Surface` wrapper is ours (the `SurfaceTexture` belongs to the view), so the
 * destruction callback releases it before the view releases the texture underneath.
 */
private fun TextureView.attach(session: PreviewMediaSession) {
    var wrapper: Surface? = null
    surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(
            texture: SurfaceTexture,
            width: Int,
            height: Int,
        ) {
            val surface = Surface(texture)
            wrapper = surface
            session.setSurface(surface)
        }

        override fun onSurfaceTextureSizeChanged(
            texture: SurfaceTexture,
            width: Int,
            height: Int,
        ) = Unit

        override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
            session.setSurface(null)
            wrapper?.release()
            wrapper = null
            return true
        }

        override fun onSurfaceTextureUpdated(texture: SurfaceTexture) = Unit
    }
}

/** How often the transport's clock samples the playhead while the body is on screen. */
private const val POSITION_TICK_MS: Long = 500L

/** The neutral box before the codec reports a size (16:9, the phone-video default). */
private const val DEFAULT_VIDEO_ASPECT: Float = 16f / 9f

/** The first frame a paused video asks for, so the body is not a black box. */
private const val FIRST_FRAME_MS: Long = 1L
