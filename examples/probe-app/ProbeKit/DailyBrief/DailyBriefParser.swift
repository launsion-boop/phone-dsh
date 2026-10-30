// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — ProbeKit: bounded RSS/Atom parsing.

import Foundation

public struct DailyBriefParser: Sendable {
    public init() {}

    public func parse(_ data: Data, source: DailyBriefSource) throws -> [DailyBriefItem] {
        guard !data.isEmpty else { throw DailyBriefError.invalidFeed("响应为空") }
        guard data.count <= DailyBriefLimits.maximumFeedBytes else {
            throw DailyBriefError.responseTooLarge
        }
        let delegate = DailyBriefFeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            let detail = delegate.failure ?? parser.parserError?.localizedDescription ?? "XML 格式无效"
            throw DailyBriefError.invalidFeed(detail)
        }
        guard !delegate.rows.isEmpty else { throw DailyBriefError.invalidFeed("没有找到 RSS item 或 Atom entry") }
        guard delegate.rows.count <= DailyBriefLimits.maximumItems else {
            throw DailyBriefError.invalidFeed("条目数超过 \(DailyBriefLimits.maximumItems) 上限")
        }
        return try delegate.rows.enumerated().map { offset, row in
            let title = DailyBriefPlainText.text(row.title, limit: 500)
            guard !title.isEmpty else {
                throw DailyBriefError.invalidFeed("第 \(offset + 1) 条缺少标题")
            }
            let link = DailyBriefSourceValidator.contentURL(from: row.link)
            let publishedAt = DailyBriefDates.parseFeedDate(row.published ?? row.updated)
            let summary = DailyBriefPlainText.text(
                row.summary ?? row.content ?? row.description ?? "",
                limit: DailyBriefLimits.summaryCharacters)
            return DailyBriefItem(
                id: DailyBriefIDs.item(sourceID: source.id, guid: row.guid,
                                       link: link, title: title, publishedAt: publishedAt),
                sourceID: source.id,
                sourceName: source.name,
                title: title,
                summary: summary,
                link: link,
                publishedAt: publishedAt)
        }
    }
}

public enum DailyBriefPlainText {
    public static func text(_ input: String, limit: Int) -> String {
        guard limit > 0, !input.isEmpty else { return "" }
        var output = ""
        output.reserveCapacity(min(input.count, limit * 2))
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            if input[index...].hasPrefix("<!--") {
                guard let close = input.range(of: "-->", range: input.index(index, offsetBy: 4)..<input.endIndex) else {
                    break
                }
                index = close.upperBound
                continue
            }
            if character == "<", let end = input[index...].firstIndex(of: ">") {
                let inside = input[input.index(after: index)..<end]
                let tag = inside.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    .first.map { String($0).lowercased().replacingOccurrences(of: "/", with: "") } ?? ""
                if tag == "script" || tag == "style" {
                    let closing = "</\(tag)>"
                    guard let closeRange = input.range(of: closing, options: .caseInsensitive,
                                                       range: input.index(after: end)..<input.endIndex) else {
                        break
                    }
                    index = closeRange.upperBound
                } else {
                    if Self.blockTags.contains(tag) { output.append(" ") }
                    index = input.index(after: end)
                }
                continue
            }
            output.append(character)
            index = input.index(after: index)
        }
        let collapsed = output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    private static let blockTags: Set<String> = [
        "p", "br", "div", "section", "article", "header", "footer", "li", "ul", "ol",
        "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th", "table", "blockquote",
    ]
}

private struct DailyBriefRawItem {
    var guid: String?
    var title = ""
    var link: String?
    var summary: String?
    var content: String?
    var description: String?
    var published: String?
    var updated: String?
}

private final class DailyBriefFeedDelegate: NSObject, XMLParserDelegate {
    private(set) var rows: [DailyBriefRawItem] = []
    private(set) var failure: String?
    private var current: DailyBriefRawItem?
    private var field = ""
    private var buffer = ""
    private var atomLink: (href: String, rel: String)?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" || elementName == "entry" {
            current = DailyBriefRawItem()
            field = ""
            buffer = ""
            atomLink = nil
            return
        }
        guard current != nil else { return }
        field = elementName
        buffer = ""
        if elementName == "link", let href = attributeDict["href"], !href.isEmpty {
            atomLink = (href, attributeDict["rel"] ?? "alternate")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil, !field.isEmpty else { return }
        buffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" || elementName == "entry" {
            if var current {
                if current.link == nil, let atomLink, atomLink.rel == "alternate" {
                    current.link = atomLink.href
                }
                rows.append(current)
            }
            current = nil
            field = ""
            buffer = ""
            atomLink = nil
            return
        }
        guard var current, field == elementName else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "id", "guid": current.guid = value
        case "title": current.title = value
        case "link":
            if !value.isEmpty {
                current.link = value
            } else if let atomLink, atomLink.rel == "alternate" {
                current.link = atomLink.href
            }
        case "summary", "subtitle": current.summary = value
        case "description": current.description = value
        case "content", "content:encoded": current.content = value
        case "published", "pubDate", "date": current.published = value
        case "updated": current.updated = value
        default: break
        }
        self.current = current
        field = ""
        buffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failure = parseError.localizedDescription
    }
}

public enum DailyBriefFeedDates {
    public static func parse(_ value: String?) -> Date? {
        DailyBriefDates.parseFeedDate(value)
    }
}

extension DailyBriefDates {
    static func parseFeedDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
