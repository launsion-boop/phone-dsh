// phone-dsh — :loopback / com.phonedsh.loopback: the D22 launch cookie.
// SPDX-License-Identifier: MIT
//
// Protocol (D22): the launch page may be opened as `GET /?token=<launch token>`.
// The origin answers 303 to `/` and sets a cookie carrying the same per-start
// token, so page-relative requests carry the credential without a token in a
// URL. The launch route is the one place the token is allowed in a URL; the
// cookie is the one place it is stored.
//
// Attribute source is the iOS baseline, not this module's invention:
//
//   * name: `Sources/PhoneDSHLoopback/LoopbackServer.swift:112`
//     `public static let launchCookieName = "xl_launch_token"`;
//   * value: `Sources/PhoneDSHLoopback/LoopbackServer.swift:636-641`
//     `launchCookie(name:token:)` returns
//     `"\(name)=\(token); Path=/; HttpOnly; SameSite=Strict"`.
//
// It deliberately has no `Secure` (the origin is loopback HTTP, so a Secure
// cookie would never be sent) and no `Domain`, so every user agent binds it to
// the request authority that received it — a host-only cookie. The authority
// binding is also enforced server-side: [LoopbackService] only issues and
// honors this cookie when the request's `Host` is this origin's own authority.
//
// The value is a per-start secret: this file never logs it, and the only
// conversions it offers are the wire forms (`Set-Cookie`, `Cookie`).

package com.phonedsh.loopback

/** The D22 launch cookie of the loopback origin. */
object LaunchCookie {
    /** The cookie name of the iOS baseline (`LoopbackServer.swift:112`). */
    const val NAME: String = "xl_launch_token"

    /**
     * The exact `Set-Cookie` value of the D22 exchange.
     *
     * `Path=/` so the page, every subresource and `/channel` see it; `HttpOnly`
     * keeps page script from reading it; `SameSite=Strict` keeps it on this
     * origin. No `Secure` and no `Domain` (iOS baseline, lines 636-641).
     */
    fun headerValue(token: String): String = "$NAME=$token; Path=/; HttpOnly; SameSite=Strict"

    /** The deletion form used when an origin goes away: same name, expired. */
    fun deletionValue(): String = "$NAME=; Path=/; Max-Age=0"

    /**
     * Reads [NAME] from a `Cookie` header.
     *
     * Mirrors the iOS reader (`LoopbackServer.swift:623-634`): repeated cookie
     * headers may be joined with `, `, so both separators are accepted, and the
     * value is trimmed. Returns null when the cookie is absent.
     */
    fun value(cookieHeader: String?): String? {
        if (cookieHeader == null) return null
        for (segment in cookieHeader.split(';', ',')) {
            val trimmed = segment.trim()
            val equals = trimmed.indexOf('=')
            if (equals <= 0) continue
            if (trimmed.substring(0, equals).trim() != NAME) continue
            return trimmed.substring(equals + 1).trim()
        }
        return null
    }

    /**
     * True when [token] can be a cookie value (RFC 6265 `cookie-octet`).
     *
     * The App's tokens are lowercase hex, so this is only a guard for a pinned
     * test/deployment token: a `;`, `,`, `"` or `\` in a token would corrupt the
     * header, and the origin then keeps the pre-D22 page response instead.
     */
    fun isSafeValue(token: String): Boolean = token.isNotEmpty() && token.all { character ->
        val code = character.code
        code in 0x21..0x7E && character != '"' && character != ',' &&
            character != ';' && character != '\\'
    }
}
