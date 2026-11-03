// SPDX-License-Identifier: MIT

import SwiftUI

struct PersonalMemoryPage: View {
    var body: some View {
        List {
            Section(NativeText("Personal Memory", "Personal Memory")) {
                Label(NativeText("个人记忆正在接入", "Personal Memory is being connected"), systemImage: "brain.head.profile")
                Text(NativeText("这里将展示待确认、关于我、工作进展、来源、修订、归档与遗忘。当前没有读取或生成任何个人记忆。",
                                "Pending candidates, about me, work context, sources, revisions, archives and forgetting will appear here. No personal memory has been read or generated."))
                    .font(.system(size: 14))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
            Section(NativeText("数据来源", "Data sources")) {
                Text(NativeText("此页面使用 personal-memory 契约，不复用内存压力探针 MemoryPage。",
                                "This page uses the personal-memory contract and does not reuse the MemoryPage pressure probe."))
                    .font(.system(size: 13))
                    .foregroundStyle(HomeSpec.textSecondary)
            }
        }
        .homeGroupedList()
        .navigationTitle(NativeText("个人 Memory", "Personal Memory"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("profile.personal-memory")
    }
}
