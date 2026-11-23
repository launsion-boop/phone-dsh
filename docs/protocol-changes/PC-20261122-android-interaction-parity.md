# Android 导航、输入与附件交互

基线 `881d0bdf7`。P09 以 iOS 产品入口为参照，观察七条路径：归档/关于返回、Bot/DSH 输入、Bot 附件、Bot 抽屉和 PC 配对下拉。Android 的页面展示与用户输入接线由本次变更承担，iOS 为既有实现和模拟器验收端。

根页内部子层优先消费一次返回，关闭后根页重新显示可用底栏。抽屉遮住底栏。软键盘只占用一次布局空间，页头和输入框可用；输入法返回不丢草稿。配对弹层可以下拉或点击关闭。Bot 使用系统照片、文档选择器，仅在发送时将选中文件交给当前 Bot 工作区的既有导入服务。取消不添加，超限或无法读取不生成成功附件；沿用既有文件数与字节限制。

复用 `push-back.golden.json`、`sheet-detents.golden.json` 和 Bot 附件向量。未增加消息字段、环境变量、持久键或版本。旧端、新端相互读写和回滚沿用原合同。针对两端从冷启动执行原走查路径，包含返回桌面反例、键盘输入非空草稿、点抽屉底部、附件选择/取消及下拉关闭，用实际录屏对照。Android 构建、导航/草稿/附件定向测试与协议检查作为补充。

## 验收

契约冻结于 `4ba88738d`。用同一版本的 Worker 源码和全量 VFS 镜像重新打包两端。Android 的 Bot 导入复用现有会话和目录导入 RPC，检查分块回执、提交目录、数量和字节数，失败时中止暂存事务。系统选择器授予的 URI 只在本地草稿中使用。

- 模拟器验证归档、关于的系统返回和边缘返回、Bot 和 DSH 输入键盘后的页头与发送键、抽屉遮挡底栏、照片及文件选择、PC 配对页向下关闭。两端均用正常入口，未发送模型消息。
- Android JVM 定向回归 190 项通过。Android 15 仪器测试 `MobileInteractionDeviceTest` 与 `BotComposerImportDeviceTest` 均通过；后者在真实运行的 Bot 会话提交附件并核对持久物化后的文件字节。
- `bash scripts/ci/check.sh --only phone-spec` 通过。`bash scripts/ci/check.sh --only phone-p0-conformance,phone-cross-tree` 的 cross-tree 通过；P0 保留基线的 Bot 菜单来源行号、outbox 动作以及小智固件入口和页面缺口。
- 实证范围为手机模拟器。未验证真机、外设配对、真实模型回复或断电恢复。
