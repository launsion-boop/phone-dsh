// Android open-source license notices supplied by the host's audited catalog.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsGroupedRow
import com.phonedsh.ui.surface.SettingsSubPageFrame

/** A verified license notice; name, license label and full notice come from the host catalog. */
public data class AndroidLicenseNotice(
    public val name: String,
    public val license: String,
    public val notice: String? = null,
)

/** Shows only the host-provided license catalog; this module has no generated legal-notice asset. */
@Composable
public fun LicensesPage(
    entries: List<AndroidLicenseNotice>? = null,
    modifier: Modifier = Modifier,
    embedded: Boolean = true,
    onBack: () -> Unit = {},
) {
    val content: @Composable () -> Unit = {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(LICENSES_PAGE_TAG),
            contentPadding = PaddingValues(top = com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            if (entries.isNullOrEmpty()) {
                item(key = "license-catalog-unavailable") {
                    Column {
                        SettingsGroupCard {
                            SettingsGroupedRow(
                                title = UiStrings.ABOUT_LICENSES,
                                value = UiStrings.UNAVAILABLE,
                                enabled = false,
                                dividerBelow = false,
                            )
                        }
                        SettingsFootnoteRow(
                            text = "许可信息暂不可用。",
                            modifier = Modifier.testTag(LICENSES_NOTE_TAG),
                        )
                    }
                }
            } else {
                item(key = "license-catalog") {
                    SettingsGroupCard {
                        entries.forEachIndexed { index, entry ->
                            SettingsGroupedRow(
                                title = entry.name,
                                value = entry.license,
                                dividerBelow = index != entries.lastIndex || !entry.notice.isNullOrBlank(),
                            )
                            entry.notice?.takeIf(String::isNotBlank)?.let { notice ->
                                com.phonedsh.ui.surface.SettingsBodyRow(
                                    text = notice,
                                    dividerBelow = index != entries.lastIndex,
                                    modifier = Modifier.testTag("$LICENSES_NOTICE_PREFIX$index"),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
    if (embedded) content() else {
        SettingsSubPageFrame(title = UiStrings.ABOUT_LICENSES, onBack = onBack, modifier = modifier, grouped = true) { content() }
    }
}

internal const val LICENSES_PAGE_TAG: String = "pdsh.settings.licenses"
internal const val LICENSES_NOTE_TAG: String = "pdsh.settings.licenses.note"
internal const val LICENSES_NOTICE_PREFIX: String = "pdsh.settings.licenses.notice."
