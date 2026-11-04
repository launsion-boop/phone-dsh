// Where instrumented captures land on the device.
// SPDX-License-Identifier: MIT
//
// The test process owns its external files directory, so the host can pull the
// PNGs with plain `adb pull` without a permission, a content provider or a
// storage scope. The directory is keyed twice:
//
//   * by profile (`gate` / `ios-parity`): the two suites write different frames,
//     and a parity run must never be able to overwrite a gate baseline;
//   * by the *observed* system font scale: a run that silently picked up a
//     different scale writes somewhere else instead of overwriting a baseline.
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

    /** `<external files>/pdsh-screenshots/<profile>/fs-<scale>/`. */
    fun outputDir(activity: Activity, profile: ScreenshotProfile = ScreenshotProfile.active()): File =
        File(
            File(File(activity.getExternalFilesDir(null), ROOT_DIR), profile.id),
            "fs-" + fontScaleLabel(activity),
        )

    /**
     * Writes the parity-state registry next to the captures in [outputDir].
     *
     * One line per registered state, `android|ios|status|owner|screen|note`. The
     * host pulls it and cross-checks the 27 iOS files against it, so a state that
     * is renamed on either side fails the capture instead of silently dropping out
     * of the comparison.
     */
    fun writeRegistry(activity: Activity, profile: ScreenshotProfile, lines: List<String>) {
        val dir = outputDir(activity, profile)
        check(dir.isDirectory || dir.mkdirs()) { "cannot create the capture directory $dir" }
        File(dir, REGISTRY_FILE).writeText(lines.joinToString(separator = "\n", postfix = "\n"))
    }

    /** The pulled registry file name. */
    const val REGISTRY_FILE: String = "parity-registry.txt"
}
