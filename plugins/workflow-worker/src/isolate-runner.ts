// SPDX-License-Identifier: MIT
/**
 * Dedicated workflow-isolate entry.
 *
 * This file runs inside its own Worker, never in the DSH Worker. It hosts the
 * official `WorkflowExecution` unchanged, supplies its `node:vm` face as the
 * embedded QuickJS/WASM realm (`quickjs-vm.ts`), and forwards every child
 * request to the parent Worker over structured messages. The guest script
 * never executes in this Worker's JavaScript global. The parent owns the real
 * `ctx.subagents`, Session, VFS, model permissions and tool identity; the
 * isolate only receives JSON the QuickJS bridge materialized and returns the
 * JSON result.
 * @module @phone-dsh/dsh-workflow-worker/isolate-runner
 */

import type { ChildHandle, ChildPort, ChildResult, ChildStartRequest } from '@deepseek-ai/dsh-workflow-ptc'
import { WorkflowExecution } from '@deepseek-ai/dsh-workflow-ptc/src/runtime.ts'
import type { ExecutionObserver } from '@deepseek-ai/dsh-workflow-ptc/src/runtime.ts'
import type { WorkflowResult } from '@deepseek-ai/dsh-workflow'
import { installJscCompat } from '../../worker-entry/src/jsc-compat.ts'
import { installPromiseWithResolvers } from '../../worker-entry/src/promise-compat.ts'
import { openPort, hideHostGlobals, type IsolatePort } from './isolate-ports.ts'
import { QUICKJS_REALM_MARKER, prepareQuickJs, setQuickJsActivityListener } from './quickjs-vm.ts'
import {
  isTagged, renderError,
  type IsolateChildDispose, type IsolateChildResult, type IsolateChildStart,
  type IsolateDone, type IsolateFatal, type IsolateProgress, type IsolateReady, type IsolateRun,
  type IsolateSyncYield, type IsolateToParent, type ParentToIsolate,
} from './protocol.ts'

/** A deferred that does not require `Promise.withResolvers` (absent on iOS 17.0-17.3). */
interface Deferred<T> {
  readonly promise: Promise<T>
  readonly resolve: (value: T) => void
  readonly reject: (reason: unknown) => void
}

/** Create one deferred. */
function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((accept, refuse) => { resolve = accept; reject = refuse })
  return { promise, resolve, reject }
}

// iOS 17.0-17.3 lacks several platform primitives the official runtime and
// QuickJS wrapper touch; install the same prelude the main Worker uses before
// any module evaluates.
installJscCompat()
installPromiseWithResolvers()

/** Correlation state for one child requested by the official execution. */
interface ChildRecord {
  readonly result: Deferred<ChildResult>
  readonly disposed: Deferred<void>
}

/** The isolate half of the child-agent bridge. */
class RpcChildPort implements ChildPort {
  private next = 0
  private readonly starts = new Map<number, Deferred<string>>()
  private readonly children = new Map<number, ChildRecord>()
  private readonly port: IsolatePort

  constructor(port: IsolatePort) {
    this.port = port
  }

  async startAgent(request: ChildStartRequest): Promise<ChildHandle> {
    const callId = ++this.next
    const started = deferred<string>()
    this.starts.set(callId, started)
    const message: IsolateChildStart = { type: 'child-start', callId, request }
    this.port.send(message)
    const childId = await started.promise
    const result = deferred<ChildResult>()
    const disposed = deferred<void>()
    this.children.set(callId, { result, disposed })
    const requestResult: IsolateChildResult = { type: 'child-result', callId }
    this.port.send(requestResult)
    const port = this.port
    return {
      id: childId,
      result: result.promise,
      async dispose(): Promise<void> {
        const dispose: IsolateChildDispose = { type: 'child-dispose', callId }
        port.send(dispose)
        await disposed.promise
      },
    }
  }

  /** Apply one parent response. */
  receive(message: ParentToIsolate): void {
    switch (message.type) {
      case 'child-started': {
        const started = this.starts.get(message.callId)
        this.starts.delete(message.callId)
        started?.resolve(message.childId)
        break
      }
      case 'child-start-failed': {
        const started = this.starts.get(message.callId)
        this.starts.delete(message.callId)
        started?.reject(new Error(message.error))
        break
      }
      case 'child-result-ok': {
        const record = this.children.get(message.callId)
        record?.result.resolve({
          output: message.result.output,
          stopReason: message.result.stopReason,
          ...message.result.structured === undefined ? {} : { structured: message.result.structured },
        })
        break
      }
      case 'child-result-failed': {
        const record = this.children.get(message.callId)
        record?.result.reject(new Error(message.error))
        break
      }
      case 'child-disposed': {
        const record = this.children.get(message.callId)
        this.children.delete(message.callId)
        record?.disposed.resolve()
        break
      }
      case 'run':
        // A run message is handled before this bridge is constructed.
        break
    }
  }
}

/** Send one progress observation. */
function progress(port: IsolatePort, event: IsolateProgress): void {
  port.send(event)
}

/** Build the official observer over the structured-message port. */
function observer(port: IsolatePort): ExecutionObserver {
  return {
    phase: (title) => { progress(port, { type: 'phase', title }) },
    log: (message) => { progress(port, { type: 'log', message }) },
    agentStart: (info) => { progress(port, { type: 'agent-start', info }) },
    agentEnd: (info) => { progress(port, { type: 'agent-end', info }) },
  }
}

/**
 * Run one official execution. Construction and `drive()` stay inside this
 * isolate; a thrown construction failure is reported as a fatal message.
 * @param port - message port to the parent.
 * @param run - validated initialization data.
 */
async function run(port: IsolatePort, run: IsolateRun): Promise<void> {
  const children = new RpcChildPort(port)
  port.onMessage((message) => {
    if (!isTagged(message) || message.type === 'run') return
    children.receive(message as unknown as ParentToIsolate)
  })
  setQuickJsActivityListener(() => {
    const yielded: IsolateSyncYield = { type: 'sync-yield' }
    port.send(yielded)
  })
  try {
    // QuickJS/Emscripten needs the platform `console`/`process` faces while it
    // instantiates its WASM module. Hide host globals only after the realm is
    // ready and before any guest code can run.
    await prepareQuickJs()
    hideHostGlobals()
    // Realm load time is not script execution time: the parent only starts the
    // activity watchdog after this readiness message.
    const ready: IsolateReady = { type: 'ready' }
    port.send(ready)
    const execution = new WorkflowExecution(
      run.meta,
      run.body,
      run.args,
      run.limits,
      observer(port),
      children,
    )
    const result = await execution.drive()
    const done: IsolateDone = { type: 'done', result }
    port.send(done)
  } catch (error: unknown) {
    const fatal: IsolateFatal = { type: 'fatal', error: renderError(error) }
    port.send(fatal)
  }
}

const port = openPort()
// Kept as a real global assignment so the embedded realm marker survives
// bundling and the build can prove the QuickJS realm is reachable.
Object.defineProperty(globalThis, '__PDSH_WORKFLOW_REALM__', {
  value: QUICKJS_REALM_MARKER,
  enumerable: false,
  configurable: false,
})
// The first message is the run; later messages are child responses and are
// consumed by the bridge installed inside run().
const pendingRun = deferred<IsolateRun>()
port.onMessage((message) => {
  if (!isTagged(message) || message.type !== 'run') return
  pendingRun.resolve(message as unknown as IsolateRun)
})
void pendingRun.promise.then(init => run(port, init))

/** Keep the official result type reachable for declaration checks. */
export type { WorkflowResult }
