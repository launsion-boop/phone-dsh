// SPDX-License-Identifier: MIT
import Foundation

/// Bounded UTF-8 server-sent event parser. It emits only validated tasks.
struct TaskSSEParser {
    private var line = Data()
    private var eventName = ""
    private var data = Data()

    mutating func push(_ byte: UInt8) throws -> DeviceTask? {
        if byte != 10 {
            guard line.count < 8192 else { throw DeviceTaskError.invalidTask }
            line.append(byte)
            return nil
        }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { eventName = ""; data.removeAll(keepingCapacity: true) }
            guard eventName == "task", !data.isEmpty else { return nil }
            return try DeviceTask.decode(data)
        }
        guard let text = String(data: line, encoding: .utf8) else { throw DeviceTaskError.invalidTask }
        if text.first == ":" { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        if name == "event" { eventName = value }
        if name == "data" {
            let bytes = Data(value.utf8)
            guard data.count + bytes.count + (data.isEmpty ? 0 : 1) <= 4096 else { throw DeviceTaskError.invalidTask }
            if !data.isEmpty { data.append(10) }
            data.append(bytes)
        }
        return nil
    }
}
