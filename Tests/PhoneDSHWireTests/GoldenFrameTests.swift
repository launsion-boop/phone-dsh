// SPDX-License-Identifier: MIT
// Golden-vector conformance tests for PhoneDSHWire.
// The files under spec/v1/golden/frames are the interoperability
// oracle: binary payloads must round-trip byte for byte and JSON payloads must
// decode semantically and re-encode as canonical JSON byte for byte.

import Foundation
import XCTest
import PhoneDSHWire

final class GoldenFrameTests: XCTestCase {
    // MARK: - Helpers

    private func assertBinaryGolden<T: Equatable>(
        _ filename: String,
        decode: (Data) throws -> T,
        expected: ([String: Any]) throws -> T,
        encode: ([String: Any], T) throws -> Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try WireTestSupport.loadFrame(filename)
        let fields = try WireTestSupport.fields(fixture)
        let value = try expected(fields)
        let expectedPayload = try WireTestSupport.payloadHex(fixture)
        XCTAssertEqual(WireTestSupport.hex(try encode(fields, value)), expectedPayload,
                       filename, file: file, line: line)
        let decoded = try decode(try WireTestSupport.payloadData(fixture))
        XCTAssertEqual(decoded, value, filename, file: file, line: line)
        try WireTestSupport.assertFrame(fixture, file: file, line: line)
    }

    private func assertJSONGolden(
        _ filename: String,
        reencode: (Data) throws -> Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try WireTestSupport.loadFrame(filename)
        let payload = try WireTestSupport.payloadData(fixture)
        let decodedObject = try JSONSerialization.jsonObject(with: payload)
        let expectedObject = try WireTestSupport.fields(fixture) as NSDictionary
        XCTAssertTrue(expectedObject.isEqual(decodedObject), filename, file: file, line: line)
        XCTAssertEqual(try CanonicalJSON.canonicalize(payload), payload,
                       "\(filename) payload is not canonical", file: file, line: line)
        XCTAssertEqual(try reencode(payload), payload, filename, file: file, line: line)
        try WireTestSupport.assertFrame(fixture, file: file, line: line)
    }

    private func assertMutationGolden(_ filename: String) throws {
        try assertBinaryGolden(
            filename,
            decode: { try VfsMutationPayload.decode($0).body },
            expected: { try WireTestSupport.mutationBody($0) },
            encode: { fields, body in
                let mseq = try WireTestSupport.uint64(fields["mseq"], "mseq")
                return try VfsMutationPayload.encode(mseq: mseq, body: body)
            })
    }

    // MARK: - HELLO

    func testGoldenHelloHost() throws {
        try assertJSONGolden("hello-host-1.json") { data in
            let hello = try JSONDecoder().decode(HelloPayload.self, from: data)
            XCTAssertEqual(hello.role, .host)
            XCTAssertEqual(hello.nextMseq, 42)
            XCTAssertEqual(hello.ackedMseq, 41)
            XCTAssertEqual(hello.durableMseq, 40)
            XCTAssertNil(hello.lastMseq)
            XCTAssertEqual(hello.fence, Fence(owner: "phone", generation: 3, walSeq: 41))
            return try CanonicalJSON.encode(hello)
        }
    }

    func testGoldenHelloWorker() throws {
        try assertJSONGolden("hello-worker-1.json") { data in
            let hello = try JSONDecoder().decode(HelloPayload.self, from: data)
            XCTAssertEqual(hello.role, .worker)
            XCTAssertEqual(hello.lastMseq, 41)
            XCTAssertNil(hello.nextMseq)
            XCTAssertNil(hello.ackedMseq)
            XCTAssertNil(hello.durableMseq)
            return try CanonicalJSON.encode(hello)
        }
    }

    // MARK: - VFS binary frames

    func testGoldenVFSMutationWrite() throws {
        try assertMutationGolden("vfs-mut-write-1.json")
    }

    func testGoldenVFSMutationAppend() throws {
        try assertMutationGolden("vfs-mut-append-1.json")
    }

    func testGoldenVFSMutationMkdir() throws {
        try assertMutationGolden("vfs-mut-mkdir-1.json")
    }

    func testGoldenVFSMutationRemove() throws {
        try assertMutationGolden("vfs-mut-remove-1.json")
    }

    func testGoldenVFSMutationChmod() throws {
        try assertMutationGolden("vfs-mut-chmod-1.json")
    }

    func testGoldenVFSMutationBinary() throws {
        try assertMutationGolden("vfs-mut-binary-1.json")
    }

    func testGoldenVFSAckLevel1() throws {
        try assertBinaryGolden(
            "vfs-ack-1.json",
            decode: { try VfsAckBody.decode($0) },
            expected: { fields in
                VfsAckBody(level: try WireTestSupport.ackLevel(fields["level"], "level"),
                           uptoMseq: try WireTestSupport.uint64(fields["upto_mseq"], "upto_mseq"))
            },
            encode: { _, body in body.encoded() })
    }

    func testGoldenVFSAckLevel2() throws {
        try assertBinaryGolden(
            "vfs-ack-2.json",
            decode: { try VfsAckBody.decode($0) },
            expected: { fields in
                VfsAckBody(level: try WireTestSupport.ackLevel(fields["level"], "level"),
                           uptoMseq: try WireTestSupport.uint64(fields["upto_mseq"], "upto_mseq"))
            },
            encode: { _, body in body.encoded() })
    }

    func testGoldenVFSBarrier() throws {
        try assertBinaryGolden(
            "vfs-barrier-1.json",
            decode: { try VfsBarrierBody.decode($0) },
            expected: { fields in
                VfsBarrierBody(wantLevel: try WireTestSupport.ackLevel(fields["want_level"], "want_level"),
                               uptoMseq: try WireTestSupport.uint64(fields["upto_mseq"], "upto_mseq"))
            },
            encode: { _, body in body.encoded() })
    }

    func testGoldenVFSResync() throws {
        try assertBinaryGolden(
            "vfs-resync-1.json",
            decode: { try VfsResyncBody.decode($0) },
            expected: { fields in VfsResyncBody(path: try WireTestSupport.string(fields, "path")) },
            encode: { _, body in try body.encoded() })
    }

    // MARK: - Journal frames

    func testGoldenJournal() throws {
        try assertBinaryGolden(
            "journal-1.json",
            decode: { try JournalBody.decode($0) },
            expected: { fields in
                JournalBody(jseq: try WireTestSupport.uint64(fields["jseq"], "jseq"),
                            sessionID: try WireTestSupport.string(fields, "session_id"),
                            record: try WireTestSupport.data(hex: try WireTestSupport.string(fields, "record_hex")))
            },
            encode: { _, body in try body.encoded() })
    }

    func testGoldenJournalAck() throws {
        try assertBinaryGolden(
            "journal-ack-1.json",
            decode: { try JournalAckBody.decode($0) },
            expected: { fields in
                JournalAckBody(level: try WireTestSupport.ackLevel(fields["level"], "level"),
                               sessionID: try WireTestSupport.string(fields, "session_id"),
                               uptoJseq: try WireTestSupport.uint64(fields["upto_jseq"], "upto_jseq"))
            },
            encode: { _, body in try body.encoded() })
    }

    // MARK: - Remote API frames

    func testGoldenAPIRequest() throws {
        try assertBinaryGolden(
            "api-req-1.json",
            decode: { try ApiRequestFrame.decode($0) },
            expected: { fields in
                ApiRequestFrame(
                    reqID: try WireTestSupport.uint32(fields["req_id"], "req_id"),
                    head: try WireTestSupport.apiRequestHead(fields["head"]),
                    body: try WireTestSupport.data(hex: try WireTestSupport.string(fields, "body_hex")))
            },
            encode: { _, frame in try frame.encoded() })
    }

    func testGoldenAPIResponse() throws {
        try assertBinaryGolden(
            "api-res-1.json",
            decode: { try ApiResponseFrame.decode($0) },
            expected: { fields in
                ApiResponseFrame(
                    reqID: try WireTestSupport.uint32(fields["req_id"], "req_id"),
                    head: try WireTestSupport.apiResponseHead(fields["head"]),
                    body: try WireTestSupport.data(hex: try WireTestSupport.string(fields, "body_hex")))
            },
            encode: { _, frame in try frame.encoded() })
    }

    func testGoldenAPIResponseContinuation() throws {
        try assertBinaryGolden(
            "api-res-continuation-1.json",
            decode: { try ApiResponseFrame.decode($0) },
            expected: { fields in
                ApiResponseFrame(
                    reqID: try WireTestSupport.uint32(fields["req_id"], "req_id"),
                    head: nil,
                    body: try WireTestSupport.data(hex: try WireTestSupport.string(fields, "body_hex")))
            },
            encode: { _, frame in
                XCTAssertNil(frame.head)
                return try frame.encoded()
            })
    }

    func testGoldenAPIResponseEmptyBody() throws {
        try assertBinaryGolden(
            "api-res-empty-body-1.json",
            decode: { try ApiResponseFrame.decode($0) },
            expected: { fields in
                ApiResponseFrame(
                    reqID: try WireTestSupport.uint32(fields["req_id"], "req_id"),
                    head: try WireTestSupport.apiResponseHead(fields["head"]),
                    body: Data())
            },
            encode: { _, frame in try frame.encoded() })
    }

    func testGoldenAPIEnd() throws {
        try assertBinaryGolden(
            "api-end-1.json",
            decode: { try ApiEndFrame.decode($0) },
            expected: { fields in
                ApiEndFrame(reqID: try WireTestSupport.uint32(fields["req_id"], "req_id"))
            },
            encode: { _, frame in frame.encoded() })
    }

    func testGoldenAPIAbort() throws {
        try assertBinaryGolden(
            "api-abort-1.json",
            decode: { try ApiAbortFrame.decode($0) },
            expected: { fields in
                ApiAbortFrame(reqID: try WireTestSupport.uint32(fields["req_id"], "req_id"),
                              reason: try WireTestSupport.string(fields, "reason"))
            },
            encode: { _, frame in try frame.encoded() })
    }

    // MARK: - Exec frames

    func testGoldenExecRequest() throws {
        try assertJSONGolden("exec-req-1.json") { data in
            let request = try ExecRequestPayload.decode(data)
            XCTAssertEqual(request.requiresMseq, 47)
            XCTAssertEqual(request.idemKey,
                           "2d3562b36e18c2441bd7bb4ed95c67bd72a86983387bd7f04f6d1ef1668cc81a")
            let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            XCTAssertEqual(body?["exec_id"] as? String, "xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0-0")
            XCTAssertNil(body?["requires_mseq"])
            XCTAssertNil(body?["idem_key"])
            let decoded = try JSONDecoder().decode(ExecRequestPayload.self, from: data)
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(try CanonicalJSON.encode(decoded), data)
            return try request.encodedPayload()
        }
    }

    func testGoldenExecEventExit() throws {
        try assertJSONGolden("exec-evt-1.json") { data in
            let event = try ExecEventPayload.decode(data)
            XCTAssertEqual(try CanonicalJSON.canonicalize(event.json), event.json)
            return event.encodedPayload()
        }
    }

    func testGoldenExecEventOutput() throws {
        try assertJSONGolden("exec-evt-2.json") { data in
            try ExecEventPayload.decode(data).encodedPayload()
        }
    }

    func testGoldenExecControlCancel() throws {
        try assertJSONGolden("exec-ctl-1.json") { data in
            let control = try JSONDecoder().decode(ExecControlPayload.self, from: data)
            XCTAssertEqual(control.op, .cancel)
            XCTAssertNil(control.data)
            return try CanonicalJSON.encode(control)
        }
    }

    func testGoldenExecControlStdin() throws {
        try assertJSONGolden("exec-ctl-2.json") { data in
            let control = try JSONDecoder().decode(ExecControlPayload.self, from: data)
            XCTAssertEqual(control.op, .stdin)
            XCTAssertEqual(control.data, "aGVsbG8K")
            return try CanonicalJSON.encode(control)
        }
    }

    // MARK: - Control JSON frames

    func testGoldenLifecycle() throws {
        try assertJSONGolden("lifecycle-1.json") { data in
            let lifecycle = try JSONDecoder().decode(LifecyclePayload.self, from: data)
            XCTAssertEqual(lifecycle.state, .run)
            XCTAssertEqual(lifecycle.budget, 120_000)
            XCTAssertEqual(lifecycle.admission, .open)
            return try CanonicalJSON.encode(lifecycle)
        }
    }

    func testGoldenConsoleReady() throws {
        try assertJSONGolden("console-1.json") { data in
            let console = try JSONDecoder().decode(ConsolePayload.self, from: data)
            XCTAssertEqual(console.text, "XL_DSH_READY")
            return try CanonicalJSON.encode(console)
        }
    }

    func testGoldenConsoleUTF8() throws {
        try assertJSONGolden("console-2.json") { data in
            let console = try JSONDecoder().decode(ConsolePayload.self, from: data)
            XCTAssertEqual(console.text, "ready \u{2713}")
            return try CanonicalJSON.encode(console)
        }
    }

    func testGoldenFence() throws {
        try assertJSONGolden("fence-1.json") { data in
            let fence = try JSONDecoder().decode(FencePayload.self, from: data)
            XCTAssertEqual(fence.admission, .closed)
            XCTAssertEqual(fence.fence.generation, 4)
            return try CanonicalJSON.encode(fence)
        }
    }

    func testGoldenError() throws {
        try assertJSONGolden("error-1.json") { data in
            let error = try JSONDecoder().decode(ErrorPayload.self, from: data)
            XCTAssertEqual(error.code, .badSeq)
            XCTAssertEqual(error.refSeq, 18)
            return try CanonicalJSON.encode(error)
        }
    }

    func testGoldenErrorVFSRefused() throws {
        try assertJSONGolden("error-2.json") { data in
            let error = try JSONDecoder().decode(ErrorPayload.self, from: data)
            XCTAssertEqual(error.code, .vfsRefused)
            XCTAssertNil(error.refSeq)
            XCTAssertEqual(error.path, "/dsh/workspace/a")
            XCTAssertEqual(error.limit, 15 * 1024 * 1024)
            XCTAssertEqual(error.reason, .fileTooLarge)
            XCTAssertEqual(error.isVFSRefused, true)
            return try CanonicalJSON.encode(error)
        }
    }

    func testGoldenHostVFSRefused() throws {
        // The host answers a VFS_MUT it refuses on resource grounds with the
        // same non-closing diagnostic; ref_seq names the refused VFS_MUT and
        // the structured mseq/accepted_bytes members name the refused mutation.
        try assertJSONGolden("error-3.json") { data in
            let error = try JSONDecoder().decode(ErrorPayload.self, from: data)
            XCTAssertEqual(error.code, .vfsRefused)
            XCTAssertEqual(error.refSeq, 4)
            XCTAssertEqual(error.path, "/dsh/workspace/big.bin")
            XCTAssertEqual(error.limit, 64 * 1024 * 1024)
            XCTAssertEqual(error.reason, .fileTooLarge)
            XCTAssertEqual(error.mseq, 5)
            XCTAssertEqual(error.acceptedBytes, 0)
            XCTAssertTrue(error.message.contains("mseq 5"))
            XCTAssertTrue(error.message.contains("0 accepted bytes"))
            return try CanonicalJSON.encode(error)
        }
    }

    // MARK: - Whole-set assertions

    func testEveryFrameTypeHasGolden() throws {
        let files = try WireTestSupport.frameFiles()
        XCTAssertGreaterThanOrEqual(files.count, FrameType.allCases.count)
        var covered: Set<FrameType> = []
        for file in files {
            let fixture = try WireTestSupport.loadFrame(file)
            covered.insert(try WireTestSupport.frameType(fixture))
        }
        XCTAssertEqual(covered, Set(FrameType.allCases), "a frame type has no golden vector")
    }

    func testEveryGoldenFrameHeaderAndPayload() throws {
        for file in try WireTestSupport.frameFiles() {
            let fixture = try WireTestSupport.loadFrame(file)
            try WireTestSupport.assertFrame(fixture)
            let frameHex = try WireTestSupport.frameHex(fixture)
            let payloadHex = try WireTestSupport.payloadHex(fixture)
            XCTAssertEqual(frameHex.count, 32 + payloadHex.count, file)
            XCTAssertEqual(String(frameHex.prefix(4)), "5a4c", file)
        }
    }

    func testGoldenVFSMutationsCoverAllOps() throws {
        var ops: Set<VfsOp> = []
        for file in try WireTestSupport.frameFiles() where file.hasPrefix("vfs-mut-") {
            let fields = try WireTestSupport.fields(try WireTestSupport.loadFrame(file))
            let raw = try WireTestSupport.uint8(fields["op"], "op")
            ops.insert(try XCTUnwrap(VfsOp(rawValue: raw)))
        }
        XCTAssertEqual(ops, Set(VfsOp.allCases))
    }

    func testJSONGoldensAreCanonicalAndStable() throws {
        for file in try WireTestSupport.frameFiles() {
            let fixture = try WireTestSupport.loadFrame(file)
            guard try WireTestSupport.frameType(fixture).carriesJSONPayload else { continue }
            let payload = try WireTestSupport.payloadData(fixture)
            XCTAssertEqual(try CanonicalJSON.canonicalize(payload), payload, file)
        }
    }

    func testBinaryGoldensHaveNoJSONTypes() throws {
        for file in try WireTestSupport.frameFiles() {
            let fixture = try WireTestSupport.loadFrame(file)
            let type = try WireTestSupport.frameType(fixture)
            if type.carriesJSONPayload {
                XCTAssertNotNil(try JSONSerialization.jsonObject(with: try WireTestSupport.payloadData(fixture)), file)
            } else {
                XCTAssertEqual(try WireTestSupport.payloadHex(fixture).count,
                               (try WireTestSupport.payloadData(fixture)).count * 2, file)
            }
        }
    }
}
