// SPDX-License-Identifier: MIT
/**
 * The fixture locale is part of the oracle.
 *
 * Git translates its human-readable messages from the inherited environment,
 * so a host configured with `zh_CN.UTF-8` would make only the system git speak
 * Chinese while the Worker git keeps emitting the English source messages. The
 * byte-for-byte golden tests would then fail for a language difference rather
 * than a behavior difference. The shared fixture environment pins the C locale
 * for both implementations; this regression seeds a Chinese locale in the
 * inherited process environment and proves the system git output does not move.
 * Only the locale variables are seeded, never a system locale installation, so
 * the check also runs on a host that does not ship the Chinese catalog.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tests/fixture-locale.test
 */
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  HAS_GIT, SKIP_NO_GIT, diffResults, fixtureEnvironment, systemGit, tempDirectory,
} from './helpers.ts'
import type { CommandResult } from './helpers.ts'

const skip = HAS_GIT ? false : SKIP_NO_GIT

/** Locale variables that can select git's message language. */
const LOCALE_KEYS = ['LC_ALL', 'LC_MESSAGES', 'LANG', 'LANGUAGE'] as const
type LocaleKey = (typeof LOCALE_KEYS)[number]
type LocaleSnapshot = Record<LocaleKey, string | undefined>

/** Snapshot the inherited locale so the test can restore it exactly. */
function localeSnapshot(): LocaleSnapshot {
  return {
    LC_ALL: process.env.LC_ALL,
    LC_MESSAGES: process.env.LC_MESSAGES,
    LANG: process.env.LANG,
    LANGUAGE: process.env.LANGUAGE,
  }
}

/** Replace every locale variable; `undefined` removes it from the environment. */
function setLocale(snapshot: LocaleSnapshot): void {
  for (const key of LOCALE_KEYS) {
    const value = snapshot[key]
    if (value === undefined) delete process.env[key]
    else process.env[key] = value
  }
}

/** A neutral inherited environment: every message-selecting variable is C. */
const NEUTRAL_INHERITED_LOCALE: LocaleSnapshot = {
  LC_ALL: 'C',
  LC_MESSAGES: 'C',
  LANG: 'C',
  LANGUAGE: undefined,
}

/**
 * The reported PR environment. The values are only strings, so this test does
 * not require the locale to be installed; where it is installed, a missing C
 * pin makes the system git translate and the comparison fails.
 */
const CHINESE_INHERITED_LOCALE: LocaleSnapshot = {
  LC_ALL: 'zh_CN.UTF-8',
  LC_MESSAGES: 'zh_CN.UTF-8',
  LANG: 'zh_CN.UTF-8',
  LANGUAGE: 'zh_CN',
}

test('the shared fixture environment pins the system git to the C locale', { skip }, () => {
  const temp = tempDirectory()
  const saved = localeSnapshot()
  try {
    const environment = fixtureEnvironment(temp.path)
    assert.equal(environment.env.LC_ALL, 'C', 'the fixture environment requests the C locale')

    const repository = join(temp.path, 'repository')
    mkdirSync(repository)
    const git = (args: readonly string[]): CommandResult => systemGit(args, repository, environment.env)
    const init = git(['init', '-q', '-b', 'main'])
    assert.equal(init.code, 0, init.stderr.toString())
    writeFileSync(join(repository, 'staged.txt'), 'staged\n')
    writeFileSync(join(repository, 'changed.txt'), 'changed\n')
    const add = git(['add', 'staged.txt'])
    assert.equal(add.code, 0, add.stderr.toString())
    writeFileSync(join(repository, 'changed.txt'), 'changed again\n')
    writeFileSync(join(repository, 'untracked.txt'), 'untracked\n')

    // One translated stdout message and one translated fatal stderr message,
    // matching the two shapes whose language broke the oracle in the PR run.
    const commands: readonly (readonly string[])[] = [
      ['status'],
      ['ls-files', '-z', '--', ':(glob)nope*'],
    ]
    for (const args of commands) {
      const label = args.join(' ')
      setLocale(NEUTRAL_INHERITED_LOCALE)
      const neutral = git(args)
      setLocale(CHINESE_INHERITED_LOCALE)
      const chineseInherited = git(args)
      const difference = diffResults(neutral, chineseInherited)
      assert.equal(difference, undefined, `${label}: fixture locale ignores an inherited Chinese locale: ${difference}`)
      const output = `${chineseInherited.stdout.toString('latin1')}${chineseInherited.stderr.toString('latin1')}`
      assert.doesNotMatch(output, /[^\x00-\x7F]/, `${label}: the fixture emits English messages, not translated ones`)
    }
  } finally {
    setLocale(saved)
    temp.cleanup()
  }
})
