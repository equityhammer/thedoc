[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## Recommended structure

```
<app>/
├── app/
│   ├── build.gradle.kts                    # alias plugins, BuildConfig on, applicationVariants APK rename
│   ├── proguard-rules.pro
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── java/<package>/
│       │   ├── <App>Application.kt         # CrashReporter.install + notification channels + DI container by lazy
│       │   ├── MainActivity.kt             # ComponentActivity + ComposeContent + setContent { <App>Theme { NavGraph(...) } }
│       │   ├── data/
│       │   │   ├── <App>Database.kt        # Room: getInstance() singleton with INSTANCE/synchronized
│       │   │   ├── *Dao.kt
│       │   │   ├── *Entity.kt
│       │   │   ├── SettingsStore.kt        # DataStore preferences OR SharedPreferences object
│       │   │   └── <App>Container.kt       # If app has > 3 deps; holds db + client + settings + scope
│       │   ├── service/                    # Foreground services
│       │   ├── receiver/                   # BroadcastReceivers (alarm, boot)
│       │   ├── network/                    # OkHttp client, WS, REST
│       │   ├── navigation/ (or ui/nav/)    # NavGraph, route constants
│       │   ├── ui/
│       │   │   ├── screen/                 # HomeScreen.kt, SettingsScreen.kt, etc. (each one composable per file)
│       │   │   ├── component/              # Reusable widgets
│       │   │   └── theme/                  # Theme.kt + Color.kt + Type.kt (Material 3)
│       │   ├── viewmodel/                  # AndroidViewModel + StateFlow
│       │   └── util/
│       │       ├── CrashReporter.kt        # Mandatory - see template
│       │       ├── UpdateNotifier.kt       # Mandatory if sprint loop is active
│       │       ├── DebugLogger.kt          # Optional - periodic state dump POSTed to server
│       │       └── AppSettings.kt          # Optional - small SharedPreferences wrapper + CompositionLocal
│       └── res/
│           ├── drawable/ic_notification.xml  # MUST exist - used as smallIcon for ALL notifications
│           ├── values/{strings,colors,themes}.xml
│           └── xml/network_security_config.xml  # Tailscale IP cleartext exception
├── gradle/
│   ├── libs.versions.toml                   # See "Standard dependencies" below
│   └── wrapper/
├── dist/
│   ├── serve_<app>.py                       # Sprint server
│   ├── sprint.md                            # Current sprint state (see template)
│   └── crashes/                             # Gitignored
├── build.gradle.kts                         # Top-level: just `apply false` plugins
├── settings.gradle.kts
├── gradle.properties
├── gradlew / gradlew.bat
├── README.md
├── CLAUDE.md                                # Project context for Claude Code
├── SPEC.md                                  # Vision + non-goals (for non-trivial apps)
└── REFACTOR.md                              # Anti-patterns + lessons (for apps that have evolved)
```

### Naming conventions

- **Package:** `com.app.<slug>` or `com.<brand>.<slug>`. Pick one and stick with it across your apps.
- **Application class:** `<Slug>Application`.
- **Theme:** `<Slug>Theme` Composable in `ui/theme/Theme.kt`.
- **Database:** `<App>Database` with `getInstance(ctx)` and a single DAO accessor.
- **APK filename:** `<slug>-<versionName>-<buildType>.apk`. Set via `applicationVariants.all { outputs.all { outputFileName = ... } }`.

---

## Standard dependencies (`gradle/libs.versions.toml`)

```toml
[versions]
agp = "8.5.2"
kotlin = "2.0.0"
ksp = "2.0.0-1.0.24"           # only if using Room
compose-bom = "2024.10.01"
navigation = "2.8.5"
room = "2.6.1"                  # only if persistent state
lifecycle = "2.8.6"
activity-compose = "1.9.2"
core-ktx = "1.13.1"
# Optional based on app needs:
okhttp = "4.12.0"
datastore = "1.1.1"
coil = "2.7.0"
coroutines = "1.8.1"

[libraries]
compose-bom = { group = "androidx.compose", name = "compose-bom", version.ref = "compose-bom" }
compose-ui = { group = "androidx.compose.ui", name = "ui" }
compose-ui-graphics = { group = "androidx.compose.ui", name = "ui-graphics" }
compose-ui-tooling-preview = { group = "androidx.compose.ui", name = "ui-tooling-preview" }
compose-ui-tooling = { group = "androidx.compose.ui", name = "ui-tooling" }
compose-material3 = { group = "androidx.compose.material3", name = "material3" }
compose-material-icons-extended = { group = "androidx.compose.material", name = "material-icons-extended" }
compose-animation = { group = "androidx.compose.animation", name = "animation" }
navigation-compose = { group = "androidx.navigation", name = "navigation-compose", version.ref = "navigation" }
room-runtime = { group = "androidx.room", name = "room-runtime", version.ref = "room" }
room-ktx = { group = "androidx.room", name = "room-ktx", version.ref = "room" }
room-compiler = { group = "androidx.room", name = "room-compiler", version.ref = "room" }
lifecycle-viewmodel-compose = { group = "androidx.lifecycle", name = "lifecycle-viewmodel-compose", version.ref = "lifecycle" }
lifecycle-runtime-compose = { group = "androidx.lifecycle", name = "lifecycle-runtime-compose", version.ref = "lifecycle" }
lifecycle-service = { group = "androidx.lifecycle", name = "lifecycle-service", version.ref = "lifecycle" }
activity-compose = { group = "androidx.activity", name = "activity-compose", version.ref = "activity-compose" }
core-ktx = { group = "androidx.core", name = "core-ktx", version.ref = "core-ktx" }
okhttp = { group = "com.squareup.okhttp3", name = "okhttp", version.ref = "okhttp" }
datastore-preferences = { group = "androidx.datastore", name = "datastore-preferences", version.ref = "datastore" }
coroutines-android = { group = "org.jetbrains.kotlinx", name = "kotlinx-coroutines-android", version.ref = "coroutines" }
junit = { group = "junit", name = "junit", version = "4.13.2" }
json = { group = "org.json", name = "json", version = "20240303" }   # required for any code that uses org.json from JVM unit tests; android.jar's stubs throw "not mocked"

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
```

### `app/build.gradle.kts` skeleton

```kotlin
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)               // only if using Room
}

android {
    namespace = "com.app.<slug>"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.app.<slug>"
        minSdk = 26                       // Android 8.0
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        resValue("string", "app_name", "<App Display Name>")
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"   // OPTIONAL: lets debug + release coexist on the same device (useful for "beta channel")
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true                // Required so BuildConfig.VERSION_NAME is generated
    }

    applicationVariants.all {
        val variant = this
        outputs.all {
            val output = this as com.android.build.gradle.internal.api.BaseVariantOutputImpl
            output.outputFileName = "<slug>-${variant.versionName}-${variant.buildType.name}.apk"
        }
    }
}
```

---

## Build / release conventions

- **Versioning:** `versionCode` is a monotonic integer; `versionName` is `MAJOR.MINOR.PATCH` with PATCH bumped per sprint, MINOR bumped at major feature gates. Bumped manually in `app/build.gradle.kts` at the end of each sprint. No fastlane / no semantic-release / no CI bumping.
- **Always `clean` for sprint ships.** Use `./gradlew clean assembleDebug`, not `./gradlew assembleDebug`. Gradle's `generateDebugBuildConfig` task reports UP-TO-DATE even when `defaultConfig.versionName` changes, so the BuildConfig.java carries over from the previous build and crash reports show the wrong `app version` line. The user-facing version banner reads from `PackageManager` so it's correct either way, but diagnostic logs become misleading.
- **Update `CHANGELOG.md` in the same diff as the version bump.** Every sprint ship adds a new top-level `## vX.Y.Z - YYYY-MM-DD` section to `app/src/main/assets/CHANGELOG.md`. The Home screen's "tap version" affordance loads it from assets, so without an update the user sees stale content for the new build.
- **Build channel:** Debug only. No signed release builds. APK lands in `app/build/outputs/apk/debug/<slug>-<version>-debug.apk` and gets symlinked or `find_newest_apk()`-discovered by the dist server.
- **No CI/CD by default.** All builds are local `./gradlew assembleDebug` or via Claude Code.
- **Distribution:** Tailscale + sideload. The local Python server at `<tailscale-ip>:<port>` exposes the APK. Browse to it from your phone, tap download, tap install. No Play Store, no internal testing track.
- **Conflict-review pass at end of sprint:** Walk every implemented item against every other; resolve any cross-talk (state stores, shared keys, lifecycle order) BEFORE building.

---

