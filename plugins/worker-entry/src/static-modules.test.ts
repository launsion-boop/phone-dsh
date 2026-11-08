// SPDX-License-Identifier: MIT
/**
 * The final Worker static-module table: the Worker-native workflow seams
 * are installed, while the existing sharp and app-boot behaviour is untouched.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { APP_BOOT_SPECIFIER } from './fs-read-state.ts'
import { SHARP_MODULE_SPECIFIER } from './sharp-marker.ts'
import { sharpShim } from './sharp-shim.ts'
import terminalShim from './terminal-shim.ts'
import vmShim from './vm-shim.ts'
import {
  PHONE_STATIC_MODULE_OVERRIDES,
  TERMINAL_SPECIFIER,
  VM_MODULE_SPECIFIERS,
  WORKFLOW_PTC_SPECIFIER,
  composePhoneStaticModules,
} from './static-modules.ts'

test('composePhoneStaticModules installs the workflow and vm seams', () => {
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
  assert.equal(modules[TERMINAL_SPECIFIER]?.(), terminalShim)
  for (const specifier of VM_MODULE_SPECIFIERS) {
    assert.equal(modules[specifier]?.(), vmShim)
    assert.notEqual(modules[specifier]?.(), baseVm)
  }
})

test('the default override table keeps sharp and installs vm without image access', () => {
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.sharp, sharpShim)
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.vm?.(), vmShim)
  assert.equal(PHONE_STATIC_MODULE_OVERRIDES.workflowPtc, undefined)
})
