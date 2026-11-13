# Independent Search and Fetch API on a cookie-authenticated phone Worker

Status: normative for the Android host and the shared Worker bridge. It extends
[official DeepSeek web tools](gateway-official-web.md); everything that clause
leaves unchanged stays unchanged. Change record:
[PC-20261108-independent-search](../../docs/protocol-changes/PC-20261108-independent-search.md).

The person may select an independent Search/Fetch service instead of following the
model service (iOS 「独立 DeepSeek 搜索 API」, Android 「自己填一个」). It has its own base
URL and its own key. The key is never the model key, and the model key is never used
for it.

## 1. Base URL

A host accepts an independent base only through this normalization. The
[shared cases](golden/gateway/independent-search/cases.json) (`bases`) are the judge;
`canonical: null` means invalid.

1. Trim leading and trailing ASCII whitespace.
2. The scheme is `https`, compared case-insensitively, followed by `://`.
3. The string contains no `?`, `#`, `%`, `\`, `@`, whitespace, control or non-ASCII
   character. The authority contains no `:` (no explicit port, not even `:443`),
   no `[` or `]`.
4. The host is lowercased. It is a DNS name of at least two labels, at most 253
   characters, each label 1–63 characters of `a-z`, `0-9` and `-`, neither starting
   nor ending with `-`. The last label contains a letter, which excludes IPv4
   literals; `localhost` has one label and is excluded. No empty label (no `..`,
   no trailing `.`).
5. The path is empty, `/`, or `/`-separated segments with at most one trailing `/`.
   Each segment is one or more of `A-Z a-z 0-9 . _ ~ -` and is neither `.` nor `..`.
   An empty segment (`//`) is invalid. Path case is kept.
6. The last segment is not `search` or `fetch`, compared case-insensitively.
7. The canonical base is `https://` + host + path without the trailing `/`. A root
   path gives `https://host`. A canonical base is at most 512 characters.

The base is not secret. A host stores only the canonical spelling.

## 2. Operations and gateway grant

The grant covers exactly two operations: `POST <canonical>/search` and
`POST <canonical>/fetch`. The method is compared after trimming, case-insensitively.
The URL is compared as an exact string with no normalization, so a query, fragment,
explicit port, trailing `/`, percent-encoding, case change or extra segment is a
different URL. The cases in `requests` are the judge.

For an admitted request the host:

- resolves the independent key at request time from the independent account; a missing
  or unusable key fails `credential_unavailable` before any upstream contact and never
  falls back to the model key;
- strips caller credentials (`authorization`, `proxy-authorization`,
  `x-pdsh-upstream-authorization`, `x-api-key`, `api-key`, `x-dsh-auth-token`) and
  injects `Authorization: Bearer <independent key>` last;
- refuses every redirect and contacts only the admitted URL;
- treats the exchange as sensitive: no response-log record, the key is redacted from
  the response body and headers, `cache-control: no-store`.

A refused method or URL gets the existing `invalid_request` refusal or the existing
diagnostic `/v1/http` policy. The gateway schema, the `/v1/http` envelope and the
failure vocabulary are unchanged.

## 3. Worker environment

A host publishes these four existing entries only when the independent mode is
selected, its stored base is canonical, a usable key is readable, and the launch
allows host-injected credentials:

| Entry | Value |
| --- | --- |
| `PDSH_WEB_SEARCH_PROVIDER` | `deepseek-search-api` |
| `PDSH_WEB_FETCH_PROVIDER` | `phone-host-fetch` |
| `DEEPSEEK_SEARCH_API_BASE_URL` | the canonical base |
| `DEEPSEEK_SEARCH_API_KEY` | the fixture `placeholder` |

The fetch half is served by the Worker-local `phone-host-fetch` provider: it
uses the Worker's global `fetch`, which `llm-bridge` carries over the host
`/v1/http` route and the gateway's egress allow-list, and returns `text/plain`
bodies verbatim. The independent `/fetch` operation described below remains
registered by `web-deepseek-api` for deployments that select it, but
`phone-host-fetch` is the phone host's default selection; the independent base
and key are used for search.

Otherwise the host publishes none of them and mounts no independent grant. The
independent mode never publishes the official base or falls back to the follow-model
grant; a misconfigured independent service leaves both web tools off. Follow-model
mode keeps [official DeepSeek web tools](gateway-official-web.md) unchanged.

## 4. Worker cookie route

In a cookie-authenticated Worker (no `PDSH_CHANNEL_TOKEN` and no
`PDSH_EXEC_BRIDGE_TOKEN`) with `PDSH_WEB_SEARCH_PROVIDER=deepseek-search-api`, the
bridge treats `DEEPSEEK_SEARCH_API_BASE_URL` as follows:

- equal to the official `https://api.deepseek.com/v1/tools`: the official fallback;
- otherwise, equal to its own §1 canonical form: the bridge carries the two §2
  operation URLs over the host `/v1/http` route with `PDSH_DSH_LAUNCH_TOKEN` as the
  bearer. If the route origin or the launch bearer is unavailable it must fail
  instead of sending them directly;
- otherwise: no cookie route; other requests keep their existing transport.

The bridge compares the parsed request URL with the two operation URLs. A parser may
route a spelling the host then refuses; the bridge never sends an operation URL
directly. A launch with a channel or exec-bridge token is unchanged: every request
already uses the host route (iOS).

## 5. Persisted settings (Android)

The Android host keeps a private settings document `{version: 1, mode, baseUrl}` with
`mode` `follow-model` or `search-api` and `baseUrl` empty or canonical. An absent
document is follow-model. A document with another version, mode, member or a
non-canonical base is unreadable: the page reports it and both web tools stay off.
The key lives in the host key store under a separate account. Committing a base
different from the stored one deletes the stored key first; a key is accepted only
after a canonical base is stored. Removing the service deletes the key and the document.
