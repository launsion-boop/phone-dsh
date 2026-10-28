// SPDX-License-Identifier: MIT
/**
 * G2-FIX-100 regression for the shell-ext write surface: the `EFBIG` a
 * command sees and the `pdsh-shell:` remediation trailer both name the
 * single-file limit that is actually enforced.
 *
 * The defect: the adapter already formatted its byte count from the
 * configured budget, but the shell trailer still carried the pre-ENG-07
 * `... limited to 15 MiB` literal, so a default 64 MiB refusal was followed by
 * a hint naming a 15 MiB budget. Both numbers now come from the shared
 * `formatByteLimit`/budget owner in the WASI toolbox's `src/limits.ts`.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, truncateSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { defineCommand } from 'just-bash/browser'
import {
  DEFAULT_SINGLE_FILE_LIMIT,
  MAX_SINGLE_FILE_LIMIT,
  MEBIBYTE,
  MIN_SINGLE_FILE_LIMIT,
} from '../../wasi-toolbox/src/limits.ts'
import { VfsFileSystem } from './filesystem.ts'
import { WorkerShell, parseShellTrailer } from './index.ts'

const CWD = '/dsh/workspace'

function virtualRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-limit-diag-'))
  for (const directory of [CWD, '/dsh/home', '/dsh/tmp']) mkdirSync(join(root, directory), { recursive: true })
  return root
}

test('G2-FIX-100: a write refusal names the byte count and MiB label of the configured limit', async (t) => {
  const limits = [MIN_SINGLE_FILE_LIMIT, DEFAULT_SINGLE_FILE_LIMIT, MAX_SINGLE_FILE_LIMIT]
  for (const limit of limits) {
    const root = virtualRoot()
    t.after(() => rmSync(root, { recursive: true, force: true }))
    const fs = new VfsFileSystem({ root, workerPaths: true, maxFileSize: limit })
    const target = join(root, 'dsh/workspace/probe.bin')
    // A sparse file of exactly the budget: the append check stats it, so the
    // case needs no multi-megabyte buffer.
    writeFileSync(target, new Uint8Array(0))
    truncateSync(target, limit)
    const mib = limit / MEBIBYTE
    await assert.rejects(
      fs.appendFile('/dsh/workspace/probe.bin', 'x'),
      (error: unknown) => {
        const message = (error as Error).message
        assert.equal((error as { code?: string }).code, 'EFBIG')
        assert.equal(
          message.includes(`${String(limit)} bytes (${String(mib)} MiB)`),
          true,
          `limit ${String(limit)} must render as "${String(limit)} bytes (${String(mib)} MiB)": ${message}`,
        )
        if (limit !== 15 * MEBIBYTE) {
          assert.equal(message.includes('15 MiB'), false, message)
        }
        return true
      },
    )
  }
})

test('G2-FIX-100: the limit-refused trailer hint is derived from the enforced budget', async (t) => {
  const root = virtualRoot()
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const limit = 1 * MEBIBYTE
  const fs = new VfsFileSystem({ root, workerPaths: true, maxFileSize: limit })
  const writebig = defineCommand('writebig', async (_args, ctx) => {
    await ctx.fs.writeFile(ctx.fs.resolvePath(ctx.cwd, 'big.bin'), 'x'.repeat(limit + 1))
    return { stdout: '', stderr: '', exitCode: 0 }
  })
  const shell = new WorkerShell({ fs, commands: [writebig] })
  const result = await shell.run(['bash', '-c', 'writebig'], { cwd: CWD })
  assert.notEqual(result.exitCode, 0)
  assert.match(result.stderr, /File too large/u)
  const trailer = parseShellTrailer(result.stderr.trimEnd().split('\n').at(-1) as string)
  assert.equal(trailer?.reason, 'limit-refused')
  assert.equal(trailer?.program, 'writebig')
  assert.equal(trailer?.hint, 'a single VFS file is limited to 1 MiB (PLAN D4)')
})
