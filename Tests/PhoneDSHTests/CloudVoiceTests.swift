// SPDX-License-Identifier: MIT
// spec/v1/cloud-voice.md: the shared cases judge the real start builder,
// server-message decoder, transcript rule, speakable/chunk rules and the
// credential decision. TTS runs against a URLProtocol stub; nothing here
// contacts pdsh.tonoai.cn.

import Foundation
import XCTest
@testable import PhoneDSH

final class CloudVoiceTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/v1/golden/cloud-voice/cases.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func list(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(try cases()[key] as? [[String: Any]], key)
    }

    func testConstants() throws {
        let c = try XCTUnwrap(try cases()["constants"] as? [String: Any])
        XCTAssertEqual(c["asr_url"] as? String, CloudVoice.asrURL.absoluteString)
        XCTAssertEqual(c["asr_subprotocol"] as? String, CloudVoice.asrSubprotocol)
        XCTAssertEqual(c["tts_url"] as? String, CloudVoice.ttsURL.absoluteString)
        XCTAssertEqual(c["tts_voice"] as? String, CloudVoice.ttsVoice)
        XCTAssertEqual(c["tts_sample_rate"] as? Int, CloudVoice.ttsSampleRate)
        XCTAssertEqual(c["tts_input_max_scalars"] as? Int, CloudVoice.ttsInputMaxScalars)
        XCTAssertEqual(c["pre_start_queue_max"] as? Int, CloudVoice.preStartQueueMax)
        XCTAssertEqual(c["connect_timeout_ms"] as? Int, CloudVoice.connectTimeoutMs)
        XCTAssertEqual(c["started_timeout_ms"] as? Int, CloudVoice.startedTimeoutMs)
        XCTAssertEqual(c["finish_timeout_default_ms"] as? Int, CloudVoice.finishTimeoutDefaultMs)
        XCTAssertEqual(c["finish_grace_ms"] as? Int, CloudVoice.finishGraceMs)
    }

    func testStartMessage() throws {
        let start = try XCTUnwrap(try cases()["start"] as? [String: Any])
        let built = try JSONSerialization.jsonObject(with: CloudVoice.startMessage(turnID: UInt32(start["turn_id"] as! Int)))
        XCTAssertEqual(built as? NSDictionary, start["message"] as? NSDictionary)
    }

    func testCredentialDecision() throws {
        for item in try list("credentials") {
            let account: CloudVoiceCredential.Account
            if item["signed_in"] as? Bool == true {
                account = (item["token"] as? String).map { .token($0) } ?? .unavailable
            } else {
                account = .signedOut
            }
            let got = CloudVoiceCredential.resolve(account: account, profileBaseURL: item["profile_base_url"] as? String,
                                                   profileKey: item["profile_key"] as? String)
            XCTAssertEqual(got, item["expect"] as? String, item["name"] as? String ?? "")
        }
    }

    func testServerMessages() throws {
        for item in try list("server_messages") {
            let text: String
            if let raw = item["raw"] as? String { text = raw } else {
                text = String(decoding: try JSONSerialization.data(withJSONObject: item["json"]!), as: UTF8.self)
            }
            let expect = try XCTUnwrap(item["expect"] as? [String: Any])
            let want: CloudASRMessage
            switch expect["kind"] as? String {
            case "started": want = .started(finishTimeoutMs: expect["finish_timeout_ms"] as! Int)
            case "partial": want = .partial(text: expect["text"] as! String)
            case "final": want = .final(segmentID: expect["segment_id"] as! Int, text: expect["text"] as! String)
            case "completed": want = .completed(endReason: expect["end_reason"] as! String)
            case "cancelled": want = .cancelled
            case "error": want = .error(code: expect["code"] as! String)
            case "ignored": want = .ignored
            default: want = .invalid
            }
            XCTAssertEqual(CloudASRMessage.decode(text), want, text)
        }
    }

    func testTranscripts() throws {
        for item in try list("transcripts") {
            var transcript = CloudASRTranscript()
            for step in item["messages"] as! [String] {
                let parts = step.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                switch parts[0] {
                case "final": transcript.apply(.final(segmentID: Int(parts[1])!, text: parts[2]))
                case "partial": transcript.apply(.partial(text: parts[1]))
                case "completed": transcript.apply(.completed(endReason: parts[1]))
                case "error": transcript.apply(.error(code: parts[1]))
                case "cancelled": transcript.apply(.cancelled)
                case "close": transcript.closed()
                default: XCTFail(step)
                }
            }
            if let text = item["expect"] as? String {
                XCTAssertEqual(transcript.outcome, .text(text), "\(item)")
            } else {
                XCTAssertNotEqual(transcript.outcome, .pending, "\(item)")
                if case .text = transcript.outcome { XCTFail("no text expected: \(item)") }
            }
        }
    }

    func testSpeakableAndChunks() throws {
        for item in try list("speakable") {
            XCTAssertEqual(CloudVoiceSpeech.speakable(item["input"] as! String), item["expect"] as? String)
        }
        for item in try list("chunks") {
            let input: String
            if let spec = item["input_repeat"] as? [String: Any] {
                input = String(repeating: spec["unit"] as! String, count: spec["count"] as! Int)
            } else { input = item["input"] as! String }
            let chunks = CloudVoiceSpeech.chunks(input, max: item["max"] as! Int)
            if let lengths = item["expect_lengths"] as? [Int] {
                XCTAssertEqual(chunks.map { $0.unicodeScalars.count }, lengths)
            } else {
                XCTAssertEqual(chunks, item["expect"] as? [String])
            }
            XCTAssertEqual(chunks.joined(), input)
        }
    }

    func testFinishBeforeStartedIsHeldAndUnknownLimitsUseTheDefault() {
        XCTAssertEqual(CloudASRMessage.decode(#"{"type":"started","session_id":"s","limits":{"finish_timeout_ms":0}}"#),
                       .started(finishTimeoutMs: CloudVoice.finishTimeoutDefaultMs))
        var transcript = CloudASRTranscript()
        transcript.fail("cancelled")
        transcript.apply(.completed(endReason: "finish"))
        XCTAssertEqual(transcript.outcome, .failed("cancelled"), "a local end is final")
    }

    // MARK: - TTS over a stub

    func testTTSStreamsWholeSamplesAndSendsTheRequest() async throws {
        TTSStub.reply = (200, Data(repeating: 7, count: 7001), "audio/pcm")
        let client = CloudTTSClient(session: TTSStub.session())
        var total = 0
        for try await chunk in client.stream("你好", credential: "tok") {
            XCTAssertEqual(chunk.count % 2, 0)
            total += chunk.count
        }
        XCTAssertEqual(total, 7000)
        let request = try XCTUnwrap(TTSStub.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.url, CloudVoice.ttsURL)
        let body = try XCTUnwrap(TTSStub.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["input": "你好", "voice": "zh-female-vv", "response_format": "pcm"])
    }

    func testTTSErrorCarriesStatusAndCode() async throws {
        TTSStub.reply = (401, Data(#"{"error":{"type":"authentication_error","code":"credential_expired","message":"x","request_id":"r"}}"#.utf8), "application/json")
        let client = CloudTTSClient(session: TTSStub.session())
        do {
            for try await _ in client.stream("你好", credential: "old") {}
            XCTFail("expected an error")
        } catch let error as CloudVoiceError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.code, "credential_expired")
            XCTAssertTrue(error.isCredentialExpired)
        }
    }
}

final class TTSStub: URLProtocol {
    nonisolated(unsafe) static var reply: (Int, Data, String) = (200, Data(), "audio/pcm")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        }
        let (status, body, type) = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
