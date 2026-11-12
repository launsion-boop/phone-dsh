# iPhone Gmail connector

```yaml
change: PC-20261111-ios-gmail
contracts: [P09, P24]
status: frozen
breaking: false
version_decision: Add an iOS route and Xcode package pins without a wire or storage version change.
base: bddb6d5b070ae96f107e4b50a60b1ed9e1935d28
contract_revision: PC-20261111-ios-gmail@1
```

The Gmail card in Discover opens an iPhone page to connect Google, search
messages, read a selected body, and disconnect. This change is limited to the
iPhone app. The Android and HarmonyOS port work is tracked separately. The
existing P27 Bot row protocol is unaffected.

The app requests `gmail.readonly` through the Google Sign-In SDK. The client ID
and reversed URL scheme come from the iOS build. An unconfigured app shows a
setup state. Denying the scope or receiving HTTP 401 leaves the connector
disconnected and offers reconnect. Cancellation and stale requests must not
replace the current account or results. Disconnect clears visible mail and
asks Google to revoke the grant. The app calls Gmail over HTTPS. It keeps mail
in memory, skips attachment downloads, and blocks remote content in previews.

Google owns OAuth and Gmail response formats. The change adds no Phone DSH
wire fields, version, or on-disk mail data. Old clients have no Gmail page.
New clients work with the existing Worker and gateway. Rollback ignores the
SDK's local grant, which the user can remove in their Google Account.
The iOS project pins Google Sign-In and its dependencies in the Xcode workspace
lock. The root SwiftPM dependency graph is unchanged.

The coordinator owns the iOS implementation and the P09 page projections.
`GmailAPITests` drives the real client with valid query, MIME, and invalid token
fixtures. `GmailConnectorUITests` opens the page from Discover. Run those tests
with `PhoneDSHSim` and the generated UI test scheme. The existing P24 vectors
govern dependency resolution. Check the exact Xcode lock with
`xcodebuild -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile`.
