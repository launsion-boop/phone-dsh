// SPDX-License-Identifier: MIT

import Foundation

public actor CSVOfficeTools {
    private let store: OfficeArtifactStore

    public init(store: OfficeArtifactStore) {
        self.store = store
    }

    public func analyze(artifactID: String, amountField: String = "amount",
                        groupBy: String? = nil, expectedTotal: Decimal? = nil) async throws -> [String: Any] {
        let ref = try await store.metadata(for: artifactID)
        guard ref.byteCount <= 8 * 1024 * 1024 else {
            throw OfficeToolError.unsupported("CSV 超过 8 MiB 分析上限")
        }
        let data = try await store.read(artifactID, range: 0..<ref.byteCount)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OfficeToolError.unsupported("CSV 不是 UTF-8")
        }
        let rows = try Self.parse(text)
        guard let header = rows.first, rows.count > 1 else {
            throw OfficeToolError.invalidArguments("CSV 需要表头和至少一行数据")
        }
        guard Set(header).count == header.count,
              let amountIndex = header.firstIndex(of: amountField) else {
            throw OfficeToolError.invalidArguments("缺少金额列 \(amountField)")
        }
        let groupIndex = try groupBy.map { name -> Int in
            guard let index = header.firstIndex(of: name) else {
                throw OfficeToolError.invalidArguments("缺少分组列 \(name)")
            }
            return index
        }
        var total = Decimal.zero
        var groups: [String: Decimal] = [:]
        var anomalies: [[String: Any]] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            guard row.count == header.count else {
                throw OfficeToolError.invalidArguments("第 \(offset + 2) 行有 \(row.count) 列，应为 \(header.count) 列")
            }
            let raw = row[amountIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
                throw OfficeToolError.invalidArguments("第 \(offset + 2) 行金额无效：\(raw)")
            }
            total += amount
            let group = groupIndex.map { row[$0] } ?? "total"
            groups[group, default: Decimal.zero] += amount
            if amount < 0 {
                anomalies.append(["row": offset + 2, "amount": raw, "reason": "negative"])
            }
        }
        if let expectedTotal, total != expectedTotal {
            throw OfficeToolError.invalidArguments("合计 \(Self.decimal(total)) 与 expectedTotal \(Self.decimal(expectedTotal)) 不一致")
        }
        let orderedGroups = groups.keys.sorted().map { group -> [String: Any] in
            let sum = groups[group] ?? Decimal.zero
            var row: [String: Any] = [
                "name": group,
                "amount": Self.decimal(sum),
            ]
            if total != 0 {
                row["percent"] = Self.decimal(sum / total * 100)
            }
            return row
        }
        return [
            "fileId": artifactID,
            "rowCount": rows.count - 1,
            "amountField": amountField,
            "total": Self.decimal(total),
            "groups": orderedGroups,
            "anomalies": anomalies,
            "chart": [
                "type": "bar",
                "labels": orderedGroups.map { $0["name"] ?? "" },
                "values": orderedGroups.map { $0["amount"] ?? "0" },
            ],
        ]
    }

    private static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"",
                   let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                   next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else if character == "\"" {
                    quoted = false
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty {
                quoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                if character == "\r",
                   let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
                   next < text.endIndex, text[next] == "\n" {
                    index = next
                }
                row.append(field)
                field = ""
                if row.count > 1 || row[0].isEmpty == false { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if quoted { throw OfficeToolError.invalidArguments("CSV 引号未闭合") }
        row.append(field)
        if row.count > 1 || row[0].isEmpty == false { rows.append(row) }
        return rows
    }
}
