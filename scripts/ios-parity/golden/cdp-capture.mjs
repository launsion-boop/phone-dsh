#!/usr/bin/env node
/**
 * Deterministic 402x874 DPR3 screenshot of an already-running DSH Web UI.
 *
 * Zero dependencies: drives a headless Google Chrome over the DevTools Protocol
 * using Node's built-in global WebSocket (Node >= 22).
 *
 * The DSH Web UI keeps a WebSocket open, so Chrome's one-shot
 * `--screenshot --virtual-time-budget=N` never exits. This script instead waits
 * for the app's boot sentinel, captures one frame, and force-closes Chrome.
 *
 * Exits non-zero (and writes the report) when the official UI cannot boot, so a
 * harness can fail loudly instead of shipping a boot skeleton as a "screenshot".
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'

// Boot failure strings that must never be mistaken for a rendered UI.
const BOOT_FAILURE_MARKERS = [
  'bootstrap facade is missing',
  'Failed to load plugins',
  'web boot:',
]

function parseArgs(argv) {
  const args = {
    width: 402,
    height: 874,
    dpr: 3,
    theme: 'light',
    mobile: true,
    bootTimeoutMs: 45000,
    settleMs: 1500,
    report: null,
    label: 'official',
    keepProfile: false,
    chrome: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    out: null,
    url: null,
    profileDir: null,
    clicks: [],
    dismissOnboarding: false,
    requireText: null,
    requireTextTimeoutMs: 20000,
    probe: null,
    dumpDom: null,
    bodyTextMax: 6000,
    openSession: null,
    sessionDrawerSelector: 'button[aria-label="菜单"]',
    sessionDrawerCloseSelector: 'button[aria-label="关闭面板"]',
    sessionGroupSelector: '[data-row-key="workspace:"]',
    sessionOverflowSelector: '[data-row-key="overflow:"]',
    transcriptSelector: '[data-chat-node-key]',
    transcriptMinRows: 1,
    sessionTimeoutMs: 20000,
    afterOpenClicks: [],
    requireVisibleFlowKinds: [],
    transcriptRequireFlowKinds: [],
    requiredVisibleSelectors: [],
    scrollToSelector: null,
    failOnConsoleError: false,
    failOnNetworkError: false,
  }
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i]
    const next = () => {
      i += 1
      if (i >= argv.length) throw new Error(`missing value for ${key}`)
      return argv[i]
    }
    switch (key) {
      case '--url': args.url = next(); break
      case '--out': args.out = next(); break
      case '--report': args.report = next(); break
      case '--label': args.label = next(); break
      case '--width': args.width = Number(next()); break
      case '--height': args.height = Number(next()); break
      case '--dpr': args.dpr = Number(next()); break
      case '--theme': args.theme = next(); break
      case '--boot-timeout-ms': args.bootTimeoutMs = Number(next()); break
      case '--settle-ms': args.settleMs = Number(next()); break
      case '--chrome': args.chrome = next(); break
      case '--profile-dir': args.profileDir = next(); break
      case '--dismiss-onboarding': args.dismissOnboarding = true; break
      case '--require-text': args.requireText = next(); break
      case '--require-text-timeout-ms': args.requireTextTimeoutMs = Number(next()); break
      case '--click-text': args.clicks.push({ type: 'text', value: next() }); break
      case '--click-selector': args.clicks.push({ type: 'selector', value: next() }); break
      case '--probe': args.probe = next(); break
      case '--dump-dom': args.dumpDom = next(); break
      case '--body-text-max': args.bodyTextMax = Number(next()); break
      case '--open-session': args.openSession = next(); break
      case '--session-drawer-selector': args.sessionDrawerSelector = next(); break
      case '--session-drawer-close-selector': args.sessionDrawerCloseSelector = next(); break
      case '--session-group-selector': args.sessionGroupSelector = next(); break
      case '--session-overflow-selector': args.sessionOverflowSelector = next(); break
      case '--transcript-selector': args.transcriptSelector = next(); break
      case '--transcript-min-rows': args.transcriptMinRows = Number(next()); break
      case '--session-timeout-ms': args.sessionTimeoutMs = Number(next()); break
      case '--after-open-click-selector': args.afterOpenClicks.push(next()); break
      case '--require-visible-transcript-flow': args.requireVisibleFlowKinds.push(next()); break
      case '--transcript-require-flow-kind': args.transcriptRequireFlowKinds.push(next()); break
      case '--require-visible-selector': args.requiredVisibleSelectors.push(next()); break
      case '--scroll-to-selector': args.scrollToSelector = next(); break
      case '--fail-on-console-error': args.failOnConsoleError = true; break
      case '--fail-on-network-error': args.failOnNetworkError = true; break
      case '--desktop-metrics': args.mobile = false; break
      case '--keep-profile': args.keepProfile = true; break
      default: throw new Error(`unknown argument: ${key}`)
    }
  }
  if (!args.url) throw new Error('--url is required')
  if (!args.out) throw new Error('--out is required')
  return args
}

class Cdp {
  constructor(socket) {
    this.socket = socket
    this.nextId = 0
    this.pending = new Map()
    this.listeners = new Map()
    socket.addEventListener('message', (event) => {
      let message
      try {
        message = JSON.parse(typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString('utf8'))
      } catch {
        return
      }
      if (message.id !== undefined) {
        const entry = this.pending.get(message.id)
        if (!entry) return
        this.pending.delete(message.id)
        if (message.error) entry.reject(new Error(`${message.error.message} (${message.error.code})`))
        else entry.resolve(message.result)
        return
      }
      const handlers = this.listeners.get(message.method) ?? []
      for (const handler of handlers) handler(message.params, message.sessionId)
    })
  }

  static connect(url, timeoutMs = 15000) {
    return new Promise((resolvePromise, rejectPromise) => {
      const socket = new WebSocket(url)
      const timer = setTimeout(() => {
        socket.close()
        rejectPromise(new Error(`CDP connect timeout after ${timeoutMs}ms: ${url}`))
      }, timeoutMs)
      socket.addEventListener('open', () => {
        clearTimeout(timer)
        resolvePromise(new Cdp(socket))
      })
      socket.addEventListener('error', () => {
        clearTimeout(timer)
        rejectPromise(new Error(`CDP socket error: ${url}`))
      })
    })
  }

  on(method, handler) {
    const handlers = this.listeners.get(method) ?? []
    handlers.push(handler)
    this.listeners.set(method, handlers)
  }

  send(method, params = {}, sessionId) {
    this.nextId += 1
    const id = this.nextId
    const payload = { id, method, params }
    if (sessionId) payload.sessionId = sessionId
    const promise = new Promise((resolvePromise, rejectPromise) => {
      this.pending.set(id, { resolve: resolvePromise, reject: rejectPromise })
    })
    this.socket.send(JSON.stringify(payload))
    return promise
  }

  close() {
    try { this.socket.close() } catch { /* already closed */ }
  }
}

function pngSize(buffer) {
  if (buffer.length < 24 || buffer[0] !== 0x89 || buffer[1] !== 0x50) return null
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) }
}

function truncate(value, max = 4000) {
  if (typeof value !== 'string') return value
  return value.length > max ? `${value.slice(0, max)}…[truncated ${value.length - max} chars]` : value
}

function stringifyRemote(value) {
  if (value == null) return String(value)
  if (value.type === 'string') return value.value
  if ('value' in value) return String(value.value)
  return value.description ?? value.unserializableValue ?? value.type
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const outPath = resolve(args.out)
  mkdirSync(dirname(outPath), { recursive: true })

  if (!existsSync(args.chrome)) throw new Error(`Chrome not found: ${args.chrome}`)
  const profileDir = args.profileDir ?? join(dirname(outPath), '.chrome-profile')
  if (!args.keepProfile) rmSync(profileDir, { recursive: true, force: true })
  mkdirSync(profileDir, { recursive: true })

  const report = {
    label: args.label,
    createdAt: new Date().toISOString(),
    target: {
      url: args.url.replace(/token=[^&]+/, 'token=<redacted>'),
      viewport: { width: args.width, height: args.height, dpr: args.dpr },
      colorScheme: args.theme,
      mobile: args.mobile,
    },
    chrome: null,
    screenshot: null,
    runtime: null,
    console: { errors: [], warnings: [], exceptions: [], logEntries: [] },
    network: { failures: [], httpErrors: [] },
    boot: { ok: false, reason: null },
    session: null,
  }

  const chrome = spawn(args.chrome, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--disable-background-networking',
    '--disable-sync',
    '--hide-scrollbars',
    '--force-color-profile=srgb',
    '--remote-debugging-port=0',
    `--user-data-dir=${profileDir}`,
    `--window-size=${args.width},${args.height}`,
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'] })

  let chromeStderr = ''
  chrome.stderr.on('data', (chunk) => { chromeStderr += chunk.toString() })
  const chromeExit = new Promise((resolvePromise) => {
    chrome.once('exit', (code, signal) => resolvePromise({ code, signal }))
  })

  const cleanup = () => {
    try { chrome.kill('SIGKILL') } catch { /* already gone */ }
  }
  const watchdog = setTimeout(() => {
    console.error(`[cdp-capture] watchdog: killing Chrome after ${Math.round((args.bootTimeoutMs + 60000) / 1000)}s`)
    cleanup()
    process.exit(9)
  }, args.bootTimeoutMs + 60000)

  let cdp = null
  try {
    const devtoolsFile = join(profileDir, 'DevToolsActivePort')
    const devtoolsDeadline = Date.now() + 30000
    while (!existsSync(devtoolsFile)) {
      if (Date.now() > devtoolsDeadline) throw new Error('Chrome did not open a DevTools port within 30s')
      await sleep(100)
    }
    const [port] = readFileSync(devtoolsFile, 'utf8').split('\n')
    const base = `http://127.0.0.1:${port.trim()}`
    let pageTarget = null
    const targetDeadline = Date.now() + 15000
    while (!pageTarget) {
      const targets = await fetch(`${base}/json/list`).then((r) => r.json())
      pageTarget = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl)
      if (!pageTarget) {
        if (Date.now() > targetDeadline) throw new Error('no page target exposed by Chrome')
        await sleep(150)
      }
    }
    report.chrome = { executable: args.chrome, version: null, remoteDebuggingPort: Number(port.trim()) }

    cdp = await Cdp.connect(pageTarget.webSocketDebuggerUrl)
    cdp.on('Runtime.exceptionThrown', (params) => {
      const details = params.exceptionDetails ?? {}
      report.console.exceptions.push({
        text: truncate(details.exception?.description ?? details.text ?? 'unknown exception'),
        url: details.url,
        line: details.lineNumber,
        column: details.columnNumber,
      })
    })
    cdp.on('Runtime.consoleAPICalled', (params) => {
      const level = params.type
      const text = truncate((params.args ?? []).map(stringifyRemote).join(' '))
      if (level === 'error') report.console.errors.push({ source: 'console', text })
      else if (level === 'warning') report.console.warnings.push({ source: 'console', text })
    })
    cdp.on('Log.entryAdded', (params) => {
      const entry = params.entry ?? {}
      const record = { source: entry.source, level: entry.level, text: truncate(entry.text), url: entry.url }
      if (entry.level === 'error') report.console.errors.push(record)
      else if (entry.level === 'warning') report.console.warnings.push(record)
      else report.console.logEntries.push(record)
    })
    cdp.on('Network.loadingFailed', (params) => {
      if (params.canceled) return
      report.network.failures.push({
        errorText: params.errorText,
        type: params.type,
        blockedReason: params.blockedReason ?? null,
      })
    })
    cdp.on('Network.responseReceived', (params) => {
      const response = params.response ?? {}
      if (response.status >= 400) {
        report.network.httpErrors.push({ url: response.url, status: response.status })
      }
    })

    await cdp.send('Runtime.enable')
    await cdp.send('Log.enable')
    await cdp.send('Page.enable')
    await cdp.send('Network.enable')
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      width: args.width,
      height: args.height,
      deviceScaleFactor: args.dpr,
      mobile: args.mobile,
      screenWidth: args.width,
      screenHeight: args.height,
      screenOrientation: { type: 'portraitPrimary', angle: 0 },
    })
    await cdp.send('Emulation.setEmulatedMedia', {
      media: 'screen',
      features: [{ name: 'prefers-color-scheme', value: args.theme }],
    })
    await cdp.send('Emulation.setTouchEmulationEnabled', { enabled: args.mobile, maxTouchPoints: 5 })

    const nav = await cdp.send('Page.navigate', { url: args.url })
    if (nav.errorText) throw new Error(`navigation failed: ${nav.errorText}`)

    const probe = `(() => {
      const root = document.getElementById('root')
      const text = (document.body && document.body.innerText) || ''
      const skeletonPresent = !!document.querySelector('[data-dsh-boot-skeleton]')
      const rootChildren = root ? root.children.length : -1
      return {
        url: location.href,
        title: document.title,
        readyState: document.readyState,
        bootMounted: !!document.querySelector('[data-dsh-boot]'),
        skeletonPresent,
        rootChildren,
        appMounted: !skeletonPresent && rootChildren > 0 && text.trim().length > 10,
        bodyText: text,
        viewport: {
          innerWidth: window.innerWidth,
          innerHeight: window.innerHeight,
          dpr: window.devicePixelRatio,
          visualWidth: window.visualViewport ? window.visualViewport.width : null,
          visualHeight: window.visualViewport ? window.visualViewport.height : null,
        },
      }
    })()`

    const bootDeadline = Date.now() + args.bootTimeoutMs
    let state = null
    while (Date.now() < bootDeadline) {
      const result = await cdp.send('Runtime.evaluate', { expression: probe, returnByValue: true })
      state = result.result?.value ?? null
      if (state?.bootMounted || state?.appMounted) break
      await sleep(250)
    }
    if (!state) throw new Error('Runtime.evaluate returned no value while waiting for boot')
    report.runtime = {
      finalUrl: state.url,
      title: state.title,
      viewport: state.viewport,
      bootMounted: state.bootMounted,
      skeletonPresent: state.skeletonPresent,
    }

    const failureMarkers = BOOT_FAILURE_MARKERS.filter((marker) => (state.bodyText ?? '').includes(marker))
    if ((!state.bootMounted && !state.appMounted) || failureMarkers.length > 0) {
      report.boot.reason = failureMarkers.length
        ? `boot failure marker(s): ${failureMarkers.join(' | ')}`
        : 'no boot sentinel and no mounted app in #root (skeleton still present or empty)'
      report.boot.bodyText = truncate(state.bodyText)
      throw new Error(`official UI did not boot: ${report.boot.reason}`)
    }

    // Official first-run affordances. The harness never edits official UI: it only
    // presses controls a user would press. Order matters (PWA banner -> preview
    // notice -> auth gate), but each is retried because they mount asynchronously.
    const ONBOARDING_TARGETS = [
      { kind: 'pwa-install-banner-close', spec: { type: 'selector', value: 'button[aria-label="关闭提示"]' } },
      { kind: 'preview-notice-continue', spec: { type: 'text', value: '继续' } },
      { kind: 'get-started-dialog-close', spec: { type: 'selector', value: 'button[aria-label="关闭"]' } },
    ]

    const visibleRectGuard = `
      const visible = (el) => {
        const r = el.getBoundingClientRect()
        return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth
      }`

    const buildClickExpression = (spec) => (spec.type === 'selector'
      ? `(() => {${visibleRectGuard}
          const el = document.querySelector(${JSON.stringify(spec.value)})
          if (!el || !visible(el)) return null
          const r = el.getBoundingClientRect()
          el.click()
          return { tag: el.tagName, text: (el.innerText || el.getAttribute('aria-label') || '').trim().slice(0, 120),
            rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) } }
        })()`
      : `(() => {${visibleRectGuard}
          const wanted = ${JSON.stringify(spec.value)}
          const nodes = Array.from(document.querySelectorAll('button,[role="button"],a')).filter(visible)
          const el = nodes.find((node) => ((node.innerText || '').trim()) === wanted)
            || nodes.find((node) => ((node.innerText || '').trim()).startsWith(wanted))
          if (!el) return null
          const r = el.getBoundingClientRect()
          el.click()
          return { tag: el.tagName, text: (el.innerText || el.getAttribute('aria-label') || '').trim().slice(0, 120),
            rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) } }
        })()`)

    const tryClick = async (spec) => {
      const result = await cdp.send('Runtime.evaluate', { expression: buildClickExpression(spec), returnByValue: true })
      return result.result?.value ?? null
    }

    const specExists = async (spec) => {
      const expression = buildClickExpression(spec).replace('el.click()', 'void 0')
      const result = await cdp.send('Runtime.evaluate', { expression, returnByValue: true })
      return Boolean(result.result?.value)
    }

    const clickWithRetry = async (spec, timeoutMs) => {
      const clickDeadline = Date.now() + timeoutMs
      while (Date.now() < clickDeadline) {
        const clicked = await tryClick(spec)
        if (clicked) return clicked
        await sleep(250)
      }
      return null
    }

    report.interactions = []
    if (args.dismissOnboarding) {
      // Overlays mount asynchronously (plugins load, PWA prompt fires, the auth
      // gate follows the preview notice), so watch for a minimum window instead
      // of trusting the first quiet pass, and require two consecutive quiet
      // passes after that window before declaring the state clean.
      const sweepStart = Date.now()
      const minSweepMs = 8000
      const maxSweepMs = 30000
      let pass = 0
      let quietPasses = 0
      while (Date.now() - sweepStart < maxSweepMs) {
        pass += 1
        let acted = false
        for (const target of ONBOARDING_TARGETS) {
          const clicked = await tryClick(target.spec)
          if (!clicked) continue
          acted = true
          report.interactions.push({ pass, kind: target.kind, requested: target.spec, clicked, ok: true })
          console.log(`[cdp-capture] dismissed ${target.kind} (pass ${pass})`)
          await sleep(600)
        }
        if (acted) {
          quietPasses = 0
        } else {
          quietPasses += 1
          if (Date.now() - sweepStart >= minSweepMs && quietPasses >= 2) break
        }
        await sleep(500)
      }
      const leftovers = []
      for (const target of ONBOARDING_TARGETS) {
        if (await specExists(target.spec)) leftovers.push(target.kind)
      }
      report.leftoverOverlays = leftovers
      if (leftovers.length > 0) {
        throw new Error(`onboarding overlay still present after dismissal sweep: ${leftovers.join(', ')}`)
      }
    } else {
      report.leftoverOverlays = []
    }

    // Explicit clicks always run after the sweep: the session path needs
    // "dismiss first-run overlays, then open the sidebar / a session".
    for (const spec of args.clicks) {
      const clicked = await clickWithRetry(spec, 8000)
      report.interactions.push({ kind: 'explicit', requested: spec, clicked, ok: Boolean(clicked) })
      if (!clicked) console.warn(`[cdp-capture] warning: nothing matched ${spec.type} "${spec.value}"`)
      await sleep(600)
    }

    const evaluate = async (expression) => {
      const result = await cdp.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
      return result.result?.value ?? null
    }
    const waitForValue = async (expression, timeoutMs, intervalMs = 250) => {
      const deadline = Date.now() + timeoutMs
      let value = null
      while (Date.now() < deadline) {
        value = await evaluate(expression)
        if (value) return value
        await sleep(intervalMs)
      }
      return value
    }

    // ---------------------------------------------------------- session open
    //
    // Open an existing recorded session the way a user does at 402px: drawer
    // toggle -> workspace group (folded by default) -> "show remaining" when
    // the row is past the list cap -> session row -> close the drawer. Every
    // step is a real click on a real control, and the assertions below fail the
    // capture rather than shipping a session list or an empty chat as a
    // "conversation" screenshot.
    if (args.openSession) {
      report.session = {
        requestedId: args.openSession,
        steps: [],
        openedId: null,
        title: null,
        documentTitle: null,
        drawerClosed: null,
        transcript: null,
        requiredSelectors: [],
      }
      const sessionRowSelector = `[data-row-key="session:${args.openSession}"]`
      const sidebarOpen = () => evaluate(`(() => {
        const frame = document.querySelector('[data-mobile-frame]')
        if (!frame) return null
        return !frame.hasAttribute('data-sidebar-collapsed')
      })()`)
      const step = async (kind, selector, timeoutMs) => {
        const clicked = await clickWithRetry({ type: 'selector', value: selector }, timeoutMs)
        report.session.steps.push({ kind, selector, ok: Boolean(clicked), clicked })
        if (clicked) await sleep(600)
        return clicked
      }

      if (!await sidebarOpen()) {
        if (!await step('open-drawer', args.sessionDrawerSelector, args.sessionTimeoutMs)) {
          throw new Error(`could not open the session drawer: nothing matched ${args.sessionDrawerSelector}`)
        }
      }
      const rowPresent = () => evaluate(`!!document.querySelector(${JSON.stringify(sessionRowSelector)})`)
      if (!await rowPresent()) {
        // Workspace groups render folded until clicked; the ungrouped bucket
        // exists in this profile, so expand it.
        await step('expand-group', args.sessionGroupSelector, 5000)
      }
      if (!await rowPresent()) await step('expand-overflow', args.sessionOverflowSelector, 5000)
      if (!await waitForValue(`!!document.querySelector(${JSON.stringify(sessionRowSelector)})`, 8000, 300)) {
        const available = await evaluate(`Array.from(document.querySelectorAll('[data-row-key^="session:"]')).map((el) => el.getAttribute('data-row-key'))`)
        throw new Error(`session ${args.openSession} is not in the sidebar list; available: ${JSON.stringify(available)}`)
      }
      if (!await step('open-session', sessionRowSelector, 8000)) {
        throw new Error(`could not click the session row ${sessionRowSelector}`)
      }
      const openedId = await waitForValue(
        `(() => { const el = document.querySelector('[data-conversation-session]'); return el ? el.getAttribute('data-conversation-session') : null })()`,
        args.sessionTimeoutMs,
      )
      if (!openedId) throw new Error('no [data-conversation-session] after clicking the session row; the conversation did not open')
      if (openedId !== args.openSession) throw new Error(`opened session ${openedId} but requested ${args.openSession}`)
      report.session.openedId = openedId

      if (await sidebarOpen()) {
        const closed = await step('close-drawer', args.sessionDrawerCloseSelector, 5000)
        const settled = await waitForValue(`(() => {
          const frame = document.querySelector('[data-mobile-frame]')
          return !frame || frame.hasAttribute('data-sidebar-collapsed')
        })()`, 5000)
        report.session.drawerClosed = Boolean(closed && settled)
        if (!report.session.drawerClosed) throw new Error('the drawer did not close over the conversation before capture')
      } else {
        report.session.drawerClosed = true
      }

      // Transcript rows are the proof that this is a chat, not the hero.
      const transcriptProbe = `(() => {
        const nodes = Array.from(document.querySelectorAll(${JSON.stringify(args.transcriptSelector)}))
        const flowKinds = [...new Set(nodes.map((el) => el.getAttribute('data-chat-flow-kind')).filter(Boolean))]
        const turns = [...new Set(nodes.map((el) => el.getAttribute('data-chat-turn')).filter(Boolean))]
        const visibleFlowKinds = [...new Set(nodes
          .filter((el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; })
          .map((el) => el.getAttribute('data-chat-flow-kind')).filter(Boolean))]
        return {
          rows: nodes.length,
          flowKinds,
          visibleFlowKinds,
          turns,
          keys: nodes.map((el) => el.getAttribute('data-chat-node-key')).filter(Boolean),
        }
      })()`

      // Some chat rows (the collapsed turn-process group that owns reasoning and
      // tool calls) only exist at zero height until the reader expands them. The
      // click is a real click on the group header, and the visible-flow assertion
      // below fails the capture if the card never actually renders.
      for (const selector of args.afterOpenClicks) {
        const clicked = await clickWithRetry({ type: 'selector', value: selector }, 8000)
        report.session.steps.push({ kind: 'expand-transcript', selector, ok: Boolean(clicked), clicked })
        if (!clicked) throw new Error(`could not click the post-open control ${selector}`)
        await sleep(600)
      }

      // Which flow kinds prove this is the requested transcript. The default
      // keeps the original contract (a human user row); command-opened turns
      // (`/plan`, steered fixtures) have no `user` row, so a capture can state
      // the kinds its transcript must contain instead.
      const requiredFlowKinds = args.transcriptRequireFlowKinds.length > 0
        ? args.transcriptRequireFlowKinds
        : ['user']
      const transcript = await waitForValue(
        `(() => {
          const t = ${transcriptProbe}
          const wanted = ${JSON.stringify(requiredFlowKinds)}
          return t.rows >= ${args.transcriptMinRows} && wanted.every((kind) => t.flowKinds.includes(kind)) ? t : null
        })()`,
        args.sessionTimeoutMs,
        300,
      )
      if (!transcript) {
        const observed = await evaluate(transcriptProbe)
        const visibleText = await evaluate(`(document.body && document.body.innerText || '').slice(0, 1500)`)
        throw new Error(`session opened but no chat transcript rows (need >= ${args.transcriptMinRows} row(s) with flow kind(s) ${JSON.stringify(requiredFlowKinds)}); observed: ${JSON.stringify(observed)}; page text: ${JSON.stringify(visibleText)}`)
      }
      if (args.requireVisibleFlowKinds.length > 0) {
        const visible = await waitForValue(
          `(() => {
            const t = ${transcriptProbe}
            const wanted = ${JSON.stringify(args.requireVisibleFlowKinds)}
            return wanted.every((kind) => t.visibleFlowKinds.includes(kind)) ? t : null
          })()`,
          args.sessionTimeoutMs,
          300,
        )
        if (!visible) {
          const observed = await evaluate(transcriptProbe)
          throw new Error(`required transcript rows are not visible after opening: ${JSON.stringify(args.requireVisibleFlowKinds)}; observed: ${JSON.stringify(observed)}`)
        }
      }
      // Follow the tail like a reader would, so the turn tail (and any failure
      // card) is in frame instead of a mid-message scroll position. A card that
      // lives inside a collapsed turn process is earlier in the transcript, so a
      // capture may instead scroll its own proof element into view.
      if (args.scrollToSelector !== null) {
        const scrolled = await waitForValue(`(() => {
          const el = document.querySelector(${JSON.stringify(args.scrollToSelector)})
          if (!el) return null
          el.scrollIntoView({ block: 'center', inline: 'nearest' })
          const scroller = document.querySelector('[data-conversation-scroll]')
          const r = el.getBoundingClientRect()
          return {
            selector: ${JSON.stringify(args.scrollToSelector)},
            scrollTop: scroller ? scroller.scrollTop : null,
            scrollHeight: scroller ? scroller.scrollHeight : null,
            clientHeight: scroller ? scroller.clientHeight : null,
            rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) },
          }
        })()`, 8000, 300)
        if (!scrolled) throw new Error(`could not scroll the required element into view: ${args.scrollToSelector}`)
        report.session.scrollTo = scrolled
      } else {
        report.session.follow = await evaluate(`(() => {
          const el = document.querySelector('[data-conversation-scroll]')
          if (!el) return null
          el.scrollTop = el.scrollHeight
          return { scrollTop: el.scrollTop, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight }
        })()`)
      }
      await sleep(500)

      // Content assertions on the rendered transcript: each selector must match
      // at least one visible element, and the reported text proves what the card
      // actually shows instead of trusting that "some row exists".
      if (args.requiredVisibleSelectors.length > 0) {
        report.session.requiredSelectors = []
        for (const selector of args.requiredVisibleSelectors) {
          const observed = await waitForValue(`(() => {
            const nodes = Array.from(document.querySelectorAll(${JSON.stringify(selector)}))
            const visible = nodes.filter((el) => {
              const r = el.getBoundingClientRect()
              const style = getComputedStyle(el)
              return r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < innerHeight
                && r.right > 0 && r.left < innerWidth
                && style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0
            })
            if (visible.length === 0) return null
            const first = visible[0]
            const r = first.getBoundingClientRect()
            const scroller = document.querySelector('[data-conversation-scroll]')
            return {
              selector: ${JSON.stringify(selector)},
              count: nodes.length,
              visibleCount: visible.length,
              text: String(first.innerText ?? '').trim().slice(0, 400),
              ariaLabel: first.getAttribute('aria-label'),
              rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) },
              scrollTop: scroller ? scroller.scrollTop : null,
            }
          })()`, args.sessionTimeoutMs, 300)
          report.session.requiredSelectors.push(observed ?? { selector, count: 0, visibleCount: 0, missing: true })
          if (!observed) throw new Error(`required visible element not found: ${selector}`)
          console.log(`[cdp-capture] required selector ${selector}: ${observed.visibleCount}/${observed.count} visible — ${JSON.stringify(observed.text.slice(0, 120))}`)
        }
      }

      report.session.transcript = await evaluate(transcriptProbe)
      report.session.documentTitle = await evaluate('document.title')
      report.session.title = String(report.session.documentTitle ?? '').replace(/\s+—\s+.*$/, '')
      console.log(`[cdp-capture] opened ${openedId} "${report.session.title}": ` +
        `${report.session.transcript?.rows} transcript row(s) ${JSON.stringify(report.session.transcript?.flowKinds)}`)
    }

    if (args.probe) {
      const probeResult = await cdp.send('Runtime.evaluate', {
        expression: args.probe,
        returnByValue: true,
        awaitPromise: true,
      })
      report.probe = probeResult.result?.value ?? probeResult.result ?? null
      console.log('[cdp-capture] probe:', JSON.stringify(report.probe, null, 2))
    }

    if (args.dumpDom) {
      // Debug aid for the session path: record what the 402px page actually
      // shows (text, user-visible controls, data-* hooks) so selectors are
      // chosen from the real DOM instead of guessed class names.
      const dumpExpression = `(() => {
        const clamp = (value, max) => (typeof value === 'string' && value.length > max ? value.slice(0, max) + '…[truncated]' : value)
        const visible = (el) => {
          const r = el.getBoundingClientRect()
          if (r.width <= 0 || r.height <= 0) return false
          if (r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) return false
          const style = getComputedStyle(el)
          return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0
        }
        const describe = (el) => {
          const r = el.getBoundingClientRect()
          const attrs = {}
          for (const attr of el.attributes) {
            if (!(attr.name.startsWith('data-') || ['href', 'role', 'aria-label', 'title', 'type', 'name', 'aria-expanded', 'aria-selected', 'disabled', 'aria-disabled'].includes(attr.name))) continue
            attrs[attr.name] = clamp(attr.value, 200)
          }
          return {
            tag: el.tagName.toLowerCase(),
            text: clamp((el.innerText || '').trim(), 300),
            rect: { x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) },
            attrs,
          }
        }
        const interactive = Array.from(document.querySelectorAll('button,[role="button"],a[href],[role="link"],[role="tab"],[role="menuitem"],input,textarea,select')).filter(visible).map(describe)
        const labelled = Array.from(document.querySelectorAll('[role="dialog"],[aria-modal="true"],[role="list"],[role="listitem"],[role="log"],[role="main"],[role="navigation"],[role="complementary"],[role="status"],[aria-live]')).filter(visible).map(describe)
        const dataAttributes = {}
        for (const el of document.querySelectorAll('*')) {
          for (const attr of el.attributes) {
            if (!attr.name.startsWith('data-')) continue
            const entry = dataAttributes[attr.name] ?? (dataAttributes[attr.name] = { count: 0, samples: [] })
            entry.count += 1
            if (entry.samples.length < 5 && !entry.samples.includes(attr.value)) entry.samples.push(clamp(attr.value, 160))
          }
        }
        return {
          url: location.href,
          title: document.title,
          scrollHeight: document.documentElement.scrollHeight,
          htmlLength: document.documentElement.outerHTML.length,
          bodyTextLength: (document.body ? document.body.innerText : '').length,
          bodyText: clamp(document.body ? document.body.innerText : '', ${Math.max(args.bodyTextMax * 4, 8000)}),
          interactive,
          labelled,
          dataAttributes,
          iframeCount: document.querySelectorAll('iframe').length,
        }
      })()`
      const dumpResult = await cdp.send('Runtime.evaluate', { expression: dumpExpression, returnByValue: true })
      const dump = dumpResult.result?.value ?? null
      const dumpPath = resolve(args.dumpDom)
      mkdirSync(dirname(dumpPath), { recursive: true })
      writeFileSync(dumpPath, `${JSON.stringify(dump, null, 2)}\n`)
      report.domDump = {
        path: dumpPath,
        interactiveCount: dump?.interactive?.length ?? null,
        bodyTextLength: dump?.bodyTextLength ?? null,
        dataAttributes: dump ? Object.keys(dump.dataAttributes) : [],
      }
      console.log(`[cdp-capture] dumped DOM: ${dumpPath} (${dump?.interactive?.length ?? 0} visible controls)`)
    }

    if (args.requireText) {
      const requireDeadline = Date.now() + args.requireTextTimeoutMs
      let found = false
      while (Date.now() < requireDeadline && !found) {
        const result = await cdp.send('Runtime.evaluate', {
          expression: `(document.body && document.body.innerText || '').includes(${JSON.stringify(args.requireText)})`,
          returnByValue: true,
        })
        found = result.result?.value === true
        if (!found) await sleep(300)
      }
      report.requiredText = { text: args.requireText, found }
      if (!found) {
        throw new Error(`required state text not found before capture: ${JSON.stringify(args.requireText)}`)
      }
    }

    // Let fonts, CSS and the first plugin paint settle; capture the longest text snapshot.
    let previousText = state.bodyText ?? ''
    let stable = 0
    const settleDeadline = Date.now() + Math.max(args.settleMs * 4, 8000)
    while (Date.now() < settleDeadline && stable < 2) {
      await sleep(400)
      const result = await cdp.send('Runtime.evaluate', { expression: probe, returnByValue: true })
      const next = result.result?.value
      if (!next) break
      state = next
      if ((next.bodyText ?? '') === previousText) stable += 1
      else stable = 0
      previousText = next.bodyText ?? ''
    }

    // A golden may not ship through a console error or an uncaught exception:
    // check right before the frame so the report still records the failure.
    if (args.failOnConsoleError) {
      const errors = report.console.errors
      const exceptions = report.console.exceptions
      report.consoleGate = { enabled: true, errorCount: errors.length, exceptionCount: exceptions.length }
      if (errors.length > 0 || exceptions.length > 0) {
        const first = errors[0]?.text ?? exceptions[0]?.text ?? 'unknown'
        throw new Error(`console gate failed: ${errors.length} error(s), ${exceptions.length} exception(s); first: ${JSON.stringify(first.slice(0, 300))}`)
      }
    }
    // Network failures and HTTP >= 400 are the other half of "the page rendered
    // from a healthy server": a golden may not ship through a broken asset, a
    // failed API call or a plugin request that 404'd.
    if (args.failOnNetworkError) {
      const failures = report.network.failures
      const httpErrors = report.network.httpErrors
      report.networkGate = { enabled: true, failureCount: failures.length, httpErrorCount: httpErrors.length }
      if (failures.length > 0 || httpErrors.length > 0) {
        const first = httpErrors[0] === undefined
          ? failures[0]?.errorText ?? 'unknown'
          : `${httpErrors[0].status} ${httpErrors[0].url}`
        throw new Error(`network gate failed: ${failures.length} failure(s), ${httpErrors.length} HTTP error(s); first: ${JSON.stringify(String(first).slice(0, 300))}`)
      }
    }

    const shot = await cdp.send('Page.captureScreenshot', {
      format: 'png',
      fromSurface: true,
      captureBeyondViewport: false,
    })
    const buffer = Buffer.from(shot.data, 'base64')
    writeFileSync(outPath, buffer)
    const size = pngSize(buffer)
    report.screenshot = {
      path: outPath,
      width: size?.width ?? null,
      height: size?.height ?? null,
      bytes: buffer.length,
      expectedWidth: args.width * args.dpr,
      expectedHeight: args.height * args.dpr,
    }
    report.runtime = {
      ...report.runtime,
      finalUrl: state.url,
      title: state.title,
      viewport: state.viewport,
      bootMounted: state.bootMounted,
      appMounted: state.appMounted,
      skeletonPresent: state.skeletonPresent,
    }
    report.boot = {
      ok: true,
      reason: null,
      sentinel: '[data-dsh-boot]',
      bodyTextHead: truncate(state.bodyText, args.bodyTextMax),
    }
    report.console = {
      errors: report.console.errors,
      warnings: report.console.warnings,
      exceptions: report.console.exceptions,
      logEntries: report.console.logEntries.slice(0, 100),
    }

    if (report.screenshot.width !== args.width * args.dpr || report.screenshot.height !== args.height * args.dpr) {
      throw new Error(
        `screenshot is ${report.screenshot.width}x${report.screenshot.height}, expected ${args.width * args.dpr}x${args.height * args.dpr}`,
      )
    }
    console.log(`[cdp-capture] ${args.label}: ${outPath} ${report.screenshot.width}x${report.screenshot.height} ` +
      `css=${state.viewport.innerWidth}x${state.viewport.innerHeight}@${state.viewport.dpr}`)
    return 0
  } finally {
    clearTimeout(watchdog)
    if (cdp) cdp.close()
    cleanup()
    await Promise.race([chromeExit, sleep(3000)])
    if (!args.keepProfile) {
      try {
        rmSync(profileDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
      } catch (error) {
        console.warn(`[cdp-capture] warning: could not remove temporary Chrome profile ${profileDir}: ${error.message}`)
      }
    }
    if (args.report) {
      mkdirSync(dirname(resolve(args.report)), { recursive: true })
      writeFileSync(resolve(args.report), `${JSON.stringify(report, null, 2)}\n`)
    }
    if (chromeStderr.trim() && !report.boot.ok && report.chrome) {
      report.chrome.stderrTail = truncate(chromeStderr.trim().split('\n').slice(-20).join('\n'))
      if (args.report) writeFileSync(resolve(args.report), `${JSON.stringify(report, null, 2)}\n`)
    }
  }
}

main().then((code) => {
  process.exit(code ?? 0)
}).catch((error) => {
  console.error(`[cdp-capture] FAILED: ${error.message}`)
  process.exit(1)
})
