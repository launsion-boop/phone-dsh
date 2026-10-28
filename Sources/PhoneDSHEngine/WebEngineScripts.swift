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
          Object.keys(levels).forEach(function (name) {
            var original = console[name];
            console[name] = function () {
              try {
                var parts = [];
                for (var i = 0; i < arguments.length; i++) {
                  parts.push(String(arguments[i]));
                }
                post({ kind: 'console', level: levels[name], text: parts.join(' ') });
              } catch (error) {}
              if (typeof original === 'function') {
                return original.apply(console, arguments);
              }
            };
          });
          var lastBootState = '';
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
          }
          function observe() {
            inspectBoot();
            try {
              var target = document.documentElement || document;
              new MutationObserver(inspectBoot).observe(target, {
                subtree: true,
                childList: true,
                characterData: true,
                attributes: true,
                attributeFilter: ['content']
              });
              var title = document.querySelector('title');
              if (title) {
                new MutationObserver(inspectBoot).observe(title, {
                  subtree: true, childList: true, characterData: true
                });
              }
            } catch (error) {}
            window.addEventListener('load', inspectBoot);
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
