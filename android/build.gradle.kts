// SPDX-License-Identifier: MIT
// Root build. Plugin versions live in gradle/libs.versions.toml; modules apply
// them. No repositories here: settings.gradle.kts owns repository policy.

import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

// One coordinate line for the module set. `0.1.0` is the app's `versionName`
// (android/app/build.gradle.kts): a consumer that pins
// `com.phonedsh:lib:0.1.0` is asking for the code version 0.1.0 of the demo app
// was built from, so the two numbers must move together.
val pdshVersion = "0.1.0"

subprojects {
    group = "com.phonedsh"
    version = pdshVersion
}

// ---------------------------------------------------------------------------
// Publication: eight coordinates, one version, one repository.
//
// `:lib` is the entry point, but its AAR alone is not a deliverable: the UI's
// reachable code names `:core` value types (the chat page's canonical JSON) and
// `:domain` value types (the device pages' snapshots), and `:lib` declares both
// as `api` edges. Without a POM those edges arrive nowhere, and a minifying
// consumer fails in R8 with 44 missing classes (L63 measured exactly that).
// So every module on `:lib`'s `api` closure publishes too, with the SAME
// version, and a consumer needs one line:
//
//   implementation("com.phonedsh:lib:0.1.0")
//
// AAR (Android library): lib, dsh, domain, controller, shell
// JAR (java-library):    core, net, platform
//
// Repository: `<android>/build/repo`, a file repository inside the build tree.
// Deliberately not `~/.m2`:
//   * it is a product of this checkout, and the root .gitignore rule `build/`
//     already covers it, so CI starts from nothing;
//   * a stale `0.1.0` left by another project on the machine can never satisfy
//     a resolve — the directory only exists if this tree published it;
//   * resolving needs no network and writes nothing into the user's home.
// The matching resolution repository is declared in settings.gradle.kts
// (RepositoriesMode.FAIL_ON_PROJECT_REPOS: settings owns repository policy).
// ---------------------------------------------------------------------------
val publishedModules = setOf(
    "lib", "dsh", "domain", "controller", "shell", // AAR
    "core", "net", "platform", // JAR
)
val localRepositoryDir: File = rootDir.resolve("build/repo")

subprojects {
    // `:app`, `:engine`, `:testkit` and `:platform-android` are not published:
    // they are the host, the WebView engine, the device test kit and the Android
    // SPI implementation, none of which belongs on a UI consumer's classpath.
    if (!publishedModules.contains(name)) return@subprojects

    // The repository is declared once, here, for every published module. Each
    // module declares its own publication (its `from(components[...])` has to be
    // wired from inside that project's evaluation — see the comment in
    // lib/build.gradle.kts); the coordinates and metadata come from this file so
    // eight POMs cannot drift apart.
    plugins.withId("maven-publish") {
        extensions.configure<PublishingExtension>("publishing") {
            repositories {
                maven {
                    name = "local"
                    url = uri(localRepositoryDir)
                }
            }
            // A live collection: a module script creates its publication after
            // this callback runs, and `configureEach` still reaches it. The
            // artifactId is the Gradle module name, so the coordinate is
            // `com.phonedsh:<module>:<version>` for all eight.
            publications.withType<MavenPublication>().configureEach {
                artifactId = project.name
                pom {
                    name.set("com.phonedsh:${project.name}")
                    description.set(
                        "PDSH Android: ${project.name}. :lib is the published entry " +
                            "point; this artifact is one of its api-closure siblings and is " +
                            "meant to be resolved through the published POM, not by hand.",
                    )
                    licenses {
                        license {
                            name.set("MIT")
                        }
                    }
                }
            }
        }
    }
}

// One command publishes the whole closure. The consumer probe depends on it, so
// a clean checkout can build an app against the coordinates in one invocation;
// a real consumer runs it once and then only consumes.
tasks.register("publishLocalRepository") {
    description = "Publishes the eight com.phonedsh artifacts to android/build/repo"
    group = "publishing"
    dependsOn(publishedModules.map { ":$it:publishAllPublicationsToLocalRepository" })
}
