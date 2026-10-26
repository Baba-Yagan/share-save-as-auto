import com.android.build.api.dsl.CommonExtension

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
subprojects {
    project.evaluationDependsOn(":app")
}
// Consumer-side compileSdk pin: raise every Android plugin module to compileSdk 36
// (flutter_plugin_android_lifecycle requires consumers to compile against >= 36).
// This is set on the consumer side only; plugin sources are left untouched.
subprojects {
    val sub = this
    fun Project.configureCompileSdk() {
        if (pluginManager.hasPlugin("com.android.application") ||
            pluginManager.hasPlugin("com.android.library")) {
            val android = extensions.getByName("android") as CommonExtension
            if ((android.compileSdk ?: -1) < 36) {
                android.compileSdk = 36
            }
        }
    }
    try {
        sub.afterEvaluate { sub.configureCompileSdk() }
    } catch (_: Exception) {
        // Project already evaluated: apply the compileSdk pin directly.
        sub.configureCompileSdk()
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
