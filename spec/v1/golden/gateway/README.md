# Gateway golden vectors

One file is one language-independent exchange, judged by
[`gateway_check.py`](../../tools/gateway_check.py); the normative semantics live in
[`gateway-security.md`](../../gateway-security.md). `log-001` locks the positive response log
(`recorded: true`), `fail-003`/`fail-004` lock the invalid-request and sent transport-failure
surfaces, and `resp-006` locks body suppression for HEAD/1xx/204/205/304.

The `com.phonedsh.gateway.GatewayTransport` seam stays injectable on purpose. This lane does not add
OkHttp (no offline artifact for it); the production adapter will use the cached Ktor client 3.2.3
already pinned in `android/net/build.gradle.kts`.
