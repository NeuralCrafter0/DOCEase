import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Release signing: read android/key.properties when it exists (CI writes it from
// GitHub secrets; developers can create it locally). It is gitignored.
// The release signing config is only used when key.properties exists, every
// field is set, and storeFile points to an existing keystore. Otherwise release
// builds fall back to the debug key (NOT release-signed) so local
// `flutter run --release` and unsigned CI builds keep working.
// Never ship a debug-signed build.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val releaseStoreFile: File? =
    keystoreProperties.getProperty("storeFile")
        ?.takeIf { it.isNotBlank() }
        ?.let { file(it) }
        ?.takeIf { it.isFile }
val hasReleaseSigning =
    releaseStoreFile != null &&
        listOf("storePassword", "keyAlias", "keyPassword").all {
            !keystoreProperties.getProperty(it).isNullOrBlank()
        }
if (keystorePropertiesFile.exists() && !hasReleaseSigning) {
    logger.warn(
        "android/key.properties is incomplete or its storeFile does not exist; " +
            "release build will NOT be release-signed (debug key fallback).",
    )
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = releaseStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseSigning) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:33.1.2"))
    implementation("com.google.firebase:firebase-analytics")
}

flutter {
    source = "../.."
}
