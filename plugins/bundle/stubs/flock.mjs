// SPDX-License-Identifier: MIT
// Single-process replacement for `@deepseek-ai/node-addon-system/flock`.
// The phone runtime is one Node instance per app process, and the JSONL
// backend's in-process write claim already excludes every other writer in that
// process, so the kernel-lock request succeeds without a native flock(2).
// Risk: a second harness process (or another app extension) writing the same
// session directory is NOT excluded. See plugins/README.md "flock stub".

export function tryLockExclusive(_fd) {
  return Promise.resolve()
}

export default { tryLockExclusive }
