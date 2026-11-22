// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — 积分提示条（spec/v1/tono-account.md §11 规则 3）。
//
// Shown after a cloud-origin 402: 「领取积分」 when the account has not
// claimed, 「积分已用完」 without a retry control when it is used up. The
// failed turn itself is DSH's own error; this banner never re-sends it.

import PhoneDSH
import SwiftUI

struct CloudCreditsBanner: View {
    @State private var center = CloudCreditsCenter.shared

    var body: some View {
        Group {
            if let notice = center.notice {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: notice == .exhausted ? "creditcard.trianglebadge.exclamationmark" : "gift")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(CloudCreditsCenter.text(notice))
                        .font(.footnote)
                        .foregroundStyle(HomeSpec.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if notice == .claim {
                        Button {
                            Task { await center.claim() }
                        } label: {
                            Text("领取积分").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(HomeSpec.textPrimary, in: Capsule())
                                .foregroundStyle(HomeSpec.page)
                        }
                        .buttonStyle(.plain)
                        .disabled(center.claiming)
                        .accessibilityIdentifier("credits.banner.claim")
                    }
                    Button { center.dismissNotice() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                    }
                    .accessibilityLabel("关闭提示")
                    .foregroundStyle(HomeSpec.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(HomeSpec.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, HomeSpec.contentInset)
                .padding(.top, 6)
                .accessibilityIdentifier("credits.banner")
            }
        }
        .task { center.start() }
    }
}
