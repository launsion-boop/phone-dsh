# 04 — Preview UX + Android precedent (read-only research)

Status: research / proposal. No app code, spec or git state was modified.
Scope: iOS native preview surfaces, the Android tree's preview capability, the official
DSH preview precedent, and one proposed cross-platform preview contract + roadmap.
Repo under study: `phone-dsh` (iOS `examples/probe-app/PhoneDSHProbe/`, Android `android/`).
Official DSH read at
`/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness/packages/client/`
(checkout `7be5505b0b`, 2026-10-20).

Evidence notation: `path:line` always means the file as it is in this working tree.
"absent" means a repo-wide search found zero call sites; the search term is given.

Related receipts in this folder: `02-official-dsh.md` is the deep dive on how the official
preview renders (renderer registry, HTML model, localhost, feature matrix). This file does not
repeat that; §3 below only extracts the surface model and the copy/do-not-copy calls, and the rest
is iOS/Android UX and the cross-platform contract.

---

## 0. Findings at a glance

1. **On iOS one tapped filename costs two modals.** Chat → (sheet 1) workbench → file list →
   (sheet 2) preview. There is no preview route; the workbench is the only consumer of a
   chat path. `ChatPage.swift:2522`, `:2542-2543`, `:383`, `NativeWorkbenchPage.swift:24`,
   `FilesPage.swift:59`, `:142-168`.
2. **The extra layer is spec, not drift.** `spec/ui/v1/README.md` §1 makes the workbench the
   entry for "对话里点工具写出的文件路径" (`README.md:53`, NativeWorkbenchPage row) and makes the
   preview a *sub-page of the file browser* (`README.md:52`, FilesPage row). Removing the layer is
   cheap in code and needs a spec edit to stay legal.
3. **The real work inside that layer is path reconciliation**, not browsing: unknown-path
   refresh, NFC/NFD fallback, unique-basename fallback, "write still in flight" retry
   (`ChatPage.swift:2530-2550`, `:635-645`, `FilesPage.swift:142-168`). That belongs in a route
   resolver, not in a sheet.
4. **Android has a preview *skeleton* but no preview data and no OS handoff.** The route, the
   pure state machine, the renderers' extension routing and the copy all exist; the host never
   supplies a read (`PdshNavHost.kt:393-405` passes `files = null`; `FilePreviewRead` is only
   constructed in tests), never supplies a WebView for HTML, never supplies share
   (`onShare = {}`), and the app has no `Intent`, no `startActivity`, no `FileProvider`, no
   `ACTION_VIEW`/`ACTION_SEND` and no Compose `@Preview` anywhere.
5. **The official DSH page (and with it the official preview) is not a user-facing surface on the
   phone.** On iOS the engine WebView lives in a 2x2 invisible anchor (`RootView.swift:10-19`,
   `Components.swift:44-62`) and no `WebSurfacePage` is instantiated anywhere; on Android the web
   face is opt-in behind `pdsh.face.web` (`HostShell.kt:143-152`). The page's own previews are
   gated to the loopback origin (`NavigationPolicy.kt:26-37`), and local files are never served
   over that HTTP origin.
6. **Official DSH already answers the architecture question**: a preview is a **tab in a
   surface beside the conversation**, opened directly from a chat link, deduplicated by resource
   address, with a renderer registry, a plain-text fallback, and an "Open in app" split button
   (`ui-chat/src/client/apply.ts:245-263`, `ui-sidebar-right/README.md:39-50`, `:93`).
7. **On a phone that surface is full-screen, not a rail**: the official panel switches to
   fullscreen below 768 px (`SidebarRight.tsx:360`, README `:39`). The right answer for
   phone-dsh is therefore a **full-screen preview route with its own tab strip**, not a modal
   chain and not a sidebar.
8. **Both platforms have an honest-loading regression**: the first frame of a preview today says
   "这个文件已经不在了。" before any read has answered (`FilesPage.swift:315-318`,
   `FilesPage.kt:370-375`).

---

## 1. iOS today: why a chat file link goes through an extra layer

### 1.1 The call path

```
对话 ChatPage
  tap 文件名 / 附件行 / markdown 链接 / 命令结果里的链接
    └─ openWorkspaceResult(path)                      ChatPage.swift:2522
         normalize → refreshFiles if unknown → NFC match → unique basename
         └─ initialWorkbenchPath = match; showWorkbench = true   :2542-2543
              └─ [sheet 1] NativeWorkbenchPage(sessionID:initialPath:)   :383
                   ├─ Picker 文件 | 命令                            NativeWorkbenchPage.swift:16-21
                   └─ FilesPage(initialPath:)                        :24
                        └─ .task → openInitialPathIfNeeded()         FilesPage.swift:142-168
                             └─ selectedFile = match
                                  └─ [sheet 2] FilePreviewPage        :59
                                       ├─ Quick Look（子 VC）         :297 / :456-487
                                       ├─ PDSHPageView（HTML）        :301
                                       ├─ Text / Markdown            :306-314
                                       ├─ 完成 → dismiss              :324
                                       └─ ShareLink                  :328
```

Three facts about this path are worth naming precisely:

* **`FilePreviewPage` is private to `FilesPage.swift`** (`:224`) and has exactly two callers: the
  row button (`:125-134`) and the deferred open from `initialPath` (`:166`). Nothing else in the
  app can present a preview.
* **`initialPath` exists only for the chat path.** `NativeWorkbenchPage.initialPath` →
  `FilesPage(initialPath:)` is the whole reason the workbench takes an argument
  (`NativeWorkbenchPage.swift:8`, `:24`).
* **`initialWorkbenchPath` is cleared only when the sheet closes** (`ChatPage.swift:631-633`), and
  a path that could not be matched is parked in `pendingPreviewPath` and re-opened when
  `model.files` changes (`:635-645`).

### 1.2 Why the layer exists (four reasons, each with evidence)

| # | Reason | Evidence |
|---|---|---|
| R1 | The workbench is the only thing wired to a path; there is no preview route or state. `openWorkspaceResult` can only set `showWorkbench`. | `ChatPage.swift:2522-2551` |
| R2 | The preview is a *child of the file browser*: `.sheet` is attached to the list, so a preview must have a list beneath it. | `FilesPage.swift:59-64` |
| R3 | Turning a tool-reported path into a real `WorkspaceFile` is genuine reconciliation work (refresh, NFC/NFD, basename, in-flight write). The layer absorbs that work by re-running it inside the file list. | `ChatPage.swift:2530-2550`; `FilesPage.swift:142-168` |
| R4 | The spec encodes it: workbench entry = "对话里点工具写出的文件路径（含待预览路径补开）" (`README.md:53`), files page navigation = "页面栈；预览子页 FilePreviewPage" (`:52`). | `spec/ui/v1/README.md` §1 |

Historical note: the nested-modal trap has already bitten this path once — `fd48bcb9 Files: host
Quick Look inline instead of a nested modal`, and the comment at `FilesPage.swift:292-297` and
`:449-455` explains that a second modal from inside a sheet is silently dropped by iOS.

### 1.3 What the extra layer costs

| # | Symptom | Mechanism |
|---|---|---|
| C1 | Two stacked modals for one tap; three when the link is inside the command-result sheet (`ChatPage.swift:405-410` → `:4243`). | sheet-in-sheet |
| C2 | **Closing the preview lands in the file browser, not in the chat.** Reaching chat needs a second dismiss. | `FilesPage.swift:59` + `:324` |
| C3 | The 文件/命令 picker — irrelevant to reading a file — is on screen behind the preview, and a user can land in 命令. | `NativeWorkbenchPage.swift:16-21` |
| C4 | The same file is loaded twice: the list's `.task` refresh and the preview's `.task`. | `FilesPage.swift:57`, `:352` |
| C5 | No way to move to the next file without dismissing twice. | no preview-level navigation |
| C6 | Tapping a chat path twice can look different, because the parked path and the sheet state are independent. | `ChatPage.swift:643`, `:631-633` |
| C7 | Two image experiences in one transcript: markdown inline images already have a tap-to-fullscreen lightbox, attachments route through the workbench chain. | `NativeMarkdownBody.swift:348-380` vs `NativeMessageRows.swift:129-154` |

### 1.4 Where the preview should open — three candidates, one decision

| Candidate | Fits | Breaks |
|---|---|---|
| **A. chat inline only** | zero navigation; perfect for a bounded peek | cannot hold PDF/HTML/tabs/zoom; a 40 MB CSV in the transcript is a scroll bomb |
| **B. full-screen preview route (push in the current stack)** | one layer, system back = dismissal, chat scroll/state untouched, room for tabs and zoom, both platforms already have a route/push concept | loses the "still in the chat" feel for a 2-second glance |
| **C. sidebar tab / panel** | official DSH model | iOS has no persistent sidebar (`NativeTab` is declared and unused, `NativeShell.swift:13-31`; navigation is a drawer at `:284-311`); no multi-pane on a phone |

**Decision: B as the default, with A promoted to a bounded *peek* and C's tab strip moved inside B.**

Rationale, in order of weight:
1. Official DSH itself degrades the panel to **fullscreen below 768 px**
   (`ui-sidebar-right/README.md:39`, `SidebarRight.tsx:360`) — i.e. the phone form of the
   official model *is* a full-screen surface.
2. PUSH (not a cover/sheet) gives the platform back gesture for free and keeps the origin screen
   (chat, list, artifacts) intact — which is exactly what C2 fails at today.
3. A tab strip inside the preview recovers the official model's real benefit (compare two files,
   return to a file you were reading) without inventing a phone sidebar.
4. The peek (A) is the only place where "stay in the chat" matters, and it must be *bounded* by
   design: text first page, image, PDF page 1 — never a full renderer.

### 1.5 Smaller iOS defects found on the way

| # | Symptom | Evidence | Note |
|---|---|---|---|
| D1 | First frame asserts the file is gone until the read answers | `FilesPage.swift:315-318` (`else` branch = `ContentUnavailableView`), load task at `:352` | there is no loading branch at all |
| D2 | No "load more": text caps at 200 lines / 256 KiB with a footer sentence | `:226-231`, `:404-414` | official has paged reads + Load more (`ui-sidebar-documentpreview/README.md:56`) |
| D3 | Two caps and two code paths: JSON/CSV read 8 MiB directly from disk, everything else 256 KiB over the Worker | `:229-231`, `:374-388`, `:399-414` | same file type family, different truth |
| D4 | Share is silently absent when the path check fails; the reason is only in the bottom bar | `:326-333`, `:343-350` | share should be a property of "file exists", not of the same check as rendering |
| D5 | A standalone `.html` cannot be previewed at all (needs a workspace owner) | `:277-282`, `:298-304` | the page emitter exists; only the root is missing |
| D6 | HTML preview never shows its CSP tier, though the engine knows it | `:364` fixed sentence vs `PageSchemeHandler.swift:455-457` | "sandbox / local / online" is measurable |
| D7 | No reload for an HTML preview; `updateUIView` reloads only on URL change | `PageSurface.swift:142-145` | a page that fails has no retry |
| D8 | External navigation is cancelled with no feedback | `PageSurface.swift:187-195` | a tapped link does nothing |
| D9 | Dark mode: the files page paints `Color.white` unconditionally and the drawer forces light | `FilesPage.swift:55`, `NativeShell.swift:168`, `:252` | preview sheet inherits white |
| D10 | Two different workspace root computations: browser = `workspaceRoot/materialized/workspace`, inline markdown image = `workspaceRoot/<rel>` | `FilesPage.swift:243-248` + `ChatModel.swift:836-839` vs `NativeMarkdownBody.swift:385-390` | at most one is right; must be one resolver |

---

## 2. Android: how it opens files, web and local content

Short answer: **it does not open anything yet.** Android has a well-built preview *skeleton*
(route + pure screen state + extension routing + copy + tests) with **no host data and no
platform handoff**. There is no intent, no share sheet, no FileProvider, and no per-file WebView.

### 2.1 What exists

| Layer | What it is | Evidence |
|---|---|---|
| Route | `PdshRoute.Files(folderId)` = PUSH; `PdshRoute.Workbench(previewPath, section)` = SHEET; `PdshRoute.WebSurface` = FULLSCREEN | `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshRoute.kt:84-86`, `:143-148`, `:165-167` |
| Router | push/pop stack with `canGoBack`, `replaceTop`, `contains` | `PdshRoute.kt:216-242` |
| Preview state | `FilesScreenState.from(FilesSource, FilesLocalState)` — pure; preview is a **sub-state** (`previewPath`), not a route | `ui/page/FilesPage.kt:302-437`, `:560-585` |
| File-type routing | `classifyFileKind`: HTML / MARKDOWN / TEXT / EXTERNAL, plus Android toolchain extensions (`kt`, `kts`, `java`, `gradle`) | `FilesPage.kt:112-167` |
| Preview bodies | text (both-axis scroll), page surface (host-supplied), unsupported card | `FilesPage.kt:905-966`, `:968-989` |
| Back behaviour | header back = close preview → up a directory → leave page | `FilesPage.kt:621-629` |
| Workbench | files/commands segments; preview path taken from the route | `ui/page/NativeWorkbenchPage.kt`, `PdshNavHost.kt:587-609` |
| Artifacts | list + attribution; opening says there is no preview | `ui/page/SessionArtifactsPage.kt:19-21`, `PdshNavHost.kt:704-766` |
| Tests | JVM tests drive the state machine (`FilesPageTest.kt`), device screenshots for other pages | `android/lib/src/test/.../FilesPageTest.kt` |

The Android preview state is arguably *better designed* than iOS's: it is a pure function, it has
an explicit `waiting` state, and the back stack is a single value. The problem is entirely below
it (no data) and beside it (no OS integration).

### 2.2 What is absent (each verified by search)

| # | Absent | Evidence |
|---|---|---|
| A1 | **No file listing**: the route hard-codes `FilesSource(files = null)` → the page renders its waiting state forever | `PdshNavHost.kt:393-405` |
| A2 | **No file read**: `FilePreviewRead` is constructed only in tests; no host code path produces one | `grep 'FilePreviewRead('` → `lib/src/test/.../FilesPageTest.kt` only |
| A3 | **No WebView for HTML**: `FilesPage(pageSurface = …)` is never supplied, so `FilePreview.Page(available=true)` would render an empty box | `FilesPage.kt:918-933`; `FilesRoute` passes no surface (`PdshNavHost.kt:395-405`) |
| A4 | **No share**: `onShare = {}` and `shareable` is always null, so the 分享 action never renders | `PdshNavHost.kt:402-404`; `FilesPage.kt:638-644` |
| A5 | **No OS handoff**: zero `Intent` / `startActivity` / `ACTION_VIEW` / `ACTION_SEND` under `android/` (outside engine lifecycle services), no `<provider>`/FileProvider, one activity, no VIEW/SEND intent filters | `app/src/main/AndroidManifest.xml`; a `grep -rn` for ACTION_VIEW, ACTION_SEND, startActivity and FileProvider returns nothing |
| A6 | **No artifact preview**: the open gesture never previews — it reports "可通过系统分享用其他应用打开" or "文件已不在本机产物存储中" | `PdshNavHost.kt:740-760`; `UiStrings.kt:1509-1511` |
| A7 | **No Compose `@Preview`** anywhere; previews are device screenshots only | `grep '@Preview'` → none |
| A8 | **No visual baseline** for the files/workbench screens (no FILES/WORKBENCH samples in the screenshot suite) | `lib/src/androidTest/.../ScreenshotSamples.kt` |
| A9 | **The host refuses every preview gesture by name**: tapping a workbench row hands off `OpenWorkbenchFile`, which the shell answers with a notice | `PdshNavHost.kt:601-607` → `HostShell.kt:328`, `:354` |
| A10 | The route even prints the gap: "本宿主未实现文件内容读取；预览保持待读" | `HostShell.kt:394-395` |

### 2.3 The one web surface, and what it is not

| Question | Answer | Evidence |
|---|---|---|
| Is there a WebView? | Yes — exactly **one**, owned by `:engine`, loading the official DSH page | `engine/src/main/kotlin/com/phonedsh/engine/WebViewEngine.kt:634-645` |
| JS? | `javaScriptEnabled = true`, DOM storage on, mixed content never allowed, `LOAD_DEFAULT` | `WebViewEngine.kt:634-645` |
| Where does the page come from? | `http://127.0.0.1:<random port>` served by an embedded Ktor CIO server with a per-start token | `net/src/main/kotlin/com/phonedsh/loopback/LoopbackServer.kt:38-66`, `:119-189` |
| Which routes? | `/` launch page, `/index.html`, `/{tail...}` static assets, channel upgrade, `/v1/http` egress, protocol proxy | `net/src/main/kotlin/com/phonedsh/loopback/LoopbackService.kt:157-195` |
| Can it navigate out? | No. `NavigationPolicy` allows only the exact origin + its paths + `blob:` from that origin | `engine/.../NavigationPolicy.kt:26-37` |
| What is `blob:` for? | the Web UI's own document previews (the comment says so) | `NavigationPolicy.kt:34-35` |
| Is any local file served over HTTP? | No. There is no file route; the parser accepts only assets from `assetsDir` | `LoopbackService.kt:188-195`, `StaticAssetStore.kt` |
| Is there an address bar / reload / open-in-browser? | No. It is a full-screen hosted app, no toolbar | `ui/page/WebSurfacePage.kt:1-28`; `PdshRoute.kt:165-167` |
| Cleartext policy | only `127.0.0.1` is exempted; everything else keeps the platform default | `app/src/main/res/xml/network_security_config.xml` |

So "web preview" on Android today = **the DSH web app**, not a browser. There is no second
WebView, no per-file origin, and no equivalent of iOS's `pdsh-page://` scheme.

### 2.4 Android-specific constraints that shape the contract

| Constraint | Consequence |
|---|---|
| No `QLPreviewController` equivalent in-app ("Android has no equivalent in this module", `SessionArtifactsPage.kt:19-21`) | binary preview must be **share/open-with first**, in-app rendering later |
| No FileProvider and no `<provider>` in the manifest | sharing requires a new manifest entry + `res/xml/file_paths.xml` — a platform task, not a UI one |
| One activity, one WebView (the engine), one loopback origin with a launch token | a second WebView for HTML preview must be a **new component**, and must never load the tokenized loopback origin |
| Screenshot tests are device-instrumented, no `@Preview` | preview screens must get golden samples before they can be reviewed cheaply |
| The page-structure gate compares Android to iOS contracts (`spec/ui/v1/pages/files.json`, `native-workbench.json`) | splitting the preview out of `FilesPage` requires new/updated page contracts and whitelist entries, otherwise the gate fails |

### 2.5 The second surface nobody sees: the official page, and the native bridge it already has

There are two clients of the same workspace in this app, and only one of them is on screen.

| | Native shell (chat / files / artifacts) | Official DSH page (the engine WebView) |
|---|---|---|
| iOS visibility | the product | **never visible**: a 2x2 transparent anchor, `accessibilityHidden`, `allowsHitTesting(false)` (`RootView.swift:10-19`, `Components.swift:44-62`); no `WebSurfacePage` call site exists |
| Android visibility | the product | opt-in: `engine.webFaceOnLaunch()` + `pdsh.face.web`, pushed as `PdshRoute.WebSurface` (`HostShell.kt:129`, `:143-152`) |
| Preview | none (this research's subject) | the full official `ui-sidebar-documentpreview`, opened from that page's own chat / file tree |
| Office | none | `plugins/phone-native-preview` -> WKWebView message handler -> system Quick Look, path resolved by `workspaceFiles/stat` and re-checked with realpath (`Sources/PhoneDSHEngine/WebEngineNativePreview.swift:1-27`) |

Consequences for the contract:

1. **The native preview route is not a duplicate of the web preview - it is the only preview a user
   can reach today.** So it cannot be "just open the web page at that file".
2. **The Office hand-off is already solved once, in the bridge**, and its rules are the rules the
   native route should reuse: resolve through `workspaceFiles/stat`, accept only `/dsh/workspace/…`,
   map into the materialized workspace, re-check with realpath, **never copy the bytes, never write
   a temp file**, one in-flight request, and a result code the UI can render
   (`WebEngineNativePreview.swift:8-27`). A second, independent Quick Look path in the native shell
   would be a second set of bugs.
3. **If the web face is ever promoted to a visible surface, the two preview stacks must share the
   resolver and the caps**, or the same file will read differently depending on which face the user
   is in.

Note on the existing audit: `docs/receipts/ios-baseline-screens/REACHABILITY.md` row 17 lists
`web-surface` as user-reachable at `RootView.swift:17`; that line is now the anchor's
`accessibilityHidden(true)` and no `WebSurfacePage` call site exists in the tree. The row should be
re-derived (out of scope here, flagged not fixed).

---

## 3. Official DSH precedent (copy / do not copy)

Deep dive on the renderers themselves: `02-official-dsh.md`. What follows is the surface model and
the decisions this research borrows from it.

| Topic | Official behaviour | Source |
|---|---|---|
| Where a preview opens | **A tab in the right Sidebar**, beside the conversation — not a modal, not a desktop app | `ui-chat/src/client/apply.ts:245-263` ("Files open in the right Sidebar, not in a desktop application") |
| Identity | the **whole resource address** is the content identity; same address → focus existing tab; different dirs with the same name → two tabs | `ui-sidebar-documentpreview/README.md:31`, `:126` |
| Chat links | assistant markdown file links open the sidebar after the message settles; `#L24` becomes a navigation parameter (not part of the address) | `ui-chat/README.md:38`; `apply.ts:261-262` |
| Renderer choice | a registry of renderers per extension; a dropdown when several match; plain text only for text-compatible sources; binary containers get an "unsupported" state, **no read** | `README.md:31-35`; `document/unviewable.ts` |
| Narrow viewport | panel auto-fullscreen **below 768 px**; leaving fullscreen closes it | `ui-sidebar-right/README.md:39`; `SidebarRight.tsx:360` |
| Tabs & back | tab strip per pane, two horizontal panes max, one tab minimum while expanded; **no content back/forward stack** (a known limitation) | `ui-sidebar-right/README.md:70`, `:147` |
| Loading | one centred 28 px `StateDot` + "Rendering document…"; additional pages keep loaded content and add a 14 px inline spinner | `LoadingIndicator.tsx`; `README.md:66` |
| Errors | mapped per host code: `too-large` names the cap, `not-text` → unsupported + Open, `not-found` → explanation only, transport → Retry; loaded content is retained on a later failure | `failure-line.ts`; `README.md:56` |
| Large files | text is **paged** (`offset`, until `eof`); complete-bytes formats are capped by the host, never truncated; Excel has its own 16 MiB / 250 k cells / 15 s limits | `README.md:56-57`, `:81-86` |
| Open vs Preview | preview stays in-app; a separate **"Open in app" split button** (default app / show location) appears only when the host reports `canOpenWorkspacePath` | `ui-open-in-app/README.md` |
| Web pages | a **separate Browser tab type**: address bar + Back/Forward/Reload/Go + "Open in system browser"; loopback allowed; `file:` rejected; per-tab sandbox toggle (Web only) with an amber warning | `ui-sidebar-browser/README.md:22-30`, `:60-68` |
| Local HTML JS policy | a **product setting**, not a per-tab toggle: Off = sanitised static iframe with no scripts; On = scripted blob iframe, `sandbox="allow-scripts"` without same-origin, relative `.js`/`.css` packed under 4 MiB/asset, 32 MiB/64 assets | `ui-sidebar-documentpreview/README.md:49`, `:60` |
| Images | inline contained preview + shared lightbox; a hover-dwell **thumbnail peek** for image file links | `ui-chat/README.md:46` |
| A11y (as stated) | loading status has `role="status"` + accessible name and respects reduced motion; shortcut tooltips carry the binding | `LoadingIndicator.tsx`; `ui-open-in-app/README.md` |

**Copy:** direct open from chat; address-identity dedupe; renderer registry with plain-text
fallback and an explicit unsupported state; paged text + Load more; code-mapped error copy with a
recourse; full-screen degradation on narrow screens; a separate browser surface for HTTP(S);
"Open/Share" as a first-class action with a host capability check.

**Do not copy (for a phone):**
1. **Two horizontal panes + drag/dock**: no room on a 402 pt screen, and it is where most of the
   sidebar's complexity lives.
2. **A per-tab sandbox/JS toggle**: official itself calls the unsandboxed frame a compatibility
   escape hatch with an amber warning; on a phone a per-tab switch becomes a footgun. Use one
   product setting + a visible tier chip instead.
3. **An address bar for local documents**: a local page has no user-typeable URL. Only the HTTP(S)
   browser surface gets an address bar.

---

## 4. Proposed contract — Preview v1 (both platforms)

### 4.1 Principles

1. **One gesture, one layer.** A tap on a file reference never opens a browser to get to a viewer.
2. **Depth is chosen by intent, not by file type.** Peek vs full is a user decision (tap vs
   press-and-hold), not a consequence of the extension.
3. **The preview owns its own chrome.** Title, tabs, actions, states live inside the preview
   surface; the host page behind it never has to know a preview is open.
4. **One path resolver, one read API, one set of caps** for both platforms and for every entry
   point (chat, list, artifacts, commands, workbench, deep link).
5. **Never assert what has not been read.** Loading, unsupported, too-large, missing and transport
   failure are five different screens with different recourses.

### 4.2 Surfaces (three depths) and file-type routing

| Depth | Name | What it shows | How it is reached | Dismiss |
|---|---|---|---|---|
| **D0** | reference chip (in chat) | glyph + name + one-line excerpt or size; no body | rendered by the transcript | n/a |
| **D1** | **peek** | a *bounded* body: text first N lines, one image, PDF page 1, HTML thumbnail or "网页预览需打开" | press-and-hold on D0; long-press on a list row | swipe down → **back to the exact origin, scroll preserved** |
| **D2** | **preview screen** | the full body + tab strip + actions + states | tap on D0/D1/row/"打开"; deep link; `预览` in a menu | back → origin |

D1 is deliberately *not* a smaller copy of D2: it never mounts a real renderer that can take
seconds (no PDF.js, no HTML JS), and it never offers tabs.

**File-type routing.** The extension is only a hint; the read's own verdict wins (a NUL byte or
invalid UTF-8 means binary — `FilesPage.kt:454-466`, and iOS should adopt the same check instead of
trusting its extension list, `FilesPage.swift:284-288`).

| Family (extensions) | D1 peek | D2 body | Actions |
|---|---|---|---|
| text / code / log (`txt md json yaml yml xml py js ts swift kt kts java gradle sh toml ini diff css c h go rs log`) | first ~40 lines, one truncated screen | paged text; markdown and code get their renderers | share · open |
| CSV / TSV | first ~20 rows as monospace | paged text now; table view in P2 | share · open |
| images (`png jpg jpeg gif webp svg`) | fit-width thumbnail | zoomable image (`svg` static, scripts never run) | share · open |
| PDF | page 1 only | PDF viewer (iOS: Quick Look today; Android: `ACTION_VIEW` in v1) | share · open |
| HTML / HTM | no live page — "网页预览需打开" | sandboxed local page + tier chip + reload | share · reload |
| Office (`doc docx ppt pptx xls xlsx`) | none | system hand-off only (Quick Look / `ACTION_VIEW`); no in-app renderer in v1 | share · 打开方式 |
| binary containers (`zip gz tar mp4 mp3 ttf ttc sqlite db dmg iso wasm …`) | none | unsupported card + measured size | share · 打开方式 |
| unknown suffix, decodable | first ~40 lines | paged text | share · open |
| unknown suffix, not decodable | none | "无法作为文本预览" + size | share · 打开方式 |

Two rules this table encodes: **a peek never reads more than one page**, and **an unpreviewable
file always offers the way out** (share / open-with) instead of a dead end.

### 4.3 Routing table

| Entry | Depth | Route / presentation | Back lands on |
|---|---|---|---|
| chat: markdown link, attachment row, "预览 <path>" chip, changed-files card | **D2** (tap) / D1 (long-press) | preview route, PUSH | chat, same scroll |
| chat: command-result sheet link | D2 | preview route pushed above the result sheet | the result sheet |
| files list row | D2 | preview route PUSH | the list at the same directory |
| workbench row | D2 | preview route PUSH (workbench stays a sheet) | workbench |
| artifacts row | D2 | preview route PUSH | artifacts |
| web UI link (`dsh-resource://…`) | D2 | same route, same resolver | wherever it came from |
| http(s) URL | **browser surface** (not a file preview) | its own full-screen route | origin |

Rule: **the preview route is the only place a file body is rendered.** The workbench and the file
list become *navigators*, never viewers — this is what removes iOS's sheet-in-sheet and Android's
duplicated `previewPath` state.

### 4.4 Actions: Open vs Preview vs Share

| Action | Meaning | Availability rule |
|---|---|---|
| **Preview / 预览** | bounded D1 peek | any file whose bytes exist; never offered for a missing file |
| **Open / 打开** | enter D2 | any file the app can read as text/markdown/image/PDF/HTML; for a binary it becomes **"打开方式…"** with an explanation, never a silent no-op |
| **Share / 分享** | platform share sheet (`ShareLink` / `ACTION_SEND` + FileProvider) | **every file that exists on disk**, independent of whether it can be rendered. Today iOS ties it to `safeFileURL` and Android never offers it — both wrong |
| **Open in app / 在应用打开** | hand the file to another installed app (`ACTION_VIEW` chooser / iOS share sheet's app row / `UIDocumentInteractionController`) | only when the file exists and a handler resolves; otherwise show the share sheet |
| **在浏览器打开** (HTTP only) | system browser | never for a local page; **never for the engine loopback origin** (it carries a launch token — `LoopbackServer.kt:119-189`) |
| **Reload** | re-read the same path / reload the page | always in D2's header; D1 never reloads |

No action may be present-but-dead. A capability the host lacks (`canOpenWorkspacePath`,
FileProvider, PDF renderer) removes the action from the menu *and* explains the absence once, in
the empty state — the official `ui-open-in-app` rule.

### 4.5 Tabs, history, back

* **One preview screen, N tabs.** A tab is keyed by the resolved path (address identity, as
  official does), so the same file opened twice focuses instead of duplicating; two files with the
  same basename in different directories are two tabs.
* **Cap: 6 tabs, LRU** — beyond that the oldest non-focused tab is closed. Tabs are *transient*:
  never persisted across launches (official persists layout but not content; on a phone even the
  layout is not worth the state).
* **Inside a tab**: text/PDF keep scroll position per tab; HTML keeps its own in-page history
  (WebView back), which is *separate* from the route back.
* **Back semantics, in priority order**: ① close peek; ② HTML in-page back if the page navigated;
  ③ close the focused tab (first tab closes the preview); ④ return to the origin.
* **Never** return to a screen the user did not open (the current iOS C2 failure).
* **No content forward/back stack** beyond the above — that is a documented official limitation
  (`ui-sidebar-right/README.md:147`) and would add a second, confusing history to a phone.

### 4.6 Chat link direct open (the rule)

A tap on any file reference in the transcript resolves the path with the **same resolver as the
files list** and then:

1. path resolves → **open D2 directly**, no browser sheet, no workbench hop;
2. path unknown but a unique basename match exists → open D2 for that file and show a one-line
   note ("按文件名匹配到 `…`");
3. path still unknown → **do not lie and do not open a browser**: keep the reference tappable,
   show "文件还在写入" + a Retry, and auto-open when the workspace listing changes (this is the
   `pendingPreviewPath` behaviour at `ChatPage.swift:635-645`, which is good and should survive);
4. path escapes the workspace or has `..` → refuse with a concrete reason.

### 4.7 Web preview contract

"Web preview" below means **rendering a web document**, not "showing the DSH web app's right
sidebar": that surface is invisible on iOS and opt-in on Android (§2.5), so it cannot be the
preview. The two things being contract-ed are a local page and a remote page, never one screen:

| | **Local page** (workspace `.html`) | **Web page** (`http(s)://`) |
|---|---|---|
| Surface | D2 with a page body | separate **browser surface** (full-screen, own route) |
| Origin | `pdsh-page://<workspace>/<path>` on iOS; a dedicated read-only scheme/handler on Android (new) | the real URL |
| JS | **product setting** "允许页面脚本" (default: on for workspace pages), plus a visible chip `脚本开/关` | always on |
| Network | per the page's declared CSP tier (`sandbox`/`local`/`online`) — show the tier as a chip | network allowed; mixed content / private network per platform policy |
| Address bar | **no** — instead a read-only origin line (`本地源 · 不出网`) | yes, with Go |
| Reload | yes, header action | yes, toolbar |
| Back | closes the tab (no in-page nav, CSP forbids frames) | in-page history first, then close |
| External open | only via an explicit "分享此文件"（不是"在浏览器打开"） | "在系统浏览器打开" |
| Blocked navigation | show "已阻止页面跳转" — never a dead tap (fixes `PageSurface.swift:187-195`) | n/a |
| Localhost | the engine origin is **never** a preview target and is **never** handed to the system browser (token) | allowed as a normal URL, but a link to the engine port is rendered as "本机 DSH 服务" and opened only in the in-app browser surface |

### 4.8 States

```
                    ┌──────────────┐
   open ──────────► │ reading      │  spinner + file name + size (no claim about existence)
                    └──────┬───────┘
        ok ┌───────────────┼────────────────┬──────────────┬─────────────┐
           ▼               ▼                ▼              ▼             ▼
       ready ◄── eof ── partial        unsupported     missing       error
        │  │            (Load more)    (binary)        (not found)   (transport)
        │  └── file changed ──► stale ──► reload
        │                        │
        └── too-large ───────────┴──► unsupported(cap) + [分享 / 打开方式]
```

| State | Copy shape | Recourse |
|---|---|---|
| reading | "正在读取…" + name + size | none (cancel = back) |
| ready | body | share / open |
| partial | body + "仅显示前 N 行 / 已加载 x/y" | **载入更多** |
| unsupported (binary container) | "无法在应用内预览" + measured size | 分享 / 打开方式 |
| too-large | "超过 N MB 上限" (name the cap) | 分享 / 打开方式 |
| missing | "文件不在了" + path | 刷新工作区 |
| error (transport) | last content kept + "读取失败：…" | 重试 |
| unsafe | "这个路径不能预览" | none |
| no session | "没有当前会话…" | 切回会话 |

Rules: never truncate silently; never replace loaded content with an error; never show
"missing" before a read answered (fixes D1 and `FilesPage.kt:370-375`).

### 4.9 Large files

* **Text** (incl. md/code/json/csv/log): paged read (`offset` + `limit`), first page ≈ 200 lines /
  64 KiB (the peek shows less — §4.2), "载入更多" until `eof`; **one cap for all text types** — delete the iOS JSON/CSV 8 MiB
  special case (D3) in favour of paging.
* **Binary** (image/PDF/office/archive): never into `Data`/`ByteArray` on the UI path. iOS keeps the
  Quick Look URL (bounded, path-checked); Android opens with an `ACTION_VIEW` chooser.
* **PDF/images in-app** is P2 and, when it lands: fit-width default, 25–400 % zoom, lazy pages.
* Any cap that is hit **is named in the UI** with the number, plus the escape (share/open) — the
  existing footer sentences are the right instinct (`FilesPage.swift:379-414`), they just need the
  recourse to be actionable rather than a sentence.

### 4.10 Dark mode

* Preview chrome uses semantic colours only. Remove `Color.white` from the files page
  (`FilesPage.swift:55`) and stop forcing light on the drawer for preview content
  (`NativeShell.swift:168`, `:252`).
* Text/code bodies: system label colour + a dark syntax theme (Android already has tokens;
  iOS `NativeCodeHighlighter` needs a variant).
* Document bodies keep their own colours (PDF page, HTML page) but the **surround** (page gaps,
  insets, scrollbar) follows the theme — official does exactly this with a cool grey / matte black
  surround (`ui-sidebar-documentpreview/README.md:64`).
* HTML pages get `color-scheme: light dark` injected so form controls and scrollbars follow the
  system, without altering the page's own CSS.

### 4.11 Accessibility

| Item | Requirement |
|---|---|
| Focus | opening D1/D2 moves accessibility focus to the preview's title; closing returns it to the origin element |
| Announce | state changes are announced (`role="status"` / live region / `AccessibilityNotification`): reading → ready / partial / failed |
| Tabs | "第 2 个，共 3 个" on the strip; close targets ≥ 44 pt; the strip is a single adjustable group |
| Text body | reported as "文件内容，N 行，只读"; selection enabled; Dynamic Type to AX5 with horizontal scroll instead of clipping |
| HTML/binary | the container is one element with a label; always offer the escape hatch "以文本查看" (also the recovery for a broken page) |
| Motion | sheet/peek transitions respect Reduce Motion |
| Contrast | the state chips (tier, script on/off) must pass 4.5:1 in both themes |

### 4.12 Platform mapping (same contract, two idioms)

| Contract element | iOS | Android |
|---|---|---|
| D0 chip | `WorkspaceOutputReferences` / `NativeAttachmentList` | `ChatRows.PathReferenceRow` |
| D1 peek | `.sheet` with `.presentationDetents([.medium])` + drag indicator | `ModalBottomSheet` with a partial detent |
| D2 route | `NavigationStack` push, screen draws its own header | `PdshRoute.Preview(target)` + `PageFrame` |
| State | `FilePreviewPage.loadPreview` → one enum | `FilesScreenState.from` + a new `PreviewScreenState.from` |
| Tabs | custom strip + `ScrollViewReader` | `ScrollableTabRow` / LazyRow chips |
| Share | `ShareLink` (already) — but gated on existence, not on renderability | new `FileProvider` + `ACTION_SEND` / `ACTION_VIEW` |
| Local HTML | `PDSHPageView` (`pdsh-page://`, CSP tier) | **new** read-only scheme handler or `WebViewAssetLoader` + a WebView owned by the preview, CSP injected the same way |
| Binary / Office hand-off | reuse the rules of `WebEngineNativePreview` (stat-resolved path, realpath re-check, no byte copy, one in-flight request) | new bridge + `FileProvider`; `ACTION_VIEW` chooser, no in-app renderer in v1 |
| Text read | `workspaceFiles/read` offset/limit | same RPC through the host |
| A11y | `.accessibilityFocused` + announcements | `FocusRequester` + `liveRegion` semantics |

---

## 5. Screen & flow diagrams

### 5.1 Today (iOS) — two modals for one tap

```
 ┌───────────────────────────────┐
 │ 对话 ChatPage                 │
 │  [预览 report.pdf ───────────►│ tap
 └───────────────┬───────────────┘
                 │ openWorkspaceResult()            ChatPage.swift:2522
                 ▼
 ┌───────────────────────────────┐  sheet 1
 │ 工作面板 NativeWorkbenchPage  │  :383
 │  [ 文件 | 命令 ]              │  (irrelevant to reading a file)
 │   FilesPage(initialPath:)     │  :24
 │    └─ 列表（用户从未要求看它） │
 └───────────────┬───────────────┘
                 │ selectedFile = match             FilesPage.swift:142-168
                 ▼
 ┌───────────────────────────────┐  sheet 2 (nested)
 │ FilePreviewPage               │  :59
 │  Quick Look / PDSHPage / 文本 │
 │  [分享]            [完成]     │
 └───────────────┬───────────────┘
                 │ 完成
                 ▼
         回到文件列表（不是对话）  ← 两个「返回」有两种含义
```

### 5.2 Target (both platforms) — one layer, depths by intent

```
                        D0  transcript chip
                        ┌──────────────────────┐
                        │ ▤ report.pdf   1.2 MB│
                        │   first line excerpt │
                        └───┬──────────────┬───┘
              tap           │              │        press-and-hold
                            ▼              ▼
                 D2 预览页 (push)     D1 peek (medium sheet)
                 ┌───────────────┐    ┌───────────────────────┐
                 │ ‹  report.pdf ⋯│    │ ▤ report.pdf          │
                 │ ┌─┬─┬─┐ tabs  │    │  bounded body only    │
                 │ │1│2│3│       │    │  (200 lines / img /   │
                 │ └─┴─┴─┘       │    │   pdf p.1 / 网页需打开)│
                 │               │    │  [打开]      [分享]   │
                 │   body        │    └───────────┬───────────┘
                 │               │                │ swipe down
                 │ [载入更多]    │                ▼
                 └───────┬───────┘         回到对话原位置
                         │ back
                         ▼
                   origin screen
        (chat / file list / artifacts / workbench / command sheet)
```

### 5.3 Preview screen anatomy (D2)

```
┌──────────────────────────────────────────────────────┐
│ ‹             report.pdf                        ⋯    │  header: back · title · menu
├──────────────────────────────────────────────────────┤
│  ┌────────┐ ┌────────┐ ┌────────┐                    │  tab strip (≤6, path-keyed)
│  │report  │ │data.csv│ │app.html│                    │
│  └────────┘ └────────┘ └────────┘                    │
├──────────────────────────────────────────────────────┤
│                                                      │
│   body                                               │  text / md / code / image /
│   (per-tab scroll, per-tab renderer)                 │  pdf / html / unsupported
│                                                      │
│                                                      │
├──────────────────────────────────────────────────────┤
│ 仅显示前 200 行 · 载入更多        ·   分享   打开方式 │  status line + actions
└──────────────────────────────────────────────────────┘

menu ⋯: 分享 · 在应用打开 · 在文件夹中定位 · 重新加载 · (html) 脚本 开/关 · (web) 在浏览器打开
```

---

## 6. Prioritized roadmap

Cost is rough engineer-days including tests; "contract" means it changes the shared spec/state.

### P0 — remove the extra layer and make the screen honest (≈ 6-9 d total)

| # | Change | Impact | Cost | Evidence |
|---|---|---|---|---|
| **P0.1** | **Chat link opens the preview directly (iOS): delete the workbench hop.** `openWorkspaceResult` sets a preview target instead of `showWorkbench`; the workbench keeps only its own entries. | highest: the most common gesture loses one modal **and** one screen; C1-C4 disappear | S · 1-2 d · iOS only | `ChatPage.swift:2522-2551`, `NativeWorkbenchPage.swift:24` |
| **P0.2** | **One preview route, one entry API (both).** iOS: `FilePreviewPage` → `PreviewPage` presented by the route (no `.sheet` inside `FilesPage`). Android: `PdshRoute.Preview(target)`; drop `previewPath` from `FilesLocalState` / `WorkbenchLocalState`. | unlocks every later item; kills the nested-modal bug class; makes back single-meaning | M · 3-5 d · both, contract | `FilesPage.swift:59`, `FilesPage.kt:560-585`, `PdshRoute.kt:143-148` |
| **P0.3** | **Honest loading frame.** First frame = "正在读取…" + name/size, not "这个文件已经不在了。" | removes a false statement on every open | S · 0.5 d · both | `FilesPage.swift:315-318`, `FilesPage.kt:370-375` |
| **P0.4** | **Back returns to the origin**, and a dismissed peek never lands on a screen the user did not open. | fixes C2; the single most-reported kind of "lost" feeling in modal chains | S · 0.5 d · iOS (Android already pops a route) | `FilesPage.swift:59`, `:324` |
| **P0.5** | **Android: a real single-file read.** Host implements "read one path for preview" (text page + metadata) and wires it into the preview route; the *listing* can stay unbuilt if the route receives an explicit path. | without it Android's preview is permanently "待读" and A9 is the only outcome | M · 3-4 d · Android host | `PdshNavHost.kt:393-405`, `HostShell.kt:394-395` |
| **P0.6** | **Spec/fixture update**: §1 row 52-53 + new preview page row; Android page contracts (`files.json`, `native-workbench.json`) and whitelist entries. | keeps the page-structure gate green and makes the new model legal | S · 0.5 d · docs | `spec/ui/v1/README.md` §1, `spec/ui/v1/pages/` |

**P0 acceptance (all must hold):** from a chat path, one tap → preview → one back → chat at the
same scroll offset; preview's first frame never claims a missing file; on Android the same flow
shows real text; no screenshot golden regresses except the ones intentionally re-baselined.

### P1 — the preview becomes a surface (≈ 12-18 d)

| # | Change | Impact | Cost | Evidence |
|---|---|---|---|---|
| **P1.1** | **Tab strip + dedupe by path** (≤6, LRU, transient). | compare two files; revisit without re-navigating; official parity | M · 3-4 d · both | `ui-sidebar-documentpreview/README.md:31`, `:126` |
| **P1.2** | **Share/export everywhere** — iOS decouples share from renderability; Android adds `FileProvider` + `ACTION_SEND`, and "打开方式" via `ACTION_VIEW`. | today Android has *no* way out of the app; iOS silently hides share. This is the largest capability gap | M · 3-4 d · Android platform + both UI | `FilesPage.swift:322-351`, `PdshNavHost.kt:402-404`, `WebEngineNativePreview.swift:8-27` |
| **P1.3** | **Paged text + Load more + one cap**; delete the JSON/CSV 8 MiB branch; thread `#L24` as a navigation parameter. | no more "share the file to see the rest" dead ends; line links land on the right line | M · 2-3 d · both | `FilesPage.swift:229-231`, `:404-414`; official `README.md:56`, `:126` |
| **P1.4** | **Local HTML page contract**: origin line + tier chip + reload + "已阻止页面跳转"; JS is a product setting; Android gets its own read-only asset loader + WebView with the same CSP injection. | one coherent story for the most fragile file type; makes D6-D8 testable | M · 4-5 d · both | `PageSchemeHandler.swift:248-266`, `PageSurface.swift:142-145`, `:187-195` |
| **P1.5** | **Dark mode + Dynamic Type + focus/announcement** on preview chrome and bodies. | accessibility and the most visible visual defect (white sheet in dark mode) | M · 2-3 d · both | `FilesPage.swift:55`, `NativeShell.swift:168`, `:252` |
| **P1.6** | **Unsupported/too-large states with a recourse**, replacing the binary card's dead end. | turns a wall into an exit | S · 1 d · both | `FilesPage.kt:937-942`, `FilesPage.swift:389-398` |

### P2 — richness, once the surface is right (≈ 15-25 d, mostly optional)

| # | Change | Impact | Cost |
|---|---|---|---|
| P2.1 | **D1 peek** (press-and-hold, bounded body, haptics, scroll-preserving dismiss) | delightful, low frequency; needs design time more than code | M · 3-4 d |
| P2.2 | **In-app PDF + image zoom** (fit width, 25-400 %, lazy pages) | makes Android read PDFs without leaving the app; iOS already has it via Quick Look | L · 6-8 d (Android) |
| P2.3 | **Spreadsheet table view** (CSV/TSV first, XLSX later) | the one file type a phone currently cannot read at all | L · 8-10 d |
| P2.4 | **Office conversion** — do not start before the desktop provider decision | big, cross-cutting; see `docs/research-office-conversion-2026-10-29.md` | XL |
| P2.5 | **Per-tab scroll/line restore + in-preview search** | quality of life once tabs exist | S-M · 2-3 d |
| P2.6 | **Shared contract fixtures** (`preview.json` page contract + state fixtures both sides) | keeps the two implementations honest; replaces prose parity claims | M · 3 d |

### Explicit non-goals for v1

* No phone sidebar/rail; no two-pane docking.
* No address bar for local documents; no editing anywhere.
* No per-tab JS toggle (one product setting + a tier chip).
* No persisted preview tabs.
* No `file://` exposure to other apps and no handing the tokenized loopback origin to the system
  browser.
* No in-app renderer for Office/archive formats.

---

## 7. Open questions (need a decision above this receipt)

1. **Peek gesture**: long-press (iOS-friendly, discoverable via context menu) vs pull-down from
   the chip? Long-press is the safer default and matches the official "hover dwell" idea on touch.
2. **JS default for workspace HTML pages**: on (matches official "Coding Tools enabled") or off
   (safer, but every 3D demo breaks)? Recommendation: on for `pdsh-page://` workspace pages,
   because the CSP tier already bounds them; the setting exists to turn it off.
3. **Does `Preview` become a page in `spec/ui/v1`** (a real route with a contract) or stay an
   "embedded child page" like `CommandExecutionResultPage`? Recommendation: a real page — it has
   its own entry points, states and actions.
4. **Android binary strategy**: share-first only (cheap, honest) vs a PDF renderer in v1 (costly).
   Recommendation: share-first in P1, renderer in P2.
5. **Tab cap**: 6 is a guess; 4 may be better for a 402 pt strip with thumb reach.
6. **Who owns the workspace path resolver** (`WorkspacePathResolver` / `PreviewTarget`)? It has to
   be one shared, tested unit — today iOS has three near-copies (D10).

---

## 8. Evidence index

**iOS**
`examples/probe-app/PhoneDSHProbe/`
* `ChatPage.swift:383` workbench sheet · `:405-410` command-result sheet · `:631-645` pending path
  and auto-open · `:2522-2551` `openWorkspaceResult` · `:3682`, `:3986` markdown `OpenURLAction` ·
  `:4030-4060` `WorkspaceOutputReferences` · `:4063-4105` `workspaceRelativePath` ·
  `:4243-4275` `CommandExecutionResultPage`
* `NativeWorkbenchPage.swift:8`, `:13-39` (NavigationStack, segmented, Done, large detent)
* `FilesPage.swift:55` white background · `:59-64` preview sheet · `:100-139` list · `:142-168`
  deferred open · `:224-445` `FilePreviewPage` · `:226-231` caps · `:243-259` path check ·
  `:290-353` body branches · `:315-318` "already gone" first frame · `:322-334` Done/Share ·
  `:355-427` `loadPreview` · `:447-487` `EmbeddedQuickLook`
* `RootView.swift:10-19` invisible engine anchor (no visible web face) · `Components.swift:44-62`
  the 2x2 anchor view
* `NativeMessageRows.swift:122-158` attachment rows · `NativeMarkdownBody.swift:348-380` inline
  image + lightbox · `NativeShell.swift:13-31` unused `NativeTab` · `:168`, `:252` forced light ·
  `:284-311` drawer entries · `ChatModel.swift:834-843` workspace roots · `:2923-2944`
  `refreshFiles`

**Engine (iOS) and the preview plugins**
* `Sources/PhoneDSHEngine/PageSurface.swift:20-47` entry/URL · `:63-76` resolution failure copy ·
  `:120-140` WKWebView config · `:142-145` reload-on-URL-change · `:149-176` error bar script ·
  `:187-210` navigation policy + failure footer
* `Sources/PhoneDSHEngine/PageSchemeHandler.swift:20-26` contract · `:104-117` path validation ·
  `:227-239` tier detection · `:248-266` CSP per tier · `:454-458` CSP injection
* `Sources/PhoneDSHEngine/WebEngineNativePreview.swift:1-27` the existing native Office hand-off
  contract (stat-resolved path, realpath re-check, no byte copy, one in-flight request)
* `plugins/phone-native-preview/README.md`, `src/register.ts`, `src/protocol.ts` — the web-side
  `documentPreviews` registration that calls that bridge (`priority: 'extension'`,
  `loading: 'renderer'`, `.doc/.docx/.ppt/.pptx` only)

**Android**
* `android/lib/src/main/kotlin/com/phonedsh/ui/nav/PdshRoute.kt:84-86` Files · `:143-148`
  Workbench · `:165-167` WebSurface · `:216-242` stack
* `.../nav/PdshNavHost.kt:182`, `:194` route dispatch · `:393-405` `FilesRoute` (null listing, no
  surface, no share) · `:587-609` `WorkbenchRoute` · `:704-766` `SessionArtifactsRoute`
* `.../page/FilesPage.kt:112-167` `classifyFileKind` · `:216-228` `FilePreviewRead` · `:250-271`
  preview variants · `:370-393` projection (incl. "no read → gone card") · `:560-585` local state ·
  `:608-620` page signature (`pageSurface`, `onShare`) · `:905-966` `PreviewBody` · `:937-942`
  binary card · `:1023-1052` bottom bar
* `.../page/SessionArtifactsPage.kt:19-21` "no preview here"
* `.../page/NativeWorkbenchPage.kt` workbench state (segments, preview pending)
* `.../ui/UiStrings.kt:993-1009`, `:1509-1511`
* `android/app/src/main/kotlin/com/phonedsh/probe/HostShell.kt:216-220` `onOpenWorkbench` ·
  `:328` "宿主未实现" · `:354` action label · `:394-395` route note
* `android/app/src/main/AndroidManifest.xml` (no provider, no VIEW/SEND filter) ·
  `res/xml/network_security_config.xml` (127.0.0.1 cleartext only)
* `android/engine/src/main/kotlin/com/phonedsh/engine/WebViewEngine.kt:634-645` settings ·
  `:722-744` launch URL · `engine/src/main/kotlin/com/phonedsh/engine/NavigationPolicy.kt:26-37`
* `android/net/src/main/kotlin/com/phonedsh/loopback/LoopbackServer.kt:38-66`, `:119-189` ·
  `LoopbackService.kt:157-195`
* `android/lib/src/main/kotlin/com/phonedsh/ui/page/WebSurfacePage.kt:1-28` (full-screen host)
* `android/lib/src/test/kotlin/com/phonedsh/ui/page/FilesPageTest.kt` (state-machine coverage)

**Official DSH** (`packages/client/`)
* `ui-chat/src/client/apply.ts:245-263` openFile → sidebar (with the design comment)
* `ui-chat/README.md:38` link behaviour + `#L24` · `:46` image peek · `:48` link-opening setting
* `ui-sidebar-right/README.md:39-50` presentations / 768 px · `:70` tab rules · `:93`
  `openResource` semantics · `:147` no content history
* `ui-sidebar-documentpreview/README.md:31-37` registration · `:49` HTML JS policy · `:56-58`
  reads/reload · `:62-64` image/PDF/zoom · `:126` navigation
* `ui-sidebar-documentpreview/src/client/LoadingIndicator.tsx`,
  `.../document/unviewable.ts`, `.../failure-line.ts`, `.../definition.ts`
* `ui-open-in-app/README.md` (Open split button, `canOpenWorkspacePath`, show location)
* `ui-sidebar-browser/README.md:22-30`, `:60-68` (toolbar, sandbox, limits)
* `ui-sidebar-files/README.md` (tree rows → previews; per-code failure lines)
