// SPDX-License-Identifier: MIT
/**
 * Exercise the workflow isolate's **browser Worker** bootstrap path under Node.
 *
 * Production creates `new Worker(new URL('workflow-isolate.js', location.href))`;
 * the isolate then binds `postMessage`/`addEventListener` before hiding the
 * ambient globals. Node's worker_threads path uses `parentPort` instead, so it
 * cannot see a lazy-reference regression. This fixture installs a browser-like
 * global pair, forwards structured messages over the Node IPC channel, and
 * imports the same built `workflow-isolate.js` production ships.
 *
 * The guest script itself still runs in QuickJS; this harness only substitutes
 * the Worker transport, not the execution realm.
 */
import { resolve } from 'node:path'

const isolatePath = process.argv[2]
if (isolatePath === undefined) {
  console.error('usage: browser-isolate-host.mjs <workflow-isolate.js>')
  process.exit(2)
}

const capture = process.send.bind(process)
const listeners = []
globalThis.addEventListener = (type, listener) => {
  if (type === 'message') listeners.push(listener)
}
globalThis.postMessage = message => { capture(message) }

process.on('message', data => {
  for (const listener of listeners) listener({ data })
})

try {
  await import(resolve(isolatePath))
} catch (error) {
  console.error(`browser isolate import failed: ${error instanceof Error ? error.stack ?? error.message : String(error)}`)
  process.exit(3)
}

// The isolate handler was installed synchronously by the import; tell the
// parent test that it may now post the initial `run` frame over IPC.
process.send({ type: '__fixture_ready__' })
