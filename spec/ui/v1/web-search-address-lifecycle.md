# Web search address lifecycle

P05, P09, P18. The address is a non-secret canonical base. The host supplies the
last confirmed stored base to the Android page and distinguishes an unreadable
document from an empty address. The key itself never enters the page facts, logs,
or the address field.

For the independent-search mode, a changed address draft is submitted on IME Done,
loss of focus, or page departure. Trim surrounding whitespace; if a nonempty draft
has no `://`, prepend `https://` before the existing P05 base validator runs.
An invalid or failed write does not claim success; while the page remains open the
draft stays editable. Leaving does not wait on a remote service or block navigation.
Returning shows only the last confirmed base. A pasted key is saved solely by the
explicit Save action. If the draft differs from the last confirmed base, no key
save may bind it to the old service. The host rechecks the expected base under the
store lock before the key write, and a key that is unreadable or invalid is not
overwritten. Address-only commits with a prior key follow the
fail-closed rule in `../../v1/gateway-independent-search.md` §5.

`fixtures/web-search-address-lifecycle.json` covers valid, invalid, stale identity
and unreadable-key cases; its schema is `schema/web-search-address-lifecycle.schema.json`.
Android still cannot replace an existing keyed endpoint and key in one atomic
operation. This is an open parity gap; it must be represented honestly and not
implemented by deleting or reusing the old credential. Worker and network formats
are unchanged.

In the task's 402pt, 3× light iOS reference with an independent base and no key,
the title is inline beside a circular back button. The two mode choices share an
inset white card: x=16…386pt, y=466…981px, with the first divider at y=721px.
Only the selected choice's subtitle is visible; the hidden subtitle retains its
layout space. The address field is an inset card at y=1184…1336px and the key
section's card starts at y=1555px. These measured values and the reference PNG
SHA-256 are in `visual402` of the shared fixture. They are observations for this
viewport and state, not universal safe-area, dark-mode or dynamic-type values.

A successful local mode or address write does not occupy a persistent global
notice bar. When the confirmed address changes while the page remains visible,
show the existing short saved acknowledgement under the address and clear it
after two seconds; editing clears it immediately. A failed write must not use
that acknowledgement. This matches the observed iOS interaction and keeps the
page's content geometry stable after reopening.

## Published Android AAR compatibility

The published AAR retains the existing JVM signatures and data-class component
order of `WebSearchFacts`, `WebSearchScreenState`, `WebSearchSettingsPage`, and
`PdshHostAction.CommitWebSearchKey`. The host supplies the confirmed base through
an additive composition-local value. Its default is unavailable. If an old host
does not supply that value, or the settings document is unreadable, the address
and key controls are disabled and a reason is visible. This fails closed instead
of binding a credential to an unknown address. A current host supplies either a
confirmed base or an explicit unavailable state and checks the same base under
the settings-store lock before writing a key. Existing stored data is unchanged.
