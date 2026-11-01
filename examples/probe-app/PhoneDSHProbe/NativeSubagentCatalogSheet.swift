// SPDX-License-Identifier: MIT
//
// WS-E — subagent catalog sheet: the phone form of the official 336×≤560
// dropdown tree, plus the `.sheet` presenter. Baseline 7be5505b0b (0.2.1-rc.2):
//   ui-subagent/.../SubagentHeaderLineage.tsx:201-390, .module.css, locales.ts
// 402pt: width 336 (max min(400, vw−32)), max-height min(560, vh−140),
// padding 4, radius 16; row min-height 44 (padding 6/7/6/9, radius 12, 12/17);
// disclosure 14 (12pt chevron); activity slot 14 (14pt spinner / 6pt dot);
// secondary 10/15; children indent 16+3.

import SwiftUI

enum NativeSubagentMode: String, CaseIterable, Hashable {
    case oneShot = "one-shot"
    case continuable
    case external
    case unknown

    var label: String {
        switch self {
        case .oneShot: "一次性"
        case .continuable: "可继续"
        case .external: "外部任务"
        case .unknown: "模式未知"
        }
    }
}

enum NativeSubagentActivity: String, CaseIterable, Hashable {
    case running
    case completed
    case inactive

    var label: String {
        switch self {
        case .running: "正在运行"
        case .completed: "已完成"
        case .inactive: "当前未运行"
        }
    }
}

enum NativeSubagentCatalogState: Equatable {
    case ready
    case loading
    case error(String?)
}

struct NativeSubagentCatalogEntry: Identifiable, Hashable {
    let id: String
    var label: String? = nil
    var displayTitle: String? = nil
    var mode: NativeSubagentMode = .continuable
    var activity: NativeSubagentActivity = .inactive
    var tokenText: String? = nil
    var durationText: String? = nil
    var durationExactText: String? = nil
    var isCurrent: Bool = false
    var requiresMigration: Bool = false
    var parentID: String? = nil
    /// `nil` = children not loaded yet, `[]` = authoritative leaf.
    var children: [NativeSubagentCatalogEntry]? = nil

    var title: String { label ?? id }
    var isExternal: Bool { mode == .external }
    var isKnownLeaf: Bool { children?.isEmpty == true }
    /// Official: external rows and migration-pending rows never disclose.
    var canExpand: Bool { !isExternal && !requiresMigration && !isKnownLeaf }
}

struct NativeSubagentCatalogSheet: View {
    var entries: [NativeSubagentCatalogEntry]
    var state: NativeSubagentCatalogState = .ready
    var currentSessionID: String? = nil
    var availableSize: CGSize? = nil
    var onOpenSession: (NativeSubagentCatalogEntry) -> Void = { _ in }
    var onOpenAside: (NativeSubagentCatalogEntry) -> Void = { _ in }
    var onExpand: ((NativeSubagentCatalogEntry) -> Void)? = nil
    var onRetry: (() -> Void)? = nil

    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading { notice("正在加载子智能体…") }
                if let errorText { errorRow(errorText) }
                ForEach(visibleRows) { row in
                    NativeSubagentCatalogRow(
                        entry: row.entry,
                        depth: row.depth,
                        isExpanded: expanded.contains(row.entry.id),
                        isCurrent: row.entry.isCurrent || row.entry.id == currentSessionID,
                        onOpen: { onOpenSession(row.entry) },
                        onOpenAside: { onOpenAside(row.entry) },
                        onToggle: { toggle(row.entry) }
                    )
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .frame(width: width, height: cardHeight, alignment: .top)
        // Official mobile menu: rgba(248,249,250,.58) over a 40pt backdrop blur.
        .background(NativeParityTokens.menu.opacity(0.58),
                    in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous))
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NativeParityTokens.radiusLG, style: .continuous)
                .strokeBorder(NativeParityTokens.borderL1, lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
        .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("子智能体会话"))
    }

    // MARK: - Geometry

    private var width: CGFloat {
        let available = (availableSize?.width ?? 402) - 32
        return max(240, min(NativeParityTokens.subagentMenuWidth, min(400, available)))
    }

    private var maxHeight: CGFloat {
        max(120, min(560, (availableSize?.height ?? 740) - 140))
    }

    private var cardHeight: CGFloat {
        let notice: CGFloat = errorText != nil ? 48 : (isLoading ? 32 : 0)
        let content = max(44, 8 + notice + CGFloat(visibleRows.count) * 44)
        return min(content, maxHeight)
    }

    // MARK: - Tree

    private struct VisibleRow: Identifiable {
        let entry: NativeSubagentCatalogEntry
        let depth: Int
        var id: String { entry.id }
    }

    private var visibleRows: [VisibleRow] {
        func flatten(_ list: [NativeSubagentCatalogEntry], depth: Int,
                     parent: NativeSubagentCatalogEntry?) -> [VisibleRow] {
            list.flatMap { source in
                var entry = source
                if entry.parentID == nil { entry.parentID = parent?.id }
                var rows = [VisibleRow(entry: entry, depth: depth)]
                if expanded.contains(entry.id), let children = entry.children {
                    rows += flatten(children, depth: depth + 1, parent: entry)
                }
                return rows
            }
        }
        return flatten(entries, depth: 1, parent: nil)
    }

    private func toggle(_ entry: NativeSubagentCatalogEntry) {
        if expanded.contains(entry.id) {
            expanded.remove(entry.id)
            closeBranch(entry)
        } else {
            expanded.insert(entry.id)
            onExpand?(entry)
        }
    }

    private func closeBranch(_ entry: NativeSubagentCatalogEntry) {
        for child in entry.children ?? [] {
            expanded.remove(child.id)
            closeBranch(child)
        }
    }

    // MARK: - States

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    private var errorText: String? {
        guard case let .error(message) = state else { return nil }
        return (message?.isEmpty == false ? message : nil) ?? "无法加载子智能体"
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(NativeParityTokens.labelTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(NativeParityTokens.error)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        Text("重试")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(NativeParityTokens.error)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 32)
    }
}

// MARK: - Row

private struct NativeSubagentCatalogRow: View {
    let entry: NativeSubagentCatalogEntry
    let depth: Int
    let isExpanded: Bool
    let isCurrent: Bool
    let onOpen: () -> Void
    let onOpenAside: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            disclosure
            openButton
            if !isCurrent && !entry.isExternal {
                sidebarButton.padding(.top, 4)
            }
        }
        .padding(.leading, CGFloat(depth - 1) * 19 + 9)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .frame(minHeight: 44, alignment: .center)
        // iOS affordance for the official hover tooltip: both row actions stay
        // reachable by long-press as well as by the row / sidebar chevron.
        .contextMenu {
            if !entry.isExternal {
                Button("打开子会话", action: onOpen)
                Button("在侧边栏打开", action: onOpenAside)
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if entry.canExpand {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.12), value: isExpanded)
                    .foregroundStyle(NativeParityTokens.labelTertiary)
                    .frame(width: 14, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isExpanded
                ? "收起 \(entry.title) 的下级子智能体"
                : "展开 \(entry.title) 的下级子智能体"))
        } else {
            Color.clear.frame(width: 14, height: 17)
        }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 6) {
                activitySlot
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(NativeParityTokens.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 17)
                    secondaryLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                metrics
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.isExternal)
        .accessibilityLabel(Text(rowAccessibilityLabel))
        .accessibilityHint(Text("打开子会话"))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private var activitySlot: some View {
        Group {
            if entry.isExternal {
                Color.clear
            } else {
                switch entry.activity {
                case .running:
                    NativeSubagentActivitySpinner(size: 14)
                case .completed:
                    Circle().fill(NativeParityTokens.success).frame(width: 6, height: 6)
                case .inactive:
                    Circle().fill(NativeParityTokens.color(light: 0xD4D4D4, dark: 0x545557))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 14, height: 17)
    }

    private var secondaryLine: some View {
        HStack(spacing: 4) {
            if let title = entry.displayTitle, !title.isEmpty {
                Text(title).lineLimit(1).truncationMode(.tail)
                Text("·").foregroundStyle(NativeParityTokens.labelCaption)
            }
            Text(modeText)
                .lineLimit(1)
                .layoutPriority(1)
                .padding(.horizontal, 4)
                .frame(height: 15)
                .background(NativeParityTokens.selector,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            if activityVisible {
                Text("·").foregroundStyle(NativeParityTokens.labelCaption)
                Text(entry.activity.label).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(NativeParityTokens.labelTertiary)
        .frame(height: 15)
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(entry.tokenText ?? "").frame(height: 17)
            Text(entry.durationText ?? "").frame(height: 15)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(NativeParityTokens.labelTertiary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityHidden(true)
    }

    private var sidebarButton: some View {
        Button(action: onOpenAside) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(NativeParityTokens.labelTertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("在侧边栏打开 \(entry.title)"))
        .help("在侧边栏打开")
    }

    private var modeText: String {
        entry.requiresMigration ? "需要迁移" : entry.mode.label
    }

    private var activityVisible: Bool {
        !entry.isExternal && !entry.requiresMigration
    }

    private var rowAccessibilityLabel: String {
        let secondary = [entry.displayTitle, modeText, activityVisible ? entry.activity.label : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let metrics = [entry.tokenText, entry.durationExactText ?? entry.durationText]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return [entry.title, secondary, metrics].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Presenter

extension View {
    /// Phone presentation of the catalog: a floating 336pt card inside the
    /// system sheet, with the official medium/large detents.
    func nativeSubagentCatalogSheet(
        isPresented: Binding<Bool>,
        entries: [NativeSubagentCatalogEntry],
        state: NativeSubagentCatalogState = .ready,
        currentSessionID: String? = nil,
        onOpenSession: @escaping (NativeSubagentCatalogEntry) -> Void = { _ in },
        onOpenAside: @escaping (NativeSubagentCatalogEntry) -> Void = { _ in },
        onExpand: ((NativeSubagentCatalogEntry) -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        sheet(isPresented: isPresented) {
            GeometryReader { proxy in
                NativeSubagentCatalogSheet(
                    entries: entries,
                    state: state,
                    currentSessionID: currentSessionID,
                    availableSize: proxy.size,
                    onOpenSession: { entry in
                        isPresented.wrappedValue = false
                        onOpenSession(entry)
                    },
                    onOpenAside: { entry in
                        isPresented.wrappedValue = false
                        onOpenAside(entry)
                    },
                    onExpand: onExpand,
                    onRetry: onRetry
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .presentationBackground(Color.clear)
            .presentationCornerRadius(NativeParityTokens.radiusLG)
        }
    }
}

#if DEBUG
private let nativeSubagentCatalogPreviewSize = CGSize(width: 402, height: 800)

private let nativeSubagentCatalogPreviewEntries: [NativeSubagentCatalogEntry] = [
    .init(id: "child-1", label: "探索代码库", displayTitle: "定位 subagent 视图",
          mode: .oneShot, activity: .completed, tokenText: "12.4K tok", durationText: "1分20秒",
          children: [.init(id: "child-1-1", label: "读取 CSS", mode: .oneShot,
                           activity: .completed, tokenText: "1.8K tok", durationText: "3秒")]),
    .init(id: "child-2", label: "实现目录 sheet", mode: .continuable, activity: .running,
          tokenText: "48.1K tok", durationText: "12分4秒"),
    .init(id: "child-3", label: "外部任务", mode: .external),
    .init(id: "child-4", label: "待迁移子智能体", mode: .unknown, requiresMigration: true),
]

#Preview("子智能体目录 · 空 / 单个") {
    VStack(spacing: 24) {
        NativeSubagentCatalogSheet(entries: [], availableSize: nativeSubagentCatalogPreviewSize)
        NativeSubagentCatalogSheet(entries: [nativeSubagentCatalogPreviewEntries[0]],
                                   currentSessionID: "child-1",
                                   availableSize: nativeSubagentCatalogPreviewSize)
    }
    .padding(24)
}

#Preview("子智能体目录 · 多个 / 运行中 / 嵌套") {
    NativeSubagentCatalogSheet(entries: nativeSubagentCatalogPreviewEntries,
                               availableSize: nativeSubagentCatalogPreviewSize)
        .padding(24)
}

#Preview("子智能体目录 · 加载中 / 失败") {
    VStack(spacing: 24) {
        NativeSubagentCatalogSheet(entries: [], state: .loading,
                                   availableSize: nativeSubagentCatalogPreviewSize)
        NativeSubagentCatalogSheet(entries: [], state: .error("无法连接子智能体投影"),
                                   availableSize: nativeSubagentCatalogPreviewSize,
                                   onRetry: {})
    }
    .padding(24)
}
#endif
