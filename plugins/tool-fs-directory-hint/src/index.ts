// SPDX-License-Identifier: MIT
/**
 * Make `read`'s directory error actionable.
 *
 * DSH's `tool-fs` reports `cannot read "<path>": not a regular file` for an
 * existing directory. The model has to infer `glob`/`ls` from the code, and a
 * phone turn often starts by reading the workspace root. This phone policy
 * appends one sentence to that exact result through the supported
 * `tools/post-execute` waterfall; it does not rename the tool, change its
 * schema, replace its error code (`FS_NOT_REGULAR_FILE`), or patch DSH.
 * @module @phone-dsh/dsh-tool-fs-directory-hint
 */
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-tools'
import type { PostToolDecision, ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools'

/** Loader row name. */
export const name = 'tool-fs-directory-hint'

/** The post-execute event is owned by the tools service. */
export const inject = ['tools']

/** The one sentence appended to the DSH error. */
export const HINT = 'Hint: this path is a directory; use glob (or `bash ls`) to list its entries.'

/** True when a result is the exact DSH directory error and lacks the hint. */
export function isDirectoryReadError(result: Readonly<ToolExecutionResult>): boolean {
  if (!result.isError) return false
  const text = result.content
    .map(block => block.type === 'text' ? block.text : '')
    .join('\n')
  return /cannot read ".+": not a regular file/u.test(text) && !text.includes(HINT)
}

/** Append the hint to the model-facing content without touching error identity. */
export function withHint(content: ToolExecutionResult['content']): ToolExecutionResult['content'] {
  return [...content, { type: 'text', text: HINT }]
}

/** Register the post-execute policy. */
export function apply(ctx: Context): void {
  ctx.on('tools/post-execute', async (
    exec: ToolExecution,
    result: Readonly<ToolExecutionResult>,
    next: () => Promise<PostToolDecision>,
  ): Promise<PostToolDecision> => {
    const decision = await next()
    if (exec.name !== 'read' || decision.kind !== 'accept' || !isDirectoryReadError(result)) {
      return decision
    }
    // The accept arm is either a content replacement or a value replacement,
    // never both; a read failure has no successful value.
    if ('value' in decision) return decision
    return { ...decision, content: withHint(decision.content ?? result.content) }
  })
}
