// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHShell

public final class OfficeToolBridge: PhoneToolBridge, @unchecked Sendable {
    public let supportsContext = false
    public let handles: Set<String> = [
        "files.list", "files.pick", "doc.preview", "share.export", "pdf.text",
        "pdf.render_pages", "docx.read", "xlsx.read", "csv.analyze", "doc.write",
        "sheet.write", "slides.write", "chart.render", "ocr.image", "mail.compose_draft",
        "calendar.create_event", "contacts.search", "text.translate", "office.convert",
    ]

    private let store: OfficeArtifactStore
    private let presenter: (any OfficePresenting)?
    private let pdfTools: PDFOfficeTools
    private let ooxmlTools: OOXMLTools
    private let csvTools: CSVOfficeTools
    private let writer: OfficeDocumentWriter
    private let imageTools: OfficeImageTools
    private let systemTools: OfficeSystemTools

    public init(store: OfficeArtifactStore = .shared,
                presenter: (any OfficePresenting)? = nil) {
        self.store = store
        self.presenter = presenter
        self.pdfTools = PDFOfficeTools(store: store)
        self.ooxmlTools = OOXMLTools(store: store)
        self.csvTools = CSVOfficeTools(store: store)
        self.writer = OfficeDocumentWriter(store: store)
        self.imageTools = OfficeImageTools(store: store)
        self.systemTools = OfficeSystemTools(store: store, presenter: presenter)
    }

    public func callTool(name: String, arguments: String) async throws -> String {
        do {
            return try await route(name: name, arguments: arguments)
        } catch let error as OfficeToolError {
            return try OfficeJSON.failure(tool: name, error: error)
        } catch {
            return try OfficeJSON.string([
                "ok": false,
                "tool": name,
                "error": ["code": "unavailable", "message": "办公工具暂时不可用"],
            ])
        }
    }

    private func route(name: String, arguments: String) async throws -> String {
        #if DEBUG
        await OfficeFixtureInstaller.installIfNeeded(store: store)
        #endif
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        let object = try OfficeJSON.object(Data(arguments.utf8))
        switch tool {
        case "files.list":
            let page = try await store.list(
                cursor: try OfficeJSON.int(object, "cursor", default: 0, minimum: 0),
                limit: try OfficeJSON.int(object, "limit", default: 20,
                                          minimum: 1, maximum: OfficeLimits.maximumPageItems))
            return try OfficeJSON.string([
                "items": page.items.map(Self.reference),
                "nextCursor": page.nextCursor ?? NSNull(),
                "total": page.total,
            ])
        case "files.pick":
            guard let presenter else { throw OfficeToolError.unavailable("文件选择器不可用") }
            let urls = try await presenter.pickDocuments()
            var items: [[String: Any]] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let ref = try await store.importFile(at: url)
                items.append(Self.reference(ref))
            }
            return try OfficeJSON.string(["items": items])
        case "doc.preview":
            guard let presenter else { throw OfficeToolError.unavailable("Quick Look 不可用") }
            let artifactID = try requiredArtifactID(object)
            _ = try await store.metadata(for: artifactID)
            let url = try await store.fileURL(for: artifactID)
            try await presenter.preview(url)
            return try OfficeJSON.string(["fileId": artifactID, "status": "dismissed"])
        case "share.export":
            guard let presenter else { throw OfficeToolError.unavailable("系统分享不可用") }
            let artifactID = try requiredArtifactID(object)
            _ = try await store.metadata(for: artifactID)
            let url = try await store.fileURL(for: artifactID)
            let status = try await presenter.share(url)
            return try OfficeJSON.string(["fileId": artifactID, "status": status])
        case "pdf.text":
            return try OfficeJSON.string(await pdfTools.text(
                artifactID: try requiredArtifactID(object),
                cursor: try OfficeJSON.string(object, "cursor", required: false) ?? "0:0",
                limit: try OfficeJSON.int(object, "limit", default: 12_000,
                                          minimum: 1, maximum: 50_000)))
        case "pdf.render_pages":
            return try OfficeJSON.string(await pdfTools.renderPages(
                artifactID: try requiredArtifactID(object),
                pageRange: try OfficeJSON.string(object, "pageRange", required: false) ?? "1",
                maximumDimension: try OfficeJSON.int(object, "maximumDimension", default: 1024,
                                                     minimum: 256, maximum: 2048),
                imageBudget: try OfficeJSON.int(object, "imageBudget", default: 1,
                                                minimum: 1, maximum: 4),
                maximumBytes: try OfficeJSON.int(object, "maximumBytes", default: 180_000,
                                                 minimum: 16_384, maximum: 180_000)))
        case "docx.read":
            return try OfficeJSON.string(await ooxmlTools.readDOCX(
                artifactID: try requiredArtifactID(object)))
        case "xlsx.read":
            return try OfficeJSON.string(await ooxmlTools.readXLSX(
                artifactID: try requiredArtifactID(object)))
        case "csv.analyze":
            let expectedText = try OfficeJSON.string(object, "expectedTotal", required: false)
            let expected = expectedText.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            if expectedText != nil && expected == nil {
                throw OfficeToolError.invalidArguments("expectedTotal 不是有效金额")
            }
            return try OfficeJSON.string(await csvTools.analyze(
                artifactID: try requiredArtifactID(object),
                amountField: try OfficeJSON.string(object, "amountField", required: false) ?? "amount",
                groupBy: try OfficeJSON.string(object, "groupBy", required: false),
                expectedTotal: expected))
        case "doc.write":
            return try OfficeJSON.string(Self.reference(await writer.document(object: object)))
        case "sheet.write":
            return try OfficeJSON.string(Self.reference(await writer.sheet(object: object)))
        case "slides.write":
            return try OfficeJSON.string(Self.reference(await writer.slides(object: object)))
        case "chart.render":
            return try OfficeJSON.string(Self.reference(await imageTools.chart(object: object)))
        case "ocr.image":
            let languages = (object["languages"] as? [String]) ?? []
            guard languages.count <= 5, languages.allSatisfy({ $0.count <= 20 }) else {
                throw OfficeToolError.invalidArguments("languages 最多 5 个语言标识")
            }
            return try OfficeJSON.string(await imageTools.ocr(
                artifactID: try requiredArtifactID(object), languages: languages))
        case "mail.compose_draft":
            return try OfficeJSON.string(await systemTools.mailDraft(object: object))
        case "calendar.create_event":
            return try OfficeJSON.string(await systemTools.createCalendarEvent(object: object))
        case "contacts.search":
            return try OfficeJSON.string(await systemTools.searchContacts(object: object))
        case "text.translate":
            return try OfficeJSON.string(await systemTools.translate(object: object))
        case "office.convert":
            return try OfficeJSON.string([
                "status": "BLOCKED",
                "reason": "云端 LibreOffice 转换服务未配置；Quick Look 预览不能冒充交付级转换",
            ])
        default:
            throw OfficeToolError.unknownTool(tool)
        }
    }

    private func requiredArtifactID(_ object: [String: Any]) throws -> String {
        guard let artifactID = try OfficeJSON.string(object, "fileId") else {
            throw OfficeToolError.invalidArguments("fileId 不能为空")
        }
        guard artifactID.hasPrefix("art_"), artifactID.count <= 128 else {
            throw OfficeToolError.invalidArguments("fileId 格式无效")
        }
        return artifactID
    }

    private static func reference(_ ref: OfficeArtifactRef) -> [String: Any] {
        [
            "fileId": ref.artifactID,
            "version": ref.version,
            "sha256": ref.sha256,
            "mediaType": ref.mediaType,
            "byteCount": ref.byteCount,
            "name": ref.name,
        ]
    }
}
