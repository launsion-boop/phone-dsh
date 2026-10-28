// SPDX-License-Identifier: MIT
/**
 * Line-based text diff: Myers' algorithm, unified hunks and the numstat
 * counters. `git diff`, `git diff-tree --numstat` and the rename-similarity
 * estimate all sit on this module; it works on bytes, so a non-UTF-8 file is
 * diffed the same way git diffs it (unless it is binary).
 * @module @phone-dsh/dsh-wasi-toolbox/git/textdiff
 */
import { compareBytes, encodeText } from './fs.ts'

/** One line of a file, including its terminator when the file has one. */
export interface TextLine {
  readonly bytes: Uint8Array
  /** True when this is the final line and the file does not end with '\n'. */
  readonly missingNewline: boolean
}

/** One edit operation. */
export interface DiffOp {
  readonly type: 'equal' | 'insert' | 'delete'
  /** Zero-based line index on the old side (equal/delete). */
  readonly oldIndex?: number
  /** Zero-based line index on the new side (equal/insert). */
  readonly newIndex?: number
}

/** Split bytes into lines, keeping the terminator. */
export function splitLines(data: Uint8Array): TextLine[] {
  const lines: TextLine[] = []
  let start = 0
  for (let index = 0; index < data.byteLength; index += 1) {
    if (data[index] === 0x0a) {
      lines.push({ bytes: data.subarray(start, index + 1), missingNewline: false })
      start = index + 1
    }
  }
  if (start < data.byteLength) lines.push({ bytes: data.subarray(start), missingNewline: true })
  return lines
}

/** Git's binary heuristic: a NUL byte in the first 8000 bytes. */
export function isBinary(data: Uint8Array): boolean {
  const limit = Math.min(8000, data.byteLength)
  for (let index = 0; index < limit; index += 1) if (data[index] === 0) return true
  return false
}

function equals(left: TextLine, right: TextLine): boolean {
  return left.missingNewline === right.missingNewline && compareBytes(left.bytes, right.bytes) === 0
}

/** Trim the common prefix and suffix so Myers only sees the changed middle. */
function trim(oldLines: readonly TextLine[], newLines: readonly TextLine[]): {
  prefix: number
  suffix: number
  oldMiddle: readonly TextLine[]
  newMiddle: readonly TextLine[]
} {
  let prefix = 0
  while (prefix < oldLines.length && prefix < newLines.length
    && equals(oldLines[prefix] as TextLine, newLines[prefix] as TextLine)) prefix += 1
  let suffix = 0
  while (suffix < oldLines.length - prefix && suffix < newLines.length - prefix
    && equals(oldLines[oldLines.length - 1 - suffix] as TextLine, newLines[newLines.length - 1 - suffix] as TextLine)) {
    suffix += 1
  }
  return {
    prefix,
    suffix,
    oldMiddle: oldLines.slice(prefix, oldLines.length - suffix),
    newMiddle: newLines.slice(prefix, newLines.length - suffix),
  }
}

/** Maximum edit distance before a change block is emitted wholesale. */
const MAX_EDIT_DISTANCE = 4000

/**
 * Diff two line arrays with Myers' O((N+M)D) algorithm. The common prefix and
 * suffix are trimmed first, and a change block larger than
 * {@link MAX_EDIT_DISTANCE} edits falls back to delete-then-insert so a
 * pathological file cannot lock the Worker.
 */
export function diffLines(oldLines: readonly TextLine[], newLines: readonly TextLine[]): DiffOp[] {
  const { prefix, suffix, oldMiddle, newMiddle } = trim(oldLines, newLines)
  const ops: DiffOp[] = []
  for (let index = 0; index < prefix; index += 1) {
    ops.push({ type: 'equal', oldIndex: index, newIndex: index })
  }
  const middle = myers(oldMiddle, newMiddle)
  for (const op of middle) {
    ops.push({
      type: op.type,
      ...op.oldIndex === undefined ? {} : { oldIndex: op.oldIndex + prefix },
      ...op.newIndex === undefined ? {} : { newIndex: op.newIndex + prefix },
    })
  }
  for (let index = suffix; index > 0; index -= 1) {
    ops.push({
      type: 'equal',
      oldIndex: oldLines.length - index,
      newIndex: newLines.length - index,
    })
  }
  return ops
}

function myers(oldLines: readonly TextLine[], newLines: readonly TextLine[]): DiffOp[] {
  const n = oldLines.length
  const m = newLines.length
  if (n === 0 && m === 0) return []
  if (n === 0) return newLines.map((_line, index) => ({ type: 'insert' as const, newIndex: index }))
  if (m === 0) return oldLines.map((_line, index) => ({ type: 'delete' as const, oldIndex: index }))
  const max = n + m
  const offset = max
  const v = new Int32Array(2 * max + 2)
  const trace: Int32Array[] = []
  let found = false
  for (let d = 0; d <= max; d += 1) {
    trace.push(v.slice())
    for (let k = -d; k <= d; k += 2) {
      const index = k + offset
      let x: number
      if (k === -d || (k !== d && (v[index - 1] as number) < (v[index + 1] as number))) {
        x = v[index + 1] as number
      } else {
        x = (v[index - 1] as number) + 1
      }
      let y = x - k
      while (x < n && y < m && equals(oldLines[x] as TextLine, newLines[y] as TextLine)) {
        x += 1
        y += 1
      }
      v[index] = x
      if (x >= n && y >= m) {
        found = true
        break
      }
    }
    if (found) break
    if (d > MAX_EDIT_DISTANCE) return fallback(oldLines, newLines)
  }
  // Backtrack through the recorded frontiers.
  const ops: DiffOp[] = []
  let x = n
  let y = m
  for (let d = trace.length - 1; d >= 0; d -= 1) {
    const frontier = trace[d] as Int32Array
    const k = x - y
    let previousK: number
    if (k === -d || (k !== d && (frontier[k - 1 + offset] as number) < (frontier[k + 1 + offset] as number))) {
      previousK = k + 1
    } else {
      previousK = k - 1
    }
    const previousX = frontier[previousK + offset] as number
    const previousY = previousX - previousK
    while (x > previousX && y > previousY) {
      ops.push({ type: 'equal', oldIndex: x - 1, newIndex: y - 1 })
      x -= 1
      y -= 1
    }
    if (d > 0) {
      if (x === previousX) {
        ops.push({ type: 'insert', newIndex: y - 1 })
        y -= 1
      } else {
        ops.push({ type: 'delete', oldIndex: x - 1 })
        x -= 1
      }
    }
  }
  while (x > 0 && y > 0) {
    ops.push({ type: 'equal', oldIndex: x - 1, newIndex: y - 1 })
    x -= 1
    y -= 1
  }
  while (x > 0) {
    ops.push({ type: 'delete', oldIndex: x - 1 })
    x -= 1
  }
  while (y > 0) {
    ops.push({ type: 'insert', newIndex: y - 1 })
    y -= 1
  }
  return ops.reverse()
}

function fallback(oldLines: readonly TextLine[], newLines: readonly TextLine[]): DiffOp[] {
  const ops: DiffOp[] = []
  oldLines.forEach((_line, oldIndex) => ops.push({ type: 'delete', oldIndex }))
  newLines.forEach((_line, newIndex) => ops.push({ type: 'insert', newIndex }))
  return ops
}

/** Added and deleted line counts of a diff. */
export interface DiffCounts {
  readonly added: number
  readonly deleted: number
}

/** Count inserted and deleted lines. */
export function countDiff(oldLines: readonly TextLine[], newLines: readonly TextLine[]): DiffCounts {
  let added = 0
  let deleted = 0
  for (const op of diffLines(oldLines, newLines)) {
    if (op.type === 'insert') added += 1
    else if (op.type === 'delete') deleted += 1
  }
  return { added, deleted }
}

/** One hunk of a unified diff. */
export interface DiffHunk {
  readonly oldStart: number
  readonly oldCount: number
  readonly newStart: number
  readonly newCount: number
  readonly lines: readonly { readonly kind: ' ' | '-' | '+'; readonly line: TextLine }[]
}

/** Split the op list into hunks with `context` unchanged lines around changes. */
export function unifiedHunks(
  oldLines: readonly TextLine[],
  newLines: readonly TextLine[],
  context = 3,
): DiffHunk[] {
  const ops = diffLines(oldLines, newLines)
  const changeIndices: number[] = []
  ops.forEach((op, index) => { if (op.type !== 'equal') changeIndices.push(index) })
  if (changeIndices.length === 0) return []
  const groups: { start: number; end: number }[] = []
  let start = Math.max(0, (changeIndices[0] as number) - context)
  let end = Math.min(ops.length, (changeIndices[0] as number) + 1 + context)
  for (let index = 1; index < changeIndices.length; index += 1) {
    const next = changeIndices[index] as number
    // `end` already includes `context` equal ops, so the gap left between this
    // hunk and `next` is `next - end`. Git starts a new hunk once that gap
    // exceeds one context block, i.e. once the unchanged run between the two
    // changes is longer than `2 * context`.
    if (next - end > context) {
      groups.push({ start, end })
      start = Math.max(0, next - context)
      end = Math.min(ops.length, next + 1 + context)
    } else {
      end = Math.min(ops.length, next + 1 + context)
    }
  }
  groups.push({ start, end })
  return groups.map(group => buildHunk(ops, group.start, group.end, oldLines, newLines))
}

function buildHunk(
  ops: readonly DiffOp[],
  start: number,
  end: number,
  oldLines: readonly TextLine[],
  newLines: readonly TextLine[],
): DiffHunk {
  const lines: { kind: ' ' | '-' | '+'; line: TextLine }[] = []
  let oldStart = -1
  let newStart = -1
  let oldCount = 0
  let newCount = 0
  for (const op of ops.slice(start, end)) {
    if (op.type === 'equal') {
      if (oldStart < 0) oldStart = (op.oldIndex as number) + 1
      if (newStart < 0) newStart = (op.newIndex as number) + 1
      oldCount += 1
      newCount += 1
      lines.push({ kind: ' ', line: oldLines[op.oldIndex as number] as TextLine })
    } else if (op.type === 'delete') {
      if (oldStart < 0) oldStart = (op.oldIndex as number) + 1
      oldCount += 1
      lines.push({ kind: '-', line: oldLines[op.oldIndex as number] as TextLine })
    } else {
      if (newStart < 0) newStart = (op.newIndex as number) + 1
      newCount += 1
      lines.push({ kind: '+', line: newLines[op.newIndex as number] as TextLine })
    }
  }
  // A zero-length range names the position between lines, not the first line
  // that happens to be in the slice: count the lines consumed before the hunk
  // on that side. A `-U0` insertion with no context has no old line in the
  // slice at all, and a pure deletion likewise has no new line.
  if (oldCount === 0) oldStart = consumedBefore(ops, start, 'insert')
  if (newCount === 0) newStart = consumedBefore(ops, start, 'delete')
  return {
    oldStart: oldStart < 0 ? 0 : oldStart,
    oldCount,
    newStart: newStart < 0 ? 0 : newStart,
    newCount,
    lines,
  }
}

/** Lines consumed before `start` by every op except `skip`. */
function consumedBefore(ops: readonly DiffOp[], start: number, skip: DiffOp['type']): number {
  let count = 0
  for (let index = 0; index < start; index += 1) {
    if ((ops[index] as DiffOp).type !== skip) count += 1
  }
  return count
}

/** Format one hunk range the way git does (`-1,3` / `-1` / `-0,0`). */
export function formatRange(start: number, count: number): string {
  if (count === 1) return `${start}`
  return `${start},${count}`
}

/** Render one unified hunk body (lines with their prefix and newline marker). */
export function renderHunkBody(hunk: DiffHunk): Uint8Array {
  const chunks: Uint8Array[] = []
  for (const entry of hunk.lines) {
    chunks.push(encodeText(entry.kind))
    chunks.push(entry.line.bytes)
    if (entry.line.missingNewline) chunks.push(encodeText('\n\\ No newline at end of file\n'))
  }
  return concat(chunks)
}

function concat(chunks: readonly Uint8Array[]): Uint8Array {
  let length = 0
  for (const chunk of chunks) length += chunk.byteLength
  const out = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

/** Similarity score (0-100) between two blobs for `-M` rename detection. */
export function similarity(oldData: Uint8Array, newData: Uint8Array): number {
  if (oldData.byteLength === 0 && newData.byteLength === 0) return 100
  if (isBinary(oldData) || isBinary(newData)) {
    return compareBytes(oldData, newData) === 0 ? 100 : 0
  }
  const oldLines = splitLines(oldData)
  const newLines = splitLines(newData)
  const ops = diffLines(oldLines, newLines)
  let common = 0
  for (const op of ops) if (op.type === 'equal') common += (oldLines[op.oldIndex as number] as TextLine).bytes.byteLength
  const total = Math.max(oldData.byteLength, newData.byteLength)
  return total === 0 ? 100 : Math.min(100, Math.round((common / total) * 100))
}
