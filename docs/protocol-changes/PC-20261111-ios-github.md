# iPhone GitHub connector

The [GitHub OAuth revision](../../spec/v1/github-oauth.md) replaces manual token entry.

```yaml
change: PC-20261111-ios-github
contracts: [P09, P18]
status: frozen
breaking: false
version_decision: Add an iPhone route and one new Keychain record. Keep existing protocols and records compatible.
base: bddb6d5b070ae96f107e4b50a60b1ed9e1935d28
contract_revision: PC-20261111-ios-github@1
```

Discover lists GitHub immediately below Gmail. Its detail sheet opens the
account page. A user can enter a GitHub.com fine-grained personal access
token, see the authenticated login and accessible repositories, open a
repository in GitHub, or disconnect the phone. Other platforms have separate
release plans. The Bot protocol and Worker receive no new messages.

The app issues HTTPS GET to `api.github.com/user` and
`api.github.com/user/repos` with GitHub's 2022-11-28 API version.
Repository metadata requires read permission. Pages contain up to 30 rows.
The app uses GitHub's next-page indication and builds the next request from
the fixed endpoint. Credentials travel in the Authorization header. Requests
reject redirects. Repository links must use HTTPS and the exact GitHub.com
host. A 401 requires reconnection. Rate limit, forbidden and transport
failures show a retryable notice. Cancelled or superseded operations cannot
restore a disconnected session.

After verification, the app stores one UTF-8 token in the device-only
Keychain service `dev.phone-dsh.probe.github`, account `access-token`,
using the existing secret store. Disconnect deletes this record and clears
local results. The user can revoke the token in GitHub settings. Repository
metadata stays in memory. No secret enters another service, a model, logs,
or app preferences.

Older app builds ignore the new Keychain service. On first open with no record,
the page offers connection. A new build restores only the record it owns.
Rollback keeps other credential stores readable and leaves this token removable
in GitHub settings. GitHub owns the REST response schema.

The coordinator owns the contract and its P09 projection. The iPhone worker
owns the API, Keychain adapter use, native UI and regression tests.
`GitHubConnectorAPITests` uses URLProtocol fixtures for a valid login and
repository page, a rejected token and invalid link data. The navigation
test checks the order and opens the connector through Discover.
