// SPDX-License-Identifier: MIT
// Minimal ustar parser used by the PhoneDSHLogTests overlay assertions.

import Foundation

struct ParsedTarEntry: Equatable {
    var name: String
    var mode: Int
    var typeflag: Character
    var data: Data
}

enum TarParser {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func parse(_ archive: Data) throws -> [ParsedTarEntry] {
        var entries: [ParsedTarEntry] = []
        var offset = 0
        while offset + 512 <= archive.count {
            let header = archive.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                break
            }
            let name = try field(header, offset: 0, length: 100)
            let prefix = try field(header, offset: 345, length: 155)
            let typeByte = header[header.startIndex + 156]
            let typeflag = Character(UnicodeScalar(typeByte))
            let sizeText = try field(header, offset: 124, length: 12)
            guard let size = Int(sizeText.trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8),
                  size >= 0 else {
                throw ParseError(description: "invalid tar size field")
            }
            let modeText = try field(header, offset: 100, length: 8)
            guard let mode = Int(modeText.trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) else {
                throw ParseError(description: "invalid tar mode field")
            }
            let fullName = prefix.isEmpty ? name : prefix + "/" + name
            offset += 512
            guard offset + size <= archive.count else {
                throw ParseError(description: "tar entry data runs past the archive")
            }
            let data = archive.subdata(in: offset..<(offset + size))
            entries.append(ParsedTarEntry(name: fullName, mode: mode,
                                          typeflag: typeflag, data: data))
            offset += size
            if offset % 512 != 0 {
                offset += 512 - (offset % 512)
            }
        }
        return entries
    }

    private static func field(_ header: Data, offset: Int, length: Int) throws -> String {
        let start = header.index(header.startIndex, offsetBy: offset)
        let end = header.index(start, offsetBy: length)
        let bytes = header[start..<end].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
