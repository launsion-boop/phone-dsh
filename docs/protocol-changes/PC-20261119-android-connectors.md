<!-- SPDX-License-Identifier: MIT -->

# PC-20261119-android-connectors — Android GitHub and Gmail connectors

## 0. 摘要（機器可讀）

```yaml
change: PC-20261119-android-connectors
contracts: [P05, P09, P18]
status: frozen
breaking: false
version_decision: Add the Android consumer of github-oauth-v1 unchanged, plus an Android Gmail page. No broker route, Worker route, Phone DSH wire field or shared on-disk data changes; the new Android records are host-private.
base: 56f15487c
contract_revision: docs/protocol-changes/PC-20261119-android-connectors.md@3
```

## 1. 識別與角色

- **Trigger → 現況 → 期望.** `spec/ui/v1/pages/_baseline.json` carries
  `git-hub-connector` and `gmail-connector` as known Android divergences, and the
  Android 发现 page shows Gmail as a disabled example and has no GitHub row.
  [github-oauth.md](../../spec/v1/github-oauth.md) says Android has no consumer
  of `github-oauth-v1`. Expected: Android lists Gmail and GitHub as on iOS and
  opens native pages with the iOS behaviour described in
  [PC-20261111-ios-github](PC-20261111-ios-github.md) and
  [PC-20261111-ios-gmail](PC-20261111-ios-gmail.md).
- **Roles.** One coordinator holds contract owner, Android implementer and
  integrator. An independent reviewer pass checks the combined diff.
- **Owning contracts.** `spec/v1/github-oauth.md` (broker HTTP boundary, token
  and callback rules, shared fixture `spec/v1/golden/github-oauth/github-oauth-cases.json`);
  this record for the Android-only mechanics; `spec/ui/v1/pages/{git-hub-connector,gmail-connector,connectors}.json`
  for P09.
- **Ends.** Broker `services/github-oauth` (unchanged producer). iOS
  connector (unchanged consumer). Android connector (new consumer). Google and
  GitHub REST are upstream-owned. HarmonyOS keeps no consumer.

## 2. 契約 delta

| 項目 | Before → After |
| --- | --- |
| GitHub broker HTTP | Unchanged. Android sends the same `exchange` and `revoke` JSON bodies, validates the same state, code, verifier and `ghu_` token domains, and rejects redirects with a ten-second timeout. |
| GitHub configuration | Android reads Gradle properties `pdsh.github.oauthOrigin`, `pdsh.github.oauthClientId` and `pdsh.github.appSlug` into `BuildConfig.PDSH_GITHUB_OAUTH_ORIGIN`, `PDSH_GITHUB_OAUTH_CLIENT_ID` and `PDSH_GITHUB_APP_SLUG`, then applies the iOS validation. Missing or invalid values show the unconfigured state. |
| GitHub authorization surface | iOS `ASWebAuthenticationSession` → Android opens the authorization URL with `ACTION_VIEW` pinned to the default browser package (the one resolving a plain https link), so an app that claims github.com links never receives the attempt's state; with no default browser the platform chooser is shown. An attempt survives `MainActivity` recreation; only leaving the page while the app is in front cancels it. The fixed callback `phonedsh-github://oauth/callback` is received by an exported, no-UI `GitHubOAuthCallbackActivity`, which forwards the URI to the one pending attempt in the process and brings `MainActivity` back. No callback while waiting, followed by `MainActivity` resuming, counts as user cancellation. A callback with no pending attempt, for example after process death, completes nothing and is dropped; the page stays on its connect button. A delivered callback is validated against the attempt by the shared validator before any exchange. |
| GitHub token storage (P18) | iOS Keychain `dev.phone-dsh.probe.github`/`access-token` → Android `AndroidSecureStore` key `github.connector.access-token`: AES-GCM under an AndroidKeyStore key in `noBackupFilesDir` (`platform.keychain-credential-store`). One UTF-8 token; non-`ghu_` content is discarded on open as on iOS. The expiry stays in memory only. |
| GitHub REST | Unchanged. Same `/user` and `/user/repos` reads, same 2022-11-28 version, 30-row pages, next-page relation, `https://github.com/<owner>/<repo>` link check and error mapping. |
| Gmail authorization | iOS Google Sign-In SDK → Android Google Identity Services `AuthorizationClient` (`com.google.android.gms:play-services-auth`), scope `https://www.googleapis.com/auth/gmail.readonly`. The OAuth client is registered by package and signing certificate, so the build carries no client id; Gradle property `pdsh.gmail.enabled` (`BuildConfig.PDSH_GMAIL_ENABLED`, default `false`) marks a build whose client is registered. `false` shows the unconfigured state. A user who declines the resolution leaves the page disconnected. |
| Gmail state (P18) | New private `SharedPreferences` file `phone-dsh-gmail`, key `connected.v1` (Boolean, absent = false). It records only that the user connected, so a page open restores silently and a disconnect is not undone by an unrevoked grant. No token, address or mail is persisted; Google Play services keeps the grant. |
| Gmail REST | Unchanged from iOS: `profile`, `messages` list (12 per page, `INBOX` when the query is empty), `metadata` reads of From/Subject, `full` read for the selected message, first non-attachment `text/plain` then `text/html` part, 2 MB decode cap, 401/403/404 mapping. |
| Gmail HTML preview | iOS WKWebView with a CSP and a block-all content rule → Android `WebView` with JavaScript off, `blockNetworkLoads`, `blockNetworkImage`, file and content access off, every subresource request answered locally with an empty response, and every navigation refused. |
| Gmail disconnect | Clears results, clears `connected.v1`, then calls `AuthorizationClient.revokeAccess` for the last connected account (remembered by the host, since the mailbox leaves `Connected` first) and scope. A consent screen survives an activity configuration change. A failed revoke shows the iOS notice that points to Google Account connections. |
| 發現 page (P09) | Android connector order becomes Gmail, GitHub, devices, web search, MCP, matching iOS. Gmail and GitHub are no longer examples; their pill is 打开 and their sheet action opens the page. |
| Logs | No code, verifier, token, account address or mail content is logged on Android. |

Self-check (spec/README.md §5.1): no second representation of any broker or
REST field, no widened validation, no new wire field, no Worker env. The two
new records are platform-private and listed under P18 here.

## 3. 相容性與發佈

| Producer → Consumer | Behaviour |
| --- | --- |
| old Android → broker | Old Android makes no broker calls. |
| new Android → broker `github-oauth-v1` | Same requests as iOS; broker tests are unchanged. |
| new Android → old broker | No older broker revision exists with these routes; an unconfigured build shows the unconfigured state. |
| persisted old data → new / rollback | No earlier Android record exists. Rollback ignores the secure-store key and the Gmail preferences file; the GitHub token expires on GitHub's schedule and can be revoked in GitHub settings; the Google grant can be removed in Google Account connections. |

- The broker must allow the Android build's client id. A GitHub App and
  Google OAuth client registered for the Android package are deployment
  inputs, not repository content.
- The dependency `com.google.android.gms:play-services-auth` is added to `:app`
  only. Android has no dependency lock contract (P24 covers Apple packages
  only).

## 4. 分工與證據

- Android paths: `android/net/src/{main,test}/kotlin/com/phonedsh/connectors/**`
  (pure clients and state machines), `android/lib/.../ui/page/{GitHubConnectorPage,GmailConnectorPage,ConnectorsPage}.kt`,
  `android/app/.../probe/connectors/**`, `MainActivity.kt`, `HostShell.kt`,
  `AndroidManifest.xml`, `app/build.gradle.kts`.
- Shared fixture: `spec/v1/golden/github-oauth/github-oauth-cases.json`, read
  from disk by the `:net` tests through `pdsh.repo.root`.
- Acceptance:
  `bash android/tools/with-android-toolchain.sh ./gradlew :net:test :lib:testDebugUnitTest :app:testDebugUnitTest`,
  `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`.
- Not verifiable here: live GitHub and Google authorization, which need a
  registered GitHub App, a deployed broker and a registered Android Google
  OAuth client; browser hand-off and Play services behaviour on a device.

## 5. 修訂紀錄

| revision | 由誰 | 原因 | 通知了哪些端 |
| --- | --- | --- | --- |
| 1 | coordinator | Initial freeze. | Android |
| 2 | coordinator | Implementation found the browser path cannot tell a stale callback apart before validation; a callback with no pending attempt is dropped instead of reported as `invalidCallback`. No wire or storage change. | Android |
| 3 | coordinator | Review: pin the browser, keep an attempt across recreation, revoke with the remembered account. No wire or storage change. | Android |
