/**
 * Marks in-process DSH requests dispatched by a PCLink remote Peer.
 *
 * The DSH exact-fetch route API hands the handler only a Request; the source
 * Peer is the one passed to `createSharedFetchHandler().fetch(request, peer)`.
 * The forwarder runs that call inside this AsyncLocalStorage scope, so the
 * `/api/pclink.admin/*` handler can make the authoritative source-Peer
 * decision without trusting an endpoint or path string.
 */
import { AsyncLocalStorage } from 'node:async_hooks'

const storage = new AsyncLocalStorage()

/**
 * Run one forwarder call as a PCLink remote dispatch.
 * @template T
 * @param {() => T} callback Work to run.
 * @returns {T} callback result.
 */
export function runAsPclinkRemote(callback) {
  return storage.run({ remote: true }, callback)
}

/**
 * Whether the current in-process dispatch came from a PCLink remote Peer.
 * @returns {boolean} true inside {@link runAsPclinkRemote}.
 */
export function isPclinkRemoteRequest() {
  return storage.getStore()?.remote === true
}
