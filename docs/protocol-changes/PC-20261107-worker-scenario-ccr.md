# CCR: real Worker scenario accounting and startup diagnostics

```yaml
change: PC-20261107-worker-scenario-ccr
contracts: [P16, P22]
status: draft
breaking: pending
version_decision: pending
base: 00402003f6efde6c5fdda3032053443dd5a7d76f
contract_revision: pending
```

With the fixed DSH checkout and freshly built Worker bundle/image, the macOS
WKWebView smoke suite passed, but the previously skipped abort and WebContent
kill scenarios actually failed. In a separate rerun with redacted model bodies
retained, request 1 was the auxiliary title request (no tools), while requests 2
and 3 were primary agent requests. The mock assigns scripted replies using the
global arrival index, so the title request consumed the only reply containing
the expected bash tool call. The session did not execute that tool; the
`file_exists` assertion correctly failed. The kill itself was applied and the
session returned to running, but the overall scenario did not pass. Mock
delivery also counts all completed model responses against main-turn usage,
including the title response. The original failure is reproduced, and this
trace establishes the request ordering for the rerun, not for all schedules.

The budget-abort tests also saw genuine Worker console errors: the deliberate
unsupported PTY terminal shim threw during an unsupported preset mount, and
the browser connection carrier remained pending for services absent on the
Worker host. Runner timeout diagnostics were separately recorded. These are
not evidence that console events may be removed or reclassified as clean.
Existing tests requiring no console errors and capability visibility remain
in force. The relevant mock and shim predate PR 59, but the Worker profile also
changed in this PR; no baseline runtime equivalence is claimed without a run.

Before implementation, freeze request classification, ordering, retry and
deduplication rules, and independent evidence for each auxiliary and primary
response. Do not simply subtract an assumed title response or weaken the tool,
delivery or console assertions. Any Worker profile change must preserve the
real browser assets, single host connection owner and fail-loud behavior for
unsupported terminal/presets. Exercise both request orderings, retries,
concurrent requests, genuinely lost responses, and the actual Worker restart
and terminal-output path. Rebuild the bundle/image before runtime acceptance.
The current investigation does not close GAP-25 or GAP-26.

The pinned upstream internally marks title generation with a purpose and
records a title-request event, but the examined model adapter does not preserve
that purpose in the HTTP request. Neither arrival position nor an empty tool
list is a sound general discriminator: a primary request can also have no
tools, and requests can reorder. A pre-dispatch event does not prove a title
response was consumed. The existing aggregate usage count also cannot prove a
one-to-one response/receipt match, and identical request bodies can represent
either a retry or separate work. Any candidate correlation must establish its
source and lifecycle without adding an unreviewed wire field, and must fail
closed for ambiguous or missing evidence. Unique token counts in a controlled
mock may be useful as an experiment for primary responses, but must be tested
against the real mapper and do not independently prove title consumption.

The current mock records a request body as a completed response before the
asynchronous `sendHead`/`sendAll` finishes; its resumed-stall branch also marks
completion before the delayed remainder. Therefore that count alone proves
neither full socket delivery nor Worker consumption. A revised contract must
separate planned, fully written, consumed, durably recorded and executed states
and use evidence appropriate to each. Do not relabel the current count as a
delivery receipt.
