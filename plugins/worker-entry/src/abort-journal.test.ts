// SPDX-License-Identifier: MIT
/**
 * CHANGE(3) diagnosis — pinned DSH journals a terminal `turn/end` when a
 * pending model stream is cancelled.
 *
 * G2-FIX-9's Swift host waits, inside the D14 drain window, for the DSH session
 * journal to close an aborted turn before it tears the Worker down. That fix
 * rests on one cross-boundary assumption: the pinned DSH session, with a model
 * SSE response still pending, appends `turn/end` after `session/cancel`. The
 * previous landing only exercised a scripted Worker that wrote `turn/end`
 * itself, so the assumption was never diagnosed against the pinned runtime
 * (acceptance P0-2).
 *
 * This test diagnoses it against the real pinned runtime:
 *
 * 1. pack the phone image from the pinned checkout (the same
 *    `scripts/pack-image.mjs` the image gate runs);
 * 2. boot it with the real `createWorkerHost` under Node (the packed-image
 *    boot harness path used by `tests/image-boot.test.ts`);
 * 3. serve the host `/v1/http` route with a Messages SSE response that writes
 *    the head and a thinking delta, then holds the stream open forever;
 * 4. drive the real webserver through the same synthetic request/response pair
 *    the Worker entry builds for a `0x40 API_REQ` frame: `session/create`,
 *    `session/prompt`, then, once the journal has an open turn **and** the
 *    model response is open, the real `session/cancel` remote method;
 * 5. assert the session journal ends on `turn/end` with the cancel cause.
 *
 * Result: the pinned runtime (0.2.1-rc.2, 7be5505) does append
 * `turn/end {reason:{kind:'aborted', reason:{kind:'user'}}}` on the same turn
 * whose model stream is still pending, so no worker-entry shim is needed and
 * no DSH source is patched. The Swift host may rely on it; this test pins that
 * contract. If a future pin changes the behaviour, this test fails before the
 * silent abort regression can land.
 *
 * Contract gap: `session/cancel → turn/end` is pinned-upstream behaviour, not
 * a rule written in `spec/v1`. The phone stack depends on it across
 * the Worker/host boundary; this test is the executable note. Any upstream
 * change requires re-running it before moving `dsh-pin.json`.
 */
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, test } from 'node:test'

import { build } from 'esbuild'

const here = dirname(fileURLToPath(import.meta.url))
const pluginRoot = resolve(here, '..', '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the pinned runtime and packer come from the checkout'
  : false

const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'

/** Temp directories created by this file. */
const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

/** The child's reported observation. */
interface Diagnosis {
  booted?: boolean
  error?: string
  sessionId?: string
  journalPath?: string
  journalOpenBeforeCancel?: boolean
  modelStreamOpenBeforeCancel?: boolean
  cancelStatus?: number
  sawTerminalTurn?: boolean
  lastRecordType?: string
  lastTurnEndReason?: string
  lastTurnEndCause?: string
  journalTail?: string
}

/**
 * Bundle the diagnosis child against the pinned checkout's runtime sources.
 * The checkout is not an npm dependency of plugins, so the runtime prefix
 * is resolved explicitly, exactly as `worker-entry/build.mjs` does.
 * @param options - bundle inputs.
 * @param options.outfile - bundled child path.
 * @param options.checkout - verified pinned checkout.
 */
async function bundleHarness(options: { outfile: string; checkout: string }): Promise<void> {
  const runtimeSrc = join(options.checkout, 'packages/experimental/webworker-runtime/src')
  await build({
    entryPoints: [join(here, 'fixtures', 'abort-journal-harness.ts')],
    outfile: options.outfile,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    external: ['node:*'],
    banner: {
      // esbuild's ESM output still sees CommonJS `require('stream')` calls in
      // bundled dependencies; Node has no ambient require in an ES module.
      js: "import { createRequire as __xlCreateRequire } from 'node:module'; const require = __xlCreateRequire(import.meta.url);",
    },
    absWorkingDir: options.checkout,
    logLevel: 'silent',
    plugins: [{
      name: 'pdsh-runtime-source',
      setup(builder) {
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-experimental-webworker-runtime\/src\// }, args => ({
          path: join(runtimeSrc, args.path.slice(RUNTIME_PREFIX.length)),
        }))
      },
    }],
  })
}

/**
 * Run the diagnosis child to completion and collect its streams.
 * @param environment - complete child environment.
 * @param harness - bundled child path.
 * @param image - packed image path.
 * @returns exit status and captured text.
 */
function run(environment: NodeJS.ProcessEnv, harness: string, image: string): Promise<{
  status: number | null
  stdout: string
  stderr: string
}> {
  return new Promise((resolveRun, reject) => {
    const child = spawn(process.execPath, [harness, image], {
      env: environment,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const stdout: Buffer[] = []
    const stderr: Buffer[] = []
    const watchdog = setTimeout(() => {
      child.kill('SIGKILL')
    }, 120_000)
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk))
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk))
    child.once('error', reject)
    child.once('close', (status) => {
      clearTimeout(watchdog)
      resolveRun({
        status,
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
      })
    })
  })
}

test('pinned DSH journals turn/end when session/cancel aborts a pending model stream', {
  skip,
  timeout: 180_000,
}, async () => {
  assert.notEqual(checkout, undefined)
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-abort-journal-'))
  scratch.push(directory)
  const imageDirectory = join(directory, 'image')
  const environment = { ...process.env, PDSH_DSH_CHECKOUT: checkout }

  // 1. Pack the real phone image from the pinned checkout.
  const pack = spawnSync(process.execPath, [join(pluginRoot, 'scripts', 'pack-image.mjs'), '--out', imageDirectory], {
    cwd: pluginRoot,
    env: environment,
    encoding: 'utf8',
  })
  assert.equal(pack.status, 0,
    `pack-image failed (${String(pack.status)}):\n${pack.stdout}\n${pack.stderr}`)

  // 2. Bundle the diagnosis child against the checkout's runtime sources.
  const harness = join(directory, 'abort-journal-harness.mjs')
  await bundleHarness({ outfile: harness, checkout: checkout as string })

  // 3. Boot the image, hang the model stream, cancel the open turn and read
  //    back the session journal the pinned runtime wrote.
  const child = await run(environment, harness, join(imageDirectory, 'image.tar.gz'))
  const marker = child.stdout
    .split('\n')
    .find(line => line.startsWith('__PDSH_ABORT_JOURNAL__ '))
  assert.ok(marker !== undefined,
    `the diagnosis child wrote no result line\nstdout:\n${child.stdout}\nstderr:\n${child.stderr}`)
  const result = JSON.parse(marker.slice('__PDSH_ABORT_JOURNAL__ '.length)) as Diagnosis
  const detail = `\ndiagnosis: ${JSON.stringify(result, null, 2)}\nstderr:\n${child.stderr}`

  assert.equal(result.booted, true, `the pinned image did not boot${detail}`)
  assert.equal(result.error, undefined, `the diagnosis failed before observing the turn${detail}`)
  assert.match(result.journalPath ?? '', /^\/dsh\/home\/sessions\//,
    `the journal was not the mounted DSH home session log${detail}`)

  // Preconditions: the cancel must arrive while the turn is open and while the
  // model response is still pending. Otherwise the test would prove nothing
  // about the abort path (acceptance P0-2).
  assert.equal(result.journalOpenBeforeCancel, true,
    `no open turn was journaled before session/cancel${detail}`)
  assert.equal(result.modelStreamOpenBeforeCancel, true,
    `the model response was not pending when session/cancel was sent${detail}`)
  assert.equal(result.cancelStatus, 200, `session/cancel was not accepted${detail}`)

  // The observation: the pinned session closes the aborted turn itself.
  assert.equal(result.sawTerminalTurn, true,
    `the pinned DSH session never appended turn/end after session/cancel${detail}`)
  assert.equal(result.lastRecordType, 'turn/end',
    `the session journal does not end on turn/end${detail}`)
  assert.equal(result.lastTurnEndReason, 'aborted',
    `turn/end did not record the abort${detail}`)
  assert.equal(result.lastTurnEndCause, 'user',
    `turn/end did not record the user cancel cause${detail}`)

  console.error(`abort-journal: pinned DSH journaled ${result.lastRecordType} `
    + `reason=${String(result.lastTurnEndReason)} cause=${String(result.lastTurnEndCause)} `
    + `after cancelling a pending model stream (${result.journalPath})`)
})
