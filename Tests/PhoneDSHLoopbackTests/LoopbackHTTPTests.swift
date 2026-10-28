// SPDX-License-Identifier: MIT
// PhoneDSHLoopback HTTP origin tests: token/Origin security, static and
// image routes, streaming egress, exec-bridge forwarding, MCP proxy, chunked
// requests and keep-alive. No @MainActor, all I/O is real loopback TCP.

import Foundation
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback
import PhoneDSHAgentCore

final class LoopbackHTTPTests: XCTestCase {
    private func startServer(
        routes: LoopbackRoutes = LoopbackRoutes(),
        configuration: LoopbackConfiguration = LoopbackConfiguration(),
        stateProvider: ChannelHostStateProvider? = nil
    ) async throws -> (server: LoopbackServer, client: TestHTTPClient) {
        let server = LoopbackServer(configuration: configuration,
                                    routes: routes,
                                    channelStateProvider: stateProvider)
        let endpoint = try await server.start()
        addTeardownBlock {
            await server.stop()
        }
        return (server, TestHTTPClient(endpoint: endpoint))
    }

    private func cacheControl(_ response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "Cache-Control")
    }

    private func makeStaticSite() throws -> URL {
        let root = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(root) }
        let staticDirectory = root.appendingPathComponent("static")
        try FileManager.default.createDirectory(at: staticDirectory, withIntermediateDirectories: true)
        try Data("<!doctype html><title>worker</title>\n".utf8)
            .write(to: staticDirectory.appendingPathComponent("index.html"))
        try Data("console.log('boot');\n".utf8)
            .write(to: staticDirectory.appendingPathComponent("boot.js"))
        try Data("self.onmessage = () => {};\n".utf8)
            .write(to: staticDirectory.appendingPathComponent("worker-entry.js"))
        try Data("export const client = 1;\n".utf8)
            .write(to: staticDirectory.appendingPathComponent("client.js"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        return root
    }

    // MARK: - Start and token

    func testStartBindsLoopbackRandomPortAndGeneratesToken() async throws {
        let (_, client) = try await startServer()
        XCTAssertEqual(client.endpoint.baseURL.host, "127.0.0.1")
        let port = try XCTUnwrap(client.endpoint.baseURL.port)
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(client.endpoint.token.count, 32)
        XCTAssertTrue(client.endpoint.token.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(client.endpoint.origin, "http://127.0.0.1:\(port)")
    }

    func testTwoStartsGetDifferentTokens() async throws {
        let first = LoopbackServer()
        let second = LoopbackServer()
        let a = try await first.start()
        let b = try await second.start()
        addTeardownBlock {
            await first.stop()
            await second.stop()
        }
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertNotEqual(a.baseURL.port, b.baseURL.port)
    }

    // MARK: - Security

    func testMissingTokenIsUnauthorizedWithNoStore() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (http, data) = try await client.send("GET", "/", authorized: false)
        XCTAssertEqual(http.statusCode, 401)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unauthorized")
    }

    func testPageWithBearerTokenAndCrossOriginIsolation() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (http, data) = try await client.send("GET", "/")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "<!doctype html><title>worker</title>\n")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy"), "same-origin")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy"), "require-corp")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testCrossOriginIsolationDisabledOmitsCoopAndCoep() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")),
            configuration: LoopbackConfiguration(crossOriginIsolation: false))
        let (http, _) = try await client.send("GET", "/")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNil(http.value(forHTTPHeaderField: "Cross-Origin-Opener-Policy"))
        XCTAssertNil(http.value(forHTTPHeaderField: "Cross-Origin-Embedder-Policy"))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testPageWithQueryToken() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let request = client.makeRequest(
            "GET", "/?token=\(client.endpoint.token)", authorized: false)
        let (data, response) = try await client.session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("worker"))
    }

    func testWrongTokenIsForbidden() async throws {
        let (_, client) = try await startServer()
        var request = client.makeRequest("GET", "/", authorized: false)
        request.setValue("Bearer wrong-value",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "forbidden")
    }

    func testWrongOriginIsForbidden() async throws {
        let (_, client) = try await startServer()
        let (http, _) = try await client.send("GET", "/", origin: "http://127.0.0.1:1")
        XCTAssertEqual(http.statusCode, 403)
        let (other, _) = try await client.send("GET", "/", origin: "http://other.example")
        XCTAssertEqual(other.statusCode, 403)
    }

    func testMatchingOriginIsAccepted() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (http, _) = try await client.send("GET", "/", origin: client.endpoint.origin)
        XCTAssertEqual(http.statusCode, 200)
    }

    // MARK: - Static and images

    func testStaticAssetServedAndMissingIs404() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (http, data) = try await client.send("GET", "/static/boot.js")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "console.log('boot');\n")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"),
                       "application/javascript; charset=utf-8")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let (missing, _) = try await client.send("GET", "/static/nope.js")
        XCTAssertEqual(missing.statusCode, 404)
    }

    func testStaticTraversalIsRejected() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (http, _) = try await client.send("GET", "/static/%2e%2e/secret.txt")
        XCTAssertEqual(http.statusCode, 404)
        let (absolute, _) = try await client.send("GET", "/static/%2Fetc%2Fpasswd")
        XCTAssertEqual(absolute.statusCode, 404)
    }

    // MARK: - D22 launch cookie

    func testPageResponseSetsHttpOnlySameSiteStrictLaunchCookie() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (http, _) = try await client.send("GET", "/")
        XCTAssertEqual(http.statusCode, 200)
        let setCookie = try XCTUnwrap(
            http.value(forHTTPHeaderField: "Set-Cookie"),
            "D22: the page response must set the launch cookie")
        XCTAssertTrue(setCookie.hasPrefix(
            "\(LoopbackServer.launchCookieName)=\(client.endpoint.token)"))
        XCTAssertTrue(setCookie.contains("HttpOnly"))
        XCTAssertTrue(setCookie.contains("SameSite=Strict"))
        XCTAssertTrue(setCookie.contains("Path=/"))
    }

    func testStaticAssetsAcceptTheLaunchCookieWithoutAQueryToken() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        // A page load with ?token= seeds the cookie in the URLSession jar...
        let request = client.makeRequest("GET", "/?token=\(client.endpoint.token)",
                                         authorized: false)
        let (pageData, pageResponse) = try await client.session.data(for: request)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: pageData, as: UTF8.self).contains("worker"))

        // ...and the page-relative boot.js request carries no query token.
        let (data, response) = try await client.session.data(
            for: client.makeRequest("GET", "/static/boot.js", authorized: false))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200,
                       "D22: page-relative assets authenticate with the cookie")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "console.log('boot');\n")

        // The explicit Cookie header is the same credential.
        let cookie = "\(LoopbackServer.launchCookieName)=\(client.endpoint.token)"
        let (explicit, _) = try await client.send("GET", "/static/worker-entry.js",
                                                  headers: ["Cookie": cookie],
                                                  authorized: false)
        XCTAssertEqual(explicit.statusCode, 200)
    }

    func testStaticAssetsStillRequireACredential() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let (missing, _) = try await client.send("GET", "/static/boot.js", authorized: false)
        XCTAssertEqual(missing.statusCode, 401)
        let (wrong, _) = try await client.send(
            "GET", "/static/boot.js",
            headers: ["Cookie": "\(LoopbackServer.launchCookieName)=wrong"],
            authorized: false)
        XCTAssertEqual(wrong.statusCode, 403)
    }

    func testAPIRoutesAcceptTheLaunchCookieOnly() async throws {
        let (_, client) = try await startServer()
        let cookie = "\(LoopbackServer.launchCookieName)=\(client.endpoint.token)"
        // No `/api` route is mounted here: the cookie authenticates, so the
        // request reaches routing and answers 404 instead of 401.
        let (authorized, _) = try await client.send("GET", "/api/session",
                                                    headers: ["Cookie": cookie],
                                                    authorized: false)
        XCTAssertEqual(authorized.statusCode, 404)
        let (missing, _) = try await client.send("GET", "/api/session", authorized: false)
        XCTAssertEqual(missing.statusCode, 401)
    }

    func testLaunchCookieDoesNotAuthorizeImageRoutes() async throws {
        let root = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(root) }
        let image = root.appendingPathComponent("image.tar.gz")
        try Data([1, 2, 3]).write(to: image)
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(imageBaseURL: image))
        let cookie = "\(LoopbackServer.launchCookieName)=\(client.endpoint.token)"
        let (cookieOnly, _) = try await client.send("GET", "/image/base",
                                                    headers: ["Cookie": cookie],
                                                    authorized: false)
        XCTAssertEqual(cookieOnly.statusCode, 401,
                       "D22 keeps the pre-existing rule outside /, /static and /api")
        let (withToken, _) = try await client.send("GET", "/image/base")
        XCTAssertEqual(withToken.statusCode, 200)
    }

    func testImageRoutesServeArchives() async throws {
        let root = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(root) }
        let base = root.appendingPathComponent("image.tar.gz")
        try Data([1, 2, 3]).write(to: base)
        let sha = sha256Name()
        let lazy = root.appendingPathComponent("\(sha).tar.gz")
        try Data([4, 5, 6]).write(to: lazy)
        let bootID = "00112233445566778899aabbccddeeff"
        let overlay = root.appendingPathComponent("overlay.tar")
        try Data([7, 8]).write(to: overlay)
        let routes = LoopbackRoutes(
            imageBaseURL: base,
            lazyImageProvider: { requested in requested == sha ? lazy : nil },
            overlayProvider: { requested in requested == bootID ? overlay : nil })
        let (_, client) = try await startServer(routes: routes)

        let (baseResponse, baseData) = try await client.send("GET", "/image/base")
        XCTAssertEqual(baseResponse.statusCode, 200)
        XCTAssertEqual(baseData, Data([1, 2, 3]))
        XCTAssertEqual(baseResponse.value(forHTTPHeaderField: "Content-Type"), "application/gzip")
        XCTAssertEqual(baseResponse.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let (lazyResponse, lazyData) = try await client.send("GET", "/image/lazy/\(sha).tar.gz")
        XCTAssertEqual(lazyResponse.statusCode, 200)
        XCTAssertEqual(lazyData, Data([4, 5, 6]))

        let (overlayResponse, overlayData) = try await client.send(
            "GET", "/image/overlay/\(bootID).tar")
        XCTAssertEqual(overlayResponse.statusCode, 200)
        XCTAssertEqual(overlayData, Data([7, 8]))
        XCTAssertEqual(overlayResponse.value(forHTTPHeaderField: "Content-Type"), "application/x-tar")

        let (unknown, _) = try await client.send("GET", "/image/lazy/\(String(repeating: "a", count: 64)).tar.gz")
        XCTAssertEqual(unknown.statusCode, 404)
        let (bad, _) = try await client.send("GET", "/image/overlay/not-a-boot-id.tar")
        XCTAssertEqual(bad.statusCode, 404)
    }

    func testOverlayIsUniquePerBoot() async throws {
        let root = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(root) }
        let bootA = "00000000000000000000000000000001"
        let bootB = "00000000000000000000000000000002"
        let fileA = root.appendingPathComponent("a.tar")
        let fileB = root.appendingPathComponent("b.tar")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)
        let (_, client) = try await startServer(routes: LoopbackRoutes(
            overlayProvider: { $0 == bootA ? fileA : ($0 == bootB ? fileB : nil) }))
        let (_, dataA) = try await client.send("GET", "/image/overlay/\(bootA).tar")
        let (_, dataB) = try await client.send("GET", "/image/overlay/\(bootB).tar")
        XCTAssertEqual(String(decoding: dataA, as: UTF8.self), "A")
        XCTAssertEqual(String(decoding: dataB, as: UTF8.self), "B")
    }

    func testEveryResponseHasNoStore() async throws {
        let (_, client) = try await startServer(routes: LoopbackRoutes(
            httpEgress: EchoHTTPEgress()))
        let responses = [
            try await client.send("GET", "/").0,
            try await client.send("GET", "/nope").0,
            try await client.send("GET", "/", authorized: false).0,
            try await client.send("POST", "/v1/http",
                                  headers: ["X-PDSH-Target-URL": "http://example.test/echo"]).0,
        ]
        for response in responses {
            XCTAssertEqual(cacheControl(response), "no-store")
        }
    }

    // MARK: - Egress

    private func egressHeaders(target: String = "http://example.test/echo",
                               method: String = "POST") -> [String: String] {
        ["X-PDSH-Target-URL": target,
         "X-PDSH-Target-Method": method,
         "Content-Type": "application/octet-stream"]
    }

    func testSmallPostEchoesThroughHostEgress() async throws {
        let egress = EchoHTTPEgress()
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        let body = Data(repeating: 0x5A, count: 1024)
        let (http, data) = try await client.send("POST", "/v1/http",
                                                 headers: egressHeaders(), body: body)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, body)
        let recorded = try XCTUnwrap(egress.recordedRequests.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.url.absoluteString, "http://example.test/echo")
        XCTAssertEqual(recorded.body, body)
        XCTAssertNil(recorded.headers["Authorization"])
        XCTAssertNil(recorded.headers["authorization"])
        XCTAssertEqual(recorded.headers["content-type"], "application/octet-stream")
    }

    func testEgressDoesNotForwardLaunchCookieOrReturnUpstreamCookies() async throws {
        let egress = CookieBoundaryEgress()
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        let browserCookie = "\(LoopbackServer.launchCookieName)=\(client.endpoint.token); account=browser"
        let pageReferer = "\(client.endpoint.origin)/?token=\(client.endpoint.token)"
        let (http, _) = try await client.send(
            "POST", "/v1/http",
            headers: egressHeaders().merging([
                "Cookie": browserCookie,
                "Referer": pageReferer,
                "Referrer": pageReferer,
            ]) { _, new in new })

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNil(egress.recordedRequests.first?.headers["cookie"],
                     "the loopback launch cookie must not leave the authenticated origin")
        XCTAssertNil(egress.recordedRequests.first?.headers["referer"],
                     "a page Referer query token must not leave the authenticated origin")
        XCTAssertNil(egress.recordedRequests.first?.headers["referrer"],
                     "the nonstandard Referrer spelling must be dropped too")
        XCTAssertNil(http.value(forHTTPHeaderField: "Set-Cookie"),
                     "an upstream must not set cookies on the loopback origin")
        XCTAssertNil(http.value(forHTTPHeaderField: "Set-Cookie2"),
                     "legacy upstream cookie headers must not reach the loopback origin")
        XCTAssertNil(http.value(forHTTPHeaderField: "Clear-Site-Data"),
                     "an upstream must not clear the loopback origin's site data")
    }

    func testHTTPEgressDoesNotForwardLoopbackCookieOrReferer() async throws {
        let egress = EchoHTTPEgress()
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        // Raw TCP proves the headers are actually on the loopback wire. A
        // same-origin XHR attaches the launch cookie and Referer itself.
        let tcp = RawTCPClient(port: UInt16(client.endpoint.baseURL.port ?? 0))
        addTeardownBlock { tcp.close() }
        try await tcp.connect()
        let body = "echo"
        var request = Data("POST /v1/http HTTP/1.1\r\n".utf8)
        request.append(Data("Host: 127.0.0.1\r\n".utf8))
        request.append(Data("Authorization: Bearer \(client.endpoint.token)\r\n".utf8))
        request.append(Data("X-PDSH-Target-URL: http://example.test/echo\r\n".utf8))
        request.append(Data("X-PDSH-Target-Method: POST\r\n".utf8))
        request.append(Data("Cookie: \(LoopbackServer.launchCookieName)=\(client.endpoint.token); upstream=1\r\n".utf8))
        request.append(Data("Cookie2: legacy=1\r\n".utf8))
        request.append(Data("Referer: \(client.endpoint.origin)/?token=\(client.endpoint.token)\r\n".utf8))
        request.append(Data("Referrer: \(client.endpoint.origin)/?token=\(client.endpoint.token)\r\n".utf8))
        request.append(Data("Content-Type: text/plain\r\n".utf8))
        request.append(Data("Content-Length: \(body.utf8.count)\r\n\r\n".utf8))
        request.append(Data(body.utf8))
        try await tcp.send(request)
        let head = try await tcp.readUntil(Data("\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        _ = try await tcp.readUntil(Data("0\r\n\r\n".utf8))
        let recorded = try XCTUnwrap(egress.recordedRequests.first)
        for name in recorded.headers.keys {
            let lower = name.lowercased()
            XCTAssertFalse(["cookie", "cookie2", "referer", "referrer"].contains(lower),
                           "the loopback identity header \(name) reached the upstream")
        }
    }

    func testEgressResponseCannotSetOrClearLoopbackCookie() async throws {
        let cookieName = "xl_test_egress_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let egress = FixedHeaderHTTPEgress(
            status: 200,
            headers: [
                "Set-Cookie": "\(cookieName)=attacker; Path=/; HttpOnly",
                "Set-Cookie2": "\(cookieName)_legacy=attacker; Path=/",
                "Clear-Site-Data": "\"cookies\", \"storage\"",
                "Alt-Svc": "h2=\":443\"; ma=86400",
                "X-Keep": "yes",
            ],
            body: Data("ok".utf8))
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        // The default configuration uses the shared cookie jar, so a leaked
        // Set-Cookie would be observable here after URLSession processes it.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer {
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == cookieName {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            session.invalidateAndCancel()
        }
        let (data, response) = try await session.data(
            for: client.makeRequest("POST", "/v1/http", headers: egressHeaders()))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, Data("ok".utf8))
        for name in ["Set-Cookie", "Set-Cookie2", "Clear-Site-Data", "Alt-Svc"] {
            XCTAssertNil(http.value(forHTTPHeaderField: name), "\(name) reached the browser")
        }
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Keep"), "yes")
        let stored = (HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == cookieName }
        XCTAssertFalse(stored, "the egress response wrote to the URLSession cookie jar")
    }

    func testLargePostEchoesThroughHostEgress() async throws {
        let egress = EchoHTTPEgress()
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        let body = Data(repeating: 0xA5, count: 1024 * 1024)
        let (http, data) = try await client.send("POST", "/v1/http",
                                                 headers: egressHeaders(), body: body)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data.count, body.count)
        XCTAssertEqual(data, body)
    }

    func testStreamingFirstChunkArrivesBeforeTheEnd() async throws {
        let egress = GatedStreamingEgress()
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        let request = client.makeRequest("POST", "/v1/http", headers: egressHeaders())
        let (bytes, response) = try await client.session.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        var received = Data()
        var sawFirstLine = false
        var secondLineBeforeRelease = false
        for try await byte in bytes {
            received.append(byte)
            if byte == 0x0A && !sawFirstLine {
                sawFirstLine = true
                if await egress.gate.isReleased() {
                    secondLineBeforeRelease = true
                }
                XCTAssertFalse(secondLineBeforeRelease)
                await egress.gate.release()
            }
        }
        XCTAssertTrue(sawFirstLine)
        let text = String(decoding: received, as: UTF8.self)
        XCTAssertTrue(text.contains("\"chunk\":1"))
        XCTAssertTrue(text.contains("\"chunk\":2"))
    }

    func testEgressFailureBeforeHeadIsBadGateway() async throws {
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: FailingHTTPEgress()))
        let (http, _) = try await client.send("POST", "/v1/http", headers: egressHeaders())
        XCTAssertEqual(http.statusCode, 502)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testMissingEgressTargetIsBadRequest() async throws {
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: EchoHTTPEgress()))
        let (http, _) = try await client.send("POST", "/v1/http", body: Data("x".utf8))
        XCTAssertEqual(http.statusCode, 400)
    }

    func testEgressRedirectCannotReachAuthenticatedControlRoute() async throws {
        for status in [302, 307, 308] {
            let workspace = try makeTemporaryDirectory()
            addTeardownBlock { removeTemporaryDirectory(workspace) }
            let provider = ScriptedExecProvider(events: [.exit(code: 0, signal: nil, truncated: false)])
            let bridge = FakeExecBridge(provider: provider)
            _ = try await bridge.start()
            addTeardownBlock { await bridge.stop() }
            let (_, client) = try await startServer(routes: LoopbackRoutes(
                httpEgress: RedirectingEgress(status: status), execBridge: bridge))
            let body = try JSONSerialization.data(withJSONObject: [
                "exec_id": "redirect-must-not-run-\(status)",
                "argv": ["echo", "must-not-run"],
                "cwd": workspace.path,
            ])
            // Match XHR's credentialed same-origin automatic redirect. Native
            // URLSession otherwise drops Authorization during the redirect.
            // The body is a valid exec request: a 307/308 must never deliver it
            // to the authenticated control route with the channel bearer.
            var headers = egressHeaders(target: "http://example.test/redirect")
            headers["Content-Type"] = "application/json"
            let redirects = AuthenticatedAutoRedirects(endpoint: client.endpoint)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let request = client.makeRequest("POST", "/v1/http", headers: headers,
                body: body, origin: client.endpoint.origin)
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, status)
            XCTAssertEqual(http.url?.path, "/v1/http")
            XCTAssertNil(http.value(forHTTPHeaderField: "Location"))
            XCTAssertEqual(data, Data("redirect refused at the proxy boundary".utf8))
            XCTAssertEqual(redirects.count, 0)
            XCTAssertEqual(provider.runCount, 0, "redirect \(status) reached /v1/exec")
        }
    }

    // MARK: - /v1/hello

    func testHelloMergesExecutorAndChannelCapabilities() async throws {
        let provider = ScriptedExecProvider(events: [])
        let (_, client) = try await startServer(routes: LoopbackRoutes(
            execProvider: provider,
            accelerators: ["rg", "jaq"]))
        let (http, data) = try await client.send("GET", "/v1/hello")
        XCTAssertEqual(http.statusCode, 200)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["protocol"] as? String, "pdsh-exec-bridge/1")
        let capabilities = try XCTUnwrap(object["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["exec"] as? Bool, true)
        XCTAssertEqual((capabilities["accelerators"] as? [String]) ?? [], ["rg", "jaq"])
        let channel = try XCTUnwrap(capabilities["channel"] as? [String: Any])
        XCTAssertEqual(channel["proto"] as? Int, 1)
        let execProvider = try XCTUnwrap(capabilities["exec_provider"] as? [String: Any])
        XCTAssertEqual(execProvider["environment"] as? String, "test")
    }

    // MARK: - Exec bridge forwarding

    func testExecBridgeRoutesAreForwarded() async throws {
        let workspace = try makeTemporaryDirectory()
        addTeardownBlock { removeTemporaryDirectory(workspace) }
        let provider = ScriptedExecProvider(events: [
            .stdout(seq: 0, data: Data("needle\n".utf8)),
            .exit(code: 0, signal: nil, truncated: false),
        ])
        let bridge = FakeExecBridge(provider: provider)
        _ = try await bridge.start()
        addTeardownBlock { await bridge.stop() }

        let (_, client) = try await startServer(routes: LoopbackRoutes(execBridge: bridge))
        let body = try JSONSerialization.data(withJSONObject: [
            "exec_id": "xl1-test-0",
            "argv": ["rg", "needle"],
            "cwd": workspace.path,
        ])
        let (http, data) = try await client.send(
            "POST", "/v1/exec",
            headers: ["Content-Type": "application/json"],
            body: body,
            origin: client.endpoint.origin)
        XCTAssertEqual(http.statusCode, 200)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("\"type\":\"start\"") })
        XCTAssertTrue(lines.contains { $0.contains("\"type\":\"exit\"") })
        XCTAssertEqual(provider.runCount, 1)

        let (status, statusData) = try await client.send("GET", "/v1/exec/xl1-test-0")
        XCTAssertEqual(status.statusCode, 200)
        XCTAssertTrue(String(decoding: statusData, as: UTF8.self).contains("exited"))
    }

    // MARK: - MCP proxy

    func testMCPProxyPreservesIdempotencyKey() async throws {
        let upstream = try await TinyHTTPServer.start(responseBody: Data("{\"ok\":true}".utf8))
        addTeardownBlock { upstream.stop() }
        let base = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let (_, client) = try await startServer(routes: LoopbackRoutes(mcpBaseURL: base))
        let idem = "xl1-00112233445566778899aabbccddeeff"
        let (http, data) = try await client.send(
            "POST", "/mcp",
            headers: ["Idempotency-Key": idem, "Content-Type": "application/json"],
            body: Data("{\"jsonrpc\":\"2.0\"}".utf8))
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true}")
        let sawKey = await waitUntil {
            upstream.requestHead.lowercased().contains("idempotency-key: " + idem.lowercased())
        }
        XCTAssertTrue(sawKey)
        XCTAssertFalse(upstream.requestHead.contains(client.endpoint.token))
    }

    // MARK: - HTTP/1.1 corners

    func testChunkedRequestBodyIsAccepted() async throws {
        let egress = EchoHTTPEgress()
        let (_, client) = try await startServer(routes: LoopbackRoutes(httpEgress: egress))
        let tcp = RawTCPClient(port: UInt16(client.endpoint.baseURL.port ?? 0))
        addTeardownBlock { tcp.close() }
        try await tcp.connect()
        var request = Data("POST /v1/http HTTP/1.1\r\n".utf8)
        request.append(Data("Host: 127.0.0.1\r\n".utf8))
        request.append(Data("Authorization: Bearer \(client.endpoint.token)\r\n".utf8))
        request.append(Data("X-PDSH-Target-URL: http://example.test/chunked\r\n".utf8))
        request.append(Data("X-PDSH-Target-Method: POST\r\n".utf8))
        request.append(Data("Transfer-Encoding: chunked\r\n\r\n".utf8))
        request.append(Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8))
        try await tcp.send(request)
        let head = try await tcp.readUntil(Data("\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let body = try await tcp.readUntil(Data("0\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("hello world"))
        XCTAssertEqual(egress.recordedRequests.first?.body, Data("hello world".utf8))
    }

    func testKeepAliveServesTwoRequestsOnOneConnection() async throws {
        let root = try makeStaticSite()
        let (_, client) = try await startServer(
            routes: LoopbackRoutes(staticDirectory: root.appendingPathComponent("static")))
        let tcp = RawTCPClient(port: UInt16(client.endpoint.baseURL.port ?? 0))
        addTeardownBlock { tcp.close() }
        try await tcp.connect()
        let token = client.endpoint.token
        for index in 0..<2 {
            let request = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8)
            try await tcp.send(request)
            let head = try await tcp.readUntil(Data("\r\n\r\n".utf8))
            let text = String(decoding: head, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), "request \(index)")
            let body = try await tcp.readExactly(37)
            XCTAssertEqual(String(decoding: body, as: UTF8.self),
                           "<!doctype html><title>worker</title>\n")
        }
    }
}

private struct RedirectingEgress: HTTPEgress {
    let status: Int

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(status: status,
                headers: ["lOcAtIoN": "/v1/exec"],
                body: Data("redirect refused at the proxy boundary".utf8), isFinal: true))
            continuation.finish()
        }
    }
}

private final class CookieBoundaryEgress: HTTPEgress, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPEgressRequest] = []

    var recordedRequests: [HTTPEgressRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(
                status: 200,
                headers: [
                    "Set-Cookie": "upstream-session=must-not-stick; Path=/",
                    "Set-Cookie2": "legacy-session=must-not-stick",
                    "Clear-Site-Data": "\"cookies\", \"storage\", \"cache\"",
                ],
                body: Data("ok".utf8),
                isFinal: true))
            continuation.finish()
        }
    }
}

private final class AuthenticatedAutoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: LoopbackEndpoint
    private let lock = NSLock()
    private var redirectCount = 0

    init(endpoint: LoopbackEndpoint) { self.endpoint = endpoint }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return redirectCount
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirectCount += 1
        lock.unlock()
        guard let url = request.url, url.scheme == endpoint.baseURL.scheme,
              url.host == endpoint.baseURL.host, url.port == endpoint.baseURL.port else {
            completionHandler(nil)
            return
        }
        var authenticated = request
        authenticated.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        authenticated.setValue(endpoint.origin, forHTTPHeaderField: "Origin")
        completionHandler(authenticated)
    }
}

private struct FixedHeaderHTTPEgress: HTTPEgress {
    let status: Int
    let headers: [String: String]
    let body: Data

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(status: status, headers: headers,
                                               body: body, isFinal: true))
            continuation.finish()
        }
    }
}
