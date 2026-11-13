# PC-20261113-01 工具/相册图片进入模型上下文（P26）

<!-- SPDX-License-Identifier: MIT -->

Status: implemented on `feat/vision-model-attachments` (App + phone plugins only; no DSH source patch).
Base: `a2bb79dfe` (PR #159 merge).
Scope: **P26** additive Bot tool `attach_to_model` and its MCP image block.
**P19: none** — user attachments stay path/text-only; the App does not inject prompt image parts.
**P18: none** — no worker capability field is added; the model route is checked by the MCP client.

## 1. Direction

The Agent reads the photo library directly; it does not depend on the user attaching a
picture. Any image that goes to the LLM is an explicit `attach_to_model` call, and that
call is approval-gated exactly once. The approval card names the purpose and the local
file/asset, so “send to the model service” is visible before bytes leave the phone.

## 2. Tool

```json
{
  "name": "attach_to_model",
  "arguments": {
    "path": "/dsh/workspace/photo.jpg",
    "fileId": "art_...",
    "photoId": "PHAsset localIdentifier",
    "page": 2,
    "purpose": "看看这张照片"
  },
  "requires": "exactly one of path/fileId/photoId and purpose; page is an optional PDF page (1-8)"
}
```

Not in `p0Names`: the frozen P0 catalog and every non-vision deployment are unchanged.
The tool is appended to `allDefinitions` and `BotToolCatalog.isRegistered`.

### Sources

- `path`: Bot materialized workspace file (user attachment, document, scan artifact path).
- `fileId`: `OfficeArtifactStore` artifact (camera capture / scanned PDF).
- `photoId`: Photos `PHAsset.localIdentifier` from `photos.recent/search`; exported with
  `isNetworkAccessAllowed = false` so iCloud is never fetched implicitly.
- PDF: the chosen page is rasterized (PDFKit) to a 1568px JPEG; a scanned document has no
  reliable text layer, so a page image is more honest than OCR guesswork. The per-turn cap
  limits pages naturally.

### Result and model admission

The tool returns an MCP `content` array with a short text part and:

```json
{"type":"image","mimeType":"image/jpeg","data":"<canonical base64>","name":"photo.jpg"}
```

`dsh-mcp-client`:
1. checks canonical base64 and a raster media type;
2. calls `llm.resolveModelInfo(provider, model)` and requires `inputModalities` to include
   `image`;
3. admits the bytes through the durable attachment store and replaces the block with an
   `ImageBlock`.

A text-only route receives a diagnostic text instead of the image. No DSH patch is needed.

## 3. Approval

- Host classifier: `model.image.attach`, `external-send`, `ask`, `known: true`.
- Worker `approval-gate` classifies the same operation/resource so the card's
  `alwaysScope=until` matches the host and never returns `stale:always_scope`.
- One tool call = one approval; approving does not create a standing permission for later
  images unless the user chooses the card's existing scope.
- Task sessions are denied (`task_scope:model_image_denied`): a background task has no
  present user to approve model egress; the image stays in the workspace.
- Per-turn cap: 2 tool images (`modelImageCounts`, reset in `beginTurn`/`endTurn`).
- Image bounds: longest edge 1568 px, encoded ≤ 1 MiB, JPEG quality ladder; decode failure
  returns `image_unavailable`, never a fabricated image.

## 4. Fallbacks / compatibility

- No `BotModelImageReader` (tests/non-App hosts): `unsupported`.
- Missing workspace file / artifact / photo / PDF page: `image_unavailable`.
- Old App + new Worker: the tool is absent from the old catalog.
- New App + old Worker: the Worker catalog does not advertise the tool.
- A non-vision route: MCP client text diagnostic. The tool never claims the model can see.

## 5. Open follow-ups

- Dedicated OCR text for PDFs whose pages are mostly text; page rasterization is the current
  route and is deliberately bounded to one image per call.
- Optional `vision` advertisement in the App capability manifest (P18), if a deployment
  needs to show “can send images” before the first tool call. Not required for admission.
- Multi-page batch helper: the model may call the tool twice per turn, but a single call is
  one page to keep the approval and context budget explicit.

## 6. Tests

See `docs/receipts/2026-11-13-vision-attachments.md`.
