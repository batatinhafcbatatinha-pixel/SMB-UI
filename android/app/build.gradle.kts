import org.gradle.api.tasks.compile.JavaCompile

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.add("-Xlint:-options")
}

android {
    namespace = "com.example.flutter_app_novo"
    // Use a recent compileSdk required by some plugins' resources (e.g., Material3 attrs)
    // Plugins require Android SDK 36 or higher, set compileSdk accordingly.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    
    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.flutter_app_novo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            pickFirsts += setOf("lib/**/libc++_shared.so")
        }
    }

    // CI provides a stable release keystore through env vars so APK updates install
    // over previous versions; local builds fall back to the debug keys.
    val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")?.let { file(it) }
    signingConfigs {
        if (releaseKeystore != null && releaseKeystore.exists()) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // Enable R8/ProGuard and include our rules file so missing optional
            // classes (EL/GSS/etc.) are treated as optional and don't break the build.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.hierynomus:smbj:0.11.5")
    implementation("net.engio:mbassador:1.3.0")
    implementation("org.slf4j:slf4j-api:1.7.36")
    implementation("org.slf4j:slf4j-simple:1.7.36")
}

flutter {
    source = "../.."
}
