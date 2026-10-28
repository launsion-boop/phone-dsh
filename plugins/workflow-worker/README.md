# @phone-dsh/dsh-workflow-worker

Worker-native implementation of the `@deepseek-ai/dsh-workflow-ptc` plugin row
for the phone DSH Worker. It keeps the official workflow contract and the
official script semantics; it replaces only the execution substrate that the
phone cannot provide (a child Node process with a control pipe).

## What resolves where

| Concern | Owner |
|---|---|
| `meta` validation | official `@deepseek-ai/dsh-workflow-ptc/src/meta.ts` bundled from the pinned checkout |
| Script execution (`agent`, `parallel`, `pipeline`, `phase`, `log`, `args`) | official `@deepseek-ai/dsh-workflow-ptc/src/runtime.ts` `WorkflowExecution`, in a dedicated workflow Worker; the script itself runs in an embedded QuickJS/WASM realm |
| Child agents, Session/cwd, tool permissions, model identity | parent DSH Worker through `ctx.subagents.startActivation({ delivery: 'caller' })` |
| Cancellation, synchronous deadline, child cleanup | QuickJS interrupt handler + parent isolate termination as the backstop; child disposal stays in the parent |
| `workflow/*` lifecycle events | parent `WorkflowEngine.emitWorkflowEvent` |
| Tool catalog / presentation | real native tools; PTC presentation degrades to native only when no `ptcRuntime` exists (see `tool-presentation-shim.ts`) |

The standard preset's `workflow-ptc` row names the official package. The Worker
static-module table serves that exact specifier from this package, so neither
the preset file nor the model-facing `tool-workflow` contract changes.

## Isolation and limits

The guest script does **not** run in the DSH Worker or in the isolate's own
JavaScript global. `quickjs-vm.ts` evaluates it inside a fresh QuickJS/WASM
realm whose only bindings are the official `agent`/`parallel`/`pipeline`/
`phase`/`log` hooks, converted across a JSON boundary. That realm has no
`fetch`, `process`, `require`, dynamic `import()`, `EventSource`,
`WebTransport`, `WebSocket`, `Worker`, DOM, module loader, filesystem handle,
environment or Native token. Constructor/prototype tricks such as
`({}).constructor.constructor('return import("node:fs")')()` reach only the
QuickJS global. The parent revalidates provider, cwd, schema, Agent/session
identity and budget before starting a real child.

This is an in-process software realm, not an OS-process or hardware privilege
boundary. The official orchestration code (not user code) runs in the dedicated
Worker; the isolate Worker is terminated after every run, which also reclaims
the QuickJS WASM memory. `syncTimeoutMs` is enforced by the QuickJS interrupt
handler: a guest `while (true) {}` is interrupted inside the realm and the next
workflow gets a fresh isolate. A real expiry returns the stable
`WorkflowBudgetError [WORKFLOW_SYNC_BUDGET]` diagnostic; its stack is pinned to
that first line because JavaScriptCore's native stack is only a frame list
(`budgetError@<url>`), and the official runtime renders the stack first. Guest
errors that merely spell `InternalError` or `interrupted` keep their own
identity because the mapping uses the interrupt callback's flag, never error
text. A parent watchdog with a small grace period terminates a wedged host half
that never yields. Cancellation and every terminal path await child disposal.

PTC/PTY/OS process spawn is **not implemented here**. A `ptc` preset gets the
real native tool catalog with a warning, not a claim that the PTC transport
works.

## Tests

`tests/workflow-worker.test.ts` builds this package and the isolate from the
pinned checkout, then exercises real scripts in a `worker_threads` isolate:
guest scoping, constructor/import/EventSource escapes, the child-agent bridge
(including provider/model staying in `agentOptions`), failed-start accounting,
realm-level synchronous-loop interruption (plain, after `await`, after a child,
after a non-awaited `agent()` and inside a `parallel()` thunk), the exact
typed deadline diagnostic, a guest error that imitates the interrupt sentinel
keeping its own identity, cancellation plus in-flight-start disposal, real
isolate load-failure/exit reporting, and a successful next run. A second fixture
imports the same built `workflow-isolate.js` with a browser-like
`postMessage`/`addEventListener` pair, covering the production browser Worker
transport path and its pre-hide message-port capture; a browser `onerror` case
checks the parent reports the
fault and terminates the Worker. The packed image test exercises the same
bridge through the standard preset and a scripted Messages server with a real
child `bash` call.

WebKit/JavaScriptCore execution and the real iOS browser Worker remain
**NOT_RUN on Linux**; the Mac simulator gate must exercise the actual
WKWebView Worker. The Node worker_threads path is an adapter, not a substitute
for that gate.
