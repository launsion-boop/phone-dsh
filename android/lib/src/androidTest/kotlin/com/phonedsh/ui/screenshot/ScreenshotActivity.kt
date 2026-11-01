// The capture host activity: a bare, themed, action-bar-free window.
// SPDX-License-Identifier: MIT
//
// `ui-test-manifest` contributes a bare `ComponentActivity`, but its theme comes
// from the test APK and on this device resolves to a dark action-bar theme: the
// action bar then overlays the top of the edge-to-edge content and the capture
// contains window chrome instead of only product pixels. This activity is
// declared by the androidTest manifest with `PdshScreenshotTheme` (light, no
// action bar, white window background), so the frame is the product surface and
// nothing else.
//
// It lives in the test APK on purpose: no production manifest gains an activity,
// and the screenshot harness cannot ship in the AAR.
package com.phonedsh.ui.screenshot

import androidx.activity.ComponentActivity

class ScreenshotActivity : ComponentActivity()
