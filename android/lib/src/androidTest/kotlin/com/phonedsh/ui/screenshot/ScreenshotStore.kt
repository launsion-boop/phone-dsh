// Where instrumented captures land on the device.
// SPDX-License-Identifier: MIT
//
// The test process owns its external files directory, so the host can pull the
// PNGs with plain `adb pull` without a permission, a content provider or a
// storage scope. The directory is keyed by the *observed* system font scale: a
// run that silently picked up a different scale writes somewhere else instead of
// overwriting a baseline.
package com.phonedsh.ui.screenshot

import android.app.Activity
import java.io.File
import java.util.Locale

object ScreenshotStore {
    /** The root under the app's external files directory. */
    const val ROOT_DIR: String = "pdsh-screenshots"

    /** `fs-1.0`, `fs-2.0`, ... from the configuration's own font scale. */
    fun fontScaleLabel(activity: Activity): String =
        String.format(Locale.US, "%.1f", activity.resources.configuration.fontScale)

    /** `<external files>/pdsh-screenshots/fs-<scale>/`. */
    fun outputDir(activity: Activity): File =
        File(File(activity.getExternalFilesDir(null), ROOT_DIR), "fs-" + fontScaleLabel(activity))
}
