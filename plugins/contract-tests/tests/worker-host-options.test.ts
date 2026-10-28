// SPDX-License-Identifier: MIT
// createWorkerHost's option names are the seam the phone Worker entry builds
// its runtime host against; renaming one silently drops platform behaviour.
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { findFunction, interfaceMembers, parseText } from '../src/ast.ts'
import { readCheckoutFile } from '../src/checkout-file.ts'
import { observe } from '../src/observed.ts'

/** Options `worker-entry/src/runtime-binding.ts` passes to createWorkerHost. */
const REQUIRED_OPTIONS = [
  'staticModules',
  'staticModulePrefixes',
  'requestListener',
  'alsCausality',
  'image',
  'overlays',
  'env',
  'channel',
] as const

test('worker host: createWorkerHost accepts the phone host option names', (t) => {
  const source = parseText(
    'worker-host.ts',
    readCheckoutFile('packages/experimental/webworker-runtime/src/worker-host.ts'),
  )
  const members = interfaceMembers(source, 'WorkerHostOptions')
  observe(t, 'createWorkerHostOptions', members)
  const names = members.map(member => member.name)
  for (const name of REQUIRED_OPTIONS) {
    assert.ok(names.includes(name), `WorkerHostOptions no longer carries the ${name} option`)
  }

  const factory = findFunction(source, 'createWorkerHost')
  assert.notEqual(factory, undefined, 'createWorkerHost must stay a function declaration')
  const parameter = factory?.parameters[0]
  const parameterType = parameter?.type?.getText(source) ?? ''
  observe(t, 'createWorkerHostParameter', { name: parameter?.name.getText(source) ?? '', type: parameterType })
  assert.equal(parameterType, 'WorkerHostOptions', 'createWorkerHost must keep building from WorkerHostOptions')
})
