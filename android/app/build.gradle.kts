import groovy.json.JsonSlurper
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()

if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use {
        keystoreProperties.load(it)
    }
}

// ---------------------------------------------------------------------------
// Release plugin-registrant snapshot.
//
// `src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` is written
// by the Flutter tool, and its contents depend on the build mode: `flutter run`,
// `flutter test`, `flutter pub get` and the IDE's background tooling all rewrite
// it in debug mode, where dev-only plugins such as `integration_test` must be
// registered, while `flutter build ... --release` rewrites it without them.
//
// The file lives in the `main` source set, so every variant compiles whatever
// happens to be on disk when javac runs, and the Flutter Gradle plugin never
// adds dev-dependency plugin modules (integration_test) to the release
// classpath. A release build that compiles a debug-mode registrant therefore
// dies in `:app:compileReleaseJavaWithJavac` with
// "package dev.flutter.plugins.integration_test does not exist".
//
// No one owns that file: any other Flutter process (an IDE, a second terminal)
// rewrites it at any time, including in the middle of a running release build.
// The release variant therefore compiles a snapshot of the Java sources taken
// while Gradle is still configuring, with any dev-only registration removed, so
// a rewrite that lands before or after the snapshot cannot break the build.
// debug/profile keep compiling the live file, so integration tests still get
// `IntegrationTestPlugin`.
// ---------------------------------------------------------------------------

val toolGeneratedJavaDir = layout.projectDirectory.dir("src/main/java").asFile
val releaseJavaSnapshotDir = layout.buildDirectory.dir("flutterPluginRegistrant/release/java").get().asFile
val releaseRegistrantSnapshot = File(releaseJavaSnapshotDir, "io/flutter/plugins/GeneratedPluginRegistrant.java")

/** Dev-only plugins that ship native Android code, e.g. `integration_test`. */
val devDependencyPluginNames: Set<String> = run {
    val manifest = rootProject.file("../.flutter-plugins-dependencies")
    if (!manifest.isFile) {
        emptySet()
    } else {
        runCatching {
            val root = JsonSlurper().parse(manifest) as? Map<*, *> ?: return@runCatching emptySet()
            (root["plugins"] as? Map<*, *>)
                ?.values
                ?.filterIsInstance<List<*>>()
                ?.flatten()
                ?.filterIsInstance<Map<*, *>>()
                ?.filter { it["dev_dependency"] == true && it["native_build"] == true }
                ?.mapNotNull { (it["name"] as? String)?.takeIf { name -> name.isNotEmpty() } }
                ?.toSet()
                .orEmpty()
        }.getOrDefault(emptySet())
    }
}

/** `new <package>.<PluginName>()`, where any package segment may be the plugin name. */
val devOnlyPluginReference: Regex? = devDependencyPluginNames
    .takeIf { it.isNotEmpty() }
    ?.let { names ->
        Regex(
            "new\\s+(?:[A-Za-z_][A-Za-z0-9_]*\\.)*(?:" +
                names.sorted().joinToString("|") { Regex.escape(it) } +
                ")\\.[A-Z][A-Za-z0-9_]*\\s*\\(\\s*\\)"
        )
    }

/** The `flutterEngine.getPlugins().add(...);` statement that references it. */
val devOnlyRegistrationStatement: Regex? = devOnlyPluginReference?.let { reference ->
    Regex("flutterEngine\\.getPlugins\\(\\)\\.add\\(\\s*" + reference.pattern + "\\s*\\)\\s*;?")
}

// Freeze the Java sources of the main source set while Gradle is configuring, so
// later rewrites of the tree by other Flutter tool invocations cannot change what
// the release variant compiles. A concurrent release build may have snapshotted an
// older tree, so the previous copy is discarded instead of merged.
if (toolGeneratedJavaDir.isDirectory) {
    releaseJavaSnapshotDir.deleteRecursively()
    toolGeneratedJavaDir.copyRecursively(releaseJavaSnapshotDir, overwrite = true)
    // A snapshot taken from a debug-mode registrant is not compilable on its own,
    // so the dev-only registrations are dropped from the copy. Only the
    // `getPlugins().add(...)` call is removed: the surrounding `try`/`catch`
    // references no plugin class, so it compiles and does nothing at runtime.
    val statement = devOnlyRegistrationStatement
    if (statement != null && releaseRegistrantSnapshot.isFile) {
        releaseRegistrantSnapshot.writeText(statement.replace(releaseRegistrantSnapshot.readText(), ""))
    }
    if (releaseRegistrantSnapshot.isFile &&
        !releaseRegistrantSnapshot.readText().contains("class GeneratedPluginRegistrant")
    ) {
        throw GradleException(
            "Failed to snapshot the plugin registrant generated for the release build. " +
                "Launch release builds through the Flutter tool " +
                "(`flutter build apk --release`, or " +
                "powershell -ExecutionPolicy Bypass -File .\\build_release_apk.ps1) and retry."
        )
    }
}

tasks.matching { it.name.startsWith("compileRelease") && it.name.contains("Javac") }.configureEach {
    doFirst {
        if (!releaseRegistrantSnapshot.isFile) {
            throw GradleException(
                "No plugin registrant was generated for the release build. Launch release builds " +
                    "through the Flutter tool (`flutter build apk --release`, or " +
                    "powershell -ExecutionPolicy Bypass -File .\\build_release_apk.ps1) so the " +
                    "Flutter tool can regenerate the plugin registrant before Gradle runs."
            )
        }
        val leaked = devOnlyPluginReference?.find(releaseRegistrantSnapshot.readText())?.value
        if (leaked != null) {
            throw GradleException(
                "The plugin registrant used for the release build registers dev-only plugins " +
                    "($leaked), which the Flutter Gradle plugin excludes from the release " +
                    "classpath. Launch release builds through the Flutter tool " +
                    "(`flutter build apk --release`, or " +
                    "powershell -ExecutionPolicy Bypass -File .\\build_release_apk.ps1)."
            )
        }
    }
}

android {
    namespace = "com.example.task_app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.example.task_app"

        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion

        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Uses android/key.properties when available.
            // Falls back to debug signing for local testing.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 keep rules are enforced for ML Kit component registrars
            // (Face ID) and the PYLO home widgets.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    lint {
        checkReleaseBuilds = false
    }

    // `main` itself contributes no Java sources: the release variant compiles the
    // frozen copy taken at configuration time (see above), while debug and profile
    // compile the live tree that the Flutter tool regenerates. The Flutter tool
    // rewrites the generated plugin registrant for every non-release command, and
    // the release classpath never contains dev-dependency plugins, so compiling
    // that mutable file from a release build fails with an unresolvable package.
    sourceSets.getByName("main") {
        java.setSrcDirs(emptyList<String>())
    }
    sourceSets.getByName("debug") {
        java.srcDir("src/main/java")
    }
    sourceSets.getByName("profile") {
        java.srcDir("src/main/java")
    }
    sourceSets.getByName("release") {
        java.srcDir(releaseJavaSnapshotDir)
    }

    packaging {
        jniLibs {
            pickFirsts += setOf(
                "arm64-v8a/libapp.so",
                "armeabi-v7a/libapp.so",
                "x86_64/libapp.so",
                "x86/libapp.so",
                "arm64-v8a/libsqlite3.so",
                "armeabi-v7a/libsqlite3.so",
                "x86_64/libsqlite3.so",
                "x86/libsqlite3.so"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(
            org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        )
    }
}

dependencies {
    coreLibraryDesugaring(
        "com.android.tools:desugar_jdk_libs:2.1.5"
    )
}

flutter {
    source = "../.."
}