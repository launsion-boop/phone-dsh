// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { BotStreamHub } from './channel.ts'

const STREAM_HUB_SERVICE = 'dshbotStreamHub'

export function registerBotStreamHub(ctx: Context, hub: BotStreamHub): void {
  ctx.provide(STREAM_HUB_SERVICE, hub)
}

export function botStreamHub(ctx: Context): BotStreamHub | undefined {
  return ctx.get(STREAM_HUB_SERVICE) as BotStreamHub | undefined
}

export const botHiddenSessions = new Set<string>()
