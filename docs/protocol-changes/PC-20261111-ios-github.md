# iPhone GitHub connector

The [GitHub OAuth revision](../../spec/v1/github-oauth.md) replaces manual token entry.

```yaml
change: PC-20261111-ios-github
contracts: [P05, P09, P18]
status: frozen
breaking: false
version_decision: Add an iPhone route, one Keychain record and a broker-only authorization service. No Phone DSH wire field, Worker route or on-disk repository data changes.
base: 20ef5ca45e5d279c4cf994fd3793c1a7a4fa6a00
contract_revision: PC-20261111-ios-github@2
```

Discover lists GitHub immediately below Gmail. Its detail sheet opens the
account page. Connect opens GitHub in the iOS system authentication session;
the app generates a fresh state and RFC 7636 verifier for that attempt and
sends only the S256 challenge to GitHub. The broker receives the code at
`<origin>/v1/github/oauth/callback` and redirects to the fixed
`phonedsh-github://oauth/callback`. The app validates scheme, host, path and
state before it exchanges the code through
`POST /v1/github/oauth/exchange`. The user chooses repositories on GitHub's
installation page; the app displays the login and the authorized repository
metadata, opens a repository in GitHub, or disconnects the phone. Other
platforms have separate release plans. The Bot protocol and Worker receive no
new messages.

The app issues HTTPS GET to `api.github.com/user` and
`api.github.com/user/repos` with GitHub's 2022-11-28 API version.
Repository metadata requires read permission. Pages contain up to 30 rows.
The app uses GitHub's next-page indication and builds the next request from
the fixed endpoint. Credentials travel in the Authorization header. Requests
reject redirects. Repository links must use HTTPS and the exact GitHub.com
host. A 401 requires reconnection. Rate limit, forbidden and transport
failures show a retryable notice. Cancelled or superseded operations cannot
restore a disconnected session.

Only GitHub App user access tokens with the `ghu_` prefix are accepted. The
broker holds the GitHub App Client Secret, exchanges the authorization code
with GitHub, and revokes the token on disconnect; it stores no token and sees
no Phone DSH data. GitHub supports PKCE for OAuth and GitHub Apps since July
2025, so the broker's requested verifier is what binds the code to this
attempt even though the callback uses a custom URL scheme. The broker returns
only the access token and its lifetime, never a refresh token.

After verification, the app stores the single UTF-8 access token in the
device-only Keychain service `dev.phone-dsh.probe.github`, account
`access-token`, using the existing secret store. The record is added with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. A legacy fine-grained PAT
stored in the same slot by an earlier build is rejected by the `ghu_` check and
discarded when the page opens. Disconnect deletes this record, clears local
results, and then asks the broker to revoke the token; if revocation fails, the
page links to GitHub's authorized app settings. The token expires after the
lifetime GitHub reports, and the page then asks for a new authorization. Local
repository metadata stays in memory. No secret enters another service, a
model, logs, or app preferences.

Older app builds ignore the new Keychain service. On first open with no record,
the page offers connection. A new build restores only the record it owns.
Rollback keeps other credential stores readable and leaves this token removable
in GitHub settings. GitHub owns the REST response schema.

The coordinator owns the contract and its P09 projection. The iPhone worker
owns the API, Keychain adapter use, native UI and regression tests.
`GitHubOAuthTests` covers the PKCE attempt, callback validation and the broker
exchange/revoke client. `GitHubConnectorAPITests` uses URLProtocol fixtures for
a valid login and repository page, a rejected token and invalid link data. The
navigation test checks the order and opens the connector through Discover.
`node --test services/github-oauth/*.test.mjs` covers the broker and runs in the
`phone-github-oauth` gate.
