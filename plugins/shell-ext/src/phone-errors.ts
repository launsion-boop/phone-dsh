// SPDX-License-Identifier: MIT

const READ_ONLY_PHONE_TOOLS = new Set([
  'files.list',
  'pdf.text',
  'pdf.render_pages',
  'docx.read',
  'xlsx.read',
  'csv.analyze',
  'ocr.image',
  'contacts.search',
])

interface ProviderFailureInput {
  readonly exitCode: number
  readonly providerCode?: string
  readonly providerMessage?: string
}

export function phoneProviderFailure(tool: string | undefined, result: ProviderFailureInput): string | undefined {
  const providerCode = result.providerCode
  const isTimeout = result.exitCode === 124 || providerCode === 'deadline_exceeded'
  if (providerCode === undefined && !isTimeout && result.exitCode !== 69) return undefined

  const isAdmission = providerCode === 'admission_closed'
  const isCancelled = providerCode === 'cancelled' || result.exitCode === 130
  const code = isAdmission ? providerCode
    : isTimeout ? 'provider_timeout'
      : isCancelled ? 'cancelled' : 'provider_unavailable'
  const message = providerCode === 'admission_closed'
    ? 'Phone DSH is not accepting tools; return to the foreground or wait for recovery'
    : isTimeout
      ? 'The host tool did not finish before the execution deadline'
      : result.providerMessage ?? 'The host tool provider is unavailable'
  const error: Record<string, unknown> = {
    code,
    message: message.slice(0, 240),
    retryable: isAdmission || (isTimeout && tool !== undefined && READ_ONLY_PHONE_TOOLS.has(tool)),
    foreground_required: isAdmission,
    outcome: isAdmission ? 'not_started' : isCancelled ? 'cancelled' : 'unknown',
  }
  if (tool !== undefined) error.tool = tool
  if (providerCode !== undefined && providerCode !== code) error.cause = providerCode
  return JSON.stringify({ ok: false, error })
}
