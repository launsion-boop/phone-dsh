// SPDX-License-Identifier: MIT

import Foundation
import PDFKit
import PhoneDSHShell
import ProbeKit
import UIKit
import XCTest

final class OfficeTests: XCTestCase {
    func testArtifactStoreAndPDFToolsEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfficeArtifactStore(root: root)
        let pdf = try makePDF(texts: ["Invoice 120.50\nPage one", "Total 120.50\nPage two"])
        let ref = try await store.importFile(at: pdf)
        XCTAssertEqual(ref.mediaType, "application/pdf")
        XCTAssertEqual(ref.sha256.count, 64)

        let header = try await store.read(ref.artifactID, range: 0..<4)
        XCTAssertEqual(String(decoding: header, as: UTF8.self), "%PDF")
        let reloaded = OfficeArtifactStore(root: root)
        let reloadedMetadata = try await reloaded.metadata(for: ref.artifactID)
        XCTAssertEqual(reloadedMetadata, ref)

        let tools = PDFOfficeTools(store: store)
        let text = try await tools.text(artifactID: ref.artifactID)
        XCTAssertEqual(text["pageCount"] as? Int, 2)
        XCTAssertEqual(text["nextCursor"] as? NSNull, NSNull())
        let pages = try XCTUnwrap(text["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue((pages[0]["text"] as? String)?.contains("Invoice 120.50") == true)
        XCTAssertEqual(pages[1]["page"] as? Int, 2)

        let rendered = try await tools.renderPages(artifactID: ref.artifactID, pageRange: "1")
        let items = try XCTUnwrap(rendered["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["page"] as? Int, 1)
        let image = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(items[0]["base64"] as? String)))
        XCTAssertTrue(image.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertLessThanOrEqual(image.count, 180_000)

        let bridge = OfficeToolBridge(store: store)
        let listed = try await bridge.callTool(name: "phone.files.list", arguments: "{}")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [String: Any])
        let listedItems = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(object["total"] as? Int, listedItems.count)
        XCTAssertTrue(listedItems.contains { $0["fileId"] as? String == ref.artifactID })
        let unknown = try await bridge.callTool(name: "phone.not.real", arguments: "{}")
        let failure = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(unknown.utf8)) as? [String: Any])
        XCTAssertEqual(failure["ok"] as? Bool, false)
        XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? String, "unknown_tool")
    }

    func testPDFTextPaginationAndInvalidInputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfficeArtifactStore(root: root)
        let ref = try await store.importFile(at: makePDF(texts: ["abcdefghij"]))
        let tools = PDFOfficeTools(store: store)
        let first = try await tools.text(artifactID: ref.artifactID, limit: 4)
        XCTAssertEqual(first["nextCursor"] as? String, "0:4")
        let second = try await tools.text(artifactID: ref.artifactID, cursor: "0:4", limit: 50)
        let pages = try XCTUnwrap(second["pages"] as? [[String: Any]])
        XCTAssertEqual(pages[0]["text"] as? String, "efghij")
        do {
            _ = try await tools.text(artifactID: ref.artifactID, cursor: "0:99")
            XCTFail("out-of-range cursor must fail")
        } catch {
            guard case OfficeToolError.invalidRange = error else { return XCTFail("unexpected error: \(error)") }
        }
        for invalid in ["", ",", "1-2-3", "1:", "2"] {
            do {
                _ = try await tools.renderPages(artifactID: ref.artifactID, pageRange: invalid)
                XCTFail("invalid page range must fail: \(invalid)")
            } catch {
                guard case OfficeToolError.invalidArguments = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testActualScanRendering() async throws {
        guard let path = ProcessInfo.processInfo.environment["PDSH_OFFICE_FIXTURE_DIR"] else {
            throw XCTSkip("external PDF fixture directory was not supplied")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfficeArtifactStore(root: root)
        let ref = try await store.importFile(at: URL(fileURLWithPath: path).appendingPathComponent("receipt-scan.pdf"))
        let url = try await store.fileURL(for: ref.artifactID)
        _ = try XCTUnwrap(PDFDocument(url: url))
        let rendered = try await PDFOfficeTools(store: store).renderPages(artifactID: ref.artifactID, pageRange: "1")
        let items = try XCTUnwrap(rendered["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["page"] as? Int, 1)
        let image = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(items[0]["base64"] as? String)))
        XCTAssertTrue(image.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testOOXMLAndCSVReadEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = OfficeArtifactStore(root: root)
        let docxURL = root.appendingPathComponent("contract.docx")
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Termination after 30 days.</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Fee 120.50</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
          </w:body>
        </w:document>
        """
        try OfficeZIPWriter.write(entries: [
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("_rels/.rels", Data("<Relationships/>".utf8)),
            ("word/document.xml", Data(document.utf8)),
        ], to: docxURL)
        let docxRef = try await store.importFile(at: docxURL)
        let docx = try await OOXMLTools(store: store).readDOCX(artifactID: docxRef.artifactID)
        let blocks = try XCTUnwrap(docx["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["text"] as? String, "Termination after 30 days.")
        XCTAssertEqual(blocks[1]["text"] as? String, "Fee 120.50")

        let xlsxURL = root.appendingPathComponent("invoice.xlsx")
        let workbook = "<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Invoice\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        let relationships = "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\" Type=\"worksheet\"/></Relationships>"
        let shared = "<sst><si><t>Travel</t></si></sst>"
        let sheet = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\"><v>120.5</v></c><c r=\"B2\"><v>-4</v></c><c r=\"B3\"><f>SUM(B1:B2)</f><v>116.5</v></c></row></sheetData></worksheet>"
        try OfficeZIPWriter.write(entries: [
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(relationships.utf8)),
            ("xl/sharedStrings.xml", Data(shared.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ], to: xlsxURL)
        let xlsxRef = try await store.importFile(at: xlsxURL)
        let xlsx = try await OOXMLTools(store: store).readXLSX(artifactID: xlsxRef.artifactID)
        let cells = try XCTUnwrap(xlsx["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells[0]["value"] as? String, "Travel")
        XCTAssertEqual(cells[1]["value"] as? String, "120.5")
        XCTAssertEqual(cells[2]["locator"] as? String, "Invoice!B2")
        XCTAssertEqual(cells[3]["formula"] as? String, "SUM(B1:B2)")
        XCTAssertEqual(cells[3]["value"] as? String, "116.5")

        let csvURL = root.appendingPathComponent("expenses.csv")
        try Data("category,amount\ntransport,120.50\nother,-4.00\n".utf8).write(to: csvURL)
        let csvRef = try await store.importFile(at: csvURL)
        let expected = try XCTUnwrap(Decimal(string: "116.50"))
        let report = try await CSVOfficeTools(store: store).analyze(
            artifactID: csvRef.artifactID, groupBy: "category", expectedTotal: expected)
        XCTAssertEqual(report["total"] as? String, "116.5")
        XCTAssertEqual(report["rowCount"] as? Int, 2)
        XCTAssertEqual((report["anomalies"] as? [[String: Any]])?.count, 1)
        let groups = try XCTUnwrap(report["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
    }

    func testZIPCompressionZip64AndMalformedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeZIPTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("deflated.zip")
        let text = Data(String(repeating: "invoice 120.50\n", count: 100).utf8)
        try OfficeZIPWriter.write(entries: [("invoice.txt", text), ("empty.txt", Data())],
                                  to: url, compress: true)
        let reader = try OfficeZIPReader(fileURL: url)
        XCTAssertEqual(reader.entries["invoice.txt"]?.method, 8)
        XCTAssertEqual(try reader.data(named: "invoice.txt"), text)
        XCTAssertEqual(try reader.data(named: "empty.txt"), Data())
        try withZip64CentralEntry(from: url, to: root.appendingPathComponent("zip64.zip"))
        XCTAssertEqual(try OfficeZIPReader(fileURL: root.appendingPathComponent("zip64.zip"))
            .data(named: "invoice.txt"), text)

        var corrupt = try Data(contentsOf: url)
        let entry = try XCTUnwrap(reader.entries["invoice.txt"])
        let header = try Data(contentsOf: url).subdata(in: entry.localOffset..<entry.localOffset + 30)
        let dataOffset = entry.localOffset + 30 + Int(header[26]) + Int(header[27]) << 8 + Int(header[28]) + Int(header[29]) << 8
        corrupt[dataOffset] ^= 1
        try corrupt.write(to: root.appendingPathComponent("bad-crc.zip"))
        XCTAssertThrowsError(try OfficeZIPReader(fileURL: root.appendingPathComponent("bad-crc.zip"))
            .data(named: "invoice.txt"))
        corrupt = try Data(contentsOf: url)
        let central = try XCTUnwrap(corrupt.range(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound)
        corrupt[central + 8] = 1
        try corrupt.write(to: root.appendingPathComponent("encrypted.zip"))
        XCTAssertThrowsError(try OfficeZIPReader(fileURL: root.appendingPathComponent("encrypted.zip")))
        try OfficeZIPWriter.write(entries: [("safe.txt", Data("safe".utf8))],
                                  to: root.appendingPathComponent("escape.zip"))
        var escape = try Data(contentsOf: root.appendingPathComponent("escape.zip"))
        let escapedBytes = try XCTUnwrap(escape.range(of: Data("safe.txtsafe".utf8)))
        escape.replaceSubrange(escapedBytes, with: Data("../x.txt".utf8))
        try escape.write(to: root.appendingPathComponent("escape.zip"))
        XCTAssertThrowsError(try OfficeZIPReader(fileURL: root.appendingPathComponent("escape.zip")))
    }

    private func withZip64CentralEntry(from source: URL, to destination: URL) throws {
        var data = try Data(contentsOf: source)
        let central = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound)
        let nameLength = Int(data[central + 28]) | Int(data[central + 29]) << 8
        let extraOffset = central + 46 + nameLength
        var extra = Data([1, 0, 24, 0])
        for offset in [24, 20, 42] {
            let value = UInt64(UInt32(data[central + offset]) | UInt32(data[central + offset + 1]) << 8
                | UInt32(data[central + offset + 2]) << 16 | UInt32(data[central + offset + 3]) << 24)
            withUnsafeBytes(of: value.littleEndian) { extra.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32.max.littleEndian) { data.replaceSubrange(central + offset..<central + offset + 4, with: $0) }
        }
        withUnsafeBytes(of: UInt16(28).littleEndian) { data.replaceSubrange(central + 30..<central + 32, with: $0) }
        data.insert(contentsOf: extra, at: extraOffset)
        let eocd = try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards)?.lowerBound)
        let centralSize = UInt32(data[eocd + 12]) | UInt32(data[eocd + 13]) << 8
            | UInt32(data[eocd + 14]) << 16 | UInt32(data[eocd + 15]) << 24
        withUnsafeBytes(of: (centralSize + 28).littleEndian) {
            data.replaceSubrange(eocd + 12..<eocd + 16, with: $0)
        }
        try data.write(to: destination)
    }

    func testGenerationOCRDraftAndConversionStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeGenerationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfficeArtifactStore(root: root)
        let bridge = OfficeToolBridge(store: store)
        func call(_ name: String, _ arguments: String) async throws -> [String: Any] {
            let result = try await bridge.callTool(name: name, arguments: arguments)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        }
        let document = try await call("doc.write", #"{"fileName":"meeting.docx","title":"会议纪要","blocks":[{"type":"heading","text":"决议"},{"type":"paragraph","text":"总费用 116.50"},{"type":"table","rows":[["交通","120.50"],["退款","-4.00"]]}]}"#)
        let documentID = try XCTUnwrap(document["fileId"] as? String)
        let parsedDocument = try await call("docx.read", #"{"fileId":"\#(documentID)"}"#)
        let blocks = try XCTUnwrap(parsedDocument["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "tableRow" }.count, 2)
        XCTAssertTrue(blocks.contains { ($0["text"] as? String)?.contains("116.50") == true })
        let sheet = try await call("sheet.write", #"{"fileName":"expenses.xlsx","title":"费用","sheetName":"Expenses","rows":[[{"text":"category"},{"text":"amount"}],[{"text":"transport"},{"number":"120.50"}],[{"text":"other"},{"number":"-4.00"}]]}"#)
        let parsedSheet = try await call("xlsx.read", #"{"fileId":"\#(try XCTUnwrap(sheet["fileId"] as? String))"}"#)
        let cells = try XCTUnwrap(parsedSheet["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 6)
        XCTAssertEqual(cells[3]["value"] as? String, "120.5")
        XCTAssertEqual(cells[3]["locator"] as? String, "Expenses!B2")
        let slides = try await call("slides.write", #"{"fileName":"weekly.pptx","title":"Weekly","slides":[{"title":"Summary","bullets":["Total 116.50"]}]}"#)
        let slidesURL = try await store.fileURL(for: try XCTUnwrap(slides["fileId"] as? String))
        let package = try OfficeZIPReader(fileURL: slidesURL)
        XCTAssertTrue(package.entries.keys.contains("ppt/slides/slide1.xml"))
        XCTAssertTrue(XMLParser(data: try package.data(named: "ppt/slides/slide1.xml")).parse())
        let chart = try await call("chart.render", #"{"fileName":"total.png","title":"Expense Total 116.50","labels":["transport","other"],"values":["120.50","-4.00"]}"#)
        let chartID = try XCTUnwrap(chart["fileId"] as? String)
        let ocr = try await call("ocr.image", #"{"fileId":"\#(chartID)","languages":["en-US"]}"#)
        XCTAssertEqual(ocr["engine"] as? String, "Apple Vision")
        XCTAssertGreaterThan(try XCTUnwrap(ocr["lines"] as? [[String: Any]]).count, 0)
        let mail = try await call("mail.compose_draft", #"{"to":"office@example.test","subject":"Weekly 费用","body":"Total 116.50"}"#)
        XCTAssertEqual(mail["sent"] as? Bool, false)
        let mailID = try XCTUnwrap(mail["fileId"] as? String)
        let mailSize = try await store.metadata(for: mailID).byteCount
        let mailData = try await store.read(mailID, range: 0..<mailSize)
        XCTAssertTrue(String(decoding: mailData, as: UTF8.self).contains("X-Phone-DSH-Draft: true"))
        let conversion = try await call("office.convert", #"{"fileId":"\#(documentID)"}"#)
        XCTAssertEqual(conversion["status"] as? String, "BLOCKED")
        do {
            _ = try await OfficeDocumentWriter(store: store).document(
                object: ["fileName": "../bad.docx", "title": "x", "blocks": []])
            XCTFail("unsafe file names must fail")
        } catch {
            guard case OfficeToolError.invalidArguments = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testOfficeBridgeDoesNotAdvertiseUnsupportedContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeContextTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = PDSHShellProvider(materializedWorkspace: root, toolBridge: OfficeToolBridge())
        XCTAssertFalse(provider.channelAcceleratorNames.contains("ctx"), "\(provider.channelAcceleratorNames)")
        XCTAssertTrue(provider.channelAcceleratorNames.contains("phone"), "\(provider.channelAcceleratorNames)")
    }

    private func makePDF(texts: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficeFixture-\(UUID().uuidString).pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            for text in texts {
                context.beginPage()
                NSString(string: text).draw(
                    in: CGRect(x: 36, y: 36, width: 540, height: 700),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        return url
    }
}
