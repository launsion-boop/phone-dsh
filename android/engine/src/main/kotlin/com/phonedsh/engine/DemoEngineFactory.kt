// phone-dsh — :engine / com.phonedsh.engine: the one way a host builds the engine.
// SPDX-License-Identifier: MIT
//
// :app must not name WebViewEngine: importing that class would import the
// android.webkit surface into the UI lane, and the §6.3-5 single-WebView
// invariant is enforced by the host not being able to construct a second one.
// This factory is the only construction seam; it returns the WebView-free
// [DemoEngine].

package com.phonedsh.engine

import android.content.Context
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackHttpEgress
import com.phonedsh.loopback.LoopbackModelProxy
import com.phonedsh.loopback.NativeMcpServing

/**
 * Builds the one engine for [context].
 *
 * [channelHandler] is the codec seam owned by the host (every binary frame the
 * page sends arrives there unchanged), [workerAssets] is the bundle to
 * materialize, and [pageParams] are merged into the launch URL (`boot_id`,
 * `env`, `fence`, ...). An `env` entry is merged with the engine-owned launch
 * token; the `token`, `image` and `channel` names are reserved and ignored.
 *
 * [launchToken] supplies a fresh secret for every `start()`: the same value is
 * the loopback gate/cookie token and the worker's `PDSH_DSH_LAUNCH_TOKEN`, and
 * it is never logged or persisted. `:app` passes its own source so generation
 * happens at the composition root; the default keeps any other host safe.
 *
 * [httpEgress] is the `/v1/http` policy for the origin. `null` answers 503;
 * `:app` passes the `:net` gateway adapter so the Worker has one outbound path.
 *
 * [modelProxy] is the model-protocol edge, or `null` when this launch has no
 * configured upstream. `:app` builds it from the launch's real base URL and the
 * device key store; the engine mounts it on the origin and rewrites the Worker's
 * `DEEPSEEK_BASE_URL` to that origin. The engine never sees the key.
 *
 * [writesAllowed] is D14's admission as a lambda: `:app` passes
 * `{ controller.admission == Admission.OPEN }` so the channel-reopen lane never
 * reloads the page into a host that would refuse the fresh worker's writes (see
 * ChannelReopenLane.kt). The default `true` keeps a composition without a
 * controller working, at the cost of reloading immediately.
 *
 * [bootOverlaySource] is the `wal.md` §8 boot overlay producer. `:app` passes the
 * one built over its recovered log's `materialized/` tree. `null` keeps the
 * pre-P28 behaviour for a composition with no materialized tree, and the engine
 * then loads the page with no `?overlay=` at all — which is exactly the state that
 * loses a recovered workspace, so production must supply it.
 *
 * [nativeMcp] is the `/mcp/native` server (spec/v1/native-mcp.md), or `null`
 * when this host serves no native phone tools. When present the origin mounts it
 * behind the token gate, `tools/call` follows [writesAllowed], and the Worker env
 * gets `PDSH_PHONE_MCP_URL` / `PDSH_PHONE_MCP_TOKEN`.
 *
 * The default [logger] writes to logcat.
 */
fun createDemoEngine(
    context: Context,
    channelHandler: LoopbackChannelHandler,
    logger: EngineLogger = AndroidEngineLogger(),
    workerAssets: WorkerAssets,
    pageParams: Map<String, String> = emptyMap(),
    launchToken: LaunchTokenSource = LaunchTokenSource.fresh(),
    httpEgress: LoopbackHttpEgress? = null,
    modelProxy: LoopbackModelProxy? = null,
    writesAllowed: () -> Boolean = { true },
    bootOverlaySource: BootOverlaySource? = null,
    nativeMcp: NativeMcpServing? = null,
): DemoEngine = WebViewEngine(
    context,
    channelHandler,
    logger,
    workerAssets,
    pageParams,
    launchToken,
    httpEgress,
    modelProxy,
    writesAllowed,
    bootOverlaySource,
    nativeMcp,
)
