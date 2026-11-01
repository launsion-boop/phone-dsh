// SPDX-License-Identifier: MIT

import Foundation
import PDFKit
import UIKit

public actor PDFOfficeTools {
    private let store: OfficeArtifactStore
    private var renderedCache: [String: Data] = [:]
    private var renderedCacheOrder: [String] = []

    public init(store: OfficeArtifactStore) {
        self.store = store
    }

    public func text(artifactID: String, cursor: String = "0:0",
                     limit: Int = 12_000) async throws -> [String: Any] {
        guard limit > 0, limit <= 50_000 else {
            throw OfficeToolError.invalidArguments("limit 必须在 1...50000")
        }
        let position = try Self.cursor(cursor)
        let ref = try await store.metadata(for: artifactID)
        guard ref.mediaType == "application/pdf" else {
            throw OfficeToolError.unsupported("pdf.text 只接受 application/pdf")
        }
        let url = try await store.fileURL(for: artifactID)
        guard let document = PDFDocument(url: url) else {
            throw OfficeToolError.unavailable("PDF 无法打开")
        }
        guard !document.isEncrypted else {
            throw OfficeToolError.unsupported("加密 PDF 需要先解锁")
        }
        var remaining = limit
        var pages: [[String: Any]] = []
        var nextCursor: String?
        for index in position.page..<document.pageCount {
            guard remaining > 0 else { nextCursor = "\(index):0"; break }
            guard let page = document.page(at: index) else {
                throw OfficeToolError.unavailable("PDF 第 \(index + 1) 页无法读取")
            }
            let fullText = page.string ?? ""
            let start = index == position.page ? position.offset : 0
            guard start <= fullText.count else {
                throw OfficeToolError.invalidRange("cursor 超出第 \(index + 1) 页文本长度")
            }
            let startIndex = fullText.index(fullText.startIndex, offsetBy: start)
            let endIndex = fullText.index(startIndex, offsetBy: min(remaining, fullText.distance(from: startIndex, to: fullText.endIndex)))
            let text = String(fullText[startIndex..<endIndex])
            if !text.isEmpty {
                pages.append(["page": index + 1, "text": text])
            }
            remaining -= text.count
            if endIndex < fullText.endIndex {
                nextCursor = "\(index):\(fullText.distance(from: fullText.startIndex, to: endIndex))"
                break
            }
            if index + 1 < document.pageCount, remaining == 0 {
                nextCursor = "\(index + 1):0"
                break
            }
        }
        return [
            "fileId": artifactID,
            "pageCount": document.pageCount,
            "pages": pages,
            "nextCursor": nextCursor ?? NSNull(),
            "notFound": pages.isEmpty,
        ]
    }

    public func renderPages(artifactID: String, pageRange: String,
                            maximumDimension: Int = 1024,
                            imageBudget: Int = 1,
                            maximumBytes: Int = 180_000) async throws -> [String: Any] {
        guard (256...2048).contains(maximumDimension),
              (1...4).contains(imageBudget),
              (16_384...180_000).contains(maximumBytes) else {
            throw OfficeToolError.invalidArguments("图片预算超出允许范围")
        }
        let ref = try await store.metadata(for: artifactID)
        guard ref.mediaType == "application/pdf" else {
            throw OfficeToolError.unsupported("pdf.render_pages 只接受 application/pdf")
        }
        let url = try await store.fileURL(for: artifactID)
        guard let document = PDFDocument(url: url) else {
            throw OfficeToolError.unavailable("PDF 无法打开")
        }
        guard !document.isEncrypted else {
            throw OfficeToolError.unsupported("加密 PDF 需要先解锁")
        }
        let pages = try Self.pageIndices(pageRange, pageCount: document.pageCount)
        guard pages.count <= imageBudget else {
            throw OfficeToolError.invalidArguments("本次最多渲染 \(imageBudget) 页，请缩小 pageRange")
        }
        let perImageBytes = maximumBytes / imageBudget
        var items: [[String: Any]] = []
        for index in pages {
            guard let page = document.page(at: index) else {
                throw OfficeToolError.unavailable("PDF 第 \(index + 1) 页无法读取")
            }
            let key = "\(ref.sha256):\(index):\(maximumDimension):\(perImageBytes)"
            let data = try renderedCache[key] ?? render(page, maximumDimension: maximumDimension,
                                                        maximumBytes: perImageBytes, cacheKey: key)
            items.append([
                "page": index + 1,
                "mediaType": "image/png",
                "byteCount": data.count,
                "base64": data.base64EncodedString(),
                "sourceHash": ref.sha256,
                "renderPolicy": "maxDimension=\(maximumDimension),maxAggregateBytes=180000",
            ])
        }
        return ["fileId": artifactID, "items": items, "pageCount": document.pageCount]
    }

    private func render(_ page: PDFPage, maximumDimension: Int,
                        maximumBytes: Int, cacheKey: String) throws -> Data {
        var dimension = maximumDimension
        while dimension >= 64 {
            let bounds = page.bounds(for: .cropBox)
            let scale = min(1, CGFloat(dimension) / max(bounds.width, bounds.height))
            let size = CGSize(width: max(1, floor(bounds.width * scale)),
                              height: max(1, floor(bounds.height * scale)))
            let image = page.thumbnail(of: size, for: .cropBox)
            if let data = image.pngData(), data.count <= maximumBytes {
                if renderedCache[cacheKey] == nil { renderedCacheOrder.append(cacheKey) }
                renderedCache[cacheKey] = data
                if renderedCacheOrder.count > 16, let expired = renderedCacheOrder.first {
                    renderedCacheOrder.removeFirst()
                    renderedCache[expired] = nil
                }
                return data
            }
            dimension = Int(Double(dimension) * 0.75)
        }
        throw OfficeToolError.resultTooLarge
    }

    private static func cursor(_ raw: String) throws -> (page: Int, offset: Int) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let page = Int(parts[0]), let offset = Int(parts[1]),
              page >= 0, offset >= 0 else {
            throw OfficeToolError.invalidArguments("cursor 必须形如 0:0")
        }
        return (page, offset)
    }

    private static func pageIndices(_ raw: String, pageCount: Int) throws -> [Int] {
        if raw == "*" { return Array(0..<pageCount) }
        var indices: Set<Int> = []
        guard pageCount > 0, !raw.isEmpty else {
            throw OfficeToolError.invalidArguments("pageRange 超出空 PDF")
        }
        for component in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = component.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count <= 2, let first = Int(bounds[0]), first >= 1 else {
                throw OfficeToolError.invalidArguments("pageRange 必须形如 1,2 或 1-3")
            }
            let last = bounds.count == 2 ? Int(bounds[1]) : first
            guard let last, last >= first, last <= pageCount else {
                throw OfficeToolError.invalidArguments("pageRange 超出 1...\(pageCount)")
            }
            indices.formUnion((first - 1)...(last - 1))
        }
        return indices.sorted()
    }
}
