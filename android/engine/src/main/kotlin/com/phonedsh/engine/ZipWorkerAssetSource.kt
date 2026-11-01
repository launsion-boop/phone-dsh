// phone-dsh — :engine / com.phonedsh.engine: worker bundle read out of a zip.
// SPDX-License-Identifier: MIT
//
// Why a zip instead of loose assets: AGP's asset merge gunzips every asset whose
// file name ends in `.gz` and drops the suffix (MergedAssetWriter's
// AssetWorkAction -> AssetItem.shouldBeUnGzipped, no Gradle switch). That turns
// `image.tar.gz` into `image.tar` with DIFFERENT bytes, and the bundle addresses
// its archives by their `.gz` names (boot.js `?image=`, manifest.json `lazy/*`).
// The build packs the bundle into ONE asset (`assets/worker-bundle.zip`); entry
// names and bytes then survive the APK pipeline untouched.
//
// This class is the JVM half (android-free) so ZipWorkerAssetSourceTest can
// prove entry names and bytes round-trip; ApkWorkerAssetSource only bridges
// `AssetManager` -> a cache file.

package com.phonedsh.engine

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.zip.ZipFile

/** A [WorkerAssetSource] backed by one zip file on disk. */
class ZipWorkerAssetSource(
    private val archiveFile: File,
    override val versionStamp: String,
) : WorkerAssetSource, Closeable {
    private var archive: ZipFile? = null

    /** True while the zip handle is open; the instrumented test can assert cleanup. */
    val isOpen: Boolean get() = archive != null

    override fun listAssets(): List<String> {
        val entries = zip().entries()
        val found = ArrayList<String>()
        while (entries.hasMoreElements()) {
            val entry = entries.nextElement()
            if (entry.isDirectory) continue
            found.add(entry.name)
        }
        found.sort()
        return found
    }

    override fun open(assetPath: String): InputStream {
        val zip = zip()
        val entry = zip.getEntry(assetPath)
            ?: throw IOException("the worker bundle zip has no entry '$assetPath'")
        return zip.getInputStream(entry)
    }

    override fun close() {
        runCatching { archive?.close() }
        archive = null
    }

    private fun zip(): ZipFile {
        archive?.let { return it }
        val opened = ZipFile(archiveFile)
        archive = opened
        return opened
    }
}
