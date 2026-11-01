# M99 build-time compatibility gate

The Worker TypeScript under `plugins/` is shared verbatim with the phone image, where it runs inside
`com.huawei.webview`: an engine pinned at roughly Chromium 99 / V8 9.9 that users cannot update from
Play. `tsconfig.json` compiles against ES2024, so the type checker accepts APIs and syntax the phone
does not have. `scripts/compat-gate.mjs` scans the shared sources at build time, prints every hit as
`path:line: api`, and exits 1 on anything the baseline does not cover.

## Run

```sh
cd plugins && npm run compat                                  # human report, exit 0/1
node scripts/compat-gate.mjs --root . --json > /tmp/compat.json   # machine report
```

Flags: `--root`, `--baseline`, `--strict` (unverified rules block), `--block-tests`,
`--include-strings`, `--verbose`, `--json`, `--today`.

## Verdict: the Chromium milestone, not the ES year

`sinceChromium` decides; `since` (the ES edition) only explains the history. At or below 99 the M99
engine already ships the feature, so the hit is a note — recorded, never blocking, even in test
files. A later milestone blocks. `"unverified"` warns, and blocks only under `--strict`.

ES years would misclassify: `Array.prototype.at` is ES2022 but Chromium 92, `findLast` and
`findLastIndex` are ES2023 but Chromium 97, `Object.hasOwn` is Chromium 93, `structuredClone` is
Chromium 98 — all inside M99, and an ES-year rule would have called 60+ working call sites debt.
Beyond 99: `toSorted`/`toReversed`/`toSpliced`/`Array.prototype.with` (110), `RegExp` v flag (112),
`Object.groupBy`/`Map.groupBy` (117), `Promise.withResolvers` (119), `Array.fromAsync` (121),
`using` (134), `RegExp.escape` (~136), import attributes (123).

## Freezing existing hits

Never widen a rule or a milestone to go green. Freeze a known site with an `allow[]` entry scoped to
a path prefix and one exact `api`:
`{"path":"subprocess-xl/src/index.ts","api":"Promise.withResolvers","reason":"frozen 2026-10-31",
"expires":"2027-03-31"}`. An `expires` earlier than the run day fails the gate, so a freeze cannot
become permanent; new code must add no error. Regenerate the list from the current tree:

```sh
node scripts/compat-gate.mjs --json | node -e 'let s="";process.stdin.on("data",d=>s+=d)
.on("end",()=>{for(const h of JSON.parse(s).hits.filter(x=>x.severity==="error"))
console.log(JSON.stringify({path:h.path,api:h.api,reason:"frozen: pre-gate",expires:"2027-03-31"}))})'
```

## Polyfills and blind spots

`polyfills[]` declares `{ "api", "provider", "note", "expires" }`; a missing provider file or a past
expiry fails the gate. Comment lines and single-literal lines are skipped, test files (`tests/`,
`*.test.*`) warn instead of blocking (`--block-tests` flips that). The scan is lexical, not a parser:
a spelling inside a longer string still counts, the `v`-flag and fluent `.with(` patterns are
approximate, and no import graph is read, so a polyfill declaration is realm-blind.

## Why fail-loud here

A device probe of the Huawei WebView is not available in CI, and a transpiler cannot fix a missing
API: downlevelling `??=` is syntax, `Object.groupBy` is not — it needs a polyfill or a rewrite. The
decision therefore happens in the diff: rewrite, declare a polyfill, or pin an older DSH. Operating
mode: existing errors are frozen with expiring `allow[]` entries, new code adds none; the ~118K
scanned lines take well under a second.
