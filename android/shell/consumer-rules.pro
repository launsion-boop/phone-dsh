# SPDX-License-Identifier: MIT
# R8 keep rules shipped with the :shell AAR. Without these, release builds can
# fail at System.loadLibrary / native registration time while debug works.
-keepclasseswithmembernames class com.phonedsh.shell.** {
    native <methods>;
}
-keep class com.phonedsh.shell.** { *; }
