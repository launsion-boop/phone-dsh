// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: frame/glTF oracle regressions.
//
// Root cause these pin: two shipped `workspace_command` oracles encoded
// assumptions that the real source284 run disproved.
//
//   * G2-F07 required exactly 60 `.bmp` files and explicitly rejected `.png`,
//     even though Python's stdlib in this environment has working zlib. The
//     real run produced 60 structurally valid PNG frames; the oracle now
//     accepts one set of 60 valid PNG *or* BMP frames and checks the real
//     image bytes (PNG chunk CRCs, IHDR, IDAT decompressed length and pixels;
//     BMP header/data size) instead of the extension.
//   * G2-F09 required `POSITION.count >= 8` for every mesh. A triangular
//     prism has six distinct corners; the real cube/prism scene is valid. The
//     oracle now recognises the two shapes by distinct corner/triangle counts
//     (8/12 cube, 6/8 prism) and still validates bin length, bufferView
//     contiguity, accessor bounds, index ranges, triangle degeneracy and
//     closed-edge incidence.
//
// The assertions are read from the shipped catalog, not copied here, and run
// through the same `ScenarioWorkspaceCommand` host-bash evaluator the macOS
// scenario runner and the simulator host phase use. Fixtures are generated in
// Swift (including a stored-deflate PNG writer), so a failure in the oracle is
// not masked by a shared Python image library.
//
// The class name starts with `PhoneDSH` so the CI gate
// `swift test --filter 'PhoneDSH|PhoneDSHShell'` executes it.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioFrameGLTFOracleTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ScenarioWorkspaceCommand.hostProcessesAvailable,
                          "workspace_command host evaluation requires /bin/bash on macOS")
    }

    // MARK: - Real catalog commands

    private static var repositoryRoot: URL {
        guard let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            preconditionFailure("cannot locate the repository root from #filePath")
        }
        return root
    }

    private func scenario(_ id: String) throws -> Scenario {
        let url = Self.repositoryRoot
            .appendingPathComponent("scripts/ci/scenarios/catalog.json")
        let catalog = try ScenarioCatalog.load(from: url)
        return try XCTUnwrap(catalog.scenarios.first { $0.id == id },
                             "\(id) is missing from the shipped catalog")
    }

    private func workspaceCommands(_ id: String) throws -> [String] {
        try scenario(id).assertions
            .filter { $0.type == "workspace_command" }
            .compactMap(\.command)
    }

    /// The frame-byte command for G2-F07 (the other command validates index.json).
    private func f07FrameCommand() throws -> String {
        let commands = try workspaceCommands("G2-F07")
        let index = try XCTUnwrap(commands.first { $0.contains("frames/index.json") },
                                  "G2-F07 lost its frames/index.json oracle")
        return try XCTUnwrap(commands.first { $0 != index },
                             "G2-F07 lost its frame-image oracle")
    }

    private func f07IndexCommand() throws -> String {
        let commands = try workspaceCommands("G2-F07")
        return try XCTUnwrap(commands.first { $0.contains("frames/index.json") },
                             "G2-F07 lost its frames/index.json oracle")
    }

    /// The geometry command for G2-F09; the determinism command is untouched.
    private func f09GeometryCommand() throws -> String {
        let commands = try workspaceCommands("G2-F09")
        return try XCTUnwrap(commands.first { $0.contains("bufferViews") },
                             "G2-F09 lost its glTF geometry oracle")
    }

    // MARK: - Evaluation

    private func withWorkspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-frame-gltf-oracle-\(UUID().uuidString)",
                                    isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try body(workspace)
    }

    @discardableResult
    private func evaluate(_ command: String, workspace: URL) throws
        -> ScenarioWorkspaceCommandOutcome {
        let results = workspace.deletingLastPathComponent()
            .appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results,
                                                withIntermediateDirectories: true)
        return try ScenarioWorkspaceCommand.evaluate(command: command,
                                                     workspace: workspace,
                                                     resultsDirectory: results)
    }

    private func assertPasses(_ command: String,
                              workspace: URL,
                              _ message: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws {
        let outcome = try evaluate(command, workspace: workspace)
        XCTAssertTrue(outcome.ok, "\(message)\n\(outcome.detail)", file: file, line: line)
    }

    private func assertFails(_ command: String,
                             workspace: URL,
                             _ message: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) throws {
        let outcome = try evaluate(command, workspace: workspace)
        XCTAssertFalse(outcome.ok, "\(message)\n\(outcome.detail)", file: file, line: line)
    }

    // MARK: - File helpers

    private func write(_ data: Data, _ relativePath: String, in workspace: URL) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func write(_ bytes: [UInt8], _ relativePath: String, in workspace: URL) throws {
        try write(Data(bytes), relativePath, in: workspace)
    }

    // MARK: - F07 fixtures

    private enum FrameFormat: String {
        case png
        case bmp
    }

    private func frameName(_ index: Int, _ format: FrameFormat) -> String {
        String(format: "frame_%03d.", index) + format.rawValue
    }

    /// Writes `count` real frames and returns their names. The caller writes
    /// index.json separately so malformed-index cases can be built too.
    @discardableResult
    private func writeFrames(_ workspace: URL,
                             _ format: FrameFormat,
                             count: Int = 60,
                             duplicateLast: Bool = false) throws -> [String] {
        var names: [String] = []
        for index in 0..<count {
            let name = frameName(index, format)
            names.append(name)
            let data: Data
            switch format {
            case .png:
                data = Data(pngData(width: 320, height: 180, seed: index))
            case .bmp:
                data = Data(bmpData(width: 320, height: 180, seed: index))
            }
            try write(data, "frames/\(name)", in: workspace)
        }
        if duplicateLast, let first = names.first, let last = names.last {
            let firstURL = workspace.appendingPathComponent("frames/\(first)")
            try write(Data(contentsOf: firstURL), "frames/\(last)", in: workspace)
        }
        return names
    }

    private func writeIndex(_ workspace: URL,
                            names: [String],
                            fps: Int = 10,
                            width: Int = 320,
                            height: Int = 180) throws {
        let object: [String: Any] = ["fps": fps,
                                     "width": width,
                                     "height": height,
                                     "frames": names]
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        try write(data, "frames/index.json", in: workspace)
    }

    // MARK: - F07 behaviour

    func testF07AcceptsSixtyValidPNGFrames() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .png)
            try writeIndex(workspace, names: names)
            try assertPasses(try f07FrameCommand(), workspace: workspace,
                             "60 structurally valid PNG frames must pass")
            try assertPasses(try f07IndexCommand(), workspace: workspace,
                             "a matching index.json must pass for PNG frames")
        }
    }

    func testF07AcceptsSixtyValidBMPFrames() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .bmp)
            try writeIndex(workspace, names: names)
            try assertPasses(try f07FrameCommand(), workspace: workspace,
                             "the old BMP path must keep passing")
            try assertPasses(try f07IndexCommand(), workspace: workspace,
                             "a matching index.json must pass for BMP frames")
        }
    }

    func testF07RejectsCorruptPNGCRC() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .png)
            try writeIndex(workspace, names: names)
            let url = workspace.appendingPathComponent("frames/\(names[0])")
            var bytes = [UInt8](try Data(contentsOf: url))
            // Byte 60 is inside the first IDAT payload: the chunk CRC no longer
            // matches, so a magic/size-only check would wrongly pass.
            bytes[60] ^= 0xff
            try write(bytes, "frames/\(names[0])", in: workspace)
            try assertFails(try f07FrameCommand(), workspace: workspace,
                            "a PNG with a broken chunk CRC must fail")
        }
    }

    func testF07RejectsWrongPNGDimensions() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .png)
            try writeIndex(workspace, names: names)
            try write(Data(pngData(width: 321, height: 180, seed: 10)),
                      "frames/\(names[10])", in: workspace)
            try assertFails(try f07FrameCommand(), workspace: workspace,
                            "a frame that is not 320x180 must fail")
        }
    }

    func testF07RejectsWrongBMPDimensions() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .bmp)
            try writeIndex(workspace, names: names)
            let url = workspace.appendingPathComponent("frames/\(names[0])")
            var bytes = [UInt8](try Data(contentsOf: url))
            setUInt32LE(321, &bytes, at: 18)
            try write(bytes, "frames/\(names[0])", in: workspace)
            try assertFails(try f07FrameCommand(), workspace: workspace,
                            "a BMP whose header width is not 320 must fail")
        }
    }

    func testF07RejectsDuplicateFirstAndLastFrames() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .png, duplicateLast: true)
            try writeIndex(workspace, names: names)
            try assertFails(try f07FrameCommand(), workspace: workspace,
                            "identical first and last images must fail")
        }
    }

    func testF07RejectsMissingFrame() throws {
        try withWorkspace { workspace in
            let names = try writeFrames(workspace, .png, count: 59)
            try writeIndex(workspace, names: names + ["frame_059.png"])
            try assertFails(try f07FrameCommand(), workspace: workspace,
                            "a 59-frame set must fail")
        }
    }

    func testF07RejectsIndexPathEscape() throws {
        try withWorkspace { workspace in
            var names = try writeFrames(workspace, .png)
            names[0] = "../\(names[0])"
            try writeIndex(workspace, names: names)
            try assertFails(try f07IndexCommand(), workspace: workspace,
                            "an index name that is not a plain frames/ basename must fail")
        }
    }

    func testF07RejectsIndexNameThatDoesNotExist() throws {
        try withWorkspace { workspace in
            var names = try writeFrames(workspace, .png)
            names[0] = "missing.png"
            try writeIndex(workspace, names: names)
            try assertFails(try f07IndexCommand(), workspace: workspace,
                            "an index name that does not match a real frame must fail")
        }
    }

    func testF07RejectsFramesDirectorySymlinkEscape() throws {
        try withWorkspace { workspace in
            // Build a complete, otherwise valid 60-frame set outside the
            // workspace, then expose it only through a `frames` directory
            // symlink. Both F07 commands must reject the escape instead of
            // accepting every realpath because they all share that root.
            let outsideRoot = workspace.deletingLastPathComponent()
                .appendingPathComponent("outside-frames", isDirectory: true)
            let names = try writeFrames(outsideRoot, .png)
            try writeIndex(outsideRoot, names: names)
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("frames", isDirectory: true),
                withDestinationURL: outsideRoot.appendingPathComponent("frames",
                                                                       isDirectory: true))
            try assertFails(try f07FrameCommand(), workspace: workspace,
                            "a frames directory symlink that escapes the workspace must fail")
            try assertFails(try f07IndexCommand(), workspace: workspace,
                            "the index oracle must also reject a frames directory symlink escape")
        }
    }

    // MARK: - PNG writer (stored deflate, real CRCs)

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }

    private func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }

    /// A zlib stream using uncompressed (BTYPE=00) deflate blocks; Python's
    /// `zlib.decompress` accepts it and it needs no compression library.
    private func storedZlib(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var index = 0
        repeat {
            let length = min(65_535, input.count - index)
            let blockFinal: UInt8 = index + length == input.count ? 1 : 0
            out.append(blockFinal)
            let value = UInt16(length)
            let inverse = ~value
            out.append(UInt8(value & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(inverse & 0xff))
            out.append(UInt8((inverse >> 8) & 0xff))
            out.append(contentsOf: input[index..<index + length])
            index += length
        } while index < input.count
        let checksum = adler32(input)
        out.append(UInt8((checksum >> 24) & 0xff))
        out.append(UInt8((checksum >> 16) & 0xff))
        out.append(UInt8((checksum >> 8) & 0xff))
        out.append(UInt8(checksum & 0xff))
        return out
    }

    private func appendUInt32BE(_ value: UInt32, _ bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8(value & 0xff))
    }

    private func appendPNGChunk(_ bytes: inout [UInt8],
                                type: String,
                                payload: [UInt8]) {
        let typeBytes = Array(type.utf8)
        appendUInt32BE(UInt32(payload.count), &bytes)
        bytes.append(contentsOf: typeBytes)
        bytes.append(contentsOf: payload)
        appendUInt32BE(crc32(typeBytes + payload), &bytes)
    }

    private func pngData(width: Int, height: Int, seed: Int) -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity(height * (1 + width * 3))
        for y in 0..<height {
            raw.append(0)
            for x in 0..<width {
                raw.append(UInt8((x + seed * 11) & 0xff))
                raw.append(UInt8((y + seed * 13) & 0xff))
                raw.append(UInt8((x ^ y ^ seed) & 0xff))
            }
        }
        var ihdr: [UInt8] = []
        appendUInt32BE(UInt32(width), &ihdr)
        appendUInt32BE(UInt32(height), &ihdr)
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, no interlace.
        var png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        appendPNGChunk(&png, type: "IHDR", payload: ihdr)
        appendPNGChunk(&png, type: "IDAT", payload: storedZlib(raw))
        appendPNGChunk(&png, type: "IEND", payload: [])
        return png
    }

    // MARK: - BMP writer

    private func appendUInt16LE(_ value: UInt16, _ bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32LE(_ value: UInt32, _ bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 24) & 0xff))
    }

    private func setUInt32LE(_ value: UInt32, _ bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        bytes[offset + 2] = UInt8((value >> 16) & 0xff)
        bytes[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    private func bmpData(width: Int, height: Int, seed: Int) -> [UInt8] {
        let rowBytes = width * 3
        let padding = (4 - rowBytes % 4) % 4
        var pixels: [UInt8] = []
        pixels.reserveCapacity((rowBytes + padding) * height)
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width {
                pixels.append(UInt8((x ^ y ^ seed) & 0xff))
                pixels.append(UInt8((y + seed * 13) & 0xff))
                pixels.append(UInt8((x + seed * 11) & 0xff))
            }
            pixels.append(contentsOf: repeatElement(UInt8(0), count: padding))
        }
        var bytes: [UInt8] = Array("BM".utf8)
        appendUInt32LE(UInt32(54 + pixels.count), &bytes)
        appendUInt16LE(0, &bytes)
        appendUInt16LE(0, &bytes)
        appendUInt32LE(54, &bytes)
        appendUInt32LE(40, &bytes)
        appendUInt32LE(UInt32(bitPattern: Int32(width)), &bytes)
        appendUInt32LE(UInt32(bitPattern: Int32(height)), &bytes)
        appendUInt16LE(1, &bytes)
        appendUInt16LE(24, &bytes)
        appendUInt32LE(0, &bytes)
        appendUInt32LE(UInt32(pixels.count), &bytes)
        appendUInt32LE(2_835, &bytes)
        appendUInt32LE(2_835, &bytes)
        appendUInt32LE(0, &bytes)
        appendUInt32LE(0, &bytes)
        bytes.append(contentsOf: pixels)
        return bytes
    }

    // MARK: - F09 fixtures

    private struct Geometry {
        var positions: [Float]
        var indices: [UInt16]
    }

    private struct GLTFFixture {
        var document: [String: Any]
        var binary: Data
    }

    private func flatQuadMesh(corners: [(Float, Float, Float)],
                              quads: [[Int]],
                              offset: (Float, Float, Float)) -> Geometry {
        var positions: [Float] = []
        var indices: [UInt16] = []
        for quad in quads {
            let base = UInt16(positions.count / 3)
            for corner in quad {
                let p = corners[corner]
                positions.append(contentsOf: [p.0 + offset.0,
                                              p.1 + offset.1,
                                              p.2 + offset.2])
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        return Geometry(positions: positions, indices: indices)
    }

    /// A closed quad mesh whose POSITION accessor contains each distinct
    /// corner exactly once. This is the normal glTF representation a viewer
    /// expects; it is deliberately not flat-shaded.
    private func sharedQuadMesh(corners: [(Float, Float, Float)],
                                quads: [[Int]],
                                offset: (Float, Float, Float)) -> Geometry {
        var positions: [Float] = []
        for corner in corners {
            positions.append(contentsOf: [corner.0 + offset.0,
                                          corner.1 + offset.1,
                                          corner.2 + offset.2])
        }
        var indices: [UInt16] = []
        for quad in quads {
            indices.append(contentsOf: [UInt16(quad[0]), UInt16(quad[1]),
                                        UInt16(quad[2]), UInt16(quad[0]),
                                        UInt16(quad[2]), UInt16(quad[3])])
        }
        return Geometry(positions: positions, indices: indices)
    }

    /// A closed cube with eight shared POSITION vertices and 12 triangles.
    /// The old `POSITION.count >= 8` assertion passed this shape but wrongly
    /// rejected the six-vertex prism next to it.
    private func sharedCubeGeometry(offset: (Float, Float, Float) = (-2, 0, 0)) -> Geometry {
        let corners: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ]
        let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                     [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]
        return sharedQuadMesh(corners: corners, quads: quads, offset: offset)
    }

    /// A closed cube, flat-shaded: 24 POSITION entries that deduplicate to the
    /// eight real corners and 12 triangles. Kept as a supplement so the oracle
    /// is also pinned for viewers/exporters that duplicate vertices per face.
    private func cubeGeometry(offset: (Float, Float, Float) = (-2, 0, 0)) -> Geometry {
        let corners: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ]
        let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                     [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]
        return flatQuadMesh(corners: corners, quads: quads, offset: offset)
    }

    /// A closed triangular prism with six shared POSITION vertices and eight
    /// triangles (two caps + six sides). This is the real shape the old
    /// `POSITION.count >= 8` assertion misclassified as invalid.
    private func sharedPrismGeometry(offset: (Float, Float, Float) = (1.5, 0, 0)) -> Geometry {
        let corners: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (0.5, 1, 0),
            (0, 0, 1), (1, 0, 1), (0.5, 1, 1),
        ]
        var positions: [Float] = []
        for corner in corners {
            positions.append(contentsOf: [corner.0 + offset.0,
                                          corner.1 + offset.1,
                                          corner.2 + offset.2])
        }
        let indices: [UInt16] = [0, 1, 2, 3, 5, 4,
                                 0, 3, 4, 0, 4, 1,
                                 1, 4, 5, 1, 5, 2,
                                 2, 5, 3, 2, 3, 0]
        return Geometry(positions: positions, indices: indices)
    }

    /// A closed triangular prism, flat-shaded: 18 POSITION entries that
    /// deduplicate to six corners and eight triangles (two caps + six sides).
    private func prismGeometry(offset: (Float, Float, Float) = (1.5, 0, 0)) -> Geometry {
        let corners: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (0.5, 1, 0),
            (0, 0, 1), (1, 0, 1), (0.5, 1, 1),
        ]
        var positions: [Float] = []
        var indices: [UInt16] = []
        func triangle(_ a: Int, _ b: Int, _ c: Int) {
            let base = UInt16(positions.count / 3)
            for corner in [a, b, c] {
                let p = corners[corner]
                positions.append(contentsOf: [p.0 + offset.0,
                                              p.1 + offset.1,
                                              p.2 + offset.2])
            }
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            let base = UInt16(positions.count / 3)
            for corner in [a, b, c, d] {
                let p = corners[corner]
                positions.append(contentsOf: [p.0 + offset.0,
                                              p.1 + offset.1,
                                              p.2 + offset.2])
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        triangle(0, 1, 2)
        triangle(3, 5, 4)
        quad(0, 3, 4, 1)
        quad(1, 4, 5, 2)
        quad(2, 5, 3, 0)
        return Geometry(positions: positions, indices: indices)
    }

    /// A deliberately invalid "cube" that is flat-shaded into 24 POSITION
    /// entries which deduplicate to only six corners while still claiming 12
    /// triangles. The baseline `POSITION.count >= 8` check passes it, so only
    /// the shape/topology validation can reject it.
    private func sixCornerCubeGeometry(offset: (Float, Float, Float) = (-2, 0, 0)) -> Geometry {
        let corners: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ]
        let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4],
                     [3, 7, 6, 2], [0, 4, 7, 3], [1, 2, 6, 5]]
        // Map the top-two corners onto existing corners so only six distinct
        // positions remain, without changing the 12-triangle index count.
        let remap = [0, 1, 2, 3, 4, 5, 0, 1]
        let remapped = quads.map { $0.map { remap[$0] } }
        return flatQuadMesh(corners: corners, quads: remapped, offset: offset)
    }

    /// A deliberately invalid "cube" with exactly six POSITION vertices and
    /// 12 triangles. It has the prism's vertex count but not its (6, 8) shape,
    /// so the oracle must reject it rather than accepting every mesh with at
    /// least six corners.
    private func sharedSixCornerCubeGeometry(offset: (Float, Float, Float) = (-2, 0, 0)) -> Geometry {
        let corners: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1),
        ]
        // The old eight-corner cube with the two top corners mapped onto
        // corners 0 and 1, leaving six positions and 12 triangles.
        let quads = [[0, 3, 2, 1], [4, 5, 0, 1], [0, 1, 5, 4],
                     [3, 1, 0, 2], [0, 4, 1, 3], [1, 2, 0, 5]]
        return sharedQuadMesh(corners: corners, quads: quads, offset: offset)
    }

    private func appendFloatLE(_ value: Float, _ bytes: inout [UInt8]) {
        let bits = value.bitPattern
        bytes.append(UInt8(bits & 0xff))
        bytes.append(UInt8((bits >> 8) & 0xff))
        bytes.append(UInt8((bits >> 16) & 0xff))
        bytes.append(UInt8((bits >> 24) & 0xff))
    }

    private func makeGLTF(meshes: [Geometry],
                          badIndex: Bool = false,
                          badAccessorOffset: Bool = false,
                          truncateBinary: Bool = false,
                          bufferURI: String = "scene.bin") -> GLTFFixture {
        var binary: [UInt8] = []
        var views: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var primitives: [[String: Any]] = []
        for (meshIndex, mesh) in meshes.enumerated() {
            var indices = mesh.indices
            if badIndex, meshIndex == 0 {
                // `positions` stores three float components per vertex, so
                // `count / 3` is exactly one past the last valid VEC3 index.
                // Do not derive the bad index from the raw component count:
                // that can still land inside the vertex range and only break
                // the triangle instead of exercising the index-range check.
                indices[0] = UInt16(mesh.positions.count / 3)
            }
            let positionOffset = binary.count
            for value in mesh.positions {
                appendFloatLE(value, &binary)
            }
            let positionView = views.count
            let positionViewEntry: [String: Any] = [
                "buffer": 0,
                "byteOffset": positionOffset,
                "byteLength": mesh.positions.count * 4,
                "target": 34_962,
            ]
            views.append(positionViewEntry)
            let positionAccessor = accessors.count
            let positionAccessorEntry: [String: Any] = [
                "bufferView": positionView,
                "componentType": 5_126,
                "count": mesh.positions.count / 3,
                "type": "VEC3",
            ]
            accessors.append(positionAccessorEntry)
            let indexOffset = binary.count
            for value in indices {
                appendUInt16LE(value, &binary)
            }
            let indexView = views.count
            let indexViewEntry: [String: Any] = [
                "buffer": 0,
                "byteOffset": indexOffset,
                "byteLength": indices.count * 2,
                "target": 34_963,
            ]
            views.append(indexViewEntry)
            let indexAccessor = accessors.count
            let indexAccessorEntry: [String: Any] = [
                "bufferView": indexView,
                "componentType": 5_123,
                "count": indices.count,
                "type": "SCALAR",
            ]
            accessors.append(indexAccessorEntry)
            let primitive: [String: Any] = [
                "attributes": ["POSITION": positionAccessor],
                "indices": indexAccessor,
                "mode": 4,
            ]
            primitives.append(primitive)
        }
        if badAccessorOffset {
            accessors[0]["byteOffset"] = (views[0]["byteLength"] as! Int) + 8
        }
        let declaredLength = binary.count
        var data = Data(binary)
        if truncateBinary {
            data = Data(data.prefix(data.count - 8))
        }
        let nodes: [[String: Any]] = meshes.indices.map { index -> [String: Any] in
            ["mesh": index, "name": "mesh-\(index)"]
        }
        let meshEntries: [[String: Any]] = primitives.map { primitive -> [String: Any] in
            ["primitives": [primitive]]
        }
        let buffer: [String: Any] = ["uri": bufferURI,
                                     "byteLength": declaredLength]
        let document: [String: Any] = [
            "asset": ["version": "2.0", "generator": "phone-dsh oracle fixture"],
            "scene": 0,
            "scenes": [["nodes": Array(meshes.indices)]],
            "nodes": nodes,
            "meshes": meshEntries,
            "buffers": [buffer],
            "bufferViews": views,
            "accessors": accessors,
        ]
        return GLTFFixture(document: document, binary: data)
    }

    private func writeGLTF(_ fixture: GLTFFixture,
                           in workspace: URL,
                           writeBinary: Bool = true) throws {
        let json = try JSONSerialization.data(withJSONObject: fixture.document,
                                              options: [.prettyPrinted, .sortedKeys])
        try write(json, "scene.gltf", in: workspace)
        if writeBinary {
            try write(fixture.binary, "scene.bin", in: workspace)
        }
    }

    // MARK: - F09 behaviour

    func testF09AcceptsCubeAndSixVertexPrismInEitherMeshOrder() throws {
        for meshes in [[sharedCubeGeometry(), sharedPrismGeometry()],
                       [sharedPrismGeometry(), sharedCubeGeometry()]] {
            try withWorkspace { workspace in
                try writeGLTF(makeGLTF(meshes: meshes), in: workspace)
                try assertPasses(try f09GeometryCommand(), workspace: workspace,
                                 "a shared-vertex cube plus a six-vertex triangular prism must pass")
            }
        }
    }

    func testF09AcceptsFlatShadedDuplicatesInEitherMeshOrder() throws {
        for meshes in [[cubeGeometry(), prismGeometry()],
                       [prismGeometry(), cubeGeometry()]] {
            try withWorkspace { workspace in
                try writeGLTF(makeGLTF(meshes: meshes), in: workspace)
                try assertPasses(try f09GeometryCommand(), workspace: workspace,
                                 "flat-shaded vertices must still pass after coordinate deduplication")
            }
        }
    }

    func testF09RejectsCubeThatHasOnlySixCorners() throws {
        try withWorkspace { workspace in
            try writeGLTF(makeGLTF(meshes: [sixCornerCubeGeometry(), prismGeometry()]),
                          in: workspace)
            try assertFails(try f09GeometryCommand(), workspace: workspace,
                            "a flat-shaded 12-triangle cube with only six distinct corners must fail")
        }
    }

    func testF09RejectsSharedSixCornerCube() throws {
        try withWorkspace { workspace in
            try writeGLTF(makeGLTF(meshes: [sharedSixCornerCubeGeometry(), sharedCubeGeometry()]),
                          in: workspace)
            try assertFails(try f09GeometryCommand(), workspace: workspace,
                            "a six-POSITION 12-triangle cube must not pass just because a prism has six corners")
        }
    }

    func testF09RejectsOutOfRangeIndex() throws {
        try withWorkspace { workspace in
            // Use the shared-vertex cube so the bad index is derived from eight
            // real POSITION vertices; `count / 3` is then 8, one past the last
            // valid index. Assert the failure comes from the index-range check
            // rather than from a later triangle/topology stage.
            try writeGLTF(makeGLTF(meshes: [sharedCubeGeometry(), sharedPrismGeometry()],
                                   badIndex: true), in: workspace)
            let outcome = try evaluate(try f09GeometryCommand(), workspace: workspace)
            XCTAssertFalse(outcome.ok,
                           "an index at or beyond POSITION.count must fail\n\(outcome.detail)")
            XCTAssertTrue(outcome.detail.contains("index out of range"),
                          "the failure must come from the index-range check\n\(outcome.detail)")
        }
    }

    func testF09RejectsAccessorOffsetOutsideItsBufferView() throws {
        try withWorkspace { workspace in
            try writeGLTF(makeGLTF(meshes: [cubeGeometry(), prismGeometry()],
                                   badAccessorOffset: true), in: workspace)
            try assertFails(try f09GeometryCommand(), workspace: workspace,
                            "an accessor outside its bufferView must fail")
        }
    }

    func testF09RejectsBinaryShorterThanDeclaredByteLength() throws {
        try withWorkspace { workspace in
            try writeGLTF(makeGLTF(meshes: [sharedCubeGeometry(), sharedPrismGeometry()],
                                   truncateBinary: true), in: workspace)
            try assertFails(try f09GeometryCommand(), workspace: workspace,
                            "a scene.bin shorter than buffer.byteLength must fail")
        }
    }

    func testF09RejectsExternalBufferPathEscape() throws {
        try withWorkspace { workspace in
            let fixture = makeGLTF(meshes: [sharedCubeGeometry(), sharedPrismGeometry()],
                                   bufferURI: "../outside.bin")
            try writeGLTF(fixture, in: workspace, writeBinary: false)
            let outside = workspace.deletingLastPathComponent()
                .appendingPathComponent("outside.bin")
            try fixture.binary.write(to: outside)
            try assertFails(try f09GeometryCommand(), workspace: workspace,
                            "a buffer URI that escapes the workspace must fail")
        }
    }

    func testF09RejectsSymlinkedBufferEscape() throws {
        try withWorkspace { workspace in
            let fixture = makeGLTF(meshes: [sharedCubeGeometry(), sharedPrismGeometry()])
            try writeGLTF(fixture, in: workspace, writeBinary: false)
            let outside = workspace.deletingLastPathComponent()
                .appendingPathComponent("outside.bin")
            try fixture.binary.write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: workspace.appendingPathComponent("scene.bin"),
                withDestinationURL: outside)
            try assertFails(try f09GeometryCommand(), workspace: workspace,
                            "a scene.bin symlink that escapes the workspace must fail")
        }
    }
}
