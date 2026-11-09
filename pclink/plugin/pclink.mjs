/**
 * The PCLink PC runtime: durable state, relay supervision, pairing, E2E
 * sessions, forwarding and the two admin carriers.
 */
import { join } from 'node:path'
import { pclinkError } from '../core/errors.mjs'
import { b64urlEncode } from '../core/encoding.mjs'
import { loadAdminFile, pclinkStateDir, probeAuditAppend, removeFile } from '../core/store.mjs'
import { AdminPlane } from './admin-plane.mjs'
import { AdminServer } from './admin-server.mjs'
import { dshRuntimeInfo } from './dsh-info.mjs'
import { PairingManager } from './pairing-manager.mjs'
import { RelayLink } from './relay-link.mjs'
import { SessionManager } from './session-manager.mjs'
import { PclinkStore } from './state.mjs'

/** Plugin version reported in `peer.hello.app.version`. */
export const PLUGIN_VERSION = '0.1.0'
/** Fail-closed probe retry interval. */
export const FAIL_CLOSED_RETRY_MS = 5_000

/**
 * The PC plugin runtime. `start()` is async because the admin listener binds
 * before the relay is dialed; every later relay event is handled synchronously.
 */
export class PclinkRuntime {
  /**
   * @param {{
   *   connection: object,
   *   gateway: object,
   *   dshHome: string,
   *   relayOrigin: string,
   *   pcName: string,
   *   log?: (...args: unknown[]) => void,
   *   WebSocketCtor?: typeof WebSocket,
   *   timers?: {setTimeout: Function, clearTimeout: Function, now: () => number},
   *   random?: () => number,
   *   dshInfo?: {version: string, commit?: string},
   *   appVersion?: string,
   *   probeAudit?: (dir: string) => void,
   * }} options Runtime dependencies and config.
   */
  constructor(options) {
    this.connection = options.connection
    this.gateway = options.gateway
    this.dshHome = options.dshHome
    this.relayOrigin = options.relayOrigin
    this.pcName = options.pcName
    this.log = options.log ?? (() => {})
    this.timers = options.timers ?? {
      setTimeout: (fn, ms) => setTimeout(fn, ms),
      clearTimeout: handle => clearTimeout(handle),
      now: () => Date.now(),
    }
    this.random = options.random ?? Math.random
    this.WebSocketCtor = options.WebSocketCtor
    this.dshInfo = options.dshInfo ?? dshRuntimeInfo(this.log)
    this.appVersion = options.appVersion ?? PLUGIN_VERSION
    this.probeAudit = options.probeAudit ?? probeAuditAppend
    this.stateDir = pclinkStateDir(this.dshHome)
    this.warnings = []
    this.failClosed = false
    this.failClosedWarning = undefined
    this.auditProbeError = undefined
    this.pendingTombstones = []
    this.failClosedTimer = undefined
    this.started = false
    this.stopped = false
    this.store = undefined
    this.link = undefined
    this.pairing = undefined
    this.sessions = undefined
    this.adminPlane = undefined
    this.adminServer = undefined
    if (this.relayOrigin === 'https://relay.example.invalid') {
      this.warnings.push('PCLINK_RELAY_URL 仍是占位值 wss://relay.example.invalid；安装前必须替换为正式中继。')
    }
  }

  /** Start the admin carrier, then the relay supervisor. */
  async start() {
    if (this.started) return
    this.started = true
    this.store = new PclinkStore({ dir: this.stateDir, log: this.log }).load()
    this.warnings.push(...this.store.warnings)
    if (this.store.identity === undefined) throw new Error('PCLink identity was not loaded')
    this.link = new RelayLink({
      origin: this.relayOrigin,
      identity: this.store.identity,
      allowlist: () => this.store.allowlist(),
      onFrame: frame => this.handleRelayFrame(frame),
      onState: state => this.handleRelayState(state),
      WebSocketCtor: this.WebSocketCtor,
      timers: this.timers,
      random: this.random,
      log: this.log,
      canConnect: () => !this.failClosed && !this.stopped,
    })
    this.pairing = new PairingManager({
      store: this.store,
      send: frame => this.link.send(frame),
      relayOrigin: this.relayOrigin,
      pcName: this.pcName,
      timers: this.timers,
      onCompleted: record => this.handlePairingCompleted(record),
      onFailure: (code, message) => this.log(`pairing failure ${code}: ${message}`),
      log: this.log,
    })
    this.sessions = new SessionManager({
      connection: this.connection,
      gateway: this.gateway,
      store: this.store,
      link: this.link,
      pcName: this.pcName,
      appVersion: this.appVersion,
      dsh: this.dshInfo,
      timers: this.timers,
      log: this.log,
      onOnlineChange: () => {},
      onPeerUnpaired: peerMachineId => this.unpairFromPhone(peerMachineId),
    })
    this.adminPlane = new AdminPlane({
      store: this.store,
      pairing: this.pairing,
      sessions: this.sessions,
      relay: { origin: this.relayOrigin, state: 'offline' },
      unpair: body => this.unpair(body),
      rotateIdentity: body => this.rotateIdentity(body),
      extraWarnings: () => [
        ...this.warnings,
        ...(this.failClosedWarning === undefined ? [] : [this.failClosedWarning]),
        ...this.sessions.versionWarnings,
      ],
    })
    this.adminServer = new AdminServer({ dir: this.stateDir, plane: this.adminPlane, log: this.log, random: this.random })
    await this.adminServer.start()
    // §4.6: a tombstone append that failed must keep the whole plugin off the
    // relay until a later append succeeds, including across a restart. Probe
    // the append+fsync path before dialing; the admin server still starts so
    // `status` can report the storage failure.
    if (!this.checkAuditWritable()) {
      this.failClosed = true
      this.failClosedWarning = this.auditProbeError
      this.log(`startup fail-closed: ${this.auditProbeError}`)
      this.scheduleFailClosedRetry()
    } else {
      this.link.start()
    }
  }

  /**
   * Probe `pairs.log` append+fsync. A failure keeps the plugin fail-closed.
   * @returns {boolean} true when the audit log is writable now.
   */
  checkAuditWritable() {
    try {
      this.probeAudit(this.stateDir)
      this.auditProbeError = undefined
      return true
    } catch (error) {
      this.auditProbeError = `pairs.log 无法追加并 fsync（${error.message}）；插件保持 fail-closed，未连接中继。`
      return false
    }
  }

  handleRelayState(state) {
    if (this.adminPlane !== undefined) this.adminPlane.relay = { origin: this.relayOrigin, state: state.state }
    if (state.state === 'offline') {
      this.pairing?.handleRelayDown()
      this.sessions?.handleRelayDown()
    }
  }

  handleRelayFrame(frame) {
    try {
      switch (frame.type) {
        case 'relay.pair.joined':
        case 'relay.pair.message':
        case 'relay.pair.close':
          this.pairing.handleFrame(frame)
          return
        case 'relay.offline':
          this.sessions.handleRelayOffline(frame)
          return
        case 'relay.error':
          this.log(`relay error ${String(frame.code)} ${String(frame.message ?? '')}`)
          if (frame.code === 'rendezvous_expired' || frame.code === 'rendezvous_exhausted') this.pairing.handleRelayError(frame.code)
          return
        case 'e2e.handshake':
          this.sessions.handleHandshake(frame)
          return
        case 'e2e':
          this.sessions.handleE2e(frame)
          return
        default:
          this.log(`ignoring relay frame ${String(frame.type)}`)
      }
    } catch (error) {
      this.log(`relay frame handler failed: ${error.message}`)
    }
  }

  handlePairingCompleted(record) {
    this.log(`new pairing recorded name=${record.peerName} machine=${record.peerMachineId}`)
    try {
      this.sessions.notifyPaired(record)
    } catch (error) {
      this.log(`paired notice failed: ${error.message}`)
    }
    this.link?.sendAllowlist()
  }

  /** Phone-initiated unpair: authoritative tombstone path on the PC. */
  unpairFromPhone(peerMachineId) {
    try {
      this.unpair({ peerMachineId }, { fromPhone: true })
    } catch (error) {
      this.log(`phone-initiated unpair was not durable: ${error.message}`)
    }
  }

  /**
   * Revoke one/all pairings: abort sessions/handshakes, tombstone, remove, allowlist.
   * @param {{peerMachineId?: string, all?: true}} body Admin request.
   * @param {{fromPhone?: boolean}} [options] Internal carrier flag.
   * @returns {{v: 1, removed: string[]}} response.
   */
  unpair(body, options = {}) {
    if (body === null || typeof body !== 'object' || Array.isArray(body)) throw pclinkError('bad_frame', 'unpair body must be an object')
    let targets
    if (body.all === true) {
      targets = [...this.store.records.map(record => record.peerMachineId)]
    } else if (typeof body.peerMachineId === 'string') {
      targets = [body.peerMachineId]
    } else {
      throw pclinkError('bad_frame', 'unpair requires peerMachineId or all:true')
    }
    for (const peerMachineId of targets) this.sessions.abortPeer(peerMachineId, { sendClose: !options.fromPhone })
    let removed
    try {
      removed = this.store.unpair(targets)
    } catch (error) {
      this.enterFailClosed(targets)
      throw pclinkError('unavailable', `unpair tombstone failed; the plugin is off the relay: ${error.message}`)
    }
    this.link?.sendAllowlist()
    this.log(`unpair removed=${removed.join(',')}`)
    return { v: 1, removed }
  }

  /**
   * Enter the fail-closed state after a tombstone/probe failure and retry it.
   * @param {string[]} targets Peers whose tombstones must be durable.
   */
  enterFailClosed(targets) {
    this.failClosed = true
    this.pendingTombstones = [...new Set([...this.pendingTombstones, ...targets])]
    this.failClosedWarning = this.auditProbeError
      ?? 'pairs.log 的 tombstone 写入失败；插件保持 fail-closed，未连接中继，直到写入成功。'
    this.link?.stop()
    this.log('fail-closed: audit append failed; relay connection stopped')
    this.scheduleFailClosedRetry()
  }

  /** Schedule the next probe/retry of the fail-closed gate (idempotent). */
  scheduleFailClosedRetry() {
    if (this.failClosedTimer !== undefined || this.stopped) return
    const retry = () => {
      this.failClosedTimer = undefined
      if (this.stopped) return
      if (!this.checkAuditWritable()) {
        this.failClosedWarning = this.auditProbeError
        this.log(`fail-closed retry: ${this.auditProbeError}`)
        this.scheduleFailClosedRetry()
        return
      }
      try {
        if (this.pendingTombstones.length > 0) this.store.unpair(this.pendingTombstones)
      } catch (error) {
        this.failClosedWarning = `pairs.log 的 tombstone 重试失败（${error.message}）；插件保持 fail-closed。`
        this.log(`fail-closed retry failed: ${error.message}`)
        this.scheduleFailClosedRetry()
        return
      }
      this.pendingTombstones = []
      this.failClosed = false
      this.failClosedWarning = undefined
      this.link?.start()
      this.log('fail-closed cleared: audit append succeeded; reconnecting the relay')
    }
    this.failClosedTimer = this.timers.setTimeout(retry, FAIL_CLOSED_RETRY_MS)
    this.failClosedTimer?.unref?.()
  }

  /**
   * Rotate the PC identity after the literal confirmation.
   * @param {{confirm?: string}} body Admin request.
   * @returns {{v: 1, rotated: true, oldMachineId: string, newMachineId: string}} response.
   */
  rotateIdentity(body) {
    if (body?.confirm !== 'rotate-identity') throw pclinkError('bad_frame', 'rotate-identity requires confirm:"rotate-identity"')
    this.pairing.dispose()
    this.sessions.abortAllHandshakes()
    for (const session of [...this.sessions.sessions.values()]) {
      this.sessions.closeSession(session, 'unpaired', 'PC identity rotated', { sendClose: true })
    }
    const { oldMachineId, newMachineId } = this.store.rotateIdentity()
    this.link.identity = this.store.identity
    this.link.sendAllowlist()
    this.link.restart()
    this.log(`identity rotated ${oldMachineId} -> ${newMachineId}`)
    return { v: 1, rotated: true, oldMachineId, newMachineId }
  }

  /**
   * @param {Request} request DSH owner `/api` request.
   * @param {'status'|'pair'|'pair/approve'|'pair/cancel'|'unpair'|'rotate-identity'} operation Route operation.
   * @returns {Promise<Response>} response.
   */
  handleAdminHttp(request, operation) {
    return this.adminPlane.handleFetch(request, { operation, via: 'webui' })
  }

  /** Stop every connection, stream and listener. */
  async stop() {
    if (this.stopped) return
    this.stopped = true
    if (this.failClosedTimer !== undefined) this.timers.clearTimeout(this.failClosedTimer)
    this.pairing?.dispose()
    this.sessions?.closeAll()
    this.link?.stop()
    if (this.adminServer !== undefined) {
      const port = this.adminServer.port
      const tokenText = this.adminServer.tokenText
      await this.adminServer.stop()
      try {
        const current = loadAdminFile(this.stateDir)
        if (current !== undefined && current.port === port && current.token === tokenText) {
          removeFile(join(this.stateDir, 'admin.json'))
        }
      } catch {
        // A malformed admin.json is left for the CLI's "plugin not running" path.
      }
    }
  }

  /** Test/status helper: current admin identity facts. */
  identityFacts() {
    return {
      machineId: this.store.identity.machineId,
      publicKey: b64urlEncode(this.store.identity.publicKey),
      name: this.pcName,
    }
  }
}
