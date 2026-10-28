// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: upstream byte accounting.
//
// G2-FIX-7/G2-FIX-126: the host ModelGateway already counts bytesUp (request
// bytes handed to URLSession) and bytesDown (response bytes received). The
// scenario report must project those counters instead of inferring direction
// from the bounded response log. The fallback below exists only for a report
// written before the gateway projection is available; it cannot recover request
// bytes and says so through `bytes_source`.

import Foundation
import PhoneDSHGateway

/// Where a report's upstream byte counters came from.
public enum ScenarioUsageBytesSource: String, Codable, Sendable {
    /// The host `PhoneDSHDiagnostics.gatewayMetrics` snapshot.
    case gatewayMetrics = "gateway_metrics"
    /// The scripted mock upstream's own request/response body counters.
    case mock
    /// Legacy fallback: response-log body bytes only, request bytes unknown.
    case responseLogFallback = "response_log_fallback"
}

/// One report's upstream byte counters and their provenance.
public struct ScenarioUsageBytes: Equatable, Sendable {
    public var bytesIn: Int
    public var bytesOut: Int
    public var source: ScenarioUsageBytesSource

    public init(bytesIn: Int, bytesOut: Int, source: ScenarioUsageBytesSource) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.source = source
    }
}

public enum ScenarioUsageMetrics {
    /// Projects the host gateway snapshot. When it is absent (a run that never
    /// reached a host, or a report from before the projection), returns the
    /// response-log fallback with an explicit provenance.
    public static func real(gatewayMetrics: ModelGatewayMetrics?,
                            responseLogBytes: Int) -> ScenarioUsageBytes {
        if let metrics = gatewayMetrics {
            return ScenarioUsageBytes(bytesIn: metrics.bytesUp,
                                      bytesOut: metrics.bytesDown,
                                      source: .gatewayMetrics)
        }
        return ScenarioUsageBytes(bytesIn: 0,
                                  bytesOut: max(0, responseLogBytes),
                                  source: .responseLogFallback)
    }

    /// The mock upstream owns both directions: `requestBytes` is what the
    /// Worker sent, `responseBytes` is what the mock streamed back.
    public static func mock(requestBytes: Int, responseBytes: Int) -> ScenarioUsageBytes {
        ScenarioUsageBytes(bytesIn: max(0, requestBytes),
                           bytesOut: max(0, responseBytes),
                           source: .mock)
    }

    /// Legacy fallback: sum the bounded response-log `body` files. This is a
    /// response-only measurement; it is never labelled as a request count.
    public static func responseLogBytes(in responseLog: URL,
                                        fileManager: FileManager = .default) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: responseLog,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []) else { return 0 }
        var total = 0
        for case let url as URL in enumerator where url.lastPathComponent == "body" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                    == true else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
            }
        }
        return total
    }
}
