// phone-dsh — :engine / com.phonedsh.engine: logcat-backed EngineLogger.
// SPDX-License-Identifier: MIT
//
// Kept out of EngineLogger.kt so the JVM unit tests never load android.util.Log:
// they inject their own EngineLogger and the Android class is only referenced by
// code that runs on a device.

package com.phonedsh.engine

import android.util.Log

/** Routes engine lines to logcat under one tag. Never receives a token. */
class AndroidEngineLogger(private val tag: String = DEFAULT_TAG) : EngineLogger {
    override fun log(level: EngineLogLevel, message: String) {
        when (level) {
            EngineLogLevel.DEBUG -> Log.d(tag, message)
            EngineLogLevel.INFO -> Log.i(tag, message)
            EngineLogLevel.WARN -> Log.w(tag, message)
            EngineLogLevel.ERROR -> Log.e(tag, message)
        }
    }

    companion object {
        const val DEFAULT_TAG: String = "PDSHEngine"
    }
}
