// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.phonedsh.probe.outbox.SendOutboxEntry
import com.phonedsh.ui.theme.PdshThemeValues

@Composable
internal fun LostSendBanner(entries: List<SendOutboxEntry>, target: String?, onAction: (String, String?) -> Unit) {
    if (entries.isEmpty()) return
    val colors = PdshThemeValues.tokens.colors
    val caption = PdshThemeValues.type.caption
    Column(Modifier.fillMaxWidth().heightIn(max = 180.dp)
        .verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp)) {
        BasicText("${entries.size} 条消息的原对话已不在引擎中", style = caption.copy(color = colors.warning))
        for (entry in entries) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                BasicText(entry.text.ifBlank { entry.attachments.orEmpty().joinToString { it.filename } }, Modifier.weight(1f), style = caption.copy(color = colors.secondary), maxLines = 2)
                val canResend = target != null && target != entry.sessionId
                BasicText("发到当前对话", Modifier.clickable(enabled = canResend, role = Role.Button) {
                    onAction(entry.rpcId, target)
                }.padding(vertical = 6.dp), style = caption.copy(color = if (canResend) colors.accent else colors.tertiary))
                BasicText("删除", Modifier.clickable(role = Role.Button) { onAction(entry.rpcId, null) }.padding(vertical = 6.dp),
                    style = caption.copy(color = colors.secondary))
            }
        }
    }
}
