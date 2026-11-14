# PC-20261113-01 权限范围与轻震动

<!-- SPDX-License-Identifier: MIT -->

Status: implemented on the device build of `06a80094e` + local fixes. No DSH source patch.

## P18: capability manifest

- `workerUnavailableCommands` now accepts boot facts (`accelerators`, `jqEngine`) and records missing `rg`, `phone`, `ts-parse`, `ts-query`, `jq`, `jaq` in `unavailable[]` with a concrete reason.
- A host accelerator (`accelerator:jq`/`jaq`) counts as a real implementation; the manifest no longer marks it unavailable merely because the WASI jq image is absent.
- `PDSHShellProvider.advertisedAcceleratorNames` only adds `phone` when the linked shell exists; the stub cannot claim an accelerator that exits `not_linked`.

## P26: approval scope

- `BotToolEffect.grantResource` separates the per-call resource from the resource to store for a standing grant. `read_image` / `attach_to_model` use `model:image`; `.always` stores that stable value (keeping the existing `session`/`until` scope), so the next image in the same scope is covered. `bash` and memory have no `grantResource` and stay exact-resource. `.allowOnce` keeps the exact resource and is consumed; deny creates no grant.
- DSH Remote still uses `allowed-once` on the wire. The App adds a session+tool local “always” memory and silently answers later approvals with `allow_once`; allow-once/deny clears it. This is app-local state, not a wire change.
- Sandbox escalation remains one-shot-only in the native permission card.

## P09: haptics

- Bot and DSH send/thinking, turn completion and new approval card emit low-intensity impacts. Thinking uses a low `.medium` and is also triggered on the turn-running transition; send and turn-start are debounced to one cue.
- No protocol or persisted projection change; haptics are UI-only and cannot be asserted by XCUITest.
