// SPDX-License-Identifier: MIT
/**
 * G2-FIX-54 "fresh context" half of the rebuild regression: a process that has
 * never booted the Worker boots it once over the image plus the workspace
 * overlay the resume path rebuilds, prints the guest and shell file views, and
 * exits non-zero only when the boot itself fails.
 *
 * The test process spawns this file so the rebuilt boot happens in a fresh
 * module graph and a fresh Worker global scope — the second of the two rebuild
 * shapes (the first, same-context boot, runs in the test itself).
 * @module @phone-dsh/dsh-plugins/tests/fixtures/python-rebuild-fresh-context
 */
import { bootAndProbe, REBUILT_WORKSPACE_OVERLAY } from './python-rebuild-harness.ts'

const booted = await bootAndProbe({
  crossOriginIsolated: false,
  workspace: REBUILT_WORKSPACE_OVERLAY,
})
try {
  console.log(`__PDSH_REBUILD_VIEW__ ${JSON.stringify(booted.view)}`)
} finally {
  await booted.dispose()
}
