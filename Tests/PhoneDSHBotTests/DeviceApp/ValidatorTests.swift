// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Runs `spec/device/v1/golden/device-app.jsonl` (device-app-v1) through the real
/// `DeviceAppRules` / `DeviceAppValidator`, plus extra lexer-edge cases of our own.
final class DeviceAppValidatorTests: XCTestCase {
    private static func goldenURL(filePath: String = #filePath) throws -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let url = candidate.appendingPathComponent("spec/device/v1/golden/device-app.jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            candidate.deleteLastPathComponent()
        }
        throw NSError(domain: "DeviceAppValidatorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot locate device-app.jsonl from #filePath"])
    }

    private func vectors() throws -> [[String: Any]] {
        let text = try String(contentsOf: Self.goldenURL(), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testGoldenVectorsThroughRealCode() throws {
        var counts: [String: Int] = [:]
        for v in try vectors() {
            let id = v["id"] as! String
            let kind = v["kind"] as! String
            counts[kind, default: 0] += 1
            switch kind {
            case "name":
                XCTAssertEqual(DeviceAppRules.isValidName(v["value"] as! String), v["valid"] as! Bool, id)
            case "path":
                XCTAssertEqual(DeviceAppRules.isValidPath(v["value"] as! String), v["valid"] as! Bool, id)
            case "title":
                XCTAssertEqual(DeviceAppRules.isValidTitle(v["value"] as! String), v["valid"] as! Bool, id)
            case "manifest":
                XCTAssertEqual(DeviceAppRules.isValidManifest(appName: v["app_name"] as! String, json: v["json"] as! String), v["valid"] as! Bool, id)
            case "digest":
                let entries = (v["files"] as! [[String: Any]]).map {
                    DeviceAppRules.FileEntry(path: $0["path"] as! String, size: $0["size"] as! Int, sha256: $0["sha256"] as! String)
                }
                XCTAssertEqual(DeviceAppRules.manifestDigest(entries), v["digest"] as! String, id)
            case "check":
                let got = DeviceAppValidator.check(files: v["files"] as! [String: String], perms: v["perms"] as! [String])
                if v["ok"] as! Bool {
                    XCTAssertNil(got, id)
                } else {
                    XCTAssertEqual(got, DeviceAppCheckFailure(code: .init(rawValue: v["code"] as! String)!, path: v["path"] as! String, line: v["line"] as! Int), id)
                }
            default:
                break // "put" is device-side (app.put session rules), not the phone validator.
            }
        }
        for kind in ["name", "path", "title", "manifest", "digest", "check"] {
            XCTAssertGreaterThan(counts[kind, default: 0], 0, kind)
        }
    }

    func testEveryRejectionCodeIsExercisedByGolden() throws {
        let codes = Set(try vectors().filter { $0["kind"] as? String == "check" && $0["ok"] as? Bool == false }.map { $0["code"] as! String })
        XCTAssertEqual(codes, Set(DeviceAppCheckFailure.Code.allCases.map(\.rawValue)))
    }

    func testFileEntriesAreDigestedByUTF8PathOrder() {
        let entries = DeviceAppRules.fileEntries(files: ["main.py": "abc", "app.json": "{}"])
        XCTAssertEqual(entries.map(\.path), ["app.json", "main.py"])
        XCTAssertEqual(entries.map(\.size), [2, 3])
        XCTAssertEqual(entries.map(\.sha256), [
            "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", // sha256("{}")
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", // sha256("abc")
        ])
    }

    // MARK: extra cases

    private let tail = "keys.get(1)\n"

    private func check(_ main: String, perms: [String] = [], extra: [String: String] = [:]) -> DeviceAppCheckFailure? {
        var files = extra
        files["main.py"] = main
        return DeviceAppValidator.check(files: files, perms: perms)
    }

    private func assertFails(_ main: String, _ code: DeviceAppCheckFailure.Code, line: Int, perms: [String] = [], file: StaticString = #filePath, testLine: UInt = #line) {
        XCTAssertEqual(check(main, perms: perms), DeviceAppCheckFailure(code: code, path: "main.py", line: line), file: file, line: testLine)
    }

    private func assertPasses(_ main: String, perms: [String] = [], extra: [String: String] = [:], file: StaticString = #filePath, testLine: UInt = #line) {
        XCTAssertNil(check(main, perms: perms, extra: extra), file: file, line: testLine)
    }

    func testBackslashContinuationCannotHideImport() {
        assertFails("import keys\nimport time, \\\n    os\n" + tail, .import, line: 3)
        assertFails("import keys\nimport \\\nos\n" + tail, .import, line: 3)
        assertFails("import keys\nfrom \\\n  socket import socket\n" + tail, .import, line: 2)
        assertFails("import keys\nimport time \\\n; import os\n" + tail, .import, line: 3)
    }

    func testBracketContinuationKeepsLineNumbers() {
        assertFails("import keys\nx = (1,\n     2)\nimport os\n" + tail, .import, line: 4)
        assertFails("import keys\nx = [\n  1,\n  exec,\n]\n" + tail, .name, line: 4)
    }

    func testNonASCIIIdentifiers() {
        assertPasses("import keys\nhéllo = 1\n名前 = 2\n" + tail)
        // CPython NFKC-normalises identifiers: a fullwidth spelling is the same name.
        assertFails("import keys\n\u{FF45}xec('1')\n" + tail, .name, line: 2)
        assertFails("import keys\nimport \u{FF4F}s\n" + tail, .import, line: 2)
        // A character that is not an identifier character outside a string is a lexical error.
        assertFails("import keys\nx = 1 \u{1F600}\n" + tail, .lex, line: 2)
        assertFails("import keys\nx\u{00A0}= 1\n" + tail, .lex, line: 2)
    }

    func testTabsAndSpacesIndentation() {
        assertPasses("import keys\nif 1:\n\tx = 1\n\ty = 2\n" + tail)
        assertPasses("import keys\nif 1:\n    x = 1\n    y = 2\n" + tail)
        // Tab and spaces whose order depends on the tab width are inconsistent.
        assertFails("import keys\nif 1:\n\tx = 1\n        y = 2\n" + tail, .lex, line: 4)
        assertFails("import keys\nif 1:\n        x = 1\n\ty = 2\n" + tail, .lex, line: 4)
        // Dedent to a column that was never opened.
        assertFails("import keys\nif 1:\n    if 2:\n        x = 1\n      y = 2\n" + tail, .lex, line: 5)
    }

    func testStringsAndTripleQuotes() {
        assertPasses("import keys\nx = '''a \"\"\" b ' c'''\ny = \"\"\"a ''' b\nimport os\n\"\"\"\n" + tail)
        assertPasses("import keys\nx = 'it\\'s import os'\ny = \"a\\\nb exec\"\n" + tail)
        assertPasses("import keys\nx = r'\\\\'\ny = Rb'exec'\nz = u'open'\n" + tail)
        assertFails("import keys\nx = '''abc\nimport os\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = \"abc\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = r'abc\\\n" , .lex, line: 2)
        // Line numbers after a multi-line string.
        assertFails("import keys\nx = '''a\nb\nc'''\nimport os\n" + tail, .import, line: 5)
    }

    func testFStringPrefixesAllRejected() {
        for prefix in ["f", "F", "rf", "fR", "Rf", "FR"] {
            assertFails("import keys\nx = \(prefix)'a'\n" + tail, .fstring, line: 2)
            assertFails("import keys\nx = \(prefix)\"\"\"a\"\"\"\n" + tail, .fstring, line: 2)
        }
        assertPasses("import keys\nf = 1\nx = f + 1\n" + tail)
    }

    func testCommentsAndStringsAreIgnoredByNameRules() {
        assertPasses("import keys\n# import os; exec(1); f'x'\nx = 'import os'\n" + tail)
        assertFails("import keys\nx = os.path  # fine\n" + tail, .name, line: 2)
        assertFails("import keys\nx = a.exec\n" + tail, .name, line: 2)
    }

    func testImportEdgeCases() {
        assertFails("import keys\nif 1: import os\n" + tail, .import, line: 2)
        assertFails("import keys\nfrom os.path import join\n" + tail, .import, line: 2)
        assertFails("import keys\nfrom .. import x\n" + tail, .import, line: 2)
        assertFails("import keys\nimport time, math.floor, os\n" + tail, .import, line: 2)
        assertFails("import keys\nimport helper.sub\n" + tail, .import, line: 2)
        assertPasses("import keys\nimport time as t, math as m\nfrom micropython import const\n" + tail)
        assertPasses("import keys, util\n" + tail, extra: ["util.py": "x = 1\n"])
        // Only top-level `.py` files are importable siblings.
        XCTAssertEqual(check("import keys, util\n" + tail, extra: ["lib/util.py": "x = 1\n"]),
                       DeviceAppCheckFailure(code: .import, path: "main.py", line: 1))
    }

    func testUnderscoreAndPermissionEdgeCases() {
        assertFails("import keys\nx = a . _b\n" + tail, .underscore, line: 2)
        assertFails("import keys\n__x__ = 1\n" + tail, .underscore, line: 2)
        assertPasses("import keys\nx = __name__\n____ = 1\n_ok = 2\n" + tail)
        assertFails("import audio, keys\nx = readinto\n" + tail, .perm, line: 1, perms: [])
        assertPasses("import audio, keys\nx = mic_gain\n" + tail, perms: ["audio", "mic"])
    }

    func testExceptEdgeCases() {
        assertFails("import keys\ntry:\n    pass\nexcept (OSError, BaseException):\n    pass\n" + tail, .except, line: 4)
        assertPasses("import keys\ntry:\n    pass\nexcept (OSError, ValueError) as e:\n    pass\n" + tail)
        assertFails("import keys\ntry:\n    pass\nexcept :\n    pass\n" + tail, .except, line: 4)
    }

    func testReportOrderIsPathThenLineThenRule() {
        // Same line: import (3) before name (4). Across files: path order wins over rule order.
        let files = ["main.py": "import keys\nkeys.get(1)\nexec(1)\n", "a.py": "x = 1\nimport os\n"]
        XCTAssertEqual(DeviceAppValidator.check(files: files, perms: []), DeviceAppCheckFailure(code: .import, path: "a.py", line: 2))
        // A lexical error reports at its own line even when a later rule would also fire.
        assertFails("import keys\nx = 'abc\nexec(1)\n" + tail, .lex, line: 2)
        // `size` beats everything, `exit_path` is last.
        let big = String(repeating: "#", count: 12289)
        XCTAssertEqual(DeviceAppValidator.check(files: ["main.py": "import os\n", "z.py": big], perms: []),
                       DeviceAppCheckFailure(code: .size, path: "z.py", line: 0))
        XCTAssertEqual(DeviceAppValidator.check(files: ["main.py": "x = 1\n"], perms: []),
                       DeviceAppCheckFailure(code: .exit_path, path: "main.py", line: 0))
    }

    func testSizeCountsBytesAndRejectsNUL() {
        XCTAssertEqual(check("import keys\n" + tail + "#" + String(repeating: "é", count: 6200)),
                       DeviceAppCheckFailure(code: .size, path: "main.py", line: 0))
        assertPasses("import keys\n" + tail + "#" + String(repeating: "x", count: 12000))
        XCTAssertEqual(check("import keys\n" + tail + "x = 1\u{0}\n"), DeviceAppCheckFailure(code: .size, path: "main.py", line: 0))
    }

    func testLexicalErrors() {
        assertFails("import keys\nx = (1,\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = 1)\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = (1]\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = 1 $ 2\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = 1 \\ 2\n" + tail, .lex, line: 2)
        assertFails("import keys\nx = 1\r2\n" + tail, .lex, line: 2)
    }

    func testCRLFAndMissingFinalNewlineAreAccepted() {
        assertPasses("import keys\r\nif 1:\r\n    x = 1\r\nkeys.get(1)")
        assertPasses("import keys\nkeys.get(1)")
        assertPasses("import keys\nif 1:\n    keys.get(1)")
    }

    func testExitPathOnlyFromRealTokens() {
        XCTAssertEqual(check("import keys\n# keys.get(1)\nx = 'keys.pressed()'\n"),
                       DeviceAppCheckFailure(code: .exit_path, path: "main.py", line: 0))
        assertPasses("import keys\nkeys . pressed()\n")
    }

    func testManifestEdgeCases() {
        func ok(_ json: String, app: String = "clock") -> Bool { DeviceAppRules.isValidManifest(appName: app, json: json) }
        let base = "{\"name\":\"clock\",\"title\":\"x\",\"version\":1,\"perms\":[]}"
        XCTAssertTrue(ok(base))
        XCTAssertTrue(ok(" \n" + base + "\n"))
        XCTAssertFalse(ok(base + " x"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1.0,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1e0,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":-1,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":01,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":true,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":NaN,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1,\"perms\":[],\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1,\"perms\":[\"mic\"]}", app: "other"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1,\"perms\":[\"Audio\"]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1,\"perms\":[1]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"x\",\"version\":1,\"perms\":[],\"x\":{\"a\":1,\"a\":2}}"))
        XCTAssertFalse(ok("[]"))
        XCTAssertTrue(ok("{\"name\":\"clock\",\"title\":\"\\u65f6\\u949f\",\"version\":12345678901234567890,\"perms\":[\"mic\",\"audio\",\"battery\"]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"a\\u200bb\",\"version\":1,\"perms\":[]}"))
        XCTAssertFalse(ok("{\"name\":\"clock\",\"title\":\"\\ud800\",\"version\":1,\"perms\":[]}"))
    }

    func testNameAndPathRejectTrailingNewline() {
        XCTAssertFalse(DeviceAppRules.isValidName("clock\n"))
        XCTAssertFalse(DeviceAppRules.isValidPath("main.py\n"))
        XCTAssertFalse(DeviceAppRules.isValidPath("a//b.py"))
        XCTAssertFalse(DeviceAppRules.isValidPath("a/b.py/"))
        XCTAssertFalse(DeviceAppRules.isValidPath("a.b/c.py"))
        XCTAssertFalse(DeviceAppRules.isValidPath("\u{FF41}.py"))
    }
}
