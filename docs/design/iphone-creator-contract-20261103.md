# iPhone Creator contract — 2026-11-03

Base: `edb6c419b0ab5b4bf3d46ca8a59dc4a3957ccf1b` (PR26).
Owner/implementer/reviewer: this change. PR14 is outside this work.

## Frozen behavior

The native entry opens the real `cordis` preset and closes settings, preserving
the previous session's draft. Opening the entry sends **no** prompt or tool call.
The user supplies and submits the creation request in that session.

Creator must have real Cordis inspection and persistent local bundle management.
The owning contracts remain the pinned DSH `CordisInspectRegistryService`,
`PluginManager` methods/`ChangeResult`, `plugin_manager` tool and
`@deepseek-ai/dsh-agent-preset` declarations. No DSH sources are patched, and no
wire fields/endpoints, aliases or second result envelopes are introduced.

The existing `node:module` shim must expose Node ancestor search paths for
profile-local package metadata. The pinned runtime's executable module loading
remains unchanged; new JS is not made loadable by this metadata correction.

Worker-specific installation supports workspace-local, declarative preset
bundles using packages already shipped in the image. It must validate before
publishing, persist an owned copy, apply the real Loader/profile path, verify
the new preset can compose, and preserve it after a cold Worker boot. It must
not claim npm/Git/native package installation or arbitrary JS plugin support.
Unsupported input returns an existing management error with an actionable
diagnostic, never a successful placeholder result. Ordinary DSH tool approval
and cancellation remain in force.

Compatibility: old data/profile manifests remain readable; no existing default
or session is rewritten. New local bundles use DSH's existing manifest and
Cordis patch formats. Earlier images without the metadata-path correction
cannot discover these new local bundles: their files remain, but those custom
sessions require this correction to compose. Rollback must not mutate them or
silently substitute a default preset. Built-in sessions retain their formats.

## Acceptance

- Real packed Worker: cordis has no broken row; create/project `cordis`, with no
  model request or turn until an explicit prompt.
- Real tool execution: inspect services/config/tools, author a local bundle,
  install it with truthful `ChangeResult`, read its real YAML, select/create it,
  and verify a newly booted Worker reads the persisted files.
- Negative cases: malformed/unsupported bundles, unavailable package references,
  cancellation and failed activation leave the previous profile usable.
- Native UI: enable Creator after healthy roster read, enter/project `cordis`,
  dismiss the whole sheet, preserve the old draft, and leave the new input idle.
- Rebuild Worker/image; plugin typecheck/tests, SDK/spec/conformance/hygiene,
  Debug/Release compilation and real WKWebView validation. Simulator/scripted
  tests are recorded separately from physical iPhone/real-provider acceptance.
