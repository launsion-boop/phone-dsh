// SPDX-License-Identifier: MIT
/**
 * The P0 chat defect: a Worker session must be *resumed*, not replaced.
 *
 * The App used to open a new Worker session whenever the first turn of a
 * conversation did not start, which happens when `session/prompt` repeats a
 * `requestId` the Session already recorded (`hasPromptRequest` answers
 * `{accepted:true}` and never delivers). The transcript kept the earlier
 * messages, the model did not, and the follow-up question was answered
 * `UNKNOWN` — with nothing on screen saying the context was gone.
 *
 * This test drives the real pinned Worker (not a fake) in two child processes:
 *
 *   1. boot, one turn, then a second `session/prompt` with the **same**
 *      `requestId`: it must not start a turn and must not reach the model. The
 *      process also drains the persisted `/dsh/home/sessions` tree.
 *   2. a **new process** mounts that tree as its boot overlay (the same
 *      `/dsh/home/**` the Android host repacks from `materialized/home`), sends
 *      the product's recall question to the same session id with a fresh
 *      `requestId`, and the scripted model answers from the request transcript
 *      it actually received.
 *
 * Only model output is scripted. Session persistence, the boot overlay, the
 * resume path and the prompt idempotency are the pinned runtime's own.
 *
 * Skipped without `PDSH_DSH_CHECKOUT`; WebKit/on-device execution is NOT
 * verified by this file (it runs the Worker runtime under Node).
 */
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gzipSync } from 'node:zlib'
import { after, test } from 'node:test'

import { build } from 'esbuild'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the Worker runtime and the packed image come from the pinned checkout'
  : false

/** Temp directories created by this file. */
const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

interface CaptureLine {
  level: string
  text: string
}

interface ResumeProbe {
  phase?: string
  sessionId?: string
  duplicateAccepted?: boolean
  duplicateStartedTurn?: boolean
  duplicateModelRequests?: number
  turnsAfterDuplicate?: number
  recallAnswer?: string
  requestCarriedEarlierPrompt?: boolean
  requestCarriedRecallPrompt?: boolean
  modelRequests?: number
  newLogBytes?: number
}

interface HarnessResult {
  ok: boolean
  thrown?: string
  probe?: ResumeProbe
  lines: CaptureLine[]
}

const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'

/**
 * Bundle the resume harness against the pinned checkout's runtime sources.
 * @param options - bundle inputs.
 * @param options.outfile - bundled harness path.
 * @param options.checkout - verified pinned checkout.
 * @returns resolves when esbuild wrote the harness.
 */
async function bundleHarness(options: { outfile: string; checkout: string }): Promise<void> {
  const runtimeSrc = join(options.checkout, 'packages/experimental/webworker-runtime/src')
  await build({
    entryPoints: [join(root, 'tests', 'fixtures', 'session-resume-harness.ts')],
    outfile: options.outfile,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    external: ['node:*'],
    banner: {
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
 * Run the harness to completion and read its one result line.
 * @param options - process inputs.
 * @returns the parsed result plus raw streams for a failure message.
 */
function runHarness(options: {
  harness: string
  image: string
  environment: NodeJS.ProcessEnv
}): Promise<{ result?: HarnessResult; status: number | null; stdout: string; stderr: string }> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(process.execPath, [options.harness, options.image], {
      env: options.environment,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const stdout: Buffer[] = []
    const stderr: Buffer[] = []
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk))
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk))
    child.once('error', rejectRun)
    child.once('close', status => {
      const out = Buffer.concat(stdout).toString('utf8')
      const lines = out.split('\n')
      const marker = lines.find(line => line.startsWith('__PDSH_RESUME_RESULT__ '))
      let result: HarnessResult | undefined
      if (marker !== undefined) {
        result = JSON.parse(marker.slice('__PDSH_RESUME_RESULT__ '.length)) as HarnessResult
      }
      resolveRun({ result, status, stdout: out, stderr: Buffer.concat(stderr).toString('utf8') })
    })
  })
}

test('a Worker session is resumed across a reboot, so the model keeps the earlier turn', {
  skip,
  timeout: 300_000,
}, async () => {
  assert.notEqual(checkout, undefined)
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-session-resume-'))
  scratch.push(directory)
  const imageDirectory = join(directory, 'image')
  const environment = { ...process.env, PDSH_DSH_CHECKOUT: checkout }

  const pack = spawnSync(process.execPath, [join(root, 'scripts', 'pack-image.mjs'), '--out', imageDirectory], {
    cwd: root,
    env: environment,
    encoding: 'utf8',
  })
  assert.equal(pack.status, 0, `pack-image failed (${String(pack.status)}):\n${pack.stdout}\n${pack.stderr}`)
  const image = join(imageDirectory, 'image.tar.gz')

  const harness = join(directory, 'session-resume-harness.mjs')
  await bundleHarness({ outfile: harness, checkout: checkout as string })

  // ---- boot 1: the duplicate requestId is swallowed, and the home is drained.
  const home = join(directory, 'home-out')
  mkdirSync(home, { recursive: true })
  const first = await runHarness({
    harness,
    image,
    environment: {
      ...environment,
      PDSH_EMULATE_JSC: '1',
      PDSH_RESUME_PHASE: 'first',
      PDSH_RESUME_HOME_OUT: home,
    },
  })
  assert.ok(first.result !== undefined, `boot 1 wrote no result line\n${first.stdout}\n${first.stderr}`)
  const firstResult = first.result as HarnessResult
  assert.equal(firstResult.ok, true, `boot 1 failed: ${firstResult.thrown ?? 'unknown'}\n${first.stderr}`)
  const firstProbe = firstResult.probe
  assert.ok(firstProbe?.sessionId, 'boot 1 created no session')
  // The root cause: a repeated requestId is accepted and never delivered.
  assert.equal(
    firstProbe?.duplicateAccepted,
    true,
    'the duplicate prompt was not answered accepted; the swallow this test reproduces has changed shape',
  )
  assert.equal(
    firstProbe?.duplicateStartedTurn,
    false,
    'a repeated requestId started a turn: the dedupe this defect depends on no longer applies',
  )
  assert.equal(
    firstProbe?.duplicateModelRequests,
    0,
    `a repeated requestId reached the model ${String(firstProbe?.duplicateModelRequests)} time(s)`,
  )
  assert.equal(firstProbe?.turnsAfterDuplicate, 1, 'the session log does not hold exactly the first turn')

  // The persisted home is the next boot's overlay; the same gzip(ustar) envelope
  // the Android host hands to the Worker (`wal.md` §8, D21).
  const overlayTar = join(directory, 'overlay.tar')
  const overlay = spawnSync(process.execPath, [
    join(root, 'scripts', 'pack-overlay.mjs'), home, '--out', overlayTar,
  ], { cwd: root, env: environment, encoding: 'utf8' })
  assert.equal(overlay.status, 0, `pack-overlay failed:\n${overlay.stdout}\n${overlay.stderr}`)
  const overlayGzip = join(directory, 'overlay.tar.gz')
  writeFileSync(overlayGzip, gzipSync(readFileSync(overlayTar)))

  // ---- boot 2: a new process, the same session id, a fresh requestId.
  const requestsOut = join(directory, 'requests.json')
  const second = await runHarness({
    harness,
    image,
    environment: {
      ...environment,
      PDSH_EMULATE_JSC: '1',
      PDSH_RESUME_PHASE: 'second',
      PDSH_RESUME_OVERLAY: overlayGzip,
      PDSH_RESUME_SESSION: firstProbe?.sessionId ?? '',
      PDSH_RESUME_REQUESTS_OUT: requestsOut,
    },
  })
  assert.ok(second.result !== undefined, `boot 2 wrote no result line\n${second.stdout}\n${second.stderr}`)
  const secondResult = second.result as HarnessResult
  assert.equal(secondResult.ok, true, `boot 2 failed: ${secondResult.thrown ?? 'unknown'}\n${second.stderr}`)
  const secondProbe = secondResult.probe
  assert.equal(
    secondProbe?.requestCarriedRecallPrompt,
    true,
    'the recall question never reached the model in boot 2',
  )
  assert.equal(
    secondProbe?.requestCarriedEarlierPrompt,
    true,
    'the model request on the resumed session did not carry the earlier user message: ' +
      'the session was not resumed with its durable history',
  )
  assert.equal(
    secondProbe?.recallAnswer,
    'CONTEXT-OK 323',
    `the scripted model answered ${String(secondProbe?.recallAnswer)}: the resumed request had no earlier context`,
  )
})
