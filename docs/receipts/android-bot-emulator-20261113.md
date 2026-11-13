# Android Bot emulator receipt（2026-11-13）

環境：macOS 26.2、Android SDK、emulator `37.2.13`、system image
`system-images;android-37.2;google_apis_ps16k;arm64-v8a`、AVD `pdsh`（headless、
`-gpu swiftshader_indirect`）、`adb` 裝置 `emulator-5554`。這是 **emulator** 證據，
不是真機。

## `:app:assembleDebug`

`:app:assembleDebug` PASS，產出 debug APK（含未 strip 的 arm64 `libpdsh_jni.so`，
所以檔案比 iOS bundle 大）。`:app:testDebugUnitTest` 887 tests / 0 failed。

## Instrumented `BotStoreAndroidVectorTest`

第一次在 emulator 上真的執行就抓到兩個 Android-only driver bug（JVM tests 看不到），
修於 `cf75caeb`：

1. `execSQL("PRAGMA secure_delete=ON")` 被 Android 拒絕（「Queries can be performed
   using SQLiteDatabase query or rawQuery methods only」）→ PRAGMA 改走 `rawQuery`
   fallback。
2. store 的 `abort-*` crash point 在 transaction 內 `close()`；Android 不會結束
   transaction session，WAL 寫鎖殘留，下一次 open `SQLITE_BUSY` → `close()` 先 rollback。

命令與結果：

```bash
adb push spec /data/local/tmp/pdsh
adb shell am instrument -w -r \
  -e pdsh.repo.root /data/local/tmp/pdsh \
  -e class com.phonedsh.probe.bot.store.BotStoreAndroidVectorTest \
  com.phonedsh.app.test/androidx.test.runner.AndroidJUnitRunner
# => OK (3 tests)
```

## Bot tab

K6 把 Bot runtime/driver/tab 接進 App 後，在 emulator 上發現兩個 UI 生命週期問題，
修於 `e5f81fdc`：

- `botPlatformConfig` 原本是普通 lazy（第一次 composition 讀到 `null` 後不再更新），
  改成 `StateFlow`，由 runtime 建立時 publish。
- `HostShell` 自己的 `HomeTabBar` 呼叫沒有傳 `showBot`；補上
  `showBot = botPlatform != null`。
- Bot listener 原本在主執行緒 bind（`NetworkOnMainThreadException`），改成
  `Dispatchers.IO`；修好後 logcat 顯示 listener origin（token redacted）。

修好後：底部 bar 出現 `Bot`，點進去顯示「嗨，我是 Bot / 我可以处理任务、整理文件和
查找资料。想让我帮你做什么？/ 向 Bot 提问」。

未驗：真機（GAP-38 關閉條件）、模型服務未配置所以沒有真實 Bot 回合、鍵盤/返回/drawer
的完整互動、Worker `phone-bot` preset / claim 與 `/v1/http` egress token 替換（Host API gap）。
