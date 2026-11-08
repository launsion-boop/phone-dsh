# Official DeepSeek Search and Fetch on Android, Harmony and iOS

For a selected model service on `https://api.deepseek.com` at port 443, the host may reuse
its saved model credential for the official Search and Fetch API. The supported model base
paths are `/`, `/v1`, `/anthropic` and `/anthropic/v1`, with an optional trailing slash.
A base URL with user information, a query or a fragment is ineligible. A missing or
unreadable key leaves the search capability disabled at startup.

The reuse grant covers only POST to the two canonical URLs
`https://api.deepseek.com/v1/tools/search` and `https://api.deepseek.com/v1/tools/fetch`.
It grants no other origin, path, method, URL alias or redirect. The host strips caller
credentials, then injects the saved model key as Bearer authentication regardless of
the model encoder. Each request resolves the key again. A missing or unreadable key
fails before contacting the upstream. Responses must not expose the key.
In a cookie-authenticated phone Worker launch, the bridge uses the existing
`PDSH_DSH_LAUNCH_TOKEN` as the bearer on `/v1/http` when there is no explicit
channel or exec-bridge token. This fallback is scoped to the two canonical URLs
above when the official Search API is selected. Other requests keep their existing
transport. The bridge must not send those two requests directly if the host
route or launch bearer is unavailable.

On iOS, follow-model mode uses this grant with the selected model key.
Independent Search/Fetch mode keeps its own endpoint and credential routing.
The [independent Search/Fetch clause](gateway-independent-search.md) defines that
mode's base URL, operations and cookie route. It replaces this grant when it is selected.
The Worker receives the existing provider IDs, official base URL, and placeholder.
The gateway resolves the grant before dispatch and refuses redirects for this grant.

The [shared route cases](golden/gateway/official-deepseek-web/cases.json) exercise
the model base and request scope rules on the phone hosts. The existing gateway schema,
`/v1/http` envelope, failure vocabulary and general redirect rules are unchanged.
