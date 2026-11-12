// SPDX-License-Identifier: MIT
//
// W1-05 parity bench: export element geometry from the real probe App through
// XCUITest. The fixture is the shared JSON under scripts/parity/fixtures/ (the
// host passes its contents in the test-runner environment, because the
// simulator cannot read the repository checkout).
//
// What is measured: `XCUIElement.frame` in points, the accessibility label /
// value, and the fixture's per-element tolerance. What is deliberately NOT
// measured: pixel colours, glyph rasterisation, or a line count guessed from a
// frame height. XCUITest exposes no text-layout object, so `lines` and
// `wrapPoints` are null here; the comparator reports them as not exposed instead
// of inventing them. See docs/parity/bench.md and "Needed outside my scope".
//
// The test writes one JSON export per fixture to
// `PDSH_PARITY_OUT` when the runner can write it, else to the runner's
// temporary directory. It prints `PDSH_PARITY_IOS_OUT=<path>` so the host can
// copy the files into build/parity/ios.

import XCTest

final class ParityGeometryExportUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testExportAllParityFixtures() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(
            ["chat-empty", "session-drawer-open", "settings-root"],
            fixtures.compactMap { $0["id"] as? String },
            "scripts/parity/fixtures v0 must contain exactly the three bench screens"
        )

        let output = outputDirectory()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("PDSH_PARITY_IOS_OUT=\(output.path)")

        for fixture in fixtures {
            try export(fixture: fixture, to: output)
        }
    }

    // MARK: - Fixtures

    private func environment(_ name: String) -> String? {
        // xcodebuild strips the TEST_RUNNER_ prefix before the runner starts,
        // but accept both spellings so a direct `simctl` invocation also works.
        for key in [name, "TEST_RUNNER_\(name)"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func repoRoot() -> URL? {
        if let configured = environment("PDSH_PARITY_ROOT") {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        // #filePath is the compile-time source path. Four parents take
        // .../examples/probe-app/PhoneDSHDeviceUITests/<file> to the repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func loadFixtures() throws -> [[String: Any]] {
        if let encoded = environment("PDSH_PARITY_FIXTURES_JSON"),
           let data = encoded.data(using: .utf8),
           let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return value
        }
        guard let root = repoRoot() else {
            XCTFail("PDSH_PARITY_ROOT is unset and #filePath did not resolve a repo root")
            return []
        }
        let directory = root.appendingPathComponent("scripts/parity/fixtures", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            XCTFail("no fixtures in \(directory.path); pass PDSH_PARITY_FIXTURES_JSON")
            return []
        }
        return try files.map { file in
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FixtureError.invalid("\(file.path): not a JSON object")
            }
            return object
        }
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let message): return message
            }
        }
    }

    private func outputDirectory() -> URL {
        if let configured = environment("PDSH_PARITY_OUT") {
            let candidate = URL(fileURLWithPath: configured, isDirectory: true)
            if (try? FileManager.default.createDirectory(
                at: candidate,
                withIntermediateDirectories: true
            )) != nil {
                return candidate
            }
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pdsh-parity-ios", isDirectory: true)
    }

    // MARK: - Export

    private func export(fixture: [String: Any], to directory: URL) throws {
        guard (fixture["schema"] as? String) == "pdsh.parity.fixture.v0",
              let fixtureID = fixture["id"] as? String,
              let originID = fixture["origin"] as? String,
              let elements = fixture["elements"] as? [[String: Any]] else {
            throw FixtureError.invalid("fixture is missing schema/id/origin/elements")
        }

        app.terminate()
        app = XCUIApplication(bundleIdentifier: "dev.phone-dsh.probe")
        let seed = fixture["seed"] as? [String: Any]
        let iosSeed = seed?["ios"] as? [String: Any] ?? [:]
        app.launchArguments = iosSeed["launchArguments"] as? [String] ?? []
        app.launchEnvironment = iosSeed["launchEnvironment"] as? [String: String] ?? [:]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 60),
            "\(fixtureID): app did not reach the foreground"
        )

        if let actions = fixture["actions"] as? [[String: Any]] {
            for action in actions {
                try run(action: action, fixture: fixture)
            }
        }
        // The drawer's production open motion is 280 ms; give the real UI time
        // to settle before reading frames. This is not a replacement for a
        // wait on an element, which every action already does.
        usleep(700_000)

        let origin = resolve(id: originID, in: fixture)
        let originFrame = origin?.frame
        let originMissing = originFrame == nil || !(origin?.exists ?? false)

        var exported: [[String: Any]] = []
        for element in elements {
            guard let elementID = element["id"] as? String else { continue }
            var record: [String: Any] = ["id": elementID]
            if let tolerance = element["tolerance"] {
                record["tolerance"] = tolerance
            }
            if let gated = element["gatedAxes"] {
                record["gatedAxes"] = gated
            }
            if let exemption = element["exemption"] as? String {
                record["exemption"] = exemption
            }
            guard let selector = element["ios"] as? [String: Any] else {
                record["found"] = false
                record["identity"] = "no-ios-selector"
                record["reason"] = "fixture has no ios selector for this element"
                exported.append(record)
                continue
            }
            record["identity"] = identity(of: selector)
            guard let elementValue = resolve(selector: selector) else {
                record["found"] = false
                record["reason"] = "unknown ios selector shape"
                exported.append(record)
                continue
            }
            let exists = elementValue.waitForExistence(timeout: 5)
            record["found"] = exists
            if !exists {
                record["reason"] = "XCUIElement did not exist within 5 s"
                exported.append(record)
                continue
            }
            let absolute = frameObject(elementValue.frame)
            record["absoluteFrame"] = absolute
            record["frame"] = relativeFrame(absolute, origin: originFrame)
            if element["text"] as? Bool == true {
                // XCUITest exposes the accessible label/value, not a text
                // layout. Never derive a line count from a frame height.
                let label = elementValue.label
                let text: Any = label.isEmpty
                    ? (elementValue.value as? String ?? NSNull())
                    : label
                record["text"] = text
                record["lines"] = NSNull()
                record["lineCount"] = NSNull()
                record["wrapPoints"] = NSNull()
            }
            exported.append(record)
        }

        let payload: [String: Any] = [
            "schema": "pdsh.parity.geometry-export.v0",
            "fixture": fixtureID,
            "platform": "ios",
            "unit": "pt",
            "origin": originID,
            "originMissing": originMissing,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "examples/probe-app/PhoneDSHDeviceUITests/ParityGeometryExportUITests.swift (XCUITest frames)",
            "frame": ["width": app.frame.width, "height": app.frame.height],
            "elements": exported,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let target = directory.appendingPathComponent("\(fixtureID).json")
        try data.write(to: target, options: .atomic)
        print("PDSH_PARITY_IOS_EXPORT=\(target.path)")
    }

    private func run(action: [String: Any], fixture: [String: Any]) throws {
        guard let type = action["action"] as? String,
              let elementID = action["element"] as? String else {
            throw FixtureError.invalid("action is missing action/element")
        }
        guard let fixtureElement = (fixture["elements"] as? [[String: Any]])?
            .first(where: { ($0["id"] as? String) == elementID }),
              let selector = fixtureElement["ios"] as? [String: Any],
              let element = resolve(selector: selector) else {
            throw FixtureError.invalid("action \(type) cannot resolve \(elementID)")
        }
        switch type {
        case "tap":
            XCTAssertTrue(element.waitForExistence(timeout: 15), "\(elementID) not found for tap")
            element.tap()
        case "type":
            XCTAssertTrue(element.waitForExistence(timeout: 15), "\(elementID) not found for type")
            element.tap()
            element.typeText(action["text"] as? String ?? "")
        case "long_press":
            XCTAssertTrue(element.waitForExistence(timeout: 15), "\(elementID) not found for long press")
            element.press(forDuration: 0.8)
        case "wait":
            let seconds = (action["timeoutMillis"] as? NSNumber)?.doubleValue ?? 10_000
            XCTAssertTrue(
                element.waitForExistence(timeout: seconds / 1000),
                "\(elementID) did not appear within \(seconds / 1000)s"
            )
        default:
            throw FixtureError.invalid("unknown fixture action \(type)")
        }
        usleep(250_000)
    }

    // MARK: - Selectors

    private func identity(of selector: [String: Any]) -> String {
        if selector["application"] as? Bool == true { return "application" }
        if selector["identifier"] != nil { return "accessibilityIdentifier" }
        if selector["label"] != nil { return "label" }
        if let first = selector["first"] as? String { return "first:\(first)" }
        return "unknown"
    }

    private func resolve(id: String, in fixture: [String: Any]) -> XCUIElement? {
        guard let element = (fixture["elements"] as? [[String: Any]])?
            .first(where: { ($0["id"] as? String) == id }),
              let selector = element["ios"] as? [String: Any] else {
            return nil
        }
        return resolve(selector: selector)
    }

    private func resolve(selector: [String: Any]) -> XCUIElement? {
        if selector["application"] as? Bool == true {
            return app
        }
        let type = selector["type"] as? String
        let query: XCUIElementQuery
        switch type {
        case "button": query = app.buttons
        case "staticText": query = app.staticTexts
        case "textView": query = app.textViews
        case "scrollView": query = app.scrollViews
        default: query = app.descendants(matching: .any)
        }

        if let identifier = selector["identifier"] as? String {
            let element = query[identifier]
            if element.exists { return element }
            // A NavigationLink can expose the title on a descendant; fall back
            // to the unfiltered tree before giving up.
            return app.descendants(matching: .any)[identifier]
        }
        if let label = selector["label"] as? String {
            let predicate = NSPredicate(format: "label == %@", label)
            let element = query.matching(predicate).firstMatch
            if element.exists { return element }
            let anyExact = app.descendants(matching: .any).matching(predicate).firstMatch
            if anyExact.exists { return anyExact }
            // A NavigationLink can append its trailing value to the label
            // ("模型服务, DeepSeek"). The fixture names the stable prefix.
            let prefix = NSPredicate(format: "label BEGINSWITH %@", label)
            return app.descendants(matching: .any).matching(prefix).firstMatch
        }
        if let first = selector["first"] as? String {
            switch first {
            case "scrollView": return app.scrollViews.firstMatch
            case "textView": return app.textViews.firstMatch
            default: return nil
            }
        }
        return nil
    }

    // MARK: - Frames

    private func frameObject(_ frame: CGRect) -> [String: Any] {
        [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "w": Double(frame.size.width),
            "h": Double(frame.size.height),
        ]
    }

    private func relativeFrame(_ frame: [String: Any], origin: CGRect?) -> [String: Any] {
        guard let origin else { return frame }
        let x = (frame["x"] as? Double ?? 0) - Double(origin.origin.x)
        let y = (frame["y"] as? Double ?? 0) - Double(origin.origin.y)
        return [
            "x": x,
            "y": y,
            "w": frame["w"] as? Double ?? 0,
            "h": frame["h"] as? Double ?? 0,
        ]
    }
}
