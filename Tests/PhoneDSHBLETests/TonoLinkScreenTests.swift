// SPDX-License-Identifier: MIT
import XCTest
@testable import PhoneDSHBLE

final class TonoLinkScreenTests: XCTestCase {
    private func record(_ kind: UInt8, codec: UInt8 = 1, key: UInt8 = 0, _ payload: [UInt8]) -> Data {
        let n = payload.count
        return Data([65, 80, 86, 49, kind, codec, key, 0, UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)] + payload)
    }

    func testParserSplitsRecordsAcrossReads() throws {
        var parser = APV1Parser()
        let stream = record(1, [0, 0, 0, 1, 0x67, 1]) + record(2, key: 1, [0, 0, 0, 1, 0x65, 0x88]) + record(3, [])
        var out: [APV1Record] = []
        for chunk in stride(from: 0, to: stream.count, by: 5) {
            out += try parser.receive(stream.subdata(in: chunk..<min(chunk + 5, stream.count)))
        }
        XCTAssertEqual(out.map(\.kind), [.configuration, .video, .reset])
        XCTAssertTrue(out[1].keyframe)
        XCTAssertEqual(out[1].payload, Data([0, 0, 0, 1, 0x65, 0x88]))
    }

    func testParserRejectsGarbage() {
        var parser = APV1Parser()
        XCTAssertThrowsError(try parser.receive(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)))
    }

    func testAccessUnitsSplitAtFirstSlice() throws {
        // SPS, PPS, IDR slice (first_mb=0), P slice (first_mb=0) → two pictures.
        let stream = Data([0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 1, 0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x41, 0x9a])
        let units = try APV1NAL.accessUnits(APV1NAL.split(stream), codec: .h264)
        XCTAssertEqual(units.count, 2)
        XCTAssertTrue(try APV1NAL.isKeyframe(units[0], codec: .h264))
        XCTAssertFalse(try APV1NAL.isKeyframe(units[1], codec: .h264))
    }

    func testGlideTapEndsWithPressAndReleaseAtTarget() {
        let steps = TonoLinkPhoneHands.glideSteps(1000, 0, holdMs: 120)
        let moves = steps.filter { $0["op"] as? String == "absolute" }
        XCTAssertEqual(moves.first?["x"] as? Int, 16384)                    // starts from the centre
        XCTAssertEqual(moves.suffix(2).map { $0["buttons"] as? Int }, [1, 0])
        XCTAssertEqual(moves.last?["x"] as? Int, 32767)
        XCTAssertEqual(moves.last?["y"] as? Int, 0)
    }
}

final class TonoLinkSwipeTests: XCTestCase {
    func testSwipePressesAbsoluteMovesRelativeReleasesAtEnd() {
        let steps = TonoLinkPhoneHands.swipeSteps(from: TonoLinkPoint(500, 874), to: TonoLinkPoint(500, 437), ms: 400)
        let ops = steps.compactMap { $0["op"] as? String }
        let press = steps.firstIndex { $0["op"] as? String == "absolute" && $0["buttons"] as? Int == 1 }!
        XCTAssertTrue(steps[press...].contains { $0["op"] as? String == "move" })
        XCTAssertEqual(steps.last?["buttons"] as? Int, 0)
        XCTAssertEqual(steps.last?["y"] as? Int, Int((437.0 * 32767 / 1000).rounded()))
        let dy = steps.filter { $0["op"] as? String == "move" }.reduce(0) { $0 + ($1["dy"] as! Int) }
        XCTAssertEqual(dy, Int((-437 * 0.932).rounded()))
        XCTAssertFalse(ops.contains("swipe"))
    }
}

final class TonoLinkTypingTests: XCTestCase {
    func testChineseBecomesPinyinWordsBetweenASCIIRuns() {
        XCTAssertEqual(TonoLinkPhoneHands.typingSegments("kafei"), [.ascii("kafei")])
        XCTAssertEqual(TonoLinkPhoneHands.typingSegments("咖啡"), [.pinyin(["kafei"])])
        let mixed = TonoLinkPhoneHands.typingSegments("iPhone 咖啡店")
        XCTAssertEqual(mixed.first, .ascii("iPhone "))
        guard case .pinyin(let words) = mixed.last else { return XCTFail("\(mixed)") }
        XCTAssertEqual(words.joined(), "kafeidian")
    }
}
