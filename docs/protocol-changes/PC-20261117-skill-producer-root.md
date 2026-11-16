# PC-20261117-skill-producer-root — official skill root and real producer chain

- status: frozen (no schema/wire change)
- base: `9a373adeac0e10f2d3b61c9136a70107778bbc5b`
- owning: `spec/bot/v2/provenance.md` §3.4

## Findings

- Official DSH `skill-filesystem` discovers multiple roots: `projectRoot/.dsh/skills`
  (`project-dsh`), `projectRoot/.agents/skills` (`project-agents`), plus user/custom/bundled. A project
  skill with the same name overrides user/custom. A Bot's cwd is its per-Bot `botRoot`, so two Bots can
  legitimately have the same name at different project paths.
- `phone-feature-admin`'s `SkillsStore` remains the single profile-level host editor
  (`/dsh/home/skills`, source `host`), flat `*.md` only.
- Correct identity is therefore `(source, owner_bot_id?, name)`: `skill.changed.skill.source` enum and
  optional `owner_bot_id`; project sources require owner == author bot; global sources must not carry
  owner. Legacy events without source read as `host`. L key must use this tuple; no name-only merge.

## Producer contract

- After a real host `SkillsStore.write/delete` (source host) or a real project-root skill write/delete
  (source project-dsh/project-agents, owner Bot) succeeds, read the final file bytes (delete: bytes/hash before
  removal) and emit `skill.changed` with file/name, sha256, bytes, previous_sha256, monotonic revision
  and real author. No manual append; no directory scan claiming a model citation; failed/partial/temp
  writes emit nothing. `derivation` only for real source refs.
- L rechecks the real file; same only on hash match. Known erased/revoked/deleted source skips the file
  provider; G-4 r2 worst-of applies; cache/workspace cannot resurrect current. D receipt stays unknown
  until this producer is wired.

## Identity / compatibility

- `skill.source` is optional for the old host writer (missing = host); new project producers must set
  it and `owner_bot_id`. Same name at host/project or two Bot project roots is not one artifact.
- No absolute cwd/root path is stored; source+owner is the identity. No guessed per-Bot key.

## Owners / verification

- R2 real producer/helper and Bot-only use-site guards; C small shared runtime/composition; L index/
  state/rechecker; G contract. Need actual filesystem create/update/delete + revoke/erase counterexample,
  fixed SHA and real caller; no manual event append/unit-only PASS. A04 remains OPEN.


## Revision 2 — exact official sources, no root path, Bot loader disabled

- Official source enum is `project-dsh|project-agents|custom|user-dsh|user-agents|bundled`; legacy
  missing source means `user-dsh` (feature-admin `/dsh/home/skills`).
- Identity is `(source, owner_bot_id?, name)`. No `skill.root` path/VFS field: for project roots the
  source + per-Bot owner uniquely identifies the configured root; adding a path is not needed and would
  leak/relocate the root identity. Do not invent a root field.
- `phone-bot` preset currently drops `skill-filesystem`/`tool-skill`, so Bot project-dsh files are not
  loaded by official discovery. A04 may record **file lineage** from real Bot write/edit, but cannot
  claim Bot skill load/use; that remains OPEN/BLOCKED.
- Delete: official `tool-fs` has no delete; `bash rm` emits no fs/observed. Do not parse bash. Feature
  admin `skillsDelete` is the real user-dsh delete; Bot project delete requires a real managed entry
  before A04 can claim it; otherwise OPEN.
- Producer R2 records only actual final bytes/hash/revision/author from real write/edit; derivation only
  when real sources exist; no scan/pretend citation.
