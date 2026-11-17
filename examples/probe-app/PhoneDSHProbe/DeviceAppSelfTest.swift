// SPDX-License-Identifier: MIT
// DEBUG-only automation of the device-app-v1 install flow against a real Link device.
//
// !!! WARNING: THIS FILE BYPASSES THE PER-INSTALL APPROVAL CARD (device-app.md §7). !!!
// !!! It installs a program on a device with no user confirmation. It is compiled   !!!
// !!! only under `#if DEBUG`, runs only with the launch argument                    !!!
// !!! `-pdsh-selftest-device-app 1`, and MUST NEVER SHIP in a release build.         !!!
//
// It uses the same installer (`DeviceAppInstaller.live`) and `callLinkTool(origin: .user)` as the app.
// Evidence is flushed to Documents/selftest-device-app.json after every step.
#if DEBUG
import Foundation
import PhoneDSHAgentCore
import PhoneDSHBLE
import PhoneDSHBot

@MainActor
enum DeviceAppSelfTest {
    static let argument = "-pdsh-selftest-device-app"
    static let nameArgument = "-pdsh-selftest-name"
    static let bundleArgument = "-pdsh-selftest-bundle"
    static let totalCap: TimeInterval = 150
    static let appName = "selftest_pulse"

    static func argumentValue(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static var requested: Bool { argumentValue(argument) == "1" }

    private static var started = false

    static func runIfRequested() async {
        guard requested, !started else { return }
        started = true
        await Run().execute()
    }

    // MARK: - Embedded example app (one small valid app, perms [])

    static let embeddedManifest = #"{"name":"selftest_pulse","title":"Selftest Pulse","version":1,"perms":[]}"#
    static let embeddedMain = """
    import lcd, keys, ui, kit
    ui.page("Selftest Pulse", "Long OK = back")
    n = 0
    while True:
        lcd.fill_rect(20, 100, 40, 40, ui.ACCENT if n % 2 == 0 else ui.BG)
        lcd.text("%d   " % n, 20, 160, ui.FG, ui.BG, lcd.F32)
        k = keys.get(300)
        if k == "back":
            break
        n += 1
    """ + "\n"

    // MARK: - One run

    @MainActor
    private final class Run {
        let started = Date()
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var facts: [String: Any] = [:]
        var finished = false
        let file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selftest-device-app.json")

        func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }
        func elapsed() -> Double { (Date().timeIntervalSince(started) * 10).rounded() / 10 }
        var remaining: TimeInterval { totalCap - Date().timeIntervalSince(started) }

        func log(_ step: String, _ detail: [String: Any] = [:]) {
            var entry: [String: Any] = ["t": stamp(), "elapsed_s": elapsed(), "step": step]
            for (key, value) in detail { entry[key] = value }
            steps.append(entry)
            flush(done: false)
        }

        func fail(_ reason: String) {
            failures.append(reason)
            log("failure", ["reason": reason])
        }

        func flush(done: Bool, ok: Bool? = nil) {
            var root: [String: Any] = [
                "started": ISO8601DateFormatter().string(from: started),
                "updated": stamp(),
                "done": done,
                "cap_s": DeviceAppSelfTest.totalCap,
                "steps": steps,
                "failures": failures,
                "facts": facts,
            ]
            if let ok { root["ok"] = ok }
            guard JSONSerialization.isValidJSONObject(root),
                  let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: file, options: .atomic)
        }

        func finish() {
            guard !finished else { return }
            finished = true
            let ok = failures.isEmpty
            facts["total_s"] = elapsed()
            flush(done: true, ok: ok)
        }

        /// Plain Foundation value of a Link JSON value, for the evidence file.
        func plain(_ value: JSONValue?) -> Any {
            guard let value, let data = try? JSONEncoder().encode(value),
                  let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return NSNull() }
            return any
        }

        func snapshot(_ device: BLEDeviceStore.Device) -> [String: Any] {
            ["id": device.id.uuidString, "name": device.name, "state": device.state, "linkState": device.linkState,
             "linkDeviceID": device.linkDeviceID, "linkIdentity": device.linkIdentity,
             "tools": device.linkTools.count, "identityError": device.identityError, "rssi": device.rssi]
        }

        func execute() async {
            // Hard cap: a watchdog writes the final record even if a call is stuck.
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(DeviceAppSelfTest.totalCap))
                guard let self, !self.finished else { return }
                self.fail("total cap \(Int(DeviceAppSelfTest.totalCap)) s reached")
                self.finish()
            }
            log("start", ["arguments": Array(CommandLine.arguments.dropFirst())])
            await body()
            watchdog.cancel()
            finish()
        }

        func body() async {
            let store = BLEDeviceStore.shared
            store.trustConnectedDevices = true
            let wanted = DeviceAppSelfTest.argumentValue(DeviceAppSelfTest.nameArgument) ?? "PDSH Passport"

            // 1. scan, connect, wait for Link identity and tools/list.
            let scanStart = Date()
            log("scan.begin", ["wanted": wanted, "store_status": store.status])
            var target: BLEDeviceStore.Device?
            var lastScan = Date.distantPast
            let scanDeadline = min(60, remaining)
            while !finished, Date().timeIntervalSince(scanStart) < scanDeadline {
                if Date().timeIntervalSince(lastScan) > 8 { store.scan(); lastScan = Date() }
                if let found = store.devices.first(where: { $0.name == wanted }) { target = found; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let found = target else {
                facts["scan_phase_s"] = Date().timeIntervalSince(scanStart)
                fail("scan timeout: no peripheral named \(wanted) within \(Int(scanDeadline)) s")
                log("scan.timeout", ["store_status": store.status, "scanning": store.scanning,
                                     "seen": store.devices.map { "\($0.name) rssi=\($0.rssi) \($0.state)" }])
                return
            }
            facts["scan_phase_s"] = Date().timeIntervalSince(scanStart)
            log("scan.found", snapshot(found))

            let connectStart = Date()
            if found.state == "未连接" { store.connect(found.id) }
            var device = found
            var lastState = ""
            let expected = ["app.info", "app.begin", "app.put", "app.abort", "app.commit", "app.run", "app.stop", "app.remove"]
            var ready = false
            while !finished, Date().timeIntervalSince(connectStart) < min(60, remaining) {
                if let now = store.devices.first(where: { $0.id == found.id }) {
                    device = now
                    let key = "\(now.state)|\(now.linkState)|\(now.linkTools.count)|\(now.linkDeviceID.isEmpty)"
                    if key != lastState { lastState = key; log("connect.state", snapshot(now)) }
                    if now.state == "未连接", Date().timeIntervalSince(connectStart) > 3,
                       Int(Date().timeIntervalSince(connectStart)) % 10 == 0 { store.connect(found.id) }
                    if !now.linkDeviceID.isEmpty, expected.allSatisfy(now.linkTools.contains) { ready = true; break }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            facts["connect_phase_s"] = Date().timeIntervalSince(connectStart)
            facts["device_id"] = device.linkDeviceID
            facts["link_identity"] = device.linkIdentity
            facts["tools"] = device.linkTools
            facts["att_mtu"] = "not exposed by BLEDeviceStore (omitted)"
            guard ready else {
                fail("link not ready within 60 s: state=\(device.state) linkState=\(device.linkState) tools=\(device.linkTools.count) missing=\(expected.filter { !device.linkTools.contains($0) })")
                log("connect.timeout", snapshot(device))
                return
            }
            log("connect.ready", snapshot(device))
            let id = device.id

            // 2. app.info
            let info1 = await call(id, "app.info", .object([:]))
            recordInfo("info.before", info1)

            // 3. bundle, validate, digest, install
            guard let files = loadFiles() else { return }
            let perms: [String] = []
            if let failure = DeviceAppValidator.check(files: files, perms: perms) {
                fail("DeviceAppValidator.check: \(failure.code.rawValue) \(failure.path):\(failure.line)")
                return
            }
            log("validator.ok")
            let entries = PhoneDSHBot.DeviceAppRules.fileEntries(files: files)
            let digest = PhoneDSHBot.DeviceAppRules.manifestDigest(entries)
            facts["declared_digest"] = digest
            log("digest", ["digest": digest, "files": entries.map { "\($0.path) \($0.size) \($0.sha256)" }])
            let bundle = PhoneDSHBLE.DeviceAppBundle(
                name: DeviceAppSelfTest.appName,
                files: files.keys.sorted().map { PhoneDSHBLE.DeviceAppFile(path: $0, bytes: Data(files[$0]!.utf8)) },
                digest: digest)

            let installStart = Date()
            var reported = ""
            do {
                let result = try await DeviceAppInstaller.live(deviceID: id, installID: UUID()).install(bundle)
                reported = result.digest
                facts["install"] = ["digest": result.digest, "calls": result.calls, "resumes": result.resumes,
                                    "confirmedByInfo": result.confirmedByInfo,
                                    "duration_s": Date().timeIntervalSince(installStart)] as [String: Any]
                log("install.done", facts["install"] as? [String: Any] ?? [:])
                if result.digest != digest { fail("installer reported digest \(result.digest) != declared \(digest)") }
            } catch {
                facts["install"] = ["error": String(describing: error),
                                    "duration_s": Date().timeIntervalSince(installStart)] as [String: Any]
                fail("install failed: \(error)")
                log("install.error", facts["install"] as? [String: Any] ?? [:])
            }

            // 4. app.info again
            let info2 = await call(id, "app.info", .object([:]))
            recordInfo("info.after", info2)
            let installed = (info2?["apps"]?.arrayValue ?? []).first { $0["name"]?.stringValue == DeviceAppSelfTest.appName }
            let deviceDigest = installed?["digest"]?.stringValue ?? ""
            facts["device_reported_digest"] = deviceDigest
            facts["digest_equal"] = deviceDigest == digest
            log("digest.compare", ["declared": digest, "installer": reported, "info": deviceDigest, "equal": deviceDigest == digest])
            if deviceDigest != digest { fail("app.info digest \(deviceDigest.isEmpty ? "(app not listed)" : deviceDigest) != declared \(digest)") }

            // 5. run + stop (the app is left installed)
            let run = await call(id, "app.run", .object(["name": .string(DeviceAppSelfTest.appName)]))
            log("run", ["result": plain(run)])
            if run == nil { fail("app.run did not return ok:true") }
            try? await Task.sleep(for: .seconds(2))
            let stop = await call(id, "app.stop", .object([:]))
            log("stop", ["result": plain(stop)])
            if stop == nil { fail("app.stop did not return ok:true") }
        }

        func recordInfo(_ step: String, _ result: JSONValue?) {
            guard let result else { fail("\(step): app.info returned no ok result"); return }
            log(step, ["protocol": plain(result["protocol"]), "free_bytes": plain(result["free_bytes"]),
                       "free_mem": plain(result["free_mem"]), "limits": plain(result["limits"]),
                       "apps": plain(result["apps"])])
            if result["protocol"]?.stringValue != "device-app-v1" { fail("\(step): protocol is not device-app-v1") }
        }

        /// One `.user`-origin Link call; the ok:true result object, else nil with the reason recorded.
        func call(_ id: UUID, _ name: String, _ arguments: JSONValue) async -> JSONValue? {
            let begin = Date()
            do {
                let outcome = try await callLinkTool(
                    deviceID: id, name: name, arguments: arguments,
                    idempotencyKey: "selftest.\(name).\(UUID().uuidString.lowercased())", origin: .user)
                guard case .completed(_, let reply) = outcome else {
                    log("call.\(name).outcome", ["outcome": String(describing: outcome)])
                    fail("\(name): not completed (\(outcome))")
                    return nil
                }
                let result = reply["result"]
                log("call.\(name)", ["status": plain(reply["status"]), "ok": plain(result?["ok"]),
                                     "code": plain(result?["code"]), "duration_s": Date().timeIntervalSince(begin)])
                guard reply["status"]?.stringValue == "completed", let result, result["ok"]?.boolValue == true else {
                    fail("\(name): status=\(reply["status"]?.stringValue ?? "?") code=\(result?["code"]?.stringValue ?? "?")")
                    return nil
                }
                return result
            } catch {
                fail("\(name): \(error)")
                return nil
            }
        }

        func loadFiles() -> [String: String]? {
            if let path = DeviceAppSelfTest.argumentValue(DeviceAppSelfTest.bundleArgument) {
                // A directory of files (flat or up to 3 segments deep).
                let root = URL(fileURLWithPath: path)
                var out: [String: String] = [:]
                let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
                while let url = walker?.nextObject() as? URL {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let relative = String(url.path.dropFirst(root.path.count + 1))
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                        fail("bundle file \(relative) is not UTF-8"); return nil
                    }
                    out[relative] = text
                }
                log("bundle.loaded", ["source": path, "files": out.keys.sorted()])
                return out
            }
            log("bundle.embedded", ["name": DeviceAppSelfTest.appName])
            return ["main.py": DeviceAppSelfTest.embeddedMain, "app.json": DeviceAppSelfTest.embeddedManifest]
        }
    }
}
#endif
