# 预览器 v1 实施状态

对应 [00-PLAN.md](00-PLAN.md) 的 P0。分支 `codex/preview-v1`。

## 已落地

- `PreviewTarget` / `PreviewRouter`（`PreviewPathResolver`）/ `PreviewSurface` 新建。
- Chat 文件链接**直接**打开预览：不再先开 Workbench；关闭一次回 Chat。
- Files 列表**直接 push** 预览：不再在 Files 里套第二个 `.sheet`；系统 back 一次回列表。
- 预览首帧 `正在读取…`；缺失文件有界重试（约 6 秒），不在首帧显示假错误。
- 文本/Markdown/代码：`UITextView` 分页读取，512 KiB 一页 + `加载更多`；UTF-8 跨页不切断。
- Markdown 本地图片改为共享 resolver，走 `materialized/workspace`。
- 类型路由：文本/HTML/图片/PDF/Office/视频/音频；未知类型 metadata + 分享；无扩展名文件做 UTF-8 sniff。
- HTML：JS 默认开；`pdsh-page://` 页面；toolbar reload；外部网络默认关闭，toolbar 网络菜单可按本次预览授权（只放宽图片/字体/媒体/connect，**script-src 永不加 https:**）。
- `PDSHPageResolver.networkAllowed` + `Content-Security-Policy` 测试：授权前后 CSP 对照，19 个 PageSchemeHandler 测试通过。
- 深色：`NativePagePalette.page` 跟随 App 外观，不再固定白底；Files 也改用 palette。
- 删除 `FilePreviewPage` / `EmbeddedQuickLook` 死路径和旧 Sheet 预览。
- 新增 DEBUG 路由与截图：
  - `files.preview.text`
  - `files.preview.markdown`
  - `files.preview.html`
  - `files.preview.long`
  - `files.preview.chat`
  - `files.preview.files`

## 还没做 / 下一步

- HTML 两档 CSP、meta 白名单、弹窗/下载策略、网络授权横幅（P1）。
- localhost 独立 Web 面（按评审 defer）。
- PDF/Image fixture 与截图已加；Office/AVKit 仍需 fixture。
- 深色 Markdown 截图已加；其他类型深色基线与 Dynamic Type 待补。
- 文本 `#L` 定位、行号、滚动恢复（P1）。
- Android 侧 router/read/WebView（后续）。
- 预览单元/UI 测试；当前只有 DEBUG 截图路由。
