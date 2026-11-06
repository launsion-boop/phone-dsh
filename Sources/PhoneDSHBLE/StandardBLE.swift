// SPDX-License-Identifier: MIT
import Foundation

public struct BLEFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An allowlist of SIG service/characteristic pairs, not a generic GATT writer.
public enum StandardBLEProfile: String, CaseIterable, Sendable {
    case battery, temperature, humidity, manufacturer, model, alert
    public var service: String {
        switch self {
        case .battery: return "180F"
        case .temperature, .humidity: return "181A"
        case .manufacturer, .model: return "180A"
        case .alert: return "1802"
        }
    }
    public var characteristic: String {
        switch self {
        case .battery: return "2A19"
        case .temperature: return "2A6E"
        case .humidity: return "2A6F"
        case .manufacturer: return "2A29"
        case .model: return "2A24"
        case .alert: return "2A06"
        }
    }
    public var unit: String {
        switch self { case .battery, .humidity: return "%"; case .temperature: return "°C"; default: return "" }
    }
    public func decode(_ data: Data) throws -> String {
        let bytes = Array(data)
        switch self {
        case .battery:
            guard bytes.count == 1, bytes[0] <= 100 else { throw BLEFailure("Invalid Battery Level") }
            return String(bytes[0])
        case .temperature, .humidity:
            guard bytes.count == 2 else { throw BLEFailure("Invalid environmental measurement length") }
            let raw = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
            if self == .temperature {
                guard raw != 0x8000, Int16(bitPattern: raw) >= -27315 else { throw BLEFailure("Temperature unavailable or out of range") }
                return String(Double(Int16(bitPattern: raw)) / 100)
            }
            guard raw <= 10000 else { throw BLEFailure("Humidity unavailable or out of range") }
            return String(Double(raw) / 100)
        case .manufacturer, .model:
            guard !data.isEmpty, data.count <= 512, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                throw BLEFailure("Invalid device information")
            }
            return text
        case .alert: throw BLEFailure("Immediate Alert is write-only")
        }
    }
    public static func alertCommand(level: Int) throws -> Data {
        guard (0...2).contains(level) else { throw BLEFailure("Alert level must be 0, 1 or 2") }
        return Data([UInt8(level)])
    }
}
