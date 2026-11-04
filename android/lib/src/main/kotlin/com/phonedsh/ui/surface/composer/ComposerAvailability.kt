// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface.composer

/** Explicit host callback availability. Unknown is unavailable; Compose cannot infer it from a lambda. */
public data class ComposerAvailability(
    public val addImages: Boolean = false,
    public val addFiles: Boolean = false,
    public val speakRecentReply: Boolean = false,
    public val selectAccessMode: Boolean = false,
    public val selectModel: Boolean = false,
    public val answerQuestions: Boolean = false,
    public val dismissQuestions: Boolean = false,
    public val approvePlans: Boolean = false,
    public val requestPlanChanges: Boolean = false,
)
