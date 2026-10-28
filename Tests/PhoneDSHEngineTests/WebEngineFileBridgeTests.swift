// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHEngine: Web file/download bridge tests.
//
// These exercise the policy and the staging area that decide what a page may
// hand to WebKit: an exact loopback origin stays in the Web view, any other
// origin/scheme goes to the system opener (or is refused), selected files are
// copied into a confined per-engine directory and temporary files can be
// removed again. The UIKit picker/share presentation itself is iOS-only and is
// NOT_RUN on a Linux or macOS checkout; the real-WKWebView fixture coverage
// lives in examples/probe-app/PhoneDSHSimTests/WebEngineFileBridgeSimTests.swift.

import Foundation
import XCTest
import PhoneDSHEngine

final class WebEngineFileBridgeTests: XCTestCase {
    private let origin = URL(string: "http://127.0.0.1:45231")!

    // MARK: - Navigation policy

    func testLoopbackOriginStaysInTheWebView() {
        onMain {
            XCTAssertEqual(
                WebEngineFileBridge.route(
                    for: URL(string: "http://127.0.0.1:45231/static/web/index.html")!,
                    loopbackOrigin: origin),
                .web)
            XCTAssertEqual(
                WebEngineFileBridge.route(
                    for: URL(string: "http://127.0.0.1:45231/api/session/list")!,
                    loopbackOrigin: origin),
                .web)
            XCTAssertEqual(
                WebEngineFileBridge.route(
                    for: URL(string: "http://127.0.0.1:45231/connect?token=x")!,
                    loopbackOrigin: origin),
                .web)
            XCTAssertEqual(
                WebEngineFileBridge.route(for: URL(string: "about:blank")!,
                                          loopbackOrigin: origin),
                .web)
            // `<iframe srcdoc>` previews are page-internal documents.
            XCTAssertEqual(
                WebEngineFileBridge.route(for: URL(string: "about:srcdoc")!,
                                          loopbackOrigin: origin),
                .web)
        }
    }

    func testInternalDSHSchemesNeverReachTheSystemOpener() {
        onMain {
            for raw in [
                "dsh-resource://file/session/s1/a.txt",
                "dsh-app://app",
            ] {
                let url = URL(string: raw)!
                XCTAssertEqual(WebEngineFileBridge.route(for: url,
                                                         loopbackOrigin: origin),
                               .blocked,
                               "\(raw) is a DSH-internal address, not a system URL")
            }
            var opened: URL?
            let bridge = WebEngineFileBridge(loopbackOrigin: origin,
                                             openExternalURL: { opened = $0 })
            bridge.openExternal(URL(string: "dsh-resource://file/session/s1/a.txt")!)
            XCTAssertNil(opened)
        }
    }

    func testOtherOriginsAreExternal() {
        onMain {
            let examples = [
                "https://example.invalid/",
                "http://pc.invalid:8080/",
                "http://remote-pc.invalid:3000/static/web/index.html",
                "http://127.0.0.1:45232/static/web/index.html",
                "mailto:someone@example.invalid",
                "tel:+10000000000",
            ]
            for raw in examples {
                let url = URL(string: raw)!
                XCTAssertEqual(WebEngineFileBridge.route(for: url,
                                                         loopbackOrigin: origin),
                               .external(url),
                               "expected \(raw) to leave the local Web surface")
            }
        }
    }

    func testFileAndScriptNavigationsAreBlocked() {
        onMain {
            XCTAssertEqual(
                WebEngineFileBridge.route(for: URL(fileURLWithPath: "/etc/passwd"),
                                          loopbackOrigin: origin),
                .blocked)
            XCTAssertEqual(
                WebEngineFileBridge.route(
                    for: URL(string: "javascript:void(0)")!,
                    loopbackOrigin: origin),
                .blocked)
            XCTAssertEqual(
                WebEngineFileBridge.route(for: URL(string: "about:config")!,
                                          loopbackOrigin: origin),
                .blocked)
        }
    }

    func testExternalOpenReceivesOnlyExternalURLs() {
        onMain {
            var opened: URL?
            let bridge = WebEngineFileBridge(loopbackOrigin: origin,
                                             openExternalURL: { opened = $0 })
            let external = URL(string: "https://example.invalid/a")!
            bridge.openExternal(external)
            XCTAssertEqual(opened, external)

            opened = nil
            bridge.openExternal(URL(fileURLWithPath: "/etc/passwd"))
            XCTAssertNil(opened)
        }
    }

    // MARK: - Temporary staging

    func testSuggestedNameCannotEscapeTheStagingRoot() {
        onMain {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-bridge-\(UUID().uuidString)",
                                        isDirectory: true)
            let files = WebEngineFileBridge.TemporaryFiles(root: root)
            defer { files.removeAll() }

            do {
                let destination = try files.destination(
                    forSuggestedFilename: "../../etc/passwd")
                XCTAssertTrue(files.contains(destination))
                XCTAssertEqual(destination.lastPathComponent, "passwd")
                XCTAssertFalse(destination.path.hasSuffix("/etc/passwd"))
                XCTAssertEqual(WebEngineFileBridge.TemporaryFiles.sanitizedName(".."),
                               "file")
                XCTAssertEqual(WebEngineFileBridge.TemporaryFiles.sanitizedName("a/b.txt"),
                               "b.txt")
            } catch {
                XCTFail("staging a suggested file name failed: \(error)")
            }
        }
    }

    func testSelectedFileIsCopiedThenRemoved() {
        onMain {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-bridge-\(UUID().uuidString)",
                                        isDirectory: true)
            let root = base.appendingPathComponent("staged", isDirectory: true)
            let source = base.appendingPathComponent("attachment.txt")
            do {
                try FileManager.default.createDirectory(at: base,
                                                        withIntermediateDirectories: true)
                try Data("selected bytes".utf8).write(to: source)
            } catch {
                XCTFail("could not create the selection fixture: \(error)")
                return
            }
            defer { try? FileManager.default.removeItem(at: base) }

            let files = WebEngineFileBridge.TemporaryFiles(root: root)
            do {
                let stored = try files.importSelection(source)
                XCTAssertTrue(files.contains(stored))
                XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8),
                               "selected bytes")
                XCTAssertNotEqual(stored, source)

                files.remove(stored)
                XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
                // Only the bridge's copy is removed; the picker's original
                // belongs to the user and must survive cleanup.
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            } catch {
                XCTFail("importing the selection failed: \(error)")
            }
        }
    }

    func testDirectorySelectionIsRejected() {
        onMain {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-bridge-\(UUID().uuidString)",
                                        isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: base,
                                                        withIntermediateDirectories: true)
            } catch {
                XCTFail("could not create the directory fixture: \(error)")
                return
            }
            defer { try? FileManager.default.removeItem(at: base) }

            let files = WebEngineFileBridge.TemporaryFiles(
                root: base.appendingPathComponent("staged", isDirectory: true))
            XCTAssertThrowsError(try files.importSelection(base))
            XCTAssertThrowsError(
                try files.importSelection(URL(string: "https://example.invalid/a")!))
        }
    }

    func testSymbolicLinkSelectionIsRejectedWithoutTouchingTarget() {
        onMain {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-bridge-\(UUID().uuidString)",
                                        isDirectory: true)
            let target = base.appendingPathComponent("outside.txt")
            let link = base.appendingPathComponent("link.txt")
            do {
                try FileManager.default.createDirectory(at: base,
                                                        withIntermediateDirectories: true)
                try Data("outside bytes".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: link,
                                                           withDestinationURL: target)
            } catch {
                XCTFail("could not create the symlink fixture: \(error)")
                return
            }
            defer { try? FileManager.default.removeItem(at: base) }

            let files = WebEngineFileBridge.TemporaryFiles(
                root: base.appendingPathComponent("staged", isDirectory: true))
            XCTAssertThrowsError(try files.importSelection(link)) { error in
                guard let filesError = error as? WebEngineFileBridge.TemporaryFiles.Error,
                      case .notARegularFile = filesError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            // Rejecting the link must not remove or dereference the original.
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
            files.removeAll()
        }
    }

    func testRemovingStagingRootDoesNotDeleteItsParent() {
        onMain {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-bridge-\(UUID().uuidString)",
                                        isDirectory: true)
            let root = base.appendingPathComponent("staged", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root,
                                                        withIntermediateDirectories: true)
            } catch {
                XCTFail("could not create the staging fixture: \(error)")
                return
            }
            defer { try? FileManager.default.removeItem(at: base) }

            let files = WebEngineFileBridge.TemporaryFiles(root: root)
            files.remove(root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
            files.removeAll()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
        }
    }

    func testCleanupRemovesDownloadAndSelectionFiles() {
        onMain {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdsh-bridge-\(UUID().uuidString)",
                                        isDirectory: true)
            let source = base.appendingPathComponent("source.bin")
            do {
                try FileManager.default.createDirectory(at: base,
                                                        withIntermediateDirectories: true)
                try Data([0, 1, 2]).write(to: source)
            } catch {
                XCTFail("could not create the cleanup fixture: \(error)")
                return
            }
            defer { try? FileManager.default.removeItem(at: base) }

            let files = WebEngineFileBridge.TemporaryFiles(
                root: base.appendingPathComponent("staged", isDirectory: true))
            do {
                let stored = try files.importSelection(source)
                let download = try files.destination(
                    forSuggestedFilename: "artifact.log")
                try Data("download".utf8).write(to: download)
                files.removeAll()
                XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
                // `contains` is the path-escape guard, not an existence
                // check: it must keep accepting the deleted file's path.
                XCTAssertTrue(files.contains(stored))
            } catch {
                XCTFail("cleanup fixture failed: \(error)")
            }
        }
    }
}
