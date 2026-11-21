// SPDX-License-Identifier: MIT
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBLE

/// device-app-v1 host installer against a fake device that implements exactly §6.
/// No radio, no real device: this is not runtime conformance on hardware.
final class DeviceAppInstallerTests: XCTestCase {
    private func installer(_ device: FakeAppDevice, maxResumes: Int = 8,
                           prune: @escaping DeviceAppInstaller.PruneStaging = { _ in }) -> DeviceAppInstaller {
        DeviceAppInstaller(installID: UUID(), maxResumes: maxResumes, pruneStaging: prune, callTool: device.callTool)
    }

    private func putOffsets(_ device: FakeAppDevice) -> [(String, Int, Int)] {
        device.args("app.put").map {
            ($0["path"]?.stringValue ?? "", $0["offset"]?.intValue ?? -1,
             Data(base64Encoded: $0["data"]?.stringValue ?? "")?.count ?? -1)
        }
    }

    // MARK: - Clean install

    func testCleanInstallIsSerialChunkedAndKeysAreFresh() async throws {
        let device = FakeAppDevice()
        let bundle = makeAppBundle(mainSize: 5000)
        let result = try await installer(device).install(bundle)

        XCTAssertEqual(result.digest, bundle.digest)
        XCTAssertEqual(result.resumes, 0)
        XCTAssertFalse(result.confirmedByInfo)
        XCTAssertEqual(device.installed["clock"]?.digest, bundle.digest)
        XCTAssertEqual(device.installed["clock"]?.files["main.py"], bundle.files[0].bytes)
        XCTAssertNil(device.session)
        XCTAssertEqual(device.maxInFlight, 1, "calls are strictly serial")
        let chunks = putOffsets(device)
        // Real Passport: one Link exchange has a 3 s window; a 512 B put takes ~1.7 s, 2048 B times out.
        XCTAssertTrue(chunks.allSatisfy { $0.2 <= DeviceAppRules.transferChunkBytes && $0.2 > 0 })
        XCTAssertEqual(chunks.filter { $0.0 == "main.py" }.map(\.1), Array(stride(from: 0, to: 5000, by: 512)))
        XCTAssertEqual(device.calls("app.begin"), 1)
        XCTAssertEqual(device.calls("app.commit"), 1)
        XCTAssertEqual(device.calls("app.abort"), 0)
        let keys = device.log.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "every call has a fresh key")
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("devapp.") && $0.utf8.count <= 256 })
        XCTAssertEqual(device.log.first?.tool, "app.begin")
        XCTAssertEqual(device.log.last?.tool, "app.commit")
    }

    func testInvalidBundleSendsNothing() async throws {
        let device = FakeAppDevice()
        var bundle = makeAppBundle()
        bundle = DeviceAppBundle(name: bundle.name, files: bundle.files, digest: String(repeating: "0", count: 64))
        do { try await installer(device).install(bundle); XCTFail("must refuse") } catch let error as DeviceAppInstallError {
            guard case .invalidBundle = error else { return XCTFail("\(error)") }
        }
        let oversized = makeAppBundle(mainSize: DeviceAppRules.maxFileBytes + 1)
        do { try await installer(device).install(oversized); XCTFail("must refuse") } catch is DeviceAppInstallError {}
        XCTAssertTrue(device.log.isEmpty)
    }

    // MARK: - Lost replies and resume

    func testLostReplyOnAppliedPutResumesFromDeviceOffsetsWithoutResending() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 2, .lostReplyApplied)
        let bundle = makeAppBundle(mainSize: 5000)
        let result = try await installer(device).install(bundle)

        XCTAssertEqual(result.resumes, 1)
        XCTAssertEqual(device.calls("app.begin"), 2, "a lost staging reply is repaired by app.begin, not by repeating the put")
        let offsets = putOffsets(device).filter { $0.0 == "main.py" }.map(\.1)
        XCTAssertEqual(offsets, offsets.sorted(), "offsets only grow")
        XCTAssertEqual(Set(offsets).count, offsets.count, "the applied chunk is not sent a second time")
        XCTAssertEqual(offsets.first, 0)
        XCTAssertEqual(device.installed["clock"]?.digest, bundle.digest)
    }

    func testLostRequestOnPutIsResentFromTheDeviceOffset() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 3, .lostRequest)
        let bundle = makeAppBundle(mainSize: 5000)
        let result = try await installer(device).install(bundle)

        XCTAssertEqual(result.resumes, 1)
        let puts = putOffsets(device).filter { $0.0 == "main.py" }
        let offsets = puts.map(\.1)
        XCTAssertEqual(offsets.count - Set(offsets).count, 1, "exactly the unapplied chunk is re-sent, at the device's next offset")
        let repeated = try XCTUnwrap(offsets.firstIndex { o in offsets.filter { $0 == o }.count == 2 })
        let again = puts.indices.last { puts[$0].1 == offsets[repeated] } ?? 0
        XCTAssertLessThan(puts[again].2, puts[repeated].2, "a put that got no reply is retried with a smaller chunk")
        XCTAssertEqual(device.installed["clock"]?.files["main.py"], bundle.files[0].bytes)
    }

    func testLostBeginReplyIsRepairedByBeginAgain() async throws {
        let device = FakeAppDevice()
        device.inject("app.begin", nth: 1, .lostReplyApplied)
        let result = try await installer(device).install(makeAppBundle())
        XCTAssertEqual(result.resumes, 1)
        XCTAssertEqual(device.calls("app.begin"), 2)
        XCTAssertNotNil(device.installed["clock"])
    }

    func testDisconnectMidInstallRestartsFromTheDevicesEmptyStage() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 3, .disconnect)
        let bundle = makeAppBundle(mainSize: 5000)
        let result = try await installer(device).install(bundle)

        XCTAssertEqual(result.resumes, 1)
        let sessions = device.args("app.put").compactMap { $0["session"]?.stringValue }
        XCTAssertEqual(Set(sessions).count, 2, "the device dropped the stage, so a new session was opened")
        let restart = putOffsets(device).filter { $0.0 == "main.py" }.map(\.1)
        XCTAssertEqual(Array(restart.prefix(3)), [0, 512, 0], "the new session starts again from 0")
        XCTAssertEqual(device.installed["clock"]?.digest, bundle.digest)
    }

    func testIdleExpiryMidInstallIsRecoveredThroughBadSession() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 2, .idleExpiry)
        let result = try await installer(device).install(makeAppBundle(mainSize: 5000))
        XCTAssertEqual(result.resumes, 1)
        XCTAssertEqual(device.calls("app.begin"), 2)
        XCTAssertNotNil(device.installed["clock"])
    }

    func testInstallResumesAcrossInstallsFromTheDevicesOffsets() async throws {
        let device = FakeAppDevice()
        // The first install is cut off: the call fails, and the abort cannot reach the device either.
        device.inject("app.put", nth: 4, .throwError)   // put 1 is app.json, 2-4 are main.py chunks
        device.inject("app.abort", nth: 1, .throwError)
        let bundle = makeAppBundle(mainSize: 5000)
        do { try await installer(device).install(bundle); XCTFail("must fail") } catch let error as DeviceAppInstallError {
            guard case .callFailed(let tool, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(tool, "app.put")
        }
        XCTAssertNotNil(device.session, "the stage survives because the abort was lost")
        let staged = try XCTUnwrap(device.session?.files["main.py"]?.data.count)
        XCTAssertEqual(staged, 1024, "two 512 B chunks landed before the third put failed")

        let putsBefore = device.calls("app.put")
        let result = try await installer(device).install(bundle)
        XCTAssertEqual(result.resumes, 0)
        let resumed = putOffsets(device).dropFirst(putsBefore).filter { $0.0 == "main.py" }.map(\.1)
        XCTAssertEqual(resumed.first, 1024, "continues from the device's next offset, not from zero")
        XCTAssertEqual(resumed, resumed.sorted())
        XCTAssertEqual(device.installed["clock"]?.files["main.py"], bundle.files[0].bytes)
    }

    /// The real failure on the user's phone: a 4489 B main.py (3 puts of 2048 B) timed out because one Link
    /// exchange has a 3 s window. The installer now sends at most 512 B and halves after a put with no reply.
    func testMinesSizedBundleNeverSendsMoreThan512BytesPerPutAndShrinksAfterATimeout() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 3, .lostRequest)
        let bundle = makeAppBundle(mainSize: 4489)
        let result = try await installer(device).install(bundle)
        XCTAssertEqual(result.resumes, 1)
        let sizes = putOffsets(device).map(\.2)
        XCTAssertTrue(sizes.allSatisfy { $0 <= 512 }, "\(sizes)")
        XCTAssertTrue(sizes.contains(256), "after the lost put the chunk is halved: \(sizes)")
        XCTAssertEqual(device.installed["clock"]?.files["main.py"], bundle.files[0].bytes)
        XCTAssertGreaterThanOrEqual(DeviceAppRules.minChunkBytes, 1)
    }

    /// Real board: `app.commit` answered `no_space` with the message "out of memory" while flash was free.
    func testNoSpaceWithAnOutOfMemoryMessageIsToldApartFromAFullFlash() async throws {
        let ram = FakeAppDevice()
        ram.inject("app.commit", nth: 1, .refuse("no_space:out of memory"))
        do { try await installer(ram).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .deviceRefused(tool: "app.commit", code: "no_memory"))
        }
        let flash = FakeAppDevice()
        flash.inject("app.commit", nth: 1, .refuse("no_space:flash full"))
        do { try await installer(flash).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .deviceRefused(tool: "app.commit", code: "no_space"))
        }
    }

    func testTooManyResumesFailsAndAborts() async throws {
        let device = FakeAppDevice()
        for n in 1...6 { device.inject("app.put", nth: n, .lostRequest) }
        do { try await installer(device, maxResumes: 3).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .tooManyResumes)
        }
        XCTAssertNil(device.session)
        XCTAssertTrue(device.installed.isEmpty)
    }

    // MARK: - Replay and different bytes (device rule)

    func testDeviceAcceptsAReplayedIdenticalChunkAndRefusesDifferentBytes() async throws {
        let device = FakeAppDevice()
        let bundle = makeAppBundle(mainSize: 3000)
        let main = bundle.files[0]
        let begin = try await device.handle("app.begin", .object([
            "name": .string("clock"),
            "files": .array(bundle.files.map { .object(["path": .string($0.path), "size": .number(Double($0.bytes.count)), "sha256": .string($0.sha256)]) }),
        ]), "k1")
        guard case .completed(_, let started) = begin, let id = started["result"]?["session"]?.stringValue else { return XCTFail("begin") }
        func put(_ offset: Int, _ bytes: Data, key: String) async throws -> JSONValue {
            guard case .completed(_, let reply) = try await device.handle("app.put", .object([
                "session": .string(id), "path": .string("main.py"), "offset": .number(Double(offset)),
                "data": .string(bytes.base64EncodedString())]), key), let result = reply["result"] else { throw BLEFailure("lost") }
            return result
        }
        let first = main.bytes.subdata(in: 0..<2048)
        let appended = try await put(0, first, key: "k2")
        XCTAssertEqual(appended["next_offset"]?.intValue, 2048)
        let replayed = try await put(0, first, key: "k3")
        XCTAssertEqual(replayed["next_offset"]?.intValue, 2048, "identical replay is safe")
        var different = first; different[5] ^= 0x01
        let refused = try await put(0, different, key: "k4")
        XCTAssertEqual(refused["ok"]?.boolValue, false)
        XCTAssertEqual(refused["code"]?.stringValue, "offset_mismatch")
        XCTAssertEqual(device.session?.files["main.py"]?.data, first, "a refused write changes nothing")
    }

    func testRefusedPutFailsWithoutBlindRetryAndAborts() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 2, .refuse("offset_mismatch"))
        do { try await installer(device).install(makeAppBundle(mainSize: 5000)); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .deviceRefused(tool: "app.put", code: "offset_mismatch"))
        }
        XCTAssertEqual(device.calls("app.put"), 2, "no retry of a definitive refusal")
        XCTAssertEqual(device.calls("app.abort"), 1)
        XCTAssertNil(device.session)
        XCTAssertTrue(device.installed.isEmpty)
    }

    func testStaleStagedBytesAreCaughtByTheCommitHashCheck() async throws {
        let device = FakeAppDevice()
        let bundle = makeAppBundle(mainSize: 5000)
        // A prior install left the same bundle half staged, but a staged byte is wrong.
        device.inject("app.put", nth: 3, .throwError)
        device.inject("app.abort", nth: 1, .throwError)
        _ = try? await installer(device).install(bundle)
        device.corruptStaged(path: "main.py", at: 10)

        do { try await installer(device).install(bundle); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .deviceRefused(tool: "app.commit", code: "hash_mismatch"))
        }
        XCTAssertTrue(device.installed.isEmpty, "nothing was installed")
        XCTAssertNil(device.session, "the failed install was aborted")
    }

    // MARK: - Commit

    func testCommitOutcomeUnknownIsResolvedByInfoAndNeverResent() async throws {
        let device = FakeAppDevice()
        device.inject("app.commit", nth: 1, .lostReplyApplied)
        let bundle = makeAppBundle()
        let result = try await installer(device).install(bundle)

        XCTAssertTrue(result.confirmedByInfo)
        XCTAssertEqual(device.calls("app.commit"), 1, "a durable call is sent once")
        XCTAssertEqual(device.calls("app.info"), 1)
        XCTAssertEqual(device.calls("app.abort"), 0)
        XCTAssertEqual(device.installed["clock"]?.digest, bundle.digest)
    }

    func testCommitLostBeforeApplyIsReportedNotInstalledByDigest() async throws {
        let device = FakeAppDevice()
        device.inject("app.commit", nth: 1, .lostRequest)
        do { try await installer(device).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .commitNotInstalled)
        }
        XCTAssertEqual(device.calls("app.commit"), 1)
        XCTAssertTrue(device.installed.isEmpty)
        XCTAssertEqual(device.calls("app.abort"), 1)
        XCTAssertNil(device.session)
    }

    func testCommitCutByADisconnectIsSettledByInfoNotReportedAsATransferFailure() async throws {
        // The request may have reached the device: it is a lost reply, never a retryable failure.
        let device = FakeAppDevice()
        device.inject("app.commit", nth: 1, .throwError)
        do { try await installer(device).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .commitNotInstalled)
        }
        XCTAssertEqual(device.calls("app.commit"), 1)

        let unreadable = FakeAppDevice()
        unreadable.inject("app.commit", nth: 1, .throwError)
        for n in 1...3 { unreadable.inject("app.info", nth: n, .throwError) }
        do { try await installer(unreadable).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .commitOutcomeUnknown)
        }
        XCTAssertEqual(unreadable.calls("app.commit"), 1)
        XCTAssertEqual(unreadable.calls("app.abort"), 0)
    }

    func testCommitUnknownWithUnreadableInfoStaysUnknown() async throws {
        let device = FakeAppDevice()
        device.inject("app.commit", nth: 1, .lostReplyApplied)
        for n in 1...3 { device.inject("app.info", nth: n, .lostRequest) }
        do { try await installer(device).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .commitOutcomeUnknown)
        }
        XCTAssertEqual(device.calls("app.commit"), 1)
        XCTAssertEqual(device.calls("app.info"), 3)
        XCTAssertEqual(device.calls("app.abort"), 0, "a possibly committing session is not aborted")
    }

    func testCommitReplyWithAnotherDigestIsRefused() async throws {
        let device = FakeAppDevice()
        let bundle = makeAppBundle()
        let wrong = String(repeating: "a", count: 64)
        let tampered = DeviceAppInstaller(installID: UUID(), callTool: { name, arguments, key in
            let outcome = try await device.handle(name, arguments, key)
            guard name == "app.commit", case .completed(let id, var reply) = outcome,
                  case .object(var result)? = reply["result"] else { return outcome }
            result["digest"] = .string(wrong)
            reply = .object(["status": .string("completed"), "result": .object(result)])
            return .completed(requestID: id, reply: reply)
        })
        do { try await tampered.install(bundle); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .digestMismatch(reported: wrong))
        }
    }

    // MARK: - Abort and cancel

    func testDeviceRefusalAtBeginSendsNoAbortAndNothingElse() async throws {
        let device = FakeAppDevice()
        device.freeBytes = 10
        do { try await installer(device).install(makeAppBundle()); XCTFail("must fail") } catch {
            XCTAssertEqual(error as? DeviceAppInstallError, .deviceRefused(tool: "app.begin", code: "no_space"))
        }
        XCTAssertEqual(device.log.map(\.tool), ["app.begin"])
    }

    func testCancellationAbortsTheStage() async throws {
        let device = FakeAppDevice()
        device.inject("app.put", nth: 2, .hook { withUnsafeCurrentTask { $0?.cancel() } })
        let bundle = makeAppBundle(mainSize: 5000)
        let run = Task { try await self.installer(device).install(bundle) }
        do { try await run.value; XCTFail("must be cancelled") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(device.calls("app.abort"), 1)
        XCTAssertNil(device.session)
        XCTAssertTrue(device.installed.isEmpty)
        XCTAssertEqual(device.calls("app.commit"), 0)
    }

    // MARK: - Journal pruning

    private func tempJournal() -> LinkToolJournal {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-app-journal-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LinkToolJournal(directory: root.appendingPathComponent("ble-alert-receipts").appendingPathComponent("link-intents"))
    }

    private func intents(_ journal: LinkToolJournal) -> [LinkToolJournal.Intent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            try? JSONDecoder().decode(LinkToolJournal.Intent.self, from: Data(contentsOf: $0))
        }
    }

    func testMaximumInstallLeavesOnlyTheCommitIntentInTheJournal() async throws {
        let device = FakeAppDevice()
        let journal = tempJournal()
        let deviceID = UUID()
        // An uncertain action from before must survive any pruning.
        _ = try journal.prepare(key: "agent-light", deviceID: deviceID, name: "light.set", arguments: .object(["on": .bool(true)]))
        device.onCall = { tool, arguments, key in _ = try journal.prepare(key: key, deviceID: deviceID, name: tool, arguments: arguments) }

        let bundle = makeAppBundle(mainSize: DeviceAppRules.maxFileBytes, jsonSize: DeviceAppRules.maxFileBytes)
        device.inject("app.put", nth: 4, .lostReplyApplied)
        let run = installer(device) { _ = journal.removeStagingIntents(keys: $0) }
        let result = try await run.install(bundle)

        XCTAssertGreaterThanOrEqual(device.calls("app.put"), 12)
        XCTAssertEqual(result.resumes, 1)
        let left = intents(journal).map(\.name).sorted()
        XCTAssertEqual(left, ["app.commit", "light.set"], "staging intents are gone, the durable commit and the old action stay")
        XCTAssertLessThanOrEqual(left.count, 4)
    }

    func testFailedInstallAlsoPrunesItsStagingIntents() async throws {
        let device = FakeAppDevice()
        let journal = tempJournal()
        let deviceID = UUID()
        device.onCall = { tool, arguments, key in _ = try journal.prepare(key: key, deviceID: deviceID, name: tool, arguments: arguments) }
        device.inject("app.put", nth: 3, .refuse("no_space"))
        let run = installer(device) { _ = journal.removeStagingIntents(keys: $0) }
        do { try await run.install(makeAppBundle(mainSize: 9000)); XCTFail("must fail") } catch {}
        XCTAssertTrue(intents(journal).isEmpty, "begin, put and the abort intent are all pruned")
    }

    func testPruneOnlyRemovesStagingIntentsOfTheGivenKeys() throws {
        let journal = tempJournal()
        let deviceID = UUID()
        var keys: [String] = []
        for n in 0..<30 {   // a 60 KB transfer is 30 puts
            let key = "devapp.x.\(n)"
            keys.append(key)
            _ = try journal.prepare(key: key, deviceID: deviceID, name: "app.put",
                                    arguments: .object(["offset": .number(Double(n * 2048))]))
        }
        _ = try journal.prepare(key: "devapp.x.commit", deviceID: deviceID, name: "app.commit", arguments: .object([:]))
        _ = try journal.prepare(key: "other", deviceID: deviceID, name: "app.put", arguments: .object(["foreign": .bool(true)]))
        keys.append("devapp.x.commit")   // even if named, a durable commit is never removed
        XCTAssertEqual(journal.removeStagingIntents(keys: keys), 30)
        XCTAssertEqual(intents(journal).map(\.name).sorted(), ["app.commit", "app.put"])
        XCTAssertEqual(journal.removeStagingIntents(keys: keys), 0, "idempotent")
    }

    // MARK: - Rules against the shared golden vectors

    private var goldenRows: [JSONValue] {
        get throws {
            var url = URL(fileURLWithPath: #filePath)
            for _ in 0..<3 { url.deleteLastPathComponent() }
            let text = try String(contentsOf: url.appendingPathComponent("spec/device/v1/golden/device-app.jsonl"), encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
        }
    }

    func testEveryPutVectorRunsThroughTheFakeDevicePutRule() throws {
        let rows = try goldenRows.filter { $0["kind"]?.stringValue == "put" }
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let id = row["id"]?.stringValue ?? "?"
            let declared = try XCTUnwrap(row["declared"]?.intValue, id)
            let next = try XCTUnwrap(row["next_offset"]?.intValue, id)
            let offset = try XCTUnwrap(row["offset"]?.intValue, id)
            let length = try XCTUnwrap(row["length"]?.intValue, id)
            let same = try XCTUnwrap(row["same_bytes"]?.boolValue, id)
            let staged = Data((0..<next).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 1) })
            var bytes = Data()
            for i in offset..<offset + length {
                if i < next { bytes.append(same ? staged[i] : staged[i] ^ 0xff) } else { bytes.append(0x41) }
            }
            let device = FakeAppDevice()
            device.seedSession(path: "main.py", declared: declared, staged: staged)
            let result = device.dispatch("app.put", .object([
                "session": .string("000000aa"), "path": .string("main.py"), "offset": .number(Double(offset)),
                "data": .string(bytes.base64EncodedString())]))
            XCTAssertEqual(result["ok"]?.boolValue, row["ok"]?.boolValue, id)
            if row["ok"]?.boolValue == true {
                XCTAssertEqual(result["next_offset"]?.intValue, row["result_next"]?.intValue, id)
            } else {
                XCTAssertEqual(result["code"]?.stringValue, row["code"]?.stringValue, id)
            }
        }
    }

    func testNamePathAndDigestVectorsRunThroughTheRealRules() throws {
        for row in try goldenRows {
            let id = row["id"]?.stringValue ?? "?"
            switch row["kind"]?.stringValue {
            case "name":
                XCTAssertEqual(DeviceAppRules.isValidName(try XCTUnwrap(row["value"]?.stringValue)), row["valid"]?.boolValue, id)
            case "path":
                XCTAssertEqual(DeviceAppRules.isValidPath(try XCTUnwrap(row["value"]?.stringValue)), row["valid"]?.boolValue, id)
            case "digest":
                let files = try XCTUnwrap(row["files"]?.arrayValue).map {
                    (path: $0["path"]?.stringValue ?? "", size: $0["size"]?.intValue ?? -1, sha256: $0["sha256"]?.stringValue ?? "")
                }
                XCTAssertEqual(DeviceAppRules.manifestDigest(files), row["digest"]?.stringValue, id)
            default: break
            }
        }
    }
}
