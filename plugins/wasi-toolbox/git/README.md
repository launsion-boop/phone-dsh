# `git` inside the DSH phone Worker

MIT. A `git` program that runs **inside** the DSH Web Worker, over the same
`node:fs` the runtime backs with its in-memory VFS. A `git add` or `git commit`
is therefore an ordinary VFS mutation that reaches the WAL sink at the next
`mseq`; no command leaves the Worker (PLAN D12). There is no host git, no
subprocess provider and no DSH patch in this package.

The program exists because DSH's `workspace-changes` plugin derives the
changed-files card from git, and the phone has no operating-system git. The
plugin runs eight subcommands through `ctx.subprocess`; this implementation
reproduces all eight byte-for-byte:

| Subcommand | Shape `workspace-changes` uses |
| --- | --- |
| `rev-parse` | `--show-toplevel --absolute-git-dir --git-path objects` (128 + "not a git repository" outside a repo) |
| `add` | `--all --ignore-errors [-- . :(exclude)path]`, exit 1 when files were skipped |
| `write-tree` | tree id on stdout; 128 with `fatal: git-write-tree: error building trees` on unmerged entries |
| `ls-tree` | `-z -l <tree> -- <path>` (`<mode> <type> <oid> <size>\t<path>\0`, size `-` for a tree) |
| `cat-file` | `cat-file blob <oid>` raw bytes, `-t`, `-s`, `-p` |
| `diff-tree` | `-r -M -z --numstat <before> <after>` (rename records `a\td\t\0old\0new\0`) |
| `ls-files` | `-z --stage` (gitlinks are the `160000` entries) |
| `check-ignore` | `-z --stdin` (NUL input/output; exit 1 when nothing is ignored) |

The golden tests capture every one of those from the system git on a fixture it
builds itself, compare exit status, stdout bytes and stderr, and repeat the run
after `git gc --aggressive` so packed and deltified repositories are covered
too.

## Porcelain

Beyond the eight, the program carries the commands an agent uses most:

`init`, `add`, `status` (`--porcelain[=v1]`, `-z`, `--short`, long form),
`commit` (`-m`, `-a`, `--amend` with `-m` or `--no-edit`, author from
`GIT_AUTHOR_*` or `user.*`), `restore` (default work-tree restore from the
index, `--staged`, `--source=<tree-ish>`, the same pathspec forms as `status`),
`config`
(`--get` and `[--local] <name> <value>` over `.git/config`), `log`
(`--oneline`, `--format`/`--pretty` with `%H %h %T %t %P %p %an %ae %ad %at
%ai %aI %as %aD %cn %ce %cd %ct %ci %cI %cs %cD %s %b %B %n %%` and the
`short`/`full`/`fuller`/`raw` styles, `-n` and `-<n>`, `-p`, `--stat`,
`--date=short`, `--reverse`, and `-- <pathspec>` with the same byte-oriented
default globs and `:(glob)` matcher as the other path filters), `diff` (index
vs work tree, `--cached`, two revisions, `--stat`, `--numstat`,
`--name-status`, and `--no-index` for two
regular files or two symbolic links), `branch` (`-a`, `-r`, `-v`, `-vv`,
combined forms such as
`-avv`, `--list` patterns matched with the same byte-oriented wildmatch as
`tag -l` (`?` is one UTF-8 byte; malformed and descending classes follow git
instead of throwing a JavaScript `SyntaxError`): verbose rows align names and
print the subject,
`-vv` adds the configured upstream and its ahead/behind/gone state, a
detached HEAD is a padded verbose row too, `--list` matches remote shorthand
(`origin/main`) even under `-a`, a symbolic remote ref such as
`origin/HEAD -> origin/main` is shown without a `*` marker or oid, and a
remote with only a URL (no `remote.<name>.fetch` refspec) is not treated as an
upstream, as git requires), `tag` (list/`-n` with the shared byte-oriented
`*`/`?`/`[...]` wildmatch, lightweight and annotated create, `-f`, `-d`; `@`
is a legal tag name and a leading `-` is rejected for creation even after
`--`), `rev-list` (commit walk, `--all`, `--count`, `--reverse`, ranges and
byte-oriented pathspec globs; a trailing `/` or `/.` selects a directory's
contents only, never a same-named file, and a bare repository uses an empty
path prefix while a tree/blob/`HEAD:path` tip contributes no commits, like
git), `checkout`
(including `checkout -- <paths>`, which uses the same restore primitive as
`git restore`), `switch`, fast-forward `merge`, `rm`, `show`, `remote`, and
smart-HTTP `clone` / `fetch` / `pull` / `push`.

`show` prints a commit's patch; an annotated tag prints its `tag`/`Tagger:`/
`Date:` header and message before the peeled commit (or tag/blob/tree) it
names, matching git's separator rules and `--oneline` shape. A `<rev>:<path>`
expression (or a blob object id) is emitted as the blob's raw bytes with no
decoding or added newline, and a tree expression prints `tree <expression>`
followed by its direct entries as raw name bytes (directories with a trailing
`/`), so a non-UTF-8 entry name is never replaced with U+FFFD. `show -s`
stops at the commit header, exactly like git (no extra blank line). `branch
-a` keeps local branches and remote-tracking refs apart, showing
`remotes/origin/x` for the latter and never listing tags as branches; `-r`
removes that prefix. `log --date=short` affects the default `Date:` header and
`%ad`/`%cd`, and the `fuller` style's `AuthorDate:`/`CommitDate:`. Every
other `--date` value, and a `--date` with no value, fails loud with exit 129.
`%aI`/`%cI` use git's canonical strict-ISO form, including `Z` for UTC since
git 2.45 (the golden oracle adapts only that suffix when the system git is
older). `--reverse` reverses the already limited commit list, as git does.
`diff
--no-index` compares two regular files or two symbolic links (absolute,
relative and Unicode paths) and renders the same `diff --git`/`index`/
unified-hunk bytes as git, including `Binary files ... differ`, mode-only
changes and the tab git appends to space-bearing `---`/`+++` paths (a
byte-for-byte golden comparison). `--no-index` is an option only before `--`;
a path named `--no-index` after the separator stays on the repository diff
route. Symbolic links are read with `lstat`/`readlink` as `120000` objects
whose content is the link target, never the target file's bytes. Hunk headers
reuse the nearest git-style function line before the hunk (also with `-U0`)
and strip a CRLF's `\r`; directories, submodules, a symbolic link compared
with a regular file, and other `--no-index` shapes fail loud with exit 129
instead of printing a different diff.

An amend keeps the replaced commit's author and reuses its message with
`--no-edit`; `-m` replaces the message and `--allow-empty` overrides the
empty-commit check. There is no editor inside the Worker, so an amend without
`-m` or `--no-edit` fails with a message naming those two options.

A merge that is not a fast-forward, and every history-rewriting command
(`rebase`, `stash`, `submodule`, `cherry-pick`, `gc`, `worktree`, ...), fails
with exit 128 and a `fatal:` line that states the limitation: the operation
needs host-side git and is not available in this session. The message also
says that nothing was changed. No diagnostic points at a host endpoint the
Worker cannot reach: the Worker's `fetch` reaches only `/v1/http` and static
assets, so host-side operations are stated as limitations, never as
instructions a model could follow in-session. Unknown subcommands keep git's
ordinary `git: '<name>' is not a git command` (exit 1).

Options the program does not implement are never accepted as no-ops: they fail
with exit 129 and a `fatal:` line naming the option (for example
`--format=email`, `--graph`, `--decorate`, `status --ignored`, `diff --binary`,
`config --global`). A request for a format the program cannot render is an
error, never the default format printed as if the request had succeeded.

## Reflog

`commit`, `branch`, `switch` and `checkout` append the records the system git
would write below `<git-dir>/logs/HEAD` and
`<common-dir>/logs/refs/heads/<name>`, in git's exact line format and with its
messages (`commit (initial):`, `commit (amend):`, `branch: Created from`,
`branch: Reset to`, `checkout: moving from ... to ...`). The regression suite
runs every vector against the system git and compares the whole logs tree
byte-for-byte. `branch -d`/`-D` removes the deleted branch's log, including
when logging is disabled. `checkout -B`/`switch -C` write `branch: Reset to`
to the branch ref only when its oid moves. Resetting HEAD's current branch also
appends that record to HEAD even for an unchanged oid, followed by the checkout
record whose old oid is the post-reset value, and prints `Reset branch '<name>'`;
resetting another branch keeps `Switched to and reset branch '<name>'`. An
already-detached checkout at the same commit appends no HEAD entry. A date
without an offset (`GIT_COMMITTER_DATE=1700000000`, or zone-less strict ISO)
uses the local timezone, as git does. A date with an explicit trailing offset
keeps it: the
`%ai`/`%ci` shape and RFC 2822 forms such as `Thu, 07 Apr 2005 22:13:13
+0200` store that offset even when the host zone differs.
When either `GIT_AUTHOR_DATE` or `GIT_COMMITTER_DATE` is unset, that field uses
the current local time independently; it never inherits the other field's
date. The supported RFC timezone names include EST, PDT and CET; unrecognized
named zones fail loudly rather than silently using the host timezone.

`core.logAllRefUpdates` follows git: unset means on in a non-bare repository
and off in a bare one, `false` stops the creation of new logs (an existing log
is still appended, as git documents), and `-c core.logAllRefUpdates=false`
overrides the config. Refs under `refs/tags/` are never logged. A log write
failure fails the command loudly instead of dropping the audit entry.

## Where it runs

```
DSH Web Worker
  subprocess-xl ── WorkerShell ── bash -c …                    (write path stays local, D12)
       └────────── WorkerShell ── direct `git …` (same table) ──┐
                                                               ▼
                                                   node:fs = runtime VFS
                                                               │ mseq sink → WAL
  /v1/http ◀── HostHttpTransport ◀── clone/fetch/push ────────┘
```

- The filesystem is `NodeGitFs` over `node:fs/promises`: the Worker VFS in
  production, a temporary directory in the tests (`new NodeGitFs(root)` mirrors
  `VfsFileSystem({ root })`). The tests therefore exercise real file I/O
  without a second implementation.
- `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` and
  `GIT_ALTERNATE_OBJECT_DIRECTORIES` are honoured, because DSH's snapshots
  write objects into a private store and read committed objects through an
  alternate.
- The network is one injected transport. `HostHttpTransport` POSTs to the host
  loopback `/v1/http` with `X-PDSH-Target-URL`, `X-PDSH-Target-Method` and the
  channel bearer, exactly like `curl`; the host owns the origins allow-list and
  a `403` fails the command. The Worker opens no socket.

## Wiring (landed with this work package)

The package exports three things for the command tables:

- `createGitCommand()` — a just-bash-shaped custom command
  (`{ name: 'git', execute(args, ctx) }`) over the Worker VFS.
- `createGitToolboxProgram()` — a toolbox-shaped `run(request)` descriptor over
  the same `runGit()`. The production shell path uses `createGitCommand`; this
  descriptor exists for a table that routes JavaScript programs rather than
  WASI modules. No such table is registered in the image today (the WASI
  toolbox's `ToolboxCommand` requires a `WebAssembly.Module`), so it is a
  documented compatibility surface rather than a production route.
- `registerGitCommand(table)` / `registerGitProgram(table)` — helpers for a
  table that exposes `register(command)`.

Both reachable entry points are wired:

1. `plugins/shell-ext/src/commands.ts` (`createWorkerCommands`) always
   appends `createGitCommand()`, so `bash -c "git …"` inside the Worker runs
   the Worker implementation.
2. `plugins/subprocess-xl/src/index.ts` routes a direct argv whose program
   `isWorkerShellProgram()` lists (`git`, and every installed WASI toolbox
   program) through `WorkerShell.run` instead of the runtime's
   `node:child_process` shim, so `workspace-changes`'
   `ctx.subprocess.spawn({ argv: ['git', ...] })` lands in the same command.
3. `plugins/wasi-toolbox/package.json` exports `./git`, and
   `scripts/pack-image.mjs` stages every export face into `lib/git.js`, so the
   packed Worker image carries the program.

The worker profile enables the `workspace-changes` row, and its comment names
this program. No DSH source is patched.

## Dependencies

One npm package: `fflate` 0.8.3 (MIT, <https://github.com/101arrowz/fflate>),
the pure-JavaScript zlib codec. Git stores every loose object and pack member
as a zlib-wrapped DEFLATE stream, and the DSH Worker's `node:zlib` proxy has no
deflate/inflate/crc32 (a browser has no `node:zlib` at all), so the codec is
`git/compress.ts` over `fflate`'s synchronous API; the pack-index CRC-32 is
implemented there too. The dependency is exact-pinned in
`wasi-toolbox/package.json` and recorded in `plugins/THIRD_PARTY.md`.
Everything else is `node:` builtins (`node:crypto` for SHA-1,
`node:fs/promises`, `node:path`).

The plan named isomorphic-git; the maintainers chose the otherwise zero-dependency
implementation on 2026-10-25 after the golden comparison
against the system git passed. `tests/no-node-zlib.test.ts` fails if any source
file here imports `node:zlib` again. The adapter boundaries stay `GitFs` and
`RemoteTransport`; `runGit` is the only entry point the command wrappers use.

## Layout

| Path | Role |
| --- | --- |
| `cli.ts` | global options, dispatch table, output collector, error rendering |
| `commands.ts` | the command tables handed to `cli.ts` |
| `inspect.ts` | the eight workspace-changes subcommands, pathspecs, quoting |
| `porcelain.ts` | `init`, `add`, `status`, `commit` (including `--amend`), `restore`, `rm` |
| `config.ts` | `git config` get/set over `.git/config` |
| `history.ts` | `log`, `diff`, `show`, `branch`, `checkout`, `switch`, fast-forward `merge`, `remote` |
| `tag.ts` | `tag` list/`-n`, lightweight and annotated create, `-f`, `-d` |
| `remote.ts` | pkt-line, smart-HTTP discovery, upload-pack, receive-pack, pack import |
| `http.ts` | the host `/v1/http` transport and its allow-list errors |
| `repo.ts` | discovery, config, refs, revision syntax, tree walking |
| `objects.ts` / `pack.ts` | loose objects, pack index/reader/writer, delta application |
| `compress.ts` | zlib codec (`fflate`, browser entry) and the table-based pack CRC-32 |
| `gindex.ts` | the `DIRC` index, v2 read/write, v3 read |
| `tree.ts` | tree building from the index, tree diffs and rename detection |
| `ignore.ts` | `.gitignore` semantics for `check-ignore`, `status`, `add` |
| `textdiff.ts` | Myers diff, unified hunks, numstat counters, binary heuristic |
| `worktree.ts` | deterministic work-tree walk |
| `fs.ts` | `GitFs` abstraction and `NodeGitFs` |
| `command.ts` | just-bash command, toolbox descriptor, registries |
| `tests/` | golden, restore/amend, porcelain, porcelain-corpus (format/config/-n vectors), remote, command, pack, ignore and unsupported suites |

## Limits

- Index versions 2 and 3 are read, version 2 is written; a version-4 index is
  rejected with a clear message instead of being misread.
- `wildmatch.ts` is an independent MIT implementation of the documented
  `*`/`?`/`[...]` glob language, not a port of git's GPL `wildmatch.c`; it
  matches UTF-8 bytes and has no locale-dependent case folding.
- Pathspecs preserve literal file/directory matches before trying glob syntax;
  exclude-only selections start from all paths and then subtract exclusions.
  A default wildcard pathspec keeps git's unanchored behavior (`*` spans `/`).
  `:(glob)` switches to the pathname-aware matcher in `wildmatch.ts`: `*`, `?`
  and bracket expressions stop at `/`, and `**` is special only at a glob
  position (leading `**/`, middle `/**/`, trailing `/**`, and escaped
  `**\/`). The escaped-slash form keeps its separator literal, so unlike
  `**/` it has no zero-directory shortcut (`**\/b` does not match root `b`).
  The literal prefix before the first wildcard or escape is consumed first,
  which is what makes `a/b**` pathname-wide like git; an escaped wildcard
  stays in the parsed remainder, so it cannot promote a following `**` to
  globstar. A backslash is glob syntax even when it is the only such byte, so
  `:(glob)a\\]` reaches the matcher and selects the literal name `a]`
  instead of being compared against the raw spelling.
  Malformed wildcard bytes match nothing, as git does; invalid or incompatible
  magic (`:(glob`, `:(bogus)`,
  `:(literal,glob)`) is a real exit-128 error. Shared filtering uses the same
  parsed pathspec in `add`, `status`, `restore`, `rm`, `diff`, `diff-tree`,
  `ls-files`, `log` and `rev-list`. `ls-tree` keeps native Git's command-specific
  rejection of `:(glob)` and `:(exclude)` instead of enabling them.
- SHA-1 object ids only. Gitlinks are listed but never descended into;
  submodules stay on the host (`git submodule` is unsupported).
- Rename detection (`-M`) pairs exact blobs and line-similarity matches at
  git's default 50% threshold; the similarity metric is line-based, so a
  heavily rewritten rename can be scored differently from git. Each addition
  is consumed by at most one deletion, and a pathspec restricts both snapshots
  before rename pairing, so selecting only one side of a rename produces that
  side's deletion or addition, as git does.
- `clone` supports smart HTTP v0 without `--depth`, `--filter`, `--bare` or
  protocol v2; a received pack is stored whole with a freshly built index.
- No hooks, `.gitattributes` filters, autocrlf, commit signing, replace
  objects, sparse checkout or multi-pack-index.
- Nothing in this package has run on an iPhone. iOS/WebKit behaviour is
  **NOT_VERIFIED**; the Phase 0 probe package owns that measurement. The
  package is exercised by `node --test` on the build host (macOS, Node 24) and
  by the golden comparison against the system git. That comparison writes to a
  real temporary directory through `NodeGitFs`; the Worker VFS proxy's own
  semantics (read-only `EROFS`, append, mode reporting) are exercised by the
  toolbox/wiring suites, not by the byte-for-byte golden fixture.

## Tests

From `plugins`:

```sh
node --test "wasi-toolbox/git/tests/*.test.ts"
```

or from `plugins/wasi-toolbox`, the component gate:

```sh
node --test git/tests
```

or the package gate:

```sh
npm run typecheck && npm test
```

`tests/index.js` is the directory entry for the component gate (Node treats an
explicit path as a file, not a directory to search); it imports the same test
modules, so no assertions live in a second place.

The golden suites skip with a message when the system `git` is absent; every
fixture is generated by that git (never by the implementation under test) with
an isolated `HOME`, `GIT_CONFIG_NOSYSTEM=1` and fixed author/committer dates.
`tests/wiring.test.ts` covers the production route: the default
`createWorkerCommands()` table runs `bash -c "git …"`, a direct
`ctx.subprocess.spawn(['git', ...])` reaches the same implementation instead of
the `node:child_process` shim, and the tool worker writes through the toolbox
VFS proxy for a toolbox program registered in the shell table.
