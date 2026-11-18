// SPDX-License-Identifier: MIT
// spec/device/v1/xiaozhi-firmware.md §2–§3: the shared vectors in
// golden/xiaozhi-ota.jsonl judge the real report parser and rewrite; the route
// tests drive the relay with an injected upstream and clock.
#if DEBUG
import Foundation
import XCTest
@testable import PhoneDSHBLE

final class XiaozhiOTATests: XCTestCase {
    private func vectors(kind: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("spec/device/v1/golden/xiaozhi-ota.jsonl"), encoding: .utf8)
        let all = try text.split(separator: "\n").map { line -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        return all.filter { $0["kind"] as? String == kind }
    }

    private func report(_ object: [String: Any]) -> XiaozhiDeviceReport {
        XiaozhiDeviceReport(mac: object["mac"] as? String, version: object["version"] as? String,
                            elfSha256: object["elfSha256"] as? String, boardType: object["boardType"] as? String)
    }

    // MARK: shared vectors

    func testReportVectors() throws {
        let cases = try vectors(kind: "report")
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let id = vector["id"] as? String ?? "?"
            let input = try XCTUnwrap(vector["input"] as? [String: Any], id)
            let headers = try XCTUnwrap(input["headers"] as? [String: String], id)
            let body = (input["body"] as? String).map { Data($0.utf8) }
            let parsed = XiaozhiDeviceReport.parse(headers: headers, body: body)
            if let sentinel = vector["report"] as? String {
                XCTAssertEqual(sentinel, "invalid_body", id)
                XCTAssertEqual(parsed, .invalidBody, id)
            } else {
                let expected = report(try XCTUnwrap(vector["report"] as? [String: Any], id))
                XCTAssertEqual(parsed, .report(expected), id)
            }
        }
    }

    func testRewriteVectors() throws {
        let cases = try vectors(kind: "rewrite")
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let id = vector["id"] as? String ?? "?"
            let input = try XCTUnwrap(vector["input"] as? [String: Any], id)
            let upstream = Data(try XCTUnwrap(input["body"] as? String, id).utf8)
            var staged: XiaozhiOTARewrite.Staged?
            if let object = input["staged"] as? [String: String] {
                staged = (try XCTUnwrap(object["mac"], id), try XCTUnwrap(object["sha256"], id), try XCTUnwrap(object["elfSha256"], id))
            }
            let result = XiaozhiOTARewrite.apply(
                status: try XCTUnwrap(input["status"] as? Int, id), body: upstream,
                report: report(try XCTUnwrap(input["report"] as? [String: Any], id)),
                staged: staged, base: try XCTUnwrap(input["base"] as? String, id))
            XCTAssertEqual(result.decision.rawValue, vector["decision"] as? String, id)
            let expected = Data(try XCTUnwrap(vector["body"] as? String, id).utf8)
            if result.decision == .passthrough {
                XCTAssertEqual(result.body, upstream, "\(id): passthrough keeps the upstream bytes")
            }
            if let want = XiaozhiJSON.parse(expected) {
                // JSON value equality plus member order.
                XCTAssertEqual(XiaozhiJSON.parse(result.body), want, id)
            } else {
                XCTAssertEqual(result.body, expected, id)
            }
        }
    }

    func testOrderedJSONRoundTripKeepsOrderAndNumbers() throws {
        let text = #"{"z":1.50,"a":[true,null,"é\n\u0001"],"m":{"k":-0.5e+3}}"#
        let value = try XCTUnwrap(XiaozhiJSON.parse(Data(text.utf8)))
        XCTAssertEqual(String(decoding: value.serialized(), as: UTF8.self), #"{"z":1.50,"a":[true,null,"é\n\u0001"],"m":{"k":-0.5e+3}}"#)
        for bad in ["{", "[1,]", "{\"a\":1} x", "01", "\"\\ud800\"", ""] {
            XCTAssertNil(XiaozhiJSON.parse(Data(bad.utf8)), bad)
        }
    }

    // MARK: staged images and records

    func testStagedImagesLookupAndReplace() throws {
        let store = XiaozhiStagedImages()
        let elf = String(repeating: "1", count: 64)
        let image = try XCTUnwrap(store.stage(mac: "98:c3:77:f4:ff:38", imageData: Data("abc".utf8), elfSha256: elf))
        XCTAssertEqual(image.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(store.staged(forMAC: "98:C3:77:F4:FF:38"), image)
        XCTAssertEqual(store.image(sha256: image.sha256), image)
        let next = try XCTUnwrap(store.stage(mac: "98:c3:77:f4:ff:38", imageData: Data("abcd".utf8), elfSha256: elf))
        XCTAssertNil(store.image(sha256: image.sha256), "an earlier staged image is replaced")
        XCTAssertEqual(store.image(sha256: next.sha256), next)
        XCTAssertNil(store.stage(mac: "98:C3:77:F4:FF:38", imageData: Data(), elfSha256: elf), "mac must be canonical")
        XCTAssertNil(store.stage(mac: "98:c3:77:f4:ff:38", imageData: Data(), elfSha256: "XYZ"))
    }

    // MARK: route dispatch

    private final class FakeUpstream: XiaozhiUpstream, @unchecked Sendable {
        var result: Result<(status: Int, contentType: String?, body: Data), Error>
        private(set) var calls: [(method: String, headers: [String: String], body: Data?)] = []
        init(_ result: Result<(status: Int, contentType: String?, body: Data), Error>) { self.result = result }
        func send(method: String, headers: [String: String], body: Data?) async throws -> (status: Int, contentType: String?, body: Data) {
            calls.append((method, headers, body))
            return try result.get()
        }
    }

    private let mac = "98:c3:77:f4:ff:38"
    private let upstreamBody = #"{"mqtt":{"endpoint":"x"},"firmware":{"version":"2.6.0","url":""},"server_time":{"timestamp":1}}"#
    private let reportBody = #"{"application":{"version":"2.6.0","elf_sha256":"0d90d0cc55ae475e23bd13b309b2e300927c1e7531e7f3f5e81868ae2ef535ab"},"board":{"type":"ai-passport"}}"#

    @MainActor private func makeRelay(_ upstream: FakeUpstream, wifi: String? = "192.168.6.50")
        -> XiaozhiOTARelay {
        XiaozhiOTARelay(upstream: upstream, now: { Date(timeIntervalSince1970: 1000) }, wifiIPv4: { wifi })
    }

    private func otaRequest(method: String = "POST", headers extra: [String: String] = [:]) -> XiaozhiHTTPRequest {
        var headers = ["device-id": mac, "client-id": "c", "cookie": "secret", "x-other": "1",
                       "content-type": "application/json", "authorization": "Bearer t"]
        headers.merge(extra) { _, new in new }
        return XiaozhiHTTPRequest(method: method, path: "/xiaozhi/ota/", headers: headers, body: Data(reportBody.utf8))
    }

    @MainActor func testUnknownRoutesAre404() async {
        let relay = makeRelay(FakeUpstream(.success((200, nil, Data()))))
        for (method, path) in [("GET", "/"), ("GET", "/xiaozhi/ota"), ("POST", "/xiaozhi/firmware/x.bin"),
                               ("PUT", "/xiaozhi/ota/"), ("GET", "/xiaozhi/firmware/\(String(repeating: "A", count: 64)).bin"),
                               ("GET", "/xiaozhi/firmware/abc.bin")] {
            let response = await relay.handle(peerHost: "192.168.6.9", XiaozhiHTTPRequest(method: method, path: path))
            XCTAssertEqual(response.status, 404, "\(method) \(path)")
            XCTAssertTrue(response.body.isEmpty)
        }
    }

    @MainActor func testPublicPeerGets403AndIsNotRecorded() async {
        let upstream = FakeUpstream(.success((200, nil, Data(upstreamBody.utf8))))
        let relay = makeRelay(upstream)
        let response = await relay.handle(peerHost: "8.8.8.8", otaRequest())
        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(upstream.calls.isEmpty)
        XCTAssertTrue(relay.records.all.isEmpty)
        for host in ["192.168.1.2", "10.0.0.3", "172.16.4.4", "169.254.1.1", "fe80::1%en0", "fd00::2"] {
            let ok = await relay.handle(peerHost: host, XiaozhiHTTPRequest(method: "GET", path: "/nope"))
            XCTAssertEqual(ok.status, 404, host)
        }
    }

    @MainActor func testFirmwareDownloadHitAndMiss() async throws {
        let relay = makeRelay(FakeUpstream(.success((200, nil, Data()))))
        let image = try XCTUnwrap(relay.images.stage(mac: mac, imageData: Data("firmware".utf8), elfSha256: String(repeating: "1", count: 64)))
        let hit = await relay.handle(peerHost: "192.168.6.9", XiaozhiHTTPRequest(method: "GET", path: "/xiaozhi/firmware/\(image.sha256).bin"))
        XCTAssertEqual(hit.status, 200)
        XCTAssertEqual(hit.contentType, "application/octet-stream")
        XCTAssertEqual(hit.body, Data("firmware".utf8))
        let miss = await relay.handle(peerHost: "192.168.6.9", XiaozhiHTTPRequest(method: "GET", path: "/xiaozhi/firmware/\(String(repeating: "0", count: 64)).bin"))
        XCTAssertEqual(miss.status, 404)
        XCTAssertTrue(miss.body.isEmpty)
    }

    @MainActor func testVersionCheckForwardsOnlyListedHeadersAndRecords() async throws {
        let upstream = FakeUpstream(.success((200, "application/json; charset=utf-8", Data(upstreamBody.utf8))))
        let relay = makeRelay(upstream)
        let response = await relay.handle(peerHost: "192.168.6.9", otaRequest())
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(response.body, Data(upstreamBody.utf8), "no staged image: bytes unchanged")
        let call = try XCTUnwrap(upstream.calls.first)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.body, Data(reportBody.utf8))
        XCTAssertEqual(call.headers, ["Device-Id": mac, "Client-Id": "c", "Content-Type": "application/json", "Authorization": "Bearer t"])
        let record = try XCTUnwrap(relay.records.record(forMAC: mac))
        XCTAssertEqual(record.version, "2.6.0")
        XCTAssertEqual(record.boardType, "ai-passport")
        XCTAssertEqual(record.lastSeen, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(record.lastDecision, .passthrough)
    }

    @MainActor func testVersionCheckOffersStagedImage() async throws {
        let upstream = FakeUpstream(.success((200, nil, Data(upstreamBody.utf8))))
        let relay = makeRelay(upstream)
        let image = try XCTUnwrap(relay.images.stage(mac: mac, imageData: Data("fw".utf8), elfSha256: String(repeating: "1", count: 64)))
        let response = await relay.handle(peerHost: "192.168.6.9", otaRequest())
        XCTAssertEqual(response.contentType, "application/json", "default when upstream sent none")
        let want = #"{"mqtt":{"endpoint":"x"},"firmware":{"version":"2.6.0.1","url":"http://192.168.6.50:8781/xiaozhi/firmware/\#(image.sha256).bin"},"server_time":{"timestamp":1}}"#
        XCTAssertEqual(XiaozhiJSON.parse(response.body), XiaozhiJSON.parse(Data(want.utf8)))
        XCTAssertEqual(relay.records.record(forMAC: mac)?.lastDecision, .offer)
    }

    @MainActor func testInvalidBodyIs400WithoutForwarding() async {
        let upstream = FakeUpstream(.success((200, nil, Data())))
        let relay = makeRelay(upstream)
        var request = otaRequest()
        request.body = Data("[1]".utf8)
        let response = await relay.handle(peerHost: "192.168.6.9", request)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(upstream.calls.isEmpty)
        XCTAssertTrue(relay.records.all.isEmpty)
    }

    @MainActor func testUpstreamFailureIs502AndStillRecorded() async throws {
        let relay = makeRelay(FakeUpstream(.failure(URLError(.timedOut))))
        let response = await relay.handle(peerHost: "192.168.6.9", otaRequest())
        XCTAssertEqual(response.status, 502)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(relay.records.record(forMAC: mac)?.lastDecision, .upstreamFailed)
    }

    @MainActor func testInvalidMACIsRelayedButNotRecorded() async {
        let upstream = FakeUpstream(.success((200, nil, Data(upstreamBody.utf8))))
        let relay = makeRelay(upstream)
        let response = await relay.handle(peerHost: "192.168.6.9", otaRequest(headers: ["device-id": "nope"]))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(upstream.calls.count, 1)
        XCTAssertTrue(relay.records.all.isEmpty)
    }

    func testHTTPFramingLimits() {
        let ok = Data("POST /xiaozhi/ota/?a=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let request, let length, let start) = XiaozhiHTTP.parseHead(ok) else { return XCTFail() }
        XCTAssertEqual(request.path, "/xiaozhi/ota/")
        XCTAssertEqual(length, 2)
        XCTAssertEqual(ok[start...], Data("{}".utf8))
        XCTAssertEqual(XiaozhiHTTP.parseHead(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .reject(400))
        XCTAssertEqual(XiaozhiHTTP.parseHead(Data("POST / HTTP/1.1\r\nContent-Length: 65537\r\n\r\n".utf8)), .reject(413))
        XCTAssertEqual(XiaozhiHTTP.parseHead(Data(repeating: 65, count: XiaozhiHTTP.maxHead + 1)), .reject(413))
        let text = String(decoding: XiaozhiHTTP.encode(XiaozhiHTTPResponse(status: 404)), as: UTF8.self)
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
    }
}
#endif
