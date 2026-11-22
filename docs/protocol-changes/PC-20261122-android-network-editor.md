# Android 网络访问与模型编辑

基线 `dd384e197`。Protocol impact: P05; P09; P18.
本次冻结新增 Android 本机网络设置的持久化与出网投影，规则与兼容性由
[网关规范](../../spec/v1/gateway-security.md)和[共享用例](../../spec/ui/v1/fixtures/mobile-egress-settings.json)定义。
iOS 已提供默认地址、添加、删除、开关及模型编辑弹层；Android 普通启动原本只有未知规则和栈内编辑。
改后以持久设置驱动 UI 与宿主普通读取，模型列表保持挂载，新增和编辑使用同一个模态表单。
保存以已有请求回执为准，高级设置返回表单，取消放弃草稿。

协调、实现和集成由本任务承担。iOS 作为模拟器实测基准；Android 涉及 app 设置所有者、
既有网关策略和 lib 页面。旧客户端及旧数据不依赖新增文件。新客户端读旧安装使用默认名单，
新版本间读写同一版本，回滚时旧应用忽略文件。模型表单沿用原有存储、错误与重试语义。
单测覆盖实际策略放行、拒绝、重定向、存储失败及恢复；两端模拟器验收添加、删除、
开关恢复、冷启动和编辑弹层。检验命令包括 Gradle 的 `:app:assembleDebug`、
`:app:testDebugUnitTest`、`:lib:testDebugUnitTest` 和仓库的协议三项检查。
