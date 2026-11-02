plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "tech.xbtpulse.xbt_escrow_rehearsal"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "tech.xbtpulse.xbt_escrow_rehearsal"
        manifestPlaceholders["rehearsalLabel"] = "XBT Escrow TEST ONLY"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "participant"
    productFlavors {
        create("selfTest") {
            dimension = "participant"
            applicationId = "tech.xbtpulse.escrow_selftest"
            manifestPlaceholders["rehearsalLabel"] = "XBT SELF TEST"
        }
        create("clipboardBuyer") {
            dimension = "participant"
            applicationId = "tech.xbtpulse.escrow_candidate_v2.buyer"
            manifestPlaceholders["rehearsalLabel"] = "XBT Buyer TEST v2"
        }
        create("clipboardSeller") {
            dimension = "participant"
            applicationId = "tech.xbtpulse.escrow_candidate_v2.seller"
            manifestPlaceholders["rehearsalLabel"] = "XBT Seller TEST v2"
        }
        create("recoveryBuyer") {
            dimension = "participant"
            applicationId = "tech.xbtpulse.escrow_recovery.buyer"
            manifestPlaceholders["rehearsalLabel"] = "XBT BUYER RECOVERY TEST"
        }
        create("candidateBuyer") {
            dimension = "participant"
            applicationId = "tech.xbtpulse.escrow_candidate.buyer"
            manifestPlaceholders["rehearsalLabel"] = "XBT Signer BUYER TEST"
        }
        create("candidateSeller") {
            dimension = "participant"
            applicationId = "tech.xbtpulse.escrow_candidate.seller"
            manifestPlaceholders["rehearsalLabel"] = "XBT Signer SELLER TEST"
        }
        create("buyer") { dimension = "participant" }
        create("seller") {
            dimension = "participant"
            applicationIdSuffix = ".seller"
            manifestPlaceholders["rehearsalLabel"] = "XBT Escrow SELLER TEST"
        }
    }
    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
