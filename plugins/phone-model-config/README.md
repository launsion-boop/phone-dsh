# `@phone-dsh/dsh-phone-model-config`

Read-only projection of the model service the **native host** selected.

The host app owns editing: non-secret provider fields live in UserDefaults and
the API key lives in the device Keychain. Before the Worker boots, the host
writes `PDSH_MODEL_PROVIDER_JSON` into `engine.environment`. This package reads
that value and serves it to the existing DSH Plugins settings section; it never
reads the Keychain, never accepts a save, and never forwards a key.

## Worker contract

`PDSH_MODEL_PROVIDER_JSON` is a JSON object:

```json
{
  "version": 1,
  "selectedId": "deepseek",
  "providers": [{
    "id": "deepseek",
    "displayName": "DeepSeek",
    "baseURL": "https://model.example/anthropic",
    "model": "deepseek-flash",
    "reasoningEffort": "high"
  }]
}
```

Only those fields are projected. Unknown fields — including a mistakenly added
`apiKey`, `apiKeyEnv` or `credentialRef` — are dropped by construction. Missing
or invalid input becomes an explicit `configured: false` snapshot with a
structured `detail.code` (`env-missing`, `json-invalid`, `duplicate-provider-id`,
`selected-unknown`, …); the Host sends no user-facing prose, so the Client
localizes the code from its own `settings.phoneModelConfig` zh/en dictionaries.
The tab does not invent a provider.

## Exports

| Export | Role |
|---|---|
| `.` | Host plugin: mounts `PhoneModelConfigRemote`, endpoint `phone/modelConfig` (service key `modelConfig`, namespace `phone`). |
| `./remote` | Hand-written Client contribution for `phone/modelConfig`; mount it with `ctx.remote.$mount()` when a Client assembly does not already include the package in `@deepseek-ai/dsh-api-remotes`. |
| `./client` | Browser entry: registers one read-only `settings.plugins.tab` contribution with id `model`. React is a module-table external, never bundled here. Copy lives in the plugin-owned locale namespace `settings.phoneModelConfig`. |

The tab renders the real selected provider (display name, id, base URL, model,
reasoning effort) and states that the key is in the device Keychain and injected
by the host. Its one action posts to the native `pdshOpenModelSettings` handler,
which opens the same system model-service sheet the native recovery page uses;
there is no fake save button and no second Keychain. The same tab states that
web search uses this service's host and key.

## Integration notes

The package is not added to `plugins/package.json` or the Worker profile in this
change; the final integration owns shared profile/build/dispatcher edits.

1. Add it to the plugin workspace and the Worker image roster, then mount a host
   row (for example `id: phone-model-config`) so `PhoneModelConfigRemote` is
   active.
2. Ensure the Client bundle is built as a **page asset** (the DSH
   `__ModuleLoader__` factory format) and listed as a `dsh.client` row. The
   package's `./client` source must not be staged through the Worker lowering
   path that `plugins/scripts/pack-image.mjs` uses for node-side export faces.
3. Keep the host's real `DEEPSEEK_BASE_URL`, `PDSH_MODEL_NAME` and
   `DEEPSEEK_API_KEY` gateway wiring: this package is display-only. The key stays
   behind the host `CredentialProvider`.

## Test

```bash
node --test plugins/tests/phone-model-config.test.ts
```

The test covers missing/blank/invalid environment values, duplicate ids,
endpoint validation, frozen read-only projection and the fact that secret-shaped
fields never reach the result.
