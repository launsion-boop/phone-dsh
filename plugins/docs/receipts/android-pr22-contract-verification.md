# Android PR22 — plugin workspace contract verification (r-plugins)

SPDX-License-Identifier: MIT

Evidence-only receipt. This run verified the pinned plugin workspace; it did **not**
change plugin runtime logic, dependencies, lockfiles, tests or gates.
No plugin contract defect was found, so the only committed change is this receipt.

## Candidate binding

| Item | Value |
|---|---|
| Tested candidate commit | `346676caa8b15cc2a458c32e6a8329d2770a8ea9` ("Integrate Fleet candidate") |
| `346676c:plugins` subtree | `0407fa842599230275831bc7685fe7b19d908392` |
| Frozen campaign baseline | `714348ed33bbb8ae2adac71659b7d662670969e9` |
| `714348e:plugins` subtree | `0407fa842599230275831bc7685fe7b19d908392` |
| Plugins files changed baseline..tested candidate | **0** (`git diff --name-only` empty) |
| Deliverable change | This receipt only; no plugin runtime, test, lock or gate change |
| Worktree before commit | clean (no `node_modules` or test caches staged) |

The plugin runtime/test tree is byte-identical to the frozen baseline: the shared
shell-ext/mux/main integration did not touch `plugins/`. Per the task rule
("if a plugin was not touched by the merge, leave its logic unchanged and say
so"), no plugin source was edited. The only file added by this verification run
is this receipt (which is itself under `plugins/docs/receipts/`), so a subtree
hash of the deliverable commit necessarily differs from `0407fa8...` by exactly
that document.

## Exact commands, exits and counts

All commands were run from `plugins/`.

| # | Command | Exit | Result |
|---|---|---|---|
| 1 | `npm ci` | **0** | 717 packages installed from the committed `package-lock.json`; postinstall re-applied the just-bash terminal-state seam |
| 2 | `npm run typecheck` | **0** | `pretypecheck` (ensure-deps + patch-just-bash + wasi dev deps) then `tsc -p tsconfig.json`; no diagnostics |
| 3 | `node scripts/run-tests.mjs "tests/shell-ext-contract.test.ts" "tests/shell-ext-bridge.test.ts" "tests/shell-ext.test.ts"` | **0** | **31/31 pass**, 0 fail, 0 cancelled, 0 skipped |
| 4 | `node scripts/run-tests.mjs "tests/exec-read-denial-rendering.test.ts" "tests/exec-read-guard.test.ts"` | **0** | **11/11 pass**, 0 fail, 0 cancelled, 0 skipped |
| 5 (supplementary) | `node scripts/run-tests.mjs "worker-entry/src/mux-bridge.test.ts" "worker-entry/src/mux-projection.test.ts"` | **0** | **24/24 pass**, 0 fail, 0 cancelled, 0 skipped |

Rows 1–3 were executed at `346676c` and re-executed unchanged at the prior
receipt-only commit `13399a0`; row 4 was added and executed at `13399a0` (this
receipt edit does not change the source/test tree); row 5 was executed at
`346676c`. The plugin source/test tree is identical throughout — only this
receipt document differs.

Targeted slice breakdown (31 total):
`tests/shell-ext-contract.test.ts` = 11, `tests/shell-ext-bridge.test.ts` = 9,
`tests/shell-ext.test.ts` = 11.

Denial slice breakdown (11 total):
`tests/exec-read-denial-rendering.test.ts` = 8, `tests/exec-read-guard.test.ts` = 3.

## Coverage exercised by the executed tests

- **Command routing** — advertised accelerators forward `argv`, cwd,
  `requires_mseq` and the D10 `idem_key`; an unadvertised `rg` keeps running
  Worker-local; an unknown program is `127` plus the capability-manifest hint;
  a shell-exported identity/session cannot shadow the trusted envelope.
- **Caps** — host accelerator allow-list (`advertisedAccelerators`), the
  `pdsh-capabilities/1` manifest referent, and a refused 15 MiB write reported
  as `reason=limit-refused`.
- **Denial** — row 4's `tests/exec-read-denial-rendering.test.ts` and
  `tests/exec-read-guard.test.ts` assert that every command answers a refused
  directory with the contract `EACCES` sentence plus the remediation line, that a
  refused file under an internal root gets the same answer, and that worker
  policy refuses `rg`/`jaq` on internal roots without sending an `EXEC_REQ` while
  a readable home file still crosses. The targeted three files additionally cover
  a write rejected as `reason=limit-refused` and a direct VFS symlink `EPERM`;
  those are not the EACCES assertions.
- **Output budgets** — truncation keeps head and tail with the exact
  dropped/total byte counts; stdout and stderr are bounded at `maxOutputBytes`;
  a cut stream exits non-zero with `reason=output-truncated`.

The supplementary mux slice covers the `/api/remote.mux` send/receive/close
bridge and the projection seam.

## Sources reviewed

- `plugins/package.json` and `plugins/package-lock.json` (lockfile pins unchanged:
  `just-bash 3.6.0`, `@deepseek-ai/dsh 0.2.1-rc.2`, `typescript 5.9.3`; 16
  declared workspaces. The lock lists all 16 workspace entries plus the root
  package, i.e. 17 non-`node_modules` package entries, and installs 16 workspace
  links under `node_modules/@phone-dsh`; no workspace is missing).
- `shell-ext` contract/bridge/shell/output/capabilities/exec-denial sources,
  `channel/src` frame/WAL/hello sources, and `worker-entry/src` mux sources.

## Fixture and safety boundaries

- `NO_PROXY` has exactly one code occurrence in the plugins tree, only inside the
  labelled local fake-transport fixture `tests/wasi-python-network.test.ts:84`;
  it is **not** used for app networking. (This receipt also names the variable,
  so a raw text search over the tree sees two hits, one of them this line.)
- No real model/provider calls, billing, messaging, secrets or credentials.
- No admin/service changes; no host/kernel changes; no git push, merge, PR or
  deploy; `.github` untouched.
- No dependency added or upgraded, no package-manager switch, no generated
  `node_modules` committed.

## Environment

- Date (UTC): `2026-11-02`; the denial re-check finished at `2026-11-02T20:23:52Z`
- Node `v22.22.3`, npm `10.9.8`
- `HOME=/work/home`, `XDG_CACHE_HOME=/work/cache`
- Host/toolchain: Linux container; Android SDK/emulator not used.

## NOT_RUN

- Full workspace `npm test` and the contract/compat gates — **NOT_RUN and
  unscheduled**. They are outside this run's required slice, and the program's
  final `h-verify` lane does not include a full plugin-suite command either (its
  plugin commands are only `cd plugins && npm ci` and
  `cd plugins && npm run typecheck`). No owner or command for the full suite is
  claimed here.
- Device/emulator, APK, and installed-App checks — not applicable to a plugin
  workspace verification; no Linux result is claimed for them.
