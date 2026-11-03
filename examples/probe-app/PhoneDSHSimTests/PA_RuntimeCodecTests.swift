// SPDX-License-Identifier: MIT

import XCTest
import ProbeKit

final class PA_RuntimeCodecTests: XCTestCase {
    func testMappingIsReversibleIncludingLiteralUnderscores() throws {
        let names = ["github.pull.get", "gmail.thread.get", "local_tool.read", "a_b.c_d", "bash"]
        for name in names {
            let encoded = try ToolNameCodec.encode(name)
            XCTAssertEqual(try ToolNameCodec.decode(encoded), name)
            XCTAssertLessThanOrEqual(encoded.utf8.count, 64)
            XCTAssertTrue(encoded.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
            })
        }
        XCTAssertNotEqual(try ToolNameCodec.encode("github.pull.get"),
                          try ToolNameCodec.encode("github_pull_get"))
    }

    func testRegisteredCodecLooksUpDescriptorAndModelName() throws {
        let descriptor = pa_runtimeDescriptor()
        let codec = try ToolNameCodec(descriptors: [descriptor])
        XCTAssertEqual(try codec.modelName(for: descriptor.internalName), "github_pull_get")
        XCTAssertEqual(try codec.internalName(forModelName: "github_pull_get"), descriptor.internalName)
        XCTAssertEqual(codec.descriptor(internalName: descriptor.internalName), descriptor)
        XCTAssertEqual(codec.anthropicTools.first?.name, "github_pull_get")
    }

    func testIllegalCharactersEmptySegmentsAndLengthAreRejected() {
        for name in ["", ".github.pull", "github..pull", "github.pull.", "github pull.get", "github/pull.get", "邮件.read"] {
            XCTAssertThrowsError(try ToolNameCodec.encode(name), "expected rejection for \(name)")
        }
        XCTAssertThrowsError(try ToolNameCodec.encode(String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try ToolNameCodec.decode("github.pull.get"))
        XCTAssertThrowsError(try ToolNameCodec.decode("trailing_"))
        XCTAssertThrowsError(try ToolNameCodec.decode("bad name"))
    }

    func testDuplicateAndUnknownNamesFailAtStartupOrLookup() throws {
        let descriptor = pa_runtimeDescriptor()
        XCTAssertThrowsError(try ToolNameCodec(descriptors: [descriptor, descriptor])) { error in
            XCTAssertEqual(error as? ToolNameCodecError, .duplicateInternalName(descriptor.internalName))
        }
        let codec = try ToolNameCodec(descriptors: [descriptor])
        XCTAssertThrowsError(try codec.internalName(forModelName: "github_issue_get")) { error in
            XCTAssertEqual(error as? ToolNameCodecError, .unknownModelName("github_issue_get"))
        }
        XCTAssertThrowsError(try NativeMainAgentAdapter(
            clientResolver: PA_RuntimeFailingResolver(failure: .notConfigured),
            toolInvoker: PA_RuntimeToolInvoker(descriptors: [descriptor, descriptor])))
    }
}
