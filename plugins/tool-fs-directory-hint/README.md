# @phone-dsh/dsh-tool-fs-directory-hint

Appends one actionable sentence to DSH `tool-fs`'s existing directory error:

```
cannot read "/dsh/workspace": not a regular file
Hint: this path is a directory; use glob (or `bash ls`) to list its entries.
```

It is a `tools/post-execute` policy, not a DSH patch. The tool name, schema,
error code (`FS_NOT_REGULAR_FILE`), and result status are unchanged; only the
model-facing content gains a block. The upstream proposal to put the same hint
in `dsh-tool-fs` itself remains in `docs/upstream/`.
