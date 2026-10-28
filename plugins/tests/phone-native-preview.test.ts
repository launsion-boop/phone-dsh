// SPDX-License-Identifier: MIT
/**
 * Native Office preview plugin: extension selection, DSH address parsing, the
 * exact bridge message and the no-bridge fallback. These tests drive the same
 * registration function the browser half calls; they do not start a browser.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  NATIVE_PREVIEW_EXTENSIONS,
  NATIVE_PREVIEW_HANDLER,
  decodeNativePreviewResult,
  isNativePreviewPath,
  nativePreviewBridge,
  nativePreviewExtension,
  nativePreviewMessage,
  nativePreviewTarget,
  postNativePreview,
} from '../phone-native-preview/src/protocol.ts'
import {
  NATIVE_PREVIEW_RENDERER_ID,
  registerNativePreview,
  type NativePreviewComponent,
  type NativePreviewDefinition,
  type NativePreviewServices,
  type NativePreviewSlotOptions,
} from '../phone-native-preview/src/register.ts'

interface FakeContextState {
  readonly context: Parameters<typeof registerNativePreview>[0]
  readonly definitions: NativePreviewDefinition[]
  readonly slots: Array<{ options: NativePreviewSlotOptions; body: NativePreviewComponent }>
  readonly localeNamespaces: string[]
  readonly effects: number
}

function fakeContext(): FakeContextState {
  const definitions: NativePreviewDefinition[] = []
  const slots: Array<{ options: NativePreviewSlotOptions; body: NativePreviewComponent }> = []
  const localeNamespaces: string[] = []
  let effects = 0
  const services: NativePreviewServices = {
    locale: {
      register(namespace) {
        localeNamespaces.push(namespace)
        return () => undefined
      },
      bind() {
        return key => key
      },
    },
    documentPreviews: {
      register(definition) {
        definitions.push(definition)
        return () => undefined
      },
    },
    slots: {
      inject(_name, callback) {
        effects += 1
        return callback()
      },
      register(options, body) {
        slots.push({ options, body })
        return () => undefined
      },
    },
  }
  const context = {
    effect(callback: () => void | (() => void)) {
      effects += 1
      callback()
    },
    ...services,
  }
  return {
    context: context as unknown as Parameters<typeof registerNativePreview>[0],
    definitions,
    slots,
    localeNamespaces,
    get effects() { return effects },
  }
}

const body: NativePreviewComponent = () => null

test('only doc, docx, ppt and pptx are claimed', () => {
  assert.deepEqual([...NATIVE_PREVIEW_EXTENSIONS], ['doc', 'docx', 'ppt', 'pptx'])
  for (const path of ['a.doc', 'docs/a.docx', 'DECK.PPT', '/x/y/PRESENTATION.PPTX']) {
    assert.equal(isNativePreviewPath(path), true, path)
  }
  for (const path of ['a.pdf', 'a.png', 'a.xlsx', 'a.html', 'a.txt', 'a.md',
    'a.docx.txt', 'docx', '.docx', 'a.xls']) {
    assert.equal(isNativePreviewPath(path), false, path)
  }
  assert.equal(nativePreviewExtension('archive.TAR.GZ'), 'gz')
  assert.equal(nativePreviewExtension('folder/.docx'), undefined)
})

test('resolves a session-scoped dsh-resource address through DSH workspace-path', () => {
  assert.deepEqual(
    nativePreviewTarget('dsh-resource://file/session/session-1/docs/My%20Report.docx'),
    { sessionId: 'session-1', path: 'docs/My Report.docx' },
  )
  assert.deepEqual(
    nativePreviewTarget('dsh-resource://file/session/session-1/absolute/inside.docx'),
    { sessionId: 'session-1', path: 'absolute/inside.docx' },
  )
  assert.equal(nativePreviewTarget('dsh-resource://file/absolute/docs/a.docx'), undefined)
  assert.equal(nativePreviewTarget('dsh-resource://file/session/session-1/a.pdf'), undefined)
  assert.equal(nativePreviewTarget('dsh-resource://file/session/session-1/a.png'), undefined)
  assert.equal(nativePreviewTarget('dsh-resource://file/session/session-1/a.xlsx'), undefined)
  assert.equal(nativePreviewTarget('dsh-resource://file/session/session-1/a.html'), undefined)
  assert.equal(nativePreviewTarget('dsh-resource://file/session/session-1/a.txt'), undefined)
  assert.equal(nativePreviewTarget('not-an-address'), undefined)
})

test('the bridge message is exactly version 1 and the four fields', () => {
  const message = nativePreviewMessage('request-1', {
    sessionId: 'session-1',
    path: 'docs/a.docx',
  })
  assert.deepEqual(message, {
    v: 1,
    id: 'request-1',
    sessionId: 'session-1',
    path: 'docs/a.docx',
  })
  assert.deepEqual(Object.keys(message).sort(), ['id', 'path', 'sessionId', 'v'])
})

test('no native handler means no document registration', () => {
  const state = fakeContext()
  const registered = registerNativePreview(state.context, body, {})
  assert.equal(registered, false)
  assert.equal(state.definitions.length, 0)
  assert.equal(state.slots.length, 0)
  assert.equal(state.localeNamespaces.length, 0)
  assert.equal(state.effects, 0)
  assert.equal(nativePreviewBridge({}), undefined)
  assert.equal(nativePreviewBridge({
    webkit: { messageHandlers: { [NATIVE_PREVIEW_HANDLER]: {} } },
  }), undefined)
})

test('a present handler registers only the external Office document preview', () => {
  const state = fakeContext()
  const registered = registerNativePreview(state.context, body, {
    webkit: {
      messageHandlers: {
        [NATIVE_PREVIEW_HANDLER]: { postMessage() {} },
      },
    },
  })
  assert.equal(registered, true)
  assert.deepEqual(state.localeNamespaces, ['sidebarNativePreview'])
  assert.equal(state.definitions.length, 1)
  const definition = state.definitions[0]!
  assert.equal(definition.id, NATIVE_PREVIEW_RENDERER_ID)
  assert.deepEqual([...definition.extensions], ['doc', 'docx', 'ppt', 'pptx'])
  assert.deepEqual([...definition.binaryExtensions], ['doc', 'docx', 'ppt', 'pptx'])
  assert.equal(definition.priority, 'extension')
  assert.equal(definition.loading, 'renderer')
  assert.equal(definition.wrap, false)
  assert.equal(definition.title(), 'title')
  assert.equal(state.slots.length, 1)
  assert.deepEqual(state.slots[0]!.options, {
    name: 'sidebar.right.tab.document',
    key: NATIVE_PREVIEW_RENDERER_ID,
    locale: 'sidebarNativePreview',
  })
  assert.equal(state.slots[0]!.body, body)
})

test('the result decoder accepts only the native callback shape', () => {
  assert.deepEqual(
    decodeNativePreviewResult({ id: 'r', ok: true, code: 'presented', message: '' }),
    { id: 'r', ok: true, code: 'presented', message: '' },
  )
  for (const value of [
    undefined,
    null,
    {},
    { id: '', ok: true, code: 'presented', message: '' },
    { id: 'r', ok: 'true', code: 'presented', message: '' },
    { id: 'r', ok: true, code: '', message: '' },
    { id: 'r', ok: true, code: 'presented', message: 1 },
  ]) {
    assert.equal(decodeNativePreviewResult(value), undefined)
  }
})

test('a missing bridge is a real failure, never a fake success', async () => {
  const result = await postNativePreview(
    { sessionId: 'session-1', path: 'docs/a.docx' },
    { scope: {}, id: 'request-1' },
  )
  assert.deepEqual(result, {
    id: 'request-1',
    ok: false,
    code: 'native-bridge-unavailable',
    message: 'The native Quick Look bridge is not installed.',
  })
})
