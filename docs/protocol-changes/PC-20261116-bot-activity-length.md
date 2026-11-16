<!-- SPDX-License-Identifier: MIT -->
# Bot activity generation length

Protocol impact: P09; P26; P27: none — no row, reducer or persisted-value change.
Base: bbd67ca783c9436cdb658eec3cac0ab0e3809f46.
Contract revision: activity-evidence-v3.6.

The user observes that a 28-character result sentence is truncated by the existing
19-character-plus-ellipsis UI cleaner. Generate about 10 characters; never exceed 19,
including spaces, digits, punctuation and any result. No longer-result exception.
Example: “3 个文件冲突，逐个核对”. Preserve the meaningful task/result over filler words.

Owner: root. Producer: both Bot prompts, mirrored Worker persona and Bot-only tool
schema prose. Five-tool activity maxLength changes 160 → 19 in the cloned model-facing
schema only. bash description keeps its original schema constraints and handler.
Consumers: existing projection/UI truncation retained for old logs and noncompliant
model output. No event, original tool validator, argument stripping, handler, schema
version, row or wire change. Old/new calls still execute; old logs remain readable;
rollback needs no migration. Android and DSH source remain out of scope.

Freeze this spec before implementation. Validate the assembled prompts/profile mirror
and real ToolRuntime model-facing schema, including legacy missing-activity execution.
Historical real-model and native UI receipts remain historical, not new-run evidence.
