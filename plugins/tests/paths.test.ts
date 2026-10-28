// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { PathMapper } from '../exec-bridge/src/paths.ts'

test('identity mount maps paths to themselves', () => {
  const mapper = new PathMapper([{ host_path: '/data/ws', guest_path: '/data/ws' }])
  assert.equal(mapper.identity, true)
  assert.equal(mapper.toGuest('/data/ws/src/a.txt'), '/data/ws/src/a.txt')
  assert.equal(mapper.toHost('/data/ws'), '/data/ws')
})

test('prefix mount maps host to guest and back, on segment boundaries only', () => {
  const mapper = new PathMapper([
    { host_path: '/private/var/app/Library/xl/ws/t1/', guest_path: '/var/minis/workspace' },
    { host_path: '/private/var/app/Library/xl/recordings', guest_path: '/var/xl/recordings', read_only: true },
  ])
  assert.equal(mapper.identity, false)
  assert.equal(mapper.toGuest('/private/var/app/Library/xl/ws/t1'), '/var/minis/workspace')
  assert.equal(mapper.toGuest('/private/var/app/Library/xl/ws/t1/a/../b.txt'), '/var/minis/workspace/b.txt')
  assert.equal(mapper.toGuest('/private/var/app/Library/xl/ws/t10/x'), undefined)
  assert.equal(mapper.toHost('/var/xl/recordings/2026/a.ogg'), '/private/var/app/Library/xl/recordings/2026/a.ogg')
  assert.equal(mapper.toGuest('relative/path'), undefined)
  assert.equal(mapper.defaultGuestRoot, '/var/minis/workspace')
})

test('the longest matching mount wins', () => {
  const mapper = new PathMapper([
    { host_path: '/h', guest_path: '/g' },
    { host_path: '/h/inner', guest_path: '/other' },
  ])
  assert.equal(mapper.toGuest('/h/inner/x'), '/other/x')
  assert.equal(mapper.toGuest('/h/outer/x'), '/g/outer/x')
})

test('relative or empty mount tables are rejected', () => {
  assert.throws(() => new PathMapper([]), /no guest mounts/)
  assert.throws(() => new PathMapper([{ host_path: 'ws', guest_path: '/g' }]), /absolute/)
})

test('a guest-only mapper passes guest paths through and never maps host paths', () => {
  const mapper = PathMapper.guestOnly('/dsh/workspace')
  assert.equal(mapper.isGuestOnly, true)
  assert.equal(mapper.identity, false)
  assert.equal(mapper.defaultGuestRoot, '/dsh/workspace')
  // The channel's trusted Native cwd protocol uses guest paths directly.
  assert.equal(mapper.toGuest('/dsh/workspace'), '/dsh/workspace')
  assert.equal(mapper.toGuest('/dsh/home/../workspace/a.txt'), '/dsh/workspace/a.txt')
  assert.equal(mapper.toGuest('relative'), undefined)
  // No host mount facts were published: /etc must never look mounted.
  assert.equal(mapper.toHost('/etc'), undefined)
  assert.equal(mapper.toHost('/dsh/workspace'), undefined)
  assert.throws(() => new PathMapper([{ host_path: '/h', guest_path: '/g' }], { guestOnly: true }), /cannot carry host mounts/)
})
