// SPDX-License-Identifier: MIT
/**
 * Truth gate for the AGENTS.md byte cap (P24).
 *
 * The 4 KiB cap was silently dropping the tail of the injected instruction file
 * on the device (`Bash deviations`, `Restart and recovery`, `Manifest`, and the
 * refusal rule that explains the sandbox decorations). Raising the cap to 5 KiB
 * fixed that boot, but a fixed number only postpones the next overflow: the
 * command and Python tables grow. These tests pin the property that must hold at
 * *any* cap — a truncated document names what it dropped, and it names it inside
 * its own byte budget.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  AGENTS_MD_MAX_BYTES,
  CAPABILITIES_JSON_PATH,
  buildCapabilityManifest,
  clampMarkdown,
  truncationNote,
  type CapabilityManifestInput,
} from './capabilities.ts'

/** A minimal manifest input; every list is supplied by the caller. */
function manifestInput(overrides: Partial<CapabilityManifestInput> = {}): CapabilityManifestInput {
  return { commands: ['bash', 'cat', 'tar'], ...overrides }
}

/**
 * The injected `/dsh/home/AGENTS.md` measured on the device during P24: the
 * **full** document is 5538 B. (Under the old 5 KiB cap the file was 5055 B —
 * that was the compact shape, i.e. the fallback below had already engaged
 * silently.) The budget must keep a margin over the real document so a new
 * module does not push a rule out.
 */
const MEASURED_DEVICE_AGENTS_MD_BYTES = 5538

/** Five sections, each big enough that a small cap cannot keep them all. */
function sectionedDocument(): string {
  const body = 'x'.repeat(200)
  return ['# Title', 'intro', ...Array.from({ length: 5 }, (_, index) => `## Section ${String(index)}\n${body}`)]
    .join('\n')
}

test('a document inside the budget is returned byte-for-byte', () => {
  const text = sectionedDocument()
  assert.equal(clampMarkdown(text, 4096), text)
  assert.doesNotMatch(clampMarkdown(text, 4096), /truncated/u)
})

test('an overflowing document names the dropped sections and the byte budget', () => {
  const clamped = clampMarkdown(sectionedDocument(), 700)
  assert.ok(Buffer.byteLength(clamped, 'utf8') <= 700, `the cap still holds (${String(Buffer.byteLength(clamped, 'utf8'))} B)`)
  const note = clamped.slice(clamped.indexOf('[truncated to '))
  assert.match(note, /^\[truncated to 700 B: dropped 2 sections: Section 3, Section 4; part of "Section 2"; /u)
  assert.ok(note.includes(CAPABILITIES_JSON_PATH))
  // The sections that survived are not named as dropped.
  assert.doesNotMatch(note, /Section [01]/u)
})

test('a cut inside a section also reports the partial section', () => {
  const text = ['## Alpha', 'a'.repeat(300), '## Beta', 'b'.repeat(300)].join('\n')
  const clamped = clampMarkdown(text, 400)
  assert.ok(Buffer.byteLength(clamped, 'utf8') <= 400)
  assert.match(clamped, /\[truncated to 400 B: dropped \d+ section/u)
  assert.ok(clamped.includes('"Alpha"'), 'the section the cut landed in is named')
})

test('the note is stable: the same input produces the same bytes', () => {
  const text = sectionedDocument()
  assert.equal(clampMarkdown(text, 700), clampMarkdown(text, 700))
})

test('a pathological cap still returns inside the cap instead of throwing', () => {
  for (const cap of [1, 16, 60, 120]) {
    const clamped = clampMarkdown(sectionedDocument(), cap)
    assert.ok(Buffer.byteLength(clamped, 'utf8') <= cap, `cap ${String(cap)} holds`)
  }
})

test('truncationNote counts and names what was removed', () => {
  assert.equal(
    truncationNote(['A', 'B'], undefined, 5120),
    `\n[truncated to 5120 B: dropped 2 sections: A, B; the machine-readable lists are in ${CAPABILITIES_JSON_PATH}]\n`,
  )
  assert.equal(
    truncationNote(['A'], 'B', 5120),
    `\n[truncated to 5120 B: dropped 1 section: A; part of "B"; the machine-readable lists are in ${CAPABILITIES_JSON_PATH}]\n`,
  )
  assert.equal(
    truncationNote([], 'B', 5120),
    `\n[truncated to 5120 B: dropped the tail of "B"; the machine-readable lists are in ${CAPABILITIES_JSON_PATH}]\n`,
  )
})

test('the budget keeps headroom over the measured device document', () => {
  const headroom = AGENTS_MD_MAX_BYTES - MEASURED_DEVICE_AGENTS_MD_BYTES
  assert.ok(
    headroom >= 512,
    `the full AGENTS.md was 5538 B on the device; the ${String(AGENTS_MD_MAX_BYTES)} B cap leaves `
      + `${String(headroom)} B, which must stay above 512 B so the next command/module does not truncate a rule`,
  )
})

test('the production-shaped document fits the cap, and an overflowing one is no longer silent', () => {
  const commands = Array.from({ length: 91 }, (_, index) => `program-${String(index)}`)
  const pythonModules = Array.from({ length: 182 }, (_, index) => `module_${String(index)}`)
  const fits = buildCapabilityManifest(manifestInput({
    commands,
    pythonModules,
    python: { available: true, version: '3.13' },
    egressAllow: ['api.deepseek.com'],
  }))
  assert.ok(Buffer.byteLength(fits.markdown, 'utf8') <= AGENTS_MD_MAX_BYTES)
  assert.doesNotMatch(
    fits.markdown,
    /\[truncated to \d+ B: /u,
    'the real surface fits: no note, nothing silently missing',
  )
  // A surface the budget cannot hold must say so, in the document itself. The
  // cap is derived from the document (not from AGENTS_MD_MAX_BYTES) so this
  // stays an overflow test when the budget grows for a new section.
  const tightCap = Buffer.byteLength(fits.markdown, 'utf8') + 150
  const over = clampMarkdown(`${fits.markdown}\n## Extra\n${'y'.repeat(1500)}\n`, tightCap)
  assert.ok(Buffer.byteLength(over, 'utf8') <= tightCap)
  assert.match(over, /\[truncated to \d+ B: /u)
  // Whether the cut lands inside `Extra` (partial) or after it (fully dropped),
  // the note has to name it — a generic "shortened" would not.
  assert.ok(over.slice(over.indexOf('[truncated to ')).includes('Extra'), 'the dropped section is named')
})
