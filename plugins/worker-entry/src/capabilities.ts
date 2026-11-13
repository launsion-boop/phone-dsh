// SPDX-License-Identifier: MIT
/**
 * The Worker's environment priors, published before the first model request.
 *
 * The real-model batch exposed a P1 defect: the model had no prior knowledge
 * of the Worker's runtime, so most BUDGET-failing requests were spent probing
 * the environment instead of doing the task (G2-A05 burned 26 requests, G2-A06
 * 9). The upstream `agent-instructions` plugin already injects
 * `$DSH_HOME/AGENTS.md` (the phone `$DSH_HOME` is `/dsh/home`) as user-global
 * instructions, with a default 1 MiB source budget and a profile `maxBytes` of
 * 64 KiB. That is the zero-patch injection seam this module uses: the Worker
 * entry generates a bounded instruction file before the first request, and the
 * unmodified loader picks it up.
 *
 * Two files are published:
 *
 * - {@link AGENTS_MD_PATH}: the human/model summary, hard-capped at
 *   {@link AGENTS_MD_MAX_BYTES} (8 KiB), with stable ordering;
 * - {@link CAPABILITIES_JSON_PATH}: the complete machine-readable answer
 *   (`commands`, `python_modules`, `limits`, `network.egress_allow`, ...).
 *   The shell-ext 127 trailer already points here (ENG-02).
 *
 * {@link buildCapabilityManifest} is pure and unit-testable.
 * {@link publishCapabilityManifest} writes only when the content hash changed,
 * so a boot with the same environment emits no `VFS_MUT` (the files live in
 * the persisted `/dsh/home` and survive the Worker restart). The command list
 * is enumerated at runtime from the actual shell table
 * ({@link workerCommandSurface}: just-bash built-ins plus
 * `createWorkerCommands()` plus the installed WASI toolbox plus the host HELLO
 * accelerators), never hand-maintained; the module list comes from the
 * build-time probe `scripts/pack-image.mjs` stages beside the CPython
 * artifacts.
 * @module @phone-dsh/dsh-worker-entry/capabilities
 */
import { createHash } from 'node:crypto'
import { getCommandNames } from 'just-bash/browser'
import {
  createWorkerCommands,
  getUbuntuCapability,
  ubuntuDescription,
  WORKER_EXECUTION_LIMITS,
} from '../../shell-ext/src/index.ts'
import type { UbuntuCapability } from '../../shell-ext/src/index.ts'
import type { WorkerToolbox } from '../../wasi-toolbox/src/index.ts'
import { GIT_PHONE_NOTE, gitCapability } from '../../wasi-toolbox/git/capability.ts'
import type { GitCapability, GitTrimFact } from '../../wasi-toolbox/git/capability.ts'

/** Persisted instruction file the upstream loader injects (`$DSH_HOME/AGENTS.md`). */
export const AGENTS_MD_PATH = '/dsh/home/AGENTS.md'
/** Machine-readable manifest every capability diagnostic points at. */
export const CAPABILITIES_JSON_PATH = '/dsh/home/capabilities.json'
/**
 * Hard cap for {@link AGENTS_MD_PATH}; the loader's own budget is larger.
 *
 * Raised from 4 KiB to 5 KiB when the refusal rule below was added: the real
 * production surface (91 commands, 182 Python modules, an unreported egress
 * list) already exceeded 4 KiB, so `clampMarkdown` was dropping the tail
 * sections (`Bash deviations`, `Restart and recovery`, `Manifest`) on the
 * device. A cap the real document cannot fit hides facts instead of bounding
 * them.
 *
 * Raised again, 5 KiB → 6 KiB, by P24 after measuring the real file on the
 * device. The measurement also corrected what the earlier numbers meant: the
 * **full** production document is **5538 B**, and the 5055 B seen under the
 * 5 KiB cap was the *compact* shape — the fallback below had already engaged, so
 * 4 KiB truncated sections and 5 KiB quietly reduced the command list instead of
 * showing the whole document. At 6144 B the full shape fits with ~600 B of
 * headroom (about two more modules); no fact has to be deleted to fit, and the
 * explicit truncation note stays for the day that headroom runs out. The
 * loader's own `maxBytes` is 64 KiB, so this is still a self-imposed budget,
 * not the injection contract.
 *
 * A bigger cap only postpones the next overflow, so the other half of the P24
 * fix is visibility: {@link clampMarkdown} now names the sections it removed and
 * counts them. Every future overflow is readable in the injected document
 * instead of being inferred from a missing section.
 */
export const AGENTS_MD_MAX_BYTES = 8192
/** Schema tag of the machine-readable document. */
export const CAPABILITY_SCHEMA = 'pdsh-capabilities/1'
/** Version of the engine that must stay truthful about its own deviations. */
export const BASH_ENGINE = 'just-bash 3.6 (not GNU bash)'

/**
 * Generic execution advice every ordinary phone task receives before its first
 * request. It is task- and scenario-independent: the user's instruction stays
 * first, a small self-contained edit is done directly, delegation is only for
 * genuinely parallel or explicitly requested work, agent/job inventory is not
 * polled without purpose, deterministic checks are batched and stop after real
 * verification, Python does arithmetic when available, and unrequested large
 * artifacts are not generated. It changes no tool, sub-agent cap, safety or
 * recovery behaviour.
 */
export const TASK_EXECUTION_GUIDANCE =
  'User first; small self-contained edits direct. Delegate only parallel/explicit. '
  + 'Batch coherent edits/checks, verify, stop; no idle agent/job polls. '
  + 'Python math if available; no large unasked outputs.'

export const RESPONSE_GUIDANCE = 'Routine action results: one sentence with result/path/size. No headings, bullets, status labels, logs, recap or unasked caveats. Detail only when asked.'

const MIB = 1024 * 1024
const KIB = 1024

/**
 * The exact fact a manifest carries when the image has no build-probe
 * compression block. It lives in `python.notes` in JSON and is rendered once
 * in AGENTS.md, so both files say "not reported" instead of the old "linked".
 */
const PYTHON_COMPRESSION_NOT_REPORTED_NOTE = 'compression capability (zlib/bz2/lzma) was not reported by the build probe; probe it before relying on it'

/**
 * One recorded engine deviation, with the upstream gap id the shell corpus
 * (ENG-02) audits. A deviation listed here is a fact the model must know
 * before writing a script; the alternative is the supported spelling.
 */
export interface CapabilityBashDeviation {
  /** Upstream gap id from `tools/shell-corpus/golden/worker-shell.jsonl`. */
  readonly id: string
  /** What the engine does (or does not do). */
  readonly note: string
  /** What to do instead. */
  readonly alternative: string
  /**
   * Publish this limitation in `capabilities.json` only. The 4 KiB
   * instruction budget is reserved for the deviations an agent must know
   * before its first command; device read caps are lookup facts.
   */
  readonly jsonOnly?: boolean
}

/**
 * The expected engine deviations the corpus records. These are the
 * `expectedDeviation` entries of the ENG-02 golden corpus; a new one must be
 * added here in the same change so the model is never surprised.
 */
export const DEFAULT_BASH_DEVIATIONS: readonly CapabilityBashDeviation[] = Object.freeze([
  Object.freeze({
    id: 'JB-EPOCHSECONDS',
    note: '`EPOCHSECONDS` and `EPOCHREALTIME` are unset (they expand to an empty string)',
    alternative: 'use `date +%s` for seconds or `$SECONDS` for elapsed time',
  }),
  Object.freeze({
    id: 'JB-DEV0',
    note: '`/dev/zero` and `/dev/urandom` stop after 1 MiB per open, so '
      + '`head -c 16M /dev/zero > f` writes 1,048,576 bytes (not 16 MiB)',
    alternative: 'write large files with `python3` or 1 MiB appends',
    jsonOnly: true,
  }),
])

/** The budget rows (8 GiB tier, PLAN §2.5 / spec budgets.md §4). */
export interface CapabilityLimits {
  readonly singleFileBytes: number
  readonly shellOutputBytes: number
  readonly shellTimeoutMs: number
  readonly requestBodyBytes: number
  readonly vfsLogicalBytes: number
  readonly vfsWorkspaceBytes: number
  readonly vfsSessionsBytes: number
  readonly vfsTmpBytes: number
  readonly wasiHotInstanceBytes: number
  readonly engineHeapBytes: number
  readonly walBytes: number
  readonly journalBytes: number
  readonly responseLogBytes: number
  readonly maxSubAgents: number
}

/** Default phone rows; the boot overrides `singleFileBytes` from the host. */
export const PHONE_V1_LIMITS: CapabilityLimits = Object.freeze({
  singleFileBytes: 128 * MIB,
  shellOutputBytes: 256 * KIB,
  shellTimeoutMs: 120_000,
  requestBodyBytes: 4 * MIB,
  vfsLogicalBytes: 388 * MIB,
  vfsWorkspaceBytes: 288 * MIB,
  vfsSessionsBytes: 50 * MIB,
  vfsTmpBytes: 50 * MIB,
  wasiHotInstanceBytes: 260 * MIB,
  engineHeapBytes: 320 * MIB,
  walBytes: 512 * MIB,
  journalBytes: 64 * MIB,
  responseLogBytes: 128 * MIB,
  maxSubAgents: 2,
})

/** Python facts the Markdown summarizes; the module list is separate. */
export interface CapabilityPythonInput {
  readonly available: boolean
  readonly program?: string
  readonly version?: string
  readonly compression?: {
    readonly zlib: boolean
    readonly bz2: boolean
    readonly lzma: boolean
    readonly tarfileGzip: boolean
  }
  readonly missing?: readonly string[]
  readonly notes?: readonly string[]
}

/**
 * The host accelerator whose tool surface the manifest reports.
 *
 * The Worker forwards `phone <tool> <json-object>` as one exec request
 * (exec.md §3), so the *tool catalog* belongs to the host app, never to this
 * file. {@link phoneCapability} publishes only rows a host in this repository
 * was verified to answer.
 */
export const PHONE_COMMAND_NAME = 'phone'

/**
 * One `phone` tool row.
 *
 * `usage` is the exact command line the model should run; `note` carries the
 * fact that keeps the row honest (for example, that it is the only implemented
 * tool), never an advertisement for behaviour the host does not have.
 */
export interface CapabilityPhoneTool {
  readonly name: string
  readonly usage: string
  readonly note?: string
}

/** jq engine facts the boot probe established. */
export interface CapabilityJqInput {
  readonly available: boolean
  /** Program name on the toolbox table (`jq-wasi`). */
  readonly program?: string
  /** Build-report engine identity. */
  readonly engine?: string
  /** Input-family filters the real engine implements. */
  readonly inputFamily?: readonly string[]
  readonly notes?: readonly string[]
}

/**
 * One command the boot cannot run, with the fact that explains why.
 *
 * The command stays in the shell table (it still fails loudly with its own
 * diagnostic), but it must not appear in `commands`: a declaration the boot
 * cannot honour is the defect this row prevents. Only a boot-time fact the
 * Worker itself can observe belongs here — a mode limitation of a command that
 * otherwise runs (a sandboxed `ln -s`, an accelerator without stdin) is not an
 * unavailable command.
 */
export interface CapabilityUnavailable {
  /** Program name as the shell table spells it. */
  readonly command: string
  /** One bounded sentence: why this boot cannot run it. */
  readonly reason: string
}

/** The Worker environment keys that can reach the host `/v1/http` route. */
export interface HostRouteEnvironment {
  readonly PDSH_CHANNEL_ORIGIN?: string | undefined
  readonly PDSH_EXEC_BRIDGE_URL?: string | undefined
  readonly PDSH_CHANNEL_TOKEN?: string | undefined
  readonly PDSH_EXEC_BRIDGE_TOKEN?: string | undefined
}

/** Reason `curl` carries when this boot has no host `/v1/http` route. */
export const CURL_NO_HOST_ROUTE_REASON =
  'no host /v1/http route in this boot: PDSH_CHANNEL_TOKEN is unset, so curl and github cannot reach any host'

/**
 * Commands this boot cannot run, derived only from facts the Worker observes.
 *
 * `curl` needs both halves of the host route (`shell-ext`'s
 * `resolveHostProxy` reads the same four keys): the origin alone builds no
 * request, so a boot with an origin and no token must not declare it. The
 * Worker entry passes `process.env`; the helper stays pure so a unit test can
 * cover the matrix without a Worker.
 * @param env - the Worker environment (production: `process.env`).
 * @returns the unavailable rows, sorted by command name.
 */
export function workerUnavailableCommands(env: HostRouteEnvironment = {}): CapabilityUnavailable[] {
  const origin = env.PDSH_CHANNEL_ORIGIN ?? env.PDSH_EXEC_BRIDGE_URL
  const token = env.PDSH_CHANNEL_TOKEN ?? env.PDSH_EXEC_BRIDGE_TOKEN
  const hasHostRoute = origin !== undefined && origin !== '' && token !== undefined && token !== ''
  if (hasHostRoute) return []
  return [
    { command: 'curl', reason: CURL_NO_HOST_ROUTE_REASON },
    { command: 'github', reason: CURL_NO_HOST_ROUTE_REASON },
  ]
}

/** One capability manifest build input; every field is a fact, not a guess. */
export interface CapabilityManifestInput {
  /** Every program the shell table serves (see {@link workerCommandSurface}). */
  readonly commands: readonly string[]
  /** Host HELLO `accelerator:<name>` names, when a host HELLO arrived. */
  readonly accelerators?: readonly string[]
  /** Full host HELLO caps, for diagnostics (D12). */
  readonly hostCaps?: readonly string[]
  /** Build-time probe output staged by `scripts/pack-image.mjs`. */
  readonly pythonModules?: readonly string[]
  readonly python?: CapabilityPythonInput
  /** Present only when the image staged and registered the jq WASI engine. */
  readonly jq?: CapabilityJqInput
  readonly limits?: Partial<CapabilityLimits>
  /** Egress host allow-list from the init message (order preserved). */
  readonly egressAllow?: readonly string[]
  readonly bashDeviations?: readonly CapabilityBashDeviation[]
  /** Commands registered by the table but not runnable in this boot. */
  readonly unavailable?: readonly CapabilityUnavailable[]
  /** The boot probe's answer; omitted means "read the published global". */
  readonly ubuntu?: UbuntuCapability | undefined
}

/** Structured budget rows exactly as the JSON manifest carries them. */
export interface CapabilityLimitsDocument {
  readonly single_file_bytes: number
  readonly shell_output_bytes: number
  readonly shell_timeout_ms: number
  readonly request_body_bytes: number
  readonly vfs_logical_bytes: number
  readonly vfs_workspace_bytes: number
  readonly vfs_sessions_bytes: number
  readonly vfs_tmp_bytes: number
  readonly wasi_hot_instance_bytes: number
  readonly engine_heap_bytes: number
  readonly wal_bytes: number
  readonly journal_bytes: number
  readonly response_log_bytes: number
  readonly max_sub_agents: number
  /**
   * Shared just-bash execution ceilings (one owner:
   * `shell-ext/src/execution-limits.ts`). They bound shell command count and
   * loop/awk/sed iterations for every program, including `seq`, `awk`,
   * `for`/`while` and `sed`.
   */
  readonly execution: {
    readonly max_command_count: number
    readonly max_loop_iterations: number
    readonly max_awk_iterations: number
    readonly max_sed_iterations: number
  }
}

/** The machine-readable document written to {@link CAPABILITIES_JSON_PATH}. */
export interface CapabilityManifestDocument {
  readonly schema: string
  /** Commands this boot can run. Never contains an `unavailable` command. */
  readonly commands: readonly string[]
  /** Commands the table still serves but this boot cannot run, with reasons. */
  readonly unavailable: readonly CapabilityUnavailable[]
  readonly accelerators: readonly string[]
  readonly host_caps: readonly string[]
  /**
   * The `phone` accelerator, present only when the command table serves it
   * (a host that advertised `accelerator:phone`).
   *
   * The catalog is host-owned: the Worker cannot enumerate it, so this block
   * publishes only rows the host was verified to answer ({@link
   * phoneCapability}). A tool it does not implement fails as `not-available`
   * and executes nothing. A list the Worker cannot verify — the nineteen-row
   * Apple Office surface that used to be hard-coded here — is a capability
   * claim the Worker cannot keep, so it must not be published.
   */
  readonly phone?: {
    readonly command: string
    readonly invocation: string
    readonly tools: readonly CapabilityPhoneTool[]
    readonly tool_catalog: 'host-owned'
    readonly notes: readonly string[]
  }
  /**
   * The host's local Linux environment, present only when the boot probe
   * answered and the table therefore serves `ubuntu` (design §4.3). The host
   * owns the environment; this block publishes what it said, including the
   * backend, because a mock must not be read as a real toolchain.
   */
  readonly ubuntu?: {
    readonly command: string
    readonly backend: string
    readonly env: string
    readonly invocation: string
    readonly commands: readonly string[]
    readonly description: string
    readonly cost: readonly string[]
    readonly notes: readonly string[]
  }
  readonly python: {
    readonly available: boolean
    readonly program: string
    readonly version: string | null
    readonly compression: {
      readonly zlib: boolean
      readonly bz2: boolean
      readonly lzma: boolean
      readonly tarfileGzip: boolean
    } | null
    readonly missing: readonly string[]
    readonly notes: readonly string[]
  }
  readonly python_modules: readonly string[]
  /**
   * git's real subcommand surface and trim facts. Present only when the
   * command table actually serves `git`; the list is derived from
   * `commandTable()`, never hand-maintained.
   */
  readonly git?: {
    readonly commands: readonly string[]
    readonly supported_forms: readonly string[]
    readonly trimmed: readonly GitTrimFact[]
  }
  /**
   * The real jq engine. Absent when the image has no engine: the shell's
   * `jq` command then stays on the fail-loud shim and the manifest must not
   * claim the input family works.
   */
  readonly jq?: {
    readonly available: true
    readonly program: string
    readonly engine: string
    readonly input_family: readonly string[]
    readonly args: true
    readonly location: true
    readonly notes: readonly string[]
  }
  readonly limits: CapabilityLimitsDocument
  readonly network: {
    readonly egress_allow: readonly string[]
    /** False when the host did not put a list in the init message this boot. */
    readonly egress_reported: boolean
    readonly sockets: false
    readonly proxy: string
    readonly model: string
  }
  readonly bash: {
    readonly engine: string
    readonly gnu: false
    readonly deviations: readonly CapabilityBashDeviation[]
  }
  readonly paths: {
    readonly workspace: string
    readonly home: string
    /** Whether the file tools can read outside the current session. */
    readonly read_scope: 'global' | 'session'
    /** One sentence a model can quote when asked about the read boundary. */
    readonly read_scope_note: string
    readonly image_readonly: readonly string[]
    readonly tmp: readonly string[]
    readonly persisted: readonly string[]
    readonly volatile: readonly string[]
  }
  readonly recovery: {
    readonly persisted_roots: readonly string[]
    readonly volatile_roots: readonly string[]
    readonly write_ack: string
    readonly background_processes: string
  }
  readonly remediation: {
    readonly manifest_path: string
    readonly trailer_prefix: string
    readonly unknown_program_exit: number
  }
}

/** The pure build result; `jsonText` is what {@link publishCapabilityManifest} writes. */
export interface CapabilityManifest {
  readonly markdown: string
  readonly json: CapabilityManifestDocument
  readonly jsonText: string
  readonly markdownSha256: string
  readonly jsonSha256: string
}

/** One command surface assembled from the real table. */
export interface WorkerCommandSurface {
  readonly commands: readonly string[]
  readonly accelerators: readonly string[]
}

/** Options for {@link workerCommandSurface}; production supplies the hello and toolbox. */
export interface WorkerCommandSurfaceInput {
  readonly accelerators?: readonly string[]
  readonly toolbox?: WorkerToolbox | false | undefined
  /** Test seam: omit `git` from the table like `createWorkerCommands({ git: false })`. */
  readonly git?: boolean
  /** Test seam: omit `curl` from the table like `createWorkerCommands({ curl: false })`. */
  readonly curl?: boolean
  /** Test seam: omit the gzip family like `createWorkerCommands({ gzip: false })`. */
  readonly gzip?: boolean
}

const UTF8 = new TextEncoder()

function byteLength(text: string): number {
  return UTF8.encode(text).byteLength
}

function sha256(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

/** Sort strings by code point (stable across engines and locales). */
function sorted(values: readonly string[]): string[] {
  return [...new Set(values)].sort()
}

/**
 * Build the exact command list the shell serves.
 *
 * The list is enumerated at runtime instead of being maintained by hand:
 * just-bash's registry (built-ins), the production `createWorkerCommands()`
 * table (Worker programs, `curl`, the toolbox programs and host accelerators)
 * and the installed toolbox's aliases. Enumerating `createWorkerCommands()`
 * here means a new program is in the manifest the moment it is in the shell.
 * @param input - accelerators and the installed toolbox (production values).
 * @returns sorted command names and the sorted accelerator names.
 */
export function workerCommandSurface(input: WorkerCommandSurfaceInput = {}): WorkerCommandSurface {
  const accelerators = sorted(input.accelerators ?? [])
  const commands = createWorkerCommands({
    ...accelerators.length === 0
      ? {}
      : {
          accelerators: {
            names: accelerators,
            exec: async () => { throw new Error('capability manifest: an accelerator is never executed while enumerating') },
          },
        },
    ...input.toolbox === undefined ? {} : { toolbox: input.toolbox },
    ...input.git === false ? { git: false } : {},
    ...input.curl === false ? { curl: false } : {},
    ...input.gzip === false ? { gzip: false } : {},
  })
  return {
    commands: sorted([...getCommandNames(), ...commands.map(command => command.name)]),
    accelerators,
  }
}

function limitsDocument(limits: CapabilityLimits): CapabilityLimitsDocument {
  return {
    execution: {
      max_command_count: WORKER_EXECUTION_LIMITS.maxCommandCount,
      max_loop_iterations: WORKER_EXECUTION_LIMITS.maxLoopIterations,
      max_awk_iterations: WORKER_EXECUTION_LIMITS.maxAwkIterations,
      max_sed_iterations: WORKER_EXECUTION_LIMITS.maxSedIterations,
    },
    single_file_bytes: limits.singleFileBytes,
    shell_output_bytes: limits.shellOutputBytes,
    shell_timeout_ms: limits.shellTimeoutMs,
    request_body_bytes: limits.requestBodyBytes,
    vfs_logical_bytes: limits.vfsLogicalBytes,
    vfs_workspace_bytes: limits.vfsWorkspaceBytes,
    vfs_sessions_bytes: limits.vfsSessionsBytes,
    vfs_tmp_bytes: limits.vfsTmpBytes,
    wasi_hot_instance_bytes: limits.wasiHotInstanceBytes,
    engine_heap_bytes: limits.engineHeapBytes,
    wal_bytes: limits.walBytes,
    journal_bytes: limits.journalBytes,
    response_log_bytes: limits.responseLogBytes,
    max_sub_agents: limits.maxSubAgents,
  }
}

function formatBytes(bytes: number): string {
  if (bytes % MIB === 0) return `${String(bytes / MIB)} MiB`
  if (bytes % KIB === 0) return `${String(bytes / KIB)} KiB`
  return `${String(bytes)} B`
}

/** Comma list with a bounded size and an explicit pointer to the full JSON. */
function boundedList(values: readonly string[], limit: number, what: string): string {
  if (values.length === 0) return `none configured (${what} fails closed)`
  const shown = values.slice(0, limit)
  const more = values.length - shown.length
  return more > 0
    ? `${shown.join(', ')} (+${String(more)} more in ${CAPABILITIES_JSON_PATH})`
    : shown.join(', ')
}

/** Pick representative module names that exist in the probe output. */
function pythonExamples(modules: readonly string[]): string[] {
  const preferred = ['json', 're', 'pathlib', 'tarfile', 'zipfile', 'zlib', 'bz2', 'lzma']
  const present = new Set(modules)
  return preferred.filter(name => present.has(name))
}

/** The Agent-facing section for the local Linux environment. */
function ubuntuSection(ubuntu: NonNullable<CapabilityManifestDocument['ubuntu']>): string[] {
  return [
    '## Local Ubuntu environment',
    ubuntu.description,
    '',
    `Backend: \`${ubuntu.backend}\` on \`${ubuntu.env}\`; ops: ${ubuntu.commands.map(name => `\`${name}\``).join(', ')}.`,
    ...ubuntu.notes.map(note => `- ${note}`),
    '',
  ]
}

function pythonSection(python: CapabilityManifestDocument['python'], modules: readonly string[]): string[] {
  const lines: string[] = ['## Python']
  if (!python.available) {
    lines.push(
      '`python3` is NOT in this image (no WASI artifacts staged): `python`, `python3` and `pip` answer 127 with the '
      + 'manifest hint. Do not probe them.',
    )
    return lines
  }
  lines.push(
    `\`python3\`/\`python\` is CPython ${python.version ?? '3.x'} on WASI in the Worker: stdlib only, no host process.`,
  )
  if (modules.length === 0) {
    lines.push(
      'Module list not staged in this image; if a task needs an uncertain module, check it once with '
      + '`python3 -c "import <name>"` instead of enumerating the stdlib.',
    )
  } else {
    const examples = pythonExamples(modules)
    lines.push(
      `Stdlib present: ${String(modules.length)} top-level modules`
      + (examples.length === 0 ? '' : ` (e.g. ${examples.join(', ')})`)
      + '; not all import (see Missing). Full sorted list: capabilities.json python_modules.',
    )
  }
  if (python.compression === null) {
    lines.push(`Compression: ${PYTHON_COMPRESSION_NOT_REPORTED_NOTE}.`)
  } else {
    lines.push(
      `Compression: zlib ${python.compression.zlib ? 'yes' : 'no'}, bz2 ${python.compression.bz2 ? 'yes' : 'no'}, `
      + `lzma ${python.compression.lzma ? 'yes' : 'no'}; tarfile w:gz `
      + `${python.compression.tarfileGzip ? 'yes' : 'no'} (from the build probe).`,
    )
  }
  lines.push(`Missing: ${python.missing.join('; ')}.`)
  for (const note of python.notes) {
    if (note !== PYTHON_COMPRESSION_NOT_REPORTED_NOTE) lines.push(note)
  }
  return lines
}

/** The git trim surface, only for a table that really serves `git`. */
function gitSection(git: NonNullable<CapabilityManifestDocument['git']>): string[] {
  return [
    '## Git',
    `- supported: ${git.supported_forms.join('; ')}.`,
    `- trimmed: ${git.trimmed.map(fact => fact.note).join('; ')}.`,
    `- ${GIT_PHONE_NOTE}`,
  ]
}

/** The no-clone GitHub tool, only when this boot's command table serves it. */
function githubSection(): string[] {
  return [
    '## GitHub',
    '- `github` reads and changes a GitHub repo with no local clone: `get`, `tree`, `search`, `branch`, `commit`, `pr`. `github --help` lists the flags.',
    '- Only `get` and `tree` work anonymously. `search` needs a host-stored `api.github.com` credential (`PDSH_GITHUB_AUTH=1`); `branch`, `commit` and `pr` also need the host write opt-in (`PDSH_GITHUB_WRITE=1`). Without them the command fails before sending a request.',
    '- Do not pass a token and do not put one in a script. Requests use the host `/v1/http` allow-list; the host credential gateway injects the stored credential. Keep commits small (at most 20 files, 256 KiB each); binary files go through `--base64`.',
  ]
}

/** Heading of the fixed phone-resource practice section. */
export const MOBILE_RESOURCE_HEADING = '## 手机上的资源做法'
/** Hard byte budget of that section (S1-F: "no more than 600 bytes"). */
export const MOBILE_RESOURCE_MAX_BYTES = 600

/**
 * The fixed "phone resource practice" section of AGENTS.md.
 *
 * It is task-independent advice, not a scenario answer: the model should not
 * clone a whole repository, install dependencies, build on the phone, or read
 * a directory it does not need. The workspace budget comes from the manifest's
 * own `limits` (the tier row), never a hard-coded number, so every device reads
 * the budget its host enforces.
 * @param workspaceBytes - the tier's `vfs_workspace_bytes`.
 * @returns the Markdown lines of the section, heading included.
 */
export function mobileResourceSection(workspaceBytes: number): string[] {
  return [
    MOBILE_RESOURCE_HEADING,
    '- 克隆用 `git clone --depth 1 --single-branch --no-tags`（裸 `git clone` 已是这个默认）；只需个别文件时直接读，不要整库克隆。',
    '- 不在手机上安装依赖、不跑构建。',
    '- 搜索时排除 `.git`、`node_modules`。',
    '- 大文件按片读取。',
    '- 只处理任务需要的那部分目录。',
    `- 工作区预算 ${formatBytes(workspaceBytes)}；接近上限时先删除不需要的产物。`,
  ]
}

function markdownFor(document: CapabilityManifestDocument, compactCommands = false): string {
  const limits = document.limits
  const commandSummary = compactCommands
    ? `Commands: ${String(document.commands.length)}`
      + (document.commands.length === 0 ? '' : ` (e.g. ${document.commands.slice(0, 8).join(', ')})`)
      + `; full sorted list in ${CAPABILITIES_JSON_PATH} commands[].`
    : `Commands (${String(document.commands.length)}): ${boundedList(document.commands, 120, 'the command table')}.`
  const egressLimit = compactCommands ? 6 : 16
  const lines: string[] = [
    '# Phone DSH Worker environment',
    `Machine-readable: ${CAPABILITIES_JSON_PATH} (exact lists). Generated by the Worker boot; do not edit.`,
    '',
    TASK_EXECUTION_GUIDANCE,
    RESPONSE_GUIDANCE,
    '',
    '## Shell',
    `\`bash -c\` is ${BASH_ENGINE}. ${commandSummary}`,
    ...document.unavailable.length === 0 ? [] : [
      `Not runnable in this boot: ${document.unavailable.map(row => `\`${row.command}\``).join(', ')} `
        + `(the reasons are in ${CAPABILITIES_JSON_PATH} unavailable[]; the command still fails loudly if used).`,
    ],
    'POSIX shell syntax and builtins: variables, loops, functions, `cd`, `export`, `test`/`[`, redirections, '
      + 'pipes, `$((...))`.',
    '`trap` real builtin: `EXIT`/`0`; async signals exit 2.',
    'Unknown programs exit 127 with `pdsh-shell: exit=127 ... hint=` naming '
      + `${CAPABILITIES_JSON_PATH}; no host process/compiler/package manager.`,
    '',
    ...document.ubuntu === undefined ? [] : [...ubuntuSection(document.ubuntu), ''],
    ...document.git === undefined ? [] : [...gitSection(document.git), ''],
    ...document.commands.includes('github') ? [...githubSection(), ''] : [],
    ...document.phone === undefined ? [] : [
      '## Host phone tools',
      'The catalog is host-owned; the Worker only forwards `phone <tool> <json-object>`. '
        + `This host serves ${document.phone.tools.map(tool => `\`${tool.usage}\``).join(', ')}. `
        + 'Any other tool name fails as not available and executes nothing.',
      '',
    ],
    ...document.jq === undefined ? [] : [
      `- jq: real \`${document.jq.engine}\` engine as \`${document.jq.program}\`; implements ${document.jq.input_family.map(name => `\`${name}\``).join(', ')}, \`$ARGS\` and \`$__loc__\`.`,
      ...document.jq.notes.map(note => `  - ${note}`),
      '',
    ],
    ...pythonSection(document.python, document.python_modules),
    '',
    '## Limits',
    `- one file <= ${formatBytes(limits.single_file_bytes)}; shell stream <= ${formatBytes(limits.shell_output_bytes)} `
      + '(head+tail, non-zero `reason=output-truncated`); request body <= '
      + `${formatBytes(limits.request_body_bytes)}.`,
    `- VFS <= ${formatBytes(limits.vfs_logical_bytes)} (workspace ${formatBytes(limits.vfs_workspace_bytes)}/`
      + `sessions ${formatBytes(limits.vfs_sessions_bytes)}/tmp ${formatBytes(limits.vfs_tmp_bytes)}); `
      + `WAL ${formatBytes(limits.wal_bytes)}; journal ${formatBytes(limits.journal_bytes)}; `
      + `resp log ${formatBytes(limits.response_log_bytes)}; python hot ${formatBytes(limits.wasi_hot_instance_bytes)}.`,
    `- per command <= ${String(limits.execution.max_command_count)} commands; `
      + `${String(limits.execution.max_loop_iterations)}/${String(limits.execution.max_awk_iterations)}/`
      + `${String(limits.execution.max_sed_iterations)} loop/awk/sed iterations; over limit non-zero `
      + '`reason=iterations` (awk/seq/for/while/sed share the ceiling).',
    `- <= ${String(limits.max_sub_agents)} sub-agents (1 thermal); restart only at a tool-call boundary (heap/WebContent/24 h).`,
    '',
    ...mobileResourceSection(limits.vfs_workspace_bytes),
    '',
    '## Network',
    document.accelerators.includes('ssh')
      ? '- curl: /v1/http; native ssh/scp: ssh --help. Remote writes allowed; no Worker sockets.' + (document.accelerators.includes('adb') ? ' ADB: push/pull; large files bash timeoutMs=3600000. On timeout adb stat /dsh/transfers/NAME before retrying; running != failed; saved size verifies completion.' : '')
      : '- no sockets/DNS/TLS; `curl` only via App `/v1/http` proxy; no wget/nc/ssh/downloads.',
    `- egress allow-list: ${document.network.egress_reported
      ? boundedList(document.network.egress_allow, egressLimit, 'egress')
      : 'not reported by the host this boot; /v1/http still enforces the host allow-list'}.`,
    '- `/v1/http`: GET/POST allowed hosts; redirects yes; no CONNECT/arbitrary ports.',
    '',
    '## Paths and /tmp',
    '- `/dsh/workspace` persisted cwd; `/dsh/home` persisted `$HOME`/`$DSH_HOME`; `/dsh/bin` read-only.',
    '- Reads are global: `read`, `grep` and `glob` can reach every session under `/dsh/workspace` and '
      + '`/dsh/home`, not only this session. Writes are confined separately by the host policy.',
    '- `/tmp` and `/dsh/tmp`: one volatile store, not persisted, empty after restart, cleared first under pressure; '
      + 'writes outside `/dsh/{home,workspace,tmp}` fail.',
    // P21: the harness decorates a refusal with `[sandbox: escalation available
    // ... retry this exact command once with sandbox_permissions ...]` whenever a
    // confining provider is mounted, without consulting the approval policy
    // (`dsh-tool-bash`'s `escalationModes` is `ctx.shell.sandboxMode` alone). The
    // phone has no approval channel and no mode that widens the VFS root table,
    // so following that line can only burn a turn. The harness advice is not
    // ours to remove (pinned DSH), so the model-facing instructions say what the
    // refusal really means and what to do instead.
    '- `[sandbox: escalation available ...]` on a refusal is harness boilerplate, not an option: `/`, `/dsh/bin` '
      + 'and `/dsh/config` are the read-only image in every mode, `sandbox_permissions` cannot widen them, and this '
      + 'deployment has no approval prompt (such a request is rejected automatically). Rewrite the path under a '
      + 'writable root, or report where the file must live.',
    '',
    '## Bash deviations (ENG-02 expected deviations)',
    ...document.bash.deviations
      .filter(deviation => deviation.jsonOnly !== true)
      .map(deviation => `- ${deviation.id}: ${deviation.note}; ${deviation.alternative}.`),
    '- unsupported options exit 2 with the same `pdsh-shell:` trailer; prefer POSIX spellings.',
    '',
    '## Restart and recovery',
    '- restart replays `/dsh/home`, `/dsh/workspace` from host WAL; `/tmp` empty; writes journaled after '
      + 'host accept; unacknowledged resend after reconnect.',
    '- no `&`/nohup/daemons across a tool call: step boundary is a restart boundary.',
    '',
    '## Manifest',
    `${CAPABILITIES_JSON_PATH} (schema ${CAPABILITY_SCHEMA}) has the exact lists.`,
    '',
  ]
  return lines.join('\n')
}

/** Every `## ` heading of the generated document, in order. */
const SECTION_HEADING = /^## (.+)$/gmu

/**
 * The section names whose heading appears in `text`, in document order.
 * @param text - Markdown fragment.
 * @returns the trimmed heading titles.
 */
function sectionNames(text: string): string[] {
  return [...text.matchAll(SECTION_HEADING)].map(match => (match[1] ?? '').trim()).filter(name => name !== '')
}

/**
 * The explicit truncation note. P24 found the old one silent about *what* was
 * cut: it said the summary "was shortened", which cannot tell a model whether
 * the missing part held the rule it is about to break. This note names the
 * dropped sections and counts them.
 * @param dropped - sections whose heading is entirely gone from the result.
 * @param partial - section cut in the middle, if the cut landed inside one.
 * @param maxBytes - the byte budget the note explains.
 * @returns the note, framed by newlines so it sits on its own line.
 */
export function truncationNote(dropped: readonly string[], partial: string | undefined, maxBytes: number): string {
  const counted = dropped.length === 0
    ? undefined
    : `dropped ${String(dropped.length)} section${dropped.length === 1 ? '' : 's'}: ${dropped.join(', ')}`
  const pieces = [
    ...counted === undefined ? [] : [counted],
    ...partial === undefined ? [] : [counted === undefined ? `dropped the tail of "${partial}"` : `part of "${partial}"`],
  ]
  const what = pieces.length === 0 ? 'shortened' : pieces.join('; ')
  return `\n[truncated to ${String(maxBytes)} B: ${what}; the machine-readable lists are in ${CAPABILITIES_JSON_PATH}]\n`
}

/**
 * Where `text` must end so that `head + note` fits `budget` bytes: one line
 * boundary at or before the byte budget.
 * @param text - the full Markdown.
 * @param budget - bytes available to the retained head.
 * @returns the cut index (exclusive, at the preceding newline when there is one).
 */
function headCut(text: string, budget: number): number {
  if (budget <= 0) return 0
  let cut = text.length
  while (cut > 0 && byteLength(text.slice(0, cut)) > budget) cut -= 1
  const lineEnd = text.lastIndexOf('\n', cut)
  return lineEnd > 0 ? lineEnd : cut
}

/**
 * What a cut at `cut` costs: the sections whose heading fell past it, plus the
 * section the cut landed inside (its heading is still in the head).
 * @param text - the full Markdown.
 * @param cut - the retained head length.
 * @returns the fully dropped section names and the partially retained one.
 */
function droppedAt(text: string, cut: number): { dropped: string[]; partial: string | undefined } {
  const tail = text.slice(cut + 1)
  const dropped = sectionNames(tail)
  if (tail.startsWith('## ') || cut === 0) return { dropped, partial: undefined }
  return { dropped, partial: sectionNames(text.slice(0, cut)).at(-1) }
}

/**
 * Cut the Markdown at a line boundary so a pathological input still fits, and
 * say what was dropped.
 *
 * The note is part of the budget, so the cut is chosen against the note it will
 * carry: the loop grows the reservation until the note that the chosen cut
 * produces fits inside it (monotone in practice, bounded at four passes), and a
 * last-resort hard slice keeps the byte cap even if it does not converge.
 * @param text - the generated Markdown.
 * @param maxBytes - the hard byte cap for the returned text.
 * @returns `text` unchanged when it fits, else the retained head plus the note.
 */
export function clampMarkdown(text: string, maxBytes: number): string {
  if (byteLength(text) <= maxBytes) return text
  if (maxBytes <= 0) return ''
  let reserve = 0
  for (let pass = 0; pass < 4; pass += 1) {
    const cut = headCut(text, maxBytes - reserve)
    const { dropped, partial } = droppedAt(text, cut)
    const candidate = `${text.slice(0, cut)}${truncationNote(dropped, partial, maxBytes)}`
    if (byteLength(candidate) <= maxBytes) return candidate
    // The note spends the same budget it explains, so a bigger note moves the
    // cut earlier; a cap too small for the note at all falls through below.
    const noteBytes = byteLength(truncationNote(dropped, partial, maxBytes))
    if (noteBytes <= reserve) break
    reserve = noteBytes
  }
  let cut = headCut(text, Math.max(0, maxBytes - reserve))
  const { dropped, partial } = droppedAt(text, cut)
  const note = truncationNote(dropped, partial, maxBytes)
  // A cap that cannot hold the note keeps the note and gives up the head: the
  // note is the part that makes the truncation visible.
  if (byteLength(note) > maxBytes) return note.slice(0, maxBytes)
  let head = text.slice(0, cut)
  while (head !== '' && byteLength(head) + byteLength(note) > maxBytes) {
    const lineEnd = head.lastIndexOf('\n')
    head = lineEnd > 0 ? head.slice(0, lineEnd) : ''
  }
  return `${head}${note}`
}

/**
 * The honest `phone` section for a host that advertised `accelerator:phone`.
 *
 * The row is not a guess: the only host in this repository that advertises the
 * accelerator without a larger verified surface is the Android host, whose
 * `PhoneInfoTool` accepts exactly `argv = ["phone", "info"]` and refuses every
 * other argv. A host with a bigger catalog must declare it (the HELLO carries
 * only `accelerator:phone`, so that needs a protocol extension); until then
 * publishing one verified row is the whole truth, and a tool the host does not
 * implement is refused as `not-available` rather than advertised.
 * @returns the `phone` document section.
 */
/** The command name the local environment is served under. */
export const UBUNTU_COMMAND_NAME = 'ubuntu'

/**
 * The honest `ubuntu` document for a host that answered the boot probe.
 *
 * `description` is the same text `ubuntu --help` prints (one constant in
 * shell-ext), so the injected instructions and the command cannot describe the
 * environment differently. `cost` and `notes` are the facts the Agent must
 * weigh before starting it, restated structurally for a JSON reader.
 * @param capability - the probe's answer (environment and backend).
 * @returns the document section.
 */
export function ubuntuCapability(
  capability: UbuntuCapability,
): NonNullable<CapabilityManifestDocument['ubuntu']> {
  return {
    command: UBUNTU_COMMAND_NAME,
    backend: capability.backend,
    env: capability.env,
    invocation: `${UBUNTU_COMMAND_NAME} run [--env <id>] [--cwd <path>] [--label <text>] [--timeout-ms <n>] -- <command...>`,
    commands: ['run', 'status', 'close', 'fetch'],
    description: ubuntuDescription(capability.backend),
    cost: [
      'starting the environment takes time, disk space and battery',
      "the first use in a session needs the user's approval; later jobs in the same session do not",
      'files inside it are not kept after `ubuntu close`; the next use starts a fresh environment',
    ],
    notes: [
      'It does not run DSH: the turn, the context, the session and every file stay in DSH.',
      'Ordinary work (`ls`, `cat`, `grep`, `git`, `python3`) runs in the existing `bash` and must not start it.',
      capability.backend === 'mock'
        ? 'This build is wired to a MOCK adapter: its output is synthetic (`backend=mock`), so a mock exit 0 is not a real compile or run.'
        : `The host reported backend \`${capability.backend}\`; the exit code is the environment's own.`,
    ],
  }
}

export function phoneCapability(ubuntu: boolean = false): NonNullable<CapabilityManifestDocument['phone']> {
  return {
    command: PHONE_COMMAND_NAME,
    invocation: `${PHONE_COMMAND_NAME} <tool> <json-object>`,
    tool_catalog: 'host-owned',
    tools: [
      {
        name: 'info',
        usage: `${PHONE_COMMAND_NAME} info`,
        note: 'takes no arguments and returns device model/OS/display JSON',
      },
      ...ubuntu
        ? [{
            name: 'ubuntu',
            usage: `${PHONE_COMMAND_NAME} ubuntu <run|status|close|fetch>`,
            note: 'the local Linux environment (bridge.md §12); normally reached through the `ubuntu` command, '
              + 'and present only because the boot probe answered',
          }]
        : [],
    ],
    notes: [
      'The catalog is owned by the host build, not by the Worker. This list is what THIS host serves.',
      'Any other tool name is refused as not available: the host executes nothing and the shell reports exit 127.',
    ],
  }
}

/**
 * Build the Markdown summary and the machine-readable document.
 *
 * Pure: the same input produces byte-identical files, which is what makes the
 * boot idempotent. Volatile facts (boot id, mseq, clock) are deliberately not
 * inputs.
 * @param input - command surface, Python probe, limits, egress allow-list.
 * @returns both rendered files and their content hashes.
 */
export function buildCapabilityManifest(input: CapabilityManifestInput): CapabilityManifest {
  const unavailable = [...new Map(
    (input.unavailable ?? []).map(row => [row.command, { command: row.command, reason: row.reason }]),
  ).values()].sort((left, right) => left.command < right.command ? -1 : left.command > right.command ? 1 : 0)
  const unavailableNames = new Set(unavailable.map(row => row.command))
  // A command in `unavailable` is a fact about this boot, not a declaration:
  // it leaves `commands` so no consumer reads it as runnable.
  const commands = sorted(input.commands).filter(name => !unavailableNames.has(name))
  const accelerators = sorted(input.accelerators ?? [])
  const hostCaps = sorted(input.hostCaps ?? [])
  const pythonModules = sorted(input.pythonModules ?? [])
  const limits = { ...PHONE_V1_LIMITS, ...input.limits }
  const deviations = input.bashDeviations ?? DEFAULT_BASH_DEVIATIONS
  const pythonInput = input.python
  const compression = pythonInput?.compression === undefined ? null : {
    zlib: pythonInput.compression.zlib,
    bz2: pythonInput.compression.bz2,
    lzma: pythonInput.compression.lzma,
    tarfileGzip: pythonInput.compression.tarfileGzip,
  }
  // The git surface is derived from the real command table, and only shown
  // when the table serves git (a test/profile can omit it).
  const git: GitCapability | undefined = commands.includes('git') ? gitCapability() : undefined
  // Same rule for the phone accelerator: the section exists only when the
  // host's HELLO put the command in this table.
  const ubuntuInput = input.ubuntu ?? getUbuntuCapability()
  const ubuntu = commands.includes(UBUNTU_COMMAND_NAME) && ubuntuInput !== undefined
    ? ubuntuCapability(ubuntuInput)
    : undefined
  const phone = commands.includes(PHONE_COMMAND_NAME) ? phoneCapability(ubuntu !== undefined) : undefined
  const jqInput = input.jq
  const python: CapabilityManifestDocument['python'] = pythonInput === undefined || !pythonInput.available
    ? {
        available: false,
        program: 'python3',
        version: null,
        compression: null,
        missing: ['the WASI toolbox is not installed in this image'],
        notes: [],
      }
    : {
        available: true,
        program: 'python3 (alias python)',
        version: pythonInput.version ?? '3.13',
        // Only the build probe owns this. An input without a probe result is
        // `null` (not reported), never the old "all linked" default.
        compression,
        missing: pythonInput.missing ?? [
          'pip/ensurepip (the image is stdlib-only; no package installs)',
          'ssl/ctypes/sqlite3/curses imports (native extensions absent)',
          'socket creation (module imports; socket() raises OSError ENOTSUP)',
          'native C-extension builds (no compiler/dynamic loading)',
        ],
        notes: [
          ...pythonInput.notes ?? [
            '`subprocess` is a shim: `Popen` runs another `python3` synchronously on VFS (8 levels); `timeout=` unenforced; stdout+stderr per child <=16 MiB or OSError(EFBIG).',
            '`multiprocessing`/`venv` import; no processes or pip.',
          ],
          ...compression === null ? [PYTHON_COMPRESSION_NOT_REPORTED_NOTE] : [],
        ],
      }
  const document: CapabilityManifestDocument = {
    schema: CAPABILITY_SCHEMA,
    commands,
    unavailable,
    accelerators,
    ...ubuntu === undefined ? {} : { ubuntu },
    host_caps: hostCaps,
    ...phone === undefined ? {} : { phone },
    python,
    python_modules: pythonModules,
    ...git === undefined ? {} : {
      git: {
        commands: git.commands,
        supported_forms: git.supported_forms,
        trimmed: git.trimmed,
      },
    },
    ...jqInput === undefined || !jqInput.available ? {} : {
      jq: {
        available: true,
        program: jqInput.program ?? 'jq-wasi',
        engine: jqInput.engine ?? 'jaq-core (WASI)',
        input_family: [...jqInput.inputFamily ?? ['input', 'inputs', 'input_line_number']],
        args: true,
        location: true,
        notes: [...jqInput.notes ?? [
          'the input family is executed by a real filter engine; the shell jq command routes to it when the image stages jq.wasm',
          'not a claim of complete jq 1.6 compatibility: jaq semantics and the documented deviations apply',
        ]],
      },
    },
    limits: limitsDocument(limits),
    network: {
      egress_allow: [...input.egressAllow ?? []],
      egress_reported: input.egressAllow !== undefined,
      sockets: false,
      proxy: '/v1/http',
      model: 'app-gateway',
    },
    bash: {
      engine: BASH_ENGINE,
      gnu: false,
      deviations: [...deviations],
    },
    paths: {
      workspace: '/dsh/workspace',
      home: '/dsh/home',
      // The DSH file tools are process-wide: they have no per-session mount,
      // so every Bot session can read every workspace/home path. Saying so is
      // the honest prior; a session boundary needs a protocol change (P14/P15)
      // and must not be faked by hiding a path here. Writes are confined by the
      // host tool policy, not by this list.
      read_scope: 'global',
      read_scope_note: 'read, grep and glob can reach every session under /dsh/workspace and /dsh/home; '
        + 'writes are confined separately by the host policy',
      image_readonly: ['/dsh/bin'],
      tmp: ['/tmp', '/dsh/tmp'],
      persisted: ['/dsh/home', '/dsh/workspace'],
      volatile: ['/tmp', '/dsh/tmp'],
    },
    recovery: {
      persisted_roots: ['/dsh/home', '/dsh/workspace'],
      volatile_roots: ['/tmp', '/dsh/tmp'],
      write_ack: 'a tool call is journaled only after its writes are accepted by the host WAL',
      background_processes: 'not supported across a tool call (a step boundary is a restart boundary)',
    },
    remediation: {
      manifest_path: CAPABILITIES_JSON_PATH,
      trailer_prefix: 'pdsh-shell: ',
      unknown_program_exit: 127,
    },
  }
  // Normal rendering lists every command. A pathological table (a generated
  // test or a future plugin with hundreds of names) would push the facts the
  // model actually needs out of the 4 KiB budget, so fall back to a count plus
  // the manifest pointer before the line-level clamp is ever needed.
  let markdown = markdownFor(document)
  if (byteLength(markdown) > AGENTS_MD_MAX_BYTES) markdown = markdownFor(document, true)
  markdown = clampMarkdown(markdown, AGENTS_MD_MAX_BYTES)
  const jsonText = `${JSON.stringify(document, null, 2)}\n`
  return {
    markdown,
    json: document,
    jsonText,
    markdownSha256: sha256(markdown),
    jsonSha256: sha256(jsonText),
  }
}

/** The VFS face the manifest publisher needs; a structural subset of the entry's VFS. */
export interface CapabilityVfs {
  readonly promises?: {
    readFile(path: string): Promise<Uint8Array | string>
    writeFile(path: string, data: Uint8Array, options?: { readonly mode?: number }): Promise<void>
    mkdir?(path: string, options?: { readonly recursive?: boolean }): Promise<unknown>
  } | undefined
  readFileSync?(path: string): string | Uint8Array
  writeFileSync?(path: string, data: string | Uint8Array, options?: { readonly mode?: number }): void
  mkdirSync?(path: string, options?: { readonly recursive?: boolean }): unknown
}

/** What one publish pass did. */
export interface CapabilityPublishReport {
  /** False when the VFS has no read/write face (a unit-test double). */
  readonly active: boolean
  /** Files whose content hash differed and were written this boot. */
  readonly written: readonly string[]
  /** Files whose content hash matched and were left untouched. */
  readonly unchanged: readonly string[]
  readonly hashes: Readonly<Record<string, string>>
  readonly reason?: string
}

function decodeText(value: string | Uint8Array): string {
  return typeof value === 'string' ? value : new TextDecoder().decode(value)
}

async function readExisting(vfs: CapabilityVfs, path: string): Promise<string | undefined> {
  try {
    if (typeof vfs.promises?.readFile === 'function') {
      return decodeText(await vfs.promises.readFile(path))
    }
    if (typeof vfs.readFileSync === 'function') {
      return decodeText(vfs.readFileSync(path))
    }
    return undefined
  } catch (error) {
    const code = (error as { readonly code?: unknown } | null)?.code
    if (code === 'ENOENT' || code === 'ENOTDIR') return undefined
    throw new Error(
      `worker entry: cannot read the capability manifest ${path}: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    )
  }
}

async function writeFile(vfs: CapabilityVfs, path: string, text: string): Promise<void> {
  const bytes = UTF8.encode(text)
  if (typeof vfs.promises?.writeFile === 'function') {
    await vfs.promises.writeFile(path, bytes, { mode: 0o644 })
    return
  }
  if (typeof vfs.writeFileSync === 'function') {
    vfs.writeFileSync(path, bytes, { mode: 0o644 })
    return
  }
  throw new Error('worker entry: the VFS has no write face for the capability manifest')
}

/**
 * Publish the manifest into the persisted home, idempotently.
 *
 * The files are compared by content hash, so an unchanged environment writes
 * nothing and emits no `VFS_MUT`. A VFS without a read+write face (the unit
 * test double) is reported inactive instead of failing: it cannot persist a
 * file anyway. Any other read/write failure is loud, because a boot that
 * cannot explain its own environment reintroduces the defect this fix closes.
 * @param vfs - the mounted (namespace-wrapped) Worker VFS.
 * @param manifest - output of {@link buildCapabilityManifest}.
 * @returns what was written or unchanged.
 */
export async function publishCapabilityManifest(
  vfs: CapabilityVfs,
  manifest: CapabilityManifest,
): Promise<CapabilityPublishReport> {
  const hasRead = typeof vfs.promises?.readFile === 'function' || typeof vfs.readFileSync === 'function'
  const hasWrite = typeof vfs.promises?.writeFile === 'function' || typeof vfs.writeFileSync === 'function'
  if (!hasRead || !hasWrite) {
    return {
      active: false,
      written: [],
      unchanged: [],
      hashes: {},
      reason: 'the VFS exposes no synchronous read/write face for /dsh/home',
    }
  }
  // The home root exists on a real boot; creating it also covers a first boot
  // whose overlay carried no home directory. A test double with no mkdir keeps
  // going and lets the write surface the real error.
  try {
    if (typeof vfs.promises?.mkdir === 'function') await vfs.promises.mkdir('/dsh/home', { recursive: true })
    else vfs.mkdirSync?.('/dsh/home', { recursive: true })
  } catch (error) {
    throw new Error(
      `worker entry: cannot create /dsh/home for the capability manifest: ${error instanceof Error ? error.message : String(error)}`,
      { cause: error },
    )
  }
  const files = [
    { path: AGENTS_MD_PATH, text: manifest.markdown, hash: manifest.markdownSha256 },
    { path: CAPABILITIES_JSON_PATH, text: manifest.jsonText, hash: manifest.jsonSha256 },
  ] as const
  const written: string[] = []
  const unchanged: string[] = []
  const hashes: Record<string, string> = {}
  for (const file of files) {
    hashes[file.path] = file.hash
    const existing = await readExisting(vfs, file.path)
    if (existing !== undefined && sha256(existing) === file.hash) {
      unchanged.push(file.path)
      continue
    }
    await writeFile(vfs, file.path, file.text)
    written.push(file.path)
  }
  return { active: true, written, unchanged, hashes }
}
