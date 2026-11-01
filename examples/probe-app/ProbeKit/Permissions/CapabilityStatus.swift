// SPDX-License-Identifier: MIT

import Foundation

public enum CapabilityStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case limited(Int)
    case denied
    case restricted
    case requested
    case unavailable

    public var text: String {
        switch self {
        case .notDetermined: return "未请求"
        case .authorized: return "已允许"
        case .limited(let count): return "部分允许（\(max(0, count))）"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        case .requested: return "已请求（系统不告知是否被拒）"
        case .unavailable: return "当前设备不可用"
        }
    }

    public var permitsUse: Bool {
        switch self {
        case .authorized, .limited, .requested: return true
        case .notDetermined, .denied, .restricted, .unavailable: return false
        }
    }

    public var blocksInteraction: Bool {
        self == .restricted || self == .unavailable
    }

    public var canRequest: Bool { self == .notDetermined }
    public var canOpenSettings: Bool { self == .denied }
}
