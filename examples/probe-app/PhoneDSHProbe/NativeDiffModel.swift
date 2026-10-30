// SPDX-License-Identifier: MIT

import Foundation

struct NativeDiffLine: Equatable {
    enum Kind: Equatable { case context, added, deleted }
    var kind: Kind
    var text: String
}

func nativeDiffLines(old: String?, new: String) -> [NativeDiffLine] {
    let a = (old ?? "").components(separatedBy: .newlines)
    let b = new.components(separatedBy: .newlines)
    guard a.count <= 500, b.count <= 500 else {
        return b.map { NativeDiffLine(kind: .added, text: $0) }
    }
    var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var result: [NativeDiffLine] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, j < b.count, a[i] == b[j] {
            result.append(NativeDiffLine(kind: .context, text: a[i])); i += 1; j += 1
        } else if j < b.count, i == a.count || lcs[i][j + 1] > lcs[i + 1][j] {
            result.append(NativeDiffLine(kind: .added, text: b[j])); j += 1
        } else {
            result.append(NativeDiffLine(kind: .deleted, text: a[i])); i += 1
        }
    }
    return result
}
