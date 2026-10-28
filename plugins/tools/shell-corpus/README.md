# Shell command corpus and coverage tooling

MIT tooling for the W5 shell work. It turns real DeepSeek Harness session logs
into an anonymised command corpus, ships a committed public corpus, and runs
that corpus through a pluggable shell runner so gaps are measured instead of
guessed.

Nothing here modifies or vendors DSH: the `runtime-js` runner imports the shell
interpreter and `MemoryVfs` from the pinned checkout at run time. The checkout
is resolved from `PDSH_DSH_CHECKOUT`, otherwise from the single line in
`$HOME/.config/phone-dsh/dsh-checkout`; no machine path is stored in the repository.

## Extract commands from session logs

```sh
node tools/shell-corpus/extract.mjs --out corpus.jsonl SESSION.jsonl...
```

The extractor reads DSH session JSONL files and keeps only `bash` tool-call
command strings. It understands content-block tool calls, programmatic
sub-dispatches (`tool/ptc-dispatch`), OpenAI-style function calls, JSON-string
arguments and raw command arguments. Before writing each record it:

- replaces single- and double-quoted literals longer than 40 characters with
  `<redacted>` in the same quoting style;
- reduces an absolute path under a home directory (current home directory,
  `Users/<name>`, `home/<name>`) to `$HOME`, so project names below it do not
  leak;
- drops malformed lines, non-bash calls, empty commands and exact duplicates.

Output is one JSON object per line:

```json
{"cmd":"ls -la","source":"session"}
```

The user's logs never leave the machine; only the anonymised command strings
are written. Use `--append` to add to an existing corpus.

## Public corpus

`corpus/public.jsonl` has 428 commands, at least 60 in each category (`files`,
`text`, `git`, `package`, `build-test`, `script`, `network`). They are
synthesised from
the DSH repository's docs/tests/examples (records tagged
`"origin":"dsh-repo"`) and from typical coding-agent usage. Every record has
`cmd`, `category` and `source: "public"`. Commands run against a scratch
`/dsh/workspace` fixture (see `runtime-evaluator.mjs`) and are self-contained:
a command may create or remove files, but never depends on another corpus
command having run.

`corpus/interpreter-invocation.jsonl` is a second, small corpus for the
`bash`/`sh` invocation surface (G2-FIX-89): `bash SCRIPT` / `sh SCRIPT`,
`/bin/bash` / `/bin/sh`, script arguments, `bash -n`, `bash --version` and the
nested `bash -c 'bash SCRIPT'` form. `interpreter-invocation.test.mjs` runs
every line through the `just-bash` runner and requires `classify.mjs` to call
the outcome `ok`, so an option read as a script filename (`command-missing`) or
a nested-interpreter accounting failure (`runtime-error`) fails the class gate.
It is kept separate from `public.jsonl` because the public-corpus command count
is pinned by the coverage threshold test.

## Golden vectors and the class contract

Coverage answers "did the command exit 0?". It cannot see a built-in that
prints a literal `%y`, returns a fabricated `command -v` path, or silently
omits `tar`: those all exit 0. `golden/worker-shell.jsonl` is the second gate -
334 JSON objects, one per line, with the expected stdout bytes, stderr prefix
and exit status, plus the workspace the command starts from. The compact
contract shape is:

```json
{"name":"find/printf-expands-type","category":"files",
 "cmd":"find notes -printf '%P\\t%y\\n'",
 "fixture":{"notes/a.md":"a\\n"},"directories":["/dsh/workspace/notes"],
 "expect":{"stdout":"\\td\\na.md\\tf\\n","stderrPrefix":"","exit":0}}
```

The original field spelling (`script`, `files`, top-level `stdout`,
`stderrIncludes`, `exitCode`) is accepted too. Optional fields: `stdin`,
`directories`, `cwd`, `env`, exact `stderr`, `filesAfter` (relative path to
exact content), `filesAbsent` (paths that must not exist), `stdoutMatches` (a
regex when stdout is run-dependent, in which case exact `stdout` may be
omitted), `host` (`curl` selects a deterministic `/v1/http` double: `ok`,
`deny`, `status` or `unreachable`; `gzip: "unavailable"` removes every
compression backend) and `expectedDeviation` (`upstreamGap` id plus a note).
Every vector runs in a fresh temporary VFS through the real `WorkerShell` and
the production `createWorkerCommands` table, so a gap in the Worker command
table fails the gate instead of a scenario.

```sh
node tools/shell-corpus/golden.mjs [--golden FILE] [--quiet]
node tools/shell-corpus/contract.mjs [--golden FILE] [--manifest FILE] [--quiet]
node --test tools/shell-corpus        # both gates, also inside npm test
```

`contract.mjs` is the class-level gate. It runs the corpus plus these audits:

- at least 300 vectors, with several per required command family (tar,
  gzip/gunzip/zcat, find, grep, stat, awk, realpath, readlink, seq, command -v,
  which, python, rg, curl, cmp, redirection, `/dev/null`) and at least 40
  non-zero-exit vectors;
- at most 10 expected engine deviations, each with a unique upstream gap id;
  `--manifest FILE` writes the list for the upstream/ENG-05 report;
- every error stream from this layer ends in exactly one parseable
  `pdsh-shell: exit=... program=... reason=...` trailer; a `reason=not-available`
  trailer names `/dsh/home/capabilities.json`; a status-only negative
  (ripgrep's "no matches") needs none;
- the A05 probe sequence has no ambiguous answer: a 127 always carries the
  manifest hint and a command that promised bytes never exits 0 with none;
- the A05 probe budget: the same capability questions the scenario's
  `backup.sh` asks are replayed against the production table, every answer must
  be definitive, and the probe-request count must at least halve the recorded
  26 (see below);
- gzip with no backend, `tar --bogus`, `stat -c '%Q'`, `find -printf '%q'`,
  curl deny/unreachable, the file-redirect path and the cut-stream status are
  driven directly against the production table.

The committed vectors cover every command the G2-A05/A01/A06/C07/E09
scenarios reached for: tar create/list/extract with and without `-z`,
gzip/gunzip/zcat including the 0-byte-success negative and the
gzip -> zlib -> `tar -z` triangle, the whole `find -type` letter set and
`-printf`, every `stat -c` directive, awk `gsub`/`-f`/`-F`, the `grep -I` /
`--binary-files=without-match` forms over a NUL-byte fixture,
realpath/readlink modes including `-z`, seq, `command -v`/`which`/`type`, bare
`python` with the manifest hint, rg `--glob`/`--files`/explicit paths, curl
failure semantics, redirections and `/dev/null`. The G2-D04 byte-comparison
class adds `cmp`/`cmp -s`/`cmp -l` over identical, differing, EOF and
missing-operand fixtures. `coverage.mjs --golden FILE` runs the same vectors
after a coverage pass and folds the result into its report and exit status.

### Host-generated `cmp` goldens

`cmp`'s stdout/stderr shapes and 0/1/2 statuses are the host program's own
bytes (the G2-D04 idempotency check parses the status, and a script may parse
the diagnostic), so its 13 vectors are generated instead of authored:
`tools/shell-corpus/cmp-golden.mjs` runs the host `/usr/bin/cmp` on the same
fixtures the Worker VFS gets and writes the compact vectors.

```sh
node tools/shell-corpus/cmp-golden.mjs --print   # print the generated vectors
node tools/shell-corpus/cmp-golden.mjs --check   # fail on drift from the host
node tools/shell-corpus/cmp-golden.mjs --write   # replace only the cmp/ records
```

`--write` replaces records whose name starts with `cmp/` and leaves every other
byte of `golden/worker-shell.jsonl` alone. The committed goldens are the BSD
host shape (macOS); `cmp-golden.test.mjs` regenerates them as a drift gate on
the same host shape and skips that comparison on a GNU `cmp` host instead of
accepting a second shape silently. `contract.mjs` requires the `cmp` family
(minimum 6 vectors), so deleting the vectors fails the class gate.

## G2-A05 probe budget

`probe-budget.mjs` is the recorded rerun comparison for the compression
scenario. The first real-model batch spent **26 model requests** probing an
environment whose `tar` answered a bare 127 and whose `gzip` reported a 0-byte
success with exit 0 (the count is recorded in `shell-ext/src/command-paths.ts`;
the catalog budget is 25).

The replay asks the nine capability questions `backup.sh` depends on (`tar`
version, the path `command -v tar` prints, gzip archive creation, gzip member
bytes, gunzip, archive listing, `sha256sum`, the `python3` and `unzip`
fallbacks) through the real
`WorkerShell` and production `createWorkerCommands` table. An answer is
**definitive** when it either delivered the promised bytes/artifact or failed
with the class trailer (`pdsh-shell: exit=… reason=…`, whose `not-available` hint
names `/dsh/home/capabilities.json`); anything else is ambiguous and forces
another request. The fixed surface must produce no ambiguous answer and must at
least halve the recorded baseline.

Measured in this worktree (macOS arm64, Node 24.19):

| Surface | Probe requests | Ambiguous | Forced retries | A05 deliverables |
| --- | ---: | ---: | ---: | --- |
| recorded first batch | 26 | 2+ | many | not reached |
| fixed (replay) | 9 | 0 | 0 | complete: `backup.sh` runs twice, archive lists 3 notes, sha256 matches |

```sh
node tools/shell-corpus/probe-budget.mjs
# probe-budget: recorded baseline G2-A05: 26 model requests ... (budget 25)
# probe-budget: fixed surface: 9 probe requests, 9 definitive answers, 0 ambiguous
# probe-budget: probe requests 26 -> 9 (65.4% fewer)
# probe-budget: PASS
```

`contract.mjs` runs the same replay and reports
`taxonomy/a05-probe-budget-significant-drop`; `contract.test.mjs` locks the
recorded 26 and the fixed 9 in the report.

The real-model rerun is a separate lane (`scripts/ci/scenarios.sh`); when
that batch produces `<results>/G2-A05/report.json`, point `--compare` at the
recorded baseline and the rerun and it applies the same halving rule to the
report's `usage.model_requests`:

```sh
node tools/shell-corpus/probe-budget.mjs --compare BASELINE/report.json RERUN/report.json
```

## Coverage

```sh
node tools/shell-corpus/coverage.mjs \
  --runner runtime-js \
  --corpus tools/shell-corpus/corpus/public.jsonl \
  --out "$TMPDIR/pdsh-cov"
```

Options:

| Flag | Meaning |
| --- | --- |
| `--runner NAME` | `runtime-js` (built in) or an external runner. |
| `--runner-module FILE` | Explicit external runner module. |
| `--corpus FILE` | Corpus JSONL; defaults to the committed public corpus. |
| `--out DIR` | Report directory; defaults to a temporary directory. |
| `--threshold PERCENT` | Exit 1 when coverage is below the percentage. |
| `--golden FILE` | Also run the stdout/exit-code golden vectors and fold the result into pass/fail. |

The run writes `coverage-report.json` (all per-command results) and
`coverage-report.md` (summary tables). Every result is classified as:

- `ok`: exit status 0;
- `syntax-unsupported`: a named construct (`for`, `while`, `if`, `case`,
  `function`, `heredoc`, `pipeline`, `redirection`, `subshell`, `arithmetic`,
  `parameter-expansion`, or `unknown`) that the runner rejected;
- `command-missing`: the runner reported a named program as unavailable;
- `runtime-error`: anything else, including a runner that threw.

`runtime-js` starts one child Node process per coverage run and sends it the
whole corpus as NDJSON. The pinned interpreter uses TypeScript parameter
properties, which Node's strip-only loader rejects; the child is launched with
`--experimental-transform-types` when the running Node supports it. Every
command still gets a fresh scratch `MemoryVfs`, and the child imports only
from the checkout.

Construct detection masks quoted text, so `echo "a|b"` is not a pipeline and
`echo 'for x in y'` is not a loop.

## Runner interface (for W5-SHELL / just-bash)

An external runner module exports `createRunner(options)` returning:

```js
{
  name: 'just-bash',
  async start() {},                 // optional, called once
  async run(command) {              // required
    // Optional structured hints skip stderr parsing:
    // syntaxConstruct: 'heredoc', missingProgram: 'git'
    return { exitCode: 0, stdout: '', stderr: '' }
  },
  async close() {},                 // optional, called once
}
```

A thrown error is classified as `runtime-error`. A default export with the
same shape is accepted too. Resolution order for `--runner NAME`:

1. `--runner-module FILE`
2. `PDSH_SHELL_RUNNER_MODULE`
3. `plugins/shell-ext/coverage/<NAME>.mjs`
4. `plugins/shell-ext/<NAME>-runner.mjs`

So the `just-bash` task can land `shell-ext/coverage/just-bash.mjs` and be
selected with `--runner just-bash` without editing this directory.

## Tests

```sh
cd plugins && node --test tools/shell-corpus/
```

The tests cover extractor shape detection and anonymisation, construct
detection and classification against a fixture corpus, the runner interface
with a fake runner, the coverage CLI and threshold exit codes, the public
corpus invariants, the golden vectors and the class contract, the
host-generated `cmp` goldens (including the `--write`/`--check` round trip and
the family-minimum detection), and the A05 probe budget (including a
defect-injection case that re-introduces the 0-byte gzip success and requires
the gate to fail). `index.js` exists because current Node resolves a directory
positional to its index module rather than expanding it into the `*.test.mjs`
files; it imports the same test files, and older Node that does expand the
directory never executes it.
