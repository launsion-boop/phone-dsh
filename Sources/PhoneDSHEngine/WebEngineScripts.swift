// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: page scripts.
//
// The WKScriptMessageHandler bridge is observability-only: it carries the
// Worker boot status and page console lines. VFS mutations, exec events,
// journal records and remote API frames travel over the ordered WebSocket
// channel, never through this bridge (PLAN §2.2).
//
// The boot bridge also understands the W1 worker page, which reports readiness
// by setting the document title and the `#status` text instead of calling the
// native handler; a MutationObserver forwards that transition once.

import Foundation

enum WebEngineScripts {
    /// Installed at document start; wraps console methods and watches the
    /// W1 page's title/status text for boot readiness.
    static func observabilityBridge(handlerName: String) -> String {
        let escaped = handlerName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (function () {
          // The complete DSH page is also served to ordinary browsers. Publish
          // an explicit app display mode so the page can keep its native
          // install/notification surface without faking `standalone` or
          // changing unrelated CSS media queries.
          try {
            window.__PDSH_EMBEDDED_APP__ = Object.freeze({ version: 1, displayMode: 'app' });
          } catch (error) {}
          if (window.__xlEngineBridgeInstalled === true) { return; }
          window.__xlEngineBridgeInstalled = true;
          var handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers["\(escaped)"];
          if (!handler) { return; }
          function post(message) {
            try { handler.postMessage(message); } catch (error) {}
          }
          var levels = { log: 'log', info: 'info', warn: 'warning', error: 'error', debug: 'debug' };
          // W7 (§13): a chatty page used to stringify and post every console
          // call. Non-error levels are rate limited to 50 lines per second per
          // level; `error` is never dropped. The native forward is still only
          // attempted for an allowed line, so stringification is skipped too.
          var consoleWindowStart = Date.now();
          var consoleCounts = {};
          var consoleBudgetPerLevel = 50;
          function allowConsole(level) {
            if (level === 'error') { return true; }
            var now = Date.now();
            if (now - consoleWindowStart >= 1000) {
              consoleWindowStart = now;
              consoleCounts = {};
            }
            var count = (consoleCounts[level] || 0) + 1;
            consoleCounts[level] = count;
            return count <= consoleBudgetPerLevel;
          }
          Object.keys(levels).forEach(function (name) {
            var original = console[name];
            console[name] = function () {
              try {
                var level = levels[name];
                if (allowConsole(level)) {
                  var parts = [];
                  for (var i = 0; i < arguments.length; i++) {
                    parts.push(String(arguments[i]));
                  }
                  post({ kind: 'console', level: level, text: parts.join(' ') });
                }
              } catch (error) {}
              if (typeof original === 'function') {
                return original.apply(console, arguments);
              }
            };
          });
          var lastBootState = '';
          var bootObservers = [];
          var loadListenerAttached = false;
          function stopObserving() {
            for (var i = 0; i < bootObservers.length; i++) {
              try { bootObservers[i].disconnect(); } catch (error) {}
            }
            bootObservers = [];
            if (loadListenerAttached) {
              try { window.removeEventListener('load', inspectBoot); } catch (error) {}
              loadListenerAttached = false;
            }
          }
          function statusText() {
            var text = '';
            try { text += String(document.title || ''); } catch (error) {}
            try {
              var status = document.querySelector('#status');
              if (status) { text += ' ' + String(status.textContent || ''); }
            } catch (error) {}
            return text;
          }
          function inspectBoot() {
            var text = statusText();
            var state = '';
            if (/DSH ready|worker ready|worker is ready/i.test(text)) { state = 'ready'; }
            else if (/DSH failed|boot failed|worker error/i.test(text)) { state = 'failed'; }
            if (state === '' || state === lastBootState) { return; }
            lastBootState = state;
            post({ kind: 'boot', state: state, detail: text.trim() });
            // The probe has answered: stop watching the whole document. A
            // ready page no longer needs a per-mutation JS callback.
            if (state === 'ready') { stopObserving(); }
          }
          function observe() {
            inspectBoot();
            if (lastBootState === 'ready') { return; }
            try {
              var target = document.documentElement || document;
              var documentObserver = new MutationObserver(inspectBoot);
              documentObserver.observe(target, {
                subtree: true,
                childList: true,
                characterData: true,
                attributes: true,
                attributeFilter: ['content']
              });
              bootObservers.push(documentObserver);
              var title = document.querySelector('title');
              if (title) {
                var titleObserver = new MutationObserver(inspectBoot);
                titleObserver.observe(title, {
                  subtree: true, childList: true, characterData: true
                });
                bootObservers.push(titleObserver);
              }
            } catch (error) {}
            window.addEventListener('load', inspectBoot);
            loadListenerAttached = true;
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', observe);
          } else {
            observe();
          }
        })();
        """
    }

    /// Tight loop plus JSON work, timed inside the page.
    ///
    /// Informational only (PLAN W3-PROBES uses the same shape for the
    /// JSContext-vs-WKWebView ratio); the engine never changes behaviour from
    /// this number.
    static let jitBenchmark = """
    (function () {
      var check = 0;
      var iterations = 0;
      var start = performance.now();
      for (var round = 0; round < 6; round++) {
        for (var i = 0; i < 12000; i++) {
          check = (check + ((i * i) % 97)) % 2147483647;
          iterations += 1;
        }
        var items = [];
        for (var j = 0; j < 200; j++) {
          items.push({ i: j, s: String(j), a: [j, j + 1] });
        }
        var text = JSON.stringify(items);
        JSON.parse(text);
      }
      return {
        milliseconds: performance.now() - start,
        iterations: iterations,
        checksum: check
      };
    })();
    """
}
