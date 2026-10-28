// SPDX-License-Identifier: MIT
/**
 * Gate bootstrap: the repository does not track `node_modules`, so a clean
 * checkout cannot run `tsc` or `node --test` until the pinned devDependencies
 * from `plugins/package-lock.json` are installed. The `pretypecheck` and
 * `pretest` hooks run this file; when the dependencies are already present it
 * exits immediately, otherwise it runs `npm ci` once in `plugins`.
 *
 * This installs only versions already pinned by the lockfile; it never edits
 * `package.json` or `package-lock.json`.
 */
import { existsSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const packageRoot = fileURLToPath(new URL('../../', import.meta.url))
const required = [
  '../../node_modules/typescript/package.json',
  '../../node_modules/@types/node/package.json',
]

if (required.some(entry => !existsSync(fileURLToPath(new URL(entry, import.meta.url))))) {
  process.stderr.write('wasi-toolbox: installing pinned plugins devDependencies with npm ci\n')
  const result = spawnSync('npm', ['ci', '--no-audit', '--no-fund'], {
    cwd: packageRoot,
    stdio: 'inherit',
  })
  if (result.error !== undefined) {
    process.stderr.write(`wasi-toolbox: npm ci failed: ${result.error.message}\n`)
    process.exit(1)
  }
  process.exit(result.status ?? 1)
}
