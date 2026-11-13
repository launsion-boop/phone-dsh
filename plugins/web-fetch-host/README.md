# @phone-dsh/dsh-web-fetch-host

Host-routed `web_fetch` for the phone Worker.

The Worker's `globalThis.fetch` is installed by `@phone-dsh/dsh-llm-bridge` and
sends external HTTP through the App's `/v1/http` route, where the host gateway
enforces the egress allow-list. This package exposes that transport as a
`ctx.web` fetch provider with the same content-type rules as DSH's local
provider: `text/html`/XHTML is HTML, other `text/*` and JSON/XML are text. A
`text/plain` source is therefore returned verbatim instead of being sent to the
independent Search/Fetch API's extractor.

The Worker profile selects it explicitly:

```yaml
- id: web-fetch-host
  name: '@phone-dsh/dsh-web-fetch-host'
  disabled: !!js (process.env.PDSH_WEB_FETCH_PROVIDER ?? process.env.DSH_WEB_FETCH_PROVIDER) !== 'phone-host-fetch'
```

The provider id is `phone-host-fetch`; `tool-web` registers `web_fetch` only
when that id (or the legacy `deepseek-fetch-api` pair) is selected.
