// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface.composer

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.ChatMetrics

/** PR22's permanent plus / permission / model controls, with actions composed beside this row. */
@Composable
public fun ComposerToolbar(
    add: @Composable () -> Unit,
    access: @Composable () -> Unit,
    model: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth().testTag(COMPOSER_TOOLBAR_TAG),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box { add() }
        Box { access() }
        Spacer(Modifier.width(ChatMetrics.COMPOSER_MODEL_MIN_GAP_PT.dp))
        Box(
            modifier = Modifier.weight(1f).widthIn(min = 0.dp),
            contentAlignment = Alignment.CenterEnd,
        ) { model() }
    }
}

public const val COMPOSER_TOOLBAR_TAG: String = "pdsh.composer.toolbar"
