import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.medhistory.app.medhistory"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.medhistory.app.medhistory"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Build with --flavor prod (the real app, unchanged) or --flavor dev
    // (dev mode: --dart-define=DOCEASE_DEV_MODE=true, debug/profile only).
    flavorDimensions += "env"
    productFlavors {
        create("prod") {
            dimension = "env"
            isDefault = true
        }
        create("dev") {
            dimension = "env"
            // Own app id: never installs over / shares storage with the real app.
            // Label "DOCEase DEV" and no Firebase auto-init: src/dev/AndroidManifest.xml
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
    }
}

// The dev flavor has no release variant at all: devRelease is never created,
// so it cannot be built, installed or pulled into another build. (Without
// this, the shared configureCMakeRelease[abi] tasks make even a prod release
// build compile the devRelease Dart.)
androidComponents {
    beforeVariants(selector().withFlavor("env" to "dev").withBuildType("release")) {
        it.enable = false
    }
}

// ---- Dev-mode build guards -------------------------------------------------
// Flutter passes --dart-define values as base64 entries in -Pdart-defines.
val docEaseDartDefines: List<String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotBlank() }
        ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        ?: emptyList()
val docEaseDevModeDefine = docEaseDartDefines.contains("DOCEASE_DEV_MODE=true")
// Guard on the task graph, not the command line: whatever starts the build
// (flutter run/build, ./gradlew assembleDebug or build, an IDE), each app
// it produces shows up as a package/bundle/assemble/install<Flavor><BuildType>
// task. The dart-defines apply to every variant in one build. Refused:
//   - the dev flavor in release (also has no variant, see above),
//   - DOCEASE_DEV_MODE=true in any non-dev app (the prod app id),
//   - a dev app without DOCEASE_DEV_MODE=true.
// So a build producing both flavors (e.g. assembleDebug) is refused either
// way. Not keyed on compileFlutterBuild<Variant>: the shared
// configureCMake<BuildType>[abi] tasks pull in other flavors' Dart compiles,
// whose output is never packaged into the app being built.
val docEaseOutputTask = Regex("^(package|bundle|assemble|install)((Dev|Prod)(Debug|Profile|Release))$")
gradle.taskGraph.whenReady {
    val variants = allTasks
        .filter { it.project == project }
        .mapNotNull { docEaseOutputTask.find(it.name)?.groupValues?.get(2) }
        .distinct()
    for (variant in variants) {
        val dev = variant.startsWith("Dev")
        if (dev && variant.endsWith("Release")) {
            throw GradleException(
                "Refused: the dev flavor never builds in release mode ($variant). Use --debug or --profile.")
        }
        if (docEaseDevModeDefine && !dev) {
            throw GradleException(
                "Refused: DOCEASE_DEV_MODE=true needs --flavor dev (own app id), never the prod app ($variant).")
        }
        if (!docEaseDevModeDefine && dev) {
            throw GradleException(
                "Refused: --flavor dev needs --dart-define=DOCEASE_DEV_MODE=true ($variant).")
        }
    }
}
// The dev app id is not in google-services.json, and dev mode never uses
// Firebase: skip the google-services step for dev variants.
tasks.configureEach {
    if (name.startsWith("process") && name.contains("Dev") && name.endsWith("GoogleServices")) {
        enabled = false
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:33.1.2"))
    // Prod only, as before; the dev flavor ships no analytics.
    "prodImplementation"("com.google.firebase:firebase-analytics")
}

flutter {
    source = "../.."
}
