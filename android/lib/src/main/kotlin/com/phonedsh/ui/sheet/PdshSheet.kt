// Shared modal bottom sheet, spec/ui/v1/interaction.md §2 rules 1-9.
// SPDX-License-Identifier: MIT
//
// The sheet is Material3's platform modal bottom sheet: scrim tap, drag-down and
// system back stay enabled, the platform owns the partial-expand height and the
// present/dismiss motion. This file only adds the frozen per-page detents, the
// per-site chrome and the sheet layer of the back chain.
package com.phonedsh.ui.sheet

import androidx.activity.OnBackPressedCallback
import androidx.activity.findViewTreeOnBackPressedDispatcherOwner
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalBottomSheetProperties
import androidx.compose.material3.SheetValue
import androidx.compose.material3.contentColorFor
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import kotlinx.coroutines.launch

/** Test tags for the shared sheet's observable chrome. */
public object PdshSheetTags {
    /** The platform drag handle, present only for [SheetGrabber.VISIBLE]. */
    public const val DRAG_HANDLE: String = "pdsh_sheet_drag_handle"
}

/**
 * A system modal bottom sheet for one frozen page id (`interaction.md` §2).
 *
 * Rules implemented here:
 * - Rule 1: scrim tap, drag-down and system back all dismiss. The system-back
 *   path is this component's own callback, which always starts the platform
 *   hide unless an inner stack takes the step first (rule 9).
 * - Rules 2-3: [SheetDetents] selects the frozen anchor set. `medium` uses the
 *   platform partial-expand height; this file never writes a fraction.
 * - Rules 4-6: [chrome] selects the grabber, background and top radius.
 * - Rule 7: present/dismiss motion is the platform sheet's own; no custom
 *   duration or curve is installed.
 * - Rule 8: Material applies the platform IME inset to the sheet window and
 *   pads the content with [BottomSheetDefaults.windowInsets], so a focused field
 *   stays above the keyboard.
 * - Rule 9: [innerNavigation] pops before the sheet closes, and [backHost] is
 *   the tiny interface the W2-NAV coordinator can consume.
 *
 * @param pageId the contract page id looked up by [SheetDetents]; unknown ids
 *   use the contract default.
 * @param onDismissRequest called after the platform dismiss animation finishes.
 * @param chrome per-site chrome; the default follows the system.
 * @param innerNavigation the sheet's own navigation stack, or `null` for a
 *   single-level sheet.
 * @param backHost the host-wide sheet back layer. Pass the same instance to
 *   every sheet when a host can stack sheets; a sheet-local one is used by
 *   default so a single sheet still handles system back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun PdshSheet(
    pageId: String,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    chrome: SheetChrome = SheetChrome(),
    innerNavigation: SheetInnerNavigation? = null,
    backHost: SheetBackHost? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val tokens = LocalUiTokens.current
    val host = backHost ?: remember { SheetBackHost() }
    val detentSet: TokenDetentSetId = SheetDetents.forPage(pageId)
    val anchors = SheetDetents.detents(detentSet)
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = SheetDetents.skipPartiallyExpanded(detentSet),
        confirmValueChange = { target ->
            when (target) {
                // Rule 1: a dismiss target is never rejected.
                SheetValue.Hidden -> true
                // Rule 3: only an anchor the page's set names is reachable.
                SheetValue.PartiallyExpanded -> TokenDetent.MEDIUM in anchors
                SheetValue.Expanded -> TokenDetent.LARGE in anchors
            }
        },
    )
    val scope = rememberCoroutineScope()
    val latestOnDismiss by rememberUpdatedState(onDismissRequest)
    val latestInner by rememberUpdatedState(innerNavigation)

    // Rule 7: the platform sheet animates to Hidden; the host is told only after
    // the sheet has left the screen. Rule 9: one back step closes the top sheet;
    // it does not stop at an intermediate detent, so the overlay is gone in the
    // same state transition the push-back contract records.
    val dismiss: () -> Unit = {
        if (sheetState.targetValue != SheetValue.Hidden) {
            scope.launch { sheetState.hide() }.invokeOnCompletion {
                if (!sheetState.isVisible) latestOnDismiss()
            }
        }
    }
    val latestDismiss by rememberUpdatedState(dismiss)

    DisposableEffect(host) {
        val entry = SheetBackHost.Entry(
            popInner = { latestInner?.popInner() == true },
            dismiss = { latestDismiss() },
        )
        host.register(entry)
        onDispose { host.unregister(entry) }
    }

    val containerColor = chrome.containerColor(tokens) ?: BottomSheetDefaults.ContainerColor
    val contentColor = if (containerColor == Color.Transparent) {
        tokens.colors.textPrimary
    } else {
        contentColorFor(containerColor).takeUnless { it == Color.Unspecified }
            ?: tokens.colors.textPrimary
    }
    val radius = chrome.cornerRadiusDp(tokens)
    val shape = if (radius == null) {
        BottomSheetDefaults.ExpandedShape
    } else {
        RoundedCornerShape(topStart = radius, topEnd = radius)
    }

    ModalBottomSheet(
        // Material calls this only after its own hide/settle animation; scrim
        // tap, drag-down and Material's back fallback already left the screen.
        onDismissRequest = { latestOnDismiss() },
        modifier = modifier,
        sheetState = sheetState,
        shape = shape,
        containerColor = containerColor,
        contentColor = contentColor,
        dragHandle = if (chrome.grabberVisible()) {
            {
                BottomSheetDefaults.DragHandle(
                    modifier = Modifier.testTag(PdshSheetTags.DRAG_HANDLE),
                )
            }
        } else {
            null
        },
        // Rule 8: the platform inset is the only keyboard/inset mechanism; the
        // Material sheet also applies imePadding to its full-screen window.
        contentWindowInsets = { BottomSheetDefaults.windowInsets },
        // Material3 1.3.1 registers a predictive-back callback on the dialog
        // window that would bypass SheetBackCallback on API 33+. Turn only that
        // dialog-level callback off; our sheet-level callback below is the
        // enabled back path and starts the same platform hide.
        properties = ModalBottomSheetProperties(shouldDismissOnBackPress = false),
    ) {
        SheetBackCallback {
            if (!host.dispatch()) latestDismiss()
        }
        content()
    }
}

/**
 * Rule 9: intercepts the system back before the sheet's own dismiss callback.
 *
 * The callback lives in the sheet's dialog composition, so it is registered on
 * the dialog's dispatcher after Material's own callback. The dispatcher runs the
 * most recently added callback first, which lets an inner sheet stack consume
 * the gesture; when it does not, [dispatch] or the local fallback asks the
 * platform sheet to hide. This is the sheet's one back path: Material's
 * dialog-level predictive callback is turned off so it cannot bypass the inner
 * stack, while scrim and drag-down keep their Material implementations.
 */
@Composable
private fun SheetBackCallback(dispatch: () -> Unit) {
    val view = LocalView.current
    val latestDispatch by rememberUpdatedState(dispatch)
    DisposableEffect(view) {
        val owner = view.findViewTreeOnBackPressedDispatcherOwner()
            ?: return@DisposableEffect onDispose {}
        val callback = object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                latestDispatch()
            }
        }
        owner.onBackPressedDispatcher.addCallback(callback)
        onDispose { callback.remove() }
    }
}
