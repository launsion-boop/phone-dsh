// SPDX-License-Identifier: MIT

import Foundation

struct OfficeDocumentIR: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
        let rows: [[String]]?
    }
    let fileName: String
    let title: String
    let blocks: [Block]

    func validated() throws {
        try OfficeIR.fileName(fileName, extension: "docx")
        try OfficeIR.text(title, limit: 200, label: "title")
        guard blocks.count <= 200 else { throw OfficeToolError.invalidArguments("文档块超过 200") }
        for block in blocks {
            switch block.type {
            case "heading", "paragraph":
                guard block.rows == nil, let text = block.text else {
                    throw OfficeToolError.invalidArguments("文本块需要 text，不能有 rows")
                }
                try OfficeIR.text(text, limit: 4000, label: "block.text")
            case "table":
                guard block.text == nil, let rows = block.rows, !rows.isEmpty, rows.count <= 50 else {
                    throw OfficeToolError.invalidArguments("表格需要 1...50 行")
                }
                guard let width = rows.first?.count, width > 0, width <= 8,
                      rows.allSatisfy({ $0.count == width }) else {
                    throw OfficeToolError.invalidArguments("表格每行需要相同的 1...8 列")
                }
                for value in rows.flatMap({ $0 }) { try OfficeIR.text(value, limit: 256, label: "table.text") }
            default:
                throw OfficeToolError.invalidArguments("文档块类型不支持：\(block.type)")
            }
        }
    }
}

struct OfficeSheetIR: Decodable {
    struct Cell: Decodable {
        let text: String?
        let number: String?
    }
    let fileName: String
    let title: String
    let sheetName: String?
    let rows: [[Cell]]

    func validated() throws {
        try OfficeIR.fileName(fileName, extension: "xlsx")
        try OfficeIR.text(title, limit: 200, label: "title")
        if let sheetName { try OfficeIR.text(sheetName, limit: 31, label: "sheetName") }
        guard !rows.isEmpty, rows.count <= 1000 else {
            throw OfficeToolError.invalidArguments("工作表需要 1...1000 行")
        }
        guard let width = rows.first?.count, width > 0, width <= 26,
              rows.allSatisfy({ $0.count == width }), rows.count * width <= 10_000 else {
            throw OfficeToolError.invalidArguments("工作表需要相同列数，最多 26 列/10000 单元格")
        }
        for cell in rows.flatMap({ $0 }) {
            switch (cell.text, cell.number) {
            case (let text?, nil): try OfficeIR.text(text, limit: 4000, label: "cell.text")
            case (nil, let number?): _ = try OfficeIR.number(number)
            default: throw OfficeToolError.invalidArguments("单元格必须且只能有 text 或 number")
            }
        }
    }
}

struct OfficeSlidesIR: Decodable {
    struct Slide: Decodable {
        let title: String
        let bullets: [String]
    }
    let fileName: String
    let title: String
    let slides: [Slide]

    func validated() throws {
        try OfficeIR.fileName(fileName, extension: "pptx")
        try OfficeIR.text(title, limit: 200, label: "title")
        guard !slides.isEmpty, slides.count <= 30 else {
            throw OfficeToolError.invalidArguments("幻灯片需要 1...30 页")
        }
        for slide in slides {
            try OfficeIR.text(slide.title, limit: 200, label: "slide.title")
            guard slide.bullets.count <= 12 else { throw OfficeToolError.invalidArguments("每页最多 12 条") }
            for bullet in slide.bullets { try OfficeIR.text(bullet, limit: 500, label: "bullet") }
        }
    }
}

struct OfficeChartIR: Decodable {
    let fileName: String
    let title: String
    let labels: [String]
    let values: [String]

    func validated() throws {
        try OfficeIR.fileName(fileName, extension: "png")
        try OfficeIR.text(title, limit: 200, label: "title")
        guard !labels.isEmpty, labels.count <= 16, labels.count == values.count else {
            throw OfficeToolError.invalidArguments("图表 labels/values 需要相同的 1...16 项")
        }
        for label in labels { try OfficeIR.text(label, limit: 60, label: "label") }
        for value in values { _ = try OfficeIR.number(value) }
    }
}

enum OfficeIR {
    static func decode<T: Decodable>(_ type: T.Type, object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 128 * 1024 else { throw OfficeToolError.resultTooLarge }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OfficeToolError.invalidArguments("IR 不符合结构化类型：\(error.localizedDescription)")
        }
    }

    static func text(_ value: String, limit: Int, label: String) throws {
        guard !value.isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OfficeToolError.invalidArguments("\(label) 需要 1...\(limit) 个有效字符")
        }
    }

    static func number(_ raw: String) throws -> Decimal {
        guard let number = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !number.isNaN, number.isFinite,
              abs(NSDecimalNumber(decimal: number).doubleValue) <= 1_000_000_000_000 else {
            throw OfficeToolError.invalidArguments("数值无效或超出范围：\(raw)")
        }
        return number
    }

    static func fileName(_ raw: String, extension suffix: String) throws {
        guard raw.count <= 80, raw != ".", raw != "..", raw.hasSuffix(".\(suffix)"),
              !raw.contains("/"), !raw.contains("\\"), !raw.contains(":"),
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw OfficeToolError.invalidArguments("文件名需要安全且以 .\(suffix) 结尾")
        }
    }

    static func xml(_ raw: String) -> String {
        var value = ""
        value.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": value += "&amp;"
            case "<": value += "&lt;"
            case ">": value += "&gt;"
            case "\"": value += "&quot;"
            case "'": value += "&apos;"
            default:
                if scalar.value == 9 || scalar.value == 10 || scalar.value == 13
                    || (scalar.value >= 32 && scalar.value != 0xFFFE && scalar.value != 0xFFFF) {
                    value.unicodeScalars.append(scalar)
                }
            }
        }
        return value
    }
}
