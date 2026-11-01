// SPDX-License-Identifier: MIT
/**
 * Model-facing diagnostics for a `write`/`edit` refusal (P24).
 *
 * The pinned `dsh-tool-fs` replaces a provider denial's message with two fixed
 * decorations and drops the provider's reason entirely
 * (`packages/fs/tool-fs/src/sandbox.ts`, `FsSandboxController.mapError`: every
 * `FS_SANDBOX_DENIED` becomes `[sandbox: file access denied under <mode> mode]`
 * plus the same-turn escalation hint, with the original as a `cause` the model
 * never sees). On the device the model therefore received two lines of
 * boilerplate, no path, no reason and no next step:
 *
 *   Error: [sandbox: file access denied under workspace-write mode]
 *   [sandbox: escalation available — retry this exact operation once with
 *   sandbox_permissions ...; the approval prompt asks the user]
 *
 * The second line can never be honoured here: `plugins/profile` composes the
 * approval policy as `never`, and the read-only image (`/`, `/dsh/config`,
 * `/dsh/bin`) is outside the VFS root table, so no mode widens it. A model that
 * follows the hint burns a turn.
 *
 * This module cannot un-decorate that text (the replacement happens in trusted
 * code above us) and it does not try: it APPENDS the missing facts beside them
 * through the documented `tools/post-execute` waterfall, so the result the model
 * receives is the harness marker plus, in this product's own words, the refused
 * path, the one writable-roots sentence bash already prints
 * ({@link WORKER_VFS_NAMESPACE.writableRootsLine}), and what to do next.
 *
 * ## Why three codes, not one
 *
 * The same model question — "why can I not put my file there?" — arrives as
 * three different failures, and only the first used to be diagnosed:
 *
 *  - `FS_SANDBOX_DENIED`: the fence refused. The pinned layer replaced the
 *    reason, so this is where P24 started.
 *  - `FS_NOT_FOUND`: the target does not exist. `edit` cannot create a file, and
 *    on a fenced path "create it first" is a dead end — nothing in
 *    `cannot edit "<path>": not found` says which of the two it is.
 *  - `FS_NOT_OBSERVED`: the read-before-write policy refused. Its advice ("read
 *    the file, then retry") describes a step the model can complete on a path
 *    the fence will still refuse afterwards — one paid turn that teaches nothing.
 *
 * Every refusal the model can act on answers the same three questions (which
 * path, which rule, what next). Leaving two of the three codes with a one-line
 * answer is the same defect in a different shape, so all three are answered here
 * — with one deliberate difference: only `FS_SANDBOX_DENIED` carries the
 * harness escalation hint, so only that answer rebuts it. Copying the
 * "escalation cannot help" paragraph onto "not found" would warn about a prompt
 * the model was never shown.
 *
 * ## Four fence shapes, because the two fences are not the same fence
 *
 *  - `read-only` mode denies every write/edit, workspace included.
 *  - an image path (`/`, `/dsh/config/**`, `/dsh/bin/**`, `/etc/**`) is outside
 *    the VFS root table, so bash refuses it too.
 *  - `/dsh/home` (and the `/dev/null` device) is inside the VFS root table but
 *    outside `dsh-fs-sandbox`'s writable set (`workspaceRoot`, `/tmp`,
 *    `tmpdir()`), so only bash can reach it. Saying "outside every writable
 *    root" there would be a lie, and telling the model to retry would be a trap.
 *  - everything else in the root table is inside both fences, where the code's
 *    own meaning ("absent", "never read") is the whole answer.
 *
 * The listener never changes a successful result, an undiagnosed code, another
 * tool's result (bash keeps its own two-line `EACCES` answer, `read` keeps its
 * own `not found`), and it is idempotent: a result that already carries this
 * module's marker is left alone.
 * @module @phone-dsh/dsh-worker-entry/fs-denial-diagnostics
 */

import { WORKER_VFS_NAMESPACE, type VfsNamespace } from '../../wasi-toolbox/src/vfs-namespace.ts'

/** The mutating tools whose refusal this module annotates. */
export const FS_DENIAL_TOOLS: ReadonlySet<string> = new Set(['write', 'edit'])

/** First token of every line this module adds, so a second pass can see its own work. */
export const FS_DENIAL_MARKER = 'pdsh-fs: '

/** The refusal whose provider message the pinned layer replaces outright. */
export const FS_DENIAL_CODE = 'FS_SANDBOX_DENIED'

/**
 * Every code this module answers: the replaced one, plus the two "the target is
 * absent / was never read" refusals whose one-line provider text leaves the model
 * without the rule or the way out.
 */
export const FS_DIAGNOSED_CODES: ReadonlySet<string> = new Set([
  FS_DENIAL_CODE,
  'FS_NOT_FOUND',
  'FS_NOT_OBSERVED',
])

/**
 * The workspace root the fence falls back to when the policy service is not
 * mounted (a partial composition, or a unit test): the Worker's cwd, which the
 * phone profile pins to `/dsh/workspace`.
 */
export const DEFAULT_TOOL_WORKSPACE_ROOT = '/dsh/workspace'

/** The two temp roots the runtime's `tmpdir()` and the `/tmp` alias resolve to. */
export const TOOL_TEMP_ROOTS: readonly string[] = Object.freeze(['/tmp', '/dsh/tmp'])

/** Match the mode out of the pinned marker the tool layer already wrote. */
const MODE_IN_MARKER = /\bfile access denied under (read-only|workspace-write|danger-full-access) mode\b/u

/** The `ContentBlock` subset used for a tool result's text. */
interface TextBlock {
  readonly type: 'text'
  readonly text: string
}

/** What the diagnosis needs to know; every field is already resolved by the caller. */
export interface FsDenialFacts {
  /** One of {@link FS_DIAGNOSED_CODES}. */
  readonly code: string
  /** `write` or `edit` (selects the verb). */
  readonly toolName: string
  /** Absolute path shown to the model. */
  readonly path: string
  /** The mode named by the harness marker (`read-only`, `workspace-write`, ...). */
  readonly mode: string
  /**
   * The writable root of the phone's VFS root table that contains {@link path},
   * or undefined when the path is outside that table (or could not be resolved).
   */
  readonly root: string | undefined
  /** True when {@link path} is inside the `write`/`edit` fence (workspace + temp roots). */
  readonly toolWritable: boolean
}

/**
 * The writable root that contains `path` on the phone, if any.
 * @param path - absolute virtual path.
 * @param namespace - root table to consult (the production one by default).
 * @returns the containing root path, or undefined outside the root table.
 */
export function phoneWritableRootOf(path: string, namespace: VfsNamespace = WORKER_VFS_NAMESPACE): string | undefined {
  try {
    return namespace.rootFor(path)?.path
  } catch {
    return undefined
  }
}

/**
 * Whether `path` is `root` itself or a descendant of it — the same containment
 * `dsh-fs-sandbox`'s `isPathUnder` and `wasi-toolbox`'s root table use.
 * @param path - absolute path to test.
 * @param root - absolute root.
 * @returns true when the path is the root or below it.
 */
export function isWithinRoot(path: string, root: string): boolean {
  if (path === root) return true
  const boundary = root.endsWith('/') ? root : `${root}/`
  return path.startsWith(boundary)
}

/**
 * Whether the `write`/`edit` fence accepts `path`.
 *
 * The fence is `dsh-fs-sandbox`'s writable set: the session's workspace root plus
 * the temp roots. This is deliberately NOT the VFS root table — `/dsh/home` and
 * `/dev/null` are outside it, and that difference is the contract gap this module
 * reports instead of hiding.
 * @param path - absolute virtual path.
 * @param workspaceRoot - the session's workspace root.
 * @returns true when `write`/`edit` may create or change the path.
 */
export function toolFenceAccepts(path: string, workspaceRoot: string): boolean {
  return [workspaceRoot, ...TOOL_TEMP_ROOTS].some(root => isWithinRoot(path, root))
}

/** Render one model-facing path the way the harness does (double quotes). */
function quote(path: string): string {
  return `"${path}"`
}

/** The model-facing verb for a path (`edit` changes; `write` writes). */
function verbOf(toolName: string): string {
  return toolName === 'edit' ? 'change' : 'write'
}

/**
 * Build the appended diagnosis: the refused path, why it was refused, the one
 * writable-roots sentence bash prints, and a next step that can actually work.
 * @param facts - resolved facts about the refusal.
 * @param rootsLine - {@link WORKER_VFS_NAMESPACE.writableRootsLine} for this root table.
 * @returns two to three newline-separated lines, starting with {@link FS_DENIAL_MARKER}.
 */
export function fsDenialDiagnostic(facts: FsDenialFacts, rootsLine: string): string {
  return facts.code === FS_DENIAL_CODE ? sandboxDenial(facts, rootsLine) : missingTarget(facts, rootsLine)
}

/** The `FS_SANDBOX_DENIED` answer: the fence refused a path the tool may not touch. */
function sandboxDenial(facts: FsDenialFacts, rootsLine: string): string {
  const verb = verbOf(facts.toolName)
  const lines: string[] = []
  if (facts.mode === 'read-only') {
    lines.push(
      `${FS_DENIAL_MARKER}cannot ${verb} ${quote(facts.path)}: this session is in read-only mode, `
        + 'so `write`, `edit` and `bash` refuse every change.',
    )
    lines.push(rootsLine)
    lines.push(
      'next: nothing can write in a read-only session and a tool call cannot widen it '
        + '(this deployment has no approval prompt) — report the intended content to the user instead.',
    )
    return lines.join('\n')
  }
  if (facts.root !== undefined && !facts.toolWritable) {
    lines.push(
      `${FS_DENIAL_MARKER}cannot ${verb} ${quote(facts.path)}: ${quote(facts.root)} is writable from \`bash\`, `
        + 'not from `write`/`edit` — this tool is fenced at the workspace root and the temp roots.',
    )
    lines.push(rootsLine)
    lines.push(
      `next: ${verb} it with \`bash\` (for example \`printf '%s' "<content>" > ${quote(facts.path)}\`), `
        + 'or put the file under "/dsh/workspace" and retry `write`/`edit` there; '
        + '`sandbox_permissions` cannot widen this fence and this deployment has no approval prompt.',
    )
    return lines.join('\n')
  }
  lines.push(
    `${FS_DENIAL_MARKER}cannot ${verb} ${quote(facts.path)}: the path is outside the phone's writable roots, `
      + 'so `write`, `edit` and `bash` all refuse it (the image is read-only in every mode).',
  )
  lines.push(rootsLine)
  lines.push(
    `next: retry with a path under one of those roots (for a workspace file "/dsh/workspace/<name>"); `
      + '`sandbox_permissions` cannot widen an image path and this deployment has no approval prompt, '
      + `so escalation is always refused. If the file must live at ${quote(facts.path)}, say so instead of retrying.`,
  )
  return lines.join('\n')
}

/**
 * The `FS_NOT_FOUND` / `FS_NOT_OBSERVED` answer.
 *
 * Both arrive BEFORE the fence runs, so on a fenced path the provider's own
 * advice describes a step the model can complete without ever reaching the file.
 * This answer says which of the situations it is and what actually moves the work
 * forward; it does not repeat the escalation rebuttal, because neither code ever
 * showed the model the escalation hint.
 */
function missingTarget(facts: FsDenialFacts, rootsLine: string): string {
  const verb = verbOf(facts.toolName)
  const absent = facts.code === 'FS_NOT_FOUND'
  const lines: string[] = []
  if (facts.mode === 'read-only') {
    lines.push(
      `${FS_DENIAL_MARKER}cannot ${verb} ${quote(facts.path)}: this session is in read-only mode, `
        + (absent ? 'and the file does not exist yet.' : 'and the file was not read first.'),
    )
    lines.push(rootsLine)
    lines.push(
      'next: a read-only session creates and changes nothing — report the intended content to the user '
        + 'instead of retrying.',
    )
    return lines.join('\n')
  }
  if (facts.toolWritable) {
    // The fence accepts the path, so the failure is only about the file itself;
    // the answer is the code's own meaning, not a writable-root lesson.
    lines.push(
      absent
        ? `${FS_DENIAL_MARKER}${quote(facts.path)} is writable but does not exist yet: `
          + '`edit` only changes an existing file, while `write` creates one.'
        : `${FS_DENIAL_MARKER}${quote(facts.path)} is writable but was not read in this session: `
          + 'the read is what registers the observation a guarded `edit` needs.',
    )
    lines.push(rootsLine)
    lines.push(
      absent
        ? `next: use \`write\` with the full content to create ${quote(facts.path)}, or report that it is missing.`
        : `next: read ${quote(facts.path)} once, then repeat the same \`edit\` — nothing else is missing.`,
    )
    return lines.join('\n')
  }
  if (facts.root !== undefined) {
    lines.push(
      `${FS_DENIAL_MARKER}cannot ${verb} ${quote(facts.path)}: ${quote(facts.root)} is writable from \`bash\`, `
        + 'not from `write`/`edit`, so this tool cannot reach the file at all.',
    )
    lines.push(rootsLine)
    lines.push(
      `next: use \`bash\` for this path (for example \`printf '%s' "<content>" > ${quote(facts.path)}\`), `
        + 'or move the work under "/dsh/workspace" and retry `write`/`edit` there.',
    )
    return lines.join('\n')
  }
  lines.push(
    `${FS_DENIAL_MARKER}cannot ${verb} ${quote(facts.path)}: the path is outside the phone's writable roots, `
      + 'so `write`, `edit` and `bash` all refuse it (the image is read-only in every mode).',
  )
  lines.push(rootsLine)
  lines.push(
    absent
      ? `next: nothing can create that path — ${quote(facts.path)} is not writable in any mode. `
        + 'Put the file under a writable root (for a workspace file "/dsh/workspace/<name>") and retry, '
        + 'or report where it must live.'
      : 'next: reading it first does not help — the path stays unwritable after the read. '
        + 'Put the file under a writable root (for a workspace file "/dsh/workspace/<name>") and retry, '
        + 'or report where it must live.',
  )
  return lines.join('\n')
}

/** The Cordis `Context` subset this module uses. */
export interface FsDenialContext {
  on(name: string, listener: (...args: any[]) => unknown, options?: { readonly prepend?: boolean }): unknown
  get(name: string): unknown
}

/** A tool execution, structurally from `@deepseek-ai/dsh-tools`. */
interface ToolExecutionLike {
  readonly name?: unknown
  readonly arguments?: unknown
  readonly signal?: AbortSignal
  readonly agent?: unknown
}

/** A tool result, structurally from `@deepseek-ai/dsh-tools`. */
interface ToolResultLike {
  readonly isError?: unknown
  readonly content?: unknown
  readonly error?: unknown
}

/**
 * The decision `tools/post-execute` expects back. Only `kind` and `content` are
 * ours to read or replace; every other member of a downstream decision (a
 * block's feedback, extra contexts) is carried through untouched, which the
 * open index signature keeps type-honest.
 */
export interface PostDecisionLike {
  readonly kind?: unknown
  readonly content?: unknown
  readonly additionalContexts?: unknown
  readonly [member: string]: unknown
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Read the model-supplied path out of a `write`/`edit` argument object. */
function pathArgument(args: unknown): string | undefined {
  if (!isRecord(args)) return undefined
  const raw = args.file_path
  if (typeof raw !== 'string' || raw.trim() === '') return undefined
  return raw
}

/** The diagnosed code a failed result carries, if it carries one of ours. */
function diagnosedCode(result: ToolResultLike): string | undefined {
  const error = result.error
  if (!isRecord(error)) return undefined
  const info = error.info
  if (!isRecord(info)) return undefined
  const code = info.code
  return typeof code === 'string' && FS_DIAGNOSED_CODES.has(code) ? code : undefined
}

/**
 * The mode the harness marker named, when the message carries one.
 *
 * Only `FS_SANDBOX_DENIED` does: the two "absent / never read" codes arrive
 * before the fence, so their text has no marker and the session's own policy is
 * the only truth about the mode (a read-only session can produce both).
 */
function markerMode(result: ToolResultLike): string | undefined {
  const error = result.error
  const message = isRecord(error) && typeof error.message === 'string' ? error.message : ''
  return MODE_IN_MARKER.exec(message)?.[1]
}

/** Every text block of a tool result (the array the model receives). */
function textBlocks(content: unknown): TextBlock[] {
  if (!Array.isArray(content)) return []
  const blocks: TextBlock[] = []
  for (const block of content) {
    if (isRecord(block) && block.type === 'text' && typeof block.text === 'string') {
      blocks.push({ type: 'text', text: block.text })
    }
  }
  return blocks
}

/** True when a previous pass already appended this module's lines. */
function alreadyAnnotated(blocks: readonly TextBlock[]): boolean {
  return blocks.some(block => block.text.includes(FS_DENIAL_MARKER))
}

/** The session's fence facts: where it may write, and in which mode. */
interface SessionFence {
  readonly workspaceRoot: string
  /** The policy mode, or undefined when the service cannot answer. */
  readonly mode: string | undefined
}

/**
 * The session's fence, as `ctx.sandboxPolicy` resolves it: the per-session
 * workspace root and mode when that service is mounted, else the Worker's
 * pinned cwd and no mode.
 * @param ctx - the host context.
 * @param exec - the tool execution (carries the session the policy resolves for).
 * @returns the workspace root and mode.
 */
function sessionFence(ctx: FsDenialContext, exec: ToolExecutionLike): SessionFence {
  const service = ctx.get('sandboxPolicy')
  if (isRecord(service) && typeof service.resolve === 'function') {
    try {
      const agent = exec.agent
      const session = isRecord(agent) ? agent.session : undefined
      const policy: unknown = (service.resolve as (options: unknown) => unknown)(
        session === undefined ? {} : { session },
      )
      if (isRecord(policy)) {
        const workspaceRoot = typeof policy.workspaceRoot === 'string' && policy.workspaceRoot !== ''
          ? policy.workspaceRoot
          : DEFAULT_TOOL_WORKSPACE_ROOT
        const mode = typeof policy.mode === 'string' && policy.mode !== '' ? policy.mode : undefined
        return { workspaceRoot, mode }
      }
    } catch {
      // A policy that cannot resolve leaves the deployment default below.
    }
  }
  return { workspaceRoot: DEFAULT_TOOL_WORKSPACE_ROOT, mode: undefined }
}

/**
 * Resolve the path shown to the model: the backend's canonical display path
 * when the filesystem service can produce one, else the root table's
 * canonicalisation, else the raw argument.
 * @param ctx - the host context (for `fs` and `workingDirectory`).
 * @param exec - the tool execution (carries the agent whose cwd resolves a relative path).
 * @param raw - the model-supplied path.
 * @returns the display path.
 */
async function resolveDisplayPath(ctx: FsDenialContext, exec: ToolExecutionLike, raw: string): Promise<string> {
  const fs = ctx.get('fs')
  if (isRecord(fs) && typeof fs.resolve === 'function') {
    try {
      const agent = exec.agent
      const working = ctx.get('workingDirectory')
      let cwd: string | undefined
      if (agent !== undefined && isRecord(working) && typeof working.ensure === 'function') {
        const ensured: unknown = await working.ensure(agent, exec.signal)
        if (typeof ensured === 'string' && ensured !== '') cwd = ensured
      }
      const target: unknown = await (fs.resolve as (path: string, options?: unknown) => Promise<unknown>)(
        raw,
        { ...cwd === undefined ? {} : { cwd }, signal: exec.signal },
      )
      if (isRecord(target) && typeof target.displayPath === 'string' && target.displayPath !== '') {
        return target.displayPath
      }
    } catch {
      // A path the backend cannot resolve falls back to the root table below.
    }
  }
  try {
    return WORKER_VFS_NAMESPACE.resolve(raw)
  } catch {
    return raw
  }
}

/**
 * Append the diagnosis to one failed `write`/`edit` result.
 *
 * Returns the untouched decision for every other shape: a successful result, a
 * code outside {@link FS_DIAGNOSED_CODES}, another tool (bash and read keep their
 * own answers), a missing path argument, or a result this module already
 * annotated.
 * @param ctx - the host context.
 * @param exec - the tool execution.
 * @param result - the dispatched result.
 * @param decision - what the rest of the `tools/post-execute` chain decided.
 * @param rootsLine - the writable-roots sentence for this root table.
 * @returns the decision to use.
 */
export async function annotateFsDenial(
  ctx: FsDenialContext,
  exec: ToolExecutionLike,
  result: ToolResultLike,
  decision: PostDecisionLike,
  rootsLine: string = WORKER_VFS_NAMESPACE.writableRootsLine(),
): Promise<PostDecisionLike> {
  if (decision.kind !== 'accept') return decision
  if (result.isError !== true) return decision
  const toolName = typeof exec.name === 'string' ? exec.name : ''
  if (!FS_DENIAL_TOOLS.has(toolName)) return decision
  const code = diagnosedCode(result)
  if (code === undefined) return decision
  const raw = pathArgument(exec.arguments)
  if (raw === undefined) return decision
  const blocks = textBlocks(result.content)
  if (alreadyAnnotated(blocks)) return decision
  const path = await resolveDisplayPath(ctx, exec, raw)
  const fence = sessionFence(ctx, exec)
  const diagnosis = fsDenialDiagnostic(
    {
      code,
      toolName,
      path,
      mode: markerMode(result) ?? fence.mode ?? 'workspace-write',
      root: phoneWritableRootOf(path),
      toolWritable: toolFenceAccepts(path, fence.workspaceRoot),
    },
    rootsLine,
  )
  return { ...decision, content: [...blocks, { type: 'text', text: diagnosis }] }
}

/** Name of the Cordis plugin mounted before the profile tree. */
export const FS_DENIAL_PLUGIN_NAME = 'pdsh-fs-denial-diagnostics'

/**
 * Register the annotation on the host context.
 *
 * The listener is registered before the profile tree mounts and appends after
 * the rest of the chain, so a downstream `block` decision is never rewritten.
 * @param ctx - the host context, before the profile tree mounts.
 */
export function installFsDenialDiagnostics(ctx: FsDenialContext): void {
  const rootsLine = WORKER_VFS_NAMESPACE.writableRootsLine()
  ctx.on('tools/post-execute', async (exec: ToolExecutionLike, result: ToolResultLike, next: () => Promise<PostDecisionLike>) => {
    const decision = await next()
    try {
      return await annotateFsDenial(ctx, exec, result, decision, rootsLine)
    } catch {
      // A diagnostic must never replace the tool's own outcome with an error.
      return decision
    }
  })
}

/** The plugin mounted before the profile tree; it only registers the annotation. */
export const FS_DENIAL_PLUGIN = {
  name: FS_DENIAL_PLUGIN_NAME,
  apply(ctx: FsDenialContext): void {
    installFsDenialDiagnostics(ctx)
  },
}
