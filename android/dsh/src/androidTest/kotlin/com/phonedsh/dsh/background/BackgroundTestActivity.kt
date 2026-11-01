// phone-dsh — :dsh / androidTest: a visible app for foreground-service probes.
// SPDX-License-Identifier: MIT
//
// No UI: the activity exists only so the process is a real visible app, which is
// the condition under which a turn is allowed to open a foreground service or
// schedule a UIDT job.

package com.phonedsh.dsh.background

import android.app.Activity
import android.os.Bundle

class BackgroundTestActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }
}
