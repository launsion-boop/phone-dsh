// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.util.Base64

/**
 * One prepared image that can travel in an MCP tool result (`BotModelImage`).
 *
 * Bytes are always an encoded raster image, never a filesystem path. The
 * platform bridge decodes, orients, downscales and re-encodes the source; this
 * value only carries the already-bounded result.
 */
public class BotModelImage(
    public val mediaType: String = "image/jpeg",
    public val data: ByteArray,
    public val name: String,
    public val pixelWidth: Int,
    public val pixelHeight: Int,
) {
    override fun equals(other: Any?): Boolean =
        other is BotModelImage &&
            mediaType == other.mediaType &&
            data.contentEquals(other.data) &&
            name == other.name &&
            pixelWidth == other.pixelWidth &&
            pixelHeight == other.pixelHeight

    override fun hashCode(): Int {
        var result = mediaType.hashCode()
        result = 31 * result + data.contentHashCode()
        result = 31 * result + name.hashCode()
        result = 31 * result + pixelWidth
        result = 31 * result + pixelHeight
        return result
    }
}

/** The decode/encode failures behind `attach_to_model` (`BotModelImageError`). */
public enum class BotModelImageError {
    EMPTY,
    UNSUPPORTED,
    TOO_LARGE,
    UNAVAILABLE,
    ;
}

public class BotModelImageException(
    public val error: BotModelImageError,
    message: String,
) : Exception(message)

/** One request to hand an existing workspace file to the model. */
public data class BotModelAttachmentRequest(
    public val path: String? = null,
    public val fileId: String? = null,
    /**
     * Camera/photo artifact handles are not backed by an Android store yet.
     * The request type keeps the frozen field so the tool can refuse the
     * source explicitly instead of silently dropping it.
     */
    public val photoId: String? = null,
    /** One-based PDF page; nil means page 1. */
    public val page: Int? = null,
    public val purpose: String,
)

/**
 * The same economic bounds the design uses for a vision turn. Keep these in
 * one place so the runtime, the Android bridge and the tests agree.
 */
public object BotModelImagePolicy {
    public const val MAX_IMAGES_PER_TURN: Int = 2
    public const val MAX_DIMENSION: Int = 1_568
    public const val MAX_ENCODED_BYTES: Int = 1_048_576
}

/** The MCP `content` image-block shape of the frozen P26 contract. */
public object BotModelImagePreparer {
    /**
     * `{"type":"image","mimeType":"image/jpeg","data":"<canonical base64>","name":"…"}`.
     *
     * A canonical base64 string is required by the DSH MCP client; the encoder
     * never inserts line breaks. The block is advertised only after the bytes
     * already fit [BotModelImagePolicy.MAX_ENCODED_BYTES].
     */
    public fun mcpJSONValue(image: BotModelImage): JsonObject {
        val fields = LinkedHashMap<String, JsonValue>()
        fields["type"] = JsonString("image")
        fields["mimeType"] = JsonString(image.mediaType)
        fields["data"] = JsonString(Base64.getEncoder().encodeToString(image.data))
        fields["name"] = JsonString(image.name)
        return JsonObject(fields)
    }

    public fun structuredContent(image: BotModelImage): JsonObject = BotJson.objectOf(
        "ok" to com.phonedsh.agentcore.JsonBool(true),
        "kind" to JsonString("image"),
        "name" to JsonString(image.name),
        "bytes" to JsonNumber(image.data.size.toString()),
        "width" to JsonNumber(image.pixelWidth.toString()),
        "height" to JsonNumber(image.pixelHeight.toString()),
    )
}
