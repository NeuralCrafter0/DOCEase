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

// ---- Dev-mode build guards -------------------------------------------------
// Flutter passes --dart-define values as base64 entries in -Pdart-defines.
val docEaseDartDefines: List<String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.filter { it.isNotBlank() }
        ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        ?: emptyList()
val docEaseDevModeDefine = docEaseDartDefines.contains("DOCEASE_DEV_MODE=true")
val docEaseBuildTasks = gradle.startParameter.taskNames
    .map { it.substringAfterLast(":") }
    .filter { it.startsWith("assemble") || it.startsWith("bundle") || it.startsWith("install") }
if (docEaseBuildTasks.any { it.contains("DevRelease") }) {
    throw GradleException(
        "Refused: the dev flavor never builds in release mode. Use --debug or --profile.")
}
if (docEaseDevModeDefine && docEaseBuildTasks.any { it.contains("Prod") || !it.contains("Dev") }) {
    throw GradleException(
        "Refused: DOCEASE_DEV_MODE=true needs --flavor dev (own app id), never the prod app.")
}
if (!docEaseDevModeDefine && docEaseBuildTasks.any { it.contains("Dev") }) {
    throw GradleException(
        "Refused: --flavor dev needs --dart-define=DOCEASE_DEV_MODE=true.")
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
