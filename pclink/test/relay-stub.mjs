/**
 * Minimal PCLink relay-plane test double (test-only).
 *
 * It implements only what the C integration needs: challenge/auth/ready,
 * allowlists, e2e/e2e.handshake routing, relay.offline, pairing rendezvous and
 * ping/pong. It is deliberately self-contained (no `relay/**` import and no
 * npm dependency) and exposes only in-memory state for assertions.
 */
import { createHash, createPublicKey, randomBytes as nodeRandomBytes, verify } from 'node:crypto'
import { createServer } from 'node:http'
import { b64urlDecode, b64urlEncode } from '../core/encoding.mjs'
import { parseStrictJsonObject } from '../core/json.mjs'

const MAX_FRAME_BYTES = 16 * 1024 * 1024
const PAIR_TTL_MS = 300_000
const MAX_PAIR_SLOTS = 2
const MAX_JOINS = 10

function sha1(text) {
  return createHash('sha1').update(text).digest('base64')
}

function encodeFrame(opcode, payload) {
  const length = payload.length
  let header
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length])
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x80 | opcode
    header[1] = 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[0] = 0x80 | opcode
    header[1] = 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  return Buffer.concat([header, payload])
}

/** One accepted text WebSocket connection. */
class ServerSocket {
  constructor(socket, onMessage, onClose) {
    this.socket = socket
    this.onMessage = onMessage
    this.onClose = onClose
    this.buffer = Buffer.alloc(0)
    this.fragments = []
    this.fragmentOpcode = undefined
    this.open = true
    socket.on('data', chunk => {
      this.buffer = Buffer.concat([this.buffer, chunk])
      this.parse()
    })
    socket.on('close', () => {
      this.open = false
      this.onClose()
    })
    socket.on('error', () => {
      this.open = false
      this.onClose()
    })
  }

  parse() {
    for (;;) {
      if (this.buffer.length < 2) return
      const first = this.buffer[0]
      const second = this.buffer[1]
      const fin = (first & 0x80) !== 0
      const opcode = first & 0x0f
      const masked = (second & 0x80) !== 0
      let length = second & 0x7f
      let offset = 2
      if (length === 126) {
        if (this.buffer.length < 4) return
        length = this.buffer.readUInt16BE(2)
        offset = 4
      } else if (length === 127) {
        if (this.buffer.length < 10) return
        length = Number(this.buffer.readBigUInt64BE(2))
        offset = 10
      }
      if (length > MAX_FRAME_BYTES) {
        this.close(1009, 'frame too large')
        return
      }
      const maskLength = masked ? 4 : 0
      if (this.buffer.length < offset + maskLength + length) return
      let mask
      if (masked) {
        mask = this.buffer.subarray(offset, offset + 4)
        offset += 4
      }
      const payload = Buffer.from(this.buffer.subarray(offset, offset + length))
      this.buffer = this.buffer.subarray(offset + length)
      if (masked) {
        for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4]
      }
      if (opcode === 0x8) {
        this.close(1000, '')
        return
      }
      if (opcode === 0x9) {
        this.write(0xa, payload)
        continue
      }
      if (opcode === 0xa) continue
      if (opcode === 0x2) {
        this.close(1003, 'binary frames are rejected')
        return
      }
      if (opcode === 0x1 || opcode === 0x0) {
        if (opcode === 0x1) {
          this.fragments = [payload]
          this.fragmentOpcode = 0x1
        } else {
          this.fragments.push(payload)
        }
        if (!fin) continue
        const text = Buffer.concat(this.fragments).toString('utf8')
        this.fragments = []
        this.fragmentOpcode = undefined
        this.onMessage(text, this)
        continue
      }
      this.close(1008, 'unsupported opcode')
      return
    }
  }

  send(text) {
    if (!this.open) return
    this.write(0x1, Buffer.from(text, 'utf8'))
  }

  write(opcode, payload) {
    if (!this.open) return
    try { this.socket.write(encodeFrame(opcode, payload)) } catch { this.open = false }
  }

  close(code, reason) {
    if (!this.open) return
    const payload = Buffer.alloc(2 + Buffer.byteLength(reason))
    payload.writeUInt16BE(code, 0)
    payload.write(reason, 2)
    this.write(0x8, payload)
    this.open = false
    try { this.socket.end() } catch { /* closed */ }
  }
}

/** In-memory relay with the §3 routing rules needed by the PC test. */
export class RelayStub {
  constructor() {
    this.origin = undefined
    this.server = undefined
    this.port = undefined
    this.connections = new Set()
    this.byMachine = new Map()
    this.allowlists = new Map()
    this.slots = new Map()
    this.events = []
    this.rejectUnknownTypes = true
  }

  async start(port = 0) {
    this.server = createServer((request, response) => {
      response.writeHead(404)
      response.end()
    })
    this.server.on('upgrade', (request, socket) => this.upgrade(request, socket))
    await new Promise(resolve => this.server.listen(port, '127.0.0.1', resolve))
    this.port = this.server.address().port
    this.origin = `http://127.0.0.1:${String(this.port)}`
    return this
  }

  async stop() {
    for (const connection of [...this.connections]) connection.socket.close(1001, 'relay stopping')
    if (this.server !== undefined) await new Promise(resolve => this.server.close(resolve))
  }

  wsUrl() {
    return `ws://127.0.0.1:${String(this.port)}/`
  }

  upgrade(request, socket) {
    const key = request.headers['sec-websocket-key']
    if (typeof key !== 'string') { socket.destroy(); return }
    socket.write([
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${sha1(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)}`,
      '',
      '',
    ].join('\r\n'))
    const record = {
      socket: undefined,
      machineId: undefined,
      role: undefined,
      authenticated: false,
      challenge: { nonce: nodeRandomBytes(32), origin: this.origin },
      authTimer: setTimeout(() => {
        if (!record.authenticated) this.fail(record, 'auth_failed', 4002)
      }, 10_000),
    }
    record.socket = new ServerSocket(socket, (text, serverSocket) => this.onText(record, serverSocket, text), () => this.onClose(record))
    this.connections.add(record)
    record.socket.send(JSON.stringify({ v: 1, type: 'relay.challenge', nonce: b64urlEncode(record.challenge.nonce), relay: this.origin }))
  }

  fail(record, code, closeCode = 1008) {
    clearTimeout(record.authTimer)
    if (!record.socket.open) return
    record.socket.send(JSON.stringify({ v: 1, type: 'relay.error', code }))
    record.socket.close(closeCode, code)
    this.onClose(record)
  }

  onClose(record) {
    clearTimeout(record.authTimer)
    if (!this.connections.has(record)) return
    this.connections.delete(record)
    if (record.machineId !== undefined && this.byMachine.get(record.machineId) === record) {
      this.byMachine.delete(record.machineId)
      this.allowlists.delete(record.machineId)
    }
    for (const [rendezvous, slot] of [...this.slots]) {
      if (slot.pc === record || slot.phone === record) {
        const peer = slot.pc === record ? slot.phone : slot.pc
        if (peer !== undefined && peer.socket.open) peer.socket.send(JSON.stringify({ v: 1, type: 'relay.pair.close', rendezvous, reason: 'peer_offline' }))
        this.slots.delete(rendezvous)
      }
    }
  }

  onText(record, socket, text) {
    if (Buffer.byteLength(text, 'utf8') > MAX_FRAME_BYTES) {
      this.fail(record, 'frame_too_large', 1009)
      return
    }
    let frame
    try {
      frame = parseStrictJsonObject(text)
    } catch {
      this.fail(record, 'bad_frame', 1008)
      return
    }
    if (frame.v !== 1) { this.fail(record, 'bad_frame', 1008); return }
    if (!record.authenticated) {
      if (frame.type !== 'peer.auth') { this.fail(record, 'bad_frame', 1008); return }
      this.authenticate(record, frame)
      return
    }
    this.onAuthenticatedFrame(record, frame)
  }

  authenticate(record, frame) {
    try {
      if (frame.type !== 'peer.auth') throw new Error('expected peer.auth')
      if (typeof frame.publicKey !== 'string' || typeof frame.sig !== 'string') throw new Error('shape')
      const publicKey = b64urlDecode(frame.publicKey, { length: 32 })
      const signature = b64urlDecode(frame.sig, { length: 64 })
      if (!['phone', 'pc'].includes(frame.role)) throw new Error('role')
      const transcript = Buffer.concat([
        Buffer.from('pclink-v1/relay-auth', 'utf8'), Buffer.from([0]),
        Buffer.from(this.origin, 'utf8'), Buffer.from([0]),
        record.challenge.nonce,
      ])
      const key = createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: b64urlEncode(publicKey) }, format: 'jwk' })
      if (!verify(null, transcript, key, signature)) throw new Error('signature')
      const machineId = machineIdOf(publicKey)
      if (machineId !== frame.machineId) throw new Error('machineId')
      const existing = this.byMachine.get(machineId)
      if (existing !== undefined && existing !== record) {
        if (existing.role !== frame.role) throw new Error('role conflict')
        existing.socket.send(JSON.stringify({ v: 1, type: 'relay.error', code: 'replaced' }))
        existing.socket.close(4001, 'replaced')
        this.onClose(existing)
      }
      clearTimeout(record.authTimer)
      record.authenticated = true
      record.machineId = machineId
      record.role = frame.role
      this.byMachine.set(machineId, record)
      this.allowlists.set(machineId, new Set())
      record.socket.send(JSON.stringify({ v: 1, type: 'relay.ready', machineId, role: frame.role }))
      this.events.push({ event: 'ready', machineId, role: frame.role })
    } catch (error) {
      this.events.push({ event: 'auth-failed', reason: error.message })
      this.fail(record, 'auth_failed', 4002)
    }
  }

  target(machineId) {
    return this.byMachine.get(machineId)
  }

  onAuthenticatedFrame(record, frame) {
    try {
      switch (frame.type) {
        case 'relay.allow': {
          if (record.role !== 'pc') throw new Error('only pc')
          if (!Array.isArray(frame.peers) || frame.peers.some(peer => typeof peer !== 'string' || !/^[a-z2-7]{26}$/.test(peer))) throw new Error('allow shape')
          this.allowlists.set(record.machineId, new Set(frame.peers))
          this.events.push({ event: 'allow', machineId: record.machineId, peers: [...frame.peers] })
          return
        }
        case 'relay.ping':
          record.socket.send(JSON.stringify({ v: 1, type: 'relay.pong', nonce: frame.nonce }))
          return
        case 'relay.pong':
          return
        case 'relay.pair.open': {
          if (record.role !== 'pc') throw new Error('only pc opens')
          if (typeof frame.rendezvous !== 'string' || !/^[A-Za-z0-9_-]{22}$/.test(frame.rendezvous)) throw new Error('rendezvous')
          if (this.slots.has(frame.rendezvous)) {
            if (this.slots.get(frame.rendezvous).pc === record) return
            throw new Error('rendezvous occupied')
          }
          const active = [...this.slots.values()].filter(slot => slot.pc === record && !slot.closed).length
          if (active >= MAX_PAIR_SLOTS) throw new Error('slots')
          this.slots.set(frame.rendezvous, { pc: record, phone: undefined, joinedAt: Date.now(), joins: 0, closed: false })
          return
        }
        case 'relay.pair.join': {
          if (record.role !== 'phone') throw new Error('only phone joins')
          const slot = this.slots.get(frame.rendezvous)
          if (slot === undefined || Date.now() - slot.joinedAt > PAIR_TTL_MS) {
            if (slot !== undefined) this.slots.delete(frame.rendezvous)
            record.socket.send(JSON.stringify({ v: 1, type: 'relay.error', code: 'rendezvous_expired' }))
            return
          }
          slot.joins += 1
          if (slot.joins > MAX_JOINS || slot.phone !== undefined) {
            record.socket.send(JSON.stringify({ v: 1, type: 'relay.error', code: 'rendezvous_exhausted' }))
            this.slots.delete(frame.rendezvous)
            return
          }
          slot.phone = record
          slot.pc.socket.send(JSON.stringify({ v: 1, type: 'relay.pair.joined', rendezvous: frame.rendezvous, role: 'pc', peerMachineId: record.machineId }))
          record.socket.send(JSON.stringify({ v: 1, type: 'relay.pair.joined', rendezvous: frame.rendezvous, role: 'phone', peerMachineId: slot.pc.machineId }))
          return
        }
        case 'relay.pair.message': {
          const slot = this.slots.get(frame.rendezvous)
          if (slot === undefined) throw new Error('no slot')
          if (slot.pc !== record && slot.phone !== record) throw new Error('not joined')
          const peer = slot.pc === record ? slot.phone : slot.pc
          if (peer === undefined) throw new Error('peer not joined')
          peer.socket.send(JSON.stringify({ v: 1, type: 'relay.pair.message', rendezvous: frame.rendezvous, payload: frame.payload }))
          return
        }
        case 'relay.pair.close': {
          const slot = this.slots.get(frame.rendezvous)
          if (slot === undefined) throw new Error('no slot')
          const peer = slot.pc === record ? slot.phone : slot.pc
          if (peer !== undefined) peer.socket.send(JSON.stringify({ v: 1, type: 'relay.pair.close', rendezvous: frame.rendezvous, reason: frame.reason }))
          this.slots.delete(frame.rendezvous)
          return
        }
        case 'e2e':
        case 'e2e.handshake': {
          if (frame.type === 'e2e' && record.role === 'pc' && !this.allowlists.get(record.machineId)?.has(frame.to)) return
          if (frame.type === 'e2e.handshake') {
            const bodyType = frame.body?.type
            if (!['session.init', 'session.resp', 'session.confirm', 'session.reject'].includes(bodyType)) throw new Error('handshake body')
            if (bodyType === 'session.init' && record.role !== 'phone') throw new Error('only phone initiates')
          }
          if (frame.from !== record.machineId) frame.from = record.machineId
          const target = this.target(frame.to)
          if (target === undefined || target === record) {
            const offline = { v: 1, type: 'relay.offline', to: frame.to }
            for (const name of ['id', 'streamId', 'sid']) if (frame[name] !== undefined) offline[name] = frame[name]
            record.socket.send(JSON.stringify(offline))
            return
          }
          target.socket.send(JSON.stringify(frame))
          return
        }
        default:
          if (this.rejectUnknownTypes) throw new Error('unknown relay type')
      }
    } catch {
      this.fail(record, 'bad_frame', 1008)
    }
  }
}

// The relay derives machineId from the presented key, exactly like production.
function machineIdOf(publicKey) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
  const digest = createHash('sha256').update(publicKey).digest()
  let output = ''
  let buffer = 0
  let bits = 0
  for (const byte of digest) {
    buffer = (buffer << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      output += alphabet[(buffer >>> bits) & 31]
    }
  }
  return output.slice(0, 26).toLowerCase()
}
