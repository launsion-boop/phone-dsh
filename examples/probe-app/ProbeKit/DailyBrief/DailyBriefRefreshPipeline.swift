// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: linear Daily Brief refresh pipeline.

import Foundation

public struct DailyBriefRefreshPipeline: Sendable {
    private let transport: any DailyBriefTransport
    private let parser: DailyBriefParser
    private let now: @Sendable () -> Date

    public init(transport: any DailyBriefTransport,
                parser: DailyBriefParser = DailyBriefParser(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.parser = parser
        self.now = now
    }

    public func refresh(sources: [DailyBriefSource],
                        previous: DailyBriefSnapshot?) async throws -> DailyBriefRefreshOutcome {
        let startedAt = now()
        let enabled = sources.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            let issue = DailyBriefSourceIssue(sourceID: "", sourceName: "",
                                              message: DailyBriefError.noEnabledSources.localizedDescription)
            return DailyBriefRefreshOutcome(
                sources: sources,
                snapshotToPublish: nil,
                currentSnapshot: previous,
                report: DailyBriefRefreshReport(
                    startedAt: startedAt, finishedAt: now(), itemCount: previous?.items.count ?? 0,
                    newItemCount: 0, networkBytes: 0, sourceIssues: [issue], costSource: .actual))
        }

        var updatedSources = sources
        var fetchedItems: [String: [DailyBriefItem]] = [:]
        var sourceCursors = previous?.sourceCursors ?? [:]
        var issues: [DailyBriefSourceIssue] = []
        var networkBytes = 0
        var fetchedSourceCount = 0

        for source in enabled {
            try Task.checkCancellation()
            do {
                let response = try await transport.fetch(source)
                networkBytes += response.data.count
                if let index = updatedSources.firstIndex(where: { $0.id == source.id }) {
                    if let eTag = response.eTag { updatedSources[index].eTag = eTag }
                    if let lastModified = response.lastModified {
                        updatedSources[index].lastModified = lastModified
                    }
                    if let eTag = updatedSources[index].eTag {
                        sourceCursors[source.id] = eTag
                    } else if let lastModified = updatedSources[index].lastModified {
                        sourceCursors[source.id] = lastModified
                    }
                }
                if !response.notModified {
                    fetchedItems[source.id] = try parser.parse(response.data, source: source)
                    fetchedSourceCount += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(DailyBriefSourceIssue(
                    sourceID: source.id, sourceName: source.name,
                    message: Self.safeMessage(error)))
            }
        }
        try Task.checkCancellation()

        let previousIDs = Set(previous?.items.map(\.id) ?? [])
        var itemsByID: [String: DailyBriefItem] = [:]
        for source in enabled {
            let candidates = fetchedItems[source.id]
                ?? previous?.items.filter { $0.sourceID == source.id } ?? []
            for item in candidates where itemsByID[item.id] == nil {
                itemsByID[item.id] = item
            }
        }
        let items = itemsByID.values.sorted { left, right in
            switch (left.publishedAt, right.publishedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return left.title == right.title ? left.id < right.id : left.title < right.title
            }
        }
        let boundedItems = Array(items.prefix(DailyBriefLimits.maximumItems))
        let newItemCount = boundedItems.filter { !previousIDs.contains($0.id) }.count
        let finishedAt = now()
        let shouldPublish = fetchedSourceCount > 0
        let snapshot = shouldPublish ? DailyBriefSnapshot(
            id: DailyBriefIDs.snapshot(createdAt: finishedAt, items: boundedItems,
                                       sourceCursors: sourceCursors),
            createdAt: finishedAt, items: boundedItems, sourceCursors: sourceCursors) : nil
        let report = DailyBriefRefreshReport(
            startedAt: startedAt, finishedAt: finishedAt,
            itemCount: boundedItems.count, newItemCount: newItemCount,
            networkBytes: networkBytes, sourceIssues: issues, costSource: .actual)
        return DailyBriefRefreshOutcome(
            sources: updatedSources,
            snapshotToPublish: snapshot,
            currentSnapshot: snapshot ?? previous,
            report: report)
    }

    private static func safeMessage(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.count <= 200 ? text : String(text.prefix(199)) + "…"
    }
}

public final class DailyBriefURLSessionTransport: DailyBriefTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration,
                                  delegate: DailyBriefRedirectDelegate(), delegateQueue: nil)
    }

    public func fetch(_ source: DailyBriefSource) async throws -> DailyBriefTransportResponse {
        let url = try DailyBriefSourceValidator.validate(source.url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        if let eTag = source.eTag { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = source.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1",
                         forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DailyBriefError.invalidResponse }
        _ = try DailyBriefSourceValidator.validate(http.url)
        if http.expectedContentLength > Int64(DailyBriefLimits.maximumFeedBytes) {
            throw DailyBriefError.responseTooLarge
        }
        if http.statusCode == 304 {
            return DailyBriefTransportResponse(
                data: Data(), notModified: true,
                eTag: Self.header("ETag", in: http) ?? source.eTag,
                lastModified: Self.header("Last-Modified", in: http) ?? source.lastModified)
        }
        guard (200...299).contains(http.statusCode) else {
            throw DailyBriefError.httpStatus(http.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > DailyBriefLimits.maximumFeedBytes {
                throw DailyBriefError.responseTooLarge
            }
        }
        return DailyBriefTransportResponse(
            data: data,
            eTag: Self.header("ETag", in: http),
            lastModified: Self.header("Last-Modified", in: http))
    }

    private static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }
}

private final class DailyBriefRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url,
              (try? DailyBriefSourceValidator.validate(url)) != nil else { return nil }
        return request
    }
}
