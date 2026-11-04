# L32 — 预览面补上 video / audio 两类渲染器

> 范围：`android/lib/src/main/kotlin/com/phonedsh/ui/surface/preview/**`（L29 的实现，本车道追加
> `PreviewPlayback.kt` / `PreviewPlaybackState.kt`，改 `PreviewKind.kt` / `PreviewState.kt` /
> `PreviewSurface.kt`）、`UiStrings.kt` / `UiPageTags.kt`（仅追加）、
> `android/lib/src/test/**/preview/*`（改 2 新增 1）、`android/lib/src/androidTest/**`（新增
> `PreviewMediaDeviceTest.kt` + 两个媒体 fixture）。
> **未改**：`spec/**`、`Sources/**`、`examples/**`、`plugins/**`、`shell/**`、`android/core/**`、
> `android/dsh/**`、`android/engine/**`、页面文件、`android/lib/build.gradle.kts`（**没有加依赖**）。
> **没有任何 git 写操作。**
> 设备：自建 AVD `l32_media`（android-35、1080×2400@420、端口 **5660**、`-no-window`），用完已删。
> 未触碰 5556 / 5558 / 5658 / 5662 / 5664 上其他车道的设备。

---

## 1. 一句话

L29 把 video / audio 留在「诚实卡片 + 分享」（L29 §6、§10 Q4）。这一条车道把这两类接上
**`android.media.MediaPlayer`**（`:lib` 没有 media3/exoplayer，也没有加），视频画在
`TextureView` 上，音频画成卡片；**离开页面 release、失去音频焦点暂停、坏文件走 `无法预览` +
原因 + `重试`**。契约 checker 仍 `0 new`。

## 2. 用了什么播放器，为什么

* `android.media.MediaPlayer`：平台解码器，`minSdk 26` 上 PR15 列的 8 个扩展名全有解码器
  （mp4/mov/m4v 是 ISO-BMFF 容器，mp3/m4a/wav/aac/flac 都是平台解码器）。
* **没有加 ExoPlayer/media3**：`:lib` 的依赖里从来没有它（`grep media3` 为空），一个屏的预览不值得
  多一个 ~1MB 依赖 + 第二套生命周期；`build.gradle.kts` 一个字未动。
* 视频面用 **`TextureView`** 而不是 `SurfaceView`：`SurfaceView` 的像素在 SurfaceFlinger 图层里，
  `captureToImage`（本仓库的截图门）会拍到一个黑矩形；`TextureView` 画进窗口，
  下面的设备截图就是真实解码帧。
* 一个 `PreviewMediaSession` 同时服务两类（PR15 也是 `case .video, .audio: player = AVPlayer(url:)`
  一个 player），audio 用 `AudioAttributes.CONTENT_TYPE_MUSIC`，video 用 `CONTENT_TYPE_MOVIE`。

## 3. 生命周期：离开页面真的会停

```kotlin
// PreviewPlayback.kt（playbackSession，video/audio 两个 body 共用）
val session = remember(file) { PreviewMediaSession(context) }
DisposableEffect(session) {
    session.open(file.toFile(), kind)
    onDispose { session.release() }          // ← 离屏即 release
}
// 后台也不算「在预览」：ON_STOP 暂停，ON_START 不自动续播
val lifecycleOwner = LocalLifecycleOwner.current
DisposableEffect(lifecycleOwner, session) {
    val observer = LifecycleEventObserver { _, event ->
        if (event == Lifecycle.Event.ON_STOP) session.pauseForBackground()
    }
    lifecycleOwner.lifecycle.addObserver(observer)
    onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
}
```

`release()`：`abandonAudioFocusRequest` → `setSurface(null)` → `reset()` → `release()`，
幂等且不向 composition 抛异常。路由 pop、换文件、失败卡替换 body 都会走它
（`PreviewSurface.kt` 里失败时把 body 换成 `FailureBody`，body 离屏 → dispose）。

设备证据（`logcat.txt`，离开页面那一次）：

```
19:47:17.611 audio focus requested granted=true
19:47:17.614 start positionMs=0
19:47:18.927 audio focus abandoned
19:47:18.968 release            ← 路由 pop 后音频停
```

后台（HOME，composition 还在）：

```
19:47:16.394 audio focus abandoned
19:47:16.399 pause byFocus=false positionMs=4
19:47:16.399 pause for background
```

## 4. 音频焦点

* 播放时 `AudioManager.requestAudioFocus(AudioFocusRequest)`：`AUDIOFOCUS_GAIN`、
  `USAGE_MEDIA`、`setWillPauseWhenDucked(false)`，listener 绑主 looper（回调要改 Compose state）。
* 暂停（用户点的）与 release 都 `abandonAudioFocusRequest`。
* 回调按 `PreviewFocusAction` 分三类：
  `LOSS` / `LOSS_TRANSIENT` → 暂停（永久丢失才放弃 request；瞬时丢失留着等 `GAIN` 回来续播）；
  `LOSS_TRANSIENT_CAN_DUCK` → 音量降到 `DUCK_VOLUME`（0.2），**不**暂停；
  `GAIN` / `GAIN_TRANSIENT` → 恢复 `FULL_VOLUME`，若之前是焦点丢失暂停的才续播。
* 焦点丢失不是用户暂停：卡片多一行 `另一个 App 正在使用音频，播放已暂停。`，transport 回到 `播放`。
* 设备实测（测试里用第二个 focus client 抢焦点）：

```
19:47:20.230 start positionMs=0
19:47:20.267 pause byFocus=true positionMs=0
19:47:20.268 focus change=-1 pause resumeOnGain=false   ← AUDIOFOCUS_LOSS
```

## 5. 错误态：走现有的诚实失败卡

`MediaPlayer.setOnErrorListener` → `playbackFailureReason(what, extra)` → body 的
`LaunchedEffect(failure)` 调 `onFailure` → 页面 `state.failed(reason)` →
现成的 `无法预览` + 原因 + `重试`（`PreviewSurface.kt` 的 `FailureBody`，一行未改）。

原因按平台 `MEDIA_ERROR_*` 分类：`MALFORMED` 文件损坏 / `UNSUPPORTED` 没有解码器 /
`IO` 读不到 / `TIMED_OUT` 超时 / `SERVER_DIED` 播放器出错 / 其它 `播放器无法打开这个文件。`
`setDataSource` 抛的 `IOException` / `IllegalArgumentException` 也落到同一张卡。

设备实测（4 KiB 的 `0x7f` 冒充 `.wav`）：`无法预览 / 播放器无法打开这个文件。/ 重试`
（`screens/preview-media-failed.png`）。把同一路径写成真 WAV 再点 `重试` → 卡片消失、
`时长 0:02` 出现（`screens/preview-media-recovered.png`，logcat `prepared durationMs=2000`）。

## 6. 两类 body

| kind | 实现 |
|---|---|
| video | `TextureView` + `MediaPlayer`，宽高比用解码器报的 `videoWidth/videoHeight`（未准备时 16:9），准备后 `seekTo(1)` 要第一帧（不显示黑框）；下方 `播放/暂停` + `0:07 / 0:32` |
| audio | 卡片：文件名 / `时长 0:06`（解码器报的；没有就说 `时长未知`）/ `播放·暂停` / 时钟 / 焦点提示 |

两类的 transport 是同一个 `MediaTransport`，所以文案和状态不会各说一套。

## 7. 设备证据（AVD 5660，android-35）

```
$ adb -s emulator-5660 shell am instrument -w \
    -e class com.phonedsh.ui.screenshot.PreviewMediaDeviceTest,com.phonedsh.ui.screenshot.PreviewSurfaceDeviceTest \
    com.phonedsh.lib.test/androidx.test.runner.AndroidJUnitRunner
OK (19 tests)        # 5 条新媒体 + L29 的 14 条预览（回归）
```

`PreviewMediaDeviceTest`（5 条，`screens/facts.txt` 是它们自己的记录）：

| 测试 | 断言了什么 |
|---|---|
| `anAudioFilePlaysAndLeavingThePageStopsIt` | `.m4a` 播起来：`暂停` + 时钟 `0:00 → 0:01` + `isMusicActive=true`；pop 之后 `isMusicActive=false`；再进来是 `播放`、`0:00` |
| `anotherAppsFocusRequestPausesTheAudioAndSaysWhy` | 另一个 focus client 抢走 → `暂停` 变 `播放` + 焦点提示那行 |
| `backgroundingTheAppStopsTheSoundAndDoesNotResumeOnReturn` | `moveToState(CREATED)` → `isMusicActive=false`；回前台仍是 `播放`，不自动响 |
| `aVideoFileDecodesPlaysAndShowsAFrame` | `.mp4` transport `0:00 / 0:04`，点击后 `暂停` + 时钟前进 + `isMusicActive=true`，暂停后 `false` |
| `aCorruptMediaFileEndsInCannotPreviewWithRetry` | 坏 `.wav` → `无法预览`+原因+`重试`；写好真文件点 `重试` → `时长 0:02` |

截图（1080×2400，`captureToImage` 真抓屏）：

| 文件 | 证明 |
|---|---|
| `preview-audio-ready.png` | 音频卡：`tone.m4a` / `时长 0:06` / `播放` / `0:00 / 0:06` |
| `preview-audio-playing.png` | `暂停` + `0:01 / 0:06`（真的在走） |
| `preview-audio-focus-lost.png` | `播放` + `另一个 App 正在使用音频，播放已暂停。` |
| `preview-audio-returned.png` | 离开再回来：`播放`、`0:00 / 0:06`（新会话，没在放） |
| `preview-video-ready.png` | 视频页暂停态也显示首帧（surface 挂上后 seek 到 1 ms 求一帧）+ transport `0:00 / 0:04` |
| `preview-video-playing.png` | **真实解码帧**（ffmpeg testsrc 彩条）+ `暂停` + `0:01 / 0:04` |
| `preview-video-paused.png` | 暂停后 `播放` 回来 |
| `preview-media-failed.png` | `无法预览` + `播放器无法打开这个文件。` + `重试` |
| `preview-media-recovered.png` | 重试后音频卡出现（`时长 0:02`） |

`logcat.txt` 是同一轮 `logcat -d -s PdshPreview` 原文（prepare / prepared / start / pause /
focus / release 全在里面）。

## 8. 验证

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
cd android
./gradlew :lib:testDebugUnitTest          # BUILD SUCCESSFUL，744 tests / 0 failures
./gradlew :app:assembleDebug              # BUILD SUCCESSFUL（宿主没被牵连）
./gradlew :lib:assembleDebugAndroidTest   # BUILD SUCCESSFUL
python3 spec/ui/v1/tools/page_structure_check.py --root . --baseline spec/ui/v1/pages/_baseline.json
# page-structure: ok (17 known divergence(s), 0 new, 0 stale; 3 whitelisted)
```

新增/改动的 JVM 测试（`lib/src/test/kotlin/com/phonedsh/ui/surface/preview/`）：

* `PreviewKindTest`（8 条）：`six kinds have a renderer`、`video and audio are exactly PR15's
  extension sets`（含 `webm`/`ogv` 仍是 `WEB_MEDIA`）；原有 mp4/mov/m4v/mp3/m4a/wav/aac/flac 表继续钉着。
* `PreviewStateTest`（12 条）：`a media file is ready without a text page`；unsupported 原因表
  去掉 video/audio（现在有渲染器了，不该再解释「还没接上」）。
* `PreviewPlaybackTest`（13 条，新）：播放状态机（prepared/started/positioned/paused/ended/failed）、
  `播放/暂停` 在哪些 phase 出现、焦点 5 个常量 → 3 个动作、`m:ss / h:mm:ss` 时钟、`MEDIA_ERROR_*`
  分类。
* `PreviewTokenReferenceTest`（5 条）未改、仍绿：新文件没有裸 `N.dp`/`N.sp`/`Color(0x…)`，
  token 引用都在 `tokens.json` 里，第 2 行 SPDX。

## 9. Open questions

1. **视频的 transport 是自绘的**（`播放/暂停` + 时钟），PR15 的 `VideoPlayer` 带系统控件
   （进度条 / 全屏 / 音量）。要不要补进度条拖动？现在 `MediaPlayer.seekTo` 已经有，缺的是 UI。
2. **没有播完自动重播/循环**：播到结尾停住、回到 `播放`（点一下从头再来）。符合预览语义，但和
   iOS 的 `AVPlayer` 行为（停在结尾）需要确认。
3. **横屏/全屏**：现在是页面内的 16:9（或解码器宽高比）盒子；全屏要动页面/宿主的方向策略，不在本车道。
4. **`PREVIEW_REASON_VIDEO` / `PREVIEW_REASON_AUDIO` 两个字符串现在没有引用了**：
   `UiStrings.kt` 对本车道是「仅追加」，所以没有删；要不要在后续清理里一并删掉（会碰 L29 的注释块）。
5. **音频焦点被 `AUDIOFOCUS_LOSS_TRANSIENT` 拿走时的续播**是自动的（`resumeOnGain`）。如果产品
   希望「回来也要用户再点一次」，改一行即可。
6. **设备测试的媒体 fixture 是 ffmpeg 生成的真文件**（`lib/src/androidTest/assets/preview/`，
   65 KB + 48 KB）：H.264 baseline 320×240 + AAC。若仓库不接受二进制测试资产，可换成
   `MediaCodec`/`MediaMuxer` 在设备上现生成（代码量约 +80 行，且更依赖模拟器编码器）。
