# Contract change request: LAN A-label and Worker URL interoperability

```yaml
change: PC-20261107-lan-idna-ccr
contracts: [P07, P13]
status: draft
breaking: true
version_decision: pending — validation and compatibility have not been selected
base: c3bb145a
contract_revision: pending
```

The P07 LAN profile accepts ASCII LDH-shaped SRV names, and the Swift, Python and Android candidate decoders currently accept labels such as `xn--a.example`. The Worker P13 MCP input validator uses the runtime URL parser: under Node 18/22 it rejects that example, whereas a local macOS WKWebView experiment accepted it. The real iOS Worker runtime has not been verified. Other syntactically similar A-labels are valid. The numeric-final-label correction does not settle internationalized domain processing. Passing the currently shared positive vectors is not proof that every accepted candidate is consumable by the Worker.

The contract owner must define a common IDNA/A-label policy and Unicode version or another explicitly versioned compatibility decision, retaining legitimate names where supported. Freeze shared positive and invalid A-label vectors, encoding and compatibility matrix before changing implementations. Swift, the Python reference, Android and the actual Worker input parser must be exercised against the same cases. Do not fix only one platform, silently map a hostname, introduce lookalike allowlists, or claim the profile is end-to-end conformant on the basis of current tests. DNS-SD and TLS verification remain independent: a syntactically accepted hostname is neither an authorization nor proof of identity.

Feasibility observation (2026-11-07): in a local iOS Simulator experiment, the SDK's ICU 78.1/Unicode 17 UTS-46 API accepted `xn--4u8c.example`, while the available Node 22.21.1 Worker runtime's ICU 77.1/Unicode 16 URL parser rejected it. Independent platform UTS-46 calls therefore cannot be assumed equivalent merely because their API names match; Python's IDNA2008 package also differs from WHATWG handling of some valid URL A-labels. This is a version-specific observation, not a universal list of invalid names. A frozen solution needs either a shared, versioned implementation/data set and actual Worker compatibility, or a specified fail-closed check against the actual Worker runtime; a short fixture allowlist or a blanket ban on internationalized names is not a conformance proof.

A local macOS WKWebView experiment also accepted `xn--4u8c.example` and rejected `foo.123`; this differs from Node for the former. The Node execution of the real `validateServerInput` function tests that code path but does not establish the URL behavior of an iOS WKWebView Worker. Any final policy must test the actual Worker runtime and distinguish it from Node test evidence.

An independent iOS Simulator 27.1 `WKWebView.evaluateJavaScript` URL experiment (not the product app or a physical iPhone) also accepted `xn--a.example`, `xn--x.example`, `xn--zckzah.example`, `xn--ls8h.example` and `xn--4u8c.example`, while rejecting `foo.123`; it exited successfully with a simulator `/tmp` sandbox warning. Thus the Node validator regression is explicitly a Node-runtime check, not proof of the iOS Worker URL outcome. Product Worker and other supported OS/runtime versions remain to be tested.

## Additional cross-runtime evidence

A separate audit compiled the real Swift `LANDeviceCandidate` on macOS and
called the real Python reference `candidate`; both accepted and retained
`xn--a`, `xn--x`, `xn--8i7caa`, and `xn--4u8c`. The repository's actual
`validateServerInput` function was imported and called under Node 22.21.1
(ICU 77 / Unicode 16) and Node 24.18.0 (ICU 78 / Unicode 17). Both rejected
the first three values; Node 22 rejected `xn--4u8c` while Node 24 accepted it.
Both accepted `xn--bcher-kva`, `xn--zckzah`, and `xn--ls8h`. Python's separate
IDNA2008 library rejected `xn--ls8h`, showing that substituting that library
for UTS #46 would itself change accepted names. Android was source-reviewed
only. These are host and Node observations, not production iOS Worker or
physical Android runtime evidence.

A local system ICU 78.1 UTS #46 experiment using nontransitional processing,
Bidi and ContextJ checks reported errors for the first three and no errors for
`xn--4u8c`, `xn--ls8h`, and `xn--bcher-kva`. It did not enable every candidate
strict option, so it is not a complete proposed validator. The currently
specified WHATWG non-strict domain-to-ASCII behavior is not itself evidence
that every `xn--` label is a valid A-label. Choosing a shared Unicode/UTS #46
version and options still needs compatibility and rollback decisions, a
versioned implementation on all ends, and actual Worker-runtime endpoint
verification. A valid label unsupported by an older runtime must not silently
be relabeled as invalid or altered. The existing save flow has side effects;
`phone/mcpUpsert` cannot be treated as a read-only validation probe without a
separately verified transaction and rollback. No contract or implementation is
frozen by this evidence, and no TLS, authorization, or discovery acceptance
follows from it.

The current Swift LAN module, Android domain module and Python reference do
not share pinned IDNA data. System ICU data varies with the OS; merely checking
its version cannot provide a fixed Unicode release on older supported devices.
A shared pinned Rust implementation exposed through C and JNI is one candidate,
not an implemented solution: it would add P12 ABI and multi-architecture
packaging obligations, including standalone Python distribution and Android
16 KB artifact verification. The existing optional shell XCFramework cannot
silently stand in for a mandatory LAN validator. Exact crate and Unicode-data
versions, license, minimum Rust version and reproducible distributions would
need review; the candidate has not been built, measured or tested. The shell
manifest declares Rust 1.85 while one existing Android toolchain lane specifies
1.99.1, so dependency MSRV compatibility requires an explicit decision.

A standalone macOS Rust probe subsequently built `idna` 1.1.0 with
`idna_adapter` 1.2.2 and ICU normalizer/property data 2.2.0. On the sampled
names, both the library's strict and non-strict APIs rejected `xn--a`,
`xn--x`, `xn--8i7caa`, `xn--a-0hc` and `xn--a-ugn`; both accepted and retained
`xn--zckzah`, `xn--ls8h`, `xn--4u8c` and `xn--bcher-kva`. It accepted
`foo.123`, so the separately frozen numeric-final-label rule is still needed.
This is not evidence for the actual Worker URL parser, a C/JNI bridge or a
mobile device. The exact Unicode data version and official full-suite results
still require verification. The resolved dependency graph included components
with an MSRV of Rust 1.88, above the repository manifest's 1.85; an existing
1.99.1 test lane is not a resolution of that mismatch. Artifact size, licensing
and all cross-platform packaging remain unverified. No dependency was added
to the repository and no new hostname contract was frozen.

Further probing found `domain_to_ascii_strict` rejects ordinary existing LDH
names such as `ab--cd.local` and `zz--xx.local`; applying it globally would
change the current profile. An explicit UTS #46 call with hyphens allowed
retained those sampled names and had the same results on the sampled A-labels,
but that small sample does not establish full A-label, Bidi or ContextJ
correctness. No candidate option is approved without the shared compatibility
and invalid vectors and actual end-to-end verification.

A limited Unicode 17 `IdnaTestV2` experiment selected 2,046 ASCII inputs
within the existing P07 host shape. The hyphens-allowed candidate alone
accepted two A-labels for which the selected oracle reports a V4 error;
it therefore failed that filtered comparison. An experimental additional
check of the decoded A-label's `xn--` prefix, ignoring ASCII case, matched
those 2,046 rows and an uppercased copy of them. The comparison does not
cover the entire Unicode corpus, all ToUnicode cases, a Worker runtime or any
mobile FFI. A hand-written probe also showed why the UTS #46 check must see
the whole domain for Bidi and why the existing one-trailing-root-dot handling
must occur before a strict DNS-length check. These are candidate-design
observations, not a frozen or implemented validator.

Correction: the 2,046-row filtered set above includes 24 inputs that already
end in a root dot. The official length-check oracle treats those dots
differently from P07's prior removal, and appending another dot to every input
creates invalid double-dot cases for those 24 rows. Therefore the previous
counts do not establish P07 root-dot correctness. A corrected comparison must
separate initially undotted inputs, one-dot variants and invalid double-dot
inputs; that work is still in progress. The earlier zero-mismatch observations
are retained only as results of the stated experimental harness, not as P07
conformance evidence.

Further correction: 94 of the 2,046 initially selected rows already had a
trailing dot; 24 of those had the specific length-oracle mismatch described
above. An isolated Rust 1.85.0 build using `idna` 1.1.0, `idna_adapter` 1.2.1
and ICU data 2.1.1 compiled successfully without changing the user's default
toolchain. After excluding all 94 originally dotted rows, the experimental
candidate matched the selected oracle for 1,952 inputs and separately for
uppercased and single-root-dot variants. These are bounded macOS CLI
experiments; they do not establish full Unicode conformance, a safe production
implementation, mobile FFI, actual Worker compatibility, packaging or license
closure. Double-root-dot rejection and the other existing P07 host rules still
need their own real cross-end tests.
