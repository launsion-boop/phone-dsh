// SPDX-License-Identifier: MIT
// @ts-nocheck -- the checkout is not an npm dependency of this repository;
// this file only re-exports the checkout's modules for esbuild to bundle.
/**
 * Probe entry point: re-export the DeepSeek Harness seams under test.
 *
 * `src/bundle.ts` rewrites the two `src/` package prefixes onto the checkout
 * named by `PDSH_DSH_CHECKOUT`, so this module never contains a local path.
 * Nothing is copied from DSH; every export IS the checkout's implementation.
 * @module @phone-dsh/dsh-contract-tests/probe
 */
import * as runtimeApi from '@deepseek-ai/dsh-experimental-webworker-runtime/src/index.ts'
import {
  DEFAULT_ROOT,
  IMAGE_EMPTY_DIRECTORIES,
  IMAGE_HOME_DIRECTORY,
  IMAGE_MANIFEST_PATH,
  IMAGE_OVERLAY_DIRECTORIES,
  PLATFORM_ENTRY_CONFIG,
} from '@deepseek-ai/dsh-experimental-webworker-runtime/src/image-layout.ts'
import { MemoryVfs } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/memory.ts'
import { setActiveVfs } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/active.ts'
import { spawn, spawnSync } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/child_process.ts'
import {
  createServer,
  requestListener,
  whenRequestListener,
} from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtin_modules/implemented/http.ts'
import { standardPrograms } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/shell/programs/index.ts'
import { runShellCommand } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/shell/interpret.ts'
import { PROFILE_PATCH_FILENAME, readProfilePatches } from '@deepseek-ai/dsh-app-boot/src/index.ts'

export {
  DEFAULT_ROOT,
  IMAGE_EMPTY_DIRECTORIES,
  IMAGE_HOME_DIRECTORY,
  IMAGE_MANIFEST_PATH,
  IMAGE_OVERLAY_DIRECTORIES,
  MemoryVfs,
  PLATFORM_ENTRY_CONFIG,
  PROFILE_PATCH_FILENAME,
  createServer,
  readProfilePatches,
  requestListener,
  runShellCommand,
  runtimeApi,
  setActiveVfs,
  spawn,
  spawnSync,
  standardPrograms,
  whenRequestListener,
}
