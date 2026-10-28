// SPDX-License-Identifier: MIT
/**
 * node:test reporter for the contract suite.
 *
 * It prints one line per test and forwards test stdout (the `observed ...`
 * lines) to the console, then writes a machine-readable results file that the
 * CLI folds into contract-report.json.
 * @module @phone-dsh/dsh-contract-tests/reporter
 */
import { writeFileSync } from 'node:fs'
import { basename, isAbsolute, relative } from 'node:path'

/**
 * Convert an event's absolute file path into a repository-relative label.
 * @param file - event file path, when present.
 * @returns a safe relative path or just the basename.
 */
function fileLabel(file) {
  if (typeof file !== 'string' || file === '') return ''
  const rel = relative(process.cwd(), file)
  return rel === '' || rel.startsWith('..') || isAbsolute(rel) ? basename(file) : rel
}

/**
 * The test-case details object, when the event describes a test rather than a suite.
 * @param data - event data.
 * @returns true for a test case.
 */
function isTestCase(data) {
  return data?.details?.type === 'test'
}

/**
 * Render a failed test's error object as text.
 * @param details - node:test failure details.
 * @returns the error stack, message, or JSON text, or undefined.
 */
function failureText(details) {
  const error = details?.error
  if (typeof error === 'string') return error
  if (error instanceof Error) return error.stack ?? error.message
  if (error === undefined || error === null) return undefined
  try {
    return JSON.stringify(error)
  } catch {
    return String(error)
  }
}

/**
 * Node's test reporter interface.
 * @param source - async iterable of test events.
 * @returns an async iterable of text written to stdout.
 */
export default async function* reporter(source) {
  const tests = []
  let summary = null
  for await (const event of source) {
    const data = event.data
    switch (event.type) {
      case 'test:stdout': {
        const message = typeof data?.message === 'string' ? data.message : ''
        if (message.trim() !== '') yield message.endsWith('\n') ? message : `${message}\n`
        break
      }
      case 'test:stderr': {
        const message = typeof data?.message === 'string' ? data.message : ''
        if (message.trim() !== '') {
          for (const line of message.split('\n')) {
            if (line !== '') yield `# stderr: ${line}\n`
          }
        }
        break
      }
      case 'test:pass':
      case 'test:fail': {
        if (!isTestCase(data)) break
        const failed = event.type === 'test:fail'
        const failure = failed ? failureText(data?.details) : undefined
        tests.push({
          file: fileLabel(data?.file),
          name: typeof data?.name === 'string' ? data.name : '',
          status: failed ? 'failed' : 'passed',
          duration_ms: typeof data?.duration_ms === 'number' ? data.duration_ms : undefined,
          ...failure === undefined ? {} : { failure },
        })
        yield `${failed ? 'not ok' : 'ok'} ${typeof data?.name === 'string' ? data.name : ''}\n`
        if (failure !== undefined) {
          for (const line of failure.split('\n')) yield `  ${line}\n`
        }
        break
      }
      case 'test:summary': {
        if (data?.file === undefined) summary = data
        break
      }
      default:
        break
    }
  }
  const target = process.env.PDSH_DSH_CONTRACT_RESULTS
  if (target !== undefined && target !== '') {
    writeFileSync(target, JSON.stringify({ tests, summary }))
  }
}
