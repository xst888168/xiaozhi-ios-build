# Flutter混淆规则
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 保留flutter_displaymode相关类
-keep class dev.flutter.plugin.** { *; }

# 保留Kotlin相关类
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }

# 保留androidx相关类
-keep class androidx.** { *; }
-keep class com.google.android.material.** { *; }

# Flutter 引擎引用了 Play Core 的 deferred components API，但本项目未接入
# Play Core 依赖，R8 会报 Missing class。这里显式忽略。
-dontwarn com.google.android.play.core.**
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }
-keep class io.flutter.embedding.android.FlutterPlayStoreSplitApplication { *; }

# 保留 sherpa-onnx 离线唤醒相关的 JNI 类（R8 不能裁剪，否则 KWS 崩溃）
-keep class com.k2fsa.sherpa.onnx.** { *; }
-keep class com.k2fsa.** { *; }
-dontwarn com.k2fsa.**

# 移除debug日志
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
    public static int i(...);
} 