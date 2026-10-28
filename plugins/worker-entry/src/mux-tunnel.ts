// SPDX-License-Identifier: MIT
/**
 * Production mux sessions: drive the DSH gateway's in-process stream opener
 * from the Worker runtime's tunnel lane.
 *
 * The Worker runtime registers `/api/remote.mux` as an HTTP upgrade route, but
 * its `ws` module is a deliberate not-implemented proxy and the fake HTTP
 * server never emits `upgrade`; a WebSocket can therefore not be opened inside
 * the Worker. The runtime's page tunnel already exposes the exact handler the
 * mux server calls for every decoded frame: `stream-open`, `stream-uplink-item`,
 * `stream-uplink-end` and `abort` reach `typertGateway.wireStream.open`, which
 * is also what `RemoteStreamMuxServer` uses after a WebSocket upgrade.
 *
 * This module maps the DSH mux client/server frames onto those tunnel frames.
 * Tunnel ids are namespaced with the logical mux id and a per-session
 * generation so concurrent mux sessions, a reopened mux id, and the page's own
 * tunnel requests cannot collide. No DSH source is copied or patched; the
 * runtime owns the stream handler and its lifecycle.
 * @module @phone-dsh/dsh-worker-entry/mux-tunnel
 */
import type {
  WorkerEntryMuxClientFrame,
  WorkerEntryMuxServerFrame,
  WorkerEntryMuxSession,
  WorkerEntryMuxSessionFactory,
} from './mux-bridge.ts'

/** Port the runtime tunnel uses to post frames to the page. */
export interface WorkerEntryTunnelPort {
  postMessage(message: unknown, transfer?: Transferable[]): void
  /** Observe outbound tunnel frames in order (used for mux stream frames). */
  subscribe(listener: (message: unknown) => void): () => void
}

/** Faces one tunnel-backed mux session needs. */
export interface WorkerEntryTunnelMuxOptions {
  /** Feed one frame to the runtime host (`TunnelServer.handleMessage`). */
  handleHostMessage(message: unknown): void
  /** Outbound tunnel frames. */
  readonly tunnel: Pick<WorkerEntryTunnelPort, 'subscribe'>
  /** Tunnel id prefix; defaults to `pdsh-mux:`. */
  readonly streamIdPrefix?: string
}

/** Build the page tunnel port the runtime host posts through. */
export function createTunnelPort(post: (message: unknown) => void): WorkerEntryTunnelPort {
  const listeners = new Set<(message: unknown) => void>()
  return {
    postMessage(message: unknown): void {
      for (const listener of [...listeners]) {
        try {
          listener(message)
        } catch (error) {
          console.debug('worker entry: tunnel frame listener failed', error)
        }
      }
      post(message)
    },
    subscribe(listener: (message: unknown) => void): () => void {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    },
  }
}

/**
 * Build the production session factory over the runtime's in-process stream
 * handler. One session exists per `x-pdsh-mux-id`; each session gets its own
 * tunnel namespace so a reopened mux id cannot collide with late frames from
 * the closed one.
 */
export function createTunnelMuxSessionFactory(
  options: WorkerEntryTunnelMuxOptions,
): WorkerEntryMuxSessionFactory {
  let generation = 0
  return (muxId) => {
    generation += 1
    return new TunnelMuxSession(muxId, generation, options)
  }
}

class TunnelMuxSession implements WorkerEntryMuxSession {
  private readonly prefix: string
  private readonly options: WorkerEntryTunnelMuxOptions
  private readonly openStreams = new Set<string>()
  private readonly listeners = new Set<(frame: WorkerEntryMuxServerFrame) => void>()
  private readonly unsubscribe: () => void
  private closed = false

  constructor(muxId: string, generation: number, options: WorkerEntryTunnelMuxOptions) {
    this.options = options
    this.prefix = `${options.streamIdPrefix ?? 'pdsh-mux:'}${muxId}:${generation}:`
    this.unsubscribe = options.tunnel.subscribe((message) => { this.receive(message) })
  }

  send(frame: WorkerEntryMuxClientFrame): void {
    if (this.closed) throw new Error('the mux session is closed')
    switch (frame.type) {
      case 'open': {
        if (this.openStreams.has(frame.streamId)) {
          throw new Error(`duplicate mux stream ${JSON.stringify(frame.streamId)}`)
        }
        this.openStreams.add(frame.streamId)
        this.dispatch(frame.streamId, {
          t: 'stream-open',
          id: this.tunnelId(frame.streamId),
          endpoint: frame.endpoint,
          payload: frame.payload,
        })
        return
      }
      case 'item': {
        if (!this.openStreams.has(frame.streamId)) return
        const message: Record<string, unknown> = {
          t: 'stream-uplink-item',
          id: this.tunnelId(frame.streamId),
        }
        if (frame.value !== undefined) message['value'] = frame.value
        this.dispatch(frame.streamId, message)
        return
      }
      case 'end': {
        if (!this.openStreams.delete(frame.streamId)) return
        this.dispatch(frame.streamId, { t: 'stream-uplink-end', id: this.tunnelId(frame.streamId) })
        return
      }
      case 'cancel': {
        if (!this.openStreams.delete(frame.streamId)) return
        this.dispatch(frame.streamId, { t: 'abort', id: this.tunnelId(frame.streamId) })
        return
      }
    }
  }

  onFrame(listener: (frame: WorkerEntryMuxServerFrame) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    for (const streamId of [...this.openStreams]) {
      try {
        this.options.handleHostMessage({ t: 'abort', id: this.tunnelId(streamId) })
      } catch {
        // The host is gone; cleanup still drops the mapping and listeners.
      }
    }
    this.openStreams.clear()
    this.unsubscribe()
    this.listeners.clear()
  }

  private tunnelId(streamId: string): string {
    return `${this.prefix}${streamId}`
  }

  private dispatch(streamId: string, message: unknown): void {
    try {
      this.options.handleHostMessage(message)
    } catch (error) {
      this.openStreams.delete(streamId)
      this.emit({
        type: 'error',
        streamId,
        error: {
          code: 'gateway/carrier',
          message: error instanceof Error ? error.message : String(error),
          details: {},
        },
      })
    }
  }

  private receive(message: unknown): void {
    if (this.closed || !isRecord(message)) return
    const type = message['t']
    const id = message['id']
    if (typeof id !== 'string' || !id.startsWith(this.prefix)) return
    const streamId = id.slice(this.prefix.length)
    if (!this.openStreams.has(streamId)) return
    if (type === 'stream-item') {
      this.emit(message['value'] !== undefined
        ? { type: 'item', streamId, value: message['value'] }
        : { type: 'item', streamId })
      return
    }
    if (type === 'stream-end') {
      this.openStreams.delete(streamId)
      this.emit({ type: 'end', streamId })
      return
    }
    if (type === 'stream-error') {
      this.openStreams.delete(streamId)
      this.emit({ type: 'error', streamId, error: failureOf(message['failure']) })
    }
  }

  private emit(frame: WorkerEntryMuxServerFrame): void {
    for (const listener of [...this.listeners]) {
      try {
        listener(frame)
      } catch (error) {
        console.debug('worker entry: mux session listener failed', error)
      }
    }
  }
}

function failureOf(value: unknown): { code: string; message: string; details: object } {
  if (!isRecord(value)) {
    return { code: 'gateway/carrier', message: 'the Remote stream failed', details: {} }
  }
  const code = typeof value['code'] === 'string' ? value['code'] : 'gateway/carrier'
  const message = typeof value['message'] === 'string' ? value['message'] : 'the Remote stream failed'
  const details = isRecord(value['details']) ? value['details'] : {}
  if (value['kind'] === 'remote') return { code, message, details }
  return { code: 'gateway/carrier', message, details: {} }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
