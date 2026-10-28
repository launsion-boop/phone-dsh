// SPDX-License-Identifier: MIT
/**
 * The packed phone image boots DSH 0.2.1 in the Worker runtime.
 *
 * The test packs `plugins` with `scripts/pack-image.mjs` from the pinned
 * checkout, bundles `tests/fixtures/worker-boot-harness.ts` against the
 * checkout's webworker-runtime sources, and runs it under Node with the phone
 * profile and a stubbed ordered channel. The harness reproduces WebKit's
 * JavaScriptCore native-function source format, so this exercises the same
 * plain-JSON record boundary the real Worker hits.
 *
 * It fails when a roster row is disabled by the app-boot compatibility
 * preflight, when a tool row hits `authorError`, when a runtime module proxy
 * reports a not-implemented feature, when any row stays inactive, when the
 * surface never writes `XL_DSH_READY`, or when any console line is logged at
 * error level (the Worker entry's profile stub overlay keeps the image's `web`
 * template from reporting its absent browser bundle as skipped).
 *
 * WebKit/on-device execution remains NOT_VERIFIED; this test runs the Worker
 * runtime under Node.
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
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the Worker runtime and roster come from the pinned checkout'
  : false

/** Temp directories created by this file. */
const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

interface CapturedLine {
  level: string
  text: string
}

interface WorkspaceProbe {
  workspacePath?: string
  workspaceTitle?: string
  sessionId?: string
  importedWorkspacePath?: string
  importedAbsolutePath?: string
  readText?: string
  presets?: { id: string; isDefault: boolean; broken?: string }[]
  presetSessions?: Record<string, string>
  presetErrors?: Record<string, string>
  workflowFileText?: string
  workflowChildResultSeen?: boolean
  workflowTextSeen?: boolean
  mcpFile?: string
  mcpInitialServers?: number
  mcpUpsertStatus?: string
  mcpTools?: string[]
  mcpListStatus?: string
  mcpListTools?: string[]
  mcpRemoved?: boolean
  mcpAfterRemove?: number
  mcpCallIsError?: boolean
  mcpCallContent?: string
  mcpToolsAfterRemove?: string[]
  importDiagnosticName?: string
  importDiagnosticMessage?: string
  importDiagnosticFirstStackLine?: string
  importDiagnosticCause?: string
}

interface BootResult {
  ok: boolean
  thrown?: string
  lines: CapturedLine[]
  probe?: WorkspaceProbe
}

const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'

/**
 * Bundle the boot harness against the pinned checkout's runtime sources. The
 * checkout is not an npm dependency of plugins, so the runtime prefix is
 * resolved explicitly, exactly as worker-entry/build.mjs does.
 * @param options - bundle inputs.
 * @param options.outfile - bundled harness path.
 * @param options.checkout - verified pinned checkout.
 * @returns resolves when esbuild wrote the harness.
 */
async function bundleHarness(options: { outfile: string; checkout: string }): Promise<void> {
  const runtimeSrc = join(options.checkout, 'packages/experimental/webworker-runtime/src')
  await build({
    entryPoints: [join(root, 'tests', 'fixtures', 'worker-boot-harness.ts')],
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
 * Run one child process to completion and collect its streams.
 * @param command - executable.
 * @param args - argv after the executable.
 * @param environment - complete child environment.
 * @returns exit status and captured text.
 */
function run(command: string, args: string[], environment: NodeJS.ProcessEnv): Promise<{
  status: number | null
  stdout: string
  stderr: string
}> {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, { env: environment, stdio: ['ignore', 'pipe', 'pipe'] })
    const stdout: Buffer[] = []
    const stderr: Buffer[] = []
    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk))
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk))
    child.once('error', reject)
    child.once('close', status => resolveRun({
      status,
      stdout: Buffer.concat(stdout).toString('utf8'),
      stderr: Buffer.concat(stderr).toString('utf8'),
    }))
  })
}

test('the packed phone image boots DSH 0.2.1 with every roster row live or documented pending', {
  skip,
  timeout: 180_000,
}, async () => {
  assert.notEqual(checkout, undefined)
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-image-boot-'))
  scratch.push(directory)
  const imageDirectory = join(directory, 'image')
  const environment = { ...process.env, PDSH_DSH_CHECKOUT: checkout }

  const pack = spawnSync(process.execPath, [join(root, 'scripts', 'pack-image.mjs'), '--out', imageDirectory], {
    cwd: root,
    env: environment,
    encoding: 'utf8',
  })
  assert.equal(pack.status, 0, `pack-image failed (${String(pack.status)}):\n${pack.stdout}\n${pack.stderr}`)

  // The workflow bridge spawns this file beside worker-entry.js; the Node
  // harness receives its path explicitly because it has no Worker location.
  const workerOut = join(directory, 'worker')
  const workerBuild = spawnSync(process.execPath, [join(root, 'worker-entry', 'build.mjs'), '--out', workerOut], {
    cwd: root,
    env: environment,
    encoding: 'utf8',
  })
  assert.equal(workerBuild.status, 0, `worker-entry build failed:\n${workerBuild.stdout}\n${workerBuild.stderr}`)

  const harness = join(directory, 'worker-boot-harness.mjs')
  await bundleHarness({ outfile: harness, checkout: checkout as string })

  const boot = await run(process.execPath, [harness, join(imageDirectory, 'image.tar.gz')], {
    ...environment,
    PDSH_WORKFLOW_ISOLATE_PATH: join(workerOut, 'workflow-isolate.js'),
    // The profile normalizes JSC's native-function source format; the harness
    // reproduces it so the tool-schema boundary is actually exercised.
    PDSH_EMULATE_JSC: '1',
  })
  const marker = boot.stdout
    .split('\n')
    .find(line => line.startsWith('__PDSH_BOOT_RESULT__ '))
  assert.ok(marker !== undefined, `boot harness wrote no result line\n${boot.stdout}\n${boot.stderr}`)
  const result = JSON.parse(marker.slice('__PDSH_BOOT_RESULT__ '.length)) as BootResult
  const lines = result.lines.map(line => `${line.level}: ${line.text}`)
  // The browser-only connection carrier is pending by design: it injects
  // webStartup (never provided) and credentials (disabled), so phone-surface
  // remains the one host ctx.connection. Everything else must be active; any
  // other pending or failed diagnostic is a violation.
  const documentedPending = [
    { id: 'connection-browser', name: '@deepseek-ai/dsh-client-connection', missing: ['webStartup', 'credentials'] },
  ]
  const pendingAllowed = (detail: string): boolean => documentedPending.some(({ id, name, missing }) => {
    const prefix = `${id} (${name}): pending (waiting for `
    if (!detail.startsWith(prefix)) return false
    const rest = detail.slice(prefix.length).replace(/\)$/u, '')
    const services = rest.replace(/^services?: /u, '').split(', ')
    return services.length === missing.length && services.every(service => missing.includes(service))
  })
  const documentedPendingWarning = (text: string): boolean => {
    if (!/dsh: warning: \d+ entr(?:y|ies) did not activate/.test(text)) return false
    const details = text.split('\n').filter(detail => /^.+? \(.+?\): /.test(detail))
    return details.length > 0 && details.every(detail => pendingAllowed(detail.trim()))
  }
  const violations: string[] = []
  for (const line of result.lines) {
    if (/dsh: disabling profile plugin/.test(line.text)) {
      violations.push(`compatibility preflight disabled a row:\n${line.text}`)
    }
    if (/authorError|JsonSchemaError|unsupported JSON schema|runSchemaCompiler/.test(line.text)) {
      violations.push(`tool schema authorError:\n${line.text}`)
    }
    if (/is not available in the worker host|ERR_FEATURE_UNAVAILABLE_ON_PLATFORM|notImplementedFail/.test(line.text)) {
      violations.push(`runtime module is not implemented:\n${line.text}`)
    }
    if (/dsh: warning: \d+ entr(?:y|ies) did not activate/.test(line.text)) {
      const details = line.text.split('\n').filter(detail => /^.+? \(.+?\): /.test(detail))
      const unexpected = details.filter(detail => !pendingAllowed(detail.trim()))
      if (unexpected.length > 0) violations.push(`roster row did not activate:\n${unexpected.join('\n')}`)
    }
    if (line.level === 'uncaught' || line.level === 'unhandled') {
      violations.push(`boot raised ${line.level}:\n${line.text}`)
    }
  }
  assert.deepEqual(violations, [], `the packed image booted with violations:\n${violations.join('\n\n')}`)
  // The minimal preset's persistent-shell row is intentionally refused at
  // mount; that refusal is the real diagnostic the health probe asserts below.
  const documentedBrokenPreset = (text: string): boolean =>
    text.startsWith('terminal: Error: the phone Worker has no terminal (PTY) primitive')
  const errorLines = result.lines.filter(line => line.level === 'error'
    && !documentedPendingWarning(line.text)
    && !documentedBrokenPreset(line.text))
  assert.deepEqual(
    errorLines,
    [],
    `the packed image booted with error-level console output:\n${errorLines.map(line => line.text).join('\n')}`,
  )
  assert.ok(
    result.lines.some(line => /XL_DSH_READY \d+/.test(line.text)),
    `XL_DSH_READY was not emitted:\n${lines.join('\n')}`,
  )
  assert.equal(result.ok, true, `host.start() failed: ${result.thrown ?? 'unknown error'}\n${boot.stderr}`)

  // First-use Workspace through the actual accumulated /api carrier. The
  // Worker image must create it under the App's durable workspace mount, then
  // create a session in that same Workspace, import a real file, and read it
  // back through the Files Remote. Logs above already redact transport input;
  // this probe never includes a credential.
  const probe = result.probe
  assert.ok(probe !== undefined, 'the boot harness ran no first-use Workspace probe')
  assert.equal(probe.workspacePath, '/dsh/workspace/deepseek-harness/default-workspace')
  assert.equal(probe.workspaceTitle, 'default-workspace')
  assert.match(probe.sessionId ?? '', /^session-/)
  assert.equal(probe.importedWorkspacePath, 'imports/first-launch')
  assert.ok(
    (probe.importedAbsolutePath ?? '').startsWith(
      '/dsh/workspace/deepseek-harness/default-workspace/imports/first-launch'),
    `imported file must be inside the same session workspace: ${probe.importedAbsolutePath ?? ''}`,
  )
  assert.equal(probe.readText, 'hello workspace')

  // The official roster, through the real agent-preset Remote.
  const presets = new Map((probe.presets ?? []).map(row => [row.id, row]))
  for (const id of ['standard', 'ptc', 'phone', 'minimal', 'cordis']) {
    assert.ok(presets.has(id), `preset ${id} must remain listed, not hidden: ${JSON.stringify(probe.presets)}`)
  }
  assert.equal(presets.get('standard')?.broken, undefined, `standard must resolve: ${presets.get('standard')?.broken ?? ''}`)
  assert.equal(presets.get('standard')?.isDefault, true, 'standard must be the default preset again')
  assert.equal(presets.get('ptc')?.broken, undefined, `ptc must resolve with native-equivalent presentation: ${presets.get('ptc')?.broken ?? ''}`)
  assert.equal(presets.get('phone')?.broken, undefined, `legacy phone preset must stay usable: ${presets.get('phone')?.broken ?? ''}`)
  assert.equal(presets.get('phone')?.isDefault, false, 'phone is legacy compatibility, not the default')
  assert.match(presets.get('minimal')?.broken ?? '', /terminal/i, 'minimal must report its real missing terminal/PTY capability')
  assert.match(presets.get('cordis')?.broken ?? '', /cordisInspect/i, 'cordis must report its real missing inspector service')

  assert.match(probe.presetSessions?.standard ?? '', /^session-/, `standard session/create failed: ${probe.presetErrors?.standard ?? ''}`)
  assert.match(probe.presetSessions?.ptc ?? '', /^session-/, `ptc session/create failed: ${probe.presetErrors?.ptc ?? ''}`)
  for (const preset of ['minimal', 'cordis']) {
    assert.match(probe.presetErrors?.[preset] ?? '', /agent-preset\/invalid/,
      `${preset} session/create must fail with the real invalid-preset diagnostic, not pretend to succeed`)
  }

  // Real workflow execution: the scripted model only chose tools; the file,
  // the child text and the parent tool result all come from the real Worker.
  assert.equal((probe.workflowFileText ?? '').trim(), 'WORKFLOW_FILE_OK')
  assert.equal(probe.workflowChildResultSeen, true,
    'the parent Session tool result must contain the child agent text WORKFLOW_BASH_OK')
  assert.equal(probe.workflowTextSeen, true, 'the parent model completed with WORKFLOW_DONE')

  // The packed image's phone/mcp Remote is live in this Worker: a real local
  // Streamable HTTP MCP server mounts, registers its exact tool names, lists,
  // executes one through the same ToolRuntime the model uses, and leaves no
  // registration after removal. The Node suite covers the same manager/client
  // behavior directly; this probe is the packed-image/Worker boundary.
  assert.equal(probe.mcpFile, '/dsh/home/mcp.json')
  assert.equal(probe.mcpInitialServers, 0)
  assert.equal(probe.mcpUpsertStatus, 'connected')
  assert.deepEqual(probe.mcpTools, ['mcp__image__echo', 'mcp__image__ping'])
  assert.equal(probe.mcpListStatus, 'connected')
  assert.deepEqual(probe.mcpListTools, ['mcp__image__echo', 'mcp__image__ping'])
  assert.equal(probe.mcpCallIsError, false)
  assert.match(probe.mcpCallContent ?? '', /echo:from-image/)
  assert.equal(probe.mcpRemoved, true)
  assert.equal(probe.mcpAfterRemove, 0)
  assert.deepEqual(probe.mcpToolsAfterRemove, [])

  // The production host factory installed the import diagnostic on the live
  // packed-image loader; a real missing-module import reports its name, the
  // original message and code, and the import path instead of `anonymous@`.
  assert.equal(probe.importDiagnosticName, 'ModuleImportError')
  assert.match(
    probe.importDiagnosticMessage ?? '',
    /^ModuleImportError: Error: .*__missing_module_import_probe__.*\[MODULE_NOT_FOUND\]/,
  )
  assert.equal(probe.importDiagnosticFirstStackLine, probe.importDiagnosticMessage,
    'the stack header the activation audit reads must carry the same diagnostic as message')
  assert.equal(probe.importDiagnosticCause, 'absent', 'the raw failure must not be attached as cause')
  assert.match(probe.importDiagnosticMessage ?? '', /importing @phone-dsh\/__missing_module_import_probe__/)
  assert.match(probe.importDiagnosticMessage ?? '', /from \/dsh\/home\/profiles\/web\//)

  // The boot process exits after reporting; a crash after start still fails.
  assert.equal(boot.status, 0, `boot harness exited ${String(boot.status)}\n${boot.stderr}`)

  // Repeat in the scope a WKWebView Worker actually has: no Node `global`
  // alias. Without it, isexe (which <- cross-spawn <- the official MCP SDK's
  // stdio import) throws `global is not defined` and phone-mcp never mounts.
  // The harness installs the prelude directly in this run (function-level
  // simulation); that the production entry/bundle installs it from its first
  // import is proven separately by jsc-compat.test.ts, whose stub entry deletes
  // `global` before its dynamic import.
  const workerGlobalBoot = await run(process.execPath, [harness, join(imageDirectory, 'image.tar.gz')], {
    ...environment,
    PDSH_WORKFLOW_ISOLATE_PATH: join(workerOut, 'workflow-isolate.js'),
    PDSH_EMULATE_JSC: '1',
    PDSH_EMULATE_WORKER_GLOBAL: '1',
  })
  const workerGlobalMarker = workerGlobalBoot.stdout
    .split('\n')
    .find(line => line.startsWith('__PDSH_BOOT_RESULT__ '))
  assert.ok(workerGlobalMarker !== undefined,
    `Worker-global boot wrote no result line\n${workerGlobalBoot.stdout}\n${workerGlobalBoot.stderr}`)
  const workerGlobalResult = JSON.parse(
    workerGlobalMarker.slice('__PDSH_BOOT_RESULT__ '.length),
  ) as BootResult
  assert.equal(workerGlobalResult.ok, true,
    `Worker-global boot failed: ${workerGlobalResult.thrown ?? 'unknown error'}\n${workerGlobalBoot.stderr}`)
  const workerGlobalFailures = workerGlobalResult.lines.filter(line =>
    (line.level === 'error'
      && !documentedPendingWarning(line.text)
      && !documentedBrokenPreset(line.text))
    || line.level === 'uncaught'
    || line.level === 'unhandled'
    || /phone-mcp .*failed to import/.test(line.text)
    || /global is not defined/.test(line.text))
  assert.deepEqual(workerGlobalFailures, [],
    `Worker-global boot raised failures:\n${workerGlobalFailures.map(line => line.text).join('\n')}`)
  assert.equal(workerGlobalBoot.status, 0,
    `Worker-global boot harness exited ${String(workerGlobalBoot.status)}\n${workerGlobalBoot.stderr}`)
})
