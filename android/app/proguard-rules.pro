# SPDX-License-Identifier: MIT
#
# R8 keep rules for the demo app.
#
# `NativeWire` and `NativeWal` are Kotlin `object`s in :core whose private
# `external fun`s are the JNI surface of `libpdsh_jni.so`. The Rust crate exports
# the symbols `Java_com_phonedsh_wire_<Class>_<method>` (see
# `shell/crates/pdsh-jni/src/lib.rs`), so both the class name and every native
# method name are part of the ABI. R8 cannot see that dependency: there is no
# Java call site that names the symbol, only `System.loadLibrary` at runtime.
# Without these rules release builds fail with UnsatisfiedLinkError on the first
# native call.
#
# The rules are deliberately `-keepclasseswithmembernames`, not `-keep class *`
# and not even `-keep class com.phonedsh.wire.NativeWire`: only the classes that
# actually declare native methods are pinned, and only their names are kept.
# The rest of :core, :engine and :app still shrink and obfuscate normally, so R8
# keeps earning its place in the release build.
#
# `native <methods>` matches every native method of the class. The rule keeps the
# names of the methods R8 retains; `-keepclasseswithmembernames` still permits
# shrinking, so an entry point with no surviving Java call site may be removed
# (harmless: nothing can invoke it, so no JNI lookup happens). Use
# `-keepclasseswithmembers` instead if every Rust export must remain in the dex
# even when unreachable.

-keepclasseswithmembernames class com.phonedsh.wire.NativeWire {
    native <methods>;
}

-keepclasseswithmembernames class com.phonedsh.wire.NativeWal {
    native <methods>;
}

# Ktor 3.x ships `io.ktor.util.debug.IntellijIdeaDebugDetector`, whose lazy
# initialiser probes the desktop JVM's java.lang.management MXBeans. Android has
# no java.lang.management package, so R8 reports them as missing. The detector is
# never invoked on Android (it is a JVM debugger check, not an app code path), so
# suppress only the two warnings R8 names in
# build/outputs/mapping/release/missing_rules.txt; do not keep the class.
-dontwarn java.lang.management.ManagementFactory
-dontwarn java.lang.management.RuntimeMXBean

# JSch (native SSH/SCP) instantiates its algorithm classes by name from its
# configuration table (`Class.forName`), including the Bouncy Castle-backed
# `com.jcraft.jsch.bc.*` selected in SshTransport, so R8 cannot see them. Its
# optional logging bridges reference libraries this app does not ship.
-keep class com.jcraft.jsch.** { *; }
-dontwarn org.slf4j.**
-dontwarn org.apache.logging.log4j.**
-dontwarn org.newsclub.net.unix.**
-dontwarn com.sun.jna.**
-dontwarn org.ietf.jgss.**
