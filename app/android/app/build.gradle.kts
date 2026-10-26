// سايبر مكة — تطبيق الأدمن: أداة داخلية بتتنزل APK مباشر على موبايل المحل (مش على Google Play).
plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cybermaka.maka_admin"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.cybermaka.admin"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // أداة داخلية بتتنزل باليد: توقيع الـ debug كفاية (مفيش رفع على متجر).
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // MakaPushExtension — نفس نسخة OneSignal اللي جاية مع onesignal_flutter 5.6.2
    compileOnly("com.onesignal:core:5.9.4")
}
