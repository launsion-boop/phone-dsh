// SPDX-License-Identifier: MIT
/**
 * Injection points the DSH worker plugins read from the worker global scope.
 * The owner sets them once the channel is connected; changing the channel
 * object is not supported.
 * @module @phone-dsh/dsh-channel/global
 */
import type { ChannelClient } from './client.ts'
import type { FencePayload, LifecyclePayload } from './payloads.ts'

declare global {
  /** The ordered channel, installed before any DSH plugin loads. */
  var __PDSH_CHANNEL__: ChannelClient | undefined
  /** Latest LIFECYCLE payload received from the host. */
  var __PDSH_LIFECYCLE__: LifecyclePayload | undefined
  /** Latest FENCE payload received from the host. */
  var __PDSH_FENCE__: FencePayload | undefined
}

export {}
