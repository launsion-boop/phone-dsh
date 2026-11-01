// SPDX-License-Identifier: MIT

import Foundation

public enum PhoneCapabilityGroup: String, CaseIterable, Codable, Sendable {
    case personal
    case deviceSensors
    case systemNotifications
    case filesData
    case homeMedia

    public var title: String {
        switch self {
        case .personal: return "个人信息"
        case .deviceSensors: return "设备与传感器"
        case .systemNotifications: return "系统与通知"
        case .filesData: return "文件与数据"
        case .homeMedia: return "家庭与媒体"
        }
    }

    public var capabilities: [PhoneCapability] {
        PhoneCapability.allCases.filter { $0.group == self }
    }
}

public enum PhoneCapability: String, CaseIterable, Codable, Sendable, Identifiable {
    public var id: String { rawValue }

    case contacts
    case calendar
    case reminders
    case health
    case photos
    case camera
    case microphone
    case speech
    case location
    case locationAlways
    case motion
    case bluetooth
    case notifications
    case biometrics
    case localNetwork
    case focus
    case clipboard
    case filesFolder
    case device
    case homekit
    case music
    case liveActivity
    case shortcuts

    public var group: PhoneCapabilityGroup {
        switch self {
        case .contacts, .calendar, .reminders, .health, .photos: return .personal
        case .camera, .microphone, .speech, .location, .motion, .bluetooth, .localNetwork:
            return .deviceSensors
        case .notifications, .focus, .biometrics, .liveActivity, .shortcuts: return .systemNotifications
        case .filesFolder, .clipboard, .device, .locationAlways: return .filesData
        case .homekit, .music: return .homeMedia
        }
    }

    public var title: String {
        switch self {
        case .contacts: return "通讯录"
        case .calendar: return "日历"
        case .reminders: return "提醒事项"
        case .health: return "健康"
        case .photos: return "照片"
        case .camera: return "相机"
        case .microphone: return "麦克风"
        case .speech: return "语音识别"
        case .location: return "定位"
        case .locationAlways: return "后台定位"
        case .motion: return "运动与健身"
        case .bluetooth: return "蓝牙"
        case .notifications: return "通知"
        case .biometrics: return "面容确认"
        case .localNetwork: return "本地网络"
        case .focus: return "专注模式"
        case .clipboard: return "剪贴板"
        case .filesFolder: return "文件与文件夹"
        case .device: return "设备状态"
        case .shortcuts: return "快捷指令"
        case .homekit: return "家庭"
        case .music: return "音乐"
        case .liveActivity: return "实时活动"
        }
    }

    public var purpose: String {
        switch self {
        case .contacts: return "仅在你查询时读取联系人；电话和邮箱默认脱敏。"
        case .calendar: return "读取你选择时间范围内的日程，并在确认后创建日程。"
        case .reminders: return "读取提醒事项，并在确认后创建或完成提醒。"
        case .health: return "将读取：步数、睡眠、心率、静息心率、HRV、训练、体重、正念；不写入健康数据。"
        case .photos: return "读取照片元数据，用于查找最近或指定日期的照片。"
        case .camera: return "仅在你发起拍摄时采集照片或扫描文稿。"
        case .microphone: return "仅在你发起录音时采集音频。"
        case .speech: return "将你选择的录音转换为文字。"
        case .location: return "仅在你查询时获取一次当前位置。"
        case .locationAlways: return "仅在明确创建地理围栏时注册区域监测，不伪造后台事件。"
        case .motion: return "读取你指定时间内的活动与步数。"
        case .bluetooth: return "仅在你发起扫描时发现附近蓝牙设备。"
        case .notifications: return "仅在你确认后发送本地通知，不接收远程推送。"
        case .biometrics: return "启用后，敏感写操作前需要 Face ID 或 Touch ID；这不是单独系统授权。"
        case .localNetwork: return "点击后通过系统网络浏览器实测局域网发现能力。"
        case .focus: return "通过系统 FocusStatus 读取当前是否处于专注状态。"
        case .clipboard: return "仅在你明确调用时读取或写入系统剪贴板。"
        case .filesFolder: return "通过系统选择器授权你选择的文件夹，不读取其它 App 容器。"
        case .device: return "只读显示设备型号、系统版本和当前时间，始终启用。"
        case .shortcuts: return "打开指定的快捷指令；跨 App 执行结果无法观测，不承诺已完成。"
        case .homekit: return "读取你授权的家庭与配件，并在确认后写入指定特征。"
        case .music: return "通过 MusicKit 播放你指定的真实音乐目录项目。"
        case .liveActivity: return "通过 ActivityKit 创建和更新实时活动。"
        }
    }

    public var systemImage: String {
        switch self {
        case .contacts: return "person.crop.circle"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .health: return "heart.text.square"
        case .photos: return "photo.on.rectangle"
        case .camera: return "camera"
        case .microphone: return "mic"
        case .speech: return "waveform"
        case .location, .locationAlways: return "location"
        case .motion: return "figure.walk"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .notifications: return "bell"
        case .biometrics: return "faceid"
        case .localNetwork: return "network"
        case .focus: return "moon"
        case .clipboard: return "doc.on.clipboard"
        case .filesFolder: return "folder"
        case .device: return "iphone"
        case .shortcuts: return "square.grid.2x2"
        case .homekit: return "homekit"
        case .music: return "music.note"
        case .liveActivity: return "bolt.horizontal.circle"
        }
    }

    public var defaultEnabled: Bool { self == .device }
    public var isReadOnlyAlwaysOn: Bool { self == .device }
}
