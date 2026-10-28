# @phone-dsh/dsh-contract-tests

Compatibility contract suite for the DeepSeek Harness (DSH) seams the
phone-dsh phone host depends on. It runs against **any** DSH checkout and
reports every value it observed, so a daily run against DSH master can be
diffed field by field against the pinned release.

The checkout is read-only. No DSH source is copied into this repository and no
patch is applied; the suite only imports and inspects the checkout named by
`--checkout` / `PDSH_DSH_CHECKOUT`.

This package is **not** a workspace member of `plugins`: it reuses the
parent package's `devDependencies` and `node_modules`, so it must be run from
`plugins` via `npm run contract` (as shown below). Invoking the CLI from
another directory is not supported.

## Run

```sh
# From plugins, against the pinned checkout named by the environment:
PDSH_DSH_CHECKOUT="${PDSH_DSH_CHECKOUT:-$(cat "$HOME/.config/phone-dsh/dsh-checkout")}"
npm run contract -- --checkout "$PDSH_DSH_CHECKOUT"

# Or against another checkout (for example a DSH master clone):
npm run contract -- --checkout /path/to/deepseek-harness --report "$PWD/contract-report.json"
```

The path may come from, in order: `--checkout`, `PDSH_DSH_CHECKOUT`, or the
single line of `$HOME/.config/phone-dsh/dsh-checkout`. The command exits non-zero when
a seam test fails; the report is still written first.

`node --test` files live in `tests/`. The CLI bundles a small probe (see
`src/probe.ts`) against the checkout's TypeScript sources with esbuild, then runs
the suite with the reporter in `src/reporter.mjs`. Source-level seams are read
with the TypeScript parser in `src/ast.ts`, so formatting and comments do not
change the observations.

## Seams under contract

| Test | Seam |
|---|---|
| `runtime-exports` | `webworker-runtime/src/index.ts` still exports the runtime symbols the Worker entry and image packer import. |
| `worker-host-options` | `createWorkerHost` still takes `WorkerHostOptions`, with the option names the phone entry passes (`staticModules`, `staticModulePrefixes`, `requestListener`, `alsCausality`, `image`, `overlays`, `env`, `channel`). |
| `memory-vfs` | `MemoryVfs` sink `record()` is synchronous, `flush()` awaits the sink, and `subscribe()` observes every mutation, including `appendedFrom`; seeding is silent. |
| `packer-options` | `packVfsImage` still takes `PackOptions`, with the keys `profile`, `roster`, `installation`, `workspaces`, `resolveFrom`, `homePatch`, `entries`. |
| `profile-merge` | `readProfilePatches` merges bundle, profile, HOME patch and overlay layers in that order; `prepareProfile` loads that HOME patch and returns the `boot()` patches; the packer writes `home/cordis.patch.yml`. |
| `image-layout` | `PLATFORM_ENTRY_CONFIG` still forces plaintext session JSONL, and an overlay may only populate `home/` and `workspace/`. |
| `when-request-listener` | `whenRequestListener()` waits for `createServer(listener)` and resolves with that listener; the fake server carries the members the webserver binds. |
| `child-process` | The `child_process` shim accepts `bash -c` and `sh -c`, and reports unknown programs as `ENOENT` with Node's `errno`, `path` and `syscall`. |
| `shell-programs` | The shell command table still carries the baseline program set. |
| `shell-interpreter` | The interpreter still dispatches `command`, `envs`, `subshell` and `group` command nodes and the `<`, `<<<`, `>`, `>>`, `>&`, `<&` redirections, with one behavioural run per construct. |
| `workspace-changes-git` | `workspace-changes` still runs the eight snapshot subcommands (`rev-parse`, `add`, `write-tree`, `ls-tree`, `cat-file`, `diff-tree`, `ls-files`, `check-ignore`) with their expected flags. |
| `tool-fs-search` | `tool-fs-search` still builds the `rg --json` / `rg --files` argv, and the spawn prepends `--no-config`. |
| `report` | Observed values are canonical JSON, reports carry no absolute local path, and the pin/master diff names test and observation changes. |

Each test prints one `observed <name>: <json>` line and appends the same value
to the run's observation log. The report collects those values:

## Report

`contract-report.json` (default `plugins/contract-tests/contract-report.json`,
ignored by git) has this shape:

```json
{
  "schema": "pdsh-dsh-contract-report/1",
  "generated_at": "2026-01-01T00:00:00.000Z",
  "checkout": { "version": "0.2.1-rc.2", "commit": "…", "pin_match": true, "resolved_as": "argument" },
  "result": { "status": "pass", "exit_code": 0, "duration_ms": 1, "counts": { "tests": 21, "passed": 21, "failed": 0, "skipped": 0, "todo": 0, "cancelled": 0 } },
  "tests": [{ "file": "contract-tests/tests/…", "name": "…", "status": "passed" }],
  "observed": [{ "test": "…", "name": "…", "value": [] }],
  "environment": { "node": "v24.19.0", "platform": "linux-x64" }
}
```

Absolute local paths are replaced with `<path>` before the report is written,
so the file is safe to upload as a CI artifact.

## Pin/master diff

```sh
npm run contract:diff -- pin.json master.json --out reports/
```

This writes `contract-diff.md` (human-readable) and `contract-diff.json`
(machine-readable): tests only in one report, test status changes, and observed
values that were added, removed or changed. A missing report is named as such
instead of failing the diff.

## Daily compatibility workflow

[`.github/workflows/phone-dsh-compat.yml`](../../../.github/workflows/phone-dsh-compat.yml)
runs on a daily cron and on manual dispatch. It checks out DSH at the commit in
`plugins/dsh-pin.json` and at `master`, builds the full DSH host face the
contract needs (the same `tsc -b` / `generate-typert` / `tsdown` host build as
the macOS job, because the probe's workspace imports resolve through each
package's built `lib/` output), runs this suite against both checkouts, and
uploads the two reports plus the diff. A macOS job builds the pinned checkout
and runs the `phone-plugins` stage of `scripts/ci/check.sh` with
`PDSH_DSH_CHECKOUT` pointing at it.

## Limits

- The suite tests the seams above, not the whole DSH product. A green run is not
  a promise that every DSH release boots the phone image; `npm test` and the
  image-boot test remain the behavioural gate.
- iOS, WebKit and on-device execution are **NOT_VERIFIED** here. This suite runs
  under Node against source and build artifacts, as the CI workflow does.
- A failing master run is a signal to inspect the diff, not proof that the phone
  host is broken; the pin run must stay green for the release contract.
