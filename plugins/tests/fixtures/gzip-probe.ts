// SPDX-License-Identifier: MIT
/**
 * Child-process probe for `tests/shell-ext-gzip.test.ts`.
 *
 * The parent runs this file with `node --import zlib-unavailable-register.mjs`
 * so `node:zlib` is the browser Worker's refusing stub, exactly the host that
 * exposed G2-A05. The probe drives the production command table through
 * `WorkerShell` and prints one JSON line: the command names, the gzip result,
 * the bytes it wrote, and the gunzip/`gzip -d` roundtrips.
 *
 * `PDSH_GZIP_PROBE_DISABLE_WEB=1` additionally removes the Web Compression
 * Streams, which is the "every backend unavailable" host.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createWorkerCommands, VfsFileSystem, WorkerShell } from '../../shell-ext/src/index.ts'

const root = mkdtempSync(join(tmpdir(), 'pdsh-gzip-probe-'))

try {
  if (process.env.PDSH_GZIP_PROBE_DISABLE_WEB === '1') {
    for (const name of ['CompressionStream', 'DecompressionStream']) {
      Object.defineProperty(globalThis, name, { value: undefined, configurable: true, writable: true })
    }
  }
  const fs = new VfsFileSystem({ root })
  await fs.mkdir('/dsh/workspace', { recursive: true })
  await fs.mkdir('/dsh/tmp', { recursive: true })
  const commands = createWorkerCommands({ git: false, curl: false, toolbox: false })
  const shell = new WorkerShell({ fs, commands })
  const run = async (script: string) => await shell.run(['bash', '-c', script], { cwd: '/dsh/workspace' })

  // The acceptance command: stdin -> gzip -> a file, then both decompression
  // spellings against that file.
  const gzip = await run("printf 'hello\\n' | gzip > out.gz")
  let gzipBytes: number[] = []
  try {
    gzipBytes = [...await fs.readFileBuffer('/dsh/workspace/out.gz')]
  } catch { /* the failing host may leave no file at all */ }
  const gunzip = await run('gunzip < out.gz')
  const gzipD = await run('gzip -dc out.gz')
  // No redirection: a failing gzip must not put bytes on stdout either.
  const bare = await run("printf 'hello\\n' | gzip")
  // In-place file mode: compress with -k, remove the source, expand with -k.
  const fileMode = await run("printf 'file data\\n' > data.txt; gzip -k data.txt; rm data.txt; gunzip -k data.txt.gz; cat data.txt")
  // Binary bytes must roundtrip too: the shell pipe is byte-shaped, not text.
  const binaryInput = [0x00, 0x01, 0x02, 0x7f, 0x80, 0xff]
  await fs.writeFile('/dsh/workspace/bin.dat', new Uint8Array(binaryInput))
  const binary = await run('gzip -k bin.dat; rm bin.dat; gunzip -k bin.dat.gz')
  let binaryBytes: number[] = []
  try {
    binaryBytes = [...await fs.readFileBuffer('/dsh/workspace/bin.dat')]
  } catch { /* reported by the probe assertions */ }
  // A non-gzip stdin is an error, never an empty success.
  const invalid = await run("printf 'not a gzip member' | gunzip")

  console.log(JSON.stringify({
    names: commands.map(command => command.name),
    gzip,
    gzipBytes,
    gunzip,
    gzipD,
    bare,
    fileMode,
    binary,
    binaryInput,
    binaryBytes,
    invalid,
  }))
} finally {
  rmSync(root, { recursive: true, force: true })
}
