# Android SDK package listing boundary

Status: frozen; adapter implementation pending. Protocol impact: P23.

The external Android SDK manager is not controlled by this repository. The
bootstrap adapter invokes `sdkmanager --list_installed`, requires a successful
exit status, and identifies the three configured package IDs from its installed
package table from stdout only; stderr remains visible but never supplies
package rows. The producer and both stdout captures must complete successfully. The two
captures must match byte-for-byte; a failed or divergent capture invalidates
the listing. This comparison detects divergence between the captured copies;
it cannot detect identical data loss before both copies, collusion between
utilities, or corruption in the external producer itself. If stdout lacks a final newline, the adapter must separate its
own output from the producer's final line before emitting any `PACKAGE` line.
The repository consumes the adapter's `PACKAGE <id>=installed`
or `PACKAGE <id>=MISSING` lines and exit status. Paths to the platform and
build-tools directories must also exist; a matching row alone is insufficient.
This boundary does not claim an SDK package is functional or authentic.

Supported evidence consists of the legacy pipe table and the newer whitespace
listing shown by the shared cases. A row must be in the section introduced by
`Installed packages:`, have an exact package ID as its first column, and a
version token as its second column. Package IDs are ASCII letters, digits,
underscore, dot, hyphen, slash and semicolon; versions begin with an ASCII
digit and continue with ASCII letters, digits, dot, underscore, plus or hyphen. Mixed
slash and semicolon identifiers, CRLF and version suffixes such as `-rc1`
are supported as represented by the fixtures. A CR is allowed only immediately
before a newline; an embedded CR invalidates the listing. ASCII slash
in a package path is equivalent to the sdkmanager CLI semicolon in that ID;
this translation changes neither the SDK manager invocation nor the reported
canonical ID. The supported legacy heading begins `Path | Version | Description`;
a legacy separator consists of hyphens, whitespace and pipe separators, with
at least one hyphen and one pipe. Other heading or separator forms fail closed. Non-required package rows with
a supported version, and the observed `unknown -> <supported version>` form, may
appear and are ignored. The latter form is invalid for any required ID, even
if the listing contains another, version-bearing row for that ID. Any other nonempty row inside the installed section
invalidates the listing. Diagnostics, suffix/prefix matches, missing versions
and rows preceding the section are not installed packages. For
`--list_installed`, the observed section reaches end-of-output. An unknown nonempty colon-terminated section heading, including one with
punctuation, before or after the installed section invalidates the listing.
Other unrecognized ambiguous layout must also fail closed. Nonzero sdkmanager exit always fails.

The `golden/sdk-manager-listing.jsonl` cases define supported positive and
negative listings and canonical required IDs. They must run through the real
bootstrap `--check` adapter with a controlled external process and real
filesystem directories, not a copied parser. The external manager remains
unmodified. Unknown future formats require an explicit compatibility decision;
no directory, license or toolchain installation is implied by a listing.
