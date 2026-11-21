<!-- SPDX-License-Identifier: MIT -->

# Bot card builder contract (Bot v1)

Status: normative for the seven P0 card tools (`ask_user`, `show_next_steps`, `show_attachment`,
`show_document`, `show_progress`, `show_checklist`, `show_link`). Contracts: P26 (BotToolSurface),
P27 (BotRows). Contract revision: `bot-mcp-d13-v1` (PC-20261113-bot-mcp-d13).

The card payload is produced by the App, never by the model. The model supplies labels, values,
styles and prose; the host assigns identity, order and the rendered kind. Schema:
[card-payload.schema.json](card-payload.schema.json). Frozen bytes:
[golden/card-payload.json](golden/card-payload.json) (upstream, must stay byte-identical) and
[golden/card-payload.phone.json](golden/card-payload.phone.json) (the phone delta and the negative
cases). P1 card tools (`show_table`, `show_callout`, `show_info`, `show_payload`, `show_library`)
are `target` and MUST NOT be registered in the first version; the builder rejects them.

## 1. Entry point and result

- `BotCardPayloads.build(tool:arguments:)` is the single builder. It requires `arguments` to be an
  object and returns `{"ok": true, "card": <card>}`. Any invalid input throws
  `BotCardPayloadError.invalid(<message>)`; the MCP layer turns that into the tool failure
  `invalid_arguments` and emits no `card.presented` event (`BotCardPayloads.swift:11-30`;
  `BotMCPRuntime.swift:1368-1396`).
- The `card` object always has a `cardType`. The builder adds no `id`, `tool` or `callId` to the
  tool result; those fields belong to the durable `card.presented` event (`tool-contracts.md` §2).
- Unknown tool names, P1 names and unknown card types fail closed with
  `unknown or non-P0 card tool: <tool>`; a missing required field fails with that field's message
  (§8). No half-built card is returned.
- `final` is input-only control metadata. It is validated only on the five content cards
  (`show_attachment`, `show_document`, `show_progress`, `show_checklist`, `show_link`); a
  non-boolean `final` on those tools throws `final 必须是 boolean。`, and the flag is stripped from
  the returned card. On `ask_user`/`show_next_steps` the member is ignored
  (`BotCardPayloads.swift:32-42`; `tool-contracts.md` §2).

## 2. Choice normalization (`ask_user`, `show_next_steps`)

The same algorithm applies to `options` and to object `steps`:

1. The container MUST be an array. `ask_user` requires a non-empty string `question`; `helpText` is
   an optional string. `show_next_steps` requires `steps`.
2. The raw array MUST contain 2–4 entries. The count is checked **before** any synthetic “other”
   is dropped; a raw array of one entry, or five entries, fails with the count message in §8.
3. Each entry is normalized:
   - A `show_next_steps` entry may be a string. It is trimmed; an empty result fails with
     `steps[<i>] 不能为空。`; the normalized entry is `{"label": <trimmed>}`.
   - Otherwise the entry MUST be an object with a non-empty string `label` (trimmed). A non-object
     fails with `<path> 必须是对象。`; a missing/empty/non-string label fails with
     `label 不能为空。` or `label 必须是字符串。`.
   - Optional `value` and `description` MUST be strings when present; they are trimmed and an empty
     result is omitted.
   - Optional `style` MUST be a string. It is lowercased; one of `primary`, `default`, `danger` is
     kept, every other value becomes `default`. A non-string `style` fails with
     `<path>.style 不合法。`.
   - `recommended` is kept only when it is the JSON boolean `true`; `false` and other types are
     omitted.
4. A choice whose trimmed, lowercased label is exactly `其他`, `其它` or `other` is a synthetic
   “other” and is removed. After removal the array MUST still contain 2–4 entries; otherwise the
   “effective” count message in §8 is used. The host never renders a model-supplied “other”.
4a. Phone next-step refinement (2026-11-14): **only `show_next_steps`**, after the same
trim/lowercase normalization, also drops these exact non-action labels:
`暂时不用`, `暂不需要`, `不用了`, `先这样`, `不需要`, `暂不操作`, `暂不继续`,
`没有了`, `以上都不`, `暂时不需要`, `先不用`, `以后再说`, `暂不处理`, `无需操作`, `暂停，稍后继续`, `not now`, `no thanks`, `do nothing`, `none of the above`, `skip`, `none`.
Do not apply this list to `ask_user`, substring matches, or actionable labels such as
`取消正在运行的任务`. Retain 2–4 effective actions or return the existing effective-count error;
never invent replacement options. IDs are assigned after removal, exactly as below.
`description` remains accepted and persisted for compatibility; the compact steps UI omits it.
The generator should produce 2–4 short actionable labels, omit explanations in the card,
and omit the card entirely when there are fewer than two meaningful next actions.
5. Recommendation ordering: find the first remaining choice that is not `danger` and either has
   `recommended:true` or `style:"primary"`. If one exists, remove it and insert it at index 0. If
   none exists, keep the caller order and recommend nothing.
   - Index 0, when a recommendation was found, gets `recommended:true`.
   - Every other choice loses `recommended` and a `style:"primary"` is rewritten to `"default"`.
   - A `danger` choice is never moved to index 0 by this rule and never receives
     `recommended:true`; a caller-supplied `recommended:true` on `danger` is removed. When no
     recommendation is found, a `danger` choice already at index 0 stays there.
6. Assign `id` after ordering: `o0`, `o1`, `o2`, `o3`. The id is host-owned and stable only for
   that response; a re-rendered card is a new row.
7. `ask_user` returns
   `{"cardType":"question","question":<string>,"options":[...]}` plus `helpText` when non-empty and
   `<2–4>` options. `show_next_steps` returns
   `{"cardType":"steps","steps":[...]}` with 2–4 steps. Neither card carries `title`, `value` at
   the card level or an index.

Source: `BotCardPayloads.swift:44-131`.

## 3. `show_attachment`

- `path` is required, non-empty after trimming; `caption` is optional. The card is
  `{"cardType":"attachment","path":<path>}` plus `caption`.
- No file is read, copied or verified by the builder; the attachment pipeline owns existence,
  size and MIME. An empty/missing `path` fails with `path 不能为空。`
  (`BotCardPayloads.swift:133-138`).

## 4. `show_document`

- At least one of `path` or `content` is required; neither is
  `show_document 需要 path 或 content。`.
- `title` defaults to the last path component, else the first Markdown heading of `content`, else
  `文档`. `kind` defaults to `pdf` when `path` ends in `.pdf` (case-insensitive), else `markdown`.
  `kindLabel` defaults from this table: `document=文档`, `markdown=Markdown`, `table=表格`,
  `pdf=PDF`, `code=代码`, `library=文件库`; an unknown kind keeps the kind string as its label.
- The card is `{"cardType":"document","title","docKind","docTypeLabel"}` plus the supplied
  `summary`, `path`, `content`, `fileName` (default: last path component), `size`,
  `parseHeadings` and `toc` when present.
- `toc` MUST be an array of non-empty strings; it is truncated to the first 6 entries. When `toc`
  is absent, Markdown headings (`#` lines, trimmed) are collected up to 6; no headings means no
  `toc` member. `parseHeadings` MUST be a boolean when present.
- The builder does not read the document, resolve the path or validate the extension against the
  kind.
- Source: `BotCardPayloads.swift:140-183`.

## 5. `show_progress`

- `title` is required, non-empty after trimming, and at most 80 UTF-16 code units; otherwise
  `show_progress 需要 title。` or `show_progress title 最多 80 字。`.
- `state` defaults to `running` and MUST be one of `running`, `done`, `paused`, `failed`,
  `cancelled`.
- `steps` is optional, at most 8 entries. Each entry is an object with a required non-empty
  `label`, an optional `state` (default `pending`; one of `pending`, `active`, `done`, `failed`,
  `skipped`), and an optional `detail`. Normalized steps are
  `{"id":"step-<i>","label","state"}` plus `detail`. If no step is `active` and one is `pending`,
  the first pending becomes `active`.
- `percent`: when supplied it MUST be an integer 0–100; otherwise `done` means 100, a non-empty
  step list means `round((done + skipped) / count * 100)`, and no steps means 0. When `state` is
  `done` the emitted `percent` is forced to 100 even if a different explicit value was valid.
- `cardKey` defaults to `"progress:" + first 24 hex characters of SHA-256(title)`; a supplied key
  MUST be non-empty and at most 64 UTF-16 code units. Reusing a key updates the same row; the
  builder does not deduplicate or persist.
- The card is `{"cardType":"progress","title","state","cardKey","percent"}` plus `steps`, `summary`
  and `eta` when present.
- Source: `BotCardPayloads.swift:185-245`.

## 6. `show_checklist`

- `title` is required and non-empty; `items` is required with 1–12 entries.
- Each item is an object with a required non-empty `text`, an optional boolean `done` (default
  `false`) and an optional `note`. Normalized items are
  `{"id":"item-<i>","text","done"}` plus `note`.
- The card is `{"cardType":"checklist","title","items"}` plus `summary` and `interactive` when
  present; `interactive` MUST be a boolean.
- Source: `BotCardPayloads.swift:247-269`.

## 7. `show_link`

- `links` is required and MUST be an array of at most 4 entries. Each entry is an object with a
  required `url`; URLs must parse, have scheme `http` or `https` (case-insensitive), a non-empty
  host, and at most 2,048 UTF-16 code units. An entry failing any of these is dropped; entries are
  never repaired or rewritten.
- At least one valid link is required, else
  `show_link 需要至少一個合法的 http(s) links[] {url}。`.
- Each link normalizes to `{"url":<raw>,"title":<title or site>,"site":<site or host>,"kind":<kind or "other">}`
  plus `description`. `kind` is not validated; the caller's string is kept. A top-level `title` is
  optional.
- The card is `{"cardType":"link","links":[...]}` plus `title`.
- Source: `BotCardPayloads.swift:271-299`.

## 8. Exact failure messages

These strings are the frozen phoneDSH wording; a second implementation MUST reuse them byte-for-byte
so the Worker's model-visible failure text does not fork. `<path>` is `options[<i>]` or
`steps[<i>]`, `<key>` is the missing field name.

| condition | message |
| --- | --- |
| `arguments` not an object | `arguments must be an object` |
| unknown / P1 tool | `unknown or non-P0 card tool: <tool>` |
| `ask_user` raw count | `ask_user 需要 2–4 个 options。` |
| `ask_user` count after “other” removal | `ask_user 需要 2–4 个有效 options。` |
| `show_next_steps` raw count | `show_next_steps 需要 2–4 个 steps。` |
| `show_next_steps` count after “other” removal | `show_next_steps 需要 2–4 个有效 steps。` |
| empty string step | `steps[<i>] 不能为空。` |
| entry not an object | `<path> 必须是对象。` |
| missing/empty label | `label 不能为空。` |
| non-string label | `label 必须是字符串。` |
| non-string style | `<path>.style 不合法。` |
| missing/empty string field | `<key> 不能为空。` |
| non-string field | `<key> 必须是字符串。` |
| field is not an array | `<key> 必须是数组。` |
| `final` not boolean (content cards) | `final 必须是 boolean。` |
| `show_document` with neither source | `show_document 需要 path 或 content。` |
| `toc` not an array of non-empty strings | `toc 必须是字符串数组。` |
| `show_progress` missing title | `show_progress 需要 title。` |
| title over 80 UTF-16 units | `show_progress title 最多 80 字。` |
| invalid state | `show_progress state 不合法。` |
| `steps` over 8 or not an array | `show_progress steps 最多 8 项。` |
| invalid step state | `steps[<i>].state 不合法。` |
| bad percent | `percent 必须在 0…100。` |
| `cardKey` empty or over 64 | `cardKey 最多 64 字且不能为空。` |
| checklist item count | `show_checklist 需要 1–12 个 items。` |
| link count over 4 or not an array | `show_link 最多 4 个 links。` |
| no valid link | `show_link 需要至少一個合法的 http(s) links[] {url}。` |

## 9. Companion tool-result rules

- A successful `ask_user` returns the fixed text
  `已显示提问卡；回合应在此结束，等待用户选择。`; `show_next_steps` returns
  `已显示建议下一步卡片；回合应在此结束，等待用户选择。`. Both tools then suppress later
  assistant text and `SendToUser` for the rest of the turn (`tool-contracts.md` §2).
- A successful content card with `final:true` also suppresses later assistant text and
  `SendToUser`. The flag itself never appears in the card payload or the `card.presented` event.
- The durable `card.presented` event adds `card`, `id` (`card-<uuid>`), `tool` and `callId` around
  the same payload; a failed build writes no event (`BotMCPRuntime.swift:1368-1396`).
