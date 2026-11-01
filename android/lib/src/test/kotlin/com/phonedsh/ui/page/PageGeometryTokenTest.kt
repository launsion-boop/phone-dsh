// Geometry ownership: every token is surface-owned or used by two pages.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/tokens.json` has two kinds of geometry:
//   * signature-surface geometry, listed in `signatureSurfaces.*.tokens` (the six
//     pixel-parity surfaces of README §4);
//   * page-level geometry: a `geometry.*` entry no surface declares. It exists
//     because several pages needed the same length, which is exactly when a new
//     token is allowed (`spec/ui/v1/README.md` §4 page-level subsection).
//
// This test turns the review rule into one invariant: every geometry token has an
// owner, either a signature surface that declares it or at least two page sources
// that read it. An orphan (neither) is a spec entry nobody owns: a page-private
// length that leaked into the spec, or a surface token whose surface forgot it.
// The page-level half also pins the shape: a fixed `pt` length, never a
// `screenRatio`, which stays owned by the surface that consumes it.
package com.phonedsh.ui.page

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.surfaces
import com.phonedsh.ui.text
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class PageGeometryTokenTest {
    @Test
    fun `every geometry token is surface-owned or used by at least two pages`() {
        val geometry = SpecFixtures.tokens["geometry"] as JsonObject
        val geometryNames = geometry.members.keys.map { "geometry.$it" }.toSet()
        val surfaceGeometry = SpecFixtures.surfaces()
            .flatMap { it.tokens }
            .filter { it.startsWith("geometry.") }
            .toSet()
        assertEquals(
            "a signature surface declares geometry that tokens.json does not define",
            emptySet<String>(),
            surfaceGeometry - geometryNames,
        )
        val pageLevel = geometryNames - surfaceGeometry
        assertTrue(
            "tokens.json has no page-level geometry token; this test would be vacuous",
            pageLevel.isNotEmpty(),
        )
        val sources = pageSources()
        geometryNames.sorted().forEach { token ->
            val users = sources.filterValues { source -> source.contains("tokens.$token") }
                .keys
                .sorted()
            assertTrue(
                "$token is an orphan geometry token: no signature surface declares it and only " +
                    "${users.size} page(s) $users read it. Every geometry token must be either " +
                    "surface-owned or used by at least 2 pages; a one-page length keeps reusing a " +
                    "declared token with the `unverified geometry` marker instead of entering the spec.",
                token in surfaceGeometry || users.size >= 2,
            )
        }
        pageLevel.sorted().forEach { token ->
            val entry = geometry.members.getValue(token.removePrefix("geometry.")) as JsonObject
            assertEquals("$token is page-level and must be a pt length", "pt", entry.text("unit"))
            assertTrue(
                "$token is page-level and must be a fixed length (scalesWith: null), " +
                    "because only a signature surface may derive a ratio",
                entry["scalesWith"] is JsonNull,
            )
        }
    }

    /** Every `.kt` file under the page package, keyed by file name. */
    private fun pageSources(): Map<String, String> {
        val dir = SpecFixtures.repoRoot.resolve("android/lib/src/main/kotlin/com/phonedsh/ui/page")
        return Files.list(dir).use { stream ->
            stream.filter { it.fileName.toString().endsWith(".kt") }
                .sorted()
                .toList()
                .associate { it.fileName.toString() to String(Files.readAllBytes(it), Charsets.UTF_8) }
        }
    }
}
