// SPDX-License-Identifier: MIT
// The consumer probe: an app that depends on the *published coordinate*
// `com.phonedsh:lib:0.1.0`, never on project(":lib").
//
// Why this module exists. `:lib` is the deliverable (plan §176: the
// composition-root app consumes the AAR), but nothing else in the tree proves
// the artifact works for anyone but the build that produced it. `:app` depends on
// `project(":lib")`, which shares this build's classpath, variant attributes and
// `api` edges — so it compiles even when the published artifact would not.
//
// Until L66 this module depended on `android/lib/build/outputs/aar/lib-release.aar`
// as a *file*, which has no POM: the AAR was compiled against, and then R8 failed
// on the release variant with 44 missing classes (`com.phonedsh.agentcore.*`,
// `com.phonedsh.domain.connector.*`, `com.phonedsh.domain.device.*`) because a
// file dependency brings no `api` closure. Two hand-supplied workarounds followed
// (`releaseImplementation` with four sibling artifacts, and a manual Compose
// dependency list) — both are gone. The dependency below resolves through the
// published POM and Gradle module metadata, exactly as an external app would.
//
// The repository is declared once in settings.gradle.kts (`pdshLocal`, pointing
// at android/build/repo). Nothing here names a file path, so the probe fails if
// the publication is wrong — which is the point.
//
// What each variant proves:
//   debug   — the coordinate resolves and the public surface (PdshNavHost /
//             PdshNavFacts / PdshNavState / PdshRoute / PdshTheme) is on the
//             compile classpath without this module naming a single androidx or
//             com.phonedsh artifact itself.
//   release — the same, plus R8. A minifying consumer is the normal case
//             (`:app` minifies), so a missing `api` edge or a dropped consumer
//             rule has to fail here rather than in someone's app.
//
// The artifacts have no Gradle producer edge from this project's point of view
// (they are Maven coordinates, not project dependencies), so the build asks the
// publisher to run first. A real consumer runs `./gradlew publishLocalRepository`
// once and then never needs this edge.
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.phonedsh.consumer"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.phonedsh.consumer"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            // The R8 half of the probe: a consumer that minifies is the normal
            // case (:app does), so the AAR's `api` closure *and* its consumer
            // rules have to survive here. `proguard-rules.pro` holds no product
            // rules on purpose — if the build needed one to keep an SDK class
            // alive, that rule would belong in :lib's consumer-rules.pro.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    buildFeatures {
        compose = true
        buildConfig = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

tasks.named("preBuild") {
    dependsOn(":publishLocalRepository")
}

dependencies {
    // ONE line. The seven sibling artifacts (`dsh`, `domain`, `controller`,
    // `shell`, `core`, `net`, `platform`) and the Compose runtime arrive through
    // this artifact's POM (`compile` scope = :lib's `api` edges, the Compose BOM
    // as `<scope>import</scope>`), which is the claim L63 could not make.
    implementation("com.phonedsh:lib:0.1.0")

    // The one thing an AAR cannot ship: the host Activity. `:lib` is a Compose
    // surface, so the app supplies `ComponentActivity` + `setContent`
    // (`androidx.activity:activity-compose`). It is `implementation` here, not a
    // transitive arrival, because the host lifecycle is the app's decision.
    implementation(libs.androidx.activity.compose)
}
