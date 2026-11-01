// phone-dsh — :engine / com.phonedsh.engine: the APK asset -> worker bundle bridge.
// SPDX-License-Identifier: MIT
//
// `assets/worker-bundle.zip` is produced by the `packageWorkerBundle` Gradle task
// (engine/build.gradle.kts) from examples/probe-app/Bundle/worker; see
// ZipWorkerAssetSource for why the bundle is one zip and not loose assets.
//
// `AssetManager.open` is a stream, while reading a zip wants random access, so the
// first use copies the 65 MB asset into `cacheDir` once per process, opens it as a
// ZipFile and deletes the copy when WorkerAssets is done. Peak extra disk is one
// bundle copy; nothing here outlives the materialization.

package com.phonedsh.engine

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.InputStream

/**
 * Reads the packaged worker bundle from the APK.
 *
 * The version stamp is the installing APK's identity — versionCode plus
 * lastUpdateTime — not a hash of 65 MB of assets: the assets can only change when
 * the APK is replaced, and the stamp is checked on every start, so a reinstall or
 * an upgrade copies the bundle once and a process restart copies nothing.
 */
class ApkWorkerAssetSource(
    context: Context,
    private val bundleAsset: String = BUNDLE_ASSET,
) : WorkerAssetSource, Closeable {
    private val appContext: Context = context.applicationContext ?: context
    private val assets = appContext.assets
    private var delegate: ZipWorkerAssetSource? = null
    private var scratchFile: File? = null

    override val versionStamp: String by lazy { apkStamp(appContext) }

    override fun listAssets(): List<String> = delegate().listAssets()

    override fun open(assetPath: String): InputStream = delegate().open(assetPath)

    /** Closes the zip and deletes the cache copy. Safe to call twice. */
    override fun close() {
        delegate?.close()
        delegate = null
        scratchFile?.delete()
        scratchFile = null
    }

    /**
     * Copies the asset into `cacheDir` on first use and opens it as a zip.
     *
     * The copy is 65 MB of one-shot I/O inside the materialization that already
     * runs on Dispatchers.IO; the cache file is deleted by [close].
     */
    private fun delegate(): ZipWorkerAssetSource {
        delegate?.let { return it }
        val cacheDir = File(appContext.cacheDir, CACHE_DIR)
        if (!cacheDir.isDirectory && !cacheDir.mkdirs()) {
            throw IOException("cannot create the bundle cache directory $cacheDir")
        }
        val target = File(cacheDir, "worker-bundle.zip")
        assets.open(bundleAsset).use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        val opened = try {
            ZipWorkerAssetSource(target, versionStamp)
        } catch (failure: Throwable) {
            target.delete()
            throw failure
        }
        scratchFile = target
        delegate = opened
        return opened
    }

    private fun apkStamp(context: Context): String {
        val packageInfo = packageInfo(context)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
        return "$bundleAsset:$versionCode:${packageInfo.lastUpdateTime}"
    }

    private fun packageInfo(context: Context): PackageInfo =
        try {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (missing: PackageManager.NameNotFoundException) {
            throw IllegalStateException("the App package is not installed?", missing)
        }

    companion object {
        /** Asset path of the bundle archive inside the APK (see packageWorkerBundle). */
        const val BUNDLE_ASSET: String = "worker-bundle.zip"

        private const val CACHE_DIR = "pdsh-worker-bundle"
    }
}
