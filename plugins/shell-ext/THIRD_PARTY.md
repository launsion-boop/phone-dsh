# Third-party notices for `@phone-dsh/dsh-shell-ext`

The package itself is MIT. This file records the licences of the one new
runtime dependency and its installed tree, as required by the phone-DSH
licence policy. Every entry is a permissive licence; no GPL, LGPL, AGPL or MPL
package is installed for this package.

## New dependency

| Package | Version | Licence | Source | Licence file checked |
| --- | --- | --- | --- | --- |
| `just-bash` | 3.6.0 | Apache-2.0 | <https://github.com/vercel-labs/just-bash> | `LICENSE` in the npm tarball is the Apache License 2.0 text. |

`just-bash` is imported as a normal npm dependency through its `browser`
entry (`just-bash/browser`), which excludes the Node-only command chunks and
the native optional dependencies. The package is not vendored; the controlled
terminal-state seam described below is the only local byte patch.

## Controlled patch to just-bash 3.6.0 (Apache-2.0)

`just-bash` is Apache-2.0. The published `3.6.0` browser bundle is minified and
does not ship the interpreter source, so phone-DSH applies a narrow,
byte-guarded patch to its **own installed copy** of
`node_modules/just-bash/dist/bundle/browser.js`. It does not modify, vendor or
fork the upstream package, the npm registry tarball, or any DeepSeek Harness
source.

| Item | Value |
| --- | --- |
| Package / version | `just-bash` 3.6.0 |
| Licence | Apache-2.0 (upstream `LICENSE` is retained unmodified) |
| Patched file | `dist/bundle/browser.js` only |
| Pristine SHA-256 | `38f1ad1e3283980ecdf68cede8a4eed028c6dff6e8c31793dec1e0af529c446e` |
| Patched SHA-256 | `124182d76319a5a7c542f4014362f0eba7aa66af9f0a1665574594f0c628e018` |
| Installer | `shell-ext/tools/patch-just-bash.mjs` |
| Guards | exact package name/version/licence, pristine or patched hash, exact occurrence count per replacement, result hash before atomic write |

The patch exposes the real local execution state on `Bash.exec` results:
`metadata.terminal` (real cwd separated from `PWD`, global env, options,
functions, arrays, last pipeline statuses, typed cause) plus a non-enumerable
snapshot used to seed the EXIT handler. It also uses the engine's own full
namespace clone/rollback for command substitution, source/subshell boundaries
and every non-`lastpipe` pipeline stage, so functions, options, `shopt`, cwd,
readonly attributes, the terminal cause and local scopes cannot survive a child
scope into the parent or its EXIT snapshot; plain `local`/`declare`
declarations snapshot the array cell so `local B; B=(...)` unwinds to the
caller's array. A typed pipeline-stage fatal becomes that stage's result rather
than escaping to the root. A symbol
`ExecOptions` seed sets the handler's `$?`/`PIPESTATUS`/options without a hidden
command name or shell variable, and the patched `source`/`eval` builtins apply
the phone transform plugins to their own text. The `trap` builtin receives an
engine-owned shell-scope id on its command context: a subshell, background job
or command substitution has its own virtual pid, and every stage of a
multi-command pipeline also gets a stage-scoped id even when the command word is
only resolved at runtime, composed with a nested virtual pid for a subshell or
command substitution inside that stage. A child therefore cannot clear or
replace the root handler; child EXIT actions are discarded with that scope (only
the root handler runs). Producer-owned truncation facts travel on results under
`Symbol.for('@phone-dsh/just-bash/output-truncation/v1')`, are forwarded by the
statement and compound output builders and by byte-normalised pass-through
pipeline stages, and are folded only into bytes that reach the final live
stream, never inferred from marker-like user text. It is applied by `npm ci`
(postinstall), by `pretypecheck`/`pretest`, by the direct image-packer path and
by `bundle/build.mjs`.
A wrong version, licence or byte image is refused, and a second run is
idempotent. This notice is the Apache-2.0 provenance record for the patch; the
phone-side consumer files are MIT.

## Installed dependency tree

`npm ls --omit=optional` in `plugins` is the authority. The direct
dependencies of `just-bash` are:

| Package | Version | Licence |
| --- | --- | --- |
| `diff` | 8.0.4 (nested under `just-bash`) | BSD-3-Clause |
| `fast-xml-parser` | 5.11.2 | MIT |
| `file-type` | 21.3.4 | MIT |
| `guarded-fetch` | 0.1.3 | Apache-2.0 |
| `ini` | 6.0.0 | ISC |
| `modern-tar` | 0.7.7 | MIT |
| `papaparse` | 5.7.0 | MIT |
| `re2js` | 1.3.3 | MIT |
| `run` | 2.1.3 | Apache-2.0 |
| `seek-bzip` | 2.0.0 | MIT |
| `smol-toml` | 1.9.1 | BSD-3-Clause |
| `sprintf-js` | 1.1.3 | BSD-3-Clause |
| `sql.js` | 1.15.1 | MIT |
| `turndown` | 7.2.4 | MIT |
| `typescript` | 5.9.3 | Apache-2.0 |
| `yaml` | 2.9.1 | ISC |

ISC is a permissive, GPL-compatible licence (functionally equivalent to MIT)
but is not literally one of MIT/Apache-2.0/BSD; it is recorded here explicitly
so the policy owner can accept or reject it. Deeper transitive packages are
MIT, ISC, BSD-2/3-Clause or Apache-2.0.

## Optional dependencies

`just-bash` declares two **optional** native dependencies:

| Package | Licence | Decision |
| --- | --- | --- |
| `@mongodb-js/zstd` | Apache-2.0 | Permissive. `npm ci` may install it as an optional native package; `just-bash/browser` never imports it, so it is not in the Worker bundle. |
| `node-liblzma` | LGPL-3.0 | Rejected. Not installed in this worktree (`npm ls node-liblzma` is empty) and never imported. |

The Worker imports `just-bash/browser`, which contains no reference to either
native package, so neither is in the Worker bundle. The lockfile still records
`node-liblzma` as `optional: true` because that is the dependency metadata
`just-bash` publishes; on this Node/macOS host `npm ci` does not produce the
directory (the optional native build is skipped). A plain `npm install` on
another host may attempt it as an optional build-time package.

If the licence policy also forbids an LGPL package anywhere in the lockfile
metadata, `just-bash` cannot satisfy it: every 2.x/3.x release declares
`node-liblzma` as an optional dependency, and 1.5.4 (which has no cancellation
or stdin hooks, so it cannot serve this task's contract) is the last release
without it. This needs a policy decision; the shipped Worker code path has no
LGPL edge.

## W5 coverage stubs

`src/corpus.ts` contains no third-party code. The `host` coverage mode registers
deterministic success stubs for external toolchains the Worker does not
implement; they are test scaffolding, not dependencies, and every stub says so
on stderr.

## Root notice

`plugins/THIRD_PARTY.md` is the image-level notice: it lists exactly the
npm packages `scripts/pack-image.mjs` bundles into the Worker image (for this
package: `just-bash`, its nested `diff` install, `sprintf-js`, `turndown` and
`@mixmark-io/domino`), and `scripts/pack-image.test.mjs` checks that table
against the real staging result. The tables above are wider on purpose: they
record the whole installed tree, including packages that are never bundled.
