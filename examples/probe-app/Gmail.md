# Connect Gmail on iPhone

Phone DSH uses an iOS OAuth client to search and read Gmail on the phone. Use a Google Cloud project you control and an account with a test mailbox.

1. Enable the [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com) in the project.
2. Configure the [OAuth audience](https://console.cloud.google.com/auth/audience). For an external app in Testing, add the Google account you will use as a test user.
3. In [Data Access](https://console.cloud.google.com/auth/scopes), declare `https://www.googleapis.com/auth/gmail.readonly`.
4. In [Clients](https://console.cloud.google.com/auth/clients), create an **iOS** client with the exact bundle ID of the signed app. The probe project defaults to `dev.phone-dsh.probe`.
5. Set the OAuth client ID and reversed client ID as build settings on the app target. For a client ID of the form `<id>.apps.googleusercontent.com`, the URL scheme is `com.googleusercontent.apps.<id>`.

For an existing signing setup, pass the two settings when you build:

```sh
cd examples/probe-app
xcodegen generate
xcodebuild -scheme PhoneDSHProbe -destination 'generic/platform=iOS' \
  PDSH_GMAIL_IOS_CLIENT_ID='<id>.apps.googleusercontent.com' \
  PDSH_GMAIL_REDIRECT_SCHEME='com.googleusercontent.apps.<id>' build
```

The client ID identifies the app. The iOS flow does not require a client secret.

On the installed app, open **Discover → Gmail → Open Gmail**. Connect the test account, search for a message with a known subject, and open it. Relaunch the app and repeat the search to check that access restores. Then disconnect and relaunch again. The app should ask you to connect before showing the inbox.

If the app reports that Gmail sign-in is not configured, check that both build settings are present in the installed bundle and match each other. If Google denies access, check that the client bundle ID matches the signed app, Gmail API is enabled, and the account can authorize the scope. For an external app in Testing, refresh tokens for this scope expire after seven days. See [Google's iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating) and [OAuth token expiration](https://developers.google.com/identity/protocols/oauth2#expiration).


## Verify replies on an iPhone

For a review build, add `PDSH_GMAIL_REPLY_ENABLED=YES` to the build command
and configure `https://www.googleapis.com/auth/gmail.send` for the review
OAuth project. The default build only requests read access.

Use two dedicated test accounts. Send a plain test message to the account
you connect in Phone DSH. In **Discover → Gmail → Open Gmail**, connect the
account and open the test message. Tap **Reply**, enter text, and tap
**Review reply**. Check the address and the full message before tapping
**Confirm and send**. On first use, grant the send permission in Google’s
consent screen. Check that Gmail shows the reply in the original conversation
and that the other test account received it. If Gmail cannot confirm delivery,
check the original conversation before trying again.
