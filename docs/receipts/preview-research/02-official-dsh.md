# 02 — Official DSH document preview: how it really renders (read-only)

**Provenance**

| Item | Value |
| --- | --- |
| Checkout | `/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness` |
| Commit | `7be5505b0be06009d74891c869063c9cf19a0df0` (2026-10-20) — identical to `plugins/dsh-pin.json` in this repo |
| Version | `@deepseek-ai/dsh-client-ui-sidebar-documentpreview` `0.2.1-rc.2` |
| Method | Read-only source, READMEs, host e2e specs. **No build, no server, no app launch, no git writes.** Paths below are relative to the checkout root |
| Not verified | Anything requiring a running GUI (screenshots, real WKWebView behaviour, CSP inheritance empirically). Flagged as inference where relevant |

Evidence tiers used in this file: **[src]** = source code read, **[doc]** = package README, **[e2e]** = committed end-to-end test asserting the behaviour, **[infer]** = reasoning from browser/WebKit semantics, not executed.

---

## TL;DR — top findings

1. **Two independent registries decide a file's renderer.** `ctx.sidebarRightTabs` picks the *tab type* by address glob (bands `extension > builtin > fallback`); `ctx.documentPreviews` picks the *renderer inside the tab* by filename suffix (bands `extension > builtin`, then longest suffix, then registration order). `ui-sidebar-documentpreview` owns only one tab type (`text`, band `fallback`) and eight renderers inside it. **[src]**
2. **There is no `dsh-resource://` file server and no bytes/page protocol invention.** A `file` resource address (`dsh-resource://file/session/<sessionId>/<path>`) is only an *identity*; metadata comes from a `useResource` hook backed by a host `workspaceFiles.stat` + `changes` watcher, and content comes from two host Remotes: `workspaceFiles.read` (line pages) and `workspaceFiles.readBytes` (complete bytes / byte range, optional `baseFile` relative resolution). **[src]**
3. **HTML preview is two completely different products gated by one boolean.** Off: DOMPurify-sanitized `srcdoc` iframe with `sandbox=""` plus a `default-src 'none'` CSP — no scripts, no network, no forms, no frames, no `href`. On: a `blob:` URL iframe with `sandbox="allow-scripts"` (no `allow-same-origin`) and **no CSP at all**, where inline scripts run, workspace-relative classic `.js`/`.css` are pre-read by the host and re-injected as in-frame blob URLs, and **remote network resources load normally**. **[src] [e2e]**
4. **The gate is the "Coding Tools / Show coding view" preference**, `ctx.configForms.developerTools.enabled` (host-persisted `ui-settings.enabled`, default `true`, fail-closed until the first accepted value arrives). Same switch enables the coding view in chat. **[src] [doc]**
5. **Official supports loopback services, but not in the document preview.** The preview's tab type only claims `dsh-resource://file/...` session addresses; `http(s)://` including `127.0.0.1`/`localhost` belongs to a *different* tab type (`ui-sidebar-browser`), which is **disabled by default in Web profiles and enabled on Desktop**. **[src] [doc]**
6. **Office is host-side LibreOffice → PDF**, requested on demand through `officeToPdf.render`; the spreadsheet path is the opposite — XLSX/XLS/CSV/TSV are parsed entirely in the browser in a disposable Web Worker (FortuneSheet + ExcelJS + SheetJS + PapaParse). **[src] [doc]**
7. **There is no OS Quick Look equivalent.** "Open" for a previewed file is a *native-app launch* (`open-in-app` host routes), not an in-app preview. The sanctioned extension point for a native previewer is `documentPreviews.register({ priority: 'extension' })` — exactly what this repo's `plugins/phone-native-preview` already does for `.doc/.docx/.ppt/.pptx`. **[src]**
8. **Everything is bounded, and every cap is host-side.** Text: 2 MiB/page, 5000 lines/page, 32 MiB complete file. HTML: 4 MiB/asset, 32 MiB total, 64 assets. Excel: 16 MiB, 250k cells, 15 s. Office: 50 MiB in / 100 MiB out, 60 s, 2 concurrent, 8 cached PDFs. PDF: 16,777,216 px per page raster, no zoom cap beyond 400 %. **[src]**
9. **Text is paged, not whole-file**, and Markdown/code render the *accumulated prefix* incrementally (`streaming` flag = `!eof`), so a 100 MB log never lands in memory. A newer file version arriving past page 1 restarts the walk instead of mixing versions. **[src] [doc]**
10. **Markdown local images do not use the resource protocol.** They are `<img src="/api/file?path=<absolute>">` against an authenticated host route that sends `Cache-Control: private, no-store` and `Content-Security-Policy: sandbox; default-src 'none'`. Relative paths are resolved against the *document's* host-reported absolute path, and only work when the page's base URI is `http(s)` (or desktop `dsh-app://app/`). **[src]**
11. **Per-tab view state outlives the body**: scroll offset, wrap, chosen renderer, zoom, page, and loaded pages live in stores keyed by tab id and are released when the tab record's abort signal fires. This is why switching tabs does not re-read or jump. **[src]**
12. **For iOS the cheapest faithful path is: keep the official client bundle, supply the four host seams, and register a native renderer at `extension` priority where the browser cannot do the job.** The expensive things to reproduce are `officeToPdf` (LibreOffice) and the `/api/file` route; the impossible things are the desktop `open-in-app` launches. **[infer]**

---

## 0. Surface map

| Package / file | Role |
| --- | --- |
| `packages/client/ui-sidebar-documentpreview/` | The whole preview feature: 1 tab type + 8 document renderers |
| `…/src/client/index.ts` | Tab-type registration, store/face wiring, renderer registration order (`:122-129`) |
| `…/src/client/definition.ts` | The `text` tab type: pattern, band, `canOpen`, title (`:48-56`) |
| `…/src/client/document/registry.ts` | Renderer registry + ranking (`:39-49`, `:120-122`) |
| `…/src/client/document/contract.ts` | `DocumentContent`, `DocumentBodyOwner`, four sidebar child slots |
| `…/src/client/TextPreview.tsx` | The tab body: candidate list, header, viewer menu, wrap, reload, load-more, failures |
| `…/src/client/store.ts` / `face.ts` | Per-tab store; async reads, generation/version reconciliation |
| `…/src/client/rpc.ts` | Address → `{sessionId, path}`; the two Remote call shapes |
| `…/src/client/html/*` | Static + interactive HTML, packing, bootstrap, CSP |
| `…/src/client/{markdown,code,text,image,pdf,office,excel,zoom}/` | The renderers |
| `packages/client/ui-sidebar-right/` | Tab/pane lifecycle, tab-type registry, navigation controller, persistence |
| `packages/client/resources/` | `dsh-resource://` protocol providers behind `useResource` |
| `packages/api/workspace-files/` | Host: `stat`, `read`, `readBytes`, `list`, `changes` + caps |
| `packages/api/session-controller/src/media-references.ts` | Host: authenticated `GET/HEAD /api/file` |
| `packages/document/office-to-pdf/` | Host: LibreOffice → PDF Remote (`render`, `generation`) |
| `packages/client/ui-sidebar-browser/` | Separate HTTP(S)/loopback tab type (Desktop by default) |
| `packages/client/ui-open-in-app/` + `packages/host/open-in-app/` | Native launch / reveal for the previewed file |
| `apps/web/tests/document-preview.e2e.ts` | End-to-end proof of HTML sandbox, no-network static mode, markdown images, PDF/Excel |

---

## 1. How the official UI decides which renderer for a file

### 1.1 Stage 1 — which **tab type** claims the address (address globs)

`ctx.sidebarRightTabs.register({ id, kind, patterns?, priority?, canOpen?, title })`.

- Patterns are globs over `dsh-resource://` addresses. A pattern containing `:` matches the whole address; one without matches the URI path at any depth. Ranking: band (`extension`=3, `builtin`=2, `fallback`=1) → **matched pattern length** → registration order; `canOpen` can veto. Default band when unnamed is `extension`. (`packages/client/ui-sidebar-right/src/client/tab-registry.ts:52-59`, `:337-366`)
- The document preview registers exactly one tab type:
  - pattern `dsh-resource://file/[\s\S]+`
  - band `fallback` ("plain viewers anything more specific should beat")
  - `canOpen: address => parseFileAddress(address)?.scope === 'session'` — **absolute-scope addresses and every non-`dsh-resource` address are refused**
  - title = decoded basename; the *whole address* is the content identity, so same-named files in different directories are different tabs
  (`…/documentpreview/src/client/definition.ts:48-56`)

Consequence: `ui-sidebar-documentpreview` is a **universal fallback file viewer**. A third-party type declaring `*.png` at `extension` takes images away from it; nothing else in the product competes for file addresses.

### 1.2 Stage 2 — which **renderer** inside the tab (filename suffix)

`ctx.documentPreviews.register({ id, extensions, binaryExtensions?, priority, title, loading, wrap? })` plus a body registered in the keyed slot `sidebar.right.tab.document` under the same `id`.

Ranking (`…/src/client/document/registry.ts:39-49`):

```
rank   = priority === 'builtin' ? 0 : 1      // 'extension' wins, and is the default
length = longest declared suffix that ends the filename
sort   = rank DESC, length DESC, registration order ASC
```

Suffix matching (`…/document/suffix.ts`): lowercase, leading dot stripped, backslashes accepted as separators, compound suffixes (`tar.gz`) allowed, matched against the **decoded final path segment**.

Builtin registrations, in registration order (`…/src/client/index.ts:122-129`):

| # | Renderer id suffix | Extensions | Band | Loading | Wrap |
| --- | --- | --- | --- | --- | --- |
| 1 | `/text` | *(none — appended manually as fallback)* | builtin | `text-pages` | yes |
| 2 | `/markdown` | `md`, `markdown` | builtin | `text-pages` | no |
| 3 | `/html` | `html`, `htm` | builtin | `bytes-complete` | no |
| 4 | `/image` | `png jpg jpeg gif webp bmp ico svg` (binary: all but `svg`) | builtin | `bytes-complete` | no |
| 5 | `/pdf` | `pdf` (binary) | builtin | `bytes-complete` | no |
| 6 | `/office` | `doc docx ppt pptx` (all binary) | builtin | `renderer` | no |
| 7 | `/excel` | `xlsx xls csv tsv` (binary: `xlsx xls`) | builtin | `bytes-complete` | no |
| 8 | `/code` | `CODE_HIGHLIGHT_EXTENSIONS` (~80 source/config suffixes incl. `md`, `csv`, `html`, `svg`) | builtin | `text-pages` | yes |

### 1.3 The final candidate list (the actual algorithm)

`TextPreview.tsx:68-76`:

```ts
const matched = matchingDocumentPreviews(definitions, file.path)
if (matched.length > 0 && binaryDocumentPath(definitions, file.path)) return matched   // binary veto
if (matched.length === 0 && unviewable) return matched                                 // unsupported state
const fallback = definitions.find(d => d.id === PLAIN_BODY_ID)
return fallback === undefined ? matched : [...matched, fallback]                       // plain-text tail
```

Three rules fall out:

1. **Binary veto.** If any registered renderer declares the file's suffix in its `binaryExtensions`, plain text is *not* offered. `.pdf`, `.docx`, `.xlsx`, `.png` get no "Plain text" entry; `.svg`, `.csv`, `.tsv` do, because their bytes are legitimately text.
2. **Unviewable list.** A hard-coded list of known-binary suffixes with no renderer (video, audio, archives, `doc…`, `pages`/`numbers`, executables, fonts, disk images, `psd/ai/sketch/tiff/heic/avif`) produces the *unsupported empty state* and **never issues a read** (`…/document/unviewable.ts:10-37`; `TextPreview.tsx:196-215`). `key` is deliberately excluded so credential files stay readable as text.
3. **Registration order is the tiebreak**, which is why `.md` defaults to Markdown (registered before Code), `.csv` defaults to Spreadsheet (before Code), and `.html` defaults to HTML (before Code) while all three still offer the alternates.

The per-tab `viewerId` (dropdown choice) is remembered in the tab store and *preserved while it remains available*; otherwise the first candidate wins (`TextPreview.tsx:76`).

### 1.4 Renderer selection state machine

- `state.mode` + `state.contentRendererId` identify the delivery shape (`text-pages`, `bytes-complete`, `renderer`). A change of shape or of renderer aborts in-flight reads, bumps `loadRevision`, and resets pages (`face.ts:100-140`).
- `loading` (mode) is *declared by the renderer*, not chosen by the owner — a renderer with `loading: 'renderer'` receives `content = { kind: 'renderer', revision, loaded, failed, reload }` and owns its own I/O (used only by Office).
- The dropdown renders only when `candidates.length > 1`; a single-renderer file (PDF, XLSX, DOCX) shows no viewer control (`TextPreview.tsx:267-286`; `[e2e]` asserts `viewer.count() === 0` for PDF).

### 1.5 Fallbacks when the chosen renderer cannot load

| Situation | Behaviour |
| --- | --- |
| Renderer chunk missing / body not registered | owner-rendered line `The {name} preview is unavailable.` (`TextPreview.tsx` `fallback`) |
| Host read fails before any content | empty state with file-type icon + mapped message + recourse (`open` / `retry` / `none`) |
| Host read fails after content | content stays, a retry line appears below it |
| Known-binary suffix with no renderer | unsupported empty state, **no read at all** |
| Unknown suffix | plain text (still subject to UTF-8/NUL checks) |
| Office host service absent | localized "unavailable" guidance inside the Office body (registration still exists) |

---

## 2. Exact HTML preview model

### 2.1 The switch

```ts
// …/src/client/html/index.ts:35
hooks: { interactivePreview: ctx.configForms.developerTools.enabled }
```

- `developerTools.enabled` is the **Coding Tools** switch (`ui-settings.enabled`), rendered in Settings as **"Show coding view"**; default `true`; host-persisted; on host-backed clients it stays **false until the first accepted schema value arrives** (`packages/client/ui-settings/README.md:32`). **[doc]**
- The e2e toggles it live and the iframe swaps between the two models **without reopening the file** (`apps/web/tests/document-preview.e2e.ts:838-899`). **[e2e]**
- A mode change unmounts the previous browsing context, aborts pending dependency reads, and (static → interactive) re-packs; (interactive → static) also releases CSS/JS resource subscriptions and keeps only the root file watched (`HtmlBody.tsx:79-88`).

### 2.2 Static mode (`developerTools` off) — a hostile document is inert

`…/src/client/html/basic-document.ts:8-20`:

```ts
DOMPurify.sanitize(text, {
  WHOLE_DOCUMENT: true,
  FORBID_TAGS: ['noscript','base','link','meta','iframe','frame','object','embed',
                'set','animate','animateMotion','animateTransform'],
  FORBID_ATTR: ['href','xlink:href'],
})
// then prepend, as the FIRST head child:
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none';
  style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:;
  connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
```

Rendered as `<iframe srcDoc={html} sandbox="" … data-html-preview>` (`HtmlBody.tsx:102`).

- `sandbox=""` = **every** sandbox flag withheld: no scripts, no same-origin, no forms, no popups, no top navigation, no downloads, no modals.
- CSP is a **meta tag** (not a response header) and is inserted before any document content, so it governs the whole parse; `script-src 'none'`, `connect-src 'none'`, `img-src data:` mean **no network of any kind** and no `blob:` images.
- Inline `style` and `style` elements survive (test asserts `body { margin: 0 }`), `class="dark"` survives, data-URI images survive.
- Related files are **not read**: `setResources([])` on the static branch, and `packHtml` is never called.
- Removal is complete: `<a href>`, `<svg><a xlink:href>`, MathML `href`, `<meta refresh>` (inside `noscript`, itself removed), declarative shadow roots, `<template>`-wrapped frames, `<set>/<animate attributeName="href">` — all gone or inert. E2E clicks every remaining link and asserts `blockedRequests == []` and `[href], [xlink\:href]` count 0. **[e2e]** `apps/web/tests/document-preview.e2e.ts:826-846`

Product cost: static mode loses Tailwind/CDN CSS, web fonts, external images, JS charts, and any framework page. This is a *policy* choice, not a bug.

### 2.3 Interactive mode — scripted blob document, still opaque

Pipeline (`HtmlBody.tsx:35-73`, `bootstrap.ts:24-47`, `pack.ts`, `read-relative.ts`):

1. Host returns **complete bytes** for the `.html` file (`bytes-complete` mode, 32 MiB cap).
2. `packHtml` parses the source in a **detached `<template>`** (never mounted in the app DOM) and collects only *directly declared* dependencies:
   - `<script src>` whose `type` is empty, `text/javascript`, or `application/javascript` **and** whose path ends `.js`
   - `<link rel~="stylesheet" href>` whose path ends `.css`
   - references must be relative (no scheme, no leading `/`, `#`, `?`, no backslash, no NUL); query/fragment stripped; decoded once
3. Each dependency is read **through the Host** with `readBytes(sessionId, relativePath, { baseFile: <the HTML file's path> })` — so `../outside/outside.js` works and may live **outside the workspace** (`html/index.ts:36-39`, `[e2e]` `OUTSIDE_JS_OK` at `document-preview.e2e.ts:879`).
4. The bundle (HTML text + assets) is base64-embedded in a one-line bootstrap script; the page creates a `Blob([html], {type:'text/html'})` and sets the iframe `src` to that **blob URL**.
5. Inside the frame the bootstrap decodes the payload, and for each asset calls `URL.createObjectURL(new Blob([...]))` **inside the sandbox** — deliberately, because an opaque-origin frame cannot load blob URLs minted by the parent — rewrites the matching `src`/`href`, then `document.open(); document.write(html); document.close()`.

Final element (`HtmlBody.tsx:68`):

```html
<iframe name="dsh-sidebar-html-<tabId>" src="blob:…" sandbox="allow-scripts"
        data-html-preview title="HTML document preview" class="frame" />
```

- `sandbox="allow-scripts"` **without `allow-same-origin`** ⇒ the document runs in a unique opaque origin. E2E proof: `parent.document…` throws `SecurityError` (`#parent-result = "parent-blocked"`), and the app document is unchanged (`document-preview.e2e.ts:661-675`, `:881-883`). **[e2e]**
- No `allow-forms`, `allow-popups`, `allow-modals`, `allow-top-navigation`, `allow-downloads`, `allow-pointer-lock`.
- There is **no postMessage bridge and no host callback inside the frame**; the injected `readRelated` never crosses the boundary. Relative resources are therefore resolved exactly once, at pack time, by the Client.
- The frame fills the pane edge-to-edge, `min-height: 240px`, `background: var(--dsw-alias-bg-base)`, `border: none` (`HtmlBody.module.css`).
- The frame `name` exists only for desktop shortcut routing; it grants nothing.

### 2.4 What can run inside the interactive frame

| Capability | Verdict | Evidence |
| --- | --- | --- |
| Inline `<script>` | **Yes** — sets `#result = INLINE_OK` | `[e2e]` `document-preview.e2e.ts:870` |
| Local classic `<script src="./local.js">` | **Yes**, via host-read + in-frame blob | `[e2e]` `LOCAL_JS_OK` `:878` |
| Local stylesheet `<link rel=stylesheet>` | **Yes** | `[e2e]` colour assertion `:880` |
| Dependency outside the workspace (`../…`) | **Yes** (host resolves with `baseFile`) | `[e2e]` `OUTSIDE_JS_OK` `:879` |
| Remote subresource (`<img src="https://…">`) | **Yes — real network request** | `[e2e]` `previewNetworkRequests === 1` `:884` |
| `fetch`/XHR to remote | Allowed by the frame policy (no CSP), subject to CORS because the origin is opaque | **[infer]** |
| Cookies / localStorage / IndexedDB | Blocked: opaque origin is a unique, non-persistent origin | **[infer]** |
| Read parent DOM/cookies | **No** (`SecurityError`) | `[e2e]` `:881` |
| Submit a form | **No** (`allow-forms` absent) | **[infer]** |
| `window.open` | **No** (`allow-popups` absent) | **[infer]** |
| Navigate itself (click a normal link) | Allowed by default sandbox semantics — the frame navigates *inside* itself | **[infer]** |
| Navigate the top-level app | **No** (`allow-top-navigation` absent) | **[infer]** |
| Local module `<script type="module">` | **Not packed**; left to browser rules against a `blob:` base ⇒ effectively fails | `[src]` `pack.ts:51`, `[doc]` |
| CSS `url()`/`@import` inside packed CSS | **Not traversed** | `[doc]`, `[src]` |
| Dynamic URL construction (`fetch('./x.json')`) | **No host bridge**; resolves against the blob base ⇒ fails | `[doc]` "no runtime file-read bridge" |
| `<base href>` present | Packing is **skipped entirely** and the browser resolves everything (network/relative to that base) | `[src]` `pack.ts:43` |

**CSP:** the interactive frame carries **no CSP**. The bootstrap sets none, `index.html` adds none to the frame, and the DSH web host ships no page CSP (`packages/host/webserver/src/index.ts` adds none). Note for any host that *does* set a page CSP: `blob:` documents inherit the creator's CSP per the HTML standard's local-scheme rule, so a strict app CSP would silently break interactive preview. **[infer]**

**Limits** (`pack.ts:14-16`, `:56-70`):

| Limit | Value | On breach |
| --- | --- | --- |
| Per asset | 4 MiB | throw → preview failure |
| Total package (root + assets) | 32 MiB | throw |
| Distinct assets | 64 | throw |
| Invalid UTF-8 in root or any asset | — | throw |
| Any dependency read failure | — | throw (never a partial package) |

Failure surfaces as a single localized line, `This HTML document could not be previewed.`, in `role="alert"` — no partial document, no half-applied assets.

### 2.5 Lifecycle and refresh

- The `src` blob URL is created per content revision and **revoked on unmount / replacement** (`HtmlBody.tsx:44-63`).
- Each packed dependency's host-reported `absolutePath` (or, on failure, `error.details.path`) is added to the tab's `ResourceGroup`, so editing `local.css` or `local.js` on disk triggers **auto-refresh → repack → new blob URL → new browsing context** (`[e2e]` asserts changed `src` and refreshed colour/text at `:885-892`).
- Auto-refresh defaults on; its toggle is deliberately **hidden** (state/labels/styles retained) in both the preview header and the file tree (`TextPreview.tsx:302-309`).
- Static mode subscribes to **no** dependencies; only the root file is watched.
- Known limit: HTML iframe scroll position is not restored (its browsing context is opaque); no zoom controls for HTML.

---

## 3. Localhost / `127.0.0.1` services vs workspace files

### 3.1 The document preview cannot open a URL

- Its type pattern is `dsh-resource://file/[\s\S]+` and `canOpen` requires `parseFileAddress(address)?.scope === 'session'` (`definition.ts:50-52`).
- `hostFileOf()` **throws** for anything else: `not a session file address` (`rpc.ts:63-67`).
- `openResource` itself refuses non-`dsh-resource://` addresses (throws — "a wiring mistake" per `ui-sidebar-right/README.md`).
- No renderer ever builds an `http(s)` URL for *the file*; the only `http(s)` in the preview is (a) authored Markdown image URLs, (b) authored HTML subresources inside the interactive frame, (c) `/api/file` for local images.

**Verdict: workspace (and, with `baseFile`/absolute paths, arbitrary filesystem paths the Session's `ctx.fs` can read) — never URLs.**

### 3.2 Loopback *is* supported — by the separate Browser tab type

`packages/client/ui-sidebar-browser`:

- `parseBrowserAddress` accepts `http:`/`https:` only, **including loopback**; a scheme-less host becomes `https://`; it rejects `file:`, `data:`, `blob:`, script input, embedded credentials, and **the DSH application origin itself** (`src/client/browser/url.ts:18-46`).
- Default iframe policy: `sandbox="allow-scripts allow-forms allow-same-origin allow-popups allow-popups-to-escape-sandbox"`, `referrerPolicy="no-referrer"`, and a per-tab, **non-persisted** "remove sandbox" escape hatch (`src/client/view/IframePresentation.ts:7`, `:78-82`).
- Mounting: `packages/bundle/web-app/cordis.patch.yml:296-298` disables it unless `profileContext.name === 'desktop'`. **[src]**
- Chat HTTP(S) links open here when the link preference is "In-App Sidebar" (default); otherwise the system browser (`packages/client/ui-chat/README.md:48`). **[doc]**

**Verdict: loopback services are a first-class official target, but through the Browser tab, not through Document Preview — and only when the profile enables that row (Desktop by default).**

### 3.3 Incidental egress from the interactive HTML frame

Because interactive HTML has no CSP and no network policy of its own, a workspace `.html` file can reach any origin the browser allows (`<img>`, `<script>`, `<link>`, `fetch`, `EventSource`, `WebSocket`) — including `http://127.0.0.1:*`. There is **no allowlist, no proxy, no private-network guard, no loopback special-casing** anywhere in the preview. The e2e *proves* a remote image loads (`:884`) but does **not** test loopback from HTML. **[src] + [e2e] partial**

If the product wants loopback-in-HTML-preview, it already exists as a side effect; if it wants to forbid it, that must be added (CSP `connect-src`/`img-src`, or a `sandbox` that omits scripts).

---

## 4. Client-side vs host-side, and what an iOS host must reproduce

### 4.1 The split

| Concern | Where it lives | Notes |
| --- | --- | --- |
| Tab type / renderer registries, ranking | **Client** (cordis client plugins) | Pure browser code, extension point for other plugins |
| Tab/pane layout, fullscreen, persistence (`localStorage` `dsh.sidebar-right.v1.<sessionId>`) | **Client** | Layout is browser-local; not synced |
| Text decode, Markdown, syntax highlight (Shiki), code UI | **Client** | `ui-primitives` |
| HTML sanitize (DOMPurify), packing, bootstrap, blob iframes | **Client** | Depends on host `readBytes` with `baseFile` |
| PDF parsing/rendering, text layer, worker | **Client** | `pdfjs-dist` 6 + inlined worker + inlined cMaps/standard fonts/wasm |
| XLSX/XLS/CSV/TSV parsing | **Client** | ExcelJS 4.4 (patched), SheetJS 0.20.3, PapaParse, FortuneSheet 1.0.4, in a disposable Worker |
| YAML frontmatter (lazy chunk) | **Client** | `yaml` |
| Office → PDF | **Host** | LibreOffice via `@deepseek-ai/libreoffice-kit` (native engine or WASM) |
| File metadata, paged text, complete bytes, byte ranges, relative resolution, listing, change stream, **all caps** | **Host** | `workspaceFiles` service + `ctx.fs` authority |
| `GET/HEAD /api/file?path=` (absolute path, authenticated, no-store) | **Host** | Used only by Markdown local images |
| Native app open / reveal | **Host** | `open-in-app` routes; capability advertised as `session.canOpenWorkspacePath` |
| Plugin bundle serving, index injection | **Host** | `webserver/index-inject` supplies `__DSH_DOCUMENT_PREVIEW_CONFIG__` |

### 4.2 Host seams the preview calls (exact shapes)

```ts
// metadata (streamed; one provider per address, shared by every UI)
workspaceFiles.stat(sessionId, path, signal) -> { absolutePath, version, bytes? }

// text: one line page
workspaceFiles.read(sessionId, path, { offset /* 1-based line */, limit? }, signal)
  -> { absolutePath, version, bytes?, offset, text, lines, eof }

// bytes: complete file (no `range`) or a byte window, optionally relative to another file
workspaceFiles.readBytes(sessionId, path, { range?: { offset /* 0-based */, length? },
                                              baseFile?: string }, signal)
  -> { absolutePath, version, bytes?, offset, data: Uint8Array, eof }

// change stream (one per session+path, shared)
workspaceFiles.changes(sessionId, path, signal) -> stream<{ kind:'ready' } | { kind:'change', change }>

// optional, only for .doc/.docx/.ppt/.pptx
officeToPdf.render(sessionId, path, priority, signal) -> { data: Uint8Array, version, fonts, generation }
officeToPdf.generation(signal) -> number

// optional, Markdown local images
GET /api/file?path=<absolute>   (Cache-Control: private, no-store; CSP: sandbox; default-src 'none')
```

Failure codes the UI branches on (`packages/api/workspace-files/src/types.ts`, mapped in `failure-line.ts:22-38`):
`workspace-file/not-found`, `too-large` (with `limit`), `not-text`, `not-regular-file`, `unsupported-address`, `unknown-workspace`, `outside-workspace`, `not-directory`, `watch-unsupported`, plus `gateway/*` transport codes.

### 4.3 What an iOS native host must reproduce

**Minimum to make the official client bundle work unchanged:**

1. **A real `http(s)` origin serving the page** (this repo already uses one loopback origin). Required because `fileMediaUrl()` only builds URLs for `http(s)` or `dsh-app://app/` (`packages/util/workspace-path/src/index.ts:120-125`); on `file://` or a custom scheme Markdown local images silently degrade to alt text.
2. **`workspaceFiles.stat` + `read` + `readBytes`** with the wire shapes above, including:
   - 1-based line pages with `lines` and `eof` semantics (a page past EOF is `eof: true` with empty text; `lines: 0` differs from one empty line);
   - `version` on every page (the client uses it to avoid mixing file versions);
   - relative resolution through `baseFile` (the HTML packer depends on it, including `../` escapes);
   - a hard complete-file cap (`maxFileBytes`) that **fails** instead of truncating.
3. **A change stream** (or at least a stat that can be re-polled): auto-refresh, "file has changed" notices, Office cache freshness, and HTML dependency refresh all ride on it. Without `changes`, the provider falls back to a single `stat` and the preview becomes static-but-usable.
4. **`/api/file`** — otherwise every local Markdown image breaks. `path` is the *execution-world absolute path* (the Host's `absolutePath`), not a workspace-relative one.
5. **Office**: either mount a real `officeToPdf` host, or **do not** — and instead register a native renderer at `extension` priority (the pattern this repo's `plugins/phone-native-preview` uses). If neither, the shipped Office renderer shows its "conversion unavailable" guidance; it will not fake success.
6. **A browser engine that supports the CSS/JS the renderers use.** Used by the official code and therefore a deployment-target constraint:

   | Feature | Used by | WebKit availability |
   | --- | --- | --- |
   | `AbortSignal.any`, `Promise.withResolvers` | `face.ts`, `pdf/runtime.ts`, HTML packing | Safari 17.4+ |
   | CSS `@scope` | Excel stylesheet scoping (`excel/excel.tsx:17`) | Safari 17.4+ |
   | CSS `light-dark()` | zoom control shadow (`ZoomControls.module.css`) | Safari 17.5+ |
   | `:has()` | layout selectors (`TextPreview.module.css`, `PdfBody.module.css`) | Safari 15.4+ |
   | Web Worker + module worker + `?raw` inlined worker | PDF.js, Excel parser | supported |
   | `URL.createObjectURL` in an opaque-origin frame | HTML interactive bootstrap | supported |

   Below those versions the failure modes differ: `AbortSignal.any`/`Promise.withResolvers` throw at runtime (aborting every PDF, Office and HTML dependency read), while a missing `@scope` silently lets the whole FortuneSheet stylesheet leak out of the preview pane and a missing `light-dark()` drops the zoom pill's shadow. **[infer — version numbers are public WebKit release facts, not read from this repo]**

**Optional, for parity of UX:**

7. Native open/reveal (`session.canOpenWorkspacePath`, `openWorkspacePath`) → iOS equivalent is `UIDocumentInteractionController` / `QLPreviewController` / share sheet. Note the official *does not* embed a native preview here; it launches an external app.
8. A `QLPreviewController` renderer registered as `documentPreviews` `priority: 'extension'` for suffixes the browser cannot render (`.doc/.docx/.ppt/.pptx`, and optionally `.pages/.numbers/.key`, `.heic`, archives).
9. Host-side config injection (`__DSH_DOCUMENT_PREVIEW_CONFIG__`) if you want the `office`/`excel` limits to differ on device.

### 4.4 What is *not* required from the host

- No `dsh-resource://` handler / custom URL scheme: the address is an opaque identity string.
- No HTML rendering, PDF rendering, spreadsheet rendering, or syntax highlighting on the host.
- No Quick Look, no thumbnail service, no preview cache (Office PDF cache is per-connection, in memory, LRU).
- No network access for the preview itself — except what the user's own HTML/Markdown asks for.

---

## 5. Styling / UX conventions

### 5.1 Tab, pane, sidebar vs fullscreen

- One docking surface per Session; two presentations sharing one content tree (**no remount on switch**): `push` (panel takes width from the conversation, default) and `fullscreen` (covers the viewport).
- **Below 768 px the panel is automatically fullscreen**; leaving fullscreen on a narrow viewport closes it, and widening does not reopen a closed panel (`ui-sidebar-right/src/client/shell/SidebarRight.tsx:360-361`). For a phone this means the preview is effectively a full-screen sheet — confirmed by `ui-mobile`, which treats the rightbar as open when it owns a nonzero track *or* the fullscreen presentation.
- The panel has **no header row**: the tab strip is the top edge. Controls ride the kit's chrome seat at the far end of the top-right pane's strip (presentation switch, collapse). Tabs are capsules with close controls; a lone tab closes with the column.
- Preview bodies are **not** `keepMounted` (unlike terminal/browser tabs); their continuity comes from the tab store, not from retained DOM.
- Tab title = decoded basename, with the extension-specific `FileTypeIcon` injected before it by the keyed title seat.
- Tab titles are captured at open time; the whole address is the content identity, so two same-named files are two tabs.

### 5.2 The preview's own 38 px header (`TextPreview.module.css`)

```
[ PathLabel ………………………………………………………………… ] [ Viewer ▾ ] [ wrap ] [ renderer action ] [ reload ] [ plugin actions ]
```

- Exactly **38 px**, `padding: 0 6px 0 16px`, bottom rule `0.5px solid var(--dsw-alias-border-l3)` — deliberately aligned with the conversation header's rule so the two lines meet at the column edge.
- `PathLabel` shows the Host's absolute path when available, else the requested path; directories are subdued, the final segment is primary, clipping preserves the trailing characters with a left-edge fade, hover reveals the full value.
- **Viewer dropdown** only when >1 candidate; label = current renderer's localized title, truncated at 160 px with ellipsis; `Menu` is portal + dense, aligned end, marks the selected item.
- **Wrap** only when `definition.wrap === true`; glyph shows the mode the click *selects* (not the current one); `aria-pressed` + tooltip; per-tab preference starts on.
- **Auto-refresh** toggle exists but is `<span hidden>` — kept for state/labels/styles/tests only.
- **Reload** lives in this header (not the tab strip), with the effective shortcut in its tooltip and `aria-keyshortcuts`.
- Extension seats: `sidebar.right.tab.document.action` (keyed by renderer, before Reload — e.g. Office font warning) and `sidebar.right.tab.document.actions` (list, after Reload — e.g. "Open" split button from `ui-open-in-app`).
- Tool buttons: 28 px circle, 15 px glyph, transparent, hover `interactive-bg-hover`.

### 5.3 Loading

- First load / renderer preparation (incl. Office conversion): centered **28 px `StateDot`** with `role="status"`, `aria-label` = visible text **"Rendering document..."** / 文档渲染中..., reduced-motion aware (`LoadingIndicator.tsx`).
- Additional text pages: **14 px inline** spinner inside the "Load more" button, loaded content stays visible.
- PDF pages that are not yet rendered hold their place as a **3:4 skeleton block** (`bg-skeleton`), no spinner competing with the open wait.
- Excel/PDF lazy chunks suspend to the same centered indicator; the previous bitmap stays visible until the replacement is ready.

### 5.4 Errors and empty states

Code → copy → recourse (`failure-line.ts`):

| Code | Copy (en) | Empty-state action |
| --- | --- | --- |
| `not-found` | "File not found. It may have been moved or deleted." | none |
| `too-large` | "This page exceeds the {limit} limit and cannot be read." | **open** (native/plugin slot) |
| `not-text` | "Preview is not available for this file type yet." | **open** |
| `not-regular-file` | "Not a regular file, nothing to display." | none |
| anything else (carrier) | "Read failed: {message}" | **retry** |

- Empty state layout: 36 px desaturated (`opacity .6`, `grayscale(1)`) file-type icon, one line, one action, centered with a `12%` flex spacer below so the column sits slightly above center.
- With content already loaded, failures are **additive**: a status line + Retry under the content, never a blanking of what the reader was reading.
- A stale file shows a secondary bar: "The file has changed, showing the previous content." + **Reload**, and keeps the reader's position.
- Unsupported suffix: same empty state, wording "Preview is not available for this file type yet.", plus the `unpreviewable` seat (the "Open" button) — **no read is attempted**.

### 5.5 Typography

| Surface | Font / size |
| --- | --- |
| Plain text and code body | `var(--dsw-font-mono)` with `font: var(--dsw-font-markdown-code-block)` on the page; body 13 px (`--dsh-content-font-size-secondary`), `line-height: 1.6`, `white-space: pre` (wrap ⇒ `pre-wrap` + `break-word`) |
| Code block | same monospace; `pre { padding: 16px }`; background **transparent** (sits on the pane, not the chat card); 0 radius; banner is a sibling of the scrollport so the scrollbar starts below the copy control |
| Line numbers | on by default; excluded from copied text; code lines are `.line` rows inside `pre .line` |
| Markdown | prose font (`var(--dsw-font)`), `padding: 10px 12px`, whitespace normal, GFM + footnotes + KaTeX math (micromark/mdast + katex in `ui-primitives`) |
| Frontmatter box | bordered rounded card, `var(--dsw-font-markdown-small)`, `bg-layer-1`, key/value list; verbatim `<pre>` fallback while the YAML chunk loads or if it fails; empty block collapses |
| Header path | 12–13 px, secondary label; the path label is the only always-visible identity |

### 5.6 Document surfaces, dark/light

- PDF and converted Office: `var(--dsw-alias-bg-document-preview)` — cool light grey in light mode, matte black in dark — 12 px outer inset, 12 px page gaps, page shadow `var(--dsw-elevation-prominent)`.
- PDF text layer selection: translucent blue `var(--dsw-alias-bg-document-selection)` in both themes, text rendered transparent over the canvas; blank breaks unhighlighted.
- Image: 12 px inset, `border-radius: var(--dsw-radius-md)` on the bitmap, fit-width default without upscaling content smaller than the pane.
- PDF page content keeps the document's own colours in both themes; Excel keeps its controls on a light surface with dark text in both app themes (so the sheet never inverts with the app).
- All tokens are the shared `--dsw-*` alias set; no per-package palette.

### 5.7 Zoom (PDF + images only; HTML explicitly excluded)

- Default **Fit width**; tracks pane resizing. 100 % = 96 DPI page size (PDF) or intrinsic CSS px (image).
- Fixed choices **25 / 50 / 100 / 150 / 200 %**, incremental ±25 %, clamped **25 %–400 %**.
- Floating pill: centered bottom, `bottom: 14px`, `12px` text, 28 px buttons, `radius-lg`, elevated shadow, `light-dark()` shadow colours.
- Fine pointers: hidden until the pointer enters the **bottom 72 px**, hides **420 ms** after leaving; stays visible while hovered, focused, menu open, or gesturing. `@media (hover: none), (pointer: coarse)` ⇒ **always visible** (phones).
- Trackpad pinch mapped to the pointer-anchored path; settled value survives body remounts (zoom lives in the tab store) and dies with the tab.
- PDF re-renders nearby pages at `resolved scale × devicePixelRatio`, clamped by the 16,777,216-px page budget, previous bitmap kept until ready.

### 5.8 Accessibility conventions worth copying

- Every icon control: `aria-label`, tooltip with the same name, `aria-pressed` for toggles, `aria-keyshortcuts` for the reload binding.
- Loading: `role="status"`; failures: `role="alert"`; the Excel unsupported-feature notice: `role="note"`.
- PDF pages: `role="img"` with `aria-label="PDF page N"`; the text layer supplies real selection semantics.
- Zoom menu: labeled controls, percent value in tabular numerals.

---

## 6. Feature matrix (builtin renderers)

| Format | Renderer (band) | Delivery | Dependency | Default selection | Alternates | Caps / guards | Notable behaviour |
| --- | --- | --- | --- | --- | --- | --- | --- |
| any text-ish / unknown | Plain text (builtin) | `text-pages` | none (React `<pre>`) | yes when nothing else matches | — | 2 MiB/page, 5000 lines/page, UTF-8+NUL check | line anchors for `{line}` navigation, wrap on |
| `.md .markdown` | Markdown (builtin) | `text-pages` | micromark/mdast + GFM + math + katex + Shiki (code blocks) | **yes** (before Code) | Code, Plain text | same page caps | YAML frontmatter field box, streaming re-parse on page append, local images via `/api/file` |
| `.html .htm` | HTML (builtin) | `bytes-complete` | DOMPurify; no scripting deps | **yes** (before Code) | Code, Plain text | 32 MiB file; 4 MiB/asset, 32 MiB total, 64 assets | static vs interactive per Coding Tools |
| `.png .jpg .jpeg .gif .webp .bmp .ico` | Image (builtin) | `bytes-complete` | native `<img>` + blob URL | yes | none (binary) | 32 MiB file | fit width, zoom 25–400 %, animated GIF survives zoom |
| `.svg` | Image (builtin) | `bytes-complete` | native `<img>` | **yes** | Code, Plain text | 32 MiB | SVG never enters the app DOM/iframe ⇒ scripts cannot run |
| `.pdf` | PDF (builtin) | `bytes-complete` | `pdfjs-dist` 6.3.289, module Worker, inlined cMaps/standard fonts/wasm | yes | none (binary) | 32 MiB file; 16,777,216 px/page raster | canvas + selectable text layer, lazy pages, retry per page |
| `.doc .docx .ppt .pptx` | Office (builtin) | `renderer` (self-loading) | host `officeToPdf` (LibreOffice) + nested PDF body | yes | none (binary) | host: 50 MiB in / 100 MiB out, 60 s, 2 concurrent; client PDF cache: 8 entries / 64 MiB | missing-font warning → reload stays separate; failures localized by reason |
| `.xlsx .xls` | Excel (builtin) | `bytes-complete` | ExcelJS 4.4 (patched), SheetJS 0.20.3, FortuneSheet 1.0.4, disposable Worker | yes | none (binary) | 16 MiB, 250k cells, 15 s | read-only, saved values only, charts/images/conditional formatting noticed but not drawn |
| `.csv .tsv` | Excel (builtin) | `bytes-complete` | PapaParse + FortuneSheet | **yes** | CSV: Code + Plain text; TSV: Plain text | same | first row is data; literal strings (`00123`, `TRUE`, `=SUM`) preserved; malformed quoting fails loudly |
| everything else text | Code (builtin) | `text-pages` | Shiki 4 + `util-code-language` table | when no better match | Plain text | 2 MiB/page | language label + copy, line numbers not copied, wrap toggle |
| video/audio/archives/fonts/disk images/`psd`/`heic`/… | *(none)* | — | — | unsupported empty state | — | no read at all | "Open" action from the `unpreviewable` seat |

---

## 7. What iOS should copy

**Copy the model, not the DOM.**

1. **The two-level decision.** A tab/route layer that claims an address, and a renderer list that scores by suffix with `extension > builtin`, longest suffix, registration order, plus a binary veto and an "unviewable" list. This is a few hundred lines of pure logic (`document/registry.ts` + `suffix.ts` + `unviewable.ts`) and is worth porting verbatim in spirit — it is what makes `.md` beat code, `.csv` beat code, `.svg` stay text-readable, and `.mp4` show a clean empty state instead of 4 MB of garbage.
2. **The candidate list, not a single choice.** Show a viewer menu whenever >1 renderer matches and remember the choice per tab. Users genuinely need "Code" and "Plain text" on a `.md`.
3. **Three delivery shapes.** `text-pages` (accumulate, render prefix, load more / auto-load on scroll-to-end), `bytes-complete`, and `renderer` (the renderer owns I/O — this is the hook a native Quick Look renderer needs). Model them explicitly; don't force everything through "read whole file".
4. **Page semantics.** 1-based line offsets, `lines` count distinct from empty line, `eof`, `version` on every page, and the rule "a newer version arriving past page 1 restarts the walk". This is the anti-corruption core of the whole feature.
5. **Per-tab view state keyed by tab id, released on tab close.** Scroll offset, wrap, renderer choice, zoom, PDF page. It is why tab switching feels native; without it every remount re-reads and jumps to the top.
6. **The failure taxonomy with recourse.** `not-found` / `too-large` / `not-text` / `not-regular-file` / carrier, each with a distinct next step (none / open / retry). Not one generic "couldn't preview".
7. **Two-mode HTML policy with an explicit user gate.** Static-by-default is defensible and cheap; interactive behind a developer-tools switch is what the official does. If you copy it, copy the *security posture* too: opaque origin (no app-DOM access), no forms/popups/top-navigation, no parent bridge, assets injected inside the frame, and a hard budget. Decide deliberately whether you add the CSP the official omits.
8. **The HTML packing contract** if you want workspace HTML to work at all: read only directly declared relative classic `.js` and `rel=stylesheet` `.css`, resolve via the document's own directory, inject inside the sandbox, fail the whole preview on any read error, and skip packing entirely when `<base href>` is present.
9. **Bounded everything.** Per-page bytes, page lines, complete-file cap, per-asset bytes, asset count, cell count, parse timeout, page raster pixels. Every one of these exists because something once blew up.
10. **The visual conventions.** 38 px header with a path label + right-aligned controls; 28 px circular icon buttons; centered 28 px status dot with the words "Rendering document..."; 12 px document insets with page gaps and the `bg-document-preview` surface; fit-width-first zoom with a 25–400 % clamp; monospace 13/1.6 for code and text; prose font for Markdown; line numbers excluded from copy; a frontmatter card above Markdown.
11. **The extension band for native renderers.** Register the OS previewer at `priority: 'extension'` for exactly the suffixes the WebView cannot do — this is the officially supported way to add capability without forking the product (and the pattern `phone-native-preview` already uses).

## 8. What iOS cannot copy (and the closest substitute)

| Official capability | Why iOS can't copy it as-is | Closest substitute |
| --- | --- | --- |
| **Cordis client-plugin tree + React slot seats** | Cannot be reproduced *in Swift*: the extension model is DOM React components registered into keyed slots. The WebView-hosted page can still run them | Keep the official WebView page + its plugin bundle (as this repo does), and bridge document renderers over `WKScriptMessageHandler` (already the `phone-native-preview` pattern) |
| **`officeToPdf` (LibreOffice kit)** | Needs a Node host, native LibreOffice packages or WASM, temp files, and a converter pool; the official itself reports "unavailable" in WebWorker previews | `QLPreviewController` for `.doc/.docx/.ppt/.pptx` (native, no conversion, no fidelity guarantee), or a remote/server conversion — never a fake success |
| **`/api/file` authenticated route** | It is a host route on the DSH webserver (`ctx.connection.fetch.register`) with `ctx.fs` authority; a WKWebView page has no such route | Implement `GET /api/file?path=` on the app's loopback server (same headers: `private, no-store`, `sandbox; default-src 'none'`), or patch `fileMediaUrl` — not recommended |
| **Host `workspaceFiles` service over `ctx.fs`** | 2 MiB/5000-line pages, `baseFile` resolution, `maxFileBytes`, `fs.watch`-based change streams, symlink refusal, cold-session `stat` — all Node/`ctx.fs` behaviour | Re-implement in Swift over the app's VFS: paged UTF-8 decode with fatal errors, NUL rejection, LSTAT + symlink refusal, version tokens (content hash or mtime+size), and a change feed |
| **Native "Open / Show location"** (`open-in-app`) | `NSWorkspace`/`open -a`-style launch of arbitrary desktop apps with a probed application catalog | `UIDocumentInteractionController` / share sheet / `QLPreviewController`; treat "open" as "share/open in…" and hide the control when unavailable (official hides it when `session.canOpenWorkspacePath` is false) |
| **Desktop Browser tab for loopback** | The Browser type is Electron-`<webview>` on desktop; Web is iframe-only, and the row is disabled off-desktop | `WKWebView` (or `SFSafariViewController` for public sites) as the Browser surface — but note the official *rejects the DSH application origin* and requires a URL allowlist; keep that |
| **`localStorage` layout persistence** | Browser-local, one origin, shared across windows; not a document store | `UserDefaults`/file-backed layout per session id, with the same "validate before adopting, clear only that session's key on corruption" rule |
| **`pdfjs-dist` 6 in-page canvas + text layer** | Huge JS + module worker + inlined cMaps; workable in WKWebView but heavy on older devices | `PDFKit`/`PDFView` (native scrolling, selection, search) or Quick Look for PDF; keep PDF.js only if you need identical text-layer behaviour |
| **FortuneSheet canvas spreadsheet** | A DOM/canvas spreadsheet with its own gesture model, wrapped in a CSS-`@scope` sheet that needs Safari 17.4+ | Native grid for XLSX/CSV, or render sheets to HTML/PDF host-side; at minimum keep the "read-only, saved values, warn on formulas/drawings" contract |
| **Shiki syntax highlighting** | Ships grammar bundles plus the oniguruma wasm engine into the page | Native `NSTextView` + a lightweight highlighter, or highlight host-side; keep "line numbers excluded from copy" and the language label |
| **`blob:` iframe + `document.write` bootstrap** | Works in WKWebView, but the app's own CSP is inherited by blob documents; and `sandbox` semantics differ at the margins | `WKWebView.loadHTMLString(_, baseURL:)` into a `WKWebView` with `WKContentWorld` isolation, or a **separate** `WKWebView` per preview (never `evaluateJavaScript` into the app's page); treat the preview as untrusted content |
| **`<768 px` auto-fullscreen sidebar with the docking kit** | Docking/split/float is DOM geometry over `ui-dockkit` | Native navigation: a full-screen sheet per previewed file, a tab strip equivalent (or a document list), same header anatomy |

---

## 9. Answers in one screen

1. **Renderer choice:** two registries. Address glob (band → pattern length → order, `canOpen` veto) picks the tab type; filename suffix (band → suffix length → order) picks the renderer; binary suffixes suppress plain text; a hard-coded unviewable-binary list produces the unsupported state without reading; unknown text falls back to plain text; registration order is why Markdown/Spreadsheet/HTML beat Code by default.
2. **HTML model:** *static* = DOMPurify + `sandbox=""` + `default-src 'none'` CSP + `srcdoc`, zero scripts/network/forms/frames/links, no dependency reads. *Interactive* = host-pre-read relative classic `.js`/`.css` (4 MiB each, 32 MiB total, 64 assets) → base64 bootstrap → parent `blob:` iframe `sandbox="allow-scripts"` (no `allow-same-origin`) → assets re-blobbed **inside** the frame → `document.write`. JavaScript runs; the parent is unreachable; **no CSP is set, so network is allowed**; `<base href>` disables packing; modules/`url()`/`fetch` are not packed.
3. **Loopback:** the document preview is workspace/file-only (`dsh-resource://file/session/...`, `canOpen` rejects everything else; `hostFileOf` throws on `absolute`). Loopback services are supported by the **separate Browser tab**, HTTP(S)-only, credentials and the DSH origin rejected, **disabled by default in Web profiles and enabled on Desktop**. Interactive HTML can incidentally reach loopback because it has no network policy — but that is a side effect, not a feature.
4. **Client vs host:** client owns registries, tabs, all renderers, sanitization, packing, PDF.js, Excel parsing, styling. Host owns `stat`/`read`/`readBytes`(+`baseFile`)/`changes` and every cap, `/api/file`, `officeToPdf`, native open, and bundle serving. iOS must provide those four-to-six seams; it can keep the official page and add native renderers at `extension` priority for what WebKit cannot do.
5. **UX:** 38 px path/control header under the tab strip; viewer dropdown only when >1; wrap only when declared; reload in the header; hidden auto-refresh; centered 28 px status dot "Rendering document..."; 12 px insets and page gaps on a `bg-document-preview` surface; fit-width-first 25–400 % zoom pill that is always visible on touch; monospace 13/1.6 for code/text, prose for Markdown, line numbers not copied; failures are additive with a named recourse.

---

## Appendix A — code reference index

| Topic | Reference |
| --- | --- |
| Tab-type bands & ranking | `packages/client/ui-sidebar-right/src/client/tab-registry.ts:52-59`, `:337-366` |
| Tab-type registration API | `packages/client/ui-sidebar-right/src/client/contract/slots.ts:120-200` |
| Fullscreen below 768 px | `packages/client/ui-sidebar-right/src/client/shell/SidebarRight.tsx:360-361` |
| Text tab type (pattern/band/canOpen) | `packages/client/ui-sidebar-documentpreview/src/client/definition.ts:48-56` |
| Renderer registry & sort | `…/src/client/document/registry.ts:39-49`, `:120-122` |
| Suffix matching | `…/src/client/document/suffix.ts:8-31` |
| Unviewable binary list | `…/src/client/document/unviewable.ts:10-37` |
| Candidate assembly / binary veto | `…/src/client/TextPreview.tsx:68-76` |
| Renderer registration order | `…/src/client/index.ts:122-129` |
| HTML mode gate | `…/src/client/html/index.ts:35` |
| HTML interactive iframe | `…/src/client/html/HtmlBody.tsx:35-73` (`:68` sandbox) |
| HTML static iframe | `…/src/client/html/HtmlBody.tsx:92-102` |
| Static sanitize + CSP | `…/src/client/html/basic-document.ts:8-20` |
| HTML packing rules & caps | `…/src/client/html/pack.ts:14-16`, `:39-70` |
| Relative dependency reads | `…/src/client/html/read-relative.ts:25-51` |
| In-frame bootstrap / `document.write` | `…/src/client/html/bootstrap.ts:24-47` |
| Workspace read shapes | `…/src/client/rpc.ts:20-93` |
| Store (per-tab state) | `…/src/client/store.ts:26-76`, `:150-260` |
| Async face (generation/version) | `…/src/client/face.ts:96-215` |
| Failure copy & recourse | `…/src/client/failure-line.ts:22-57` |
| Office registration (renderer mode) | `…/src/client/office/index.ts:33-44`, `:86-110` |
| Excel registration & limits | `…/src/client/excel/index.ts:17-23`; `…/src/config.ts:36-39` |
| PDF runtime (worker, assets) | `…/src/client/pdf/runtime.ts:22-70`; `…/src/client/pdf/assets.ts:1-40` |
| PDF page raster cap | `…/src/client/pdf/document.ts:48-58` |
| Zoom constants | `…/src/client/zoom/types.ts:10-19`; `…/src/client/zoom/ZoomViewport.tsx:9-10` |
| Markdown local images | `…/src/client/markdown/path-images.ts:9-30` |
| `fileMediaUrl` (http(s)/`dsh-app://` only) | `packages/util/workspace-path/src/index.ts:120-125` |
| Address grammar | `packages/util/workspace-path/src/file-address.ts:44-95` |
| File resource provider | `packages/api/workspace-files/src/client/provider.ts:38-110` |
| Host caps | `packages/api/workspace-files/src/index.ts:186-191` |
| `/api/file` route + headers | `packages/api/session-controller/src/media-references.ts:15-20`, `:66-75` |
| Office host config | `packages/document/office-to-pdf/README.md` |
| Browser tab parser & sandbox | `packages/client/ui-sidebar-browser/src/client/browser/url.ts:18-46`; `…/src/client/view/IframePresentation.ts:7`, `:75-82` |
| Browser disabled off-desktop | `packages/bundle/web-app/cordis.patch.yml:296-298` |
| E2E: static HTML inert | `apps/web/tests/document-preview.e2e.ts:826-846` |
| E2E: interactive iframe | `…/document-preview.e2e.ts:859-892` |
| E2E: markdown images via `/api/file` | `…/document-preview.e2e.ts:770-776` |

## Appendix B — localized strings (en / zh) used by the preview

| Key | en | zh |
| --- | --- | --- |
| loading | Rendering document... | 文档渲染中... |
| loadMore | Load more | 加载更多 |
| changed | The file has changed, showing the previous content. | 文件已更新，当前显示为旧内容 |
| reload / reloadNow | Read the file again / Reload | 重新读取文件 / 重新载入 |
| openWith | Open with | 打开方式 |
| viewer.text | Plain text | 纯文本 |
| wrap.aria | Line wrap | 自动换行 |
| unsupportedFile | Preview is not available for this file type yet. | 该格式文件暂时无法预览 |
| resourceUnavailable | The file resource service is unavailable. | 文件资源服务不可用 |
| rendererUnavailable | The {name} preview is unavailable. | 预览器 {name} 不可用 |
| error.tooLarge | This page exceeds the {limit} limit and cannot be read. | 单页内容超过 {limit} 上限，无法读取 |
| error.notFound | File not found. It may have been moved or deleted. | 文件不存在，可能已被移动或删除 |
| error.notRegularFile | Not a regular file, nothing to display. | 该路径不是普通文件，没有可显示的内容 |
| error.unavailable | Read failed: {message} | 读取失败：{message} |
| retry | Retry | 重试 |

## Appendix C — open questions / not verified

1. **CSP inheritance for the interactive blob iframe.** Per spec, `blob:` documents inherit the creator's CSP; DSH ships no page CSP, so the frame is unrestricted. A host that adds a CSP (e.g. an iOS loopback server hardening headers) will change preview behaviour — must be verified on-device.
2. **WKWebView `sandbox` fidelity.** Safari honours the `sandbox` attribute, but opaque-origin blob documents, `document.write`, and storage denials have historically differed from Chromium at the edges. Every claim in §2.4 marked **[infer]** should be re-tested in the target WKWebView before shipping.
3. **`@scope` / `light-dark()` on the minimum iOS target.** Excel styling depends on `@scope` (Safari 17.4+) and the zoom pill on `light-dark()` (17.5+). If the deployment target is lower, those two surfaces degrade (leaked CSS / no shadow).
4. **Memory of the all-at-once paths.** `bytes-complete` renderers hold the entire file (up to 32 MiB) plus decoded/parsed copies (PDF.js canvas, ExcelJS workbook, FortuneSheet model). The official bounds each piece but does not bound the sum; on a phone this is the first thing to measure.
5. **Loopback from interactive HTML** is untested in the official suite; it is allowed by construction (no CSP) but never asserted.
6. **`officeToPdf` on mobile.** Official cannot run it in the WebWorker preview at all, which is why the "unavailable" guidance exists — a useful precedent for iOS to *not* pretend.
