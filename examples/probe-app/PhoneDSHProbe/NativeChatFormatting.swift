// SPDX-License-Identifier: MIT

import Foundation

func nativeCompactTokens(_ value: Int) -> String {
    func scaled(_ number: Double) -> String {
        number >= 100 ? String(Int(number.rounded())) : String((number * 10).rounded() / 10)
    }
    if value < 1_000 { return "\(value)" }
    if value < 1_000_000 { return "\(scaled(Double(value) / 1_000))K" }
    return "\(scaled(Double(value) / 1_000_000))M"
}

func nativePercent(_ value: Double?) -> String? {
    guard let value else { return nil }
    if value >= 99.95 { return "100" }
    if value >= 10 { return String(Int(value.rounded())) }
    return String((value * 10).rounded() / 10)
}

func nativeClock(_ date: Date?) -> String {
    guard let date else { return "" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func nativeDuration(_ milliseconds: Double) -> String {
    let seconds = milliseconds / 1_000
    if seconds < 60 { return String(format: "%.1f秒", (seconds * 10).rounded() / 10) }
    let whole = Int(seconds.rounded())
    return "\(whole / 60)分\(whole % 60)秒"
}
