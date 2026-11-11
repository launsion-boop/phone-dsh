// SPDX-License-Identifier: MIT
// W7 (§12/§13): the response-log key recipe is frozen, so every hash
// implementation must produce byte-identical keys, and buffered writes must
// preserve the exact body bytes and their order.

import Foundation
import XCTest
@testable import PhoneDSHGateway

final class ResponseLogKeyGoldenTests: XCTestCase {
    // The shared oracle: spec/v1/golden/plan/response-log-key.json.
    func testFrozenKeyVectorsMatchTheRecipe() {
        let cases: [(String, String, [String: String], Set<String>, Data, String)] = [
            ("POST",
             "https://api.example.com/v1/chat/completions",
             ["Content-Type": " application/json ", "X-Request-Id": " req-1 ",
              "Authorization": "Bearer secret"],
             ["content-type", "x-request-id"],
             Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#.utf8),
             "22a064a9434a3ee2baa6abb121b54d316408f4995cec87f588cd88472824400a"),
            ("GET",
             "https://example.com/a?b=1#frag",
             [:],
             [],
             Data(),
             "ef08d91e3c103d7a239c5013c14c7f3b86b7adccd1f4bb1954e4767e6ea79091"),
            ("DELETE",
             "https://example.com/x",
             ["X-Trace": " abc "],
             ["x-trace"],
             Data("not json".utf8),
             "5148db24ba50956cc300a80d7f2bcd3494f5718bd7d499367e7b3f5bba9d6154"),
        ]
        for (method, rawURL, headers, allowList, body, expected) in cases {
            let url = URL(string: rawURL)!
            let actual = ResponseLog.cacheKey(method: method, url: url, headers: headers,
                                              body: body, headerAllowList: allowList)
            XCTAssertEqual(actual, expected, "the frozen key vector drifted for \(method) \(rawURL)")
        }
    }

    /// The crypto-backed path and the original scalar implementation are the
    /// same function. A difference here is a contract violation (§12), not a
    /// tolerable optimisation.
    func testPlatformDigestIsBitIdenticalToTheScalarOracle() {
        for length in [0, 1, 2, 3, 55, 56, 63, 64, 65, 127, 128, 129, 1000, 65_537] {
            let data = deterministicBytes(count: length)
            XCTAssertEqual(GatewaySHA256.digest(data), GatewaySHA256.scalarDigest(data),
                           "digest differs at length \(length)")
        }
    }

    func testPartWiseHashEqualsOneShotHash() {
        let body = deterministicBytes(count: 4096)
        XCTAssertEqual(GatewaySHA256.hexDigest(parts: [Data("POST\n".utf8), body]),
                       GatewaySHA256.hexDigest(Data("POST\n".utf8) + body))
        XCTAssertEqual(GatewaySHA256.hexDigest(parts: []),
                       GatewaySHA256.hexDigest(Data()))
    }

    func testAccumulatorPreservesOrderAndFlushesAtTheBound() {
        var accumulator = ResponseLogAccumulator(flushBytes: 8)
        XCTAssertNil(accumulator.append(Data("abc".utf8)))
        XCTAssertEqual(accumulator.bufferedBytes, 3)
        XCTAssertEqual(accumulator.append(Data("def".utf8)),
                       ResponseLogBatch(sequence: 0, body: Data("abcdef".utf8)))
        XCTAssertEqual(accumulator.bufferedBytes, 0)
        XCTAssertNil(accumulator.append(Data()))
        XCTAssertEqual(accumulator.append(Data("ghi".utf8)),
                       ResponseLogBatch(sequence: 1, body: Data("ghi".utf8)))

        var tail = ResponseLogAccumulator(flushBytes: 8)
        XCTAssertNil(tail.append(Data("12".utf8)))
        XCTAssertNil(tail.append(Data("34".utf8)))
        XCTAssertEqual(tail.flush(), ResponseLogBatch(sequence: 0, body: Data("1234".utf8)))
        XCTAssertNil(tail.flush())
    }

    private func deterministicBytes(count: Int) -> Data {
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return Data(bytes)
    }
}
