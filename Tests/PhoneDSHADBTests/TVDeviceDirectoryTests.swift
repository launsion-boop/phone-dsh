// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHADB

/// Covers the persisted device document behind ``TVDeviceDirectory``: the
/// eight-entry cap and its eviction order, serial upsert, endpoint cleanup on
/// `forget`, tolerance for a corrupt document and the newest-first ordering
/// contract every reader of `records()` relies on.
///
/// Every case builds its own `UserDefaults` suite and removes it in teardown, so
/// nothing here reads or writes `.standard`.
final class TVDeviceDirectoryTests: XCTestCase {
    /// Fixed time origin so expectations are exact and independent of "now".
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// The persisted keys are private to the class, but a corrupt-document case
    /// has to write the exact key the loader reads. `TVConnectorTests` asserts
    /// the same literals; the corrupt test first proves the key is live.
    private static let devicesKey = "phone-dsh.tv-discovery.devices.v1"
    private static let lastEndpointKey = "phone-dsh.tv-discovery.last-endpoint.v1"

    // MARK: - Helpers

    /// A per-test directory over a unique `UserDefaults` suite. The suite is
    /// removed when the test ends even if an assertion fails, so no case can
    /// observe another's records.
    private func makeDirectory() throws -> (directory: TVDeviceDirectory, defaults: UserDefaults) {
        let suite = "tv-directory-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite), "suite \(suite) must be available")
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return (TVDeviceDirectory(defaults: defaults), defaults)
    }

    /// A record whose position in the persisted order is `offset` seconds after
    /// the fixed epoch, so "newer" and "older" are explicit in every call.
    private func record(serial: String, offset: TimeInterval,
                        host: String = "192.0.2.10", port: UInt16 = 5555,
                        model: String = "Android TV") -> TVDeviceRecord {
        TVDeviceRecord(serial: serial, model: model, host: host, port: port, mac: nil,
                       lastSeen: Self.epoch.addingTimeInterval(offset))
    }

    // MARK: - Capacity and eviction

    /// Requirement 1: writing ten distinct serials keeps exactly the eight most
    /// recent records; the two oldest are the ones evicted.
    func testRememberKeepsOnlyTheEightNewestRecords() throws {
        let (directory, _) = try makeDirectory()

        for index in 1...10 {
            directory.remember(record(serial: "serial-\(index)", offset: TimeInterval(index)))
        }

        let records = directory.records()
        XCTAssertEqual(records.count, 8, "the cap is eight records")
        XCTAssertEqual(records.map(\.serial), (3...10).reversed().map { "serial-\($0)" },
                       "the eight survivors are the newest, newest first")
        XCTAssertEqual(Set(records.map(\.serial)).count, 8, "no serial is duplicated")
        XCTAssertFalse(records.contains { $0.serial == "serial-1" }, "the oldest record is evicted")
        XCTAssertFalse(records.contains { $0.serial == "serial-2" }, "the second oldest is evicted")
    }

    // MARK: - Upsert

    /// Requirement 2: remembering an existing serial replaces the record in
    /// place of a second entry, adopts the new fields and moves to the front
    /// because its `lastSeen` is now the newest.
    func testRememberUpsertsBySerialAndMovesItToTheFront() throws {
        let (directory, _) = try makeDirectory()
        directory.remember(record(serial: "a", offset: 1, host: "192.0.2.1", port: 5555, model: "Old"))
        directory.remember(record(serial: "b", offset: 2, host: "192.0.2.2", port: 5556, model: "B"))
        directory.remember(record(serial: "c", offset: 3, host: "192.0.2.3", port: 5557, model: "C"))
        XCTAssertEqual(directory.records().map(\.serial), ["c", "b", "a"])

        directory.remember(record(serial: "a", offset: 4, host: "192.0.2.9", port: 6000, model: "Renamed"))

        let records = directory.records()
        XCTAssertEqual(records.count, 3, "an upsert replaces, it does not append")
        XCTAssertEqual(records.filter { $0.serial == "a" }.count, 1, "exactly one entry per serial")
        XCTAssertEqual(records.map(\.serial), ["a", "c", "b"],
                       "the refreshed record moved ahead of the untouched ones")

        let updated = try XCTUnwrap(records.first)
        XCTAssertEqual(updated.serial, "a")
        XCTAssertEqual(updated.host, "192.0.2.9")
        XCTAssertEqual(updated.port, 6000)
        XCTAssertEqual(updated.model, "Renamed")
        XCTAssertEqual(updated.lastSeen.timeIntervalSince1970,
                       Self.epoch.addingTimeInterval(4).timeIntervalSince1970, accuracy: 0.001,
                       "the replacement keeps its new lastSeen")
        XCTAssertEqual(records.last?.serial, "b", "the other records keep their order")
    }

    /// A refresh at full capacity must not evict a still-newer record: the
    /// directory stays at eight and the refreshed serial joins the survivors.
    func testUpsertAtCapacityKeepsExactlyEightRecords() throws {
        let (directory, _) = try makeDirectory()
        for index in 1...9 {
            directory.remember(record(serial: "serial-\(index)", offset: TimeInterval(index)))
        }
        XCTAssertEqual(directory.records().map(\.serial), (2...9).reversed().map { "serial-\($0)" })

        // serial-2 is the oldest survivor; refreshing it should move it to the
        // front without pushing any of the other seven out.
        directory.remember(record(serial: "serial-2", offset: 10, host: "198.51.100.2", port: 7000))

        let records = directory.records()
        XCTAssertEqual(records.count, 8)
        XCTAssertEqual(records.map(\.serial), ["serial-2"] + (3...9).reversed().map { "serial-\($0)" })
        XCTAssertEqual(records.first?.host, "198.51.100.2")
        XCTAssertFalse(records.contains { $0.serial == "serial-1" }, "an upsert does not resurrect evicted records")
    }

    // MARK: - Forget

    /// Requirement 3a: `forget` removes the record and clears the endpoint when
    /// it pointed at the forgotten device, including in the persisted document.
    func testForgetRemovesRecordAndClearsEndpointPointingAtIt() throws {
        let (directory, defaults) = try makeDirectory()
        directory.remember(record(serial: "a", offset: 1, host: "192.0.2.10", port: 5555))
        directory.remember(record(serial: "b", offset: 2, host: "192.0.2.20", port: 5556))
        XCTAssertEqual(directory.lastEndpoint()?.host, "192.0.2.20")
        XCTAssertEqual(directory.lastEndpoint()?.port, 5556)

        directory.forget(serial: "b")

        XCTAssertEqual(directory.records().map(\.serial), ["a"], "only the forgotten record is removed")
        XCTAssertNil(directory.lastEndpoint(), "the endpoint of a forgotten device must not auto-connect")

        // The cleared state is on disk, not just in memory: a fresh instance over
        // the same suite must agree.
        let reloaded = TVDeviceDirectory(defaults: defaults)
        XCTAssertEqual(reloaded.records().map(\.serial), ["a"])
        XCTAssertNil(reloaded.lastEndpoint())
    }

    /// Requirement 3b: forgetting a different device — even one sharing the
    /// endpoint's host but with another port — leaves the endpoint intact.
    func testForgetKeepsEndpointPointingAtAnotherDevice() throws {
        let (directory, _) = try makeDirectory()
        directory.remember(record(serial: "a", offset: 1, host: "192.0.2.10", port: 5555))
        directory.remember(record(serial: "b", offset: 2, host: "192.0.2.20", port: 5556))
        XCTAssertEqual(directory.lastEndpoint()?.host, "192.0.2.20")

        directory.forget(serial: "a")

        XCTAssertEqual(directory.records().map(\.serial), ["b"])
        XCTAssertEqual(directory.lastEndpoint()?.host, "192.0.2.20")
        XCTAssertEqual(directory.lastEndpoint()?.port, 5556, "forgetting someone else must not clear the endpoint")

        // Endpoint identity is host *and* port: removing a record that shares
        // the host but not the port of the remembered endpoint is unrelated.
        directory.remember(record(serial: "c", offset: 3, host: "198.51.100.30", port: 5557))
        directory.remember(record(serial: "d", offset: 4, host: "198.51.100.30", port: 5558))
        XCTAssertEqual(directory.lastEndpoint()?.port, 5558)

        directory.forget(serial: "c")

        XCTAssertEqual(directory.records().map(\.serial), ["d", "b"])
        XCTAssertEqual(directory.lastEndpoint()?.host, "198.51.100.30")
        XCTAssertEqual(directory.lastEndpoint()?.port, 5558, "a same-host, other-port record is not the endpoint")
    }

    /// Forgetting an unknown serial is a no-op for both the list and the
    /// endpoint; this pins the early return in `forget`.
    func testForgetUnknownSerialChangesNothing() throws {
        let (directory, _) = try makeDirectory()
        directory.remember(record(serial: "a", offset: 1, host: "192.0.2.10", port: 5555))

        directory.forget(serial: "missing")

        XCTAssertEqual(directory.records().map(\.serial), ["a"])
        XCTAssertEqual(directory.lastEndpoint()?.host, "192.0.2.10")
        XCTAssertEqual(directory.lastEndpoint()?.port, 5555)
    }

    // MARK: - Corrupt storage

    /// Requirement 4: an unreadable document behaves like an empty directory;
    /// `records()` returns `[]` instead of trapping, and a later `remember`
    /// rewrites a valid document over the corrupt bytes.
    func testRecordsReturnsEmptyArrayForCorruptDocument() throws {
        let (directory, defaults) = try makeDirectory()
        XCTAssertEqual(directory.records(), [], "an empty suite has no records")

        // Prove the literal key below is the one `remember` writes before the
        // corruption overwrites it; otherwise the next assertion could pass
        // against a key nobody reads.
        directory.remember(record(serial: "a", offset: 1))
        XCTAssertNotNil(defaults.data(forKey: Self.devicesKey), "the devices document uses this key")

        defaults.set(Data("this is not json".utf8), forKey: Self.devicesKey)
        XCTAssertEqual(directory.records(), [], "corrupt JSON must not crash or leak partial records")

        // Decodable-but-wrong-shape payloads take the same tolerant path.
        defaults.set(Data(#"{"serial":"a"}"#.utf8), forKey: Self.devicesKey)
        XCTAssertEqual(directory.records(), [])

        // The next successful write replaces the corrupt document wholesale.
        directory.remember(record(serial: "fresh", offset: 2))
        XCTAssertEqual(directory.records().map(\.serial), ["fresh"])
        XCTAssertNotNil(defaults.data(forKey: Self.devicesKey))
    }

    // MARK: - Ordering

    /// Requirement 5: `records()` is strictly descending by `lastSeen`
    /// regardless of the order the records were written in.
    func testRecordsAreStrictlyNewestFirst() throws {
        let (directory, _) = try makeDirectory()
        for offset in [TimeInterval(5), 1, 9, 3, 7, 2] {
            directory.remember(record(serial: "serial-\(Int(offset))", offset: offset))
        }

        let records = directory.records()
        XCTAssertEqual(records.map(\.serial),
                       ["serial-9", "serial-7", "serial-5", "serial-3", "serial-2", "serial-1"])
        for (newer, older) in zip(records, records.dropFirst()) {
            XCTAssertGreaterThan(newer.lastSeen, older.lastSeen,
                                 "\(newer.serial) must be strictly newer than \(older.serial)")
        }
    }
}
