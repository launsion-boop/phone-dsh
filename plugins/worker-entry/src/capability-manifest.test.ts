// SPDX-License-Identifier: MIT
/**
 * Truth gate for the boot-time capability manifest (G2-ENG-05).
 *
 * The real-model batch burned most of its BUDGET requests asking the
 * environment what it could do: which commands exist, which Python modules
 * import, what the limits are, where `/tmp` is and what leaves the Worker.
 * `capabilities.ts` answers those questions before the first model request:
 * `/dsh/home/capabilities.json` is the exact machine-readable answer and
 * `/dsh/home/AGENTS.md` is the same answer inside the upstream
 * `$DSH_HOME/AGENTS.md` instruction source (no DSH patch).
 *
 * These tests are the truth gate for that claim:
 *  - `manifest.commands` and the production command table have an empty
 *    two-way difference, so a new command cannot be missing from the answer;
 *  - the egress list and the Python module list are exactly the inputs, not a
 *    hand-written approximation;
 *  - the Markdown stays inside the 4 KiB budget;
 *  - the real upstream instruction loader injects the generated file from
 *    `$DSH_HOME/AGENTS.md` (the mechanism the fix relies on);
 *  - a second boot with unchanged content emits no `VFS_MUT`.
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { getCommandNames } from 'just-bash/browser'
import { loadBaselineInstructions } from '@deepseek-ai/dsh-agent-instructions'
import { createMemoryChannelPair } from '../../channel/src/index.ts'
import { createWorkerCommands } from '../../shell-ext/src/index.ts'
import { SHELL_MANIFEST_PATH } from '../../shell-ext/src/contract.ts'
import type { WorkerToolbox } from '../../wasi-toolbox/src/index.ts'
import {
  DEFAULT_HOT_INSTANCE_MEMORY_BYTES,
  DEFAULT_SINGLE_FILE_LIMIT,
} from '../../wasi-toolbox/src/limits.ts'
import {
  startPhoneWorker,
  type PhoneWorkerHostLike,
  type PhoneWorkerRuntime,
  type WorkerEntryMutation,
  type WorkerEntrySynthesize,
  type WorkerEntryVfs,
} from './entry.ts'
import {
  AGENTS_MD_MAX_BYTES,
  AGENTS_MD_PATH,
  CAPABILITIES_JSON_PATH,
  DEFAULT_BASH_DEVIATIONS,
  PHONE_TOOL_CAPABILITIES,
  PHONE_V1_LIMITS,
  TASK_EXECUTION_GUIDANCE,
  buildCapabilityManifest,
  publishCapabilityManifest,
  workerCommandSurface,
  type CapabilityManifestInput,
} from './capabilities.ts'

/** A toolbox with one program and one alias, enough to exercise `list()`. */
function fakeToolbox(): WorkerToolbox {
  return {
    list: () => [{ program: 'python3', aliases: [] }],
    has: (program) => program === 'python3' || program === 'python',
    async run() {
      throw new Error('the manifest test never runs a toolbox program')
    },
  }
}

/**
 * Read the probe app's real default allow-list, in the order the host
 * publishes it (`PhoneDSHHost.egressAllowEnvironmentValue` sorts the Set).
 * Reading the source keeps the test on the production list without adding
 * public host names to the hygiene-scanned plugin tree.
 */
function probeAppDefaultEgress(): string[] {
  const here = dirname(fileURLToPath(import.meta.url))
  const source = readFileSync(
    join(here, '../../..', 'examples/probe-app/PhoneDSHProbe/ChatModel.swift'),
    'utf8',
  )
  const match = /static let defaultEgressAllow = "([^"]+)"/u.exec(source)
  assert.ok(match !== null, 'the probe app publishes its default egress allow-list')
  const list = match[1]
  assert.ok(list !== undefined, 'the probe app default egress list is not empty')
  return list.split(',').map(host => host.trim()).filter(host => host.length > 0).sort()
}

const PRODUCTION_EGRESS = probeAppDefaultEgress()

/** The real stdlib probe names that drive the Python section's size. */
const PRODUCTION_PYTHON_MODULES = (
  'abc argparse array ast asyncio base64 bisect bz2 calendar codecs collections concurrent '
  + 'configparser contextlib copy csv ctypes dataclasses datetime decimal difflib email encodings enum errno '
  + 'fnmatch fractions functools gc getpass gettext glob gzip hashlib heapq hmac html http importlib inspect io '
  + 'ipaddress itertools json logging lzma math mimetypes multiprocessing numbers operator os pathlib pickle platform '
  + 'pprint queue random re secrets selectors shlex shutil signal socket sqlite3 ssl stat statistics string struct '
  + 'subprocess sys tarfile tempfile textwrap threading time traceback types typing unicodedata unittest urllib uuid '
  + 'venv warnings weakref xml zipfile zlib'
).split(' ')

function manifestInput(overrides: Partial<CapabilityManifestInput> = {}): CapabilityManifestInput {
  return {
    commands: ['bash', 'cat', 'tar'],
    ...overrides,
  }
}

/** An in-memory VFS with the promise face and the sink subscription. */
interface MemoryVfs extends WorkerEntryVfs {
  readonly mutations: string[]
  contents(path: string): string | undefined
}

/** The persisted bytes two successive boots share (the host WAL does this). */
interface MemoryStore {
  readonly files: Map<string, Uint8Array>
  readonly directories: Set<string>
}

function createMemoryStore(): MemoryStore {
  return {
    files: new Map<string, Uint8Array>(),
    directories: new Set(['/', '/dsh', '/dsh/home', '/dsh/workspace']),
  }
}

/** A fresh VFS over the shared persisted store, like a Worker rebuild. */
function createMemoryVfs(store: MemoryStore = createMemoryStore()): MemoryVfs {
  const { files, directories } = store
  const listeners = new Set<(mutation: WorkerEntryMutation) => void>()
  const mutations: string[] = []
  const emit = (mutation: WorkerEntryMutation): void => {
    mutations.push(mutation.path)
    for (const listener of [...listeners]) listener(mutation)
  }
  const vfs: MemoryVfs = {
    subscribe(listener) {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
    async flush() {},
    promises: {
      async readFile(path: string) {
        const bytes = files.get(path)
        if (bytes === undefined) {
          const error = new Error(`ENOENT: ${path}`) as Error & { code: string }
          error.code = 'ENOENT'
          throw error
        }
        return bytes
      },
      async writeFile(path: string, data: Uint8Array) {
        files.set(path, new Uint8Array(data))
        emit({ kind: 'write', path, bytes: new Uint8Array(data), mode: 0o644, entryChanged: true })
      },
      async mkdir(path: string) {
        if (!directories.has(path)) {
          directories.add(path)
          emit({ kind: 'mkdir', path, mode: 0o755 })
        }
      },
      async stat() {
        return { mode: 0o644, isFile: () => true }
      },
      async lstat() {
        return { mode: 0o644, isFile: () => true }
      },
      async readdir() {
        return []
      },
      async unlink(path: string) {
        files.delete(path)
        emit({ kind: 'remove', path })
      },
      async rename(from: string, to: string) {
        const bytes = files.get(from)
        if (bytes !== undefined) {
          files.delete(from)
          files.set(to, bytes)
          emit({ kind: 'write', path: to, bytes, mode: 0o644, entryChanged: true })
        }
      },
      async truncate(path: string, length = 0) {
        const bytes = files.get(path)
        if (bytes !== undefined) {
          const next = new Uint8Array(Math.min(bytes.byteLength, length))
          next.set(bytes.subarray(0, next.byteLength))
          files.set(path, next)
        }
      },
    },
    get mutations() { return mutations },
    contents(path) {
      const bytes = files.get(path)
      return bytes === undefined ? undefined : new TextDecoder().decode(bytes)
    },
  }
  return vfs
}

test('manifest.commands has an empty two-way difference with the production command table', () => {
  const toolbox = fakeToolbox()
  const accelerators = ['rg', 'jaq']
  const surface = workerCommandSurface({ accelerators, toolbox })
  const table = createWorkerCommands({
    accelerators: { names: accelerators, exec: async () => { throw new Error('not run') } },
    toolbox,
  })
  const actual = new Set([...getCommandNames(), ...table.map(command => command.name)])
  const manifest = buildCapabilityManifest(manifestInput({ commands: surface.commands }))
  const documented = new Set(manifest.json.commands)
  const missing = [...actual].filter(name => !documented.has(name)).sort()
  const stale = [...documented].filter(name => !actual.has(name)).sort()
  assert.deepEqual(missing, [], 'every registered command appears in the manifest')
  assert.deepEqual(stale, [], 'the manifest names no command the shell cannot run')
})

test('the egress allow-list and the Python module list are exactly their inputs', () => {
  const egress = ['gateway.example.test', 'api.example.test']
  const modules = ['zlib', 'json', 're', 'pathlib']
  const manifest = buildCapabilityManifest(manifestInput({
    egressAllow: egress,
    pythonModules: modules,
    python: { available: true, version: '3.13', compression: { zlib: true, bz2: true, lzma: true, tarfileGzip: true } },
  }))
  // Order is part of the configured allow-list; the builder never reorders it.
  assert.deepEqual(manifest.json.network.egress_allow, egress)
  assert.equal(manifest.json.network.egress_reported, true)
  // An init message without a list says so instead of claiming "fails closed".
  assert.equal(buildCapabilityManifest(manifestInput()).json.network.egress_reported, false)
  // The module list follows the build-time probe (sorted for a stable file).
  assert.deepEqual(manifest.json.python_modules, [...modules].sort())
  assert.deepEqual(manifest.json.commands, ['bash', 'cat', 'tar'])
  assert.equal(manifest.json.limits.single_file_bytes, PHONE_V1_LIMITS.singleFileBytes)
})

test('the manifest publishes the host VFS tier quotas, not the stale priors', () => {
  // A host that injects its BudgetTable row (the 8 GiB row here) must see the
  // same numbers in the manifest and in the write-time quota.
  const manifest = buildCapabilityManifest(manifestInput({
    limits: {
      vfsLogicalBytes: 388 * 1024 * 1024,
      vfsWorkspaceBytes: 288 * 1024 * 1024,
      vfsSessionsBytes: 50 * 1024 * 1024,
      vfsTmpBytes: 50 * 1024 * 1024,
    },
  }))
  assert.equal(manifest.json.limits.vfs_logical_bytes, 388 * 1024 * 1024)
  assert.equal(manifest.json.limits.vfs_workspace_bytes, 288 * 1024 * 1024)
  assert.equal(manifest.json.limits.vfs_sessions_bytes, 50 * 1024 * 1024)
  assert.equal(manifest.json.limits.vfs_tmp_bytes, 50 * 1024 * 1024)
})

test('the published WASI hot-instance ceiling is the enforced one', () => {
  // The device killed python3 at exactly 157286400 bytes (150 MiB) while this
  // manifest already published 272629760 (260 MiB): the two owners of the row
  // drifted and no test compared them. The spec row is budgets.md §4.
  const manifest = buildCapabilityManifest(manifestInput())
  assert.equal(manifest.json.limits.wasi_hot_instance_bytes, DEFAULT_HOT_INSTANCE_MEMORY_BYTES)
  assert.equal(PHONE_V1_LIMITS.wasiHotInstanceBytes, DEFAULT_HOT_INSTANCE_MEMORY_BYTES)
  assert.equal(PHONE_V1_LIMITS.singleFileBytes, DEFAULT_SINGLE_FILE_LIMIT)
})

test('compression comes only from the probe, never from the module list or a linked default', () => {
  // The stdlib ZIP still lists zlib, but the interpreter probe says it is
  // absent. The manifest must print "no" and must not also claim it is linked
  // (the E09 / G2-FIX-27 contradiction).
  const probed = buildCapabilityManifest(manifestInput({
    pythonModules: ['json', 're', 'zlib'],
    python: {
      available: true,
      version: '3.13',
      compression: { zlib: false, bz2: true, lzma: true, tarfileGzip: true },
    },
  }))
  assert.deepEqual(probed.json.python.compression, {
    zlib: false,
    bz2: true,
    lzma: true,
    tarfileGzip: true,
  })
  assert.match(probed.markdown, /zlib no/)
  assert.doesNotMatch(probed.markdown, /zlib\/bz2\/lzma are linked/)
  assert.doesNotMatch(probed.markdown, /zlib yes/)

  // An image without the probe block reports nothing; the old default was
  // "all three linked".
  const unprobed = buildCapabilityManifest(manifestInput({
    pythonModules: ['json', 're', 'zlib'],
    python: { available: true, version: '3.13' },
  }))
  assert.equal(unprobed.json.python.compression, null)
  assert.match(unprobed.markdown, /not reported by the build probe/)
  assert.doesNotMatch(unprobed.markdown, /zlib\/bz2\/lzma are linked/)
  assert.doesNotMatch(unprobed.markdown, /zlib yes/)
})

test('AGENTS.md stays within 4 KiB and answers the environment questions', () => {
  const commands = Array.from({ length: 200 }, (_, index) => `program-${String(index)}`)
  const modules = Array.from({ length: 200 }, (_, index) => `module_${String(index)}`)
  const egress = Array.from({ length: 40 }, (_, index) => `host-${String(index)}.example.test`)
  const manifest = buildCapabilityManifest(manifestInput({
    commands,
    pythonModules: modules,
    egressAllow: egress,
    python: { available: true, version: '3.13' },
  }))
  const bytes = Buffer.byteLength(manifest.markdown, 'utf8')
  assert.ok(bytes <= AGENTS_MD_MAX_BYTES, `AGENTS.md is ${String(bytes)} B; the budget is ${String(AGENTS_MD_MAX_BYTES)} B`)
  assert.match(manifest.markdown, /\/dsh\/home\/capabilities\.json/u)
  assert.match(manifest.markdown, /pdsh-shell: exit=127/u)
  assert.match(manifest.markdown, /`\/tmp` and `\/dsh\/tmp`/u)
  assert.match(manifest.markdown, /pip/u)
  // G2-FIX-107 made `trap` a real EXIT-only builtin. The manifest must not
  // keep publishing the retired JB-TRAP deviation (or the old "not
  // implemented" note) now that `type trap` and execution agree.
  assert.doesNotMatch(manifest.markdown, /JB-TRAP|`trap` builtin is not implemented/iu)
  assert.match(manifest.markdown, /JB-EPOCHSECONDS/u)
  assert.doesNotMatch(manifest.markdown, /trap.*not implemented/iu)
  assert.deepEqual(manifest.json.bash.deviations.map(deviation => deviation.id), ['JB-EPOCHSECONDS', 'JB-DEV0'])
  assert.deepEqual(DEFAULT_BASH_DEVIATIONS.map(deviation => deviation.id), ['JB-EPOCHSECONDS', 'JB-DEV0'])
})

test('the boot manifest carries generic task-execution guidance, not a scenario answer', () => {
  const manifest = buildCapabilityManifest(manifestInput())
  assert.ok(manifest.markdown.includes(TASK_EXECUTION_GUIDANCE), 'the rendered file contains the advice verbatim')
  assert.ok(
    manifest.markdown.indexOf(TASK_EXECUTION_GUIDANCE) < manifest.markdown.indexOf('## Shell'),
    'the advice is published before the environment facts',
  )
  // Every required execution prior is present in one compact paragraph.
  assert.match(TASK_EXECUTION_GUIDANCE, /User first/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /small self-contained edits direct/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /Delegate only parallel\/explicit/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /Batch coherent edits\/checks/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /no idle agent\/job polls/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /verify, stop/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /Python math if available/u)
  assert.match(TASK_EXECUTION_GUIDANCE, /no large unasked outputs/u)
  assert.ok(Buffer.byteLength(TASK_EXECUTION_GUIDANCE, 'utf8') <= 200, 'the advice stays inside its 200 B share')
  // The advice must remain general: no scenario id, file name, budget change
  // or tool/safety exception can hide in the text.
  assert.doesNotMatch(TASK_EXECUTION_GUIDANCE, /scenario|G2-|F0[0-9]|budget|credential|NOT_RUN|\.md/iu)
})

test('the native office and phone surfaces match both Swift dispatch tables and handles', () => {
  const absent = buildCapabilityManifest(manifestInput())
  assert.equal(absent.json.phone, undefined)
  assert.ok(!absent.markdown.includes('Native office tools'))
  const manifest = buildCapabilityManifest(manifestInput({ commands: ['bash', 'phone'] }))
  assert.equal(manifest.json.phone?.command, 'phone')
  assert.deepEqual(manifest.json.phone?.tools, PHONE_TOOL_CAPABILITIES)
  assert.ok(manifest.markdown.includes('phone <tool> <json>'))
  assert.ok(manifest.markdown.includes('actually call read_image'))
  const here = dirname(fileURLToPath(import.meta.url))
  const root = join(here, '../../../examples/probe-app/ProbeKit')
  const office = readFileSync(join(root, 'Office/OfficeToolBridge.swift'), 'utf8')
  const phone = readFileSync(join(root, 'PhoneCapabilityBridge.swift'), 'utf8')
  const catalog = readFileSync(join(root, 'Capabilities/PhoneCapabilityGate.swift'), 'utf8')
  const composite = readFileSync(join(root, 'CompositePhoneToolBridge.swift'), 'utf8')
  const cases = (source: string): string[] => [...source.matchAll(/^\s+case "([^"]+)":$/gmu)].map(match => match[1]!).sort()
  const officeHandlesBlock = /public let handles: Set<String> = \[([\s\S]*?)\]/u.exec(office)?.[1]
  assert.ok(officeHandlesBlock !== undefined, 'OfficeToolBridge publishes a literal handles table')
  const officeHandles = [...officeHandlesBlock.matchAll(/"([^"]+)"/gu)].map(match => match[1]).sort()
  assert.deepEqual(officeHandles, cases(office), 'Office handles covers exactly the legacy routes')
  const catalogTools = [...catalog.matchAll(/^\s+"([^"]+)": PhoneToolRoute\(/gmu)].map(match => match[1]).sort()
  assert.deepEqual(catalogTools, cases(phone), 'capability handles source and dispatch table cannot drift')
  assert.ok(phone.includes('Set(PhoneToolCatalog.routes.keys)'), 'PhoneCapabilityBridge handles uses the verified catalog')
  assert.ok(composite.includes('$0.handles.contains(tool)'), 'composite dispatch is limited to advertised handles')
  assert.ok(composite.includes('.unknownTool(tool)'), 'unknown composite tools fail closed')
  assert.deepEqual([...cases(office), ...cases(phone)].sort(), PHONE_TOOL_CAPABILITIES.map(tool => tool.name).sort())
  for (const required of ['location.geofence', 'focus.status', 'home.list', 'home.set', 'music.play', 'activity.start', 'activity.update', 'shortcuts.run']) {
    assert.ok(PHONE_TOOL_CAPABILITIES.some(tool => tool.name === required), `${required} has a real dispatch and permission gate`)
  }
})

test('system authorization APIs stay inside the permission requester and its extended controller', () => {
  const here = dirname(fileURLToPath(import.meta.url))
  const root = join(here, '../../../examples/probe-app/ProbeKit')
  const swiftFiles = (directory: string): string[] => readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name)
    return entry.isDirectory() ? swiftFiles(path) : entry.name.endsWith('.swift') ? [path] : []
  })
  const request = /\b(?:requestAccess|requestFullAccessToEvents|requestFullAccessToReminders|requestAuthorization|requestWhenInUseAuthorization|requestAlwaysAuthorization|requestRecordPermission|evaluatePolicy)\s*\(/u
  const offenders = [...swiftFiles(join(root, 'Permissions')), ...swiftFiles(join(root, 'Capabilities'))]
    .filter(path => !path.endsWith('PhonePermissionRequester.swift'))
    .filter(path => !path.endsWith('PhoneExtendedPermissions.swift'))
    .filter(path => request.test(readFileSync(path, 'utf8')))
  assert.deepEqual(offenders, [], 'tools and views must return permission_required instead of prompting')
  const requester = readFileSync(join(root, 'Permissions/PhonePermissionRequester.swift'), 'utf8')
  assert.match(requester, /case \.unnecessary: return \.requested/u, 'Health read request completion is not mislabeled granted')
  assert.match(requester, /toShare: \[\], read: Self\.healthReadTypes/u, 'HealthKit never requests write access')
})

test('the production manifest fits 4 KiB with the advice and full Python/Bash facts', () => {
  const surface = workerCommandSurface({ accelerators: ['rg'], toolbox: fakeToolbox() })
  const manifest = buildCapabilityManifest(manifestInput({
    commands: surface.commands,
    accelerators: surface.accelerators,
    pythonModules: [...PRODUCTION_PYTHON_MODULES],
    python: {
      available: true,
      version: '3.13',
      compression: { zlib: true, bz2: true, lzma: true, tarfileGzip: true },
    },
    egressAllow: [...PRODUCTION_EGRESS],
  }))
  const bytes = Buffer.byteLength(manifest.markdown, 'utf8')
  assert.ok(bytes <= AGENTS_MD_MAX_BYTES, `AGENTS.md is ${String(bytes)} B; the budget is ${String(AGENTS_MD_MAX_BYTES)} B`)
  assert.doesNotMatch(manifest.markdown, /shortened to fit/u, 'the budget fallback keeps the whole document')
  assert.ok(manifest.markdown.includes(TASK_EXECUTION_GUIDANCE))
  // The production command/egress surface uses the existing compact summary,
  // with the exact lists still in the JSON document.
  assert.ok(
    manifest.markdown.includes(`Commands: ${String(surface.commands.length)} (e.g.`),
    'the production command table uses the compact summary',
  )
  assert.ok(manifest.markdown.includes('full sorted list in /dsh/home/capabilities.json'))
  assert.deepEqual(manifest.json.commands, surface.commands)
  assert.deepEqual(manifest.json.network.egress_allow, PRODUCTION_EGRESS)
  assert.deepEqual(manifest.json.python_modules, [...PRODUCTION_PYTHON_MODULES].sort())
  // The original capability details stay in the model instructions, not only
  // in capabilities.json.
  assert.ok(manifest.markdown.includes('Missing: pip/ensurepip (the image is stdlib-only; no package installs);'))
  assert.ok(manifest.markdown.includes('`subprocess` is a shim: `Popen` runs another `python3`'))
  assert.ok(manifest.markdown.includes('`EPOCHSECONDS` and `EPOCHREALTIME` are unset'))
})

test('the recorded A05/A06 capability questions are answered before the first request', () => {
  // The first real-model batch spent 26 (A05) and 9 (A06) requests finding out
  // what the environment could do. This is the deterministic proxy for the
  // external rerun: every capability question the transcripts record has a
  // direct answer in the boot manifest, so none of them needs a shell probe.
  const surface = workerCommandSurface({ toolbox: fakeToolbox() })
  const manifest = buildCapabilityManifest(manifestInput({
    commands: surface.commands,
    accelerators: surface.accelerators,
    pythonModules: [
      'bz2', 'ctypes', 'json', 'lzma', 'pathlib', 're', 'socket', 'sqlite3',
      'ssl', 'subprocess', 'tarfile', 'venv', 'zlib',
    ],
    python: { available: true, version: '3.13' },
    egressAllow: ['gateway.example.test'],
  }))
  const commands = new Set(manifest.json.commands)
  const modules = new Set(manifest.json.python_modules)
  const missing = manifest.json.python.missing.join('; ')
  const checks: [string, boolean][] = [
    ['A05 tar/gzip and checksum commands', ['tar', 'gzip', 'gunzip', 'zcat', 'sha256sum'].every(name => commands.has(name))],
    ['A05 python3 fallback', commands.has('python3') && manifest.json.python.available],
    ['A05 compression modules', ['zlib', 'bz2', 'lzma', 'tarfile'].every(name => modules.has(name))],
    ['A05 pip/unzip gaps', missing.includes('pip') && missing.includes('imports')],
    ['A06 mv/rm/seq/ls commands', ['mv', 'rm', 'ls', 'seq'].every(name => commands.has(name))],
    ['A06 shell syntax', manifest.markdown.includes('POSIX shell syntax and builtins')],
    ['limits answered', manifest.markdown.includes('one file <=') && manifest.markdown.includes('request body <=')],
    ['tmp semantics answered', manifest.markdown.includes('one volatile store')],
    ['egress answered', manifest.markdown.includes('egress allow-list: gateway.example.test')],
    ['bash deviations answered', manifest.markdown.includes('JB-EPOCHSECONDS') && !manifest.markdown.includes('JB-TRAP')],
    ['recovery answered', manifest.markdown.includes('restart replays')],
  ]
  assert.deepEqual(checks.filter(([, pass]) => !pass).map(([name]) => name), [])
})

test('the upstream instruction loader injects the generated file from $DSH_HOME/AGENTS.md', async () => {
  const home = mkdtempSync(join(tmpdir(), 'pdsh-manifest-home-'))
  try {
    const manifest = buildCapabilityManifest(manifestInput({
      commands: ['bash', 'tar'],
      pythonModules: ['json', 're', 'pathlib', 'zlib'],
      python: { available: true, version: '3.13' },
      egressAllow: ['gateway.example.test'],
    }))
    writeFileSync(join(home, 'AGENTS.md'), manifest.markdown)
    const rendered = await loadBaselineInstructions({
      cwd: home,
      dshHome: home,
      agentsHome: join(home, '.agents'),
      maxBytes: 65_536,
    })
    assert.notEqual(rendered, undefined)
    assert.match(rendered?.text ?? '', /Instructions from: \$DSH_HOME\/AGENTS\.md/u)
    assert.ok(
      (rendered?.text ?? '').includes('/dsh/home/capabilities.json'),
      'the loader injects the manifest text, including the machine-readable path',
    )
    assert.ok(
      (rendered?.text ?? '').includes(TASK_EXECUTION_GUIDANCE),
      'the same real upstream loader injects the generic task-execution guidance',
    )
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
})

test('publishing unchanged content is a no-op for the VFS sink', async () => {
  const vfs = createMemoryVfs()
  const manifest = buildCapabilityManifest(manifestInput({ egressAllow: ['gateway.example.test'] }))
  const first = await publishCapabilityManifest(vfs, manifest)
  assert.deepEqual([...first.written].sort(), [AGENTS_MD_PATH, CAPABILITIES_JSON_PATH].sort())
  const afterFirst = vfs.mutations.length
  const second = await publishCapabilityManifest(vfs, manifest)
  assert.deepEqual(second.written, [])
  assert.deepEqual([...second.unchanged].sort(), [AGENTS_MD_PATH, CAPABILITIES_JSON_PATH].sort())
  assert.equal(vfs.mutations.length, afterFirst, 'unchanged content does not emit a VFS_MUT')
})

/** The runtime seam a boot needs; `createHost` returns the shared memory VFS. */
function fakeRuntime(vfs: MemoryVfs): PhoneWorkerRuntime {
  const synthesize: WorkerEntrySynthesize = () => ({
    req: {},
    res: {},
    aborted: false,
    abort: () => {},
  })
  return {
    createHost: (): PhoneWorkerHostLike => ({
      handleMessage: () => {},
      start: async () => {},
      vfs,
    }),
    whenRequestListener: async () => () => {},
    synthesize,
  }
}

test('boot publishes both files before ready and a second boot emits no VFS_MUT', async () => {
  // A real planned restart builds a new Worker/VFS over the persisted home
  // (D24). Two VFS objects share the byte store here, so the second boot
  // proves the content-hash check on real persisted bytes.
  const store = createMemoryStore()
  const firstVfs = createMemoryVfs(store)
  const runtime = fakeRuntime(firstVfs)
  const egress = ['gateway.example.test', 'api.example.test']
  const firstPair = createMemoryChannelPair({ autoConnect: true, caps: ['accelerator:rg'] })
  const firstRuntime: PhoneWorkerRuntime = { ...runtime, createChannel: () => firstPair.worker }
  const first = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    imageURL: 'image.tar.gz',
    egressAllow: egress,
    // The explicit init list wins over the environment fallback.
    env: { PDSH_EGRESS_ALLOW: 'env.example.test' },
    python: false,
    runtime: firstRuntime,
    pagePost: () => {},
  })
  try {
    const written = JSON.parse(firstVfs.contents(CAPABILITIES_JSON_PATH) ?? '{}') as {
      network?: { egress_allow?: string[] }
    }
    assert.deepEqual(written.network?.egress_allow, egress)
    assert.notEqual(firstVfs.contents(AGENTS_MD_PATH), undefined)
  } finally {
    await first.stop()
  }
  await new Promise<void>((resolve) => setTimeout(resolve, 0))
  assert.deepEqual(firstVfs.mutations.sort(), [AGENTS_MD_PATH, CAPABILITIES_JSON_PATH].sort())

  const secondVfs = createMemoryVfs(store)
  const secondPair = createMemoryChannelPair({ autoConnect: true, caps: ['accelerator:rg'] })
  const secondRuntime: PhoneWorkerRuntime = {
    ...fakeRuntime(secondVfs),
    createChannel: () => secondPair.worker,
  }
  const second = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    imageURL: 'image.tar.gz',
    // No explicit list: the same hosts arrive through the D24 environment.
    env: { PDSH_EGRESS_ALLOW: egress.join(',') },
    python: false,
    runtime: secondRuntime,
    pagePost: () => {},
  })
  try {
    assert.deepEqual(secondVfs.mutations, [], 'the second boot wrote nothing')
    assert.equal(secondVfs.contents(CAPABILITIES_JSON_PATH), firstVfs.contents(CAPABILITIES_JSON_PATH))
    assert.equal(secondVfs.contents(AGENTS_MD_PATH), firstVfs.contents(AGENTS_MD_PATH))
  } finally {
    await second.stop()
  }
  assert.equal(SHELL_MANIFEST_PATH, CAPABILITIES_JSON_PATH, 'the 127 trailer points at the published file')
})
