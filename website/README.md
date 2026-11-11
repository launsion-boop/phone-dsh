# Phone DSH 官网设计原型

本版围绕“口袋 AI 工作区”展开，使用纯白、墨黑和珊瑚红。首页包含可交互手机示意、工作场景切换、示例文件预览、模型与 Bot 能力、开源入口及 App Store 下载。

目标首页为 `https://phonedsh.tonoai.cn/`，隐私页为 `https://phonedsh.tonoai.cn/privacy`。生产部署使用 ACK 的 tonoai 命名空间，静态页面由 Nginx 提供。

## 本地预览

在仓库根目录运行以下命令。

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

打开 `http://127.0.0.1:4173/`。静态文件可以部署到支持目录索引的 Web 服务，无需构建依赖。

## 功能盘点与宣传重点

以下根据当前工作区代码与仓库说明盘点。App Store 各版本的完整功能范围需要按发布包核对。

| 能力 | 网站表达 | 依据与范围 |
| --- | --- | --- |
| 手机端 Agent 工作区 | Agent 在 iPhone 上运行，模型服务由用户配置 | `README.md` 的项目定位和架构。手机运行 Harness，推理请求交给配置的模型服务 |
| 自选模型 | 连接自己的模型服务与 API Key | `examples/probe-app/PhoneDSHProbe/ModelProviderSettingsPage.swift`。支持服务地址、模型目录和连接测试 |
| Bot、记忆与例行任务 | 为助手分工，管理记忆和例行任务 | `README.md` 的 Bot 功能，`examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift`。执行受 iOS 生命周期和静默时段影响 |
| 工具审批 | 在对话中审核操作，回看审批记录 | `examples/probe-app/PhoneDSHProbe/Bot/`。具体能力和审批规则依实际工具而定 |
| 文件与工作成果 | 浏览工作区、预览文件、继续处理结果 | `examples/probe-app/PhoneDSHProbe/FilesPage.swift`、`ChatPage.swift`。网站中的文档和数据为演示内容 |
| MCP、搜索、Skills | 接入工具服务，查看可用 Skills | `MCPSettingsPage.swift`、`WebSearchSettingsPage.swift`、`NativeConfigurationPage.swift`。iPhone 的插件和 Skills 清单主要用于查看，插件安装与启停有平台限制 |
| SSH、ADB、BLE 和局域网工具 | 连接已配置的远程主机和设备 | `docs/native-ssh.md`、`docs/android-adb.md`、`docs/ble-devices.md`。具体传输、配对和工具支持见各自文档 |
| Gmail 只读连接器 | 收录在盘点中，首页暂以通用连接能力为主 | `GmailConnectorPage.swift`、`GmailSignIn.swift`。本会话已实现并在真机验证登录、搜索、正文和断开。当前仍处 Google OAuth 测试与送审准备阶段，发信和 Agent 访问不在本阶段范围内 |
| 开源 | 顶部 GitHub 关注入口和开源介绍 | https://github.com/launsion-boop/phone-dsh 。第一方代码采用 MIT，吉祥物许可见仓库 `NOTICE` |

## 交互与隐私页

- 中英文切换同时更新首页演示和隐私页，可跨页面保留选择。
- 主题提供跟随系统、浅色、深色。首次使用跟随系统，系统变化时自动更新。
- 手机示意使用与 iOS 一致的 Bot、DSH、发现、我的四栏导航，复用 iOS 的大肥鱼头像与 DeepSeek 标识。首页和隐私页的 logo、favicon 使用同一个 iOS App Icon。
- 案例区包含 Bot 保存、查看和删除记忆，Bot 允许或拒绝工具请求，DSH CSV 分析和 DSH 笔记整理。支持运行过程、工具展开、工作区文件预览与重置案例。
- GitHub 入口使用带官方 GitHub 标识的按钮。发现页展示连接器说明，我的页可以切换演示模型。
- `/privacy/` 收录原 `https://tonoai.cn/phone-dsh/privacy/` 的完整中英文正文，并保留政策版本和生效日期。
- 首页与隐私页的“联系我们”打开 QQ 群二维码弹窗，群号为 `714985308`，入群备注为 `PhoneDSH官网`。二维码复用仓库 `docs/assets/qq-group-714985308.png`。
- App Store 链接沿用仓库官方入口 `https://apps.apple.com/app/phone-dsh/id6828310755`。
- 首屏与下载区展示 iOS、Android 和 HarmonyOS，并使用 Apple、App Store、Android、HarmonyOS、GitHub 图标。iOS 跳转 App Store，Android 与 HarmonyOS 暂时跳转各自 GitHub 目录。
- Android 与 HarmonyOS 根据当前仓库状态标记为开发预览。macOS 14+ 以 Swift SDK 开发者支持展示，入口跳转 GitHub。依据为 `README.md`、`android/README.md`、`harmony/README.md` 和 `Package.swift`。
- 网站演示在浏览器本地运行。偏好保存在 `localStorage`，输入不会发送给模型服务。

## ACK 部署

部署清单位于 `deploy/ack.yaml`，包含两个副本、ClusterIP Service 和 ALB Ingress。复用命名空间中的 `acr-pull` 与 `tonoai-wildcard-tls`。

从仓库根执行以下命令。将镜像地址替换为你有推送权限的 registry，并使用当前提交作为 tag。

```sh
website_image="<registry>/phone-dsh-website:$(git rev-parse --short=12 HEAD)"
docker buildx build --platform linux/amd64 -t "$website_image" --push website
```

取得 registry 返回的 digest 后，更新 `deploy/ack.yaml` 中的镜像，执行服务端校验与滚动发布。

```sh
kubectl --context tonolive-prod -n tonoai apply --dry-run=server -f website/deploy/ack.yaml
kubectl --context tonolive-prod -n tonoai apply -f website/deploy/ack.yaml
kubectl --context tonolive-prod -n tonoai rollout status deployment/phone-dsh-website
curl --fail https://phonedsh.tonoai.cn/healthz
curl --fail https://phonedsh.tonoai.cn/privacy
```

发布后检查 Deployment、EndpointSlice、HTTPS 首页、隐私页、静态资源及浏览器交互。更新时可以通过上一镜像 digest 回滚。

## 验证与变更范围

所有网站源文件和部署清单位于 `website/`。

Protocol impact: none — 独立宣传网站与静态演示，未修改 App、Worker、原生模块或共享协议。

Contract revision 不适用。

已检查 JavaScript 语法、首页与隐私页的 HTTP 响应、中英文政策原文一致性，并通过浏览器操作验证语言、系统主题变化、主题持久化、四栏导航、记忆保存与删除、审批允许与拒绝、DSH 案例运行、工具过程展开、文件预览和指令演示。检查包含桌面及手机视口。

浏览器操作验证属于官网原型验收。模型调用、外部连接和 App Store 当前发布包的全部能力不由网站演示验证。Google OAuth 首页使用 `https://phonedsh.tonoai.cn/`，隐私政策使用 `https://phonedsh.tonoai.cn/privacy`。
