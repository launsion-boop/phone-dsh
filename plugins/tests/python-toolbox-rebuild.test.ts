// SPDX-License-Identifier: MIT
// G2-FIX-54 regression: python3's file view must follow the live host VFS on
// every Worker (re)construction, not only on the cold boot.
//
// The defect: after `park_resume` (and the same rebuild shape for
// `planned_restart` / `worker_kill` / `webcontent_kill`) the rebuilt Worker's
// `python3` lost the workspace view while `bash` kept it — `os.getcwd()` was
// `/`, `os.path.exists('/dsh/workspace/main.py')` was False and
// `os.listdir('/dsh')` raised, yet the shell at the same moment listed
// `/dsh/workspace` and the image's `python.wasm`. The cold boot wired the WASI
// toolbox, the rebuild path did not: the toolbox was published against a host
// VFS/tool-worker channel that the rebuilt Worker could not serve.
//
// These tests boot the real Worker entry, the real python toolbox, the real
// tool worker and the real shell over one host VFS (image + workspace overlay):
//   1. cold boot in a cross-origin isolated Worker (the SAB VFS channel);
//   2. park teardown (`handle.stop()`) and the rebuilt boot in the same module
//      and global context, without the SAB channel;
//   3. the same rebuilt boot in a fresh context (a new process).
// Each boot must give `python3` the same cwd, absolute `/dsh` read, relative
// listing and directory listing the shell sees.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { after, test } from 'node:test'
import {
  assertFileView,
  bootAndProbe,
  REBUILT_WORKSPACE_OVERLAY,
  WORKSPACE_OVERLAY,
} from './fixtures/python-rebuild-harness.ts'
import type { FileView } from './fixtures/python-rebuild-harness.ts'
import { setWorkerToolbox } from '../wasi-toolbox/src/index.ts'

after(() => {
  setWorkerToolbox(undefined)
})

const COLD_ENTRIES = ['data.txt', 'exports', 'main.py']
const REBUILT_ENTRIES = [...COLD_ENTRIES, 'fresh.txt'].sort()

test('python3 file view survives a park teardown and the rebuilt boot (same global context)', {
  timeout: 120_000,
}, async () => {
  // Cold boot: the Worker the first page load creates. A cross-origin isolated
  // context gives the tool worker the SharedArrayBuffer VFS channel.
  const cold = await bootAndProbe({ crossOriginIsolated: true, workspace: WORKSPACE_OVERLAY })
  try {
    assertFileView(cold.view, COLD_ENTRIES)
  } finally {
    await cold.dispose()
  }

  // Park teardown then the resume rebuild: the new Worker comes back without
  // the synchronous channel and with the rebuilt workspace overlay. Its
  // python3 must still see exactly what the new bash sees.
  const rebuilt = await bootAndProbe({ crossOriginIsolated: false, workspace: REBUILT_WORKSPACE_OVERLAY })
  try {
    assertFileView(rebuilt.view, REBUILT_ENTRIES)
  } finally {
    await rebuilt.dispose()
  }
})

test('the rebuilt boot without the SAB channel still serves the live VFS (injected backend)', {
  timeout: 120_000,
}, async () => {
  // The production cold boot: the host VFS's promise face is the backend, so
  // the first boot has the blocking channel and the guest sees the tree.
  const cold = await bootAndProbe({
    crossOriginIsolated: true,
    workspace: WORKSPACE_OVERLAY,
    backend: 'injected',
  })
  try {
    assertFileView(cold.view, COLD_ENTRIES)
  } finally {
    await cold.dispose()
  }

  // The rebuilt Worker keeps the same backend binding but comes back without a
  // SharedArrayBuffer channel. Before G2-FIX-54 this published a python3 whose
  // every path resolved against an empty `/` (cwd `/`, /dsh invisible) while
  // bash read the tree.
  const rebuilt = await bootAndProbe({
    crossOriginIsolated: false,
    workspace: REBUILT_WORKSPACE_OVERLAY,
    backend: 'injected',
  })
  try {
    assertFileView(rebuilt.view, REBUILT_ENTRIES)
  } finally {
    await rebuilt.dispose()
  }
})

test('the rebuilt snapshot view recaptures a bash write before the next python3 run', {
  timeout: 120_000,
}, async () => {
  // The no-SAB fallback serves a local snapshot. It must follow the live VFS
  // at every dispatch: a file `bash` writes after the boot still has to be
  // visible to the next python3 run, and a bash edit must be what it reads.
  const rebuilt = await bootAndProbe({ crossOriginIsolated: false, workspace: WORKSPACE_OVERLAY })
  try {
    assertFileView(rebuilt.view, COLD_ENTRIES)
    await rebuilt.writeHostFile('/dsh/workspace/after-boot.txt', 'written by bash\n')
    await rebuilt.writeHostFile('/dsh/workspace/data.txt', 'changed by bash\n')
    const listed = await rebuilt.python(['--list', '/dsh/workspace'])
    assert.equal(listed.exitCode, 0, listed.stderr)
    assert.deepEqual(
      listed.stdout.split('\n').slice(1).map(line => line.trim()).filter(line => line !== '').sort(),
      [...COLD_ENTRIES, 'after-boot.txt'].sort(),
      'the next python3 run sees the tree the shell wrote',
    )
    const read = await rebuilt.python(['/dsh/workspace/data.txt'])
    assert.equal(read.exitCode, 0, read.stderr)
    assert.equal(
      read.stdout.slice(read.stdout.indexOf('\n') + 1),
      'changed by bash\n',
      'the next python3 run reads the live bytes, not the boot-time capture',
    )
  } finally {
    await rebuilt.dispose()
  }
})

test('python3 file view survives the rebuilt boot in a fresh context (new process)', {
  timeout: 120_000,
}, () => {
  const fixture = fileURLToPath(new URL('./fixtures/python-rebuild-fresh-context.ts', import.meta.url))
  const child = spawnSync(process.execPath, [fixture], {
    encoding: 'utf8',
    timeout: 110_000,
    env: { ...process.env, NO_COLOR: '1' },
  })
  assert.equal(child.status, 0, `the fresh-context boot failed:\n${child.stdout}\n${child.stderr}`)
  const marker = child.stdout
    .split('\n')
    .find(line => line.startsWith('__PDSH_REBUILD_VIEW__ '))
  assert.ok(marker !== undefined, `the fresh-context boot printed no view:\n${child.stdout}\n${child.stderr}`)
  const view = JSON.parse(marker.slice('__PDSH_REBUILD_VIEW__ '.length)) as FileView
  assertFileView(view, REBUILT_ENTRIES)
})
