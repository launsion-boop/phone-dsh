# 手机端办公文件重转换：后端选型调研（2026-10-29）

标注：【实】= 官方文档/仓库原文可查；【推】= 推断或经验值。

## 结论先行

1. **交付级 Office→PDF 只有两条路**：云端 LibreOffice（许可最干净），或整包内嵌 LibreOffice（+179 MB 二进制）。纯 JS/WASM 与系统框架都做不到版式保真。
2. **端上真正能包打的是 PDF 域**：合并/拆分/水印/加密/转图/抽文本，PDFKit 全覆盖，零许可风险、亚秒级。
3. **预览级**可用 QuickLook 截图顶替 PDF，但那是截图不是转换，分辨率与分页不可控。
4. **许可红线**：LibreOffice、Collabora Online 是 MPL-2.0（闭源可链、SaaS 安全、可上架）；OnlyOffice 是 AGPL-3.0（SaaS 要供源码，打进 App 有上架风险）；Local Code 应用本身是 GPL-3.0，代码不能抄。
5. **推荐**：端上 PDF+文本+自绘 PDF，云端 LibreOffice 保高保真，QuickLook 做降级，按"文件类型×保真度"三档路由。

## 1. 端上 LibreOffice（Local Code）核实

**怎么做到【实】**：不是起 headless 进程，而是把 LibreOffice 26.8 编成静态库 + LibreOfficeKit，只保留 SVP（无 GUI）后端，全库只导出 1 个 C 符号 `OfficeCommandRun`，静态链进 App 可执行文件，再由 ios_system 注册成 `office` 命令（convert / recalculate / render；渲染走 LOK tile，PDF 走 PDFium）。MPL 补丁随仓库发布（[Vendors/LibreOffice](https://github.com/drawthingsai/local-code-community/tree/main/Vendors/LibreOffice)）。

**代价【实，仓库 receipt】**：iOS 静态库 267.7 MB → 链接后二进制 +179.4 MB；运行时资源解包 64.9 MB、打包后 17.5 MB；最低 iOS 15.4（[ios-arm64.json](https://github.com/drawthingsai/local-code-community/blob/main/Vendors/LibreOffice/Receipts/ios-arm64.json)）。

**但【实】**：官方自述"没拿到真机，iOS 运行时与内存未验证"，receipt 里 `deviceRuntime: false`；[官网](https://getlocalcode.app) iPad/iPhone 版仍写"Coming soon on the App Store"。所以"iPhone 上跑通了"目前只有链接级证据。

**许可**：应用是 GPL-3.0（[README](https://github.com/drawthingsai/local-code-community#license)），LibreOffice 是 [MPL-2.0](https://www.libreoffice.org/licenses/)，别混。商用可行（MPL 是文件级 copyleft，闭源可链），但须发布你对 MPL 文件的修改、保留 notices、不用 LibreOffice 商标。

**内存【推】**：转换峰值 200–500 MB，叠加 WKWebView 与模型后有 jetsam 风险；且仓库明说引擎调用无硬超时，卡死只能杀进程。

## 2. 端上系统能力

- **PDFKit**：PDF→图、PDF→文本、合并/拆分/水印/加密，端上最优解【实 API / 保真由源文件决定】。
- **QuickLook**：能渲染 docx/xlsx/pptx 预览与缩略图，但公开 API 没有"导出 PDF"，只能截图 → 光栅、按视口【实】。
- **WKWebView `createPDF` / `UIGraphicsPDFRenderer` / SwiftUI `ImageRenderer`**：只对 HTML 或你自己画的视图生效；WKWebView 本身不排 Office 版式【实】。
- **NSAttributedString `officeOpenXML`**：能读 docx 文本+粗样式，分页/表格/图全丢【实 API，保真归推断】。

覆盖：PDF 域 100%；Office→PDF 只有"截图级"；Office→图 = QuickLook 缩略图。

## 3. 纯 JS/WASM

mammoth（docx→语义 HTML）、docx-preview（CSS 近似分页）、pptxjs（老，形状/字体/图表弱）、SheetJS（数据与公式值，样式/打印区域/分页全丢）、pdf-lib（造 PDF，不渲染、不抽文本）。共同短板：分页、字体度量、图表、SmartArt、打印区域。定位只能是"给模型读"与"模型自己排版"，不是转换。真 WASM LibreOffice 存在（[kit](https://github.com/deepseek-ai/dsh-libreoffice-kit) 的 Node WASM：下载 35.9 MB / 解包 190.6 MB），但 iOS Worker 的 260 MB 内存上限很难装下【推】。

## 4. 云端

- **LibreOffice headless**：MPL，SaaS 无 copyleft 传染；保真≈端上同引擎；热 0.5–3 s、冷启 2–5 s；单次成本厘级【推】。首选。
- **Collabora Online**：官方 [MPLv2 条款页](https://www.collaboraonline.com/terms/collabora-online-mplv2/)，不是 AGPL；可自建、可购支持；偏协作编辑栈，重。
- **OnlyOffice Docs**：[AGPL-3.0](https://github.com/ONLYOFFICE/DocumentServer)。SaaS 需按 [§13](https://www.gnu.org/licenses/agpl-3.0.en.html) 向网络用户提供对应源码；打进闭源 App 等于整体 AGPL 化，且 App Store 有 GPL 类冲突先例（VLC iOS 为留在商店改用 [MPL 2.0](https://en.wikipedia.org/wiki/VLC_media_player)）。闭源就买商业授权，或只作独立服务调用。
- **Aspose**：保真最好最贵（Words 单平台 [US$1,199 起](https://purchase.aspose.com/pricing/)）；**CloudConvert**：[按额度计费](https://cloudconvert.com/pricing)、10 次/天免费、2–10 s；**Google Drive**：不能直接 docx→PDF，要先 copy 成 Google Doc 再 [export](https://developers.google.com/workspace/drive/api/guides/manage-downloads)，两跳且版式会漂。
- **补充**：Microsoft Graph `?format=pdf` 保真高，但[文档写明 2 MB 上限](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content-format)，做不了大 deck。

## 5. 六维对照

| 方案 | 保真 | 延迟 | 成本 | 许可 | 离线 | 体积/上架 |
| --- | --- | --- | --- | --- | --- | --- |
| 端上 LibreOffice | 高（≈桌面 LO） | 1–4 s | 0 | MPL，可闭源 | 是 | +179 MB，合规但要真机验证 |
| QuickLook+PDFKit | PDF 满分，Office 截图级 | <1 s | 0 | 系统，无风险 | 是 | 0 |
| JS/WASM 库 | 文本级，无版式 | <1 s | 0 | MIT/BSD 类 | 是 | 数 MB |
| 云 LibreOffice | 高，字体缺失即跑版 | 0.5–5 s | 厘级【推】 | MPL，SaaS 安全 | 否 | 无 |
| OnlyOffice | 高 | 1–3 s | 自建重、授权贵 | AGPL，需供源码 | 否 | 无（服务端） |
| Aspose/CloudConvert | 最高 | 1–10 s | 按量，贵 | 商业 | 否 | 无 |

除体积与许可外，表内数值为经验值【推】。

## 6. 混合与路由

端上先出预览（QuickLook 截图/缩略图），用户点"交付/分享/打印"再上云；云端失败回落到截图 PDF 并显式标注"预览版"。字体是保真主因：微软字体不能内置（许可），用 Carlito/Caladea 度量兼容替代 + iOS 中文字体，并回传 `missingFonts`。另注意 App Store [2.5.2](https://developer.apple.com/app-store/review/guidelines/) 禁止运行期下载可执行代码，引擎只能整包内置。要自建 iOS 引擎，优先复用 [dsh-libreoffice-kit](https://github.com/deepseek-ai/dsh-libreoffice-kit)（MPL-2.0、公开配方），而不是抄 GPL-3.0 的 Local Code。

| 输入 → 输出 | 预览级（端上） | 交付级 | 印刷/对外级 |
| --- | --- | --- | --- |
| docx→PDF | QuickLook 截图 | 云 LO（端上 LO 亦可） | 云 LO + 字体包 / Aspose |
| docx→txt/md | mammoth / NSAttributedString | 同左 | — |
| xlsx→PDF | SheetJS→HTML→createPDF（丢样式） | 云 LO（尊重打印区域/分页） | 云 LO + 打印设置 |
| xlsx→数据/CSV | SheetJS | 同左 | — |
| pptx→PDF/图 | QuickLook 截图 | 云 LO（字体替换仍可能跑版） | Aspose / Graph（≤2 MB） |
| PDF→图/文本 | PDFKit（扫描件走 Vision OCR） | 同左 | 同左 |
| PDF 合并/拆分/水印/加密 | PDFKit / pdf-lib | 同左 | 同左 |
| 模型生成报告 PDF | UIGraphicsPDFRenderer / ImageRenderer | 同左 | 同左 |

**必须上云**：复杂 pptx（图表/SmartArt）、xlsx 打印区域与分页、带域/目录/交叉引用的 docx、要求印刷级的长文档。
**可端上**：PDF 全套操作、docx/xlsx 文本与数据抽取、简单表格→PDF（自己排版）、模型自绘 PDF、图片批处理。
**可降级**：QuickLook 截图当预览、HTML 预览代替 PDF、纯文本/Markdown 交付。
