// SPDX-License-Identifier: MIT

import Foundation

public actor OfficeDocumentWriter {
    private let store: OfficeArtifactStore

    public init(store: OfficeArtifactStore) {
        self.store = store
    }

    public func document(object: [String: Any]) async throws -> OfficeArtifactRef {
        let ir = try OfficeIR.decode(OfficeDocumentIR.self, object: object)
        try ir.validated()
        var body = ""
        for block in ir.blocks {
            switch block.type {
            case "heading": body += paragraph(block.text ?? "", style: "Heading1")
            case "paragraph": body += paragraph(block.text ?? "")
            case "table": body += table(block.rows ?? [])
            default: throw OfficeToolError.invalidArguments("未知文档块")
            }
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body></w:document>
        """
        return try await makeFile(named: ir.fileName, entries: [
            ("[Content_Types].xml", Data(Self.types("""
                <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
                <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
                """).utf8)),
            ("_rels/.rels", Data(Self.rootRelationships(target: "word/document.xml").utf8)),
            ("word/document.xml", Data(xml.utf8)),
            ("word/styles.xml", Data("""
                <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:eastAsia="PingFang SC"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:styleId="Normal"><w:name w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style></w:styles>
                """.utf8)),
            ("docProps/core.xml", Data(Self.coreProperties(title: ir.title).utf8)),
        ])
    }

    public func sheet(object: [String: Any]) async throws -> OfficeArtifactRef {
        let ir = try OfficeIR.decode(OfficeSheetIR.self, object: object)
        try ir.validated()
        let rows = try ir.rows.enumerated().map { rowIndex, row in
            let cells = try row.enumerated().map { columnIndex, cell in
                let reference = "\(Self.column(columnIndex + 1))\(rowIndex + 1)"
                if let text = cell.text {
                    return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(OfficeIR.xml(text))</t></is></c>"
                }
                let value = try OfficeIR.number(cell.number ?? "")
                return "<c r=\"\(reference)\"><v>\(NSDecimalNumber(decimal: value).stringValue)</v></c>"
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }.joined()
        let name = ir.sheetName ?? "Sheet1"
        return try await makeFile(named: ir.fileName, entries: [
            ("[Content_Types].xml", Data(Self.types("""
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
                """).utf8)),
            ("_rels/.rels", Data(Self.rootRelationships(target: "xl/workbook.xml").utf8)),
            ("xl/workbook.xml", Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"\(OfficeIR.xml(name))\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>".utf8)),
            ("docProps/core.xml", Data(Self.coreProperties(title: ir.title).utf8)),
        ])
    }

    public func slides(object: [String: Any]) async throws -> OfficeArtifactRef {
        let ir = try OfficeIR.decode(OfficeSlidesIR.self, object: object)
        try ir.validated()
        var entries: [(name: String, data: Data)] = []
        var overrides = """
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
            """
        var slideReferences = ""
        var presentationRelationships = ""
        for (index, slide) in ir.slides.enumerated() {
            let number = index + 1
            overrides += "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            slideReferences += "<p:sldId id=\"\(255 + number)\" r:id=\"rId\(number)\"/>"
            presentationRelationships += Self.relationship(id: "rId\(number)", type: "slide", target: "slides/slide\(number).xml")
            let bullets = slide.bullets.map { "<a:p><a:pPr marL=\"285750\" indent=\"-285750\"><a:buChar char=\"•\"/></a:pPr><a:r><a:rPr lang=\"zh-CN\" sz=\"2400\"/><a:t>\(OfficeIR.xml($0))</a:t></a:r></a:p>" }.joined()
            let xml = """
                <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
                \(Self.textShape(id: 2, name: "Title", text: OfficeIR.xml(slide.title), x: 685800, y: 548640, cx: 7772400, cy: 914400, size: 3600, bold: true))
                \(Self.textShape(id: 3, name: "Content", text: bullets, x: 685800, y: 1828800, cx: 7772400, cy: 3657600, size: 2400, bold: false, paragraphs: true))
                </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """
            entries.append(("ppt/slides/slide\(number).xml", Data(xml.utf8)))
            entries.append(("ppt/slides/_rels/slide\(number).xml.rels", Data(Self.relationships(Self.relationship(id: "rId1", type: "slideLayout", target: "../slideLayouts/slideLayout1.xml")).utf8)))
        }
        presentationRelationships += Self.relationship(id: "rId\(ir.slides.count + 1)", type: "slideMaster", target: "slideMasters/slideMaster1.xml")
        entries.append(("[Content_Types].xml", Data(Self.types(overrides).utf8)))
        entries.append(("_rels/.rels", Data(Self.rootRelationships(target: "ppt/presentation.xml").utf8)))
        entries.append(("ppt/presentation.xml", Data("<p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId\(ir.slides.count + 1)\"/></p:sldMasterIdLst><p:sldIdLst>\(slideReferences)</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\" type=\"screen4x3\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>".utf8)))
        entries.append(("ppt/_rels/presentation.xml.rels", Data(Self.relationships(presentationRelationships).utf8)))
        entries.append(("ppt/slideMasters/slideMaster1.xml", Data(Self.slideMaster.utf8)))
        entries.append(("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(Self.relationships(Self.relationship(id: "rId1", type: "slideLayout", target: "../slideLayouts/slideLayout1.xml") + Self.relationship(id: "rId2", type: "theme", target: "../theme/theme1.xml")).utf8)))
        entries.append(("ppt/slideLayouts/slideLayout1.xml", Data(Self.slideLayout.utf8)))
        entries.append(("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(Self.relationships(Self.relationship(id: "rId1", type: "slideMaster", target: "../slideMasters/slideMaster1.xml")).utf8)))
        entries.append(("ppt/theme/theme1.xml", Data(Self.theme.utf8)))
        entries.append(("docProps/core.xml", Data(Self.coreProperties(title: ir.title).utf8)))
        return try await makeFile(named: ir.fileName, entries: entries)
    }

    private func makeFile(named name: String,
                          entries: [(name: String, data: Data)]) async throws -> OfficeArtifactRef {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try OfficeZIPWriter.write(entries: entries, to: url, compress: true)
        return try await store.importFile(at: url)
    }

    private func paragraph(_ text: String, style: String? = nil) -> String {
        let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p>\(properties)<w:r><w:t xml:space=\"preserve\">\(OfficeIR.xml(text))</w:t></w:r></w:p>"
    }

    private func table(_ rows: [[String]]) -> String {
        let width = 9000 / max(1, rows[0].count)
        let grid = rows[0].map { _ in "<w:gridCol w:w=\"\(width)\"/>" }.joined()
        let content = rows.map { row in
            "<w:tr>" + row.map { "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>\(paragraph($0))</w:tc>" }.joined() + "</w:tr>"
        }.joined()
        return "<w:tbl><w:tblPr><w:tblW w:w=\"9000\" w:type=\"dxa\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\"/><w:left w:val=\"single\" w:sz=\"4\"/><w:bottom w:val=\"single\" w:sz=\"4\"/><w:right w:val=\"single\" w:sz=\"4\"/><w:insideH w:val=\"single\" w:sz=\"4\"/><w:insideV w:val=\"single\" w:sz=\"4\"/></w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(content)</w:tbl>"
    }

    private static func column(_ number: Int) -> String {
        var value = number
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + (value % 26))!) + result
            value /= 26
        }
        return result
    }

    private static func types(_ overrides: String) -> String {
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>" + overrides + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"
    }

    private static func rootRelationships(target: String) -> String {
        relationships(relationship(id: "rId1", type: "officeDocument", target: target) + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>")
    }

    private static func relationships(_ body: String) -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>"
    }

    private static func relationship(id: String, type: String, target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)\" Target=\"\(target)\"/>"
    }

    private static func coreProperties(title: String) -> String {
        "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(OfficeIR.xml(title))</dc:title><dc:creator>Phone DSH</dc:creator></cp:coreProperties>"
    }

    private static func textShape(id: Int, name: String, text: String, x: Int, y: Int,
                                  cx: Int, cy: Int, size: Int, bold: Bool, paragraphs: Bool = false) -> String {
        let content = paragraphs ? text : "<a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"\(size)\"\(bold ? " b=\"1\"" : "")/><a:t>\(text)</a:t></a:r></a:p>"
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\"/><a:lstStyle/>\(content)</p:txBody></p:sp>"
    }

    private static let slideMaster = "<p:sldMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz=\"3600\"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz=\"2400\"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz=\"1800\"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"
    private static let slideLayout = "<p:sldLayout xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
    private static let theme = "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Phone DSH\"><a:themeElements><a:clrScheme name=\"Phone DSH\"><a:dk1><a:srgbClr val=\"111114\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"333333\"/></a:dk2><a:lt2><a:srgbClr val=\"F5F5F5\"/></a:lt2><a:accent1><a:srgbClr val=\"2874A6\"/></a:accent1><a:accent2><a:srgbClr val=\"2874A6\"/></a:accent2><a:accent3><a:srgbClr val=\"2874A6\"/></a:accent3><a:accent4><a:srgbClr val=\"2874A6\"/></a:accent4><a:accent5><a:srgbClr val=\"2874A6\"/></a:accent5><a:accent6><a:srgbClr val=\"2874A6\"/></a:accent6><a:hlink><a:srgbClr val=\"2874A6\"/></a:hlink><a:folHlink><a:srgbClr val=\"666666\"/></a:folHlink></a:clrScheme><a:fontScheme name=\"Phone DSH\"><a:majorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"PingFang SC\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"PingFang SC\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Phone DSH\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
}
