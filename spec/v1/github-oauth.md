# GitHub connector authorization

P05, P09, P18. Revision `github-oauth-v1`. Replaces the manual token entry in
[the original connector change](../../docs/protocol-changes/PC-20261111-ios-github.md).
Base for this revision is `fd33a55da041488630def60930bce78f5c87e680`.

## User flow

Discover opens the native GitHub connection page. Connect opens GitHub in the
iOS system authentication session. The GitHub App has repository Metadata
read permission and issues expiring user tokens. Users choose the repositories
when installing or configuring the GitHub App on GitHub. If the installation
has no visible repositories, Phone DSH links to GitHub's installation page
and offers refresh. Phone DSH displays the account and repositories authorized
to the token using the existing GitHub REST reads. Repository data stays in
app memory. The broker handles authorization only.

## HTTP boundary

The app uses a configured HTTPS broker origin, GitHub App client ID, and app
slug. The iOS build settings are `PDSH_GITHUB_OAUTH_ORIGIN`,
`PDSH_GITHUB_OAUTH_CLIENT_ID`, and `PDSH_GITHUB_APP_SLUG`. If unset or
invalid, the connection page shows that the build is unconfigured.

The app generates a fresh unpredictable state and RFC 7636 verifier for each
attempt, and sends the S256 challenge to GitHub. Its redirect URI is
`<origin>/v1/github/oauth/callback`. The verifier never enters a URL.

| Method and path | Request | Success |
| --- | --- | --- |
| GET /v1/github/oauth/callback | One state and one code or error from GitHub | 302 to fixed `phonedsh-github://oauth/callback` with only state and code, or state and normalized `access_denied` |
| POST /v1/github/oauth/exchange | JSON `{"code":"...","code_verifier":"..."}` | 200 JSON `{"access_token":"ghu_...","expires_in":28800}` |
| POST /v1/github/oauth/revoke | JSON `{"access_token":"ghu_..."}` | 204, including an already missing token |

State is 43 base64url characters. Codes are 1 to 512 URL-safe ASCII
characters (letters, digits, underscore, or hyphen). Verifiers are 43 to
128 RFC 7636 unreserved characters. User access tokens have the `ghu_`
prefix and 1 to 251 ASCII letters, digits, or underscores after it.
Callback duplicates, conflicting fields, or a wrong URI or state must not
be accepted. App POST bodies are limited to 4 KiB and reject unknown fields.
The broker exchanges codes at GitHub using its server-only Client Secret and
the configured exact redirect URI. GitHub enforces one-time redemption and
PKCE. It revokes through GitHub's app token API. Both upstream requests reject
redirects, have a ten-second timeout, and are never retried automatically.
The broker returns 400 `invalid_request`, 401 `authorization_failed`, or
502 `github_unavailable` as JSON `{"error":"..."}`. Every response is
`no-store`. No code, token, secret or callback query is logged by the broker.
No token or provider error description enters a callback URL.

The client validates the callback against the current attempt before exchange.
Cancel, stale responses, invalid token, and app disconnect cannot restore a
superseded connection. The app stores only the expiring access token as UTF-8
in the existing device-only Keychain slot. It discards an old PAT when the
connector opens. It offers reauthorization after token expiry. Disconnect
clears local results and the saved token immediately. If remote revocation
fails, the UI points to GitHub's authorized app settings.

## Compatibility and acceptance

The original build has no broker calls. The new build requires this broker
revision for OAuth. The broker does not change any Worker or gateway routes.
Older builds ignore OAuth service configuration and reject the new token type.
Rollback requires a fresh sign-in. Android and HarmonyOS have no consumers of
this revision.

The coordinator owns the broker and this contract. The iOS implementer owns
the native connector and its tests. Shared valid and invalid fixtures are in
`golden/github-oauth/github-oauth-cases.json`. Run
`node --test services/github-oauth/*.test.mjs` and the iOS simulator
`GitHubOAuthTests` and `GitHubConnectorUITests` targets. Real authorization
requires a registered GitHub App and a deployed broker; fixtures do not
establish live authorization.
