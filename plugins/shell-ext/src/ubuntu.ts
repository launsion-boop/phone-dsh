// SPDX-License-Identifier: MIT
/**
 * The `ubuntu` Worker command: one command in a separate local Linux environment.
 *
 * ---- why this is a command and not an accelerator ----
 * `bridge.md` §12 makes `ubuntu.exec` a *host tool*, not a read-only
 * accelerator: it admits a job that writes, so it must not ride exec.md §3's
 * read-only accelerator contract. The Agent still works through `bash`, and the
 * Agent-facing entry is one command in the production table
 * ({@link createWorkerCommands}), next to `rg`, `jq` and `python3`.
 *
 * ---- why the command exists only when the host advertised it ----
 * A host with no local environment must answer `ubuntu: command not found` /
 * 127 — not a timeout and not a silent success. That is design §4.3's rule:
 * "this device does not have that capability" becomes an honest, observable
 * fact. The host advertises by answering the boot probe (`phone ubuntu probe`),
 * which the Worker entry runs before the first command table is built;
 * {@link setUbuntuCapability} publishes that answer and
 * {@link createUbuntuCommand} is registered from it. Nothing here invents a
 * capability string on the channel wire (channel.md §4.1 reserves those) and
 * nothing here joins the accelerator names (exec.md §3 keeps those read-only).
 *
 * ---- the host tool this command drives ----
 * `ubuntu` sends `phone ubuntu <op> ...` through the same host-tool dispatcher
 * every phone command uses. The ops are the bridge.md §12 vocabulary:
 *
 *   `run`    → `ubuntu.exec`: approve this session, admit one job, answer its record
 *   `status` → `ubuntu.status`: the current record, or a refusal for an unknown job
 *   `fetch`  → `ubuntu.fetch`: one artifact chunk (the Worker writes it)
 *   `close`  → close the environment (the Agent may stop it when done)
 *
 * The host answers one JSON object on stdout, so this command is the only place
 * that decides how a job is rendered for the model. The rendering is explicit
 * about `backend=mock`: a synthetic 0 must never read as a real compile,
 * because "did it really run?" is the question this lane exists to keep
 * answerable.
 *
 * ---- the approval gate is the host's, and this command feeds it ----
 * `run` forwards the ambient tool-call session id (from the trusted
 * `currentToolCall()` context, never from a shell variable) so the host can
 * scope one approval to one session. The id travels **out of band**: it is an
 * `AcceleratorRequest.sessionId` field that the bridge writes into the EXEC_REQ
 * `env` member, never an argv word — `phone` is itself an ordinary command
 * inside `bash`, so a `--session` flag on the host dispatch would be a flag the
 * model can type (`spec/v1/bridge.md` §12's gate exists to stop exactly that).
 * The dialog itself is native (the app's `UbuntuApprovalPrompt`); this file only
 * carries the id and renders the answer. That is why a denial arrives as
 * `failure cause=approval_denied`, not as a host refusal: it is a decision, not
 * a defect.
 *
 * ---- why `fetch` writes through the standard VFS ----
 * The host cannot produce a `VFS_MUT` (channel.md §6 makes the Worker the only
 * writer), so `ubuntu.fetch` hands over at most 512 KiB per call and the
 * command writes the target with the same mutation shape every other Worker
 * write uses: one complete write of at most 15 MiB, then appended suffixes.
 * The mutation split is the runtime's `writeMutationBodies`; this file only
 * chooses the boundaries so a 15 MiB buffer is the most it ever holds.
 * @module @phone-dsh/dsh-shell-ext/ubuntu
 */

import { defineCommand } from 'just-bash/browser'
import type { CustomCommand, IFileSystem } from 'just-bash'
import { currentToolCall } from '@phone-dsh/dsh-exec-bridge'
import type { AcceleratorHost } from './bridge.ts'
import { byteStringToBytes, decodeUtf8 } from './encoding.ts'
import { SHELL_MANIFEST_PATH } from './contract.ts'
import { MAX_FILE_SIZE, singleFileLimitFromEnvironment } from '../../wasi-toolbox/src/limits.ts'

/** Environment id the command defaults to (bridge.md §12.1's first example). */
export const UBUNTU_DEFAULT_ENV = 'ubuntu-24.04'

/** channel.md §6: one `op = 1` mutation carries at most 15 MiB. */
export const UBUNTU_MUTATION_MAX_BYTES = 15 * 1024 * 1024

/** bridge.md §4: one binary payload decodes to at most 512 KiB. */
export const UBUNTU_FETCH_CHUNK_BYTES = 512 * 1024

/** The default artifact directory; matches the host lane's `ARTIFACT_DIR`. */
export const UBUNTU_ARTIFACT_DIR = '.ubuntu'

/** The D6 identifier rule (channel.md §6), which a job id and a session id follow. */
const D6 = /^[A-Za-z0-9._-]{1,64}$/u

/** The manifest leaf rule (bridge.md §12.7), which is never `.` or `..`. */
const ARTIFACT_NAME = /^[A-Za-z0-9._-]{1,64}$/u

/** channel.md §6's mutation path: `/dsh/workspace(/<component>)+`, no `.` or `..`. */
const MUTATION_PATH = /^\/dsh\/workspace(\/[^/]+)+$/u

/**
 * What the host answered when the Worker asked whether it can run jobs.
 *
 * Every member is a fact the host stated; the Worker infers no environment, no
 * backend and no command list.
 */
export interface UbuntuCapability {
  /** `ubuntu-24.04` today; bridge.md §12.1 keeps the environment a parameter. */
  readonly env: string
  /** `mock` while no real environment is attached, so output can say so. */
  readonly backend: string
  /** Ops the host implements: `run`, `status`, `fetch`, `close` (and `probe`). */
  readonly commands: readonly string[]
}

/** One artifact line as the host reports it. */
interface UbuntuArtifactLine {
  readonly name: string
  readonly bytes: number | null
  readonly state: string
  readonly path?: string | undefined
  readonly refusal?: UbuntuRefusal | undefined
}

/** `channel.md` §4.8's resource refusal, reused verbatim (bridge.md §12.7). */
interface UbuntuRefusal {
  readonly code: string
  readonly reason: string
  readonly limit: number
  readonly bytes: number
}

/**
 * The Agent-facing description, selected by the backend the probe reported.
 *
 * This exact text is what the model reads twice: the boot-published
 * `/dsh/home/AGENTS.md` carries it in its `## Local Ubuntu environment`
 * section, and `ubuntu --help` prints it. One builder, one wording per backend,
 * so a `backend=proot` build can never tell the model it is a mock and a
 * `backend=mock` build keeps the warning that its exit 0 is synthetic.
 *
 * @param backend - the probe's backend string (`mock`, `proot`, or a future id).
 * @returns the complete description for that backend.
 */
export function ubuntuDescription(backend: string): string {
  const mock = backend === 'mock'
  return [
    '`ubuntu` runs **one command in a separate local Linux environment**. It is for tasks that need',
    'a full Linux userland: a toolchain (`gcc`, `make`, ...), a package manager, or a program that',
    'only runs on Linux.',
    '',
    '**It does not run DSH.** The turn, the context, the session and every file stay in DSH.',
    'Ordinary work — `ls`, `cat`, `grep`, `git`, `python3`, reading, editing, searching — runs in the',
    'existing `bash` and must not start this environment.',
    '',
    '**It costs.** Starting the environment takes time, uses disk and battery. **Close it when you',
    'are done** (`ubuntu close`).',
    '',
    '**The first `run` of a session asks the user to approve it, and this command waits for that',
    'answer.** One approval covers every later `run` in the same session; ending the session (or the',
    'user revoking it) ends the approval. **A refusal is a real failure**: the run comes back',
    '`cause=approval_denied` and nothing starts. Do not retry a refused `run` in the same session —',
    'ask the user why instead. An approval is permission to use the environment, not permission to use',
    'it casually: the cost rules above still apply.',
    '',
    '```',
    'ubuntu run [--env <id>] [--cwd <path>] [--label <text>] [--timeout-ms <n>] -- <command...>',
    'ubuntu status <jobId>',
    'ubuntu fetch <jobId> <name> [--offset <n>] [--path <path>]',
    'ubuntu close',
    '```',
    '',
    '`ubuntu fetch` writes one artifact into the workspace (`/dsh/workspace/.ubuntu/<jobId>/<name>`',
    'by default). It fetches in 512 KiB chunks and writes with the same one-complete-write-plus-append',
    'shape every Worker write uses. An artifact over the environment\'s declared `fileLimitBytes` — or',
    'over this Worker\'s single-file budget — is refused with `VFS_REFUSED` / `file-too-large`, and',
    'nothing is written: a refusal is never a truncated file.',
    '',
    ...mock
      ? [
          '**This build is wired to a MOCK adapter.** The job protocol is real; the environment is not.',
          'Its output says `backend=mock` and its exit code is synthetic, so a mock `exit=0` is not a real',
          'compile or run — never present one as if it were. Files inside it are not kept, and the next',
          'use starts a fresh environment and waits again.',
        ]
      : [
          '**This build runs commands in a real local Ubuntu environment (Ubuntu Base 24.04.5 under',
          'Termux proot).** Its output says `backend=proot`; the exit code and both streams come from the',
          'real guest process. The first use downloads the official Ubuntu tarball (~30 MB, SHA-256',
          'pinned) and extracts roughly 150 MB of disk; `ubuntu close` stops every running job and keeps',
          'that cached rootfs for the next run.',
          '',
          'The environment is not a security boundary: the guest shares this device\'s UID and network,',
          'so a command that uses the network sends bytes off the device, and `/dsh/workspace` is the',
          'only host tree bound into it. The seal covers the three internal roots for the duration of',
          'each job, not the rootfs, the workspace, the database or the API-key file.',
        ],
  ].join('\n')
}

/**
 * The mock backend's description.
 *
 * Kept as a constant because the existing help/manifest tests and the boot
 * document pin this exact text for a mock build; every other backend goes
 * through {@link ubuntuDescription}.
 */
export const UBUNTU_DESCRIPTION = ubuntuDescription('mock')

/** Usage alone, for a malformed invocation. */
export const UBUNTU_USAGE = [
  'usage: ubuntu run [--env <id>] [--cwd <path>] [--label <text>] [--timeout-ms <n>] -- <command...>',
  '       ubuntu status <jobId>',
  '       ubuntu fetch <jobId> <name> [--offset <n>] [--path <path>]',
  '       ubuntu close',
].join('\n')

/** The shape the Worker entry publishes and the table reads. */
interface UbuntuGlobal {
  __PDSH_UBUNTU__?: UbuntuCapability | undefined
}

/**
 * Publish the host's answer for this boot.
 *
 * Called by the Worker entry after it probes the host. `undefined` clears it,
 * which is what a host that did not answer leaves behind: no command, so the
 * shell answers `ubuntu: command not found` and exits 127.
 *
 * The answer lives on `globalThis`, not in this module, because the Worker has
 * two module graphs: the entry bundle that runs the probe and the image's
 * plugin bundle that builds the shell table. A module-local value would not
 * cross from one to the other.
 * @param capability - the host's answer, or undefined when it has none.
 */
export function setUbuntuCapability(capability: UbuntuCapability | undefined): void {
  const globals = globalThis as UbuntuGlobal
  if (capability === undefined) {
    delete globals.__PDSH_UBUNTU__
    return
  }
  globals.__PDSH_UBUNTU__ = {
    env: capability.env,
    backend: capability.backend,
    commands: [...capability.commands],
  }
}

/**
 * The host's probe answer for this boot, or undefined when it did not answer.
 * @returns a copy of the published capability, or undefined.
 */
export function getUbuntuCapability(): UbuntuCapability | undefined {
  const published = (globalThis as UbuntuGlobal).__PDSH_UBUNTU__
  if (published === undefined) return undefined
  if (typeof published.env !== 'string' || published.env === '') return undefined
  if (typeof published.backend !== 'string' || published.backend === '') return undefined
  if (!Array.isArray(published.commands)) return undefined
  return {
    env: published.env,
    backend: published.backend,
    commands: published.commands.filter((name): name is string => typeof name === 'string'),
  }
}

/** The JSON object one host-tool op answers on stdout. */
interface UbuntuHostReply {
  readonly backend?: unknown
  readonly env?: unknown
  readonly jobId?: unknown
  readonly name?: unknown
  readonly state?: unknown
  readonly seq?: unknown
  readonly exitCode?: unknown
  readonly logTail?: unknown
  readonly artifacts?: unknown
  readonly failure?: unknown
  readonly internalAccessObserved?: unknown
  readonly seal?: unknown
  readonly sealMock?: unknown
  readonly egress?: unknown
  readonly authorityExited?: unknown
  readonly limits?: unknown
  readonly approval?: unknown
  readonly offset?: unknown
  readonly bytes?: unknown
  readonly eof?: unknown
  readonly chunk?: unknown
  readonly refusal?: unknown
}

/** The host's answer to one op. */
interface HostAnswer {
  readonly text: string
  readonly stderr: string
  readonly exitCode: number
}

/** Parse one host answer; undefined when it is not a usable object. */
function decodeReply(text: string): UbuntuHostReply | undefined {
  const trimmed = text.trim()
  if (!trimmed.startsWith('{')) return undefined
  try {
    const parsed: unknown = JSON.parse(trimmed)
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
      ? parsed as UbuntuHostReply
      : undefined
  } catch {
    return undefined
  }
}

/** A string member, or undefined when the host did not send one. */
function stringOf(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

/** A finite non-negative integer member, or undefined. */
function countOf(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : undefined
}

/** Render an exit code as `exit=<n>` / `exit=none`. */
function exitLabel(value: unknown): string {
  return typeof value === 'number' && Number.isInteger(value) ? `exit=${String(value)}` : 'exit=none'
}

/** Format bytes the way the capability manifest does. */
function formatBytes(bytes: number): string {
  if (bytes % (1024 * 1024) === 0) return `${String(bytes / (1024 * 1024))} MiB`
  if (bytes % 1024 === 0) return `${String(bytes / 1024)} KiB`
  return `${String(bytes)} B`
}

/** The artifact rows the host sent, defensively. */
function artifactsOf(reply: UbuntuHostReply): UbuntuArtifactLine[] {
  if (!Array.isArray(reply.artifacts)) return []
  const rows: UbuntuArtifactLine[] = []
  for (const value of reply.artifacts) {
    if (typeof value !== 'object' || value === null) continue
    const record = value as Record<string, unknown>
    const name = stringOf(record.name)
    if (name === undefined) continue
    rows.push({
      name,
      bytes: countOf(record.bytes) ?? null,
      state: stringOf(record.state) ?? 'unknown',
      path: stringOf(record.path),
      refusal: refusalOf(record.refusal),
    })
  }
  return rows
}

/** One `{code, reason, limit, bytes}` refusal, or undefined. */
function refusalOf(value: unknown): UbuntuRefusal | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const record = value as Record<string, unknown>
  const reason = stringOf(record.reason)
  const limit = countOf(record.limit)
  const bytes = countOf(record.bytes)
  if (reason === undefined || limit === undefined || bytes === undefined) return undefined
  return { code: stringOf(record.code) ?? 'VFS_REFUSED', reason, limit, bytes }
}

/** One `{state, reason}` seal member, or undefined. */
function sealOf(reply: UbuntuHostReply): { state: string; reason: string | undefined } | undefined {
  if (typeof reply.seal !== 'object' || reply.seal === null) return undefined
  const record = reply.seal as Record<string, unknown>
  const state = stringOf(record.state)
  if (state === undefined) return undefined
  return { state, reason: stringOf(record.reason) }
}

/** The `approval` member, or undefined. */
function approvalOf(reply: UbuntuHostReply): { state: string; sessionId: string | undefined } | undefined {
  if (typeof reply.approval !== 'object' || reply.approval === null) return undefined
  const record = reply.approval as Record<string, unknown>
  const state = stringOf(record.state)
  if (state === undefined) return undefined
  return { state, sessionId: stringOf(record.sessionId) }
}

/** The failure member, or undefined. */
function failureOf(reply: UbuntuHostReply): Record<string, unknown> | undefined {
  return typeof reply.failure === 'object' && reply.failure !== null
    ? reply.failure as Record<string, unknown>
    : undefined
}

/**
 * Render one job answer as text the model can read.
 *
 * The header carries the facts a caller needs to decide whether anything ran
 * and where it ran; the log tail is the command's last lines, never a head
 * (bridge.md §12.8); the artifact list is the manifest, not the bytes (a fetch
 * is a separate call). `backend=mock` is always shown when the host said so,
 * and the seal line says when the seal is the mock's. The approval line says
 * what the session gate decided, because "the user allowed this" is part of the
 * job's story.
 * @param reply - the decoded host answer.
 * @param command - the CLI verb that produced it, for the first line.
 * @returns stdout text; the caller decides the exit code.
 */
export function renderUbuntuReply(reply: UbuntuHostReply, command: 'run' | 'status'): string {
  const state = stringOf(reply.state) ?? 'unknown'
  const backend = stringOf(reply.backend)
  const env = stringOf(reply.env)
  const jobId = stringOf(reply.jobId)
  const lines: string[] = [
    `ubuntu: ${command} job=${jobId ?? 'unknown'} state=${state} ${exitLabel(reply.exitCode)}`
      + `${env === undefined ? '' : ` env=${env}`}`
      + `${backend === undefined ? '' : ` backend=${backend}`}`,
  ]
  const egress = typeof reply.egress === 'boolean' ? ` egress=${String(reply.egress)}` : ''
  const authority = stringOf(reply.authorityExited)
  lines.push(`ubuntu:${egress}${authority === undefined ? '' : ` authorityExited=${authority}`}`)

  const approval = approvalOf(reply)
  if (approval !== undefined) lines.push(`ubuntu: approval=${approval.state}`)

  const seal = sealOf(reply)
  if (seal !== undefined) {
    const mock = reply.sealMock === true
      ? ' (mock: this adapter seals no workspace and reads no internal root)'
      : ''
    const observed = reply.internalAccessObserved === null || reply.internalAccessObserved === undefined
      ? 'null'
      : String(reply.internalAccessObserved)
    lines.push(
      `ubuntu: seal=${seal.state}${seal.reason === undefined ? '' : ` reason=${seal.reason}`}${mock}`
        + ` internalAccessObserved=${observed}`,
    )
  }

  const failure = failureOf(reply)
  if (failure !== undefined) {
    const code = stringOf(failure.code) ?? 'unknown'
    const message = stringOf(failure.message) ?? ''
    const outcome = stringOf(failure.outcome)
    const cause = stringOf(failure.cause)
    lines.push(
      `ubuntu: failure code=${code}`
        + `${outcome === undefined ? '' : ` outcome=${outcome}`}`
        + `${cause === undefined ? '' : ` cause=${cause}`}`
        + `${message === '' ? '' : `: ${message}`}`,
    )
  }

  const tail = typeof reply.logTail === 'string' ? reply.logTail : ''
  if (tail !== '') {
    lines.push('--- log tail ---')
    lines.push(tail.endsWith('\n') ? tail.slice(0, -1) : tail)
  }

  const artifacts = artifactsOf(reply)
  if (artifacts.length > 0) {
    lines.push(`--- artifacts (${String(artifacts.length)}) ---`)
    for (const artifact of artifacts) {
      const refusal = artifact.refusal === undefined
        ? ''
        : ` ${artifact.refusal.code} reason=${artifact.refusal.reason} limit=${String(artifact.refusal.limit)}`
      const written = artifact.path === undefined ? '' : ` -> ${artifact.path}`
      lines.push(
        `${artifact.name} ${artifact.bytes === null ? 'unknown' : formatBytes(artifact.bytes)}`
          + ` ${artifact.state}${written}${refusal}`,
      )
    }
  }

  if (state !== 'succeeded' && state !== 'failed' && state !== 'cancelled' && state !== 'ingestRefused') {
    lines.push(`ubuntu: the job is still ${state}; check it with \`ubuntu status ${jobId ?? '<jobId>'}\``)
  }
  return `${lines.join('\n')}\n`
}

/**
 * The exit status a job answer should surface to the shell.
 *
 * A terminal `succeeded` carries the command's own code. `ingestRefused` is a
 * job that ran but whose artifacts could not all be taken, so it is a non-zero
 * for the caller even when the command exited 0. `failed`/`cancelled` and an
 * unfinished job are non-zero too: an admitted-but-running job is not a
 * success yet.
 * @param reply - the decoded host answer.
 * @returns the shell status.
 */
export function exitOfReply(reply: UbuntuHostReply): number {
  const state = stringOf(reply.state)
  if (state === 'succeeded') {
    return typeof reply.exitCode === 'number' && Number.isInteger(reply.exitCode) ? reply.exitCode : 0
  }
  if (state === 'ingestRefused') return 1
  if (state === 'failed' || state === 'cancelled' || state === 'unknown') return 1
  return 0
}

/** One parsed `ubuntu run` invocation. */
interface RunOptions {
  readonly env: string
  readonly cwd: string | undefined
  readonly label: string | undefined
  readonly timeoutMs: string | undefined
  readonly command: readonly string[]
}

/**
 * Parse `run [flags] -- <command...>`.
 *
 * `--session` is not a flag at all: the session id is identity, so it comes from
 * the trusted tool-call context and reaches the host out of band
 * (`AcceleratorRequest.sessionId`). It is refused with a sentence instead of
 * being ignored, so a caller that tries to choose a session learns that the
 * command does not accept one — a silent drop would look like it worked.
 * @param args - argv after the `run` verb.
 * @returns the options, or a string explaining the usage error.
 */
function parseRun(args: readonly string[]): RunOptions | string {
  let env: string | undefined
  let cwd: string | undefined
  let label: string | undefined
  let timeoutMs: string | undefined
  let index = 0
  for (; index < args.length; index += 1) {
    const word = args[index] ?? ''
    if (word === '--') {
      index += 1
      break
    }
    if (word === '--session') {
      return '--session is not a flag: this command takes the session id from the tool call it runs in'
    }
    const value = args[index + 1]
    if (word === '--env' || word === '--cwd' || word === '--label' || word === '--timeout-ms') {
      if (value === undefined) return `${word} needs a value`
      index += 1
      if (word === '--env') env = value
      else if (word === '--cwd') cwd = value
      else if (word === '--label') label = value
      else timeoutMs = value
      continue
    }
    return `unknown option ${JSON.stringify(word)}; put the command after \`--\``
  }
  const command = args.slice(index)
  if (command.length === 0) return 'run needs a command after `--`'
  return { env: env ?? UBUNTU_DEFAULT_ENV, cwd, label, timeoutMs, command }
}

/** One parsed `ubuntu fetch` invocation. */
export interface UbuntuFetchOptions {
  readonly jobId: string
  readonly name: string
  readonly offset: number
  /** The explicit `--path`, or undefined for the job's default target. */
  readonly path: string | undefined
}

/**
 * Parse `fetch <jobId> <name> [--offset N] [--path P]`.
 * @param args - argv after the `fetch` verb.
 * @returns the options, or a string explaining the usage error.
 */
export function parseUbuntuFetch(args: readonly string[]): UbuntuFetchOptions | string {
  const positional: string[] = []
  let offset = 0
  let path: string | undefined
  let index = 0
  while (index < args.length) {
    const word = args[index] ?? ''
    if (word === '--offset' || word === '--path') {
      const value = args[index + 1]
      if (value === undefined) return `${word} needs a value`
      index += 2
      if (word === '--offset') {
        if (!/^(0|[1-9][0-9]*)$/u.test(value)) return '--offset takes a non-negative decimal integer'
        offset = Number(value)
        if (!Number.isSafeInteger(offset)) return '--offset is larger than this shell can address'
      } else {
        if (value === '') return '--path needs a non-empty value'
        path = value
      }
      continue
    }
    if (word.startsWith('--')) return `unknown option ${JSON.stringify(word)}`
    positional.push(word)
    index += 1
  }
  if (positional.length !== 2) return 'fetch needs exactly one job id and one artifact name'
  const jobId = positional[0] ?? ''
  const name = positional[1] ?? ''
  if (!D6.test(jobId)) return `job id ${JSON.stringify(jobId)} is not a D6 identifier`
  if (!ARTIFACT_NAME.test(name) || name === '.' || name === '..') {
    return `artifact name ${JSON.stringify(name)} is not a legal manifest name`
  }
  return { jobId, name, offset, path }
}

/** channel.md §6's mutation path rule, as the host applies it. */
function isMutationPath(path: string): boolean {
  if (!MUTATION_PATH.test(path)) return false
  const components = path.split('/').slice(3)
  return components.length > 0 && components.every(component => component !== '.' && component !== '..')
}

/** One `ubuntu.fetch` answer, decoded. */
type FetchAnswer =
  | { readonly kind: 'chunk'; readonly offset: number; readonly bytes: number; readonly eof: boolean; readonly data: Uint8Array }
  | { readonly kind: 'refused'; readonly refusal: UbuntuRefusal }
  | { readonly kind: 'unavailable'; readonly message: string; readonly hostMissing: boolean }

/** The limits a fetch answer carries, for the Worker-side preflight. */
interface FetchLimits {
  readonly fileLimitBytes: number | undefined
  readonly workspaceLimitBytes: number | undefined
}

/** Decode one `ubuntu.fetch` answer from the host. */
function fetchAnswerOf(answer: HostAnswer): FetchAnswer {
  const decoded = decodeReply(answer.text)
  if (answer.exitCode === 127 || decoded === undefined) {
    const detail = answer.stderr.trim() !== '' ? answer.stderr.trim() : answer.text.trim()
    return {
      kind: 'unavailable',
      message: detail === '' ? 'no usable answer' : detail,
      hostMissing: answer.exitCode === 127,
    }
  }
  const refusal = refusalOf(decoded.refusal)
  if (refusal !== undefined) return { kind: 'refused', refusal }
  const failure = failureOf(decoded)
  if (failure !== undefined) {
    return {
      kind: 'unavailable',
      message: stringOf(failure.message) ?? stringOf(failure.code) ?? 'the fetch was refused',
      hostMissing: false,
    }
  }
  const offset = countOf(decoded.offset)
  const bytes = countOf(decoded.bytes)
  const chunk = stringOf(decoded.chunk)
  if (offset === undefined || bytes === undefined || chunk === undefined || typeof decoded.eof !== 'boolean') {
    return { kind: 'unavailable', message: 'the fetch answer is missing its chunk fields', hostMissing: false }
  }
  const data = new Uint8Array(Buffer.from(chunk, 'base64'))
  if (data.byteLength > UBUNTU_FETCH_CHUNK_BYTES) {
    return { kind: 'unavailable', message: 'the host sent a chunk over the 512 KiB bound', hostMissing: false }
  }
  return { kind: 'chunk', offset, bytes, eof: decoded.eof, data }
}

/** The limits a fetch answer carries, when the host sent them. */
function fetchLimitsOf(answer: HostAnswer): FetchLimits {
  const decoded = decodeReply(answer.text)
  const limits = decoded?.limits
  if (typeof limits !== 'object' || limits === null) {
    return { fileLimitBytes: undefined, workspaceLimitBytes: undefined }
  }
  const record = limits as Record<string, unknown>
  return {
    fileLimitBytes: countOf(record.fileLimitBytes),
    workspaceLimitBytes: countOf(record.workspaceLimitBytes),
  }
}

/** A resource refusal in the exact `VFS_REFUSED` shape channel.md §4.8 names. */
interface FetchRefusalResult {
  readonly reason: string
  readonly limit: number
  readonly bytes: number
}

/**
 * Map a VFS write error onto `channel.md` §4.8's refusal reasons.
 *
 * The prechecks are supposed to refuse before a byte moves; this is the
 * backstop for the cases they cannot know (a workspace that filled up between
 * the precheck and the write). A refusal here still names the resource, so the
 * caller can tell "too big" from "no room".
 * @param error - the thrown value from `writeFile`/`appendFile`.
 * @returns the refusal, or undefined when the error is not a resource refusal.
 */
function resourceRefusalOf(
  error: unknown,
  limits: FetchLimits,
  workerFileLimit: number,
): FetchRefusalResult | undefined {
  const code = (error as { code?: unknown } | null)?.code
  if (code === 'EFBIG') {
    return { reason: 'file-too-large', limit: workerFileLimit, bytes: workerFileLimit }
  }
  // `no-space` is the device's filesystem answering, not a bucket; it has no
  // contract number to name, so the limit is the 0 the refusal shape allows.
  if (code === 'ENOSPC') return { reason: 'no-space', limit: 0, bytes: 0 }
  if (code === 'EDQUOT') {
    return { reason: 'quota-exceeded', limit: limits.workspaceLimitBytes ?? 0, bytes: 0 }
  }
  return undefined
}

/**
 * The rendered refusal line for one artifact.
 *
 * @param refusal the resource refusal.
 * @param written how many bytes of this artifact are already on disk; `0` lets
 *   the line say "nothing was written", and a prefix is never dressed up as
 *   nothing.
 */
function renderFetchRefusal(refusal: UbuntuRefusal | FetchRefusalResult, written = 0): string {
  const tail = written === 0
    ? 'nothing was written'
    : `the file on disk is the first ${String(written)} bytes; delete it or resume with --offset ${String(written)}`
  return `ubuntu: VFS_REFUSED reason=${refusal.reason} limit=${String(refusal.limit)}`
    + ` bytes=${String(refusal.bytes)}; ${tail}\n`
}

/** The default target for one artifact (bridge.md §12.8). */
function defaultFetchPath(jobId: string, name: string): string {
  return `/dsh/workspace/${UBUNTU_ARTIFACT_DIR}/${jobId}/${name}`
}

/** What one fetch needs from the shell context. */
interface FetchContext {
  readonly cwd: string
  readonly fs: IFileSystem
}

/** The result of one `ubuntu fetch`. */
interface FetchOutcome {
  readonly stdout: string
  readonly stderr: string
  readonly exitCode: number
}

/** One fetched chunk at [offset], plus the answer's limits when present. */
async function fetchChunkAt(
  dispatch: (argv: readonly string[]) => Promise<HostAnswer>,
  options: UbuntuFetchOptions,
  target: string,
  offset: number,
): Promise<{ readonly answer: FetchAnswer; readonly limits: FetchLimits }> {
  const argv = [
    'fetch',
    options.jobId,
    options.name,
    '--offset',
    String(offset),
    ...options.path === undefined ? [] : ['--path', target],
  ]
  const raw = await dispatch(argv)
  return { answer: fetchAnswerOf(raw), limits: fetchLimitsOf(raw) }
}

/**
 * Fetch one artifact and write it through the standard VFS mutation shape.
 *
 * The 15 MiB buffer is the only whole-file copy this holds; the chunk loop
 * fetches 512 KiB at a time. A refusal happens before the first write, so a
 * refusal never leaves a truncated file.
 * @param options - the parsed invocation.
 * @param ctx - the shell context (cwd and VFS).
 * @param dispatch - the host-tool round trip.
 * @returns what the command prints and its exit status.
 */
async function fetchArtifact(
  options: UbuntuFetchOptions,
  ctx: FetchContext,
  dispatch: (argv: readonly string[]) => Promise<HostAnswer>,
): Promise<FetchOutcome> {
  const explicitTarget = options.path !== undefined
  const target = explicitTarget
    ? ctx.fs.resolvePath(ctx.cwd, options.path ?? '')
    : defaultFetchPath(options.jobId, options.name)
  if (!isMutationPath(target)) {
    return {
      stdout: '',
      stderr: `ubuntu: ${target} is not a /dsh/workspace mutation path; nothing was written\n`,
      exitCode: 2,
    }
  }

  // Offset 0 is where the host runs the resource precheck, so every fetch asks
  // it even when the caller resumes at a later offset.
  const probe = await fetchChunkAt(dispatch, options, target, 0)
  if (probe.answer.kind === 'refused') {
    return {
      stdout:
        `ubuntu: fetch job=${options.jobId} artifact=${options.name} refused\n`
        + renderFetchRefusal(probe.answer.refusal),
      stderr: '',
      exitCode: 1,
    }
  }
  if (probe.answer.kind === 'unavailable') {
    return fetchUnavailable(options, probe.answer)
  }
  const total = probe.answer.bytes
  const chunks: Uint8Array[] = [probe.answer.data]
  const limits = probe.limits
  // The VFS's effective single-file cap. It is the launch's published
  // `PDSH_SINGLE_FILE_LIMIT_BYTES` when the host named one (the device tier),
  // and only otherwise the process-wide `MAX_FILE_SIZE`. Preflighting with the
  // wrong one is how a 20 MiB artifact used to write 15 MiB and then fail.
  const workerFileLimit = singleFileLimitFromEnvironment() ?? MAX_FILE_SIZE
  if (options.offset > total) {
    return {
      stdout: '',
      stderr: `ubuntu: --offset ${String(options.offset)} is past ${options.name}'s ${String(total)} bytes; `
        + 'nothing was written\n',
      exitCode: 1,
    }
  }

  // Two preflights before the first write. The host's own `fileLimitBytes`
  // comes first (it is the declared JobRef number); the Worker's single-file
  // budget is the local cap the write would hit halfway through the append
  // chain. Refusing here is what keeps a refusal from becoming a truncation.
  if (limits.fileLimitBytes !== undefined && total > limits.fileLimitBytes) {
    return {
      stdout: `ubuntu: fetch job=${options.jobId} artifact=${options.name} refused\n`
        + renderFetchRefusal({
          reason: 'file-too-large',
          limit: limits.fileLimitBytes,
          bytes: total,
        }),
      stderr: '',
      exitCode: 1,
    }
  }
  if (limits.workspaceLimitBytes !== undefined && total > limits.workspaceLimitBytes) {
    return {
      stdout: `ubuntu: fetch job=${options.jobId} artifact=${options.name} refused\n`
        + renderFetchRefusal({
          reason: 'quota-exceeded',
          limit: limits.workspaceLimitBytes,
          bytes: total,
        }),
      stderr: '',
      exitCode: 1,
    }
  }
  if (total > workerFileLimit) {
    return {
      stdout: `ubuntu: fetch job=${options.jobId} artifact=${options.name} refused\n`
        + renderFetchRefusal({ reason: 'file-too-large', limit: workerFileLimit, bytes: total }),
      stderr: '',
      exitCode: 1,
    }
  }

  const exists = await ctx.fs.exists(target)
  if (options.offset > 0) {
    // Resuming: the file on disk must be exactly the accepted prefix.
    if (!exists) {
      return {
        stdout: '',
        stderr: `ubuntu: --offset ${String(options.offset)} needs ${target} to exist with that many bytes; `
          + 'nothing was written\n',
        exitCode: 1,
      }
    }
    const size = (await ctx.fs.stat(target)).size
    if (size !== options.offset) {
      return {
        stdout: '',
        stderr: `ubuntu: --offset ${String(options.offset)} does not match ${target}'s ${String(size)} bytes; `
          + 'nothing was written\n',
        exitCode: 1,
      }
    }
  } else if (exists && explicitTarget) {
    // Never overwrite a file this job did not write. The default target is the
    // job's own path, so a re-fetch there converges instead.
    return {
      stdout: '',
      stderr: `ubuntu: ${target} already exists; refusing to overwrite a file this job did not write `
        + '(pass --path for a new target)\n',
      exitCode: 1,
    }
  }

  // The plan: one complete write of at most 15 MiB, then appended suffixes.
  let cursor = options.offset
  let firstMutation = options.offset === 0
  let mutations = 0
  let fetched = 1
  let wrote = options.offset
  const remaining = total - options.offset
  const totalMutations = remaining > 0
    ? Math.ceil(remaining / UBUNTU_MUTATION_MAX_BYTES)
    : total === 0 && options.offset === 0 ? 1 : 0
  try {
    if (total === 0 && options.offset === 0) {
      await ctx.fs.mkdir(parentsOf(target), { recursive: true })
      await ctx.fs.writeFile(target, new Uint8Array(0))
      mutations += 1
    }
    while (cursor < total) {
      const length = Math.min(total - cursor, UBUNTU_MUTATION_MAX_BYTES)
      const buffer = new Uint8Array(length)
      let filled = 0
      while (filled < length) {
        const at = cursor + filled
        let chunk: Uint8Array | undefined
        if (at === 0 && chunks.length > 0) {
          chunk = chunks.shift()
        } else {
          const next = await fetchChunkAt(dispatch, options, target, at)
          if (next.answer.kind === 'refused') {
            return {
              stdout: `ubuntu: fetch job=${options.jobId} artifact=${options.name} refused after `
                + `${String(wrote)} of ${String(total)} bytes\n` + renderFetchRefusal(next.answer.refusal, wrote),
              stderr: '',
              exitCode: 1,
            }
          }
          if (next.answer.kind === 'unavailable') return fetchUnavailable(options, next.answer)
          fetched += 1
          if (next.answer.offset !== at) {
            return {
              stdout: '',
              stderr: `ubuntu: the host answered offset ${String(next.answer.offset)} for a request at `
                + `${String(at)}; wrote ${String(wrote)} of ${String(total)} bytes (partial)\n`,
              exitCode: 1,
            }
          }
          chunk = next.answer.data
        }
        if (chunk === undefined || chunk.byteLength === 0) {
          return {
            stdout: '',
            stderr: `ubuntu: the host stopped sending ${options.name} at byte ${String(at)}; `
              + `wrote ${String(wrote)} of ${String(total)} bytes (partial)\n`,
            exitCode: 1,
          }
        }
        if (filled + chunk.byteLength > length) {
          return {
            stdout: '',
            stderr: `ubuntu: the host sent a chunk that crosses a mutation boundary; `
              + `wrote ${String(wrote)} of ${String(total)} bytes (partial)\n`,
            exitCode: 1,
          }
        }
        buffer.set(chunk, filled)
        filled += chunk.byteLength
      }
      if (mutations === 0 && firstMutation) {
        await ctx.fs.mkdir(parentsOf(target), { recursive: true })
        await ctx.fs.writeFile(target, buffer)
        firstMutation = false
      } else {
        await ctx.fs.appendFile(target, buffer)
      }
      mutations += 1
      wrote += length
      cursor += length
    }
  } catch (error) {
    const refusal = resourceRefusalOf(error, limits, workerFileLimit)
    if (refusal !== undefined) {
      const detail = error instanceof Error ? error.message : String(error)
      return {
        stdout: `ubuntu: fetch job=${options.jobId} artifact=${options.name} refused after `
          + `${String(wrote)} of ${String(total)} bytes (partial)\n`
          + renderFetchRefusal(refusal, wrote),
        stderr: `${detail}\n`,
        exitCode: 1,
      }
    }
    return {
      stdout: '',
      stderr: `ubuntu: writing ${target} failed: ${error instanceof Error ? error.message : String(error)}; `
        + `wrote ${String(wrote)} of ${String(total)} bytes (partial)\n`,
      exitCode: 1,
    }
  }

  const size = (await ctx.fs.stat(target)).size
  if (size !== total) {
    return {
      stdout: '',
      stderr: `ubuntu: ${target} is ${String(size)} bytes after the write; expected ${String(total)} (partial)\n`,
      exitCode: 1,
    }
  }
  return {
    stdout:
      `ubuntu: fetch job=${options.jobId} artifact=${options.name} bytes=${String(total)}`
      + ` chunks=${String(fetched)} mutations=${String(mutations)}`
      + `${totalMutations === mutations ? '' : ` (planned ${String(totalMutations)})`}\n`
      + `ubuntu: wrote ${target}\n`,
    stderr: '',
    exitCode: 0,
  }
}

/** The parent directory of an absolute mutation path. */
function parentsOf(path: string): string {
  const index = path.lastIndexOf('/')
  return index <= 0 ? '/' : path.slice(0, index)
}

/** The answer for a fetch the host could not serve. */
function fetchUnavailable(options: UbuntuFetchOptions, answer: Extract<FetchAnswer, { kind: 'unavailable' }>): FetchOutcome {
  if (answer.hostMissing) {
    return {
      stdout: '',
      stderr: `ubuntu: fetch needs a host that implements ubuntu.fetch; it answered `
        + `(${answer.message}); see ${SHELL_MANIFEST_PATH}\n`,
      exitCode: 127,
    }
  }
  return {
    stdout: '',
    stderr: `ubuntu: fetch job=${options.jobId} artifact=${options.name} failed: ${answer.message}\n`,
    exitCode: 1,
  }
}

/** Options for {@link createUbuntuCommand}. */
export interface UbuntuCommandOptions {
  /**
   * The session id the approval gate scopes a grant to.
   *
   * Defaults to the trusted ambient `currentToolCall()?.sessionId`. It is a
   * function so a long-lived command re-reads the session that is running the
   * call, and it is never read from the shell environment: a script must not be
   * able to pick which session's approval it spends. The id reaches the host as
   * the dispatch's out-of-band `sessionId` field
   * (`bridge.ts`'s `TOOL_CALL_SESSION_ENV`), not as a `--session` argv flag.
   */
  readonly sessionId?: (() => string | undefined) | undefined
}

/**
 * Build the `ubuntu` command.
 *
 * Registered only when the host answered the boot probe and the table has a
 * host dispatcher; otherwise the name stays unregistered and the shell answers
 * `ubuntu: command not found` with status 127, which is the whole point
 * (design §4.3).
 * @param host - the host dispatcher every phone tool rides.
 * @param capability - the probe answer this boot published.
 * @param options - the trusted session source for the approval gate.
 * @returns the command definition.
 */
export function createUbuntuCommand(
  host: AcceleratorHost,
  capability: UbuntuCapability,
  options: UbuntuCommandOptions = {},
): CustomCommand {
  const sessionIdOf = options.sessionId ?? (() => currentToolCall()?.sessionId)
  const description = ubuntuDescription(capability.backend)
  return defineCommand('ubuntu', async (args, ctx) => {
    // The session id is identity, so it is read here — inside the invocation,
    // from the trusted tool-call context — and handed to the host as an
    // out-of-band dispatch field, never as an argv word and never from the
    // calling shell's environment. A call with no session cannot be attributed
    // to one, so the command refuses instead of asking the host to guess: the
    // host would have no session to bind a grant (or a denial) to.
    const session = sessionIdOf()
    const trustedSession = session !== undefined && D6.test(session) ? session : undefined
    /** The refusal every op returns when the tool-call session is missing. */
    const noSession = (): { stdout: string; stderr: string; exitCode: number } => ({
      stdout: '',
      stderr: 'ubuntu: this command needs the session of the tool call it runs in, so the host can bind '
        + 'one approval to it; this invocation has none, so nothing was started\n',
      exitCode: 1,
    })

    // One host-tool round trip. Every op answers one JSON object on stdout;
    // stderr and the exit code belong to the host tool, never to the job.
    const dispatch = async (argv: readonly string[]): Promise<HostAnswer> => {
      const env: Record<string, string> = ctx.exportedEnv === undefined
        ? Object.fromEntries(ctx.env)
        : { ...ctx.exportedEnv }
      const stdin = ctx.stdin === undefined ? '' : ctx.stdin as unknown as string
      const result = await host.exec({
        argv: ['phone', 'ubuntu', ...argv],
        cwd: ctx.cwd,
        env,
        stdin,
        signal: ctx.signal,
        sessionId: trustedSession,
      })
      return {
        text: decodeUtf8(byteStringToBytes(result.stdout)),
        stderr: result.stderr,
        exitCode: result.exitCode,
      }
    }

    /** Render one job answer, or the host refusal that produced none. */
    const render = (answer: HostAnswer, command: 'run' | 'status'): {
      stdout: string
      stderr: string
      exitCode: number
    } => {
      const decoded = decodeReply(answer.text)
      if (answer.exitCode === 127 || decoded === undefined) {
        const detail = answer.stderr.trim() !== '' ? answer.stderr.trim() : answer.text.trim()
        return {
          stdout: '',
          stderr: `ubuntu: this host cannot answer that job (${detail === '' ? 'no usable answer' : detail}); `
            + `it does not provide the local environment this command needs; see ${SHELL_MANIFEST_PATH}\n`,
          exitCode: 127,
        }
      }
      return {
        stdout: renderUbuntuReply(decoded, command),
        stderr: answer.stderr,
        exitCode: answer.exitCode === 0 ? exitOfReply(decoded) : answer.exitCode,
      }
    }

    const verb = args[0]
    if (verb === undefined) {
      return { stdout: `${description}\n`, stderr: `${UBUNTU_USAGE}\n`, exitCode: 2 }
    }
    if (verb === '--help' || verb === '-h' || verb === 'help') {
      return { stdout: `${description}\n${UBUNTU_USAGE}\n`, stderr: '', exitCode: 0 }
    }

    if (verb === 'run') {
      const parsed = parseRun(args.slice(1))
      if (typeof parsed === 'string') {
        return { stdout: '', stderr: `ubuntu: ${parsed}\n${UBUNTU_USAGE}\n`, exitCode: 2 }
      }
      if (trustedSession === undefined) return noSession()
      return render(await dispatch([
        'run',
        '--env', parsed.env,
        ...parsed.cwd === undefined ? [] : ['--cwd', parsed.cwd],
        ...parsed.label === undefined ? [] : ['--label', parsed.label],
        ...parsed.timeoutMs === undefined ? [] : ['--timeout-ms', parsed.timeoutMs],
        '--',
        ...parsed.command,
      ]), 'run')
    }

    if (verb === 'status') {
      const jobId = args[1]
      if (jobId === undefined || jobId === '' || args.length !== 2) {
        return { stdout: '', stderr: `ubuntu: status needs exactly one job id\n${UBUNTU_USAGE}\n`, exitCode: 2 }
      }
      if (trustedSession === undefined) return noSession()
      return render(await dispatch(['status', jobId]), 'status')
    }

    if (verb === 'fetch') {
      const parsed = parseUbuntuFetch(args.slice(1))
      if (typeof parsed === 'string') {
        return { stdout: '', stderr: `ubuntu: ${parsed}\n${UBUNTU_USAGE}\n`, exitCode: 2 }
      }
      if (trustedSession === undefined) return noSession()
      const outcome = await fetchArtifact(parsed, ctx, dispatch)
      return { stdout: outcome.stdout, stderr: outcome.stderr, exitCode: outcome.exitCode }
    }

    if (verb === 'close') {
      if (args.length !== 1) {
        return { stdout: '', stderr: `ubuntu: close takes no arguments\n${UBUNTU_USAGE}\n`, exitCode: 2 }
      }
      if (trustedSession === undefined) return noSession()
      const answer = await dispatch(['close'])
      if (answer.exitCode !== 0) {
        const detail = answer.stderr.trim() !== '' ? answer.stderr.trim() : answer.text.trim()
        return {
          stdout: '',
          stderr: `ubuntu: close failed (${detail === '' ? 'no answer' : detail})\n`,
          exitCode: answer.exitCode === 127 ? 127 : 1,
        }
      }
      return {
        stdout: capability.backend === 'mock'
          ? 'ubuntu: closed. Files inside the environment are not kept; the next run starts fresh.\n'
          : 'ubuntu: closed. Every running job was stopped; the cached Ubuntu rootfs stays on disk for '
            + 'the next run.\n',
        stderr: answer.stderr,
        exitCode: 0,
      }
    }

    return {
      stdout: '',
      stderr: `ubuntu: unknown command ${JSON.stringify(verb)}\n${UBUNTU_USAGE}\n`,
      exitCode: 2,
    }
  })
}
