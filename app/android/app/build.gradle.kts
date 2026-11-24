import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties. Release builds refuse to
// run without it: a debug-signed APK cannot update an installed release, so
// silently producing one only moves the failure onto the phone.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) {
        FileInputStream(f).use { load(it) }
    }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "dev.wianger.baya"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.wianger.baya"
        // The remote_pi_identity plugin needs API 34 (Block Store and
        // modern biometrics).
        minSdk = 34
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 64-bit ARM only: every phone Baya runs on (API 34+) is one, and
        // Moonlight's prebuilt OpenSSL and Opus are kept for it alone.
        ndk { abiFilters += listOf("arm64-v8a") }
        externalNativeBuild {
            ndkBuild {
                arguments += listOf("APP_PLATFORM=android-34")
            }
        }
    }

    // Moonlight's streaming core (moonlight-common-c, GPL-3.0).
    externalNativeBuild {
        ndkBuild {
            path = file("src/main/jni/Android.mk")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) signingConfig = signingConfigs.getByName("release")
        }
    }
}

gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { it.project == project && it.name.contains("Release") }
    if (buildsRelease && !hasReleaseKeystore) {
        throw GradleException(
            "Release signing is not configured. Create android/key.properties " +
                "(see docs/development.md) or build with --debug."
        )
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

dependencies {
    // Moonlight's pairing (certificates, AES) and its HTTP to Sunshine.
    implementation("org.bouncycastle:bcprov-jdk18on:1.85.2")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.85")
    implementation("com.squareup.okhttp3:okhttp:5.5.0")
    // Rewrites H.264 SPS for Android decoders, as Moonlight does.
    implementation("org.jcodec:jcodec:0.2.5")
}
