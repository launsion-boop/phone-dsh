// SPDX-License-Identifier: MIT
// PhoneDSHEngine tests: stub loopback HTTP origin (Network.framework).
//
// The stub serves the same two files a real loopback origin serves first: the
// page (`index.html`) and the bootstrap script (`boot.js`). The bootstrap posts
// either the native boot message directly or only updates the document title
// and `#status`, so both the direct WKScriptMessageHandler path and the
// MutationObserver bridge used with the W1 page are exercised.

import Foundation
import Network
import PhoneDSHEngine

final class StubLoopbackServer {
    enum BootMode {
        /// `boot.js` posts the boot message to the WKScriptMessageHandler.
        case direct
        /// `boot.js` only updates the title and `#status` like the W1 page.
        case titleOnly
        /// `boot.js` starts a small DedicatedWorker that keeps fetching a
        /// heartbeat. Navigating to `about:blank` must destroy that Worker;
        /// the heartbeat is the observable proof on a real WKWebView.
        case dedicatedWorker
    }

    private final class StartState: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
        var port: UInt16?
    }

    private let bootMode: BootMode
    private let listener: NWListener
    private let queue = DispatchQueue(label: "phone.engine.stub-loopback")
    private let lock = NSLock()
    private var paths: [String] = []
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(bootMode: BootMode) throws {
        self.bootMode = bootMode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func pageURL(token: String, bootID: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/index.html"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "boot_id", value: bootID),
        ]
        return components.url!
    }

    /// Request targets (`path?query`) in arrival order.
    var recordedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func start() throws {
        let state = StartState()
        let listener = self.listener
        listener.stateUpdateHandler = { update in
            switch update {
            case .ready:
                state.port = listener.port.map { UInt16($0.rawValue) }
                state.semaphore.signal()
            case .failed(let error):
                state.error = error
                state.semaphore.signal()
            case .cancelled:
                state.semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard state.semaphore.wait(timeout: .now() + 10) == .success else {
            throw StubServerError.startTimedOut
        }
        if let error = state.error {
            throw error
        }
        guard let port = state.port else {
            throw StubServerError.noPort
        }
        self.port = port
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        lock.lock()
        let live = connections
        connections.removeAll()
        lock.unlock()
        for connection in live {
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if accumulated.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: accumulated, on: connection)
                return
            }
            if error == nil && !isComplete {
                self.receive(connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let head = String(decoding: request, as: UTF8.self)
        let firstLine = head.split(separator: "\r\n", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        lock.lock()
        paths.append(target)
        lock.unlock()

        let path = target.split(separator: "?", maxSplits: 1,
                                omittingEmptySubsequences: false).first.map(String.init) ?? target
        var status = "200 OK"
        var contentType = "text/html; charset=utf-8"
        var body = html
        switch path {
        case "/", "/index.html":
            break
        case "/boot.js":
            contentType = "text/javascript; charset=utf-8"
            body = bootScript
        case "/worker.js":
            contentType = "text/javascript; charset=utf-8"
            body = workerScript
        case "/worker-ping":
            status = "204 No Content"
            contentType = "text/plain; charset=utf-8"
            body = ""
        default:
            status = "404 Not Found"
            contentType = "text/plain; charset=utf-8"
            body = "not found"
        }

        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private var html: String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>stub booting</title></head>
        <body><p id="status">booting…</p><script src="/boot.js"></script></body>
        </html>
        """
    }

    private var bootScript: String {
        let handlerName = WebEngine.scriptMessageHandlerName
        switch bootMode {
        case .direct:
            return """
            (function () {
              var params = new URLSearchParams(location.search);
              var bootId = params.get('boot_id') || '';
              var status = document.querySelector('#status');
              if (status) { status.textContent = 'worker ready'; }
              console.log('stub-boot:' + bootId);
              var handler = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers["\(handlerName)"];
              if (handler) {
                handler.postMessage({
                  kind: 'boot',
                  state: 'ready',
                  boot_id: bootId,
                  detail: 'stub boot'
                });
              }
            })();
            """
        case .titleOnly:
            return """
            (function () {
              document.title = 'DSH ready';
              var status = document.querySelector('#status');
              if (status) { status.textContent = 'worker ready'; }
              console.log('stub-title-boot');
            })();
            """
        case .dedicatedWorker:
            return """
            (function () {
              var params = new URLSearchParams(location.search);
              var bootId = params.get('boot_id') || '';
              var status = document.querySelector('#status');
              if (status) { status.textContent = 'worker ready'; }
              var worker = new Worker('/worker.js');
              window.__pdshProbeWorker = worker;
              worker.onmessage = function (event) {
                console.log('stub-worker:' + event.data);
              };
              console.log('stub-boot:' + bootId);
              var handler = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers["\(handlerName)"];
              if (handler) {
                handler.postMessage({
                  kind: 'boot',
                  state: 'ready',
                  boot_id: bootId,
                  detail: 'stub dedicated-worker boot'
                });
              }
            })();
            """
        }
    }

    /// DedicatedWorker body: a heartbeat proves the execution context is live
    /// before termination and stops when `about:blank` replaces the page.
    private var workerScript: String {
        """
        var tick = 0;
        setInterval(function () {
          tick += 1;
          fetch('/worker-ping?tick=' + tick).catch(function () {});
        }, 50);
        postMessage('started');
        """
    }
}

enum StubServerError: Error, Equatable {
    case startTimedOut
    case noPort
}
