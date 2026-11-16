// SPDX-License-Identifier: MIT

// BotProvenanceModels: the view-side source inspector value types and pure
// derivation rules. The wire semantics are frozen by G-2; this file only
// consumes the driver result and never invents a source, a trust value or a
// verification state.

import Foundation
import PhoneDSHBot

// MARK: - Driver boundary

/// One source inspection request. `eventIDs` are the row's P27 provenance
/// values; the production adapter resolves them through the lineage/source
/// services. They are never displayed.
struct BotSourceInspectionRequest: Equatable {
    var botID: String
    var rowID: String
    var eventIDs: [String]
}

/// A driver answer. `.unavailable` means the current state could not be read;
/// the view must say so and offer a retry instead of presenting a stale copy as
/// current.
enum BotSourceInspectionResult: Equatable {
    case available(BotSourceInspection)
    case unavailable(reason: String)
}

struct BotSourceInspection: Equatable {
    var sources: [BotProvenanceSource]
    var checkedAtMS: Int64

    init(sources: [BotProvenanceSource], checkedAtMS: Int64) {
        self.sources = sources
        self.checkedAtMS = checkedAtMS
    }
}

// MARK: - Source values

enum BotProvenanceKind: String, Equatable {
    case userMessage = "user_message"
    case file
    case calendar
    case contact
    case web
    case memory
    case inference
    case bot
    case other

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "user_message", "user-message", "message", "user": self = .userMessage
        case "file", "attachment", "document", "photo", "image": self = .file
        case "calendar", "event": self = .calendar
        case "contact", "contacts": self = .contact
        case "web", "url", "browser", "http": self = .web
        case "memory", "record": self = .memory
        case "inference", "model_inference", "model-inference": self = .inference
        case "bot", "assistant" : self = .bot
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .userMessage: return "你的消息"
        case .file: return "文件"
        case .calendar: return "日历"
        case .contact: return "联系人"
        case .web: return "网页"
        case .memory: return "记忆"
        case .inference: return "推断"
        case .bot: return "Bot 生成"
        case .other: return "其他来源"
        }
    }

    var icon: String {
        switch self {
        case .userMessage: return "person.wave.2"
        case .file: return "doc.text"
        case .calendar: return "calendar"
        case .contact: return "person.crop.circle"
        case .web: return "globe"
        case .memory: return "brain"
        case .inference: return "sparkles"
        case .bot: return "bubble.left"
        case .other: return "questionmark.circle"
        }
    }
}

enum BotProvenanceTrust: String, Equatable {
    case user
    case observation
    case assistant
    case system
    case unknown

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "user", "owner", "owner_direct", "owner-direct": self = .user
        case "observation", "observed", "tool", "device", "web", "calendar", "contact", "file":
            self = .observation
        case "assistant", "model", "bot", "inference": self = .assistant
        case "system", "projector", "host": self = .system
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .user: return "你说的"
        case .observation: return "外部观察"
        case .assistant: return "Bot 判断"
        case .system: return "系统记录"
        case .unknown: return "来源未知"
        }
    }
}

enum BotProvenanceVerification: String, Equatable {
    case verified
    case unverified
    case disputed
    case unknown

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "verified": self = .verified
        case "unverified", "not_verified", "not-verified": self = .unverified
        case "disputed", "contested": self = .disputed
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .verified: return "已核对"
        case .unverified: return "未核对"
        case .disputed: return "有争议"
        case .unknown: return "未记录核验"
        }
    }
}

/// G-1's closed current-state set. `live`/`active` and `stale` are accepted as
/// aliases only at the decoding edge; the view has one canonical value.
enum BotProvenanceState: String, Equatable {
    case current
    case changed
    case unavailable
    case revoked
    case erased
    case unknown

    init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "current", "live", "active": self = .current
        case "changed", "stale": self = .changed
        case "unavailable", "unresolved": self = .unavailable
        case "revoked": self = .revoked
        case "erased": self = .erased
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .current: return "当前有效"
        case .changed: return "已变化"
        case .unavailable: return "暂不可用"
        case .revoked: return "已撤权"
        case .erased: return "已抹除"
        case .unknown: return "状态未知"
        }
    }

    var needsAttention: Bool { self != .current }
}

struct BotProvenanceSource: Equatable, Identifiable {
    /// Stable within one inspection only; never displayed.
    var id: String
    var label: String
    var kind: BotProvenanceKind
    var trust: BotProvenanceTrust
    var reason: String?
    var observedAtMS: Int64?
    var verification: BotProvenanceVerification
    var state: BotProvenanceState
    var stateReason: String?
    /// Host-mapped human version label (a date or provider version). The raw
    /// revision/sha/record id must never be put here.
    var versionLabel: String?
    /// This entry is the row-provenance fallback, not a reported source.
    var isFallback = false
    /// The host supplied an unreadable/internal-looking label; the view
    /// replaced it instead of showing an id.
    var hasUnsafeLabel = false

    var needsAttention: Bool {
        state != .current || verification == .disputed
    }

    /// R5: distinguish "cannot be read" from "still readable, but not the
    /// current version". A changed/unknown source may be opened and compared;
    /// revoked/erased/unavailable cannot stand in for a readable history.
    var isReadable: Bool {
        switch state {
        case .current, .changed, .unknown: return true
        case .unavailable, .revoked, .erased: return false
        }
    }

    var isCurrent: Bool { state == .current }

    var isHistorical: Bool { isReadable && !isCurrent }

    /// A short human label for the inspector row; never an internal id.
    var accessLabel: String? {
        switch state {
        case .current: return nil
        case .changed: return "历史版本，可查看"
        case .unknown: return "状态未知，可查看"
        case .unavailable, .revoked, .erased: return "当前不可读"
        }
    }

    static func parse(_ value: BotJSONValue, index: Int) -> BotProvenanceSource? {
        guard let object = value.object else { return nil }
        let rawLabel = object.string("label", "name", "title") ?? ""
        let label = BotProvenanceLabel.sanitized(rawLabel)
        guard label != nil || !rawLabel.isEmpty else { return nil }
        let state = BotProvenanceState(raw: object["state"]?.string
                                        ?? object["freshness"]?.string)
        let observedAtMS: Int64? = {
            guard let raw = object["observed_at"]?.int ?? object["observed_at_ms"]?.int
                    ?? object["observedAt"]?.int,
                  raw >= 0 else { return nil }
            return Int64(raw)
        }()
        return BotProvenanceSource(
            id: "source-\(index)",
            label: label ?? "未命名依据",
            kind: BotProvenanceKind(raw: object["kind"]?.string),
            trust: BotProvenanceTrust(raw: object["trust"]?.string),
            reason: BotProvenanceText.human(object.string("reason", "why")),
            observedAtMS: observedAtMS,
            verification: BotProvenanceVerification(raw: object["verification"]?.string),
            state: state,
            stateReason: BotProvenanceText.human(
                object.string("state_reason", "stateReason", "state_detail", "stateDetail")),
            versionLabel: BotProvenanceLabel.sanitized(object.string("version_label", "versionLabel")),
            hasUnsafeLabel: label == nil)
    }

    static func parseList(_ value: BotJSONValue?) -> [BotProvenanceSource] {
        guard let values = value?.array else { return [] }
        return values.prefix(8).enumerated().compactMap { parse($0.element, index: $0.offset) }
    }

    /// A delivery resource's `source` is the G-1 source-status projection
    /// (`ref/trust/state/observed_at_ms/reason`), not the row `sources[]` entry,
    /// so it may have no human label. Build a truthful generic label from the
    /// trust value; the ref stays internal and is never displayed.
    static func parseLink(_ value: BotJSONValue?, index: Int) -> BotProvenanceSource? {
        guard let object = value?.object else { return nil }
        let trust = BotProvenanceTrust(raw: object["trust"]?.string)
        let state = BotProvenanceState(raw: object["state"]?.string)
        let observedAtMS: Int64? = {
            guard let raw = object["observed_at_ms"]?.int ?? object["observed_at"]?.int,
                  raw >= 0 else { return nil }
            return Int64(raw)
        }()
        let explicit = BotProvenanceLabel.sanitized(object.string("label", "name"))
        let label: String
        switch trust {
        case .user: label = explicit ?? "你提供的资料"
        case .observation: label = explicit ?? "外部观察到的资料"
        case .assistant: label = explicit ?? "Bot 引用的资料"
        case .system: label = explicit ?? "系统记录的资料"
        case .unknown: label = explicit ?? "来源未记录的资料"
        }
        return BotProvenanceSource(
            id: "resource-source-\(index)",
            label: label,
            kind: BotProvenanceKind(raw: object["kind"]?.string),
            trust: trust,
            reason: BotProvenanceText.human(object.string("reason")),
            observedAtMS: observedAtMS,
            verification: .unknown,
            state: state,
            stateReason: BotProvenanceText.human(
                object.string("state_detail", "state_reason")),
            versionLabel: BotProvenanceLabel.version(object.string(
                "version_label", "versionLabel")),
            hasUnsafeLabel: explicit == nil && object.string("label", "name") != nil)
    }
}

// MARK: - Text/label guards

enum BotProvenanceText {
    static func human(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum BotProvenanceLabel {
    /// A source label is user-facing prose. If a producer accidentally put a
    /// record/session/event id or a path there, do not put it in the source
    /// flow; the inspector degrades to "未命名依据" and says the label is
    /// unreadable.
    static func sanitized(_ raw: String?) -> String? {
        guard let value = BotProvenanceText.human(raw) else { return nil }
        guard !looksInternal(value) else { return nil }
        return value
    }

    static func looksInternal(_ value: String) -> Bool {
        let lowered = value.lowercased()
        if lowered.contains("record://") || lowered.contains("://")
            || lowered.contains("session/") || lowered.contains("event/")
            || lowered.contains("row/") || lowered.contains("\u{0}") {
            return true
        }
        // A single opaque token with no spaces that names a machine object.
        let words = value.split(whereSeparator: { $0.isWhitespace })
        if words.count == 1 {
            let token = String(words[0])
            let prefixes = ["evt-", "evt_", "event-", "event_", "row-", "row_",
                            "msg-", "msg_", "session-", "session_", "trace-", "trace_",
                            "call-", "call_", "tool-", "tool_", "job-", "job_",
                            "task-", "task_", "routine-", "routine_", "approval-",
                            "approval_", "req-", "req_", "request-", "request_", "url-", "url_"]
            if prefixes.contains(where: { token.lowercased().hasPrefix($0) }) { return true }
            if token.count >= 12, token.allSatisfy({ $0.isHexDigit }) { return true }
            if token.hasPrefix("/") || token.hasPrefix("~/") { return true }
        }
        return false
    }

    /// A human version label follows the same rule: no ids.
    static func version(_ raw: String?) -> String? {
        sanitized(raw)
    }
}

// MARK: - Time

enum BotProvenanceTime {
    /// Deterministic for tests: the caller supplies `now`, `calendar` and the
    /// time zone is taken from the calendar.
    static func label(_ milliseconds: Int64?, nowMS: Int64,
                      calendar: Calendar = .current) -> String? {
        guard let milliseconds else { return nil }
        guard milliseconds > 0 else { return "时间未知" }
        // More than five minutes in the future is not a real observation.
        if milliseconds > nowMS + 5 * 60 * 1_000 { return "时间异常" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let now = Date(timeIntervalSince1970: Double(nowMS) / 1_000)
        let time = timeFormatter(calendar: calendar).string(from: date)
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let difference = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if difference == 0 { return "今天 \(time)" }
        if difference == 1 { return "昨天 \(time)" }
        let year = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: now)
        if year == currentYear {
            return "\(monthDayFormatter(calendar: calendar).string(from: date)) \(time)"
        }
        return "\(year)年\(monthDayFormatter(calendar: calendar).string(from: date)) \(time)"
    }

    private static func timeFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private static func monthDayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        return formatter
    }
}

// MARK: - Inspector derivation

enum BotProvenanceAvailability: Equatable {
    case available
    case limited(String)
    case unavailable(String)
}

enum BotProvenanceBannerTone: Equatable {
    case warning
    case danger
}

struct BotProvenanceBanner: Equatable {
    var text: String
    var detail: String?
    var tone: BotProvenanceBannerTone
}

struct BotProvenanceInspectorModel: Equatable {
    var sources: [BotProvenanceSource]
    var availability: BotProvenanceAvailability
    var banner: BotProvenanceBanner?
    var checkedAtMS: Int64
    var isFallback: Bool

    /// Build from the row alone, for the brief moment before the driver
    /// answers (and for fixture previews). This path never claims a source:
    /// it states the row's own provenance and that no verifiable source was
    /// supplied.
    init(row: BotUIRow, nowMS: Int64) {
        let fallback = Self.fallbackSource(row: row)
        sources = fallback.map { [$0] } ?? []
        isFallback = true
        checkedAtMS = nowMS
        availability = .limited("没有可核验的原始记录")
        banner = nil
    }

    init(row: BotUIRow, inspection: BotSourceInspection, nowMS: Int64) {
        if !inspection.sources.isEmpty {
            sources = inspection.sources
            isFallback = false
        } else {
            sources = Self.fallbackSource(row: row).map { [$0] } ?? []
            isFallback = !sources.isEmpty
        }
        checkedAtMS = inspection.checkedAtMS
        let unreadable = sources.contains(where: \.hasUnsafeLabel)
        if unreadable {
            availability = .limited("有来源名称不可读，已隐藏原始编号")
        } else if sources.isEmpty {
            availability = .unavailable("这条内容没有留下可展示的来源")
        } else if isFallback {
            availability = .limited("没有可核验的原始记录")
        } else {
            availability = .available
        }
        // A fallback entry is not a reported source; a "state unknown"
        // banner would overstate it. The limited availability line already
        // says no verifiable source was supplied.
        banner = isFallback ? nil : Self.makeBanner(sources: sources)
    }

    static func fallbackSource(row: BotUIRow) -> BotProvenanceSource? {
        guard !row.id.hasPrefix("local-") else { return nil }
        let trust = BotProvenanceTrust(raw: row.provenance.trust)
        let (label, kind, reason): (String, BotProvenanceKind, String) = {
            switch trust {
            case .user:
                return ("你发送的内容", .userMessage, "这是你在这段对话里发出的内容。")
            case .assistant:
                return ("Bot 生成的内容", .bot, "这条内容由 Bot 生成，没有引用可核验的原始记录。")
            case .system:
                return ("系统记录", .other, "这条内容来自系统记录，没有提供可核验的来源。")
            case .observation:
                return ("外部观察", .other, "这条内容来自外部观察，没有提供可核验的来源。")
            case .unknown:
                return ("来源未记录", .other, "这条内容没有记录可核验的来源。")
            }
        }()
        return BotProvenanceSource(
            id: "fallback",
            label: label,
            kind: kind,
            trust: trust,
            reason: reason,
            observedAtMS: nil,
            verification: .unknown,
            state: .unknown,
            stateReason: nil,
            versionLabel: nil,
            isFallback: true)
    }

    static func makeBanner(sources: [BotProvenanceSource]) -> BotProvenanceBanner? {
        // Unreadable sources are a stronger state than a readable history:
        // one says the basis is gone, the other says it can still be opened
        // and compared but must not be presented as current.
        let unreadable = sources.filter { !$0.isReadable }
        if !unreadable.isEmpty {
            return BotProvenanceBanner(
                text: unreadable.count == 1
                    ? "这条依据已不可读"
                    : "有 \(unreadable.count) 条依据已不可读",
                detail: unreadable.first?.stateReason ?? unreadable.first?.reason,
                tone: .danger)
        }
        let disputed = sources.filter { $0.verification == .disputed }
        if !disputed.isEmpty {
            return BotProvenanceBanner(
                text: disputed.count == 1 ? "这条依据有争议" : "有 \(disputed.count) 条依据存在争议",
                detail: disputed.first?.reason,
                tone: .warning)
        }
        let historical = sources.filter(\.isHistorical)
        guard !historical.isEmpty else { return nil }
        let first = historical[0]
        return BotProvenanceBanner(
            text: historical.count == 1
                ? "这条依据可查看，但不是当前有效"
                : "有 \(historical.count) 条依据可查看，但不是当前有效",
            detail: first.stateReason ?? first.reason,
            tone: .warning)
    }

    var headline: String {
        if isFallback { return "关于这条内容" }
        return sources.count == 1 ? "1 条依据" : "\(sources.count) 条依据"
    }

    var historicalCount: Int { sources.filter(\.isHistorical).count }
    var unreadableCount: Int { sources.filter { !$0.isReadable }.count }

    var showsAttentionBanner: Bool { banner != nil }
}

// MARK: - Entry availability

enum BotProvenanceEntryAvailability: Equatable {
    case available
    case unavailable(String)
}

enum BotProvenanceEntry {
    /// Whether the row's context menu should offer "查看来源". Local optimistic
    /// echoes and owner text have no meaningful source view; everything else
    /// has at least the truthful fallback.
    static func availability(for row: BotUIRow) -> BotProvenanceEntryAvailability {
        if row.id.hasPrefix("local-") {
            return .unavailable("这条消息还没有写入记录")
        }
        if row.body.type == "text", row.role == "user" {
            return .unavailable("这是你自己发送的消息")
        }
        guard BotUIRendering.isRenderable(row) else {
            return .unavailable("这条内容不显示")
        }
        return .available
    }
}
