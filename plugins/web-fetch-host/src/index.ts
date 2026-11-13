// SPDX-License-Identifier: MIT
/**
 * Host-routed `web_fetch` provider for the phone Worker.
 *
 * The Worker has no node:dns/undici socket path and the image disables DSH's
 * `web-fetch-http` for that reason. Its global `fetch` is installed by
 * `@phone-dsh/dsh-llm-bridge` and carries every external request over the App's
 * `/v1/http` route, where the host gateway enforces the egress allow-list.
 *
 * This provider exposes that already-existing transport as a `ctx.web` fetch
 * provider. It deliberately does the same body classification as DSH's local
 * provider (`text/html`/XHTML -> html, other text and JSON/XML -> text), so a
 * `text/plain` source (e.g. a raw GitHub file) is returned verbatim instead of
 * being sent to the independent Search/Fetch API's extractor, which requires
 * Markdown-extractable content.
 *
 * It is not a silent fallback: the Worker profile selects it explicitly with
 * `PDSH_WEB_FETCH_PROVIDER=phone-host-fetch`.
 * @module @phone-dsh/dsh-web-fetch-host
 */
import type { Context } from '@deepseek-ai/cordis'
import { WebError } from '@deepseek-ai/dsh-web'
import type {} from '@deepseek-ai/dsh-web'
import type {
  WebFetchProvider,
  WebFetchRequest,
  WebFetchResult,
} from '@deepseek-ai/dsh-web'

/** Loader row name; the profile mounts this package by name. */
export const name = 'web-fetch-host'

/** The `web` service must exist before this provider can register. */
export const inject = ['web']

/** Provider tuning. The tool-web output cap is 200k characters, so the byte
 * cap only bounds work before that final cap is applied. */
export interface Config {
  readonly maxResponseBytes?: number
  readonly maxBodyChars?: number
  readonly userAgent?: string
}

const DEFAULT_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
const DEFAULT_MAX_BODY_CHARS = 200_000
const DEFAULT_USER_AGENT = 'phone-dsh/0.1 (+https://github.com/launsion-boop/phone-dsh)'

type BodyKind = 'html' | 'text'

/** Parse and validate one request URL before it reaches the host proxy. */
function requestURL(raw: string): URL {
  let url: URL
  try {
    url = new URL(raw)
  } catch (error) {
    throw new WebError(`invalid URL: ${raw}`, 'WEB_INVALID_URL', { cause: error })
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new WebError(`unsupported URL scheme "${url.protocol}" (only http and https are allowed)`, 'WEB_INVALID_URL')
  }
  if (url.username.length > 0 || url.password.length > 0) {
    throw new WebError('credentials in URLs are not allowed', 'WEB_BLOCKED_URL')
  }
  return url
}

/** Classify the response body with DSH's local-provider rules. */
function bodyKind(contentType: string | null): BodyKind | undefined {
  const mime = (contentType ?? '').replace(/;.*$/s, '').trim().toLowerCase()
  if (mime === 'text/html' || mime === 'application/xhtml+xml') return 'html'
  if (mime.startsWith('text/')) return 'text'
  if (mime === 'application/json' || mime === 'application/xml'
    || mime.endsWith('+json') || mime.endsWith('+xml')) return 'text'
  return undefined
}

/** Extract the declared charset, defaulting to UTF-8. */
function decodeBody(contentType: string | null): TextDecoder {
  const match = /;\s*charset\s*=\s*"?([^";]+)"?/i.exec(contentType ?? '')
  const charset = match?.[1]?.trim().toLowerCase() ?? 'utf-8'
  try {
    return new TextDecoder(charset)
  } catch (error) {
    throw new WebError(`unsupported charset "${charset}"`, 'WEB_UNSUPPORTED_CONTENT_TYPE', { cause: error })
  }
}

/** Read at most `maxBytes` from the response body and decode it. */
async function readBody(
  response: Response,
  decoder: TextDecoder,
  maxBytes: number,
  maxChars: number,
): Promise<{ text: string; truncated: boolean }> {
  const reader = response.body?.getReader()
  if (reader === undefined) return { text: '', truncated: false }
  const chunks: Uint8Array[] = []
  let total = 0
  let truncated = false
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      const remaining = maxBytes - total
      if (value.byteLength > remaining) {
        chunks.push(value.subarray(0, remaining))
        total += remaining
        truncated = true
        // Release the rest of the body instead of leaving the host route's
        // stream open after the cap.
        await reader.cancel().catch(() => {})
        break
      }
      chunks.push(value)
      total += value.byteLength
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  let text = decoder.decode(bytes)
  if (text.length > maxChars) {
    text = text.slice(0, maxChars)
    truncated = true
  }
  return { text, truncated }
}

/** One fetch through the Worker's host-routed global `fetch`. */
class HostRoutedFetchProvider implements WebFetchProvider {
  readonly id = 'phone-host-fetch'
  private readonly maxResponseBytes: number
  private readonly maxBodyChars: number
  private readonly userAgent: string

  constructor(config: Config) {
    this.maxResponseBytes = positive(config.maxResponseBytes, DEFAULT_MAX_RESPONSE_BYTES)
    this.maxBodyChars = positive(config.maxBodyChars, DEFAULT_MAX_BODY_CHARS)
    this.userAgent = config.userAgent?.trim() || DEFAULT_USER_AGENT
  }

  /** The Worker's global fetch is the host route; no network call here. */
  available(): boolean {
    return typeof globalThis.fetch === 'function'
  }

  async fetch(request: WebFetchRequest, signal?: AbortSignal): Promise<WebFetchResult> {
    const url = requestURL(request.url)
    const response = await globalThis.fetch(url.toString(), {
      method: 'GET',
      redirect: 'follow',
      headers: {
        'user-agent': this.userAgent,
        accept: 'text/html,application/xhtml+xml,text/*;q=0.9,application/json;q=0.8,*/*;q=0.1',
      },
      ...signal === undefined ? {} : { signal },
    })
    const contentType = response.headers.get('content-type')
    const kind = bodyKind(contentType)
    if (kind === undefined) {
      await response.body?.cancel()
      throw new WebError(`unsupported content type "${contentType ?? 'unknown'}"`, 'WEB_UNSUPPORTED_CONTENT_TYPE')
    }
    const body = await readBody(response, decodeBody(contentType),
                               this.maxResponseBytes, this.maxBodyChars)
    return {
      url: response.url || url.toString(),
      statusCode: response.status,
      body: { kind, content: body.text },
      truncated: body.truncated,
    }
  }
}

/** Reject non-positive/invalid numeric tuning; the schema is plain JS. */
function positive(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback
}

/** Register the host-routed provider on `ctx.web`. */
export function apply(ctx: Context, config: Config = {}): void {
  ctx.web.registerFetchProvider(new HostRoutedFetchProvider(config))
}
