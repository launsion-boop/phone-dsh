// SPDX-License-Identifier: MIT
/**
 * The final Worker static-module table: the three Worker-native workflow seams
 * are installed, while the existing sharp and app-boot behaviour is untouched.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { Context } from '@deepseek-ai/cordis'

import { APP_BOOT_SPECIFIER } from './fs-read-state.ts'
import { SHARP_MODULE_SPECIFIER } from './sharp-marker.ts'
import { sharpShim } from './sharp-shim.ts'
import terminalShim from './terminal-shim.ts'
import toolPresentationShim from './tool-presentation-shim.ts'
import vmShim from './vm-shim.ts'
import {
  PHONE_STATIC_MODULE_OVERRIDES,
  TERMINAL_SPECIFIER,
  TOOL_PRESENTATION_SPECIFIER,
  VM_MODULE_SPECIFIERS,
  WORKFLOW_PTC_SPECIFIER,
  composePhoneStaticModules,
} from './static-modules.ts'

test('composePhoneStaticModules installs the workflow, presentation and vm seams', () => {
  const baseSharp = { marker: 'base-sharp' }
  const baseVm = { marker: 'base-vm' }
  const baseAppBoot = { marker: 'base-app-boot' }
  const appBoot = () => ({ marker: 'phone-app-boot' })
  const workflowPtc = () => ({ default: class WorkerEngine {} })
  const modules = composePhoneStaticModules({
    [SHARP_MODULE_SPECIFIER]: () => baseSharp,
    [APP_BOOT_SPECIFIER]: () => baseAppBoot,
    'node:vm': () => baseVm,
    vm: () => baseVm,
  }, {
    ...PHONE_STATIC_MODULE_OVERRIDES,
    appBoot,
    workflowPtc,
  })

  assert.equal(modules[SHARP_MODULE_SPECIFIER]?.(), sharpShim)
  assert.notEqual(modules[SHARP_MODULE_SPECIFIER]?.(), baseSharp)
  assert.equal(modules[APP_BOOT_SPECIFIER], appBoot)
  assert.notEqual(modules[APP_BOOT_SPECIFIER], baseAppBoot)
  assert.equal(modules[WORKFLOW_PTC_SPECIFIER], workflowPtc)
  assert.equal(modules[TOOL_PRESENTATION_SPECIFIER]?.(), toolPresentationShim)
  assert.equal(modules[TERMINAL_SPECIFIER]?.(), terminalShim)
  for (const specifier of VM_MODULE_SPECIFIERS) {
    assert.equal(modules[specifier]?.(), vmShim)
    assert.notEqual(modules[specifier]?.(), baseVm)
  }
})

test('the default override table keeps sharp and installs vm/presentation without image access', () => {
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.sharp, sharpShim)
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.vm?.(), vmShim)
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.toolPresentation?.(), toolPresentationShim)
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.workflowPtc, undefined)
})

/** A presentation context that records the declared mode and warnings. */
function presentationContext(runtime: unknown): {
  ctx: Context
  modes: string[]
  warnings: string[]
} {
  const modes: string[] = []
  const warnings: string[] = []
  const ctx = {
    tools: { presentAs: (mode: string) => { modes.push(mode) } },
    get: (name: string) => name === 'ptcRuntime' ? runtime : undefined,
    logger: { warn: (message: string) => { warnings.push(message) } },
  }
  return { ctx: ctx as unknown as Context, modes, warnings }
}

test('presentation mode=native declares the native catalog without consulting ptc', () => {
  const { ctx, modes, warnings } = presentationContext(undefined)
  toolPresentationShim.apply(ctx, { mode: 'native' })
  assert.deepEqual(modes, ['native'])
  assert.deepEqual(warnings, [])
})

test('presentation mode=ptc without a runtime warns and presents the native catalog', () => {
  const { ctx, modes, warnings } = presentationContext(undefined)
  toolPresentationShim.apply(ctx, { mode: 'ptc' })
  assert.deepEqual(modes, ['native'])
  assert.equal(warnings.length, 1)
  assert.match(warnings[0] ?? '', /no ptcRuntime/u)
})

test('presentation mode=ptc with a mounted runtime declares ptc', () => {
  const { ctx, modes, warnings } = presentationContext({ marker: 'real-ptc-runtime' })
  toolPresentationShim.apply(ctx, { mode: 'ptc' })
  assert.deepEqual(modes, ['ptc'])
  assert.deepEqual(warnings, [])
})
