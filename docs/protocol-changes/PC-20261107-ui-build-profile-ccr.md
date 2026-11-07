# Contract change request: iOS page extraction and build conditions

```yaml
change: PC-20261107-ui-build-profile-ccr
contracts: [P09]
status: draft
breaking: true
version_decision: pending — build-profile evidence and rollback have not been frozen
base: 8fa659babf90886c152730de392a88f22ee61896
contract_revision: pending
```

`spec/ui/v1/tools/extract_ios_pages.py` currently reads both sides of Swift conditional compilation. For example, it reports the experimental device-task toggle even though the default main probe target does not define `PDSH_ENABLE_DEVICE_TASKS`. A parity check based on that output can demand a feature absent from the production build. Conversely, globally suppressing conditional sections or treating unknown flags as false could hide real UI. The current P0 gate fails on stale page inventory before it can complete the existing Android parity comparison.

A contract owner must select a reproducible target/configuration/SDK/architecture and a source of effective Swift conditions. Xcode settings can come from project, target, xcconfig, inherited values, `OTHER_SWIFT_FLAGS` and command-line overrides; a platform without Xcode cannot independently prove the resolved result. Any stored build-profile evidence needs a version, a digest of all authoritative inputs, an explicit expiry/reverification rule and fail-closed behavior for changed or unresolved inputs. The existing `pdsh.ui.page-structure/1` compatibility and old-checker rollback must be decided rather than assumed.

The implementation must apply the same configuration to page discovery, literal/statement parsing, output anchors and parity checking, preserving raw source line positions. It must correctly handle nested `#if/#elseif/#else/#endif`, boolean precedence and parentheses, and avoid interpreting directives inside comments, ordinary strings, raw strings or multiline strings. Unsupported expressions and malformed directives must fail visibly, not silently exclude content. The documentation inventory must continue to account for inactive and debug page declarations; production parity and separately auditable experimental fixtures are different views.

Before implementation, freeze shared source and expected-output fixtures covering active/inactive and experimental task flags, debug, nested branches, unknown conditions, invalid syntax, Unicode before an anchor, and fake directives in comments and raw/multiline strings. Cross-check representative cases with the actual Swift compiler. Mutation tests must fail when a build flag or input changes without updated evidence and must retain all current page-checker mutation tests. The P0 stage currently runs the page checker tests but not the extractor's own test suite; a revision must include and execute the latter. Android's actual missing device capabilities and other real page differences remain separate work; this proposal must not delete fixtures, extend the baseline, or claim parity by filtering them out.
