// SPDX-License-Identifier: MIT
/**
 * Behavior tests for the field-controlled module-import diagnostic. The first
 * case is the form JavaScriptCore actually produces for a failed
 * `new Function` body: frames only, with no message. The rest feed common
 * credential fields, arbitrary headers, URL coordinates, percent-encoded
 * secrets, custom error names/codes/causes and stacks, and assert that none of
 * that raw text reaches the formatted result while the fixed module context
 * survives.
 * @module @phone-dsh/dsh-worker-entry/module-import.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  MODULE_IMPORT_DIAGNOSTIC_LIMIT,
  enrichModuleImportError,
  installModuleImportDiagnostics,
} from './module-import.ts'

/** A JavaScriptCore-shaped failure: the name/message never appear in its stack. */
function jscFailure(message: string): Error {
  const error = new ReferenceError(message)
  error.stack = 'anonymous@\nglobal code@'
  return error
}

/** Every text a diagnostic could carry, not only an old regex's known pattern. */
function diagnosticText(error: Error): string {
  return `${error.name}\n${error.message}\n${error.stack ?? ''}`
}

test('a JSC stack reports a fixed ReferenceError reason, not the variable name', () => {
  const safe = enrichModuleImportError(jscFailure("Can't find variable: secretRuntimeGlobal"), {
    specifier: '@phone-dsh/dsh-phone-mcp',
    parentURL: '/dsh/home/profiles/web/',
  })

  assert.equal(safe.name, 'ModuleImportError')
  assert.equal(
    safe.message,
    'ModuleImportError: ReferenceError: E_MODULE_IMPORT: runtime global unavailable '
      + '(importing @phone-dsh/dsh-phone-mcp from /dsh/home/profiles/web/)',
  )
  assert.equal(safe.stack?.split('\n', 1)[0], safe.message)
  assert.equal(diagnosticText(safe).includes('secretRuntimeGlobal'), false)
  assert.equal(diagnosticText(safe).includes("Can't find variable"), false)
  assert.equal(safe.cause, undefined, 'the raw failure must not be attached as cause')
  // The diagnostic must not depend on assigning through an engine accessor;
  // own a writable data property even if an engine defines `stack` on the
  // prototype.
  const stackDescriptor = Object.getOwnPropertyDescriptor(safe, 'stack')
  assert.equal(typeof stackDescriptor?.value, 'string')
  assert.equal(stackDescriptor?.writable, true)
})

test('a known loader code survives while the raw message and custom code are dropped', () => {
  const known = Object.assign(new ReferenceError('failed to resolve image module api_key=sk-live-123'), {
    code: 'MODULE_NOT_FOUND',
  })
  known.stack = 'anonymous@'
  const safe = enrichModuleImportError(known, { specifier: '@phone-dsh/dsh-phone-mcp' })
  assert.match(safe.message, /^ModuleImportError: ReferenceError: E_MODULE_IMPORT/)
  assert.match(safe.message, /\[MODULE_NOT_FOUND\]$/)
  assert.equal(diagnosticText(safe).includes('failed to resolve image module'), false)
  assert.equal(diagnosticText(safe).includes('sk-live-123'), false)

  const unknown = Object.assign(new TypeError('raw failure'), { code: 'CUSTOM_SECRET_CODE_123' })
  const unknownSafe = enrichModuleImportError(unknown)
  assert.match(unknownSafe.message, /^ModuleImportError: TypeError: E_MODULE_IMPORT$/)
  assert.equal(unknownSafe.message.includes('CUSTOM_SECRET_CODE_123'), false)
  assert.equal(unknownSafe.message.includes('raw failure'), false)
})

test('the packed-image missing-module probe keeps fixed module locators', () => {
  const error = Object.assign(new Error("Cannot find module '@phone-dsh/__missing_module_import_probe__'"), {
    code: 'MODULE_NOT_FOUND',
  })
  error.stack = 'anonymous@'
  const safe = enrichModuleImportError(error, {
    specifier: '@phone-dsh/__missing_module_import_probe__',
    parentURL: '/dsh/home/profiles/web/',
  })
  // Mirrors the production boot test's assertion: the audit still gets the
  // missing package, the profile directory and the known loader code, but not
  // the raw resolution message.
  assert.match(safe.message, /^ModuleImportError: Error: .*__missing_module_import_probe__.*\[MODULE_NOT_FOUND\]/)
  assert.match(safe.message, /importing @phone-dsh\/__missing_module_import_probe__/)
  assert.match(safe.message, /from \/dsh\/home\/profiles\/web\//)
  assert.equal(safe.message.includes('Cannot find module'), false)
})

test('a V8 stack keeps only known static Worker locations with numeric line/column', () => {
  const error = new TypeError('bad dependency export with secret-value')
  error.stack = [
    'TypeError: bad dependency export with secret-value',
    '    at load (/static/worker-entry.js:12:34)',
    '    at secretFunction (/tmp/secret-path.js:9:9)',
    '    at <anonymous> (https://user:password@host/x?token=abc:1:2)',
  ].join('\n')
  const safe = enrichModuleImportError(error)
  const text = diagnosticText(safe)
  assert.match(text, /^ModuleImportError: TypeError: E_MODULE_IMPORT/m)
  assert.match(text, /\nat worker-entry\.js:12:34/)
  for (const leaked of ['bad dependency export', 'secret-value', 'secretFunction', '/tmp/secret-path.js', 'user:password', 'token=abc']) {
    assert.equal(text.includes(leaked), false, `${leaked} must not survive`)
  }
  assert.equal((safe.stack ?? '').split('\n').filter(line => line.startsWith('at ')).length, 1)
})

test('common key/password/header/URL/percent-encoded secrets never enter the result', () => {
  const secrets = [
    'sk-live-123',
    'hunter2',
    'passwd-value',
    'passphrase-value',
    'secret-value',
    'credential-value',
    'api-key-value',
    'x-api-key-value',
    'access-key-value',
    'private-key-value',
    'amz-credential-value',
    'arbitrary-header-value',
    'userinfo-password',
    'wss-secret',
    'query-secret',
    'percent-secret',
    'encoded-secret%2Fpart',
  ]
  const error = new Error(
    'api_key=sk-live-123, password=hunter2, passwd=passwd-value, passphrase=passphrase-value, '
    + 'secret=secret-value, credential=credential-value, x_api_key: x-api-key-value, '
    + 'x-amz-credential: amz-credential-value, access_key=access-key-value, '
    + 'private_key=private-key-value, x-arbitrary-header: arbitrary-header-value, '
    + 'wss://user:userinfo-password@channel.invalid/ws?token=wss-secret&api_key=query-secret#frag, '
    + 'https://host/a%20b?q=percent-secret, encoded=encoded-secret%2Fpart',
  )
  error.stack = `Error: ${error.message}\n    at load (/static/worker-entry.js:1:2)`
  const safe = enrichModuleImportError(error, {
    specifier: '@phone-dsh/dsh-phone-mcp',
    parentURL: '/dsh/home/profiles/web/',
  })
  const text = diagnosticText(safe)
  for (const secret of secrets) {
    assert.equal(text.includes(secret), false, `${secret} must not survive`)
  }
  assert.match(text, /@phone-dsh\/dsh-phone-mcp/)
  assert.match(text, /E_MODULE_IMPORT/)
  assert.match(text, /at worker-entry\.js:1:2/)
})

test('custom Error.name/code/cause/stack fields are not copied as safe fields', () => {
  const error = Object.assign(new Error('raw message with hunter2'), {
    name: 'ReferenceErrorLeak',
    code: 'SECRET_CODE_123',
    cause: new Error('cause with secret-value'),
  })
  error.stack = 'ReferenceErrorLeak: raw message with hunter2\n    at custom (secret-stack-value)'
  const safe = enrichModuleImportError(error, { specifier: '@phone-dsh/dsh-phone-mcp' })
  const text = diagnosticText(safe)
  assert.equal(safe.name, 'ModuleImportError')
  assert.equal((safe as { cause?: unknown }).cause, undefined)
  for (const leaked of ['ReferenceErrorLeak', 'SECRET_CODE_123', 'raw message', 'hunter2', 'cause with secret-value', 'secret-stack-value']) {
    assert.equal(text.includes(leaked), false, `${leaked} must not survive`)
  }
  assert.match(safe.message, /^ModuleImportError: Error: E_MODULE_IMPORT/)
})

test('only strict registry specifiers and the fixed profile parent are retained', () => {
  const allowed = enrichModuleImportError(new Error('x'), {
    specifier: '@scope/Package.Name',
    parentURL: '/dsh/home/profiles/web/',
  })
  assert.match(allowed.message, /importing @scope\/Package\.Name from \/dsh\/home\/profiles\/web\//)

  for (const specifier of [
    'https://user:pass@host/pkg?token=secret',
    '/dsh/home/secret.js',
    './relative/secret',
    '@scope/pkg/subpath',
    '@scope/na%2Fme',
    '@scope/pkg?x=1',
    '@scope/pkg#frag',
    'user@host/pkg',
    'C:\\secret\\pkg',
  ]) {
    const safe = enrichModuleImportError(new Error('x'), { specifier })
    assert.match(safe.message, /importing <omitted>/)
    assert.equal(safe.message.includes(specifier), false)
    assert.equal(safe.message.includes('secret'), false)
  }

  for (const parentURL of [
    'https://user:pass@host/profiles/web/?token=secret',
    '/dsh/home/profiles/web/?token=secret',
    '/dsh/home/profiles/web/#frag',
    '/tmp/secret/',
    'file:///tmp/secret/',
    'file://user:pass@/dsh/home/profiles/web/',
  ]) {
    const safe = enrichModuleImportError(new Error('x'), {
      specifier: '@scope/pkg',
      parentURL,
    })
    assert.equal(safe.message.includes('from '), false, `${parentURL} must be omitted`)
    assert.equal(safe.message.includes('secret'), false)
  }
})

test('the diagnostic is length-bounded without exceeding the limit', () => {
  const safe = enrichModuleImportError(new Error('x'), {
    specifier: `@scope/${'a'.repeat(240)}`,
    limit: 256,
  })
  assert.equal(safe.message.length, 256)
  assert.match(safe.message, /\.\.\.$/)
  assert.ok((safe.stack?.length ?? 0) <= 256)

  const defaultBound = enrichModuleImportError(new Error('x'.repeat(5000)))
  assert.ok((defaultBound.message.length ?? 0) <= MODULE_IMPORT_DIAGNOSTIC_LIMIT)
  assert.ok((defaultBound.stack?.length ?? 0) <= MODULE_IMPORT_DIAGNOSTIC_LIMIT)
  assert.equal((defaultBound.stack ?? '').split('\n').length, 1)
})

test('the import wrapper enriches failures once and leaves success alone', async () => {
  let calls = 0
  const seam = {
    internal: {
      async import(specifier: string): Promise<unknown> {
        calls += 1
        if (specifier === '@scope/bad') throw jscFailure('missing dependency secret-value')
        return { ok: true }
      },
    },
  }
  assert.equal(installModuleImportDiagnostics(seam), true)
  assert.equal(installModuleImportDiagnostics(seam), false, 'repeated wiring is a no-op')
  assert.deepEqual(await seam.internal.import('@scope/good'), { ok: true })
  await assert.rejects(seam.internal.import('@scope/bad'), (error: unknown) => {
    assert.ok(error instanceof Error)
    assert.match(error.stack ?? '', /ReferenceError: E_MODULE_IMPORT: runtime global unavailable/)
    assert.equal((error as { cause?: unknown }).cause, undefined)
    assert.equal(diagnosticText(error).includes('missing dependency secret-value'), false)
    return true
  })
  assert.equal(calls, 2, 'the wrapper must not retry or swallow the import')
})

test('a non-Error thrown value is still bounded and drops its text', () => {
  const safe = enrichModuleImportError('plain failure password=hunter2')
  assert.match(safe.message, /^ModuleImportError: Error: E_MODULE_IMPORT$/)
  assert.equal(safe.message.includes('plain failure'), false)
  assert.equal(safe.message.includes('hunter2'), false)
})
