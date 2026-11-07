# SwiftPM and Xcode package locks

Status: frozen; Xcode workspace lock implementation pending. Protocol impact: P24.

The root `Package.resolved` belongs to SwiftPM's root `Package.swift` graph.
The generated probe project has additional remote packages, so Xcode's
workspace lock is separately tracked at
`examples/probe-app/PhoneDSHProbe.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
XcodeGen generates the project but must preserve this file; other generated
project and workspace files remain untracked. For identities present in both
locks, `kind`, `location`, revision and version must agree. An additional
Xcode-only dependency must be justified by the probe project graph and pinned
in its own lock. The P24 verification workflow must not let either tool rewrite the other
graph's lock. Other build scripts may still use ordinary Xcode resolution and
are not certified by this contract.

Both use the existing version-3 `Package.resolved` representation. The Xcode
lock omits the optional `originHash` because the observed Xcode-generated hash
varies across checkout paths; the exact pins remain mandatory. The P24 Xcode resolution gate uses
`-onlyUsePackageVersionsFromResolvedFile` and fails if the lock is absent,
incompatible or incomplete. In that gate a changed package constraint must
not silently select a different version. The root SwiftPM lock remains unchanged.
The `golden/apple-package-lock-cases.jsonl` cases and its schema describe the
required positive and negative flows; tests must exercise real XcodeGen,
Xcode and SwiftPM in isolated checkouts, including a clean package cache and an
incompatible dependency constraint. No simulator or device claim follows.

Evidence currently covers the tested Xcode/Swift toolchain and current package
graph; unknown versions or formats must fail visibly rather than rewriting a
lock to manufacture a pass. This contract does not define runtime wire, ABI,
app identity or distribution signing.
