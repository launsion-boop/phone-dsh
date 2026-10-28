# @phone-dsh/dsh-phone-native-preview

> **Integration status (this snapshot).** The package is a workspace and the
> worker profile mounts its Loader row. `WebHostModel` installs
> `WebEngineNativePreview` on the current WKWebView before the page loads and
> removes it with the engine; `./client` is packed as a DSH page asset.

Office documents in the **real full DSH Web right sidebar** open in the iOS
system Quick Look controller instead of the Worker's unavailable LibreOffice
conversion. Images, PDF, spreadsheets, HTML and text keep their existing DSH
renderers; `.doc`, `.docx`, `.ppt` and `.pptx` are the only suffixes this plugin
claims.

The package has two halves:

| Export | Role |
|---|---|
| `.` | Host half: empty `apply()` so the package has a Loader row. |
| `./client` | Browser half: registers one `documentPreviews` definition and one `sidebar.right.tab.document` body. |

The client half is a no-op when `window.webkit.messageHandlers.pdshNativePreview`
is absent. In that case DSH's own Office renderer stays selected and reports its
real conversion/provider failure; this plugin never fakes success.

## Browser contract

- Uses DSH's `@deepseek-ai/dsh-util-workspace-path` `parseFileAddress` to turn a
  `dsh-resource://file/session/<id>/<path>` tab address into the Session and
  path. `absolute` addresses and non-Office suffixes are not claimed.
- Registers in `ctx.documentPreviews` with
  `priority: 'extension'`, `loading: 'renderer'`, `binaryExtensions` equal to
  the four Office suffixes, and a keyed body in
  `sidebar.right.tab.document`.
- Posts exactly `{v: 1, id, sessionId, path}` to
  `window.webkit.messageHandlers.pdshNativePreview.postMessage` and resolves
  the request through `window.__PDSH_NATIVE_PREVIEW_RESULT__`.
- Reuses the page's single React instance and the DSH primitives bundle. It does
  not import another React, does not fork the DSH document renderer, never calls
  `remote.officeToPdf`, and never reads or copies the document bytes.
- Shows the native result code/message when Quick Look refuses or fails.

## Native contract

`Sources/PhoneDSHEngine/WebEngineNativePreview.swift` installs the matching
`pdshNativePreview` handler. The final host assembly supplies:

```swift
let transport = try await host.makeTransport()
let preview = WebEngineNativePreview(
    resolver: WebEngineNativePreviewResolver(
        currentSessionID: { await sessionAuthority.currentSessionID() },
        workspacePath: { sessionID, path in
            let result = try await transport.call("workspaceFiles/stat", args: .object([
                "workspaceFileScopeId": .string(sessionID),
                "path": .string(path),
            ]))
            guard let absolute = result["absolutePath"]?.stringValue else {
                throw PhoneDSHError.invalidResponse("workspaceFiles/stat returned no absolutePath")
            }
            return absolute
        }),
    workspaceDirectory: materializedWorkspaceDirectory)
preview.install(on: engine.view) // before the page loads
```

The resolver must return the Worker's `absolutePath`, not a host path. The
bridge accepts it only under `/dsh/workspace/`, maps the suffix into the
materialized `workspace/` directory, and re-checks the real path so a symlink
cannot escape. It presents `QLPreviewController` from the top view controller
and evaluates
`window.__PDSH_NATIVE_PREVIEW_RESULT__({id,ok,code,message})` with the outcome.
The file URL is handed to Quick Look directly: no `Data`, no temporary file, no
PDF.

## Integration points owned by the final assembly

This package is deliberately not wired into the shared build/profile yet:

1. Add `phone-native-preview` to the `plugins/package.json` workspaces and to
   the client build's TypeScript inputs.
2. The image packer currently stages every `./client` export as a Worker ESM
   face (`lib/client-module.js`). A `dsh.client` package needs its `./client`
   export bundled as a **browser page asset**: keep `react` and the
   `@deepseek-ai/dsh-client-ui-primitives` platform module external, and bundle
   browser-safe `@deepseek-ai/dsh-util-workspace-path` into the client chunk
   (it is not a client plugin row). That build change belongs to the final
   integration task.
3. Add one `dsh.client` Loader row named
   `@phone-dsh/dsh-phone-native-preview` (for example id
   `phone-native-preview`) after `ui-sidebar-documentpreview`.
4. Install `WebEngineNativePreview` on the engine's `WKWebView` before boot, as
   shown above, with the same current-session authority the page uses.

## Tests

```sh
node --test plugins/tests/phone-native-preview.test.ts
```

The suite covers the suffix whitelist, DSH address parsing, the exact message
shape, the no-bridge fallback and the registration metadata. It does not start
WebKit and does not read a document.

Native validation (Mac):

```sh
swift test --filter WebEngineNativePreviewTests
```
