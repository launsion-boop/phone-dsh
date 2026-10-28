// SPDX-License-Identifier: MIT
/**
 * Compression capability probe for the CPython wasm32-wasi build.
 *
 * The phone WASI toolbox promises the standard library a Python program would
 * reach for when it handles an archive: `zlib`, `_bz2` and `_lzma` are
 * statically linked into `python.wasm`, and `tarfile.open(name, "w:gz")` plus a
 * read-back roundtrip work on the VFS. That capability is a property of the
 * produced interpreter, not of the source tree, so it is measured by running
 * the interpreter: `build.sh` runs {@link COMPRESSION_PROBE_PROGRAM} against
 * every artifact it produces (and against a reused artifact in `--check`), and
 * `compression.test.ts` runs the import and tarfile programs through the real
 * Worker composition.
 *
 * One module owns the probe programs and their markers so the build script and
 * the tests cannot drift apart: a missing capability fails in `build.sh`
 * before an image is packed and in `npm test` before a Worker ships.
 * @module @phone-dsh/dsh-wasi-toolbox/python/compression-probe
 */

/** Marker printed by the `import zlib, bz2, lzma` program. */
export const COMPRESSION_IMPORT_MARKER = 'PDSH_PYTHON_COMPRESSION_IMPORTS_OK'

/** Marker printed after the `tarfile` `w:gz` write/read roundtrip. */
export const TARFILE_GZIP_MARKER = 'PDSH_PYTHON_TARFILE_GZIP_OK'

/** Marker printed after the direct zlib/bz2/lzma roundtrips. */
export const COMPRESSION_ROUNDTRIP_MARKER = 'PDSH_PYTHON_COMPRESSION_OK'

/** Modules the produced interpreter must import; the build fails without them. */
export const COMPRESSION_PROBE_MODULES = ['zlib', 'bz2', 'lzma'] as const

/** Guest path of the gzip archive the probe writes and reads back. */
export const COMPRESSION_PROBE_ARCHIVE = '/tmp/pdsh-compression-probe.tar.gz'

/** Repetitions of the probe payload; the Python snippets use the same factor. */
export const COMPRESSION_PROBE_PAYLOAD_REPEAT = 64

/** Payload the probe stores in the archive and in each compression roundtrip. */
export const COMPRESSION_PROBE_PAYLOAD = 'xl compression probe\n'.repeat(
  COMPRESSION_PROBE_PAYLOAD_REPEAT,
)

/** The exact bytes of the probe payload as they appear inside the archive. */
export const COMPRESSION_PROBE_PAYLOAD_BYTES = new TextEncoder().encode(
  COMPRESSION_PROBE_PAYLOAD,
)

// The Python snippets below run inside the guest interpreter, so their output
// is line-oriented: one marker line followed by one canonical JSON object. The
// payload and archive literals are shared with the snippets rather than
// repeated by hand.
const payloadLiteral = "b'xl compression probe\\n' * 64"
const archiveLiteral = JSON.stringify(COMPRESSION_PROBE_ARCHIVE)

/**
 * `python3 -c` program that imports the three compression modules.
 *
 * This is the exact shape the G2-A05 transcript failed with
 * `ModuleNotFoundError: No module named 'zlib'` / `'_bz2'` / `'_lzma'`.
 */
export const COMPRESSION_IMPORT_PROGRAM = String.raw`import zlib, bz2, lzma
print('${COMPRESSION_IMPORT_MARKER}', zlib.ZLIB_VERSION, zlib.__name__, bz2.__name__, lzma.__name__)
`

/**
 * `python3 -c` program that writes one file into a `w:gz` tar archive and reads
 * it back from the same archive, exercising `tarfile` + `gzip` + `zlib` on the
 * VFS exactly as a Python script does.
 *
 * It deliberately does not import `zlib`, `bz2` or `lzma` itself: on a build
 * without the compression modules it must fail inside `tarfile.gzopen`, which
 * is the second half of the reported defect.
 */
export const TARFILE_GZIP_PROGRAM = String.raw`import io, json, tarfile

payload = ${payloadLiteral}
archive = ${archiveLiteral}
with tarfile.open(archive, 'w:gz') as tar:
    info = tarfile.TarInfo('probe.txt')
    info.size = len(payload)
    info.mtime = 0
    info.mode = 0o644
    tar.addfile(info, io.BytesIO(payload))
with tarfile.open(archive, 'r:gz') as tar:
    member = tar.getmember('probe.txt')
    extracted = tar.extractfile(member).read()
if extracted != payload:
    raise SystemExit('tarfile w:gz roundtrip mismatch')
with open(archive, 'rb') as handle:
    magic = handle.read(2).hex()
print('${TARFILE_GZIP_MARKER} ' + json.dumps({'bytes': len(payload), 'magic': magic}, sort_keys=True))
`

/**
 * `python3 -c` program that compresses the payload with each module and
 * decompresses it again, then prints the versions it observed.
 */
export const COMPRESSION_ROUNDTRIP_PROGRAM = String.raw`import gzip, json, sys
import bz2, lzma, zlib

payload = ${payloadLiteral}
for name, module in (('zlib', zlib), ('bz2', bz2), ('lzma', lzma)):
    if module.decompress(module.compress(payload)) != payload:
        raise SystemExit('compression roundtrip mismatch: ' + name)
if gzip.decompress(gzip.compress(payload)) != payload:
    raise SystemExit('compression roundtrip mismatch: gzip')
report = {
    'pythonVersion': sys.version.split()[0],
    'zlib': zlib.ZLIB_VERSION,
    'zlibRuntime': zlib.ZLIB_RUNTIME_VERSION,
    'bz2': True,
    'lzma': True,
    'gzipModule': getattr(gzip, '__file__', ''),
}
print('${COMPRESSION_ROUNDTRIP_MARKER} ' + json.dumps(report, sort_keys=True))
`

/**
 * The complete build probe: import, `tarfile` `w:gz` roundtrip, then each
 * module's own roundtrip. `build.sh` runs this against every produced runtime
 * and refuses to publish an artifact that does not print all three markers.
 */
export const COMPRESSION_PROBE_PROGRAM = [
  COMPRESSION_IMPORT_PROGRAM,
  TARFILE_GZIP_PROGRAM,
  COMPRESSION_ROUNDTRIP_PROGRAM,
].join('\n')

/** What the import program prints after its marker. */
export interface PythonCompressionImports {
  readonly modules: readonly string[]
  readonly zlibVersion: string
}

/** What the `tarfile` program prints after its marker. */
export interface PythonTarfileReport {
  /** Bytes of the member the program wrote and read back. */
  readonly bytes: number
  /** First two bytes of the produced file, hex; `1f8b` for a gzip stream. */
  readonly magic: string
}

/** What the roundtrip program prints after its marker. */
export interface PythonCompressionReport {
  readonly pythonVersion: string
  readonly zlib: string
  readonly zlibRuntime: string
  readonly bz2: boolean
  readonly lzma: boolean
  readonly gzipModule: string
}

/**
 * Parse the JSON object a program printed after `marker`.
 * @param stdout - captured standard output of the interpreter.
 * @param marker - marker that starts the line.
 * @returns the parsed object, or undefined when the marker line is absent.
 */
export function parseMarkedJson(stdout: string, marker: string): Record<string, unknown> | undefined {
  const prefix = `${marker} `
  for (const line of stdout.split('\n')) {
    if (!line.startsWith(prefix)) continue
    try {
      const parsed: unknown = JSON.parse(line.slice(prefix.length))
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>
      }
      return undefined
    } catch {
      return undefined
    }
  }
  return undefined
}

/**
 * Parse the import program's marker line.
 * @param stdout - captured standard output of the interpreter.
 * @returns the reported module names and zlib version, or undefined.
 */
export function parseCompressionImports(stdout: string): PythonCompressionImports | undefined {
  const prefix = `${COMPRESSION_IMPORT_MARKER} `
  for (const line of stdout.split('\n')) {
    if (!line.startsWith(prefix)) continue
    const fields = line.slice(prefix.length).trim().split(/\s+/)
    if (fields.length < 4) return undefined
    return { zlibVersion: fields[0] as string, modules: fields.slice(1) }
  }
  return undefined
}

/**
 * Parse the `tarfile` program's marker line.
 * @param stdout - captured standard output of the interpreter.
 * @returns the archive size and magic, or undefined.
 */
export function parseTarfileReport(stdout: string): PythonTarfileReport | undefined {
  const parsed = parseMarkedJson(stdout, TARFILE_GZIP_MARKER)
  if (parsed === undefined) return undefined
  if (typeof parsed.bytes !== 'number' || typeof parsed.magic !== 'string') return undefined
  return { bytes: parsed.bytes, magic: parsed.magic }
}

/**
 * Parse the roundtrip program's marker line.
 * @param stdout - captured standard output of the interpreter.
 * @returns the compression report, or undefined.
 */
export function parseCompressionReport(stdout: string): PythonCompressionReport | undefined {
  const parsed = parseMarkedJson(stdout, COMPRESSION_ROUNDTRIP_MARKER)
  if (parsed === undefined) return undefined
  if (
    typeof parsed.pythonVersion !== 'string'
    || typeof parsed.zlib !== 'string'
    || typeof parsed.zlibRuntime !== 'string'
    || typeof parsed.bz2 !== 'boolean'
    || typeof parsed.lzma !== 'boolean'
    || typeof parsed.gzipModule !== 'string'
  ) {
    return undefined
  }
  return {
    pythonVersion: parsed.pythonVersion,
    zlib: parsed.zlib,
    zlibRuntime: parsed.zlibRuntime,
    bz2: parsed.bz2,
    lzma: parsed.lzma,
    gzipModule: parsed.gzipModule,
  }
}

/**
 * List every capability the probe output fails to prove.
 *
 * An empty list is the acceptance condition: all three compression modules
 * imported and roundtripped, `tarfile` wrote and read a `w:gz` archive, and the
 * pure-Python wrappers were served by the interpreter itself.
 * @param stdout - captured standard output of the interpreter.
 * @returns one sentence per missing capability; empty when the probe passed.
 */
export function compressionProbeProblems(stdout: string): readonly string[] {
  const problems: string[] = []
  const imports = parseCompressionImports(stdout)
  if (imports === undefined) {
    problems.push(`the interpreter did not report ${COMPRESSION_IMPORT_MARKER}`)
  } else {
    for (const name of COMPRESSION_PROBE_MODULES) {
      if (!imports.modules.includes(name)) problems.push(`import ${name} did not run`)
    }
    if (imports.zlibVersion === '') problems.push('zlib reported an empty version')
  }
  const tarfile = parseTarfileReport(stdout)
  if (tarfile === undefined) {
    problems.push(`tarfile w:gz did not report ${TARFILE_GZIP_MARKER}`)
  } else {
    if (tarfile.bytes !== COMPRESSION_PROBE_PAYLOAD_BYTES.byteLength) {
      problems.push(`tarfile w:gz reported ${tarfile.bytes} bytes, expected ${COMPRESSION_PROBE_PAYLOAD_BYTES.byteLength}`)
    }
    if (tarfile.magic !== '1f8b') problems.push(`tarfile w:gz produced magic ${tarfile.magic}, expected 1f8b`)
  }
  const report = parseCompressionReport(stdout)
  if (report === undefined) {
    problems.push(`the interpreter did not report ${COMPRESSION_ROUNDTRIP_MARKER}`)
  } else {
    if (!/^3\.13\./.test(report.pythonVersion)) {
      problems.push(`python version ${report.pythonVersion} is not 3.13.x`)
    }
    if (report.zlib === '' || report.zlibRuntime === '') problems.push('zlib versions are empty')
    if (!report.bz2) problems.push('bz2 did not roundtrip')
    if (!report.lzma) problems.push('lzma did not roundtrip')
    if (!report.gzipModule.includes('python313.zip')) {
      problems.push('gzip.py was not served from the zipped standard library')
    }
  }
  return problems
}
