// SPDX-License-Identifier: MIT
/**
 * Scripted Messages-compatible model endpoint for the packed-image workflow
 * test.
 *
 * It simulates ONLY the model wire: HTTP `POST <base>/v1/messages` and the
 * Anthropic-style SSE events (`text`, `tool_use`, `message_stop`). It never
 * invents a tool result: every `tool_result` it reacts to was produced by DSH's
 * real tool dispatch, the real Worker shell/VFS, and the real workflow child
 * bridge. The fixed turn order is:
 *
 *   1. parent asks for the `workflow` tool;
 *   2. the workflow child asks for `bash` (write + cat workflow.txt);
 *   3. the child answers `WORKFLOW_BASH_OK`;
 *   4. the parent answers `WORKFLOW_DONE`.
 *
 * No credential is read or logged.
 * @module @phone-dsh/plugins/tests/fixtures/scripted-messages
 */
import { createServer, type Server, type ServerResponse } from 'node:http'

/** One content block as the Messages transcript carries it. */
interface WireBlock {
  readonly type?: string
  readonly text?: string
  readonly id?: string
  readonly name?: string
  readonly input?: unknown
  readonly tool_use_id?: string
  readonly content?: unknown
  readonly is_error?: boolean
}

/** One Messages request message. */
interface WireMessage {
  readonly role?: string
  readonly content?: readonly WireBlock[] | string
}

/** The started scripted upstream. */
export interface ScriptedMessages {
  /** Base URL callers put in `DEEPSEEK_BASE_URL` (a `/mock` suffix is expected by the adapter). */
  readonly url: string
  /** Number of model requests served. */
  readonly requests: () => number
  /** Stop the server and release its socket. */
  close(): Promise<void>
}

/** Render one tool_result/content value as text without trusting it. */
function contentText(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.map((block: WireBlock) => block.type === 'text' ? block.text ?? '' : '').join('')
}

/** Collect tool uses and their produced results from the transcript. */
function transcript(messages: readonly WireMessage[]): {
  uses: WireBlock[]
  results: Map<string, { text: string; isError: boolean }>
  firstUserText: string
} {
  const uses: WireBlock[] = []
  const results = new Map<string, { text: string; isError: boolean }>()
  let firstUserText = ''
  for (const message of messages) {
    if (typeof message.content === 'string') {
      if (message.role === 'user' && firstUserText === '') firstUserText = message.content
      continue
    }
    for (const block of message.content ?? []) {
      if (message.role === 'user' && block.type === 'text' && firstUserText === '') firstUserText = block.text ?? ''
      if (message.role === 'assistant' && block.type === 'tool_use' && typeof block.id === 'string') uses.push(block)
      if (message.role === 'user' && block.type === 'tool_result' && typeof block.tool_use_id === 'string') {
        results.set(block.tool_use_id, { text: contentText(block.content), isError: block.is_error === true })
      }
    }
  }
  return { uses, results, firstUserText }
}

/** One scripted assistant turn. */
interface Turn {
  readonly text: string
  readonly tool?: { readonly name: string; readonly input: Record<string, unknown> }
}

/** The child task marker; it distinguishes the delegated agent from the parent turn. */
const CHILD_MARKER = 'WORKFLOW_CHILD_TASK'

/** Decide the next turn from the real transcript. */
function decide(messages: readonly WireMessage[]): Turn {
  const { uses, results, firstUserText } = transcript(messages)
  const last = uses.at(-1)
  if (last === undefined) {
    if (firstUserText.includes(CHILD_MARKER)) {
      return {
        text: 'I will write and read workflow.txt with the real bash tool.',
        tool: {
          name: 'bash',
          input: {
            description: 'Write and read workflow.txt',
            command: "printf 'WORKFLOW_FILE_OK\\n' > workflow.txt && cat workflow.txt",
          },
        },
      }
    }
    return {
      text: 'I will run a workflow whose child uses the real bash tool.',
      tool: {
        name: 'workflow',
        input: {
          meta: {
            name: 'worker-bash-probe',
            description: 'Run a child agent that writes and reads workflow.txt through the real bash tool',
          },
          run_in_background: false,
          script: `const child = await agent('${CHILD_MARKER}: write and read workflow.txt with bash', { label: 'bash-child' });
return { child };`,
        },
      },
    }
  }
  if (last.name === 'bash' && results.has(last.id ?? '')) {
    return { text: 'WORKFLOW_BASH_OK' }
  }
  if (last.name === 'workflow' && results.has(last.id ?? '')) {
    return { text: 'WORKFLOW_DONE' }
  }
  return { text: 'Waiting for the tool result.' }
}

/** Emit one SSE event. */
function sse(response: ServerResponse, event: string, data: Record<string, unknown>): void {
  response.write(`event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`)
}

/**
 * Start the scripted Messages endpoint.
 * @param options - optional port (0 chooses an ephemeral loopback port).
 * @returns the URL and close handle.
 */
export async function startScriptedMessages(options: { port?: number } = {}): Promise<ScriptedMessages> {
  let requestCount = 0
  const server: Server = createServer((request, response) => {
    void (async () => {
      const chunks: Buffer[] = []
      for await (const chunk of request) chunks.push(Buffer.from(chunk))
      if (request.method !== 'POST' || !request.url?.endsWith('/v1/messages')) {
        response.writeHead(404, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'no route' } }))
        return
      }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8')) as { messages?: WireMessage[]; model?: string }
      const turn = decide(body.messages ?? [])
      requestCount += 1
      response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
      sse(response, 'message_start', {
        message: {
          id: `msg_scripted_${String(requestCount)}`,
          type: 'message',
          role: 'assistant',
          model: body.model,
          content: [],
          usage: { input_tokens: 64, output_tokens: 0 },
        },
      })
      sse(response, 'content_block_start', { index: 0, content_block: { type: 'text', text: '' } })
      sse(response, 'content_block_delta', { index: 0, delta: { type: 'text_delta', text: turn.text } })
      sse(response, 'content_block_stop', { index: 0 })
      if (turn.tool !== undefined) {
        sse(response, 'content_block_start', {
          index: 1,
          content_block: { type: 'tool_use', id: `toolu_scripted_${String(requestCount)}`, name: turn.tool.name, input: {} },
        })
        sse(response, 'content_block_delta', {
          index: 1,
          delta: { type: 'input_json_delta', partial_json: JSON.stringify(turn.tool.input) },
        })
        sse(response, 'content_block_stop', { index: 1 })
      }
      sse(response, 'message_delta', {
        delta: { stop_reason: turn.tool === undefined ? 'end_turn' : 'tool_use' },
        usage: { output_tokens: 16 },
      })
      sse(response, 'message_stop', {})
      response.end()
    })().catch((error: unknown) => {
      response.writeHead(500, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ type: 'error', error: { type: 'server_error', message: String(error) } }))
    })
  })
  await new Promise<void>((resolveListen, reject) => {
    server.once('error', reject)
    server.listen(options.port ?? 0, '127.0.0.1', resolveListen)
  })
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('scripted messages: no port')
  return {
    url: `http://127.0.0.1:${String(address.port)}/mock`,
    requests: () => requestCount,
    close: async () => {
      server.closeAllConnections()
      await new Promise<void>(resolveClose => { server.close(() => resolveClose()) })
    },
  }
}

export { CHILD_MARKER }
