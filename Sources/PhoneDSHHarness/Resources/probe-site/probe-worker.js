// SPDX-License-Identifier: MIT
// phone-dsh Phase 0 channel probe Worker (PLAN W3-PROBES).
//
// Runs inside a real WKWebView Worker on the loopback origin. Every request is
// same-origin: fetch goes through the host's `/v1/http` egress route with the
// echo target, the NDJSON response is read chunk by chunk, and 1000 sequential
// WebSocket echoes measure the loopback round-trip distribution. The Worker
// never talks to a non-loopback host.

self.onmessage = async function (event) {
  var task = event.data || {};
  var result = {
    crossOriginIsolated: self.crossOriginIsolated,
    mode: task.mode || 'full',
  };
  if (result.mode === 'isolation') {
    self.postMessage(result);
    return;
  }

  var token = task.token || '';
  var origin = self.location.origin;
  var auth = 'token=' + encodeURIComponent(token);

  try {
    result.fetch1k = await postEcho(1024);
    result.fetch1m = await postEcho(1024 * 1024);
    result.ndjson = await readNDJSON();
    result.ws = await wsEcho(1000);
  } catch (error) {
    result.error = String((error && error.stack) || error);
  }
  self.postMessage(result);

  async function postEcho(size) {
    var body = new Uint8Array(size);
    for (var i = 0; i < size; i += 1) {
      body[i] = (i * 31 + 7) & 0xff;
    }
    var started = performance.now();
    var response = await fetch('/v1/http?' + auth, {
      method: 'POST',
      headers: {
        'x-pdsh-target-url': origin + '/probe/echo',
        'x-pdsh-target-method': 'POST',
        'content-type': 'application/octet-stream',
      },
      body: body,
    });
    var received = new Uint8Array(await response.arrayBuffer());
    var elapsed = performance.now() - started;
    var matches = received.length === body.length;
    if (matches) {
      for (var index = 0; index < body.length; index += 1) {
        if (received[index] !== body[index]) {
          matches = false;
          break;
        }
      }
    }
    return {
      status: response.status,
      request_bytes: size,
      response_bytes: received.length,
      matches: matches,
      elapsed_ms: elapsed,
    };
  }

  async function readNDJSON() {
    var started = performance.now();
    var response = await fetch('/v1/http?' + auth, {
      headers: {
        'x-pdsh-target-url': origin + '/probe/ndjson',
      },
    });
    if (!response.body) {
      throw new Error('the NDJSON response has no readable body');
    }
    var reader = response.body.getReader();
    var decoder = new TextDecoder();
    var text = '';
    var chunks = 0;
    var firstChunkMs = -1;
    while (true) {
      var step = await reader.read();
      if (step.done) {
        break;
      }
      if (firstChunkMs < 0) {
        firstChunkMs = performance.now() - started;
      }
      chunks += 1;
      text += decoder.decode(step.value, { stream: true });
    }
    text += decoder.decode();
    var totalMs = performance.now() - started;
    var lines = text.split('\n').filter(function (line) {
      return line.trim().length > 0;
    });
    var parsed = 0;
    for (var index = 0; index < lines.length; index += 1) {
      try {
        JSON.parse(lines[index]);
        parsed += 1;
      } catch (error) {
        // Reported as parsed_lines < lines; the test turns that into a FAIL.
      }
    }
    return {
      status: response.status,
      chunks: chunks,
      lines: lines.length,
      parsed_lines: parsed,
      first_chunk_ms: firstChunkMs,
      total_ms: totalMs,
    };
  }

  function wsEcho(count) {
    return new Promise(function (resolve, reject) {
      var socket = new WebSocket(origin.replace(/^http/, 'ws') + '/channel?' + auth);
      socket.binaryType = 'arraybuffer';
      var samples = [];
      var pendingAt = -1;
      var index = 0;
      var timeout = setTimeout(function () {
        cleanup();
        reject(new Error('websocket echo timed out'));
      }, 60000);

      function cleanup() {
        clearTimeout(timeout);
        try {
          socket.close();
        } catch (error) {
          // The socket may already be closed.
        }
      }

      function percentile(sorted, fraction) {
        if (sorted.length === 0) {
          return -1;
        }
        var position = Math.ceil(fraction * sorted.length) - 1;
        position = Math.min(sorted.length - 1, Math.max(0, position));
        return sorted[position];
      }

      function sendNext() {
        if (index >= count) {
          cleanup();
          var sorted = samples.slice().sort(function (a, b) { return a - b; });
          resolve({
            count: sorted.length,
            p50_ms: percentile(sorted, 0.50),
            p95_ms: percentile(sorted, 0.95),
            min_ms: sorted.length > 0 ? sorted[0] : -1,
            max_ms: sorted.length > 0 ? sorted[sorted.length - 1] : -1,
          });
          return;
        }
        index += 1;
        pendingAt = performance.now();
        socket.send(new Uint8Array(16));
      }

      socket.onopen = sendNext;
      socket.onerror = function () {
        cleanup();
        reject(new Error('websocket error'));
      };
      socket.onmessage = function () {
        if (pendingAt < 0) {
          return;
        }
        samples.push(performance.now() - pendingAt);
        pendingAt = -1;
        sendNext();
      };
    });
  }
};
