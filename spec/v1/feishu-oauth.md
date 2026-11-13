# Feishu connector authorization

Revision `feishu-oauth-v1`. Adds the native Feishu connector to the 发现 page
next to Gmail and GitHub. The broker is implemented by the Tono platform
(`services/api/internal/feishuoauth` in the TonoPlatform repository) and
published under `contracts/openapi/tonoai-feishu-oauth-v1.yaml`; this document
is the client-side contract the iOS app relies on.

## User flow

Discover shows a 飞书 row with the 连接 pill. Its sheet opens the Feishu
connection page. Connect opens Feishu's OAuth page in the Feishu app via
[Feishu Applink](https://open.feishu.cn/document/uAjLw4CM/uYjL24iN/mobile-app/integrate-via-app-link).
If iOS cannot open the Applink in an installed app, Connect opens the same
OAuth URL in the iOS system authentication session. The user can cancel the
pending request and switch accounts in Feishu before connecting again. Both
paths require the same broker callback and validate it against the active
attempt before exchanging the code. Feishu asks the person to grant
`drive:drive:readonly` (read the root of their own cloud space) and
`offline_access` (issue a refresh token). The app then reads the signed-in
name and the root listing of that person's cloud space, and shows them on the
same page. Disconnect clears the local tokens immediately and asks the broker
to revoke them.

The Feishu App Secret never reaches the phone: the app only receives the
short-lived `user_access_token` and its `refresh_token`.

## HTTP boundary

The app uses a configured HTTPS broker origin and the public Feishu App ID.
The iOS build settings are `PDSH_FEISHU_OAUTH_ORIGIN` and
`PDSH_FEISHU_APP_ID`. If either is unset or invalid, the page reports an
unconfigured build and contacts nothing.

The app generates a fresh unpredictable state and RFC 7636 verifier for every
attempt and sends the S256 challenge to Feishu. Its redirect URI is
`<origin>/v1/feishu/oauth/callback`, which must be registered in the Feishu
developer console exactly; the verifier never enters a URL.

| Method and path | Request | Success |
| --- | --- | --- |
| GET /v1/feishu/oauth/callback | One state plus one code or `error=access_denied` from Feishu | 302 to fixed `phonedsh-feishu://oauth/callback` with only state and code, or state and normalized `access_denied` |
| POST /v1/feishu/oauth/exchange | JSON `{"code":"...","code_verifier":"..."}` | 200 JSON `{"access_token":"...","expires_in":7200,"refresh_token":"...","refresh_token_expires_in":604800,"scope":"..."}` |
| POST /v1/feishu/oauth/refresh | JSON `{"refresh_token":"..."}` | 200 JSON with the same shape and new tokens |
| POST /v1/feishu/oauth/revoke | JSON `{"token":"..."}` | 204, including an already missing or already revoked token |

State is 43 base64url characters. Feishu codes are 1 to 512 URL-safe ASCII
characters (letters, digits, underscore, or hyphen). Verifiers are 43 to 128
RFC 7636 unreserved characters. Access and refresh tokens are printable ASCII
without spaces, 8 to 4096 bytes. Callback duplicates, conflicting fields, a
wrong callback URI, a wrong state, or any query parameter other than
`state`, `code` and `error` must not be accepted. App POST bodies are limited
to 4 KiB and reject unknown fields and trailing JSON.

The broker exchanges codes at Feishu's token endpoint with its server-only App
Secret and the configured exact redirect URI, using the PKCE verifier. It
refreshes with the same credentials. Both upstream requests reject redirects,
have a ten-second timeout, and are never retried automatically. The broker
returns 400 `invalid_request`, 401 `authorization_failed`, 502
`feishu_unavailable`, or 503 `feishu_not_configured` as JSON
`{"error":"..."}`. Every response is `no-store`. No code, token, secret or
callback query is logged by the broker, and no Feishu error description enters
a response body.

The client validates the callback against the current attempt before exchange.
Cancel, stale responses, an invalid token, and disconnect cannot restore a
superseded connection. The app stores the access and refresh tokens as UTF-8 in
the device-only Keychain slot `dev.phone-dsh.probe.feishu` and discards both on
disconnect or when the broker rejects them. It refreshes silently once before
asking for a new authorization. Feishu documents that a root listing request
without `folder_token` returns the whole listing and does not paginate, so the
page shows one page sorted by last edited and offers refresh rather than a
next-page control.

## Feishu permissions

Phone DSH operates one Feishu Store app for use across enterprises. After
their enterprise enables the app, each user authorizes their own Feishu
account. The app needs the `drive:drive:readonly` and `offline_access` user
scopes and `<origin>/v1/feishu/oauth/callback` registered under 安全设置.
A missing scope surfaces as Feishu error 20027 on the authorization page; the app shows its
fixed authorization-failure copy and never a raw Feishu string.

## Compatibility and acceptance

The connector adds one Discover row and one page; it changes no existing route
and no other connector. Acceptance needs, in order: the two simulated test
suites (`FeishuOAuthTests`, `FeishuConnectorAPITests`), a broker round trip
against the Tono platform with a real App ID, and a device pass that connects,
reads the root listing, refreshes after expiry, and disconnects. Verify the
return from the installed Feishu app and the web fallback on a device where
the Applink cannot open Feishu. A build without both build settings must show the unconfigured state and make no
request.
