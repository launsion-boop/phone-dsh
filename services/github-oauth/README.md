# Run the Phone DSH GitHub OAuth broker

Register a [GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
with Metadata read permission, expiring user access tokens, and no webhook.
Register `https://<broker-origin>/v1/github/oauth/callback` as its OAuth
callback. The broker requires an HTTPS reverse proxy for that exact origin.
The reverse proxy must omit query strings and request bodies from its logs.

Provide these settings to the Node 22 or newer process through your service
configuration:

- `GITHUB_OAUTH_ORIGIN` is the external HTTPS origin.
- `GITHUB_CLIENT_ID` is the GitHub App's public client ID.
- `GITHUB_CLIENT_SECRET` comes from the server's secret store.
- `PORT` is the internal HTTP port. It defaults to 8080.

Run `node services/github-oauth/server.mjs`. The process validates its
configuration at startup. The broker does not store tokens.

Set `PDSH_GITHUB_OAUTH_ORIGIN`, `PDSH_GITHUB_OAUTH_CLIENT_ID`, and
`PDSH_GITHUB_APP_SLUG` in the iOS build. The app uses the slug to open the
GitHub App installation page when the user needs to select repositories.

Run `node --test services/github-oauth/*.test.mjs` to verify the broker against
a stub of GitHub's endpoints. To verify a deployment, authorize the registered
app on a device, select a test repository, refresh the list, open the
repository, disconnect, and verify that relaunch requires a new connection.

See the [app and broker contract](../../spec/v1/github-oauth.md).
