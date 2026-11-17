# Web search address editing and key identity

```yaml
change: PC-20261117-web-search-address
contracts: [P05, P09, P18]
status: implemented
breaking: false
version_decision: retain Android settings document v1 and existing secure account; tighten address-only writes and bind key writes to an expected base
base: bed103f760e380a46037b6e972eba23ee0782783
contract_revision: 312636e5a90059627eb8ee64397245c9451caeb6
```

## Trigger and scope

On the task-only iOS product simulator, typing `example.invalid`, leaving the page,
and reopening shows `https://example.invalid`.
On the task-only Android product emulator the same draft was present before leaving
and absent on reopening.
The existing Android address writer deletes a prior key when a base changes; iOS
instead refuses an address-only move while a key exists. Automatically calling the
old Android writer on blur would therefore delete a key without that explicit intent.

Coordinator is the sole contract owner, implementer and integrator. Owning contracts
are `spec/v1/gateway-independent-search.md` §5 and
`spec/ui/v1/web-search-address-lifecycle.md`; the latter's shared fixture and schema
cover no-key, same identity, present/unreadable key, invalid address and stale key
save, with the stale expected-base check Android-only. iOS `PhoneWebSearchSettings` and Android `WebSearchSettingsStore` are the
real persistence ends. `WebSearchFacts`, `PdshHostAction`, the Android page and host
are the in-process producer/consumer boundary.

## Delta and compatibility

* Android address-only writes retain the document and key when the independent key
  is present, invalid or unreadable; same-base is a no-op. An absent key permits
  the existing canonical write. The iOS store already has these safety semantics.
* The host projects a non-secret confirmed base and unreadable state to the page.
  Page drafts submit on Done, blur and departure, and are restored from confirmed
  data. A key draft is explicit-save only and never enters facts or logs.
* A key-save action carries the confirmed canonical base and the host verifies it
  against the current document under its store lock before touching the key.
  Draft and confirmed base mismatch must not send a key to the old service.
* Old data remains v1 and is read identically. Old clients and new clients are
  bundled within their own app builds, so no mixed in-process API is supported.
  Old app builds still delete their old key on an address-only change; rollback
  cannot retain the new refusal behavior. The new client reads old data, and no
  stored field or wire encoding changes. Worker inputs, gateway grants and network
  operations are unchanged. No new package or OS permission is needed.
* An atomic new-base-plus-new-key operation is not implemented here. The user must
  not be led to think it succeeded; this remains a parity gap. HTTPS/base validation
  remains under the existing stricter Android P05 contract.

## Ownership and acceptance

Contract owner exclusively owns the spec, schema, fixture, registry and this record.
The single implementer owns the Android web-search store, its host projection and
navigation action, the Compose page, and focused tests. The Swift store is unchanged;
the isolated simulator test consumes the same cases through that actual store. Run the Android real store tests,
Compose behavior tests on the task-only emulator, product navigation with synthetic
values and no external service, and the Swift real store tests with the shared cases.
Run `bash scripts/ci/check.sh --only phone-spec,phone-p0-conformance,phone-cross-tree`
and the protocol impact checker. Simulator evidence is not a real-device or live
service claim. Track remaining atomic replacement and visual differences as GAP-44.

## 402pt visual reference revision

The same contract additionally records the real iOS grouped navigation, selection,
mode-card and address-card geometry at 402pt/3× in the shared fixture. Only the
selected mode subtitle is visible and both subtitle slots retain their height.
The observation does not change stored fields or runtime boundaries, and no
other size or appearance is presumed. Android must measure its actual product
screen against the same screenshot; readable content and accessible actions take
priority when text size or viewport changes. Fixture revision SHA-256: `75912dfccad60bf9227988397fd56a1a5c9869f275fe0116351996e1ce0d5c72`.

## Local success feedback revision (P09)

The iOS address editor displays its success feedback below the edited row for two
seconds. A successful Android write previously left a persistent global notice
above the page, shifting the entire product layout after reopening. Successful
mode and address writes no longer create that global notice; a confirmed address
write receives a short page-local acknowledgement. Failure is not reported as a
success. No storage, network or compatibility boundary changes in this revision.

## Unreadable key before explicit save (P05, P18)

The original Android key-save path overwrote the secure account without reading
it. The iOS store reads the prior credential before saving and refuses if that
read fails. The Android store must similarly refuse an explicit key save when
the prior key is invalid or unreadable, without writing or deleting it, even
when the expected base matches. The shared fixture now identifies each case's
operation and includes this failure for both real stores. Fixture SHA-256: `d19850f200869dd9f7dac3c5805fc765219afd658c4a1862954000ae8b183397`.
No storage shape or compatibility decision changes.

## Implementation revision

The contract was frozen at `312636e5a90059627eb8ee64397245c9451caeb6` on top
of `bed103f760e380a46037b6e972eba23ee0782783`. Android implements the page and
store changes. The iOS store behavior is unchanged and is exercised by the shared
fixture in the simulator. The Android keyed-endpoint replacement gap remains open.
