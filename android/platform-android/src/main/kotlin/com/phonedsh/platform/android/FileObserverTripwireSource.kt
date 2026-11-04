// The real inotify watch behind the tripwire -- device-only.
// SPDX-License-Identifier: MIT
//
// `android.os.FileObserver` is an Android stub on the host JVM, so it lives in
// its own file: [BuildSealTripwire] stays pure bookkeeping that the JVM suite
// can drive, and this class is the only piece the device suite has to prove.
//
// One watch on `/dsh/home` covers the three roots, because inotify reports a
// child's `IN_ATTRIB`/`IN_OPEN` to a watch on the child's parent. That is also
// the reason the mask is `IN_ATTRIB | IN_OPEN` and nothing else: `IN_MODIFY` on
// a sealed root would fire on the seal's own restore, and `IN_ALL_EVENTS`
// would bury the two events the design actually reasons about.

package com.phonedsh.platform.android

import android.os.FileObserver
import java.nio.file.Path

/**
 * One `FileObserver` over the `/dsh/home` mirror, feeding a [BuildSealTripwire].
 *
 * The watch is per directory and non-recursive: a `chmod` of a root named under
 * [watch] arrives with `path = "<root>"`, while a read *inside* a root would
 * arrive only on a watch of that root. That gap is deliberate -- the seal's
 * claim is about the roots being unreadable, and the act that breaks it is the
 * `chmod` on the root, which this watch sees. A recursive watch would need one
 * `FileObserver` per subdirectory and would still not be reliable (inotify's
 * queue is bounded); claiming more precision than that would overstate §4.
 *
 * The `String` constructor of `FileObserver` is deprecated in favour of the
 * `File` one, but that one is API 29 and this module's minSdk is 26; the
 * deprecated call is the only spelling that runs on every supported device.
 *
 * @param watch the directory to watch; the `/dsh/home` mirror in production.
 * @param tripwire the audit that receives the events.
 */
@Suppress("DEPRECATION")
class FileObserverTripwireSource(
    watch: Path,
    private val tripwire: BuildSealTripwire,
) : SealWatch, AutoCloseable {
    /** The watched directory, for the status line and the logs. */
    val path: Path = watch.toAbsolutePath()

    private val observer: FileObserver = object : FileObserver(
        path.toString(),
        BuildSealTripwire.WATCH_MASK,
    ) {
        override fun onEvent(event: Int, name: String?) {
            tripwire.record(name, event)
        }
    }

    /** Arms the watch; safe to call once per job. */
    override fun start() {
        observer.startWatching()
    }

    /** Disarms the watch. Events already queued stop being recorded. */
    override fun stop() {
        observer.stopWatching()
    }

    override fun close() {
        stop()
    }
}
