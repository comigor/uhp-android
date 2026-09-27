plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val ciKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
val ciKeystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val ciKeystoreType = System.getenv("ANDROID_KEYSTORE_TYPE") ?: "PKCS12"
val ciKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
val ciKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
val ciKeystoreFile = ciKeystorePath?.let { file(it) }
val useCiSigning = ciKeystoreFile?.isFile == true

println(
    if (useCiSigning) "signing: release keystore from environment"
    else "signing: keystore absent — falling back to debug signing"
)

android {
    namespace = "dev.borges.uhp_android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.borges.uhp_android"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (useCiSigning) {
            create("ci") {
                storeFile = ciKeystoreFile
                storeType = ciKeystoreType
                storePassword = ciKeystorePassword
                keyAlias = ciKeyAlias
                keyPassword = ciKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (useCiSigning) "ci" else "debug")
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
