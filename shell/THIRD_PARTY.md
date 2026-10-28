# Third-party notices — pdsh-shell

The `pdsh-shell` workspace is MIT. Its read-only accelerators use the Rust
libraries below. Every dependency is permissive: MIT, Apache-2.0, BSD,
Unlicense, Zlib, the Unicode license, or a dual-licensed package used under its
permissive option. There is **no GPL, LGPL or AGPL code in the selected
dependency graph**.

## Direct dependencies

| Crate | Version | License | Used by | Use |
|---|---|---|---|---|
| `pdsh-core` | 0.1.0 | MIT | pdsh-ffi, pdsh-rg, pdsh-jaq, pdsh-ts, pdsh-phone, pdsh-all | VFS sandbox, cancel token, output sinks, limits, command registry |
| `pdsh-jaq-wasm` (workspace crate) | 0.1.0 | MIT | wasm32-wasip1 jq executable staged by the Worker image | jq input-language engine over jaq-core/jaq-std/jaq-json |
| `grep-matcher` | 0.1.9 | Unlicense OR MIT | pdsh-rg | `Matcher` trait (byte offsets, submatches) |
| `grep-regex` | 0.1.14 | Unlicense OR MIT | pdsh-rg | Rust-regex matcher builder (`-i`, `-F`, `-w`, multiple `-e`) |
| `grep-searcher` | 0.1.17 | Unlicense OR MIT | pdsh-rg | line-oriented searcher over any `Read` (the VFS reader) |
| `grep-printer` | 0.3.1 | Unlicense OR MIT | pdsh-rg | ripgrep's `--json` printer (`begin`/`match`/`context`/`end`) |
| `ignore` | 0.4.33 | Unlicense OR MIT | pdsh-rg | `.gitignore` / `.ignore` semantics and `-g` overrides |
| `globset` | 0.4.20 | Unlicense OR MIT | pdsh-rg | file-type (`-t` / `-T`) glob matching |
| `jaq-core` | 3.1.2 | MIT | pdsh-jaq, pdsh-jaq-wasm | jq parser, compiler and interpreter |
| `jaq-std` | 3.0.4 | MIT | pdsh-jaq, pdsh-jaq-wasm | jq standard library (`select`, `map`, `keys`, `@base64`, …) |
| `jaq-json` | 2.0.3 | MIT | pdsh-jaq, pdsh-jaq-wasm | JSON value type, reader and writer |
| `tree-sitter` | 0.25.10 | MIT | pdsh-ts | incremental parser runtime and queries |
| `tree-sitter-typescript` | 0.23.2 | MIT | pdsh-ts | TypeScript and TSX grammars |
| `tree-sitter-javascript` | 0.25.0 | MIT | pdsh-ts | JavaScript (and JSX) grammar |
| `tree-sitter-swift` | 0.7.4 | MIT | pdsh-ts | Swift grammar |
| `tree-sitter-python` | 0.25.0 | MIT | pdsh-ts | Python grammar |
| `tree-sitter-rust` | 0.24.2 | MIT | pdsh-ts | Rust grammar |
| `tree-sitter-c` | 0.24.2 | MIT | pdsh-ts | C grammar |
| `tree-sitter-json` | 0.24.8 | MIT | pdsh-ts | JSON grammar |
| `serde_json` | 1.0.154 | MIT OR Apache-2.0 | pdsh-phone | validating `phone` arguments and scripted test values |
| `serde_json` (dev) | 1.0.154 | MIT OR Apache-2.0 | pdsh-rg, pdsh-ts | asserting the emitted JSON in integration tests |

The `pdsh-rg`, `pdsh-jaq`, `pdsh-ts` and `pdsh-phone` crates live in this workspace and
are linked by `pdsh-all`; `pdsh-all` is the single `pdsh_shell_accelerators()`
registry the C ABI (`pdsh-ffi`) links. `pdsh-rg` is a hard dependency of `pdsh-all`
(it is implemented in this workspace, so no optional `rg` feature gate is
needed).

## Wasm brush spike (`pdsh-brush-wasm`)

The `pdsh-jaq-wasm` crate is the Worker image's jq executable (built only for
`wasm32-wasip1`, not part of `pdsh-all` and not linked by `pdsh-ffi`). It adds
no dependency beyond the three jaq crates already pinned above; its
`Cargo.lock` change is the new workspace package entry only.

The optional `pdsh-brush-wasm` crate (built only for `wasm32-wasip1`, not part
of `pdsh-all` and not linked by `pdsh-ffi`) depends on the rust-brush family:

| Crate | Version | License | Use |
|---|---|---|---|
| `brush-core` | 0.5.0 (exact) | MIT | bash-compatible shell core: parser, interpreter, jobs, redirection, builtin registry |
| `brush-builtins` | 0.2.0 (exact) | MIT | standard shell builtins (`echo`, `cd`, `test`, `export`, ...) |
| `brush-parser` | 0.4.0 (exact) | MIT | parses a script once so the runner can recognise a top-level pipeline |
| `tokio` | 1.54.1 | MIT | the current-thread runtime brush-core uses; the feature set is the one brush-core's own wasm dependency enables |

The three brush crates are pinned to one version because brush-core's public
API and its Wasm support change between releases; they are used directly from
crates.io and are not vendored or patched. The crate is MIT, as are its
upstream projects (<https://github.com/reubeno/brush>).

The complete dependency graph of `pdsh-brush-wasm` is permissive. New transitive
licences worth naming explicitly:

| Crate | License | Note |
|---|---|---|
| `terminfo` 0.9.0 | WTFPL | Unix-only dependency of brush-core; not linked into the wasm module |
| `r-efi` 6.0.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later | used under MIT/Apache-2.0; the LGPL option is not selected |
| `check_elevation` 0.2.7 | BSD-2-Clause | Windows-only dependency of brush-core |
| `icu_*`, `litemap`, `potential_utf`, `tinystr`, `writeable`, `yoke`, `zerovec`, ... | Unicode-3.0 | permissive Unicode licence, via `clap` |
| `self_cell` 1.3.0 | Apache-2.0 OR GPL-2.0-only | shared with the jaq graph; used under **Apache-2.0** only |

All other new crates are `MIT`, `Apache-2.0`, `MIT OR Apache-2.0`,
`Apache-2.0 OR MIT`, `Unlicense OR MIT`, `Zlib`, `BSD-2-Clause` or
`Zlib OR Apache-2.0 OR MIT`. There is no selected GPL, LGPL or AGPL option.

## Transitive dependency licences

The complete graph (`cargo metadata`) is permissive. The licences that are
worth calling out explicitly:

| Crate | License | Note |
|---|---|---|
| `self_cell` 1.3.0 | Apache-2.0 OR GPL-2.0-only | used under **Apache-2.0** only, via `jaq-json`; the GPL option is not selected |
| `foldhash` 0.1.5 / 0.2.0 | Zlib | permissive, non-copyleft; via `indexmap`/`hashbrown` (`jaq-json`, `tree-sitter` build) |
| `unicode-ident` 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 | permissive Unicode license |
| `encoding_rs` 0.8.42 | (Apache-2.0 OR MIT) AND BSD-3-Clause | via `grep-searcher` |
| `ryu` 1.0.23 | Apache-2.0 OR BSL-1.0 | permissive Boost license option |

All remaining transitive crates are `MIT`, `Apache-2.0`, `Unlicense`,
`MIT OR Apache-2.0`, `Unlicense OR MIT`, `Apache-2.0 OR MIT` or
`Unlicense/MIT`: `aho-corasick`, `autocfg`, `base64`, `bitflags`, `bstr`,
`bytes`, `cc`, `cfg-if`, `core_detect`, `crossbeam-deque`, `crossbeam-epoch`,
`crossbeam-utils`, `defmt`, `defmt-macros`, `defmt-parser`, `dyn-clone`,
`encoding_rs_io`, `equivalent`, `find-msvc-tools`, `hashbrown`, `hifijson`,
`indexmap`, `itoa`, `jiff`, `jiff-core`, `jiff-static`, `jiff-tzdb`,
`jiff-tzdb-platform`, `libc`, `libm`, `log`, `memchr`, `memmap2`,
`multiversion_no_op`, `num-bigint`, `num-integer`, `num-traits`, `once_cell`,
`portable-atomic`, `portable-atomic-util`, `proc-macro2`, `quote`, `regex`,
`regex-automata`, `regex-bites`, `regex-syntax`, `rustversion`, `same-file`,
`scopeguard`, `serde`, `serde_core`, `serde_derive`, `shlex`, `simdutf8`,
`streaming-iterator`, `syn`, `termcolor`, `thiserror`, `thiserror-impl`,
`tree-sitter-language`, `typed-arena`, `urlencoding`, `walkdir`, `winapi-util`,
`windows-link`, `windows-sys`, `zmij`.

The workspace `Cargo.lock` pins every version above. Upstream projects:

- ripgrep library crates: <https://github.com/BurntSushi/ripgrep>
- jaq: <https://github.com/01mf02/jaq>
- tree-sitter: <https://github.com/tree-sitter/tree-sitter>
- tree-sitter grammars: <https://github.com/tree-sitter>

## Build tooling and source headers

`cargo` and `rustup` are build tools and are not distributed with this
repository. The `pdsh-shell` crates declare `license = "MIT"` in
`Cargo.toml`, and every hand-written `.rs` and `.sh` source file carries
`SPDX-License-Identifier: MIT` in its first line.

New crates added to this workspace must record each direct dependency and its
license here, stay within permissive licences, and never select a GPL, LGPL or
AGPL option.
