# Android 對齊：經驗記錄

每個 worker 開工前讀一遍。審查意見和門禁失敗的原因，追加在最後。

1. **數值只認 spec。** iOS 源碼只用來參考和寫出處，不是權威。值必須逐字照抄源碼；要是推不出來，
   就標 `needsDeviceMeasure: true`，不要猜。例子：會話抽屜的偏移本來被寫成「限制在 [−width, 0]」，
   但 iOS 實際沒有下限，第一版契約因此改過一次。
2. **不放寬門禁。** 不要調高行數上限、擴大白名單、刪 fixture，也不要跳過檢查。放不下的內容拆成新檔案，
   例如 `spec/ui/v1/interaction.md`。檢查器本身有誤判時，修的是判斷的精度（例如 schema_diff 改成逐個比較
   `oneOf` 分支），而不是放過這個情況。
3. **main 上已有的紅燈。** 截至 2026-11-12：`page-structure` 有 7 個差異；`android-structure` 的 readme-map
   沒有登記 Bot/PCLink/Venus。跑門禁時要確認紅燈只來自這些，並如實回報，不要順手改。
4. **用共享 golden 測真實程式碼。** Android 測試從磁碟讀 `spec/**/golden`，不要把案例手抄進 Kotlin。
5. **動畫要播完才卸載。** 宿主用條件掛載（`if (open)`）會讓收起動畫被跳過。元件必須等動畫結束、
   回報 `onClose` 之後才離場。
6. **工具鏈：**
   - Android 測試用 `bash android/tools/with-android-toolchain.sh ./gradlew ...`。
   - app 的測試要先編 Rust：`bash android/tools/with-rust-toolchain.sh cargo build --locked --manifest-path shell/Cargo.toml -p pdsh-jni`。
   - spec 的 Python 測試用 `unittest`，這台機器沒有 pytest。
7. **權限範圍外的必要改動。** 範圍外但必要的一行登記（例如在 cross_check 裡註冊新的 golden）可以做，
   但要在報告裡單獨列出並說明理由。
