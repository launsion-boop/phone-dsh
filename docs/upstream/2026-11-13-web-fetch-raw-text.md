# Pending proposal — `web_fetch` must return raw `text/plain` files

Date: 2026-11-13
Component: DSH `tool-web` + `web-deepseek-api` (pinned 0.2.2-rc.1, commit
`66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`)
Phone profile: `plugins/profile/phone.worker.cordis.patch.yml` (independent
Search/Fetch mode selected `deepseek-fetch-api` on 2026-11-13; phone-dsh now
selects the host-routed `phone-host-fetch` provider, see below)

## Observed

On the iPhone build, `web_fetch` against a public raw source file returns:

```
HTTP 404: … the URL may be missing, blocked by the site, an unsupported
content type, or have no extractable Markdown
```

Same URL, same moment:

- `curl -L <same URL>` → **200**, 23,532 bytes, `content-type: text/plain; charset=utf-8`;
- `web_fetch https://example.com` → **200** (so the tool and the network path work);
- `bash curl` from the same Worker → 200 (so the host egress allow-list admits the
  host).

The 404 text is the remote DeepSeek Fetch API's own retrieval failure, not a
phone-dsh network error. The tool's local body renderer would accept `text/plain`
(`packages/web/web-fetch-http/src/policy.ts` classifies any `text/*` as `text`),
but that provider is not the one selected on the phone.

## Phone status (2026-11-13): fixed by the host-routed provider

phone-dsh now selects `phone-host-fetch` in independent mode
([PC-20261113-host-fetch-provider](../protocol-changes/PC-20261113-host-fetch-provider.md)).
That provider uses the Worker's global `fetch` (already carried over the host
`/v1/http` route and its egress allow-list) and returns `text/plain` verbatim,
so the phone no longer sends raw sources to the remote extractor. The upstream
proposal below remains valid for the official `/fetch` operation and for other
clients that still select it.

## Why the remote `/fetch` still needs upstream

The Worker profile pins the fetch provider:

- `web.fetchProvider = $PDSH_WEB_FETCH_PROVIDER` (independent mode:
  `deepseek-fetch-api`), and
- `web-fetch-http` is deliberately `disabled: true` in the Worker because it
  imports `undici`/`node:dns` directly and has no host route
  (`plugins/profile/phone.worker.cordis.patch.yml`, the `web` / `web-fetch-http` /
  `web-deepseek-api` rows).

phone-dsh may not patch DSH source (`scripts/ci/no_dsh_patch.py`), so the choice
of provider and its 404 mapping belong upstream. A phone-side allow-list change
would not help: the URL already passes the egress list for `curl`, and the
failure happens inside the remote fetch service after the request leaves the
phone.

## Proposal (smallest useful delta)

Either is enough:

1. **Accept `text/plain` in the official `/fetch` operation.** Return
   `{ kind: "text", content: <verbatim body>, statusCode: 200 }` for a raw text
   resource instead of a retrieval 404. The response should preserve the real
   upstream status separately when the URL itself is 404, so "upstream missing"
   and "unsupported content type" stop sharing one message.
2. **Add a DSH fetch provider that uses the already-installed global `fetch`.**
   phone-dsh's `llm-bridge` installs a `fetch` that routes `/v1/http` through the
   host and applies the egress allow-list
   (`plugins/llm-bridge/src/install.ts`); a provider built on it would work in the
   Worker without `undici`, and the official API could stay the default for
   search. The provider id would be an explicit profile choice, not a silent
   fallback.

## Workaround available today (no code change)

- `github get <owner>/<repo> <path>` for repository files.
- `bash` + `curl -L <url>` for any allow-listed public host.

Both return the bytes; neither depends on the remote extractor.

## Status

Open for the official `/fetch` operation. This note is a proposal, not a patch:
not applied to the pinned DSH checkout and not vendored here. The phone's
`phone-host-fetch` provider is a local workaround, tested in
`plugins/tests/web-fetch-host.test.ts`; it does not prove or change the remote
API's content-type behaviour. The evidence above is the field observation plus
the local profile/egress facts.
