#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Desktop simulation of the phone runtime: runs the bundled DSH
// (dist/dsh-phone.mjs) under `node --jitless` against the reference exec bridge
// and the scripted mock model, and records cold start, RSS, crash-resume and
// lifecycle-gate behaviour. No real model API and no credentials are used.
//
//   node sim/run-demo.mjs [--out <dir>] [--runs 5] [--node <path>] [--only cold,kill,...] [--bundle <file>]
//
// Scenarios: cold (cold start / RSS, jitless vs JIT), kill (SIGKILL mid bash
// command, resume), done (crash after the journal's `done` record, resume),
// rerun (crash after `start` of a read-only grep, resume), gate (lifecycle
// pause / stop), proxy (model traffic through the host HTTP egress), mcp (a
// phone tool on the app's loopback MCP endpoint, streamable HTTP + bearer).

import { spawn } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'
import { setTimeout as sleep } from 'node:timers/promises'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const { values: opts } = parseArgs({
  options: {
    out: { type: 'string', default: join(root, 'dist', `demo-${new Date().toISOString().replace(/[:.]/g, '-')}`) },
    runs: { type: 'string', default: '5' },
    node: { type: 'string', default: process.execPath },
    only: { type: 'string', default: 'cold,kill,done,rerun,gate,proxy,mcp' },
    bundle: { type: 'string', default: join(root, 'dist', 'dsh-phone.mjs') },
  },
})
if (!existsSync(resolve(opts.bundle))) throw new Error(`build the bundle first: node bundle/build.mjs (missing ${opts.bundle})`)
// Run a copy outside the source tree: nothing may resolve through node_modules or a nearby package.json.
const bundle = join(mkdtempSync(join(tmpdir(), 'pdsh-dsh-bundle-')), 'dsh-phone.mjs')
copyFileSync(resolve(opts.bundle), bundle)
const out = resolve(opts.out)
mkdirSync(out, { recursive: true })
const only = new Set(opts.only.split(','))
const results = { node: opts.node, nodeVersion: undefined, bundle, bundleSource: resolve(opts.bundle), scenarios: {} }
let dirCounter = 0

function log(line) { process.stdout.write(`${line}\n`) }

/** Spawn a helper that prints one JSON ready line on stdout. */
async function startHelper(script, args, logFile) {
  const child = spawn(process.execPath, [join(here, script), ...args], { stdio: ['ignore', 'pipe', 'pipe'] })
  const errors = []
  child.stderr.on('data', (chunk) => { errors.push(chunk); writeFileSync(logFile, Buffer.concat(errors)) })
  const line = await new Promise((resolveLine, reject) => {
    let buffered = ''
    child.stdout.on('data', (chunk) => {
      buffered += chunk
      const newline = buffered.indexOf('\n')
      if (newline >= 0) resolveLine(buffered.slice(0, newline))
    })
    child.once('exit', code => reject(new Error(`${script} exited early (${code})`)))
  })
  return { child, info: JSON.parse(line), stderr: () => Buffer.concat(errors).toString('utf8') }
}

async function environment(name, llmArgs = []) {
  const dir = join(out, `${String(++dirCounter).padStart(2, '0')}-${name}`)
  const ws = join(dir, 'ws')
  const home = join(dir, 'home')
  mkdirSync(ws, { recursive: true })
  mkdirSync(home, { recursive: true })
  writeFileSync(join(ws, 'notes.txt'), 'charge policy: charge the ledger at most once per task\n')
  const sim = await startHelper('exec-bridge-sim.mjs', ['--workspace', ws, '--token-file', join(dir, 'bridge.token')], join(dir, 'sim.log'))
  const llm = await startHelper('mock-llm.mjs', llmArgs, join(dir, 'mock-llm.log'))
  return {
    dir, ws: sim.info.workspace, home, sim, llm,
    token: readFileSync(join(dir, 'bridge.token'), 'utf8').trim(),
    stop() { sim.child.kill('SIGTERM'); llm.child.kill('SIGTERM') },
  }
}

/** Run the bundled DSH once. */
function runDsh(env, task, { jitless = true, extraEnv = {}, sessionId, label = 'run', onSpawn } = {}) {
  const args = [
    ...jitless ? ['--jitless'] : [],
    bundle, '--xl-patch', join(here, 'sim.cordis.patch.yml'),
    ...sessionId === undefined ? [] : ['--session-id', sessionId],
    task,
  ]
  const started = performance.now()
  const child = spawn(opts.node, args, {
    cwd: env.ws,
    env: {
      PATH: '/usr/bin:/bin', HOME: env.home, DSH_HOME: env.home,
      PDSH_EXEC_BRIDGE_URL: env.sim.info.url, PDSH_EXEC_BRIDGE_TOKEN: env.token,
      PDSH_SIM_LLM_URL: `${env.llm.info.url}/mock-llm`, DEEPSEEK_API_KEY: 'mock-not-a-secret',
      PDSH_DSH_TIMING: '1', PDSH_DSH_LOG: 'info', DSH_TELEMETRY_DISABLED: '1',
      // The sim runs commands directly on this machine and advertises no confinement.
      PDSH_SANDBOX_MODE: 'danger-full-access', ...extraEnv,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  onSpawn?.(child)
  let stdout = ''
  let stderr = ''
  child.stdout.on('data', (chunk) => { stdout += chunk })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return new Promise((resolveRun) => {
    child.once('exit', (code, signal) => {
      const wallMs = performance.now() - started
      writeFileSync(join(env.dir, `${label}.stdout.txt`), stdout)
      writeFileSync(join(env.dir, `${label}.stderr.txt`), stderr)
      const booted = /pdsh-dsh: booted in \d+ms .* t=(\d+)ms rss=([\d.]+)MiB/.exec(stderr)
      const maxRss = /pdsh-dsh: maxRSS=([\d.]+)MiB/.exec(stderr)
      resolveRun({
        code, signal, wallMs: Math.round(wallMs), stdout: stdout.trim(), stderr,
        bootMs: booted ? Number(booted[1]) : undefined,
        bootRssMiB: booted ? Number(booted[2]) : undefined,
        maxRssMiB: maxRss ? Number(maxRss[1]) : undefined,
      })
    })
  })
}

function sessionIds(env) {
  const base = join(env.home, 'sessions')
  if (!existsSync(base)) return []
  return readdirSync(base).flatMap(project => readdirSync(join(base, project)).filter(name => name.startsWith('session-')).map(id => ({ id, dir: join(base, project, id) })))
}

function sessionEvents(env, id) {
  const session = sessionIds(env).find(entry => entry.id === id)
  const file = readdirSync(session.dir).find(name => /^session\.v\d+\.jsonl$/.test(name))
  return readFileSync(join(session.dir, file), 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line))
}

function journal(env, id) {
  const file = join(env.home, 'tool-journal', `${id}.journal.ndjson`)
  return existsSync(file) ? readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line)) : []
}

const ledgerLines = env => existsSync(join(env.ws, 'ledger.txt')) ? readFileSync(join(env.ws, 'ledger.txt'), 'utf8').split('\n').filter(Boolean) : []
const summarizeTools = events => events.filter(e => e.type === 'tool/call' || e.type === 'tool/result').map(e => e.type === 'tool/call'
  ? `#${e.seq} call ${e.data.name} ${e.data.callId}`
  : `#${e.seq} result${e.data.message.id.startsWith('pdsh-journal-') ? ' [from tool journal]' : ''} ${e.data.error?.code ?? (e.data.message.isError ? 'error' : 'ok')}: ${JSON.stringify(e.data.message.content?.[0]?.text ?? '').slice(0, 90)}`)
const stats = values => {
  const sorted = [...values].sort((a, b) => a - b)
  return { min: sorted[0], median: sorted[Math.floor(sorted.length / 2)], max: sorted.at(-1) }
}

async function crashResume(name, { faultEnv, llmArgs, killWhen }) {
  const env = await environment(name, llmArgs)
  try {
    const crashed = await runDsh(env, 'Charge the ledger once and write report.md.', {
      label: 'crash', extraEnv: faultEnv ?? {},
      onSpawn: killWhen === undefined ? undefined : (child) => { void killWhen(env, child) },
    })
    const [{ id }] = sessionIds(env)
    const beforeEvents = sessionEvents(env, id)
    const beforeJournal = journal(env, id)
    const ledgerAfterCrash = ledgerLines(env).length
    await sleep(llmArgs?.includes('--sleep') ? 1000 * Number(llmArgs[llmArgs.indexOf('--sleep') + 1]) + 500 : 500)
    const resumed = await runDsh(env, 'Continue the task.', { label: 'resume', sessionId: id })
    const afterEvents = sessionEvents(env, id)
    const resolved = journal(env, id).filter(r => r.t === 'resolved')
    const resolution = /tool-journal: .*resumed .*/.exec(resumed.stderr)?.[0]
    return {
      sessionId: id,
      crash: { code: crashed.code, signal: crashed.signal, wallMs: crashed.wallMs },
      journalAtCrash: beforeJournal.map(r => r.t === 'header' ? 'header' : `${r.t}:${r.tool ?? r.call_id}`),
      logToolEventsAtCrash: summarizeTools(beforeEvents),
      ledgerLinesAfterCrash: ledgerAfterCrash,
      resume: { code: resumed.code, wallMs: resumed.wallMs, bootMs: resumed.bootMs, maxRssMiB: resumed.maxRssMiB, stdout: resumed.stdout },
      reconcile: resolution ?? resolved.map(r => `${r.call_id}=${r.action}`).join(', '),
      logToolEventsAfterResume: summarizeTools(afterEvents),
      ledgerLinesAfterResume: ledgerLines(env).length,
      mockRequests: env.llm.stderr().trim().split('\n'),
    }
  } finally {
    env.stop()
  }
}

async function main() {
  results.nodeVersion = await new Promise((resolveVersion) => {
    const child = spawn(opts.node, ['--version'])
    let text = ''
    child.stdout.on('data', (chunk) => { text += chunk })
    child.once('exit', () => resolveVersion(text.trim()))
  })
  log(`node ${results.nodeVersion}, bundle ${bundle}, out ${out}`)

  if (only.has('cold')) {
    const runs = Number(opts.runs)
    for (const jitless of [true, false]) {
      const samples = []
      for (let i = 0; i < runs; i++) {
        const env = await environment(`cold-${jitless ? 'jitless' : 'jit'}-${i}`, ['--sleep', '0'])
        try {
          const run = await runDsh(env, 'Charge the ledger once and write report.md.', { jitless, label: 'run' })
          if (run.code !== 0) throw new Error(`cold run failed: ${run.stderr}`)
          samples.push(run)
        } finally { env.stop() }
      }
      const key = jitless ? 'cold_jitless' : 'cold_jit'
      results.scenarios[key] = {
        runs,
        bootMs: stats(samples.map(s => s.bootMs)),
        taskWallMs: stats(samples.map(s => s.wallMs)),
        bootRssMiB: stats(samples.map(s => s.bootRssMiB)),
        maxRssMiB: stats(samples.map(s => s.maxRssMiB)),
      }
      log(`${key}: ${JSON.stringify(results.scenarios[key])}`)
    }
  }

  if (only.has('kill')) {
    // SIGKILL while the guest command is running (after its side effect, during `sleep 6`).
    results.scenarios.kill_mid_tool = await crashResume('kill', {
      llmArgs: ['--sleep', '6'],
      killWhen: async (env, child) => {
        while (!existsSync(join(env.ws, 'ledger.txt'))) {
          if (child.exitCode !== null || child.signalCode !== null) throw new Error('the harness exited before the guest command started; see crash.stderr.txt')
          await sleep(20)
        }
        await sleep(300)
        child.kill('SIGKILL')
      },
    })
    log(`kill_mid_tool: ${JSON.stringify(results.scenarios.kill_mid_tool, null, 2)}`)
  }

  if (only.has('done')) {
    // The process dies right after the journal's `done` record, before the session checkpoint.
    results.scenarios.crash_after_done = await crashResume('done', { llmArgs: ['--sleep', '0'], faultEnv: { PDSH_JOURNAL_FAULT: 'after-done' } })
    log(`crash_after_done: ${JSON.stringify(results.scenarios.crash_after_done, null, 2)}`)
  }

  if (only.has('rerun')) {
    // The process dies right after `start` of a read-only grep; resume re-runs it.
    results.scenarios.rerun_read_only = await crashResume('rerun', { llmArgs: ['--sleep', '0', '--script', 'search'], faultEnv: { PDSH_JOURNAL_FAULT: 'after-start' } })
    log(`rerun_read_only: ${JSON.stringify(results.scenarios.rerun_read_only, null, 2)}`)
  }

  if (only.has('gate')) {
    const env = await environment('gate', ['--sleep', '0'])
    try {
      const control = async (state) => {
        const response = await fetch(`${env.sim.info.url}/v1/sim/lifecycle`, {
          method: 'POST', headers: { authorization: `Bearer ${env.token}`, 'content-type': 'application/json' },
          body: JSON.stringify({ state, reason: state === 'run' ? 'foreground' : 'background_budget_exhausted' }),
        })
        return response.json()
      }
      await control('pause')
      const pausedFor = 2000
      let requestsWhilePaused
      const run = runDsh(env, 'Charge the ledger once and write report.md.', { label: 'pause' })
      await sleep(pausedFor)
      requestsWhilePaused = env.llm.stderr().split('\n').filter(Boolean).length
      await control('run')
      const paused = await run
      await control('stop')
      const stopped = await runDsh(env, 'Charge the ledger again.', { label: 'stop' })
      await control('run')
      results.scenarios.lifecycle_gate = {
        pause: { code: paused.code, wallMs: paused.wallMs, heldMs: pausedFor, modelRequestsWhilePaused: requestsWhilePaused, stdout: paused.stdout },
        stop: { code: stopped.code, stderrTail: stopped.stderr.trim().split('\n').filter(l => !l.startsWith('pdsh-dsh:')).slice(-2) },
        ledgerLines: ledgerLines(env).length,
      }
      log(`lifecycle_gate: ${JSON.stringify(results.scenarios.lifecycle_gate, null, 2)}`)
    } finally { env.stop() }
  }

  if (only.has('proxy')) {
    const env = await environment('proxy', ['--sleep', '0'])
    try {
      const run = await runDsh(env, 'Charge the ledger once and write report.md.', { label: 'run', extraEnv: { PDSH_LLM_VIA_HOST: 'all' } })
      results.scenarios.host_proxy = {
        code: run.code, wallMs: run.wallMs, stdout: run.stdout,
        proxiedRequests: env.sim.stderr().split('\n').filter(line => line.includes('/v1/http')).length,
      }
      log(`host_proxy: ${JSON.stringify(results.scenarios.host_proxy)}`)
    } finally { env.stop() }
  }

  if (only.has('mcp')) {
    const env = await environment('mcp', ['--sleep', '0', '--script', 'mcp'])
    const mcp = await startHelper('phone-mcp-sim.mjs', [], join(env.dir, 'phone-mcp.log'))
    try {
      const run = await runDsh(env, 'Save the phone clipboard to clipboard.md.', {
        label: 'run', extraEnv: { PDSH_PHONE_MCP_URL: mcp.info.url, PDSH_PHONE_MCP_TOKEN: mcp.info.token },
      })
      const saved = existsSync(join(env.ws, 'clipboard.md')) ? readFileSync(join(env.ws, 'clipboard.md'), 'utf8').trim() : undefined
      results.scenarios.phone_mcp = { code: run.code, wallMs: run.wallMs, stdout: run.stdout, clipboardMd: saved, server: mcp.stderr().trim().split('\n') }
      log(`phone_mcp: ${JSON.stringify(results.scenarios.phone_mcp, null, 2)}`)
    } finally { mcp.child.kill('SIGTERM'); env.stop() }
  }

  writeFileSync(join(out, 'results.json'), `${JSON.stringify(results, null, 2)}\n`)
  log(`wrote ${join(out, 'results.json')}`)
}

main().catch((error) => { process.stderr.write(`${error.stack ?? error}\n`); process.exit(1) })
