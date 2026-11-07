# Android SDK package listing boundary

Status: frozen; adapter implementation pending. Protocol impact: P23.

The external Android SDK manager is not controlled by this repository. The
bootstrap adapter invokes `sdkmanager --list_installed`, requires a successful
exit status, and identifies the three configured package IDs from its installed
package table. The repository consumes the adapter's `PACKAGE <id>=installed`
or `PACKAGE <id>=MISSING` lines and exit status. Paths to the platform and
build-tools directories must also exist; a matching row alone is insufficient.
This boundary does not claim an SDK package is functional or authentic.

Supported evidence consists of the legacy pipe table and the newer whitespace
listing shown by the shared cases. A row must be in the section introduced by
`Installed packages:`, have an exact package ID as its first column, and a
version token beginning with a decimal digit as its second column. Mixed
slash and semicolon identifiers, CRLF and version suffixes such as `-rc1`
are supported as represented by the fixtures. ASCII slash
in a package path is equivalent to the sdkmanager CLI semicolon in that ID;
this translation changes neither the SDK manager invocation nor the reported
canonical ID. Ignore heading rows. Diagnostics, suffix/prefix matches, missing
versions and rows preceding the section are not installed packages. For
`--list_installed`, the observed section reaches end-of-output. Unknown section
headers or unrecognized ambiguous layout must fail closed instead of treating
other output as installed rows. Nonzero sdkmanager exit always fails.

The `golden/sdk-manager-listing.jsonl` cases define supported positive and
negative listings and canonical required IDs. They must run through the real
bootstrap `--check` adapter with a controlled external process and real
filesystem directories, not a copied parser. The external manager remains
unmodified. Unknown future formats require an explicit compatibility decision;
no directory, license or toolchain installation is implied by a listing.
