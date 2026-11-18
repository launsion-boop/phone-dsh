// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsNavBar
import com.phonedsh.ui.theme.LocalUiTokens

/** The circular back control and inline title used by these product pages. */
@Composable
internal fun ProductNavigationBar(title: String, onBack: () -> Unit, leadingInset: Dp = 4.dp, topOffset: Dp = 6.dp) {
    SettingsNavBar(title = title, modifier = Modifier.padding(top = topOffset), leading = {
        val ink = LocalUiTokens.current.colors.textPrimary
        Box(Modifier.padding(start = leadingInset).size(44.dp).clip(CircleShape)
            .background(LocalUiTokens.current.colors.surface)
            .clickable(role = Role.Button, onClick = onBack)
            .semantics { contentDescription = UiStrings.BACK }, contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(20.dp)) {
                val path = Path().apply {
                    moveTo(size.width * .64f, size.height * .15f)
                    lineTo(size.width * .3f, size.height * .5f)
                    lineTo(size.width * .64f, size.height * .85f)
                }
                drawPath(path, ink, style = Stroke(width = 2.4.dp.toPx(), cap = StrokeCap.Round))
            }
        }
    })
}
