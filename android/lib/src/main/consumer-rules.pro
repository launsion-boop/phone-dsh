# SPDX-License-Identifier: MIT
#
# R8 rules that must travel with the published AAR.
#
# `:lib` is the artifact another app depends on. The JNI surface it reaches lives
# in `:core` (`com.phonedsh.wire.NativeWire` / `NativeWal`), and the Rust crate
# exports `Java_com_phonedsh_wire_<Class>_<method>`. R8 cannot see that link:
# there is no Java call site that names the symbol, only `System.loadLibrary` at
# runtime. A consuming app that minifies without these rules gets
# UnsatisfiedLinkError on the first native call, and the failure looks like a
# broken library rather than a missing rule.
#
# The demo app carries the same rules in `android/app/proguard-rules.pro` because
# it builds against the modules directly; these are the copy for anyone else.
#
# `native <methods>` matches every native method of a class that declares at
# least one; only the names are pinned, so the rest of the library still shrinks.

-keepclasseswithmembernames class com.phonedsh.wire.NativeWire {
    native <methods>;
}

-keepclasseswithmembernames class com.phonedsh.wire.NativeWal {
    native <methods>;
}

# Ktor 3.x ships `io.ktor.util.debug.IntellijIdeaDebugDetector`, whose lazy
# initialiser probes the desktop JVM's java.lang.management MXBeans. Android has
# no such package and the detector never runs there, so suppress only the
# warnings R8 names rather than keeping the class.
-dontwarn java.lang.management.ManagementFactory
-dontwarn java.lang.management.RuntimeMXBean
