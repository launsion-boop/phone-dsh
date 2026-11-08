// SPDX-License-Identifier: MIT
import Foundation
import Observation

/// Foreground-only discovery. Candidates are untrusted until a user grants an MCP endpoint.
@MainActor @Observable public final class LANDeviceDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public private(set) var candidates: [LANDeviceCandidate] = []
    public private(set) var scanning = false
    public private(set) var status = "点击扫描局域网设备"
    @ObservationIgnored private var browser: NetServiceBrowser?
    @ObservationIgnored private var services: [String: NetService] = [:]
    @ObservationIgnored private var candidateKeys: [String: String] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    public override init() { super.init() }

    public func start() {
        stop()
        candidates = []; candidateKeys = [:]
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        scanning = true
        status = "正在扫描局域网设备"
        browser.searchForServices(ofType: "_pdsh-mcp._tcp.", inDomain: "local.")
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.stop()
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            self.candidates = []; self.candidateKeys = [:]
            self.status = "扫描结果已过期，请重新扫描"
        }
    }

    public func stop() {
        scanTask?.cancel(); scanTask = nil
        browser?.stop(); browser = nil
        for service in services.values { service.stop() }
        services.removeAll()
        scanning = false
        status = candidates.isEmpty ? "未发现设备，可重新扫描或手动添加" : "选择设备并确认地址与凭证"
    }

    public func clear() {
        stop(); expiryTask?.cancel(); expiryTask = nil
        candidates = []; candidateKeys = [:]
    }

    private func key(_ service: NetService) -> String { "\(service.name)|\(service.type)|\(service.domain)" }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser, services.count < 100 else { return }
        let id = key(service)
        services[id]?.stop()
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        let id = key(service)
        services.removeValue(forKey: id)?.stop()
        if let candidateID = candidateKeys.removeValue(forKey: id) {
            candidates.removeAll { $0.id == candidateID }
        }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        stop(); status = "局域网扫描失败，请检查本地网络权限"
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        let key = key(sender)
        guard services[key] === sender, let host = sender.hostName, let txt = sender.txtRecordData(),
              let candidate = LANDeviceCandidate(service: sender.name, host: host, port: sender.port, txt: txt) else { return }
        if let old = candidateKeys[key] { candidates.removeAll { $0.id == old } }
        candidateKeys[key] = candidate.id
        candidates.append(candidate)
        candidates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = key(sender)
        if services[id] === sender { services.removeValue(forKey: id) }
    }
}
