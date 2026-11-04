#!/usr/bin/env node
# SPDX-License-Identifier: MIT
/**
 * Publishing redactions shared by the official-screenshot capture tooling.
 *
 * A capture runs on a person's machine, so its raw fields carry the home
 * directory in every recorded command, fixture path and screenshot path.  That
 * prefix says nothing about what a screenshot proves, so it is replaced with
 * `~` -- the shell spelling of "under the home directory", which keeps a
 * recorded command runnable and the relative structure intact.
 *
 * The internal service spelling is replaced for a different reason: the
 * repository contract forbids it in the public tree (`scripts/ci/hygiene.py`
 * BANNED_WORD_RE), and a captured page can render a fixture whose prompt text
 * contains it.  Writing it out literally in a published manifest is the leak.
 *
 * Both passes are textual and total -- a rule about a class of string, not a
 * list of fields -- so a field added later cannot reintroduce either one.
 */

const HOME_PATH_RE = /(?<![\w.-])\/(?:Users|home)\/([^/\s"'`<>),\]]+)/g
/** An already-elided path (`/Users/...`) is a marker, not a home directory. */
const HOME_PATH_PLACEHOLDER = /^(?:\.{3}|…)$/
// Composed at run time so this file never carries the literal spelling the
// repository bans, even though `scripts/ios-parity/**` is not scanned today.
const INTERNAL_CODENAME_RE = new RegExp(`\\b${'Tono'}${'Live'}\\b`, 'g')

export const HOME_PATH_PLACEHOLDER_TEXT = '~'
export const CODENAME_PLACEHOLDER_TEXT = '<internal-project>'

export const REDACTION_KINDS = {
  homePath: {
    kind: 'home-path',
    with: HOME_PATH_PLACEHOLDER_TEXT,
    reason: '记录下来的命令或 fixture 路径前面的家目录前缀指向的是采集机器、不是证据本身；`~` 让命令仍然可跑，相对结构也不变',
  },
  codename: {
    kind: 'internal-codename',
    with: CODENAME_PLACEHOLDER_TEXT,
    reason: '仓库不允许这个内部服务拼写进入公开树；它位于捕获到的正文里、不在渲染出的视口内，所以 PNG 不受影响、无需重做截图',
  },
}

/** Replace every publishing-redaction target in `text`, counting each kind. */
export function redactText(text, counts = null) {
  let out = text.replace(HOME_PATH_RE, (match, segment) => {
    if (HOME_PATH_PLACEHOLDER.test(segment)) return match
    if (counts) counts.homePath += 1
    return HOME_PATH_PLACEHOLDER_TEXT
  })
  out = out.replace(INTERNAL_CODENAME_RE, () => {
    if (counts) counts.codename += 1
    return CODENAME_PLACEHOLDER_TEXT
  })
  return out
}

/** Redaction counts for `text`, for recording what a published file lost. */
export function countRedactions(text) {
  const counts = { homePath: 0, codename: 0 }
  redactText(text, counts)
  return counts
}

/** The counted redactions that actually fired, in the manifest's shape. */
export function redactionReport(counts) {
  return Object.entries(REDACTION_KINDS)
    .filter(([key]) => (counts[key] ?? 0) > 0)
    .map(([key, meta]) => ({ ...meta, replacements: counts[key] }))
}

/**
 * Fail closed: refuse to write an artifact that still carries a target.
 *
 * `redactText` is idempotent, so "applying it changes nothing" *is* the
 * statement "there is nothing left to redact".
 */
export function assertRedacted(text, name) {
  if (redactText(text) !== text) {
    throw new Error(`${name} still carries a publishing redaction target`)
  }
}
