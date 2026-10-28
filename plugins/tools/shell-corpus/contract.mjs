// SPDX-License-Identifier: MIT
/**
 * Class-level contract gate for the Worker command surface.
 *
 * `golden.mjs` answers one vector at a time ("did this command print the
 * committed bytes?"). This gate answers the questions a single vector cannot:
 *
 * 1. **Size and coverage.** The committed corpus must hold at least
 *    {@link MIN_GOLDEN_VECTORS} vectors and exercise every command family the
 *    G2 scenarios reached for (tar, gzip/gunzip/zcat, find, stat, awk,
 *    realpath, readlink, seq, command -v/which, python, rg, curl, cmp,
 *    redirection and `/dev/null`).
 * 2. **Expected deviations.** The engine cannot implement a few bash features;
 *    each one is recorded with an upstream gap id, capped at
 *    {@link MAX_EXPECTED_DEVIATIONS}, and printed as a manifest for the
 *    upstream/ENG-05 report. A deviation that starts passing is an error too:
 *    the manifest must be updated, not silently stale.
 * 3. **Exit taxonomy and stderr trailers.** The behaviours a scenario cannot
 *    see from stdout are driven directly against the production command table:
 *    a program the Worker does not serve answers 127 plus a manifest hint that
 *    names a file the same boot materialised, a Worker program that ran and
 *    exited answers `reason=command-exited` (never `backend-failed`), only a
 *    failure of our own execution layer answers `reason=backend-failed`, a
 *    gzip with no backend answers non-zero and writes no member (never a
 *    0-byte success), a usage error answers 2, a cut stream answers non-zero
 *    with `reason=output-truncated`, and file redirections are not counted
 *    against the output cap.
 * 4. **G2-A05 probe budget.** The capability questions the compression
 *    scenario's `backup.sh` asks are replayed against the production table
 *    (`probe-budget.mjs`): every answer must be definitive and the request
 *    count must at least halve the 26 the first real-model batch recorded.
 *
 * The 127/usage/trailer checks are the regression gate for the two silent-lie
 * classes of G2-A05/G2-E09: error output with exit 0, and a bare 127 with no
 * statement about what the Worker provides.
 *
 * Usage:
 *   node tools/shell-corpus/contract.mjs [--golden FILE] [--manifest FILE] [--quiet]
 *
 * Exit status: 0 when the corpus and every class check pass, 1 when one
 * differs, 2 on bad arguments or an unreadable corpus file.
 * @module tools/shell-corpus/contract
 */

import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  DEFAULT_GOLDEN,
  parseGolden,
  runGoldenVectors,
} from './golden.mjs'
import {
  A05_BASELINE,
  compareProbeBudget,
  runProbeReplay,
} from './probe-budget.mjs'
import {
  SHELL_MANIFEST_PATH,
  VfsFileSystem,
  WorkerShell,
  createGunzipCommand,
  createGzipCommand,
  createTarCommand,
  createWorkerCommands,
  createZcatCommand,
  parseShellTrailer,
} from '../../shell-ext/src/index.ts'

/** Minimum committed corpus size the task's acceptance requires. */
export const MIN_GOLDEN_VECTORS = 300

/** Maximum recorded engine deviations (each carries an upstream gap id). */
export const MAX_EXPECTED_DEVIATIONS = 10

/** Working directory of every golden vector. */
const CWD = '/dsh/workspace'

/**
 * Command families the corpus must exercise, with a minimum vector count.
 *
 * The counts are deliberately above one: a single vector can be the accidental
 * spelling of a command, a handful is a semantics claim.
 */
export const REQUIRED_FAMILIES = Object.freeze([
  { name: 'tar', pattern: /(^|[\s;&|()`])tar\s/u, min: 6 },
  { name: 'gzip', pattern: /(^|[\s;&|(`])gzip\s/u, min: 5 },
  { name: 'gunzip', pattern: /(^|[\s;&|(`])gunzip\s/u, min: 3 },
  { name: 'zcat', pattern: /\bzcat\b/u, min: 2 },
  { name: 'find', pattern: /(^|[\s;&|(`])find\s/u, min: 8 },
  { name: 'grep', pattern: /(^|[\s;&|(`])grep\s/u, min: 6 },
  { name: 'stat', pattern: /(^|[\s;&|(`])stat\s/u, min: 8 },
  { name: 'awk', pattern: /(^|[\s;&|(`])awk\s/u, min: 6 },
  { name: 'realpath', pattern: /(^|[\s;&|(`])realpath\s/u, min: 4 },
  { name: 'readlink', pattern: /(^|[\s;&|(`])readlink\s/u, min: 4 },
  { name: 'seq', pattern: /(^|[\s;&|(`])seq\s/u, min: 3 },
  { name: 'command-v', pattern: /command\s+-v\b/u, min: 4 },
  { name: 'which', pattern: /\bwhich\b/u, min: 3 },
  { name: 'python', pattern: /\bpython3?\b/u, min: 2 },
  { name: 'rg', pattern: /(^|[\s;&|(`])rg\s/u, min: 6 },
  { name: 'curl', pattern: /(^|[\s;&|(`])curl\s/u, min: 5 },
  { name: 'cmp', pattern: /(^|[\s;&|(`])cmp(\s|$)/u, min: 6 },
  { name: 'sort-zero', pattern: /(^|[\s;&|(`])sort\s[^\n]*(?:-[A-Za-z]*z(?:\s|$)|--zero-terminated)/u, min: 4 },
  { name: 'du-human', pattern: /(^|[\s;&|(`])du\s[^\n]*(?:--human-readable|-[A-Za-z]*h(?:\s|$))/u, min: 4 },
  { name: 'gnu-conventions', pattern: /(?:--version|--help|(?:^|\s)--(?:\s|$))/u, min: 8 },
  // G2-FIX-130: the input-consumption family (`inputs`, `input`,
  // `input_line_number`) had no vectors, so the class gate could not see that
  // the built-in answers `Unknown function` / a constant 1.
  { name: 'jq-inputs', pattern: /(^|[\s;&|(`])jq\s[^\n]*\b(?:inputs|input_line_number|input)\b/u, min: 4 },
  { name: 'redirection', pattern: /[<>]|&>/u, min: 10 },
  { name: 'devnull', pattern: /\/dev\/null\b/u, min: 4 },
])

/**
 * Programs whose own failure paths must carry a contract trailer.
 *
 * `find`/`stat` are absent on purpose: they delegate malformed expressions to
 * just-bash's built-in parser, whose byte-for-byte error is part of their
 * contract; their own format surface is covered by the taxonomy checks. `cmp`
 * is absent for the same reason: its usage line and `EOF on`/open diagnostics
 * are the host program's own bytes, generated by `cmp-golden.mjs`, so a trailer
 * would break the byte-exact comparison those vectors exist to enforce.
 */
const TRAILERED_PROGRAMS = new Set(['tar', 'gzip', 'gunzip', 'zcat', 'awk', 'realpath', 'readlink', 'rg', 'curl', 'python', 'python3', 'git'])

/** The unknown-program name the taxonomy check uses (never registered). */
export const UNKNOWN_PROGRAM = 'pdsh-definitely-not-a-program'

/** Build one throwaway VFS and shell. */
async function withShell(commands, task, options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-contract-'))
  for (const directory of ['/dsh/workspace', '/dsh/home', '/dsh/tmp']) {
    mkdirSync(join(root, directory), { recursive: true })
  }
  const fs = new VfsFileSystem({ root })
  const shell = new WorkerShell({ fs, commands, ...options })
  try {
    return await task({ shell, fs, root })
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

/** Trailer lines of a stderr stream, parsed. */
export function trailersOf(stderr) {
  return stderr
    .split('\n')
    .map(line => parseShellTrailer(line))
    .filter(trailer => trailer !== undefined)
}

/** Run one script against the given shell. */
async function run(shell, script, options = {}) {
  return await shell.run(['bash', '-c', script], { cwd: CWD, timeoutMs: 30_000, ...options })
}

/** File size of a VFS path over the throwaway root, or -1 when absent. */
function rootFileSize(root, virtualPath) {
  try {
    return statSync(join(root, virtualPath)).size
  } catch {
    return -1
  }
}

/**
 * Audit the committed vector set without running it.
 * @param {object[]} vectors - output of {@link parseGolden}.
 * @returns {{errors: string[], deviations: object[], families: Map<string, number>, failures: number}}
 */
export function auditCorpus(vectors) {
  const errors = []
  const families = new Map(REQUIRED_FAMILIES.map(family => [family.name, 0]))
  let failures = 0
  const deviations = []
  for (const vector of vectors) {
    for (const family of REQUIRED_FAMILIES) {
      if (family.pattern.test(vector.script)) families.set(family.name, (families.get(family.name) ?? 0) + 1)
    }
    if (vector.exitCode !== 0) failures += 1
    if (vector.expectedDeviation !== undefined) {
      deviations.push({
        name: vector.name,
        upstreamGap: vector.expectedDeviation.upstreamGap,
        ...vector.expectedDeviation.note === undefined ? {} : { note: vector.expectedDeviation.note },
      })
    }
  }
  if (vectors.length < MIN_GOLDEN_VECTORS) {
    errors.push(`corpus has ${String(vectors.length)} vectors; at least ${String(MIN_GOLDEN_VECTORS)} are required`)
  }
  for (const family of REQUIRED_FAMILIES) {
    const count = families.get(family.name) ?? 0
    if (count < family.min) {
      errors.push(`family '${family.name}' has ${String(count)} vectors; at least ${String(family.min)} are required`)
    }
  }
  if (failures < 40) {
    errors.push(`only ${String(failures)} vectors assert a non-zero exit; at least 40 are required`)
  }
  if (deviations.length > MAX_EXPECTED_DEVIATIONS) {
    errors.push(`${String(deviations.length)} expected deviations; at most ${String(MAX_EXPECTED_DEVIATIONS)} are allowed`)
  }
  const seenGaps = new Set()
  for (const deviation of deviations) {
    if (seenGaps.has(deviation.upstreamGap)) {
      errors.push(`expected deviation '${deviation.name}' reuses upstream gap id '${deviation.upstreamGap}'`)
    }
    seenGaps.add(deviation.upstreamGap)
  }
  return { errors, deviations, families, failures }
}

/**
 * Audit the trailers the corpus actually produced.
 *
 * A vector's committed `stderrPrefix` names the command's own diagnostic; this
 * pass inspects the observable stream for the class invariants instead of
 * asking the author to repeat them in every record:
 *
 * - a failure that printed an error from one of our programs ends in exactly
 *   one parseable trailer whose `exit=` matches the final status;
 * - `reason=not-available` names the capability manifest;
 * - a status-only negative (ripgrep's "no matches" exit 1 with empty stderr)
 *   needs no trailer, because it did not print an error.
 *
 * @param {object[]} vectors - committed vectors.
 * @param {object[]} results - output of {@link runGoldenVectors}.
 * @returns {{errors: string[]}} audit errors.
 */
export function auditTrailers(vectors, results) {
  const byName = new Map(vectors.map(vector => [vector.name, vector]))
  const errors = []
  for (const result of results) {
    const vector = byName.get(result.name)
    if (vector === undefined || vector.expectedDeviation !== undefined) continue
    const { stderr, exitCode } = result.actual
    const program = /^([A-Za-z0-9._+-]+)\s/u.exec(vector.script)?.[1]
    // Filesystem remediation lines also start with `pdsh-shell: `; only the
    // `exit=/program=/reason=` shape is a contract trailer.
    const candidates = stderr.split('\n').filter(line => line.startsWith('pdsh-shell: exit='))
    const trailerLines = []
    for (const line of candidates) {
      const trailer = parseShellTrailer(line)
      if (trailer === undefined) {
        errors.push(`vector '${result.name}' produced an unparseable trailer ${JSON.stringify(line)}`)
        continue
      }
      trailerLines.push(line)
      if (trailer.exitCode !== exitCode) errors.push(`vector '${result.name}' trailer exit=${String(trailer.exitCode)} but the command exited ${String(exitCode)}`)
    }
    if (trailerLines.length > 1) errors.push(`vector '${result.name}' carved ${String(trailerLines.length)} trailer lines into one failure`)
    if (exitCode !== 0 && stderr.trim() !== '' && program !== undefined
      && TRAILERED_PROGRAMS.has(program) && trailerLines.length === 0) {
      errors.push(`vector '${result.name}' fails in ${program} with an unlabelled error: ${JSON.stringify(stderr)}`)
    }
    if (exitCode === 127 && !stderr.includes('reason=not-available')) {
      errors.push(`vector '${result.name}' is a 127 without reason=not-available: ${JSON.stringify(stderr)}`)
    }
    if (stderr.includes('reason=not-available') && !stderr.includes(SHELL_MANIFEST_PATH)) {
      errors.push(`vector '${result.name}' is not-available without the manifest hint (${SHELL_MANIFEST_PATH})`)
    }
  }
  return { errors }
}

/**
 * Drive the class-level behaviours the vectors encode, against the production
 * command table.
 * @param {object} [a05Replay] - a `runProbeReplay()` result to reuse; when
 *   omitted the G2-A05 replay is run here.
 * @returns {Promise<{name: string, pass: boolean, detail: string}[]>} checks.
 */
export async function auditTaxonomy(a05Replay) {
  const checks = []
  const record = (name, pass, detail) => { checks.push({ name, pass, detail }) }

  // 1. Unknown program: 127 + one manifest-hint trailer (snapshot lock).
  {
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), ({ shell }) => run(shell, UNKNOWN_PROGRAM))
    const trailer = trailersOf(result.stderr)[0]
    const expected = `pdsh-shell: exit=127 program=${UNKNOWN_PROGRAM} reason=not-available hint=not a Worker program; the capability manifest is ${SHELL_MANIFEST_PATH}`
    record(
      'taxonomy/unknown-program-is-127-with-manifest-hint',
      result.exitCode === 127 && trailer !== undefined && trailer.reason === 'not-available'
        && result.stderr.includes(expected) && result.stdout === '',
      `exit=${String(result.exitCode)} stderr=${JSON.stringify(result.stderr)}`,
    )
    record(
      'taxonomy/unknown-program-trailer-snapshot',
      result.stderr === `bash: ${UNKNOWN_PROGRAM}: command not found\n${expected}\n`,
      JSON.stringify(result.stderr),
    )
  }

  // 2. A known high-frequency gap (`unzip`) gets its own remediation line.
  {
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), ({ shell }) => run(shell, 'unzip archive.zip'))
    const trailer = trailersOf(result.stderr)[0]
    record(
      'taxonomy/unzip-127-names-the-manifest',
      result.exitCode === 127 && trailer?.reason === 'not-available'
        && (trailer?.hint ?? '').includes(SHELL_MANIFEST_PATH) && result.stdout === '',
      `exit=${String(result.exitCode)} stderr=${JSON.stringify(result.stderr)}`,
    )
  }

  // 3. Bare `python` without a toolbox: 127, but the hint names python3/WASI.
  {
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), ({ shell }) => run(shell, 'python -c 1'))
    const trailer = trailersOf(result.stderr)[0]
    record(
      'taxonomy/bare-python-127-names-python3-and-manifest',
      result.exitCode === 127 && trailer?.reason === 'not-available'
        && (trailer?.hint ?? '').includes('python3') && (trailer?.hint ?? '').includes(SHELL_MANIFEST_PATH),
      `exit=${String(result.exitCode)} stderr=${JSON.stringify(result.stderr)}`,
    )
  }

  // 3b. A Worker program that ran and exited is `command-exited`, never
  //     `backend-failed` (G2-FIX-58: `stat` on a missing path used to claim the
  //     execution backend had broken).
  {
    const result = await withShell(
      createWorkerCommands({ git: false, toolbox: false, curl: false }),
      ({ shell }) => run(shell, "stat -c '%n %s' /dsh/workspace/missing.txt"),
    )
    const trailer = trailersOf(result.stderr)[0]
    record(
      'taxonomy/stat-missing-path-is-command-exited',
      result.exitCode === 1 && trailer?.reason === 'command-exited'
        && /^stat: cannot stat '\/dsh\/workspace\/missing\.txt': No such file or directory\n/u.test(result.stderr),
      `exit=${String(result.exitCode)} stderr=${JSON.stringify(result.stderr)}`,
    )
  }

  // 3c. The manifest the not-available hint names exists in the same VFS and
  //     is generated from the live command registry.
  {
    const result = await withShell(
      createWorkerCommands({ git: false, toolbox: false, curl: false }),
      async ({ shell, fs }) => {
        const unknown = await run(shell, UNKNOWN_PROGRAM)
        let manifest
        try {
          manifest = JSON.parse(await fs.readFile(SHELL_MANIFEST_PATH))
        } catch {
          manifest = undefined
        }
        return { unknown, manifest }
      },
    )
    const trailer = trailersOf(result.unknown.stderr)[0]
    const programs = Array.isArray(result.manifest?.programs) ? result.manifest.programs : []
    record(
      'taxonomy/not-available-manifest-referent-exists',
      result.unknown.exitCode === 127 && trailer?.reason === 'not-available'
        && (trailer?.hint ?? '').includes(SHELL_MANIFEST_PATH)
        && result.manifest?.format === 1
        && ['bash', 'stat', 'tar', 'gzip', 'find', 'awk'].every(program => programs.includes(program)),
      JSON.stringify(result),
    )
  }

  // 3d. Only a failure of our own execution layer is `backend-failed`.
  {
    const toolbox = {
      list: () => [{ program: 'python3', aliases: [], description: 'broken dispatcher' }],
      has: program => program === 'python3',
      preopenTable: [],
      async run() {
        throw new Error('WASI dispatch exploded')
      },
    }
    const result = await withShell(
      createWorkerCommands({ git: false, toolbox, curl: false }),
      async ({ shell }) => ({
        crashed: await run(shell, 'python3 x.py'),
        missing: await run(shell, 'stat -c %n nope'),
      }),
    )
    record(
      'taxonomy/injected-exec-failure-is-the-only-backend-failed',
      trailersOf(result.crashed.stderr)[0]?.reason === 'backend-failed'
        && trailersOf(result.missing.stderr)[0]?.reason === 'command-exited',
      `crashed=${JSON.stringify(result.crashed.stderr)} missing=${JSON.stringify(result.missing.stderr)}`,
    )
  }

  // 4. gzip with no backend: exit 1, no stdout, no member on disk, trailer.
  {
    const options = { zlib: null, compressionStream: null, decompressionStream: null }
    const commands = [
      createGzipCommand(options),
      createGunzipCommand(options),
      createZcatCommand(options),
      createTarCommand(options),
    ]
    const result = await withShell(commands, async ({ shell, root }) => {
      const gzip = await run(shell, "printf 'payload\\n' | gzip > out.gz")
      const gunzip = await run(shell, "printf 'not-a-member' | gunzip")
      const tar = await run(shell, 'tar -czf notes.tgz notes')
      return { gzip, gunzip, tar, gzipSize: rootFileSize(root, '/dsh/workspace/out.gz') }
    })
    const trailer = trailersOf(result.gzip.stderr)[0]
    record(
      'taxonomy/gzip-without-backend-fails-loud',
      result.gzip.exitCode === 1 && result.gzip.stdout === '' && trailer?.reason === 'backend-failed'
        && result.gzipSize <= 0,
      `exit=${String(result.gzip.exitCode)} size=${String(result.gzipSize)} stderr=${JSON.stringify(result.gzip.stderr)}`,
    )
    // The exact illegal combination: 0 bytes on stdout with exit 0.
    record(
      'taxonomy/zero-byte-gzip-success-is-illegal',
      !(result.gzip.exitCode === 0 && result.gzip.stdout === '' && result.gzip.stderr === ''),
      `exit=${String(result.gzip.exitCode)} stdout=${JSON.stringify(result.gzip.stdout)}`,
    )
    record(
      'taxonomy/gunzip-without-backend-fails-loud',
      result.gunzip.exitCode === 1 && result.gunzip.stdout === '' && trailersOf(result.gunzip.stderr)[0]?.reason === 'backend-failed',
      `exit=${String(result.gunzip.exitCode)} stderr=${JSON.stringify(result.gunzip.stderr)}`,
    )
    record(
      'taxonomy/tar-gzip-without-backend-fails-loud',
      result.tar.exitCode !== 0 && trailersOf(result.tar.stderr).length === 1,
      `exit=${String(result.tar.exitCode)} stderr=${JSON.stringify(result.tar.stderr)}`,
    )
  }

  // 5. A usage boundary is exit 2 with reason=unsupported-option.
  {
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), async ({ shell }) => {
      await run(shell, "printf 'x\\n' > f.txt")
      return {
        tar: await run(shell, 'tar --bogus-option -cf a.tar f.txt'),
        stat: await run(shell, "stat -c '%Q' f.txt"),
        find: await run(shell, "find . -printf '%q\\n'"),
        awk: await run(shell, 'awk --bogus'),
      }
    })
    for (const [name, check] of Object.entries(result)) {
      const trailer = trailersOf(check.stderr)[0]
      record(
        `taxonomy/${name}-usage-is-exit-2`,
        check.exitCode === 2 && trailer?.reason === 'unsupported-option' && check.stdout === '',
        `exit=${String(check.exitCode)} stderr=${JSON.stringify(check.stderr)}`,
      )
    }
  }

  // 6. A cut stream is incomplete: non-zero + reason=output-truncated.
  {
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), async ({ shell }) => {
      const cut = await run(shell, 'seq 1 2000', { maxOutputBytes: 64 })
      const redirected = await run(shell, 'seq 1 2000 > large.txt; wc -c < large.txt', { maxOutputBytes: 64 })
      const devnull = await run(shell, 'echo ignored > /dev/null; cat /dev/null; echo done')
      return { cut, redirected, devnull }
    })
    record(
      'taxonomy/truncated-stream-is-non-zero-with-trailer',
      result.cut.exitCode === 1 && result.cut.stdoutTruncated
        && trailersOf(result.cut.stderr)[0]?.reason === 'output-truncated',
      `exit=${String(result.cut.exitCode)} stderr=${JSON.stringify(result.cut.stderr)}`,
    )
    record(
      'taxonomy/file-redirection-is-not-counted-against-maxOutputSize',
      result.redirected.exitCode === 0 && result.redirected.stdout === '8893\n' && !result.redirected.stdoutTruncated,
      `exit=${String(result.redirected.exitCode)} stdout=${JSON.stringify(result.redirected.stdout)}`,
    )
    record(
      'taxonomy/dev-null-redirection-works',
      result.devnull.exitCode === 0 && result.devnull.stdout === 'done\n' && result.devnull.stderr === '',
      `exit=${String(result.devnull.exitCode)} stderr=${JSON.stringify(result.devnull.stderr)}`,
    )
  }

  // 6b. `maxOutputSize` is a memory bound on one result, not the visible
  //     per-stream cap: a legal 17 MiB file may pass through a pipeline stage
  //     without spending the caller's maxOutputBytes, and `od -N` must format
  //     only the requested window instead of the whole operand.
  {
    const big = Buffer.alloc(17 * 1024 * 1024, 0x41)
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), async ({ shell, fs }) => {
      await fs.writeFile('/dsh/workspace/big', big)
      return {
        piped: await run(shell, 'cat big | wc -c', { maxOutputBytes: 1024 }),
        dump: await run(shell, 'od -An -tx1 -N4 big', { maxOutputBytes: 1024 }),
      }
    })
    record(
      'taxonomy/pipeline-throughput-is-not-final-output',
      result.piped.exitCode === 0 && result.piped.stdout === `${String(big.byteLength)}\n`
        && !result.piped.stdoutTruncated && result.piped.stderr === '',
      `exit=${String(result.piped.exitCode)} stdout=${JSON.stringify(result.piped.stdout)} stderr=${JSON.stringify(result.piped.stderr)}`,
    )
    record(
      'taxonomy/od-N-bounds-format-work',
      result.dump.exitCode === 0 && result.dump.stdout === ' 41 41 41 41\n'
        && !result.dump.stdoutTruncated && result.dump.stderr === '',
      `exit=${String(result.dump.exitCode)} stdout=${JSON.stringify(result.dump.stdout)} stderr=${JSON.stringify(result.dump.stderr)}`,
    )
  }

  // 7. curl failure semantics: usage is 2, a denied route is a network failure.
  {
    const deny = async () => new Response('forbidden\n', { status: 403 })
    const options = { fetch: deny, origin: 'http://127.0.0.1:9', token: 'contract' }
    const result = await withShell(createWorkerCommands({ git: false, toolbox: false, curl: options }), async ({ shell }) => ({
      denied: await run(shell, 'curl https://blocked.example/x'),
      usage: await run(shell, 'curl --cert key.pem https://worker.example.com'),
    }))
    record(
      'taxonomy/curl-denied-host-is-network-denied',
      result.denied.exitCode === 22 && trailersOf(result.denied.stderr)[0]?.reason === 'network-denied',
      `exit=${String(result.denied.exitCode)} stderr=${JSON.stringify(result.denied.stderr)}`,
    )
    record(
      'taxonomy/curl-unsupported-option-is-exit-2',
      result.usage.exitCode === 2 && trailersOf(result.usage.stderr)[0]?.reason === 'unsupported-option',
      `exit=${String(result.usage.exitCode)} stderr=${JSON.stringify(result.usage.stderr)}`,
    )
  }

  // 8. A toolbox program is registered under the declared `python` alias.
  {
    const requests = []
    const toolbox = {
      list: () => [{ program: 'python3', aliases: [], description: 'stub interpreter' }],
      has: program => program === 'python3',
      preopenTable: [{ guestPath: '/workspace', hostPath: '/dsh/workspace' }],
      async run(request) {
        requests.push(request)
        request.onStdout?.(new TextEncoder().encode('alias-ok\n'))
        return { program: request.program, exitCode: 0, cancelled: false, memoryExceeded: false, memoryPeakBytes: 0, stdoutBytes: 9, stderrBytes: 0 }
      },
    }
    const result = await withShell(createWorkerCommands({ git: false, toolbox, curl: false }), ({ shell }) => run(shell, "python -c 'print(1)'"))
    record(
      'taxonomy/python-alias-dispatches-python3',
      result.exitCode === 0 && result.stdout === 'alias-ok\n' && requests[0]?.program === 'python3',
      `exit=${String(result.exitCode)} program=${String(requests[0]?.program)} stdout=${JSON.stringify(result.stdout)}`,
    )
  }

  // 9. The G2-A05 probe sequence: every answer is definitive. A 127 without
  //    the not-available trailer, or an exit 0 with the expected bytes missing,
  //    forced the model to probe again; the metric counts those answers.
  {
    const steps = [
      { script: 'tar --version', expectsOutput: true },
      { script: "printf 'probe\\n' | gzip > probe.gz; test -s probe.gz", expectsOutput: false },
      { script: 'gunzip -c probe.gz', expectsOutput: true },
      { script: 'realpath -m probe.gz', expectsOutput: true },
      { script: "python3 -c 'print(1)'", expectsOutput: true },
      { script: 'unzip -l probe.gz', expectsOutput: false },
    ]
    const ambiguous = []
    await withShell(createWorkerCommands({ git: false, toolbox: false, curl: false }), async ({ shell }) => {
      for (const step of steps) {
        const result = await run(shell, step.script)
        const labelled = trailersOf(result.stderr).length > 0
        if (result.exitCode === 127 && !labelled) ambiguous.push({ step: step.script, why: '127 without a trailer' })
        if (step.expectsOutput && result.exitCode === 0 && result.stdout === '') {
          ambiguous.push({ step: step.script, why: 'exit 0 with empty output' })
        }
        if (result.exitCode !== 0 && result.stderr.trim() !== '' && !labelled && /^(?:tar|gzip|gunzip|zcat|realpath|unzip|python3?)\b/u.test(step.script)) {
          ambiguous.push({ step: step.script, why: 'error without a trailer' })
        }
      }
    })
    record(
      'taxonomy/a05-probe-sequence-has-no-ambiguous-answer',
      ambiguous.length === 0,
      JSON.stringify(ambiguous),
    )
  }

  // 10. A silent toolbox non-zero gets a trailer; a guest that explained
  //    itself keeps its stderr bytes.
  {
    let call = 0
    const toolbox = {
      list: () => [{ program: 'python3', aliases: ['python'], description: 'stub interpreter' }],
      has: program => program === 'python3' || program === 'python',
      preopenTable: [],
      async run(request) {
        call += 1
        if (call === 1) return { program: request.program, exitCode: 1, cancelled: false, memoryExceeded: false, memoryPeakBytes: 0, stdoutBytes: 0, stderrBytes: 0 }
        request.onStderr?.(new TextEncoder().encode('Traceback: boom\n'))
        return { program: request.program, exitCode: 1, cancelled: false, memoryExceeded: false, memoryPeakBytes: 0, stdoutBytes: 0, stderrBytes: 15 }
      },
    }
    const result = await withShell(createWorkerCommands({ git: false, toolbox, curl: false }), async ({ shell }) => ({
      silent: await run(shell, 'python3 silent.py'),
      explained: await run(shell, 'python3 explained.py'),
    }))
    record(
      'taxonomy/silent-toolbox-failure-gets-trailer',
      result.silent.exitCode === 1 && trailersOf(result.silent.stderr)[0]?.reason === 'command-exited',
      `stderr=${JSON.stringify(result.silent.stderr)}`,
    )
    record(
      'taxonomy/explained-toolbox-failure-keeps-its-own-stderr',
      result.explained.exitCode === 1 && result.explained.stderr === 'Traceback: boom\n',
      `stderr=${JSON.stringify(result.explained.stderr)}`,
    )
  }

  // 11. The G2-A05 probe budget: the recorded pre-fix run against the
  //     production surface. Every capability question must have a definitive
  //     answer on the first request, and the request count must at least
  //     halve the 26 the first real-model batch recorded.
  {
    const replay = a05Replay ?? await runProbeReplay()
    const verdict = compareProbeBudget(replay)
    const failures = verdict.checks.filter(check => !check.pass).map(check => `${check.name}: ${check.detail}`)
    record(
      'taxonomy/a05-probe-budget-significant-drop',
      verdict.pass,
      `baseline=${String(replay.baseline.modelRequests)} fixed=${String(replay.counts.requests)} `
        + `ambiguous=${String(replay.counts.ambiguous)} drop=${String(verdict.dropPercent)}%`
        + (failures.length === 0 ? '' : `; ${failures.join('; ')}`),
    )
  }

  return checks
}

/**
 * Run the whole contract.
 * @param {{goldenFile?: string, manifestFile?: string, quiet?: boolean}} options - files and verbosity.
 * @returns {Promise<{status: number, report: object}>} status and details.
 */
export async function runContract(options = {}) {
  const goldenFile = options.goldenFile ?? DEFAULT_GOLDEN
  let vectors
  try {
    const path = isAbsolute(goldenFile) ? goldenFile : resolve(goldenFile)
    vectors = parseGolden(readFileSync(path, 'utf8'))
  } catch (error) {
    return {
      status: 2,
      report: { errors: [error instanceof Error ? error.message : String(error)], vectors: 0, deviations: [], checks: [], golden: undefined },
    }
  }
  const corpus = auditCorpus(vectors)
  const golden = await runGoldenVectors(vectors)
  const a05Replay = await runProbeReplay()
  const a05Verdict = compareProbeBudget(a05Replay)
  const checks = await auditTaxonomy(a05Replay)
  const errors = [...corpus.errors, ...auditTrailers(vectors, golden.results).errors]
  for (const result of golden.results) {
    if (!result.pass) {
      errors.push(`vector '${result.name}': ${result.problems.map(problem => `${problem.field} expected ${JSON.stringify(problem.expected)}, got ${JSON.stringify(problem.actual)}`).join('; ')}`)
    }
  }
  for (const check of checks) if (!check.pass) errors.push(`${check.name}: ${check.detail}`)
  if (options.manifestFile !== undefined) {
    mkdirSync(dirname(resolve(options.manifestFile)), { recursive: true })
    writeFileSync(resolve(options.manifestFile), `${JSON.stringify({
      vectors: vectors.length,
      deviations: corpus.deviations,
      upstreamGaps: corpus.deviations.map(deviation => deviation.upstreamGap),
    }, null, 2)}\n`)
  }
  return {
    status: errors.length === 0 ? 0 : 1,
    report: {
      goldenFile,
      vectors: vectors.length,
      families: Object.fromEntries(corpus.families),
      failures: corpus.failures,
      deviations: corpus.deviations,
      golden: { total: golden.total, passed: golden.passed, failed: golden.failed },
      a05: {
        baseline: A05_BASELINE.modelRequests,
        fixed: a05Replay.counts.requests,
        ambiguous: a05Replay.counts.ambiguous,
        dropPercent: a05Verdict.dropPercent,
        deliverable: a05Replay.deliverable.complete,
      },
      checks,
      errors,
    },
  }
}

/** Print a human-readable summary. */
function describe(report) {
  const lines = []
  lines.push(`contract: ${String(report.golden.passed)}/${String(report.golden.total)} golden vectors passed (${String(report.vectors)} committed)`)
  lines.push(`contract: families ${Object.entries(report.families).map(([name, count]) => `${name}=${String(count)}`).join(' ')}`)
  lines.push(`contract: ${String(report.failures)} non-zero-exit vectors, ${String(report.deviations.length)} expected deviations`)
  if (report.a05 !== undefined) {
    lines.push(`contract: A05 probe requests ${String(report.a05.baseline)} -> ${String(report.a05.fixed)} (${String(report.a05.dropPercent)}% fewer, ${String(report.a05.ambiguous)} ambiguous, deliverable ${report.a05.deliverable ? 'complete' : 'incomplete'})`)
  }
  for (const deviation of report.deviations) {
    lines.push(`contract: deviation ${deviation.name} -> ${deviation.upstreamGap}${deviation.note === undefined ? '' : ` (${deviation.note})`}`)
  }
  for (const check of report.checks) lines.push(`${check.pass ? 'ok  ' : 'FAIL'} ${check.name}${check.pass ? '' : ` — ${check.detail}`}`)
  if (report.errors.length > 0) {
    for (const error of report.errors) lines.push(`FAIL ${error}`)
  }
  return lines.join('\n')
}

/**
 * CLI entry point.
 * @param {string[]} argv - arguments after the script name.
 * @returns {Promise<number>} process exit status.
 */
export async function main(argv) {
  let goldenFile = DEFAULT_GOLDEN
  let manifestFile
  let quiet = false
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      process.stdout.write('usage: node tools/shell-corpus/contract.mjs [--golden FILE] [--manifest FILE] [--quiet]\n')
      return 0
    }
    if (argument === '--quiet') { quiet = true; continue }
    if (argument === '--golden' || argument === '--manifest') {
      const value = argv[index + 1]
      if (value === undefined) {
        process.stderr.write(`contract: ${argument} needs a file\n`)
        return 2
      }
      if (argument === '--golden') goldenFile = value
      else manifestFile = value
      index += 1
      continue
    }
    process.stderr.write(`contract: unknown argument '${argument}'\n`)
    return 2
  }
  const { status, report } = await runContract({ goldenFile, manifestFile, quiet })
  if (report.vectors === 0 && report.checks.length === 0) {
    process.stderr.write(`contract: ${report.errors[0] ?? 'cannot read the corpus'}\n`)
    return status
  }
  if (!quiet || status !== 0) process.stdout.write(`${describe(report)}\n`)
  process.stdout.write(`contract: ${status === 0 ? 'PASS' : 'FAIL'}\n`)
  return status
}

const invokedDirectly = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(resolve(process.argv[1])).href

if (invokedDirectly) {
  main(process.argv.slice(2)).then((status) => {
    process.exitCode = status
  }).catch((error) => {
    process.stderr.write(`contract: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`)
    process.exitCode = 2
  })
}
