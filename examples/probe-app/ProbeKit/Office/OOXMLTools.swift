// SPDX-License-Identifier: MIT

import Foundation

public actor OOXMLTools {
    private let store: OfficeArtifactStore

    public init(store: OfficeArtifactStore) {
        self.store = store
    }

    public func readDOCX(artifactID: String) async throws -> [String: Any] {
        _ = try await store.metadata(for: artifactID)
        let url = try await store.fileURL(for: artifactID)
        let package = try OfficeZIPReader(fileURL: url)
        let shared = try Self.sharedStrings(package)
        let data = try package.data(named: "word/document.xml")
        let parser = DOCXBodyParser(sharedStrings: shared)
        guard parser.parse(data) else { throw OfficeToolError.unsupported("DOCX document.xml 解析失败") }
        return ["fileId": artifactID, "blocks": parser.blocks, "count": parser.blocks.count]
    }

    public func readXLSX(artifactID: String) async throws -> [String: Any] {
        _ = try await store.metadata(for: artifactID)
        let url = try await store.fileURL(for: artifactID)
        let package = try OfficeZIPReader(fileURL: url)
        let shared = try Self.sharedStrings(package)
        let workbookData = try package.data(named: "xl/workbook.xml")
        let workbook = XLSXWorkbookParser()
        guard workbook.parse(workbookData) else { throw OfficeToolError.unsupported("XLSX workbook.xml 解析失败") }
        let relationships = XLSXRelationshipParser()
        guard relationships.parse(try package.data(named: "xl/_rels/workbook.xml.rels")) else {
            throw OfficeToolError.unsupported("XLSX 工作表关系解析失败")
        }
        var cells: [[String: Any]] = []
        for sheet in workbook.sheets {
            guard let target = relationships.targets[sheet.relationshipID] else {
                throw OfficeToolError.unsupported("工作表 \(sheet.name) 缺少关系目标")
            }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/\(target)"
            let parser = XLSXWorksheetParser(sheet: sheet.name, sharedStrings: shared)
            guard parser.parse(try package.data(named: path)) else {
                throw OfficeToolError.unsupported("工作表 \(sheet.name) 解析失败")
            }
            cells.append(contentsOf: parser.cells)
            guard cells.count <= 10_000 else { throw OfficeToolError.unsupported("单元格超过 10000 个上限") }
        }
        return ["fileId": artifactID, "sheets": workbook.sheets.map(\.name),
                "cells": cells, "count": cells.count]
    }

    private static func sharedStrings(_ package: OfficeZIPReader) throws -> [String] {
        guard package.entries["xl/sharedStrings.xml"] != nil else { return [] }
        let parser = OOXMLSharedStringsParser()
        guard parser.parse(try package.data(named: "xl/sharedStrings.xml")) else {
            throw OfficeToolError.unsupported("sharedStrings.xml 解析失败")
        }
        return parser.strings
    }
}

private struct XLSXSheet {
    let name: String
    let relationshipID: String
}

private final class OOXMLSharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var current = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "si" { strings.append(current) }
    }
}

private final class DOCXBodyParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var paragraphIndex = 0
    private var tableRowIndex = 0
    private var currentText = ""
    private var currentCell: String?
    private var currentRow: [String]?
    private var inTable = false
    private(set) var blocks: [[String: Any]] = []

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
        super.init()
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "p":
            currentText = ""
            if currentCell == nil, !inTable { paragraphIndex += 1 }
        case "tbl":
            inTable = true
        case "tr":
            currentRow = []
            tableRowIndex += 1
        case "tc":
            currentCell = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "tab":
            currentText += "\t"
        case "br", "cr":
            currentText += "\n"
        case "p":
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentCell != nil {
                currentCell = text
            } else if !inTable, !text.isEmpty {
                blocks.append(["type": "paragraph", "locator": "paragraph \(paragraphIndex)", "text": text])
            }
            currentText = ""
        case "tc":
            if let cell = currentCell { currentRow?.append(cell) }
            currentCell = nil
        case "tr":
            if let row = currentRow {
                blocks.append(["type": "tableRow", "locator": "table row \(tableRowIndex)",
                               "cells": row, "text": row.joined(separator: " | ")])
            }
            currentRow = nil
        case "tbl":
            inTable = false
        default:
            break
        }
    }
}

private final class XLSXWorkbookParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [XLSXSheet] = []

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet", let name = attributeDict["name"],
              let relationshipID = attributeDict.first(where: { $0.key == "id" || $0.key.hasSuffix(":id") })?.value else { return }
        sheets.append(XLSXSheet(name: name, relationshipID: relationshipID))
    }
}

private final class XLSXRelationshipParser: NSObject, XMLParserDelegate {
    private(set) var targets: [String: String] = [:]

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship", let id = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        targets[id] = target
    }
}

private final class XLSXWorksheetParser: NSObject, XMLParserDelegate {
    private let sheet: String
    private let sharedStrings: [String]
    private var reference = ""
    private var type = "n"
    private var value = ""
    private var formula = ""
    private var inline = ""
    private var textElement = ""
    private(set) var cells: [[String: Any]] = []

    init(sheet: String, sharedStrings: [String]) {
        self.sheet = sheet
        self.sharedStrings = sharedStrings
        super.init()
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "c" {
            reference = attributeDict["r"] ?? ""
            type = attributeDict["t"] ?? "n"
            value = ""
            formula = ""
            inline = ""
            textElement = ""
        } else if ["v", "f", "is", "t"].contains(elementName) {
            textElement = elementName
            if elementName == "v" { value = "" }
            if elementName == "f" { formula = "" }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch textElement {
        case "v": value += string
        case "f": formula += string
        case "is", "t": inline += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if ["v", "f", "is", "t"].contains(elementName) { textElement = "" }
        guard elementName == "c" else { return }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered: String
        switch type {
        case "s":
            rendered = Int(raw).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? ""
        case "b":
            rendered = raw == "1" ? "TRUE" : "FALSE"
        case "inlineStr":
            rendered = inline.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            rendered = raw
        }
        var cell: [String: Any] = [
            "sheet": sheet,
            "locator": "\(sheet)!\(reference)",
            "cell": reference,
            "type": type,
            "value": rendered,
        ]
        if !formula.isEmpty { cell["formula"] = formula }
        cells.append(cell)
    }
}
