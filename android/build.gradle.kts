allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ---------------------------------------------------------------------------
// AGP 8 要求每个 Android 模块显式声明 namespace。
// 部分老旧 Flutter 插件（如 flutter_pcm_player）只在 AndroidManifest.xml 里写了
// package 属性，会导致 "Namespace not specified" 配置失败。
// 这里在子工程 evaluate 之后自动从 manifest 回填 namespace，避免手改 pub cache。
// 注意：必须注册在 evaluationDependsOn(":app") 之前，否则会因项目已评估而报错。
// ---------------------------------------------------------------------------
subprojects {
    if (!project.state.executed) {
        afterEvaluate {
            val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
            try {
                val getter = androidExt.javaClass.methods.firstOrNull {
                    it.name == "getNamespace" && it.parameterCount == 0
                } ?: return@afterEvaluate
                val current = getter.invoke(androidExt) as String?
                if (!current.isNullOrEmpty()) return@afterEvaluate

                val manifest = project.file("src/main/AndroidManifest.xml")
                if (!manifest.exists()) return@afterEvaluate
                val pkg = Regex("package\\s*=\\s*\"([^\"]+)\"")
                    .find(manifest.readText())?.groupValues?.getOrNull(1)
                    ?: return@afterEvaluate

                val setter = androidExt.javaClass.methods.firstOrNull {
                    it.name == "setNamespace" && it.parameterCount == 1
                } ?: return@afterEvaluate
                setter.invoke(androidExt, pkg)
                println("[namespace-fix] ${project.name} -> $pkg")
            } catch (e: Exception) {
                println("[namespace-fix] skipped ${project.name}: ${e.message}")
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
