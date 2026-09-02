buildscript {
    val kotlin_version by extra("2.2.20")
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // Essential for building the app
        classpath("com.android.tools.build:gradle:8.1.1")
        // The fix for your "Daemon failed" / Printing package error
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlin_version")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// AGP 8.x requires every Android library to declare a `namespace` in its
// build.gradle. Older Flutter plugins (e.g. async_wallpaper 1.0.1) still rely
// on the deprecated `package` attribute in their AndroidManifest. Without this
// shim the build fails with "Namespace not specified". We backfill the
// namespace from the plugin's `group`, which conventionally matches the old
// manifest `package` value. Registered BEFORE the evaluationDependsOn block
// below — that block forces :app to evaluate, so afterEvaluate hooks have to
// be in place before it runs.
subprojects {
    afterEvaluate {
        if (project.hasProperty("android")) {
            val androidExt = project.extensions.findByName("android")
                    as? com.android.build.gradle.BaseExtension
            if (androidExt != null && androidExt.namespace == null) {
                androidExt.namespace = project.group.toString()
            }
            // Same vintage of plugin also compiles against an SDK too old
            // for AGP 8 release-resource verification (android:attr/lStar
            // needs 31+), failing verifyReleaseResources. Bump ONLY those.
            if (androidExt != null) {
                val sdk = androidExt.compileSdkVersion
                    ?.removePrefix("android-")?.toIntOrNull()
                if (sdk != null && sdk < 31) {
                    androidExt.compileSdkVersion(36)
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
