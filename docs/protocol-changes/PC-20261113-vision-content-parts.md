# PC-20261113-01 图片进入模型上下文（P19 / P26）

<!-- SPDX-License-Identifier: MIT -->

Status: implemented on `feat/vision-model-attachments` (App + phone plugins only; no DSH source patch).
Base: `a2bb79dfe` (PR #159 merge).
Scope: **P19** `session/prompt.content` image parts; **P26** additive Bot tool `attach_to_model`.
**P18: none** — this slice does not add a `capabilities.json` field; see §5.

## 1. Why

`BotAttachmentPrompt` only produced a JSON line per attachment (`name/path/size/mimeType/kind`). The model could not see image pixels even when the selected route declared vision. `camera.capture`, `photos.*` and `camera.scan_document` returned artifacts with `fileId`/metadata only; a tool result that carries the image was missing.

## 2. P19: prompt image part

`BotDSHRemoteRuntime.sendUserMessage` now prepares at most **two** image attachments through an injected `attachmentImagePreparer` and appends image parts to the existing `session/prompt` content array:

```json
{"type":"image","mediaType":"image/jpeg","data":"<canonical base64>","name":"photo.jpg"}
```

- No new RPC method or envelope field; `SessionPromptRequest.content` is already `PromptContentPart[]`.
- The text attachment block is kept, so non-image files and a failed preparation still have their path.
- Image preparation: ImageIO decode + orientation + thumbnail with longest edge **1568 px**, JPEG quality ladder, encoded cap **1,048,576 bytes**. A failure drops the image part (never fails the whole send).
- The App asks the user before a pending image is sent: 「仅这一次 / 本会话都允许 / 取消」. The picker alone is not treated as consent for model egress. A session-scoped choice is kept in the composer's view state only.
- The transport does not inspect the model route. If the route cannot consume images, the request fails at the model boundary; the text block remains. The tool path (§3) fails closed earlier.

## 3. P26: `attach_to_model`

Additive Bot tool (not in `p0Names`, so the frozen P0 catalog is unchanged):

```json
{
  "name": "attach_to_model",
  "arguments": {"path": "/dsh/workspace/photo.jpg", "fileId": "art_...", "purpose": "看看这张照片"},
  "requires": "exactly one of path/fileId and purpose"
}
```

- Implemented in `BotMCPRuntime.dispatch`; the App injects `BotModelImageReader` (`BotWorkspaceModelImage.image(for:)`). A `path` resolves through the materialized workspace; a `fileId` resolves through `OfficeArtifactStore` (camera/photo artifacts).
- Success returns an MCP `content` array with a text part and an `image` block (`mimeType/data/name`). The DSH MCP client (`dsh-mcp-client`) decodes canonical base64, asks `llm.resolveModelInfo` for `inputModalities` including `image`, and admits it through the durable attachment store. A text-only route becomes a text diagnostic, not a silent image.
- `BotToolEffectClassifier` classifies it as `model.image.attach`, `external-send`, `ask`; the Worker `approval-gate` classifies the same operation/resource so the card's `alwaysScope` matches the host. The tool is denied in Task sessions (`task_scope:model_image_denied`) because no present user can approve model egress.
- Per-turn cap is **2** tool images (`modelImageCounts`, reset in `beginTurn`/`endTurn`). Together with the prompt cap, a turn cannot silently send more than two user attachments plus two tool images; the approval card is per call.

## 4. Fallbacks / compatibility

- No `modelImageReader` (tests, non-App hosts, older App) → `unsupported`; no catalog claim of pixels.
- Missing materialized workspace file / undecodable bytes → `image_unavailable`; the model still has the path and file tools.
- No vision route → MCP client replaces the image block with a text diagnostic; prompt images fail at the adapter. Neither path fabricates pixels.
- Old App + new Worker: `attach_to_model` is simply absent from the old catalog; prompt image parts are not sent. New App + old Worker: `session/prompt` rejects image parts before any turn; the App's UI consent does not bypass the host schema.

## 5. Open follow-ups

- `P18`: if a deployment needs to advertise “can send images” before the first tool call, add a `vision` object to the App capability manifest. This slice deliberately does not invent a worker capability; the authoritative check is the model route's `inputModalities` in `dsh-mcp-client`.
- `camera.scan_document` PDFs: `attach_to_model` currently decodes raster images only. PDF OCR (Vision text) is a follow-up; the tool returns `image_unavailable` for a PDF rather than claiming OCR.
- `photos.recent/search` metadata may not expose a `fileId`; a photo export path is a follow-up.

## 6. Tests

See `docs/receipts/2026-11-13-vision-attachments.md`.
