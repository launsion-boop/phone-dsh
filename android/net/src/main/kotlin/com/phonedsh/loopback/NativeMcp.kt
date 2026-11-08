// phone-dsh — :net / com.phonedsh.loopback: the in-process `/mcp/native` endpoint.
// SPDX-License-Identifier: MIT
//
// Kotlin end of `Sources/PhoneDSHLoopback/NativeMCP.swift` (spec/v1/native-mcp.md).
// The server is reached only through this origin's token gate: no second
// listener, no unauthenticated path. The origin answers `tools/call` with 503
// while host admission is closed; every other request (including cancellation)
// reaches the server.

package com.phonedsh.loopback

/** One authenticated `/mcp/native` request. Header names are kept as received. */
public class NativeMcpRequest(
    public val method: String,
    public val headers: Map<String, String>,
    public val body: ByteArray,
) {
    /** Case-insensitive header lookup. */
    public fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

/** The JSON body (or empty for 202/405) and its status. */
public class NativeMcpResponse(public val status: Int = 200, public val body: ByteArray = ByteArray(0))

public interface NativeMcpServing {
    public suspend fun handle(request: NativeMcpRequest): NativeMcpResponse

    /** Host shutdown: cancel pending native work and wait until its outcome is recorded. */
    public suspend fun cancelPendingOperations() {}
}

/** The JSON-RPC `method` of a request body, or `null` when it is not a JSON object with one. */
internal object NativeMcpMethod {
    fun of(body: ByteArray): String? = try {
        ((com.phonedsh.agentcore.JsonValue.parse(String(body, Charsets.UTF_8)) as? com.phonedsh.agentcore.JsonObject)
            ?.get("method") as? com.phonedsh.agentcore.JsonString)?.value
    } catch (failure: Exception) {
        null
    }
}
