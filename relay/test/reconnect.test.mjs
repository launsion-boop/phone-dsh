// SPDX-License-Identifier: MIT
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  connectClient,
  createIdentity,
  delay,
  e2eFrame,
  randomSid,
  startRelay,
} from './helpers.mjs'

class ReconnectingPeer {
  constructor({ relayProvider, identity, role, onReady, reconnectMs = 20 }) {
    this.relayProvider = relayProvider
    this.identity = identity
    this.role = role
    this.onReady = onReady
    this.reconnectMs = reconnectMs
    this.client = null
    this.readyCount = 0
    this.readyWaiters = []
    this.stopped = false
    this.lastError = null
  }

  start() {
    this.loopPromise = this.loop()
    return this
  }

  async loop() {
    while (!this.stopped) {
      const relay = this.relayProvider()
      if (relay === undefined || relay === null || relay.closed) {
        await delay(this.reconnectMs)
        continue
      }
      try {
        const { client } = await connectClient({ relay, identity: this.identity, role: this.role })
        if (this.stopped) {
          client.close()
          return
        }
        this.client = client
        this.readyCount += 1
        for (const waiter of this.readyWaiters.splice(0)) {
          if (this.readyCount >= waiter.count) waiter.resolve()
          else this.readyWaiters.push(waiter)
        }
        if (this.onReady !== undefined) this.onReady(client)
        await client.waitClose(10 * 60 * 1000)
      } catch (error) {
        this.lastError = error
        await delay(this.reconnectMs)
      }
      if (!this.stopped) await delay(this.reconnectMs)
    }
  }

  whenReady(count = 1, timeoutMs = 5000) {
    if (this.readyCount >= count) return Promise.resolve()
    return new Promise((resolve, reject) => {
      const waiter = {
        count,
        resolve: () => {
          clearTimeout(timer)
          resolve()
        },
      }
      const timer = setTimeout(() => {
        const at = this.readyWaiters.indexOf(waiter)
        if (at !== -1) this.readyWaiters.splice(at, 1)
        reject(new Error(`peer did not become ready ${count} times (last error: ${this.lastError?.message})`))
      }, timeoutMs)
      this.readyWaiters.push(waiter)
    })
  }

  send(message) {
    if (this.client === null) throw new Error('peer is not connected')
    this.client.send(message)
  }

  async stop() {
    this.stopped = true
    if (this.client !== null) this.client.close()
    if (this.loopPromise !== undefined) await this.loopPromise
  }
}

test('peers re-authenticate after a phone drop and after a relay restart', { timeout: 20_000 }, async t => {
  let relay = await startRelay({ maxConnectionsPerIp: 100 })
  const port = relay.port
  const origin = relay.origin
  t.after(async () => {
    await relay.close()
  })

  const pcIdentity = createIdentity()
  const phoneIdentity = createIdentity()
  let pc = null
  let phone = null
  const pcPeer = new ReconnectingPeer({
    relayProvider: () => relay,
    identity: pcIdentity,
    role: 'pc',
    onReady: client => {
      client.send({ v: 1, type: 'relay.allow', peers: [phoneIdentity.machineId] })
    },
  })
  const phonePeer = new ReconnectingPeer({
    relayProvider: () => relay,
    identity: phoneIdentity,
    role: 'phone',
  })
  pc = pcPeer.start()
  phone = phonePeer.start()
  t.after(async () => {
    await pcPeer.stop()
    await phonePeer.stop()
  })

  await pc.whenReady(1)
  await phone.whenReady(1)

  const firstSid = randomSid()
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: firstSid }))
  assert.equal((await pc.client.next('e2e')).sid, firstSid)

  // Drop the phone only; it reconnects and re-runs relay auth.
  phone.client.close()
  await phone.whenReady(2)
  const afterPhoneDrop = randomSid()
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: afterPhoneDrop }))
  assert.equal((await pc.client.next('e2e')).sid, afterPhoneDrop)

  // Restart the relay on the same port.  Both peers must authenticate again,
  // the PC must re-send relay.allow, and traffic must resume.
  await relay.close()
  relay = await startRelay({ port, publicOrigin: origin, maxConnectionsPerIp: 100 })
  await pc.whenReady(2)
  await phone.whenReady(2)
  await delay(50)
  const afterRestart = randomSid()
  phone.send(e2eFrame({ from: phoneIdentity.machineId, to: pcIdentity.machineId, sid: afterRestart }))
  assert.equal((await pc.client.next('e2e')).sid, afterRestart)

  const relayPeer = relay.peers.get(pcIdentity.machineId)
  assert.notEqual(relayPeer, undefined)
  assert.equal(relay.peers.get(phoneIdentity.machineId)?.role, 'phone')
})
