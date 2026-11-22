// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.page.chat

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotAttachmentPolicy
import com.phonedsh.ui.bot.driver.BotDraftAttachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

@Composable
internal fun BotAttachmentMenu(
    expanded: Boolean,
    dismiss: () -> Unit,
    remaining: Int,
    onPicked: (List<BotDraftAttachment>, List<String>) -> Unit,
) {
    val resolver = LocalContext.current.contentResolver
    val scope = rememberCoroutineScope()
    val accept: (List<Uri>) -> Unit = { uris ->
        if (uris.isNotEmpty()) scope.launch {
            val (files, errors) = withContext(Dispatchers.IO) {
                val files = mutableListOf<BotDraftAttachment>()
                val errors = mutableListOf<String>()
                for (uri in uris) {
                    if (files.size >= remaining) {
                        errors += "每条消息最多 10 个附件。"
                        break
                    }
                    try {
                        files += readPickedFile(resolver, uri)
                    } catch (e: IllegalArgumentException) {
                        errors += e.message ?: "无法读取所选附件。"
                    } catch (_: Exception) {
                        errors += "无法读取所选附件。"
                    }
                }
                files to errors
            }
            onPicked(files, errors)
        }
    }
    val photos = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(BotAttachmentPolicy.MAX_COUNT), accept,
    )
    val documents = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments(), accept)
    DropdownMenu(expanded = expanded, onDismissRequest = dismiss) {
        DropdownMenuItem(text = { Text("照片") }, onClick = {
            dismiss()
            photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        })
        DropdownMenuItem(text = { Text("文件") }, onClick = {
            dismiss()
            documents.launch(arrayOf("*/*"))
        })
    }
}

private fun readPickedFile(resolver: ContentResolver, uri: Uri): BotDraftAttachment {
    require(uri.scheme == ContentResolver.SCHEME_CONTENT) { "无法读取所选附件。" }
    val meta = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
        if (!it.moveToFirst()) null else {
            val name = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val size = it.getColumnIndex(OpenableColumns.SIZE)
            (if (name >= 0) it.getString(name) else null) to
                (if (size >= 0 && !it.isNull(size)) it.getLong(size) else null)
        }
    }
    val name = meta?.first?.takeIf(String::isNotBlank) ?: "file"
    val limit = BotAttachmentPolicy.MAX_BYTES
    require((meta?.second ?: 0) <= limit) { "附件「$name」超过 25 MiB。" }
    val size = resolver.openInputStream(uri)?.use { input ->
        val buffer = ByteArray(64 * 1024)
        var count = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            count += read
            require(count <= limit) { "附件「$name」超过 25 MiB。" }
        }
        count
    } ?: 0L
    require(size > 0) { "附件「$name」为空或无法读取。" }
    val mime = resolver.getType(uri) ?: "application/octet-stream"
    return BotDraftAttachment(UUID.randomUUID().toString(),
        BotAttachment(name, "", size, mime, BotAttachmentPolicy.kind(name, mime)), uri.toString())
}
