# Freeze independent SwiftPM and Xcode package locks

```yaml
change: PC-20261107-apple-package-lock
contracts: [P24]
status: frozen
breaking: false for matching pinned graphs
base: 7d0e2ef0c6f27b485b0b2384dc7443fc7e26e365
contract_revision: spec/toolchain/v1/apple-package-lock.md@sha256:ec13219106d9110a28553c3b5125ae3f39a5722476d70ca002bed1a6710aaed7
```

Protocol impact: P24; P23: none — its registry trigger is narrowed to the
existing SDK-listing files without changing that contract or adapter.
Xcode and root SwiftPM currently share `Package.resolved` despite resolving
different graphs. Both current head and base exhibit Xcode adding three pins
and SwiftPM removing them. Freeze a separately tracked Xcode workspace lock,
while leaving the existing root lock authoritative for SwiftPM. The candidate
version-3 Xcode lock omits `originHash`, contains 13 pinned identities and has
SHA-256 `028635e493c165fdd7c20e7c4fc26953afd770ca94afa1b8e9531448092eeb46`;
the 10 identities common with the root lock have matching URL, revision and
version. Its three additional identities are `swift-cmark`, `swift-markdown`
and `swiftmath`, already required by the probe graph. The no-hash form is a
conditional compatibility decision supported by the current Xcode tests,
not a guarantee for all versions of Xcode.

| Combination | Decision |
| --- | --- |
| Old source/lock → new gate | The Xcode workspace lock is absent: strict Xcode resolution fails and must not rewrite the root. |
| New locks → older tools | Existing SwiftPM sees the unchanged root lock. Xcode versions supporting the version-3 sidecar may use it; other versions must fail visibly rather than silently repin. |
| New source/locks → new gate | Generate the project, preserve its tracked workspace lock, resolve only from it, and preserve both files byte-for-byte. A conflicting project constraint fails. |
| Existing checkout / rollback | Root lock bytes are not migrated. Rollback removes the added sidecar and restores the prior shared-lock contention; neither runtime app data nor credentials are changed. |

The coordinator owns `spec/**`, the two lock files, the Xcode resolution gate
and ignore rules. The implementation may track only the sidecar within the
otherwise generated project; it must not check in generated project files or
add a hook. The 4 shared positive/negative cases are SHA-256
`211282e0e03dfd46ff48b72b0c252c6a4d34fe0e7ef7b35458b28f3aee954fea`;
their schema is
`b531dee7a5cd7a817da39ca4964a9326633671ff42d5b8ed924690f78b4a2f1e`.

Acceptance after this revision is committed: run the actual XcodeGen and
strict Xcode resolution in an isolated fresh checkout and cold package cache;
run SwiftPM resolution and check both locks; test missing sidecar and a real
conflicting project constraint; validate `.gitignore` does not expose generated
project files; run `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree,phone-xcode-resolve`. Check
shared pins across both actual files and record results, skips, source graph and
tool versions. Other build workflows are not yet certified by this change.

Freeze verification: registry tests → PASS (24 tests); spec golden tests →
PASS (67 tests); `bash scripts/ci/check.sh --only
phone-spec,phone-p0-conformance,phone-cross-tree` → PASS / FAIL / PASS. The P0
failure is pre-existing; these results do not implement or validate the new
sidecar in the shared checkout.

## Implementation review — caller isolation remains open

Independent controlled-process review of an unmerged implementation found
that a resolver which modifies the caller's root lock and then fails leaves
that modification behind; a change between preflight validation and snapshot
also allowed a false pass. Those tests used temporary fake tools and do not
claim the real Xcode resolver exhibited this behavior. Blindly restoring the
caller file would risk overwriting an independent user edit, so the candidate
was withdrawn.

A complete temporary snapshot could isolate normal relative output, provided
it captures actual edited and untracked source, does not hard-link locks,
rejects escaping symlinks, and keeps cache/output paths outside the caller
checkout and Git common directory. It does not by itself prevent external
code from using an absolute path to the caller. An outer macOS sandbox denying
writes to the caller was tested against the real Xcode gate, but failed when
SwiftPM attempted to establish its own nested sandbox (`Operation not
permitted`). No general caller-isolation guarantee has been established, and
no implementation, lockfile or gate change was merged on that evidence.
The earlier normal Xcode/SwiftPM experiments remain useful but do not close
this issue; the tracked root lock remains as it was before those experiments.
