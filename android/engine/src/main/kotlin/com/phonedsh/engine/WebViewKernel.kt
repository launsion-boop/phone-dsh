// phone-dsh — :engine / com.phonedsh.engine: the WebView kernel matrix and the
// runtime feature gate (plan §6.2, §6.3-3, risk R4).
// SPDX-License-Identifier: MIT
//
// Why this file exists
// --------------------
// The plan demotes *version numbers* to telemetry and makes *runtime feature
// detection* the gate. Two facts force that split:
//
//  1. Huawei's `com.huawei.webview` is a Chromium ~99 baseline whose versionName
//     uses a different numbering scheme entirely, is not updatable through Play,
//     and (on HarmonyOS NEXT) is not Android WebView at all. Parsing versionName
//     as "the Chromium version" is therefore wrong on exactly the devices the
//     plan worries about.
//  2. Play updates WebView between two app releases (risk R15), so a build-time
//     assumption can be false at runtime without anything in the APK changing.
//
// The plan's "feature baseline ≤ M99" premise did not survive measurement
// --------------------------------------------------------------------
// `ReadableStream.prototype[Symbol.asyncIterator]` only became native in
// Chromium 124 (see [ChromiumVersion.FLOOR_MAJOR]). A Chromium-99-class engine —
// the Huawei baseline this file was written around, and the WebView 109 of the
// `android-33` system image we measured — cannot run the worker *natively*, and
// the first version of this gate refused exactly those kernels. What keeps them
// working is the worker's own prelude: `plugins/worker-entry/src/boot.ts`
// imports `jsc-compat.ts`, `es2023-compat.ts`, `abort-signal-compat.ts` and
// `scheduler-compat.ts` before any DSH module evaluates. The gate must
// therefore measure the **post-prelude** surface the worker will actually see,
// which is what [WebViewKernelProbe.SCRIPT] does. That installation is a copy
// of the prelude — a copy can drift — so
// `plugins/worker-entry/src/webview-kernel-probe.test.ts` extracts the
// properties both sides install and fails, naming the missing one, when the
// copy falls behind. The floor is a diagnostic number only; it never refuses a
// kernel.
//
// So this file does three things, in order of authority:
//
//   * reads the *provider identity* (package + versionName) for telemetry only;
//   * reads the *actual engine version* from the user agent (`Chrome/NN`), which
//     is what the engine itself reports, and which a versionName can never
//     override;
//   * asks the running engine which APIs it actually has, by evaluating a small
//     probe whose every entry is a behavioural check. That result — not a
//     version comparison — decides the gate.
//
// The feature list is not invented: each id cites the worker code that needs it
// (see [KernelFeature.why]). Two of them are the ones the plan names by hand:
// ReadableStream async iteration and the `Symbol.dispose` shim.
//
// Degradation is reported, never silent
// -------------------------------------
// [KernelVerdict.UNSUPPORTED] means the worker cannot run on this engine. The
// engine refuses to pretend otherwise (it fails loud, and the host renders the
// reason instead of an empty surface). [KernelVerdict.DEGRADED] means the worker
// runs but the engine is outside the validated baseline (older than the floor, or
// its version could not be read); that is reported and never used to block a
// working page. [KernelVerdict.UNVERIFIED] means no probe ran: the host must
// render 未知, not "supported".

package com.phonedsh.engine

import org.json.JSONObject
import org.json.JSONTokener

/**
 * One runtime API the worker depends on.
 *
 * @param id the stable telemetry id, also the key in the probe's JSON.
 * @param required `true` when the worker cannot boot without it.
 * @param why the worker code that justifies the dependency (a probe nobody can
 *   trace back to real code rots into superstition).
 */
public enum class KernelFeature(
    public val id: String,
    public val required: Boolean,
    public val why: String,
) {
    /**
     * `ReadableStream.prototype[Symbol.asyncIterator]`, native **or via the
     * worker's prelude**.
     *
     * The worker's `iterator()` helper prefers `source[Symbol.asyncIterator]`
     * and only then `source[Symbol.iterator]`; a `ReadableStream` that has
     * neither throws `for-await source is neither async nor sync iterable`.
     * Native support arrived in Chromium 124 (see [ChromiumVersion.FLOOR_MAJOR]),
     * so on Chromium 99/109 the worker depends on
     * `plugins/worker-entry/src/jsc-compat.ts`, which installs the iterator
     * before any DSH module evaluates.
     *
     * The probe installs the Worker's prelude first — see
     * [WebViewKernelProbe.SCRIPT], whose copy of the prelude surface is asserted
     * against the real modules by `webview-kernel-probe.test.ts` — and then
     * *consumes* one chunk through the installed method, so "present" means the
     * worker's call shape works here, not merely that a function is defined.
     */
    READABLE_STREAM_ASYNC_ITERATION(
        id = "readable-stream-async-iteration",
        required = true,
        why = "worker/worker.js iterator(): source[Symbol.asyncIterator]; " +
            "prelude worker-entry/src/jsc-compat.ts installs it when native is missing",
    ),

    /**
     * `ReadableStream.prototype.pipeThrough`.
     *
     * `inflateImageStream` builds its pipeline with
     * `body.pipeThrough(requireGzipMember(source)).pipeThrough(...)`.
     */
    READABLE_STREAM_PIPE_THROUGH(
        id = "readable-stream-pipe-through",
        required = true,
        why = "worker/worker.js inflateImageStream(): body.pipeThrough(...)",
    ),

    /**
     * `DecompressionStream("gzip")` with a readable/writable pair.
     *
     * The image arrives as `image.tar.gz` and is inflated with
     * `new DecompressionStream("gzip")`; without it the worker cannot mount the
     * workspace at all.
     */
    DECOMPRESSION_STREAM_GZIP(
        id = "decompression-stream-gzip",
        required = true,
        why = "worker/worker.js inflateImageStream(): new DecompressionStream(\"gzip\")",
    ),

    /**
     * The `Symbol.dispose` shim is effective.
     *
     * The worker does not require the native symbol: its primordials helper uses
     * `Symbol.dispose || Symbol("Symbol.dispose")`. What must hold is that a
     * symbol-keyed disposer can be defined **and invoked** — that is the shim,
     * and a missing native symbol is a degradation note, not a failure.
     */
    SYMBOL_DISPOSE(
        id = "symbol-dispose",
        required = false,
        why = "worker/worker.js primordials: Symbol.dispose || Symbol(\"Symbol.dispose\")",
    ),
}

/** Which vendor ships this WebView provider (the plan's fragmentation axis). */
public enum class KernelVendor {
    /**
     * `com.huawei.webview`: Chromium ~99 baseline, not Play-updatable (R4).
     *
     * Chromium 99 has no native `ReadableStream` async iteration, so this
     * provider only runs the worker through its prelude — the exact case the
     * first gate refused. See [ChromiumVersion.FLOOR_MAJOR].
     */
    HUAWEI,

    /** `com.google.android.webview` / Chrome: Play-updated. */
    GOOGLE,

    /** AOSP / LineageOS builds: user-updated, version varies wildly. */
    AOSP,

    /** An OEM provider (MIUI, ColorOS, ...): version lags, engine does not fork. */
    OTHER,

    /** The framework could not name a provider. */
    UNKNOWN,
    ;

    public companion object {
        public fun of(providerPackage: String?): KernelVendor = when {
            providerPackage == null -> UNKNOWN
            providerPackage == "com.huawei.webview" -> HUAWEI
            providerPackage.startsWith("com.google.android.webview") -> GOOGLE
            providerPackage.startsWith("com.android.webview") -> AOSP
            else -> OTHER
        }
    }
}

/** The actual engine version, read from the user agent — never from versionName. */
public object ChromiumVersion {
    /**
     * The oldest Chromium with **native** `ReadableStream` async iteration —
     * the first release that runs the worker without relying on its prelude.
     *
     * This is a *diagnostic* floor, never a gate: a kernel below it still runs
     * when the feature probe passes (the worker installs
     * `plugins/worker-entry/src/jsc-compat.ts` first), it is only reported as
     * [KernelVerdict.DEGRADED]. `UNSUPPORTED` is decided by the probe alone.
     *
     * Evidence:
     *  * MDN browser-compat-data `api/ReadableStream.json` → `@@asyncIterator`:
     *    **Chrome 124** (Firefox 110, Safari 27); caniuse
     *    `mdn-api_readablestream_--asynciterator` lists Chrome 4–123 as
     *    unsupported.
     *  * Measured 2026-11-01 on the `android-33` system image, WebView
     *    `109.0.5414.123`: the feature is absent natively and the first version
     *    of this gate refused the kernel (`missing
     *    readable-stream-async-iteration`); the `android-35` image's WebView
     *    `124.0.6367.219` runs.
     *
     * The other three probed APIs are far older than this floor — `pipeThrough`
     * ships in Chrome 59, `DecompressionStream("gzip")` in Chrome 80,
     * `Symbol.dispose` in Chrome 125 (optional here; the worker shims it) — so
     * async iteration is the only feature that forces 124.
     */
    public const val FLOOR_MAJOR: Int = 124

    // Chrome/120.0.6099.230, Chromium/99.0.4844.88 and the iOS-style CriOS/...
    // A WebView UA contains one of the first two; the release number after the
    // slash is the engine's own claim about itself.
    private val MAJOR_RE = Regex("""(?:Chrome|Chromium|CriOS)/(\d+)""")

    /** The Chromium major from [userAgent], or `null` when it carries none. */
    public fun majorFromUserAgent(userAgent: String?): Int? {
        val text = userAgent ?: return null
        return MAJOR_RE.find(text)?.groupValues?.get(1)?.toIntOrNull()
    }
}

/** What the probe (and the provider read) add up to. */
public enum class KernelVerdict {
    /** No probe result: the host must render 未知, never "supported". */
    UNVERIFIED,

    /** Every required feature is present and the engine is within the baseline. */
    SUPPORTED,

    /** Every required feature is present, but the engine is older than the floor or its version is unknown. */
    DEGRADED,

    /** At least one required feature is missing: the worker cannot run here. */
    UNSUPPORTED,
}

/**
 * One measured WebView kernel: provider identity, the engine's own version, and
 * the runtime feature results.
 *
 * @param providerPackage `WebView.getCurrentWebViewPackage()?.packageName`.
 * @param providerVersionName the same package's versionName. **Telemetry only.**
 * @param userAgent the engine's user agent (from the page's `navigator.userAgent`
 *   when the probe ran, else from `WebSettings.getDefaultUserAgent`).
 * @param chromiumMajor parsed from [userAgent]; `null` means "not measured".
 * @param features the measured results, keyed by feature. A feature absent from
 *   the map was **not measured** and is never treated as supported.
 */
public data class WebViewKernelReport(
    public val providerPackage: String?,
    public val providerVersionName: String?,
    public val userAgent: String?,
    public val chromiumMajor: Int?,
    public val features: Map<KernelFeature, Boolean>,
) {
    public val vendor: KernelVendor get() = KernelVendor.of(providerPackage)

    /** Required features the engine reported as **absent**. */
    public val missingRequired: List<KernelFeature>
        get() = KernelFeature.entries.filter { it.required && features[it] == false }

    /** Required features with no measurement; a partial probe cannot claim support. */
    public val unmeasuredRequired: List<KernelFeature>
        get() = KernelFeature.entries.filter { it.required && features[it] == null }

    /** Optional features the engine lacks (their fallback shim is what runs). */
    public val missingOptional: List<KernelFeature>
        get() = KernelFeature.entries.filter { !it.required && features[it] == false }

    public val verdict: KernelVerdict
        get() = when {
            features.isEmpty() -> KernelVerdict.UNVERIFIED
            missingRequired.isNotEmpty() -> KernelVerdict.UNSUPPORTED
            unmeasuredRequired.isNotEmpty() -> KernelVerdict.UNVERIFIED
            chromiumMajor == null || chromiumMajor < ChromiumVersion.FLOOR_MAJOR -> KernelVerdict.DEGRADED
            else -> KernelVerdict.SUPPORTED
        }

    /** `"Chromium 120 (provider 14.0.0.0)"`, or the honest unknown wording. */
    public fun versionLabel(): String = buildString {
        append(chromiumMajor?.let { "Chromium $it" } ?: "Chromium unknown")
        providerVersionName?.let { append(" (provider ").append(it).append(')') }
    }

    /**
     * The technical detail the runtime page shows under "特性探测".
     *
     * Facts only: the wording belongs to the UI layer, which already owns the
     * Chinese strings. A supported kernel still names the engine and the shim
     * mode, so a support log can tell native `Symbol.dispose` from the shim.
     */
    public fun featureGateDetail(): String = buildString {
        append(versionLabel())
        append(" / ").append(vendor.name.lowercase())
        if (features.isEmpty()) {
            append(" / feature probe did not run")
            return@buildString
        }
        if (missingRequired.isNotEmpty()) {
            append(" / missing required: ")
            append(missingRequired.joinToString(", ") { it.id })
        } else {
            append(" / required features present")
        }
        if (missingRequired.isEmpty() && chromiumMajor.let { it != null && it < ChromiumVersion.FLOOR_MAJOR }) {
            append(" / below baseline ").append(ChromiumVersion.FLOOR_MAJOR)
            append(" (async iteration via the worker prelude)")
        }
        if (missingOptional.isNotEmpty()) {
            append(" / shimmed: ")
            append(missingOptional.joinToString(", ") { it.id })
        }
        unmeasuredRequired.takeIf { it.isNotEmpty() }?.let {
            append(" / unmeasured: ").append(it.joinToString(", ") { feature -> feature.id })
        }
    }

    /** One line for logcat; never contains a token or a URL. */
    public fun describe(): String = buildString {
        append("provider=").append(providerPackage ?: "unknown")
        append('/').append(providerVersionName ?: "unknown")
        append(", vendor=").append(vendor.name.lowercase())
        append(", ").append(versionLabel())
        append(", verdict=").append(verdict.name.lowercase())
        append(", features=")
        append(
            KernelFeature.entries.joinToString(",") { feature ->
                "${feature.id}:${features[feature]?.toString() ?: "unmeasured"}"
            },
        )
    }

    public companion object {
        /**
         * Combines the provider read with a probe result.
         *
         * @param fallbackUserAgent used only when the probe did not return a UA;
         *   the page's own UA wins because it is the engine actually running the
         *   worker.
         */
        public fun of(
            providerPackage: String?,
            providerVersionName: String?,
            probe: WebViewKernelProbe.Result?,
            fallbackUserAgent: String? = null,
        ): WebViewKernelReport {
            val userAgent = probe?.userAgent ?: fallbackUserAgent
            return WebViewKernelReport(
                providerPackage = providerPackage,
                providerVersionName = providerVersionName,
                userAgent = userAgent,
                chromiumMajor = ChromiumVersion.majorFromUserAgent(userAgent),
                features = probe?.features ?: emptyMap(),
            )
        }
    }
}

/**
 * The JavaScript probe and its decoder.
 *
 * The script is dependency-free and self-contained: it must run on a broken
 * page (the worker may already have thrown), so it loads nothing and touches
 * only the prelude surface it stands in for. Each entry returns a boolean and
 * is wrapped in `try`, because a `typeof` check on an exotic getter can still
 * throw.
 */
public object WebViewKernelProbe {
    /** What the page reported. */
    public data class Result(
        public val userAgent: String?,
        public val features: Map<KernelFeature, Boolean>,
    )

    /**
     * The probe body. Evaluated with `WebView.evaluateJavascript`, so it must
     * return a JSON **string** (the callback receives that string, JSON-encoded
     * once more — [parse] handles both layers).
     *
     * The Worker's first imports are its prelude: `plugins/worker-entry/src/
     * boot.ts` installs `jsc-compat.ts`, `es2023-compat.ts`,
     * `abort-signal-compat.ts` and `scheduler-compat.ts` before any DSH module
     * evaluates. The gate answers "can the Worker run here?", so this script
     * installs the same surface before it measures anything: the capability it
     * reports is the **post-prelude** engine, not the native one.
     * `readable-stream-async-iteration` is then exercised by consuming one
     * chunk. Measuring only the native API was the bug that refused every
     * Chromium <124 kernel; measuring "a function exists" would accept a
     * method that never yields.
     *
     * The installation below is a copy of the prelude, so it could drift — an
     * earlier revision installed only `ReadableStream.prototype
     * [Symbol.asyncIterator]` while the prelude installed it together with
     * `values()`, making the gate measure a weaker surface than the Worker got.
     * The copy is therefore verified, not promised:
     * `plugins/worker-entry/src/webview-kernel-probe.test.ts` runs the **real**
     * installers of the four prelude modules and this exact script, extracts the
     * properties each side installs, and fails — naming the missing property —
     * when this script's surface stops covering the prelude's. Adding a prelude
     * patch without mirroring it here is a red test, not a silently weaker
     * measurement.
     */
    public val SCRIPT: String = """
        (function () {
          var out = { ua: String(navigator.userAgent || ""), features: {} };
          function probe(id, fn) {
            try { out.features[id] = fn() === true; } catch (e) { out.features[id] = false; }
          }

          // ---------------------------------------------------------------------
          // Worker prelude mirror.
          //
          // `plugins/worker-entry/src/boot.ts` imports these four modules before any
          // DSH module evaluates: jsc-compat.ts, es2023-compat.ts,
          // abort-signal-compat.ts and scheduler-compat.ts. The Worker runs on the
          // engine *after* that prelude, so the page must measure the same surface.
          // Every definition below is feature-detected and idempotent, like the
          // original, and the install order matches boot.ts.
          //
          // This is a copy, so it can drift. `plugins/worker-entry/src/
          // webview-kernel-probe.test.ts` extracts the properties both sides install
          // and fails, naming the missing property, when this script stops covering
          // the real prelude.
          // ---------------------------------------------------------------------

          function define(target, key, value, enumerable) {
            Object.defineProperty(target, key, {
              configurable: true,
              writable: true,
              value: value,
              enumerable: enumerable === true
            });
          }

          // jsc-compat.ts — Symbol.dispose / Symbol.asyncDispose.
          function installSymbols() {
            if (typeof Symbol === "undefined") return;
            if (Symbol.dispose === undefined) {
              define(Symbol, "dispose", typeof Symbol.for === "function" ? Symbol.for("xl.symbol.dispose") : Symbol("xl.symbol.dispose"));
            }
            if (Symbol.asyncDispose === undefined) {
              define(Symbol, "asyncDispose", typeof Symbol.for === "function" ? Symbol.for("xl.symbol.asyncDispose") : Symbol("xl.symbol.asyncDispose"));
            }
          }

          // jsc-compat.ts — async iteration over ReadableStream. Web IDL § 3.7.10
          // installs one function object under both names, so `values()` and
          // `[Symbol.asyncIterator]` run the same code; an engine that has only one
          // of them gets the other aliased to it, never a second implementation.
          function streamValues(options) {
            var preventCancel = Boolean(options && options.preventCancel);
            var reader = this.getReader();
            var released = false;
            function release() {
              if (released) return;
              released = true;
              var releaseLock = reader.releaseLock;
              if (typeof releaseLock !== "function") return;
              try { releaseLock.call(reader); } catch (e) {}
            }
            var iterator = {
              next: function () {
                if (released) return Promise.resolve({ done: true, value: undefined });
                return reader.read().then(function (result) {
                  if (result.done === true) { release(); return { done: true, value: undefined }; }
                  return { done: false, value: result.value };
                }, function (error) {
                  release();
                  throw error;
                });
              },
              "return": function (value) {
                if (released) return Promise.resolve({ done: true, value: value });
                if (preventCancel) {
                  release();
                  return Promise.resolve({ done: true, value: value });
                }
                var cancelled;
                try { cancelled = reader.cancel(value); } catch (error) { release(); return Promise.reject(error); }
                release();
                return cancelled.then(function () { return { done: true, value: value }; });
              },
              "throw": function (error) {
                if (released) return Promise.reject(error);
                var cancelled;
                try { cancelled = reader.cancel(error); } catch (failure) { release(); return Promise.reject(failure); }
                release();
                cancelled["catch"](function () {});
                return Promise.reject(error);
              }
            };
            iterator[Symbol.asyncIterator] = function () { return iterator; };
            return iterator;
          }

          function installStreamAsyncIteration() {
            if (typeof Symbol === "undefined") return;
            if (typeof ReadableStream !== "function") return;
            var proto = ReadableStream.prototype;
            if (proto === null || (typeof proto !== "object" && typeof proto !== "function")) return;
            var asyncIterator = Symbol.asyncIterator;
            if (asyncIterator === undefined) return;
            var existingValues = typeof proto.values === "function" ? proto.values : undefined;
            var existingAsyncIterator = typeof proto[asyncIterator] === "function" ? proto[asyncIterator] : undefined;
            if (existingValues !== undefined && existingAsyncIterator !== undefined) return;
            var method = existingValues || existingAsyncIterator || streamValues;
            if (existingValues === undefined) define(proto, "values", method, true);
            if (existingAsyncIterator === undefined) {
              Object.defineProperty(proto, asyncIterator, {
                configurable: true,
                writable: true,
                value: method,
                enumerable: false
              });
            }
          }

          // jsc-compat.ts — Promise.withResolvers.
          function installPromiseWithResolvers() {
            if (typeof Promise !== "function") return;
            if (typeof Promise.withResolvers === "function") return;
            define(Promise, "withResolvers", function withResolvers() {
              var resolve;
              var reject;
              var promise = new Promise(function (settle, fail) {
                resolve = settle;
                reject = fail;
              });
              return { promise: promise, resolve: resolve, reject: reject };
            });
          }

          // jsc-compat.ts — Node's `global` alias, which a Web Worker does not define.
          function installNodeGlobal() {
            if (typeof global !== "undefined") return;
            define(globalThis, "global", globalThis);
          }

          // es2023-compat.ts — Array.prototype helpers.
          function toInteger(value) {
            var number = Number(value);
            if (Number.isNaN(number)) return 0;
            if (!Number.isFinite(number)) return number;
            return Math.trunc(number);
          }

          function copyArrayLike() {
            var length = Number(this.length) >>> 0;
            var out = new Array(length);
            for (var index = 0; index < length; index += 1) out[index] = this[index];
            return out;
          }

          function arrayToReversed() {
            var source = copyArrayLike.call(this);
            var length = source.length;
            var out = new Array(length);
            for (var index = 0; index < length; index += 1) out[index] = source[length - 1 - index];
            return out;
          }

          function arrayToSorted(compare) {
            return copyArrayLike.call(this).sort(compare);
          }

          function arrayToSpliced(start, deleteCount) {
            var out = copyArrayLike.call(this);
            var length = out.length;
            var relative = toInteger(start);
            var actualStart = relative < 0 ? Math.max(length + relative, 0) : Math.min(relative, length);
            var skip = deleteCount === undefined
              ? length - actualStart
              : Math.min(Math.max(toInteger(deleteCount), 0), length - actualStart);
            var items = [];
            for (var index = 3; index < arguments.length; index += 1) items[index - 3] = arguments[index];
            out.splice.apply(out, [actualStart, skip].concat(items));
            return out;
          }

          function arrayWith(index, value) {
            var out = copyArrayLike.call(this);
            var length = out.length;
            var relative = toInteger(index);
            var actual = relative < 0 ? length + relative : relative;
            if (actual < 0 || actual >= length) throw new RangeError("Invalid index: " + String(index));
            out[actual] = value;
            return out;
          }

          // es2023-compat.ts — String.prototype helpers.
          function stringIsWellFormed() {
            var text = String(this);
            for (var index = 0; index < text.length; index += 1) {
              var unit = text.charCodeAt(index);
              if (unit >= 0xd800 && unit <= 0xdbff) {
                var next = index + 1 < text.length ? text.charCodeAt(index + 1) : Number.NaN;
                if (!(next >= 0xdc00 && next <= 0xdfff)) return false;
                index += 1;
              } else if (unit >= 0xdc00 && unit <= 0xdfff) {
                return false;
              }
            }
            return true;
          }

          function stringToWellFormed() {
            var text = String(this);
            var out = "";
            for (var index = 0; index < text.length; index += 1) {
              var unit = text.charCodeAt(index);
              if (unit >= 0xd800 && unit <= 0xdbff) {
                var next = index + 1 < text.length ? text.charCodeAt(index + 1) : Number.NaN;
                if (next >= 0xdc00 && next <= 0xdfff) {
                  out += (text[index] || "") + (text[index + 1] || "");
                  index += 1;
                } else {
                  out += "\ufffd";
                }
              } else if (unit >= 0xdc00 && unit <= 0xdfff) {
                out += "\ufffd";
              } else {
                out += text[index];
              }
            }
            return out;
          }

          function installEs2023() {
            if (typeof Array !== "undefined" && Array.prototype !== undefined) {
              var array = Array.prototype;
              if (typeof array.toReversed !== "function") define(array, "toReversed", arrayToReversed);
              if (typeof array.toSorted !== "function") define(array, "toSorted", arrayToSorted);
              if (typeof array.toSpliced !== "function") define(array, "toSpliced", arrayToSpliced);
              if (typeof array.with !== "function") define(array, "with", arrayWith);
            }
            if (typeof String !== "undefined" && String.prototype !== undefined) {
              var string = String.prototype;
              if (typeof string.isWellFormed !== "function") define(string, "isWellFormed", stringIsWellFormed);
              if (typeof string.toWellFormed !== "function") define(string, "toWellFormed", stringToWellFormed);
            }
          }

          // abort-signal-compat.ts — AbortSignal.any.
          function installAbortSignalAny() {
            if (typeof AbortSignal === "undefined" || typeof AbortController === "undefined") return;
            if (typeof AbortSignal.any === "function") return;
            define(AbortSignal, "any", function any(signals) {
              var controller = new AbortController();
              var inputs = Array.from(signals);
              var already;
              for (var index = 0; index < inputs.length; index += 1) {
                if (inputs[index].aborted) { already = inputs[index]; break; }
              }
              if (already !== undefined) {
                controller.abort(already.reason);
                return controller.signal;
              }
              var onAbort = function () {
                var source;
                for (var inner = 0; inner < inputs.length; inner += 1) {
                  if (inputs[inner].aborted) { source = inputs[inner]; break; }
                }
                for (var each = 0; each < inputs.length; each += 1) inputs[each].removeEventListener("abort", onAbort);
                controller.abort(source === undefined ? undefined : source.reason);
              };
              for (var listener = 0; listener < inputs.length; listener += 1) {
                inputs[listener].addEventListener("abort", onAbort, { once: true });
              }
              return controller.signal;
            });
          }

          // scheduler-compat.ts — scheduler.yield.
          function yieldToEventLoop(current, setTimeoutFunction) {
            if (current && typeof current.postTask === "function") {
              return current.postTask(function () {}, { priority: "user-blocking" }).then(function () {});
            }
            if (typeof setTimeoutFunction === "function") {
              return new Promise(function (resolve) { setTimeoutFunction(function () { resolve(); }, 0); });
            }
            return Promise.resolve();
          }

          function installSchedulerYield() {
            if (typeof scheduler !== "undefined" && scheduler !== null) {
              if (typeof scheduler.yield === "function") return;
              define(scheduler, "yield", function yieldPromise() {
                return yieldToEventLoop(scheduler, typeof setTimeout === "function" ? setTimeout : undefined);
              });
              return;
            }
            if (typeof setTimeout !== "function") return;
            var created = {};
            define(globalThis, "scheduler", created);
            define(created, "yield", function yieldPromise() {
              return yieldToEventLoop(undefined, setTimeout);
            });
          }

          // boot.ts order. Each installer is independent: a broken engine must lose one
          // capability, not the whole probe.
          function installWorkerPrelude() {
            try { installSymbols(); } catch (e) {}
            try { installStreamAsyncIteration(); } catch (e) {}
            try { installPromiseWithResolvers(); } catch (e) {}
            try { installNodeGlobal(); } catch (e) {}
            try { installEs2023(); } catch (e) {}
            try { installAbortSignalAny(); } catch (e) {}
            try { installSchedulerYield(); } catch (e) {}
          }

          installWorkerPrelude();

          probe("readable-stream-async-iteration", function () {
            if (typeof ReadableStream !== "function") return false;
            var proto = ReadableStream.prototype;
            if (typeof proto[Symbol.asyncIterator] !== "function") return false;
            // A function that never yields a step would pass a typeof check and still
            // break the Worker's for-await, so consume one chunk.
            var stream = new ReadableStream({
              start: function (controller) { controller.enqueue(1); controller.close(); }
            });
            var iterator = proto[Symbol.asyncIterator].call(stream);
            var step = iterator.next();
            var usable = step !== null && typeof step === "object" && typeof step.then === "function";
            if (usable) step.then(function () {}, function () {});
            if (typeof iterator["return"] === "function") {
              try { iterator["return"](); } catch (e) {}
            }
            return usable;
          });
          probe("readable-stream-pipe-through", function () {
            return typeof ReadableStream === "function" &&
              typeof ReadableStream.prototype.pipeThrough === "function";
          });
          probe("decompression-stream-gzip", function () {
            if (typeof DecompressionStream !== "function") return false;
            var stream = new DecompressionStream("gzip");
            return typeof stream.readable !== "undefined" && typeof stream.writable !== "undefined";
          });
          probe("symbol-dispose", function () {
            var key = (typeof Symbol.dispose === "symbol") ? Symbol.dispose : Symbol("Symbol.dispose");
            var called = false;
            var holder = {};
            holder[key] = function () { called = true; };
            if (typeof holder[key] !== "function") return false;
            holder[key]();
            return called;
          });
          return JSON.stringify(out);
        })()
    """.trimIndent()

    /** Decodes the `evaluateJavascript` callback value; `null` when it is not a probe result. */
    public fun parse(rawEvaluated: String?): Result? {
        if (rawEvaluated == null) return null
        val inner = unwrap(rawEvaluated.trim()) ?: return null
        val payload = runCatching { JSONObject(inner) }.getOrNull() ?: return null
        val featuresJson = payload.optJSONObject("features") ?: return null
        val features = LinkedHashMap<KernelFeature, Boolean>()
        for (feature in KernelFeature.entries) {
            if (featuresJson.has(feature.id)) {
                features[feature] = featuresJson.optBoolean(feature.id, false)
            }
        }
        if (features.isEmpty()) return null
        val userAgent = payload.optString("ua", "").takeIf { it.isNotBlank() }
        return Result(userAgent = userAgent, features = features)
    }

    /**
     * The callback value is a JSON-encoded string (`"{\"ua\":...}"`), not an
     * object. Decode it properly instead of trimming quotes: the UA contains
     * escaped characters, and a naive trim would hand `JSONObject` a broken
     * document.
     */
    private fun unwrap(text: String): String? {
        if (text.startsWith("\"")) {
            return runCatching { JSONTokener(text).nextValue() as? String }.getOrNull()
        }
        return text.takeIf { it.startsWith("{") }
    }
}
