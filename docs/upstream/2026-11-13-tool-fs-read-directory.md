# Pending proposal — `read` on a directory names the file type, not the next tool

Date: 2026-11-13
Component: DSH `tool-fs` (pinned 0.2.2-rc.1, commit
`66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`)
Location: `packages/core/tools/tool-fs/lib/index.js` (built: `plugins/node_modules/@deepseek-ai/dsh-tool-fs/lib/index.js:199-201`)

## Observed

`read` on an existing directory returns:

```
cannot read "<path>": not a regular file
```

with `FS_NOT_REGULAR_FILE`. The path exists, so "not found" is wrong, but the
message gives the model no next step. The common recovery is `glob` (or
`bash ls`), and the model has to infer that from the error code. A phone task
that starts by reading the workspace root therefore spends a step learning a
tool fact it could have been told.

## Proposal (smallest useful delta)

In the `target.info.type !== 'file'` branch, distinguish a directory:

```ts
if (info.type !== 'file') {
  const hint = info.type === 'dir' ? '; this is a directory — use glob or ls' : ''
  throw new FsError(`cannot read "${target.displayPath}": not a regular file${hint}`,
                    'FS_NOT_REGULAR_FILE')
}
```

Keep the error code (`FS_NOT_REGULAR_FILE`) and the status mapping unchanged:
only the model-facing sentence grows. An MCP client that matches the code keeps
working; a client that matches the old exact string is not a contract here
(the code is).

## Phone status (2026-11-13): actionable hint added without a DSH patch

phone-dsh now mounts `@phone-dsh/dsh-tool-fs-directory-hint`
([PC-20261113-read-directory-hint](../../docs/protocol-changes/PC-20261113-read-directory-hint.md)),
a `tools/post-execute` policy that appends
`Hint: this path is a directory; use glob (or \`bash ls\`) to list its entries.`
to the exact `read` failure. The tool name, schema, result status and
`FS_NOT_REGULAR_FILE` code stay DSH's. The upstream proposal below remains the
better place for the sentence (it would also serve non-phone deployments).

## Why this belongs upstream too

`dsh-tool-fs` is a pinned DSH package, and the phone repository forbids patching
or vendoring `@deepseek-ai` sources (`scripts/ci/no_dsh_patch.py`). The Worker
profile mounts the package unmodified; the phone-side hint is a policy layer,
not a replacement for the upstream wording fix.

## Workaround available today

`glob` with the directory path, or `bash` + `ls`, both succeed and are already
in the tool list. No retry policy should depend on the old message text.

## Status

Open. Proposal only; not applied to the pinned checkout.
