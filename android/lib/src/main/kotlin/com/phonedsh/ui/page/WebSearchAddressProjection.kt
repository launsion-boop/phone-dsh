// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf

/** Confirmed non-secret search base. Null means the host cannot safely read it. */
public val LocalWebSearchSavedBase: ProvidableCompositionLocal<String?> = staticCompositionLocalOf { null }
