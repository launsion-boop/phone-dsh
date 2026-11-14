# Feishu connection on iOS

Discover uses the TonoLive native app gateway at
`https://app.tonoai.cn/api/v1` with the signed-in Tono account's access token.
The server owns Feishu credentials, account bindings, refresh, and revocation.

Use the unified Feishu snapshot for an existing authorized connection.
For first-time setup, start an authorization attempt using the server's
current recipe, open the Feishu verification link, and resume the attempt
after each confirmation. Confirm the returned reader before enabling reads.
Reuse an eligible application from a previous attempt. See the
[Unified Feishu Connection v1 contract](https://github.com/TonoTeam/TonoLive/blob/81cd6ba9665a56e6eb4d721ec4afb24173cba4dd/contracts/feishu-connection-v1/README.md).

Read a DOCX link or ID with the bound user connection. Managed bindings use
`/feishu/connections/{id}/reads` and legacy OpenConnector bindings use
`feishu.get_document_content` through the app-connections read endpoint.
