# `@phone-dsh/dsh-shell-ext` — Worker bash core and long tail

MIT. Everything a `bash -c` needs when it runs **inside** the DSH Web Worker
(PLAN D12): a real bash-like shell (just-bash), the Worker VFS as its
filesystem, the host accelerators on the exec bridge, a `/v1/http` curl shim,
the Worker `git` program, the installed WASI toolbox's programs (`python3`),
bounded output, cancellation and a wall-clock limit.

Nothing here patches or vendors DSH. The package imports its own sources,
`just-bash`, the in-repository `@phone-dsh/dsh-wasi-toolbox/git` program and
the WASI toolbox dispatch; the runtime's `node:fs` is the Worker VFS, so the
same adapter that the tests point at a temporary directory becomes the
sink-mutation path in production.

The command surface is an assembly (engine + shadows + toolbox + Worker git),
so it also has a class contract (`src/contract.ts`): a closed exit taxonomy, one
machine-readable stderr trailer on every failure this layer produces, and a
committed 512-vector golden corpus that CI runs against the real command table
(`tools/shell-corpus/contract.mjs`).

## Why just-bash

The official runtime's JavaScript shell parses four node kinds and ships 41
programs; it cannot run `for`/`while`/`if`/`case`/functions/here-docs. just-bash
3.6.0 (Vercel Labs, Apache-2.0) is an AST-based bash with those constructs and
~80 built-in commands in the browser bundle (`rg`, `sed`, `awk`, `find`, ...); the Node-only commands it names (`tar`, `sqlite3`, `python3`, `yq`, ...) are not instantiated there.
It is the shell core for `bash -c`; the runtime shell remains the explicit
fallback behind `PDSH_SHELL=runtime`. One narrow, byte-guarded patch to the
installed browser bundle exposes the engine's real terminal execution state
(see the `trap` bullet and `src/terminal.ts`); the package is not vendored and
its Apache-2.0 licence is retained.

| Environment | Effect |
| --- | --- |
| `PDSH_SHELL` | `just-bash` (default) or `runtime`. |
| `PDSH_VFS_ROOT` | Real directory backing virtual `/`; the Worker leaves it unset (`/` is the VFS) and tests/coverage point it at a temporary directory. |
| `PDSH_SHELL_TIMEOUT_MS` | Per-command wall-clock limit (default 120 s). |
| `PDSH_SHELL_MAX_OUTPUT_BYTES` | Per-stream head/tail cap (default 256 KiB). |
| `PDSH_THERMAL_STATE` | `nominal`/`fair`/`serious`/`critical`; subprocess-xl lowers its cap to 1 while not nominal. The host sets it at Worker start; a later host signal uses `ExecutionGovernor.setThermal()`. The LIFECYCLE (`0x50`) payload carries no thermal field (`channel.md` §4.5). |

## What runs where

- **`bash -c`** → `subprocess-xl` → `WorkerShell` → just-bash over
  `VfsFileSystem` → `node:fs` (the Worker `MemoryVfs`). Every write is therefore
  a normal VFS mutation and reaches the sink at the next `mseq` — except the
  virtual device files below, which never touch the VFS.
- **`bash SCRIPT` / `sh SCRIPT` / `bash -n` / `bash --version`** → the
  `bash`/`sh` commands in `src/interpreter.ts` own the whole invocation surface
  instead of the bundled command (which reads every non-`-c` first word as a
  script filename and runs scripts through a nested interpreter whose output
  accounting the engine rejects with exit 126). The script is resolved (the
  literal path, then each `PATH` directory), read and run through the same
  fresh-`Bash` path as `bash -c`, with `$0` = the resolved script path and
  `$1...`/`$#`/`$@`/`$*` set; `-n` parses with the engine's parser and exits
  0/2; `-e`/`-u`/`-x` (alone or clustered as `-eux`) become one `set -eux`
  prelude executed by the engine's own `set`; `--version` prints one version
  line; `--` ends option parsing; an option this layer does not implement exits
  2 with a usage diagnostic and is never read as a filename. `/bin/bash`,
  `/bin/sh`, `/usr/bin/bash` and the shebang exec path all reach the same core.
- **`bash -c '...' _ ARG`** → the words after the `-c` string are `$0`/`$1...`
  (default `$0` is the shell name), and the same binding is what lets the
  built-in `find -exec sh -c '...' _ {} \;` see each matched path as `$1`.
  `find`'s traversal and `-exec` argv handling stay entirely in the built-in;
  the shim only owns `-type`/`-printf`.
- **Arithmetic `$(( ))` / `(( ))`** → just-bash 3.6.0's arithmetic AST keeps a
  `${...}` operand as a de-facto variable name: `${x#0}` and `${clock:0:2}`
  reach the nounset check as `x#0` / `clock:0:2`, and a plain `${x}` after a
  `10#` prefix is concatenated through that prefix's NaN token (`NaN02`).
  `WorkerShell` registers the public `TransformPlugin` from `src/arithmetic.ts`
  on each fresh shell; it expands only the operands the engine would
  mis-evaluate with the shell's own parameter-expansion path before the command
  runs, converts `10#`/`16#`/dynamic `${base}#` values with the hidden
  `__xl_arith_base` helper, and leaves every other arithmetic expression (and
  the engine's `$x` pre-expansion path) untouched. For an `(( ))` command the
  transform also checks the operands the expression reads (in evaluation order,
  tracking assignments) before the command: when `set -u` is active and one is
  unset it exits the shell with bash's `unbound variable` diagnostic, the way a
  non-interactive bash aborts. The engine alone downgrades that error to an
  ordinary command failure, which lets `set -euo pipefail` skip the dependent
  command and continue (G2-A06). The check uses the nounset-safe `${name+set}`
  form and `$-`, so it never expands the operand itself; `$?` is captured
  before the prelude, and an `(( ))` command's other arithmetic errors
  (division by zero, bad base digits, syntax) stay non-fatal command failures
  the way bash's `(( ))` handles them. C-style
  `for ((init; cond; update))` expressions are evaluated inside the loop node
  and keep the engine's pre-fix behavior; ordinary `$(( ))` in loop bodies is
  covered.
- **Script files (`bash script.sh`, `./script.sh`)** → `WorkerShell` reads an
  executable shell file from the VFS and runs its source through the same
  interpreter construction as `bash -c`, with `$0`/`$1`... supplied; a file
  without the execute bit still fails as `Permission denied` (126), and a
  materialised command entry keeps the engine's registered-command dispatch.
  `subprocess-xl` routes a path-form argv to the Worker shell instead of the
  engine's bare path executor, which does not carry the transform plugins or
  the command table — one arithmetic code path for all three dispatch forms
  (G2-FIX-66). For a file script only, `WorkerShell` registers the transform in
  `src/bash-source.ts`, so `${BASH_SOURCE[0]}`, `$BASH_SOURCE`,
  `${BASH_SOURCE[@]}` and `${BASH_SOURCE[*]}` resolve to the same path as `$0`
  (G2-FIX-87). `bash -c` deliberately keeps GNU's unset top-level value;
  `source` nesting and `BASH_SOURCE[1+]` are not modelled.
- **`trap`** → the real EXIT-only builtin in `src/trap.ts`. `trap HANDLER EXIT`
  (or `0`) stores one handler; `trap -`/`trap ''` clears it; `trap -p` and
  `trap -l` report it; every other signal exits 2 with the
  `unsupported-option` trailer instead of pretending to install it. The handler
  runs after the root script returns against the patched engine's authoritative
  terminal state (`src/terminal.ts`): the real cwd (separate from the `PWD`
  variable), global env, shell options, global functions/arrays and the last
  pipeline statuses, restored from the engine's non-enumerable snapshot. There
  is no AST checkpoint or stderr-text guess. `$?`/`PIPESTATUS` are seeded from
  that state; a command-level assignment prefix is unwound before the handler
  runs, and function locals (including local arrays), command-substitution
  namespace changes and pipeline children never leak into it. Trap storage is
  keyed by the engine's real shell scope, so a subshell, pipeline child or
  command substitution cannot clear or replace the root handler; a child EXIT
  action is discarded with its scope. An explicit
  `exit N` in the handler changes the command status; a handler that merely
  fails keeps the script's original status. The handler remains inside the
  command's wall clock and abort surface, so a slow handler maps to 124 and a
  caller cancellation to 130. Engine limits, cancellation, parse/security
  failures and unknown engine exceptions do not run it and keep their original
  failure with one `reason=backend-failed` trailer. `type trap` remains the
  engine's `shell builtin` answer, which is now true (G2-FIX-107).
  `source`-nested scripts and asynchronous signal delivery are outside this
  surface.
- **`find -type`** → a shim shadows just-bash's built-in `find`, whose parser
  accepts only `-type f` and `-type d`. The shim keeps the full POSIX set
  (single letters and comma lists of b,c,d,f,l,p,s): `f`/`d` semantics stay in
  the built-in, lists are narrowed to the letters this symlink-free VFS can
  contain, and a list with only impossible letters never matches (`l`, `b`,
  `c`, `p`, `s`). All other argv — including `-exec` command words — is passed
  through untouched; invalid type values keep the built-in's error.
- **`grep -I` / `--binary-files=without-match`** → a shim shadows just-bash's
  built-in `grep`, whose option parser has no binary-file option. `-I` is
  accepted alone and inside a combined short cluster (`-RIn`), and the long
  spelling is accepted too. Every invocation without the option delegates to
  the built-in unchanged. With the option, the built-in runs in a nested
  `Bash` over a read-only view of the VFS that reads NUL-containing files as
  empty, so the built-in's own parser, traversal, `--include`/`--exclude`
  filters and output formatting stay authoritative while the file is treated
  as containing no matching data (GNU's `without-match` rule). A direct
  `spawn(['grep', ...])` is routed to the same table.
- **`stat -c`** → a shim shadows just-bash's built-in formatter, which renders
  only `%n %N %s %F %a %A %u %U %g %G` and echoes every other directive
  literally with exit 0. The shim renders the GNU directive set this shell uses
  from `FsStat` (`%n %N %s %b %B %i %d %D %a %A %F %h %u %U %g %G %x %X %y %Y
  %z %Z %t %T`, `%%` and the `\n`/`\t`/`\\` escapes). `%b` counts 512-byte
  blocks (`ceil(size / 512)`, the same value `find -printf '%b'` reports) and
  `%B` is the 512 block-size unit. `--format`/`-c` keeps one trailing newline
  per operand; `--printf FORMAT`/`--printf=FORMAT` shares the parser and
  concatenates rendered operands without adding a newline, and the last format
  option on the command line wins. The VFS reports one timestamp, so `%x`/`%z`
  fall back to mtime; ownership, hard-link count and device type are documented
  constants; a directive the shim does not implement fails loud with
  `stat: unsupported format specifier ...` and exit 2. The default no-`-c`
  listing is delegated to the built-in unchanged. A direct `spawn(['stat',
  ...])` is routed to the same table.
- **`ls -l`** → a shim over just-bash's long format, whose first column is a
  constant (`-rw-r--r--` for every file, `drwxr-xr-x` for every directory and
  for `.`/`..`) instead of the VFS mode: after `chmod 600 f`, `stat -c '%A' f`
  said `-rw-------` while `ls -l f` still said `-rw-r--r--` (G2-FIX-75). The
  shim keeps the built-in's columns (`user user`, the five-character size
  field, `total N` and the `Mon DD HH:MM`/`Mon DD  YYYY` timestamp), sorting,
  headers and diagnostics; only the first column, size and mtime now come from
  the same `IFileSystem.lstat` the `stat` shim reads, and the symbolic mode is
  `formatSymbolicMode(stat)` (one permission formatter, never a second copy).
  The `.`/`..` rows are real stats, so a 700 directory lists as `drwx------` in
  both `ls -ld` and `ls -la`. `-l` with the common combinations
  `-la`/`-al`/`-A`/`-d`/`-h`/`-r`/`-R`/`-S`/`-t`/`-F`/`-1` and `--` is
  supported; every non-long invocation (`ls`, `ls -a`, `ls notes`, `--help`,
  and any option the built-in rejects) is delegated to `ctx.origCommand`
  unchanged, so short listings and their error bytes do not move. A direct
  `spawn(['ls', '-l', ...])` is routed to the same table.
- **`rmdir`** → a shim because the pinned runtime's `node:fs` replacement
  implements `rm`/`unlink` but not `rmdir`/`rmdirSync`
  (`webworker-runtime/src/node/builtin_modules/implemented/fs.ts:291-300,841-842`):
  just-bash's built-in reached the adapter's directory branch and died with
  `rmdir: failed to remove '<dir>': this.nodeFs.rmdir is not a function` while
  `rm -rf` on the same directory worked (G2-D06). The shim removes exactly one
  empty directory per operand, left to right (`-p` walks the now-empty
  ancestors, `-v` reports each), fails `ENOTEMPTY`/`ENOENT`/`ENOTDIR` with the
  errno named, and leaves a populated tree untouched. Each success is the
  backend's normal remove mutation (VFS op 3), so the WAL and the materialized
  copy see it exactly like `rm -r`. The adapter's own `rm` no longer calls the
  missing `node:fs.rmdir` either, so `find -delete` on an empty directory takes
  the same path.
- **`cp -a` / `-p` / `-d` / `--preserve`** → a shim over just-bash's bundled
  `cp`. The bundled parser rejects `-a` and `-d` (G2-FIX-98) and accepts `-p`
  without ever consuming it: a mode survived only because the adapter's
  `node:fs.cp` happened to copy it, with no explicit owner/timestamp step and
  no regression constraint. The shim keeps the bundled command as the copy
  engine (`ctx.origCommand`), so path resolution, error bytes and `-n`/`-v`
  output stay the built-in's, accepts `-a`/`--archive` (recursive + preserve
  all + no-dereference), `-p`/`--preserve`, `-d`/`--no-dereference` and
  repeatable `--preserve=mode,ownership,timestamps,links,all`, then restores
  each target's mode through an explicit `ctx.fs.chmod` (VFS op 4) and its
  timestamp through `ctx.fs.utimes`. Files are restored before directories and
  directories deepest-first, so a changed directory mode cannot break a later
  write. An invocation without an archive/preserve/no-dereference option is
  delegated with its original argv unchanged. Ownership and hard links are
  documented Worker VFS constants (there is no owner and no link object); `-d`
  is accepted on the symlink-free VFS and fails loud, rather than silently
  following, if a backend really has a symlink. An invalid `--preserve`
  attribute fails as `cp: invalid argument '<x>' for '--preserve'` and creates
  no target.
- **`cmp`** → the Worker's POSIX byte comparison over the VFS (the engine has
  no `cmp` built-in at all). `cmp a b` reports the first difference as
  `<a> <b> differ: char <offset>, line <line>` and exits 1; identical files are
  silent with exit 0; a shared prefix with different lengths reports
  `cmp: EOF on <shorter file>` on stderr and exits 1; `-s` is status-only
  (0/1, silent even for the EOF case, though a directory operand is still
  diagnosed, as the host does) and `-l` lists every differing byte as
  `<offset> <octal1> <octal2>`; the host's missing-operand usage line is exit 2.
  The diagnostics are the host program's bytes — the command keeps the
  POSIX/GNU surface a script parses instead of adding an `pdsh-shell:` trailer —
  and the vectors in `tools/shell-corpus/golden/worker-shell.jsonl` are
  generated from `/usr/bin/cmp` by `tools/shell-corpus/cmp-golden.mjs`. A direct
  `spawn(['cmp', ...])` is routed to the same command table.
- **`sort -z`** → the Worker shadow over just-bash's `sort`. Without `-z` every
  invocation is delegated to the bundled program unchanged; with
  `-z`/`--zero-terminated` it parses `-r -n -u -f -b -o`, `--` and combined
  clusters (`-rz`), splits each input source into NUL records separately, sorts
  and terminates each output record with NUL, so
  `find -print0 | sort -z | xargs -0` works. `-u` compares keys only (numeric,
  folded or blank-stripped as selected) and keeps the first input record of an
  equal-key run; a read error suppresses all output. `-k` and `-t` are refused
  with exit 2 because the bundled key grammar is outside this surface.
- **`du`** → the Worker shadow over just-bash's `du`: `-h`/`--human-readable`,
  `-a`, `-s`, `-c`, `--max-depth=N`, `--` and operands. Sizes are 4 KiB
  allocation blocks (empty files 0, non-empty files a whole number of 4096-byte
  blocks), so `du -h` prints `4.0K` for a five-byte file, `1.0M` for 1 MiB, and
  a missing operand is GNU's `du: cannot access '<name>': ...` with exit 1.
- **`od`** → a shim over just-bash's built-in, which parses `-N` but formats
  the whole operand: `od -An -tx1 -N4 big` over a legal large file exhausted
  the engine's format-work budget and exited 126. The shim applies
  `-N`/`--read-bytes` and `-j`/`--skip-bytes` to the concatenated operands
  (files wholly before the window are stat-skipped), then formats only the
  window. Long options accept GNU's unambiguous prefixes, so `--skip` and
  `--skip=4` select `--skip-bytes`. `-t x1`, `-t o1`, `-t c`, `-c`,
  `-A d/o/x/n`, `-An` and `-v` are supported; another format is an explicit
  exit-2 usage error, never a silent whole-file dump. A direct
  `spawn(['od', ...])` reaches the same table.
- **GNU argv conventions** → `src/gnu-conventions.ts` is the single owner of
  `--`, `--version` and `--help` for the registry in
  `GNU_CONVENTION_PROGRAMS` (`sha256sum`/`sha1sum`/`md5sum`, `head`, `tail`,
  `cut`, `sed`, `find`, `chmod`, `jq`, `date`, `comm`, `xargs`, `od`, the
  file-operand coreutils, `sort`, `du`). A non-matching invocation delegates
  unchanged; `--version` answers `<name> (just-bash) 3.6.0`; `--help` preserves
  a native non-empty help and otherwise returns a non-empty usage with exit 0;
  a per-program value-arity table finds the real end-of-options (so
  `find . -name --` and `sort -o -- f` keep the literal `--` as a value), file
  operands that begin with `-` are read as `./-...`, and an option-shaped
  sed/jq script/filter after `--` fails instead of being re-read as an option.
  `echo`/`printf` keep their literal `--version` output.
- **Advertised accelerator** (`rg`, `jaq`, `ts-parse`, `ts-query`, `phone`,
  `ctx`) inside a script → a just-bash command definition calls the exec bridge
  with `requires_mseq` (the sink revision at dispatch) and the exec.md §1
  `idem_key`. A name the host did not advertise keeps running Worker-local
  (for example the Worker `rg` shim over just-bash's built-in).
- **Direct `spawn` of a program path** → `subprocess-xl` resolves argv[0] to its
  program identity before routing. DSH's `tool-fs-search` spawns the packaged
  ripgrep as the absolute path from `resolveRgPath()`
  (`@vscode/ripgrep*/bin/rg`, or the `<executable>-rg` sidecar); that shape
  becomes the `rg` program, so an advertised `rg` produces one EXEC_REQ 0x20
  with the bare argv and an unadvertised one runs the Worker `rg` shim. A glob
  search (`--glob`/`--iglob`) reaches the shim untouched so the shim owns the
  translation, the globset and the `--sort=modified` ordering; every other
  search translates only the flags just-bash documents as unsupported
  (`--no-config` is dropped — there are no config files — and
  `--sort=modified` becomes `--sort=path`); a path outside every known program
  still falls through and fails loud. A direct `spawn(['find', ...])` is routed
  to the same `find` command table as `bash -c 'find ...'`, so both forms share
  the `-type` behavior above instead of the runtime's unshimmed built-in.
- **Worker `rg`** → a shim over just-bash's built-in `rg`. The built-in still
  lists files, applies ignore/hidden rules, matches regexes and encodes
  `--json`; the shim removes `--glob`/`--iglob` from the delegated argv and
  applies ripgrep's globset contract afterwards. A leading `**/` matches zero
  or more path components, a glob without `/` matches basenames at any depth,
  include and `!` exclude globs combine (later wins), and a negated directory
  glob prunes its contents. `--sort=modified` is re-applied to the filtered
  list, so the result keeps modification-time order. That is what DSH's `glob`
  (`--files --glob=…` plus the `!**/.git`/`!**/.git/**` pair) and the `grep`
  include filter rely on; invalid globs fail loud with ripgrep's
  `error parsing glob` wording.
- **`gzip` / `gunzip` / `zcat`** → the Worker codec, not just-bash's built-in.
  The built-in calls `node:zlib`, which the browser Worker deliberately stubs
  with `notImplementedFail`; the Worker codec resolves one backend explicitly
  (Web `CompressionStream`/`DecompressionStream` first, a real `node:zlib`
  second), parses the RFC 1952 container itself (optional header fields,
  concatenated members, CRC32/ISIZE trailer), and fails loud with exit 1 and
  stderr when the input is corrupt or no backend produces a valid member. A
  checksum failure keeps the bytes decoded before the trailer check; an empty
  output is never reported as success.
- **`tar`** → a POSIX ustar implementation over the VFS: `-c/-t/-x`,
  `-z` (through the same portable gzip backend as `gzip`), `-f ARCHIVE`
  (including `-`), ordered `-C DIR`, `-v` and GNU long options. A leading `/`
  is stripped from member names and extraction refuses `..` and absolute
  names. GNU long-name (`L`) and pax (`x`) records are understood when reading
  an archive another tool produced; a name too long for a ustar prefix/name
  split fails loud instead of being truncated. just-bash's browser bundle
  excludes `tar` entirely (exit 127), so this is the only implementation.
- **`realpath` / `readlink`** → GNU canonicalisation over `IFileSystem`.
  `realpath` did not exist; just-bash's `readlink` rejects `-m`. Both now
  support the default “all but the last component must exist” mode, `-e`
  (all must exist), `-m` (none need exist), `realpath -s` (no symlink
  resolution) and `realpath --relative-to`. Symlinks are resolved through the
  backend, so the symlink-free Worker VFS gets the normalised absolute path
  while a host backend with symlinks keeps POSIX behaviour.
- **`awk`** → just-bash's awk language behind the missing POSIX/GNU command
  line: `-f PROGRAM-FILE` (repeatable, concatenated in order), `-F`, `-v`,
  `--posix`/`--traditional` (accepted; the built-in is the POSIX subset),
  `-V`/`--version` and `--help`. A missing program file fails loud with exit 2.
  The language and `gsub`/`sub`/`split` stay in the imported built-in.
- **`find -printf`** → the `find` shim rewrites one `-printf FORMAT` to
  `-print0` and renders the format from `FsStat` for each matched path, so
  `%y`, `%Y`, `%s`, `%m`, `%M`, `%p`, `%P`, `%f`, `%h`, `%d`, `%i`, `%n`,
  `%b`, `%k`, `%u`, `%g`, `%U`, `%G`, `%l`, `%t`, `%T@`, `%T+`, `%a`, `%c`,
  `%%` and the `\n`/`\t`/`\0` escapes expand instead of being echoed
  literally. An unsupported directive fails loud (exit 1); multiple
  `-printf` actions are refused because the shim cannot tell which OR branch
  matched. Traversal, predicates and `-exec` stay in the built-in.
- **`command -v` / `PATH`** → the shell exposes its command table as virtual
  `PATH` entries. `VfsFileSystem.registerCommandNames([])` creates `/usr/bin`
  and `/bin` in memory, and the adapter's `writeFileSync` records exactly the
  commands just-bash instantiates while it constructs the interpreter — a
  browser-excluded name never gets an entry it cannot run. `command -v X` and
  `type X` therefore return a path that exists and is executable, and
  executing it reaches the same registered command through just-bash's
  `/usr/bin/<name>` identity rule. No file is written, so the real VFS tree
  and `getAllPaths()` keep only what the user wrote. `PATH` is sanitised per
  command: a directory the VFS does not have is dropped instead of advertised.
  `which` follows the same rule and exits 1 for a name no directory contains —
  it never fabricates `/usr/bin/<name>`.
- **`curl`** → one `POST /v1/http` per request, with `X-PDSH-Target-URL`,
  `X-PDSH-Target-Method` and the channel bearer. GET, HEAD, POST, `-H`, `-d`,
  `-o`, `-s`, `-S`, `-L`, `-f`, `-w`, `--max-time` and `--retry` are supported;
  any other method or flag fails with exit 2. A host that does not allow the
  origin answers 403 and the shim surfaces exit 22 — there is no second path.
- **Output** is always `TERM=dumb NO_COLOR=1 LANG=C.UTF-8 LC_ALL=C.UTF-8` plus
  `PAGER=cat GIT_PAGER=cat CLICOLOR=0 FORCE_COLOR=0`. Each stream is capped by
  keeping a head and a tail and naming the elided byte count. The engine's
  `executionLimits.maxOutputSize` is a memory bound for one command result
  (`MAX_FILE_SIZE + maxOutputBytes`), not this visible cap: a legal file may
  pass through a pipeline stage (`cat big | wc -c`), while a stream that really
  exceeds `maxOutputBytes` still exits 1 with `reason=output-truncated`.
- **Cancellation** is cooperative (just-bash checks the abort signal at
  statement boundaries); a wall-clock expiry returns 124, a caller abort 130.

## Class contract: exit taxonomy and stderr trailers

`src/contract.ts` is the one place the assembled command surface states what a
failure looks like. It matters because the upstream `tool-bash` merges stderr
into the tool result text: a line here is what the model (and the journal) can
act on without a DSH patch.

| Reason token | Meaning | Status |
| --- | --- | --- |
| `not-available` | the Worker does not serve this program | 127 |
| `command-exited` | a Worker program ran and returned its own non-zero status; its stderr is the explanation | the command's own |
| `unsupported-option` | known command, option/directive outside its Worker surface | 2 |
| `limit-refused` | a budget (single-file limit, output cap) refused the write | 1 (or the command's own) |
| `output-truncated` | the head/tail cap cut the captured stream | 1 |
| `backend-failed` | the Worker's own execution substrate failed (missing engine built-in or codec, a toolbox dispatch that threw, the nesting budget) | 1 (or the command's own) |
| `network-denied` | no route outside the host `/v1/http` allow-list | curl's own 7/22/23 |

The three-way split is the contract, not a style choice: `not-available` says
the program is not here, `command-exited` says it ran and exited, and only
`backend-failed` says our layer broke. A command that exits non-zero with its
own stderr is never labelled `backend-failed` (G2-FIX-58: `stat` on a missing
file used to say the execution backend had failed). `classifyFailure` is the
fallback owner for a result that names no finer token, and it answers
`command-exited`.

Every failure pads stderr with exactly one line:

```text
pdsh-shell: exit=127 program=unzip reason=not-available hint=no archiver program in the Worker; /dsh/home/capabilities.json lists tar/gzip
```

The trailer is idempotent (`appendShellTrailer`), parseable
(`parseShellTrailer`) and the hint is free text to the end of the line. The
program-availability registry is diagnostic only: it is not a fake `Command`,
because registering a no-op `unzip` would make `command -v unzip` report a path
that cannot run — the G2-A05 fabricated-path defect. The shell therefore keeps
the not-found path and appends the hint to the engine's own 127.

Every path a hint names must exist. The Worker boot entry publishes the full
`pdsh-capabilities/1` document at `/dsh/home/capabilities.json` from the real
command registry (`workerCommandSurface`: just-bash's instantiated table, the
Worker shadows, the installed toolbox's `python3` and the session's HELLO
accelerators) before the first request (ENG-05). That document is the single
owner of the path: `src/capabilities.ts` adopts any manifest already there and
never rewrites it, so a `bash -c` step cannot replace the environment priors
(command table, limits, Python modules, egress, bash deviations) with the
minimal program list. The shell writes the fallback
`{format: 1, programs: [...]}` document only when no boot entry ran — a bare
`WorkerShell` in the desktop tests — and the path is absent. A backend that
cannot make the path exist yields no path at all: `unavailableHint(program,
null)` strips the manifest clause instead of advertising a referent that is not
there. G2-FIX-58 fixed the dangling referent the G2-A09 run chased (the 127
hint named this file and the model's `read` answered `not found`).

The manifest decision is memoised for one `WorkerShell` instance
(`manifestReady`): the first bootstrap decides whether the hint may name the
path, and a failed first materialisation is not retried inside that session.
The safe direction is deliberate — later hints omit the path rather than
advertise one that may not exist — and the next shell evaluates it again (every
`bash -c` step builds a fresh `WorkerShell`; a planned restart, D24, is just
the explicit case). In production the boot publisher always creates the file
first, so the failure case is a read-only embedding, not a phone boot.

The counterpart is the "never silently lie" rule. A cut stream is incomplete
data, so `WorkerShell` turns the command's 0 into 1 and appends
`reason=output-truncated`; a gzip with no backend exits 1 and writes no member;
`stat -c '%Q'` and `find -printf '%q'` are usage errors (2, not a literal echo
with 0); a short corrupt tar archive is an error instead of an empty listing;
`realpath -z` separates records with NUL; an invalid ripgrep glob is exit 2, not
"no matches". `cmp` is the third deliberate exemption from the trailer: its
usage line, `EOF on` line and open diagnostics are the host program's bytes,
so `tools/shell-corpus/contract.mjs` keeps it out of `TRAILERED_PROGRAMS` and
the `cmp-golden.mjs` vectors compare those bytes exactly.

`tests/shell-ext-contract.test.ts` pins the 127 snapshot and the taxonomy;
`tests/shell-ext-taxonomy.test.ts` pins the three-way split (`not-available` /
`command-exited` / `backend-failed`) and the referent's existence;
`tests/shell-ext-manifest-owner.test.ts` pins the combined path the repair
round added — boot publish, a `bash -c` step, then a Worker rebuild over the
persisted home, with the boot document byte-identical throughout;
`tests/shell-ext-cmp.test.ts` runs the committed host-generated `cmp` vectors
through the production table and keeps the pre-fix 127 visible;
`tests/shell-ext-tar-host.test.ts` checks the Worker tar/gzip bytes against the
host's bsdtar and the reference zlib, creates the comparison archive with
`COPYFILE_DISABLE=1`, and compares payload members only, so macOS AppleDouble
sidecars (`._name`) cannot make the gate depend on the filesystem's xattr
state; `tools/shell-corpus/contract.mjs` audits the corpus and the A05 probe
sequence (every answer definitive, no 127 without the manifest hint, no 0-byte
success) and runs `tools/shell-corpus/probe-budget.mjs`, which compares the
recorded 26-request first-batch probe cost with the fixed surface's 9
definitive answers (0 ambiguous, A05 deliverable complete).

### Recorded deviations from the work-package mechanism

Two items in the class-contract mechanism are deliberately not implemented
literally. Both are recorded here for the upstream/ENG-05 manifest rather than
silently ignored:

- **Mechanism (2) "register an explicit shim" for unregistered programs.** The
  observable contract is the same - 127 plus one remediation line pointing at
  `/dsh/home/capabilities.json` - but it is a diagnostic trailer, not a
  registered no-op `Command`. Registering `unzip` would make `command -v unzip`
  answer a path that cannot execute, which is exactly the fabricated-path lie
  that burned the G2-A05 probe budget (see `command-paths.ts`). The trailer is
  the smallest shim that keeps `command -v` truthful.
- **Mechanism (8) `/tmp` -> `/dsh/tmp` alias consumed from ENG-01's
  `VfsNamespace`.** `VfsFileSystem` still owns `WORKER_TMP_ALIAS`
  (`filesystem.ts`); moving it behind `VfsNamespace` is tracked with ENG-01 and
  is not part of this work package's seven acceptance criteria.

## Device files

just-bash opens every redirection target through `IFileSystem`; it has no
separate device-file layer. The Worker VFS is the runtime's `MemoryVfs` behind
a `node:fs` face and has no `/dev` tree (it cannot create one outside the
`/dsh` roots), so the adapter answers the fixed device set itself
(`WORKER_DEVICE_PATHS`, now `["/dev/null", "/dev/zero", "/dev/urandom"]`):

| Operation | `/dev/null` | `/dev/zero` | `/dev/urandom` |
| --- | --- | --- | --- |
| `writeFile`, `appendFile` (and `cp` to the device) | discarded before `node:fs`; no sink mutation, no `VFS_MUT` | same | same |
| `readFile`, `readFileBytes`, `readFileBuffer` | empty | `WORKER_DEVICE_READ_BYTES` (1 MiB) of `0x00` | `WORKER_DEVICE_READ_BYTES` (1 MiB) of crypto-random bytes |
| `cp` from the device | writes an empty file | writes the 1 MiB zero window | writes the 1 MiB random window |
| `exists` | true | true | true |
| `stat`, `lstat` | character device: mode `0o020666` (`S_IFCHR` plus `0666`), not a file, not a directory, size 0 | same | same |

That makes `>`, `>>`, `2>`, `2>&1`, `<`, `&>` and `&>>` (and a command's own
open) work without a real file. The devices are virtual: they never appear
below the VFS root and `getAllPaths()` does not list them. A path outside the
set (`/dev/stdout`, `/dev/stderr`, `/dev/nonexistent`, ...) keeps the normal
`node:fs` path and fails loud; `IFileSystem` has no shell-stream concept, so
answering those here would silently lie. just-bash still maps `> /dev/stdout`
and `2> /dev/stderr` itself at the redirection layer.

### The bounded device read window

`IFileSystem` has no streaming read, so `/dev/zero` and `/dev/urandom` cannot
be infinite the way POSIX devices are. Every read surface returns exactly
`WORKER_DEVICE_READ_BYTES` (1 MiB) and then reports EOF. `head -c 4 /dev/zero`
gets the 4 bytes it asked for; `cat /dev/zero` terminates after the 1 MiB
window, and because the default per-stream output cap is 256 KiB that
particular command is a truncated stream (exit 1 with `reason=output-truncated`)
rather than an infinite one. The window is a documented boundary of the
`IFileSystem` surface, not a hidden special case: a caller that needs more
reads the device again.

`/dev/urandom` uses `globalThis.crypto.getRandomValues` in 64 KiB chunks and
fails loud (`ENOSYS`) when the Worker has no crypto source. It never falls back
to `Math.random`. `/dev/null` stays byte-for-byte the pre-G2-FIX-112 device:
empty on every read, including `cp`.

## The single-file limit

`writeFile` and `appendFile` enforce the configured single-file budget before
`node:fs` runs. The budget is the shared value owned by the WASI toolbox's
`src/limits.ts`: 64 MiB by default, the host's `PDSH_SINGLE_FILE_LIMIT_BYTES`
(clamped to 16–128 MiB) when present, or an explicit `maxFileSize`. A complete write above the limit, or an append whose
post-write size would exceed it, throws an `EFBIG` whose message names the
target, the would-be size and the limit:

```
EFBIG: File too large: /dsh/workspace/big.bin would be 33554432 bytes; a file is limited to 67108864 bytes (64 MiB)
```

The byte count and the MiB label are rendered from the same enforced value by
the owner's `formatByteLimit`, so a 64 MiB budget can never be described as
`(15 MiB)`. `VfsFileSystem.maxFileSize` exposes that value, and the shell's
`limit-refused` trailer hint reads it instead of carrying a literal.

The shell turns that into the command's own error: non-zero exit and the text
on stderr. The ordered channel stays open, so the next command runs normally.
Concurrent `appendFile` calls to one target are serialised per real path
(stat→append is one critical section), so two appends cannot both pass the
pre-write check and jointly cross the limit.

The would-be size in that message is a conservative upper bound. For
`binary`/`latin1`/`ascii` text the adapter counts the maximum of the declared
encoding's byte length and UTF-8, because the Worker's `node:fs` proxy ignores
a string encoding and stores UTF-8 while a real `node:fs` root would use the
declared one. A refusal may therefore name a size slightly larger than the
`node:fs` write would have stored; it never under-counts a mutation the sink
could see.

The runtime's `MemoryVfs` publishes a mutation synchronously inside the write
and swallows observer failures, so a size guard on the sink side can only close
the ordered channel *after* the bytes are already in the Worker tree. That is
what left a `yes ... >> file` tool call without a result (G2-A09). The sink's
15 MiB payload guard remains as the last-resort backstop for writers that do
not go through this adapter. The WASI toolbox's `NodeFsBackend` enforces the
same cap, because `python3` and other WASI programs write through that adapter
rather than this one.

## Coverage

The public corpus has 428 commands. `coverage/just-bash.mjs` implements the
runner interface of `tools/shell-corpus/coverage.mjs`; every command gets a
fresh copy of the same demo workspace the `runtime-js` evaluator uses.

```sh
node tools/shell-corpus/coverage.mjs \
  --runner just-bash \
  --corpus tools/shell-corpus/corpus/public.jsonl \
  --out "$TMPDIR/pdsh-cov" --threshold 95
```

Measured in this worktree (macOS arm64, Node 24.19) on 2026-10-25:

| Mode | ok | % | command-missing | runtime-error |
| --- | ---: | ---: | ---: | ---: |
| `host` (the gate) | 425 / 428 | **99.3%** | 0 | 3 |
| `real` (`PDSH_SHELL_CORPUS_MODE=real`) | 210 / 428 | 49.1% | 215 | 3 |

`host` mode registers a deterministic success stub for every external program
the corpus names but the Worker cannot implement. Each stub writes on stderr
that it did not run. This is the same method as the brush spike's
`PDSH_BRUSH_MODE=stub`: it measures the **shell language and command table**, not
whether `npm install` or `git clone` works in the Worker. `real` mode measures
only commands that actually run.

The three `host`-mode misses are deliberate:

| Command | Why |
| --- | --- |
| `! true` | Correct bash exits 1; the coverage tool counts a non-zero status as `runtime-error`. |
| `curl -X PUT ...` | The shim refuses methods outside GET/HEAD/POST (exit 2). |
| `curl -X DELETE ...` | Same. |

### Remaining gaps (real implementations)

`real` mode's 215 missing programs are the long tail the Worker does not have.
The runner stubs them in `host` mode, and `createCorpusHostCommands` lists them:

| Group | Programs | Status |
| --- | --- | --- |
| Git | `git` (64 commands) | The Worker program from `wasi-toolbox/git` is in the production table: the eight `workspace-changes` subcommands plus porcelain. `rebase`/`stash`/`submodule` name the remote offload path instead of running. |
| JS/package managers | `npm`, `pnpm`, `npx`, `yarn`, `bun`, `deno`, `node` | Not implemented. Network and native-tool dependencies; a Worker cannot install packages. |
| Rust/Go/Apple/JVM | `cargo`, `rustc`, `go`, `gofmt`, `swift`, `xcodebuild`, `gradle`, `mvn`, `dotnet`, `bazel`, `cmake`, `make` | Not implemented; out of the Worker budget. |
| Python | `python3`, `python`, `pip`, `uv`, `pytest`, `tox`, `ruff`, `mypy`, `black`, `bundle`, `gem`, `composer`, `flutter`, `docker`, `brew`, `apk`, `apt-get` | `python3` is served by the WASI toolbox once the CPython-wasi artifacts are staged (`wasi-toolbox/python`); the rest stay host tools. |
| Linters/test runners | `tsc`, `vitest`, `jest`, `playwright` | Resolve through the package-manager gap above. |
| Network clients | `wget`, `openssl`, `ssh`, `ssh-keygen`, `scp`, `rsync`, `ping`, `nc`, `dig`, `nslookup`, `host`, `telnet`, `http`, `xh` | Only `curl` is wired to `/v1/http`; the others have no Worker transport. |

Everything outside that table is real: bash syntax, coreutils, text tools,
`find`/`glob`, compression, `jq`'s WASI engine and its fallback shim, `yq`, `sqlite3`, `curl`, the accelerator
bridge, and the VFS adapter.

## Layout

| Path | Role |
| --- | --- |
| `src/filesystem.ts` | `VfsFileSystem`: just-bash `IFileSystem` over `node:fs`, plus the virtual `/dev/null`, `/dev/zero` and `/dev/urandom` devices. |
| `src/shell.ts` | `WorkerShell`, `bash -c` / direct argv, discipline env, timeout, cancellation. |
| `src/interpreter.ts` | The `bash`/`sh` invocation surface: `-c`/`-e`/`-u`/`-x` option parsing, script/stdin plans, syntax check, version and usage. |
| `src/bash-source.ts` | File-script `BASH_SOURCE` transform: rewrites the operation-free `${BASH_SOURCE[0]}` forms to `${0}`. |
| `src/trap.ts` | The real EXIT-only `trap` builtin, its per-execute handler store and the unsupported-signal boundary. |
| `src/terminal.ts` | Validation and typing for the patched engine's authoritative terminal state and handler snapshot. |
| `src/arithmetic.ts` | Arithmetic `$(( ))` parameter-expansion transform and its hidden base converter. |
| `src/output.ts` | Head/tail byte cap and the elision marker. |
| `src/bridge.ts` | `defineCommand` accelerator bridge with `requires_mseq` + `idem_key`. |
| `src/curl.ts` | `/v1/http` curl shim. |
| `src/find.ts` | `find` shim that keeps the full POSIX `-type` grammar over just-bash's built-in. |
| `src/grep.ts` | `grep` shim for `-I` / `--binary-files=without-match`: skips NUL-containing files while keeping the built-in's option parser, traversal and output. |
| `src/gzip.ts` | `gzip`/`gunzip`/`zcat` codec: one resolved backend (Web Compression Streams, then `node:zlib`), RFC 1952 container parsing (optional headers, concatenated members, CRC32/ISIZE trailer), roundtrip validation, fail-loud errors. |
| `src/tar.ts` | POSIX ustar `tar` over the VFS; `-z` uses the gzip backend. |
| `src/path-commands.ts` | `realpath` and the GNU `readlink` modes (`-f/-e/-m/-n/-z`). |
| `src/awk.ts` | `awk` command line: `-f` program files, `-F`/`-v`, GNU switches. |
| `src/cmp.ts` | POSIX byte comparison (`cmp`, `-s`, `-l`) over the VFS with the host program's bytes and 0/1/2 statuses. |
| `src/sort.ts` | `sort -z`/`--zero-terminated`: NUL-delimited records over stdin/files with `-r -n -u -f -b -o` and `--`; non-`-z` argv delegates to the bundled sort. |
| `src/du.ts` | GNU `du` surface (`-h/--human-readable`, `-a`, `-s`, `-c`, `--max-depth`, `--`) with 4 KiB allocation-block counting and the GNU human formatter. |
| `src/gnu-conventions.ts` | The single owner of `--`, `--version` and `--help` for the registry in `GNU_CONVENTION_PROGRAMS`. |
| `src/cp.ts` | `cp` archive/preserve shim (`-a`, `-p`, `-d`, `--preserve`) over the bundled copy engine, with explicit target chmod/utimes restoration. |
| `src/command-paths.ts` | Virtual `/usr/bin` + `/bin` entry points and `PATH` truthfulness. |
| `src/contract.ts` | Class contract: exit taxonomy, stderr trailer protocol, program-availability hints, truncation annotation. |
| `src/commands.ts` | Production command table (accelerators, curl, `git`, gzip family, tar, path commands, awk, `cmp`, toolbox programs, `which`). |
| `src/toolbox-commands.ts` | The only bridge from WASI toolbox programs (`python3`) to just-bash commands; maps the host cwd through the toolbox preopens. |
| `src/corpus.ts` | Explicit coverage stubs and the `which` helper (coverage only). |
| `coverage/just-bash.mjs` | Runner for `tools/shell-corpus/coverage.mjs`. |
| `tools/ensure-deps.mjs` | `pretypecheck`/`pretest` bootstrap for `just-bash` and the workspace links. |
| `tools/patch-just-bash.mjs` | Byte-guarded, idempotent terminal-state seam for the installed just-bash 3.6.0 browser bundle (also run by `postinstall` and the image packer). |

## Tests

```sh
cd plugins
node --test tests/shell-ext.test.ts tests/shell-ext-devices.test.ts tests/shell-ext-bridge.test.ts \
  tests/shell-ext-contract.test.ts tests/shell-ext-tar-host.test.ts \
  tests/shell-ext-curl.test.ts tests/shell-ext-find.test.ts tests/shell-ext-find-rewrite.test.ts \
  tests/shell-ext-find-printf.test.ts tests/shell-ext-grep.test.ts tests/shell-ext-gzip.test.ts \
  tests/shell-ext-gzip-framing.test.ts tests/shell-ext-tar.test.ts \
  tests/shell-ext-paths.test.ts tests/shell-ext-awk.test.ts tests/shell-ext-command-paths.test.ts \
  tests/shell-ext-cmp.test.ts tests/shell-ext-cp-archive.test.ts \
  tests/shell-ext-jq-inputs.test.ts \
  tests/subprocess-xl-shell.test.ts tests/coverage-just-bash.test.ts
node --test shell-ext/test/bash-invocation.test.ts   # G2-FIX-89/95/116 invocation surface
node --test tests/shell-ext-trap.test.ts             # G2-FIX-107 EXIT trap builtin
node --test tests/shell-ext-terminal-seam.test.ts    # terminal seam + GNU bash comparison

The committed 512-vector golden corpus in
`tools/shell-corpus/golden/worker-shell.jsonl` runs through this same command
table with `node --test tools/shell-corpus`; `node tools/shell-corpus/contract.mjs`
adds the class-level audit (corpus size and command-family coverage, exit
taxonomy, trailer protocol, the A05 probe sequence) and prints the expected
engine deviations for the upstream report. Together they are the regression
gate for the class of silent divergence (a literal `%y` still exits 0, so
coverage alone cannot catch it).
```

`npm run typecheck` and `npm test` first run `shell-ext/tools/ensure-deps.mjs`,
which installs the pinned lockfile with `npm ci` when `just-bash` or a workspace
link is missing (this is what a pre-merge `node_modules` from before this work
package looks like). It never edits `package.json` or `package-lock.json`.

The tests cover the adapter (writes land in `node:fs`; `/dev/null`,
`/dev/zero` and `/dev/urandom` are virtual character devices with the bounded
read window), the accelerator request
shape (`requires_mseq`, `idem_key`, `XL_IDEMPOTENCY_KEY`), the curl allow-list
and method table, cancellation, truncation, the `PDSH_SHELL` dispatch rules, the
concurrency cap / thermal state / fatal admission, the gzip family in a host
whose `node:zlib` refuses (the browser Worker stub) and in one with no backend
at all, the host-generated `cmp` vectors for the byte-comparison class, and the
95% coverage gate. The single-file write cap has an end-to-end
component regression in `worker-entry/src/file-limit.test.ts`: the real
`WorkerShell` over an in-memory VFS double, with the real sink on a memory
channel pair, appends past the budget and checks the command error, the
untouched channel and the next successful write. `shell-ext/src/limit-diagnostics.test.ts`
pins the configured limit per case and requires the refusal text and the
`limit-refused` hint to name the same budget.

iOS/WebKit behaviour is **NOT_VERIFIED**: all numbers and behaviour above were
measured in Node on macOS. The Worker runs the same `node:fs` shim, but only a
device run can confirm timing and memory.
