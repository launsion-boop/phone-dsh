<!-- SPDX-License-Identifier: MIT -->
# Phone-only WAL replay vectors — closed-session rewrite

Status: normative phone-only fixtures. These cases exercise a WAL shape the
phone host produces for the S6 step-2 closed-session rewrite
([PC-20261112-bot-session-epoch](../../../../../docs/protocol-changes/PC-20261112-bot-session-epoch.md),
[wal.md](../../../../wal.md) §5.3). They use the same
[wal-replay.schema.json](../../../../schema/wal-replay.schema.json) shape as the
shared directory.

The kept-aside directory is deliberate: Android/HarmonyOS hosts and the Rust
`pdsh-wal` implementation do not run a Bot and do not produce this shape, so
adding the file to the shared `replay/` directory would force a platform that
does not implement the feature to count it as a conformance vector. Swift
`PhoneDSHLogTests` drives the vector through the real `WorkspaceLog` and
`Materializer`; `spec_golden.py` validates it with the same reference replay.
