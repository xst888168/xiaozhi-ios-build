# 小智 Android 客户端 · 缺陷补齐版构建说明

基于社区仓库 `TOM88812/xiaozhi-android-client`（Flutter）改造，补齐两个原始缺陷：

1. **离线语音唤醒**：说自定义名字即可唤醒（国语 / 粤语），完全本地运行，不依赖网络。
2. **点击即说 + 2 秒静音自动断句**：不再需要「长按麦克风」，点一下开始聆听，停嘴 2 秒自动发送。

> 仓库原名 `ai_assistant`，应用显示名 `AI-LHHT`，与 ESP32 小智走官方
> `wss://api.tenclass.net/xiaozhi/v1/` 协议对接（手机作为软小智客户端）。

---

## 一、环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| Flutter | **3.29.3+** | Dart SDK ≥ 3.7.0（仓库 `pubspec.yaml` 约束 `sdk: ^3.7.0`）|
| JDK | 17 | Android Gradle 构建需要 |
| Android SDK | platform `android-34` | `compileSdk`/`targetSdk = 34` |
| build-tools | `34.0.0` | |
| NDK | `27.0.12077973` | `sherpa_onnx` 原生推理需要 |
| platform-tools | 任意 | adb 安装用 |

> 已预先配好 Gradle 国内镜像（腾讯云 Maven），替换被墙的 `maven.google.com`，
> 见 `android/build.gradle.kts` 与 `android/settings.gradle.kts`。

---

## 二、一键构建（Android APK）

### Windows（PowerShell / Git Bash）

```bash
# 1) 环境变量（按你的实际安装路径修改）
$env:JAVA_HOME   = "C:/path/to/jdk-17"
$env:ANDROID_HOME= "C:/path/to/android-sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PATH        = "$env:JAVA_HOME/bin;$env:PATH"

# 2) 拉取依赖（国内可加镜像加速）
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
flutter pub get

# 3) 编译 release APK（推荐：仅 arm64，约 71MB）
flutter build apk --release --target-platform android-arm64 --split-per-abi
# 产物：build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

# 若需全架构 fat apk（体积大），去掉 --split-per-abi 即可：
# flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk

# 4) 产物
# build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### 本工作区已就绪的环境（若由我在这里编译）

- Flutter 3.29.3：`C:/Users/Administrator/WorkBuddy/2026-08-04-12-53-27/.tools/flutter329/flutter`
- JDK 17：`C:/Users/Administrator/WorkBuddy/2026-08-04-12-53-27/.tools/jdk17/jdk-17.0.20+8`
- Android SDK：`C:/Users/Administrator/WorkBuddy/2026-08-04-12-53-27/.tools/android-sdk`

构建脚本：`scripts/build_apk.sh` / `scripts/build_apk.bat`（已配好上述镜像与路径）。

---

## 三、iOS（需 Mac，本环境无 Mac）

1. 在 Mac 上 `flutter pub get`
2. `flutter build ipa`（用 TrollStore 免签装 IPA，或正常开发者签名）
3. 其余逻辑与 Android 完全一致。

---

## 四、功能使用

### 离线唤醒（自定义名字）
- 入口：**设置 → 通用 → 离线唤醒词**
- 打开总开关，在「唤醒名字」输入框填写任意中文名（如「小智」「小明」）。
- 名字在运行时自动转换为唤醒词词典：
  - **国语**：Hanyu 拼音（带声调），由 `pinyin` 包生成；
  - **粤语**：Jyutping，由 `jyutping` 包生成（需额外粤语 KWS 模型才生效，见下）。
- 模型已内置在 `assets/models/`，首次启动自动拷贝到应用私有目录，**无需联网下载**。
- 唤醒后自动开始一次聆听；对话结束自动恢复监听。命中后 2 秒冷却防重复触发。

### 粤语唤醒说明
代码层已支持粤语关键词生成与双引擎接口；但 **sherpa-onnx 官方目前没有独立的粤语 KWS 声学模型**
（粤语只出现在 ASR 模型里）。若你手头有粤语 KWS 模型，放入 `assets/models_cantonese/`
（含 `encoder.onnx / decoder.onnx / joiner.onnx / tokens.txt`），引擎会
自动加载并启用粤语唤醒，无需改代码。

### 点击即说 + 2 秒静音断句
- 聊天页底部语音按钮：**点击开始聆听**（不再长按）。
- 录音中再次点击 = 取消；**停嘴 2 秒（默认）自动发送**。
- 该行为由 `AudioUtil` 的 RMS 静音检测（`SILENCE_TIMEOUT_MS = 2000`）控制，
  可在 `lib/utils/audio_util.dart` 顶部常量调整时长。

---

## 五、关键改动文件

| 文件 | 改动 |
|------|------|
| `pubspec.yaml` | 新增 `sherpa_onnx` / `pinyin` / `jyutping`；`assets/models/`；`sdk: ^3.7.0` |
| `lib/services/wake_word_service.dart` | **新增**：基于 `KeywordSpotter` 的离线唤醒（国语+粤语双引擎、自定义名、命中暂停/恢复）|
| `lib/utils/wake_keyword.dart` | **新增**：中文名 → 关键词行（国语拼音 / 粤语 Jyutping）|
| `lib/utils/audio_util.dart` | 新增 VAD 静音自动断句（RMS + 2 秒阈值）|
| `lib/screens/chat_screen.dart` | 语音按钮改为点击即说；VAD 自动发送；唤醒命中自动开始聆听 |
| `lib/screens/settings_screen.dart` | 通用页新增唤醒开关 + 自定义名字输入 |
| `lib/screens/voice_call_screen.dart` | 进通话前 suspend 唤醒（防抢麦）；视频模式接入本地相机 + 端侧物体识别；退出 resume 唤醒 |
| `lib/services/object_detection_service.dart` | **新增**：ML Kit 物体检测（YUV_420_888→NV21，流式节流）|
| `lib/utils/vad_decision.dart` | **新增**：VAD 自动断句纯函数（含 `hasSpoken` 守卫，单测覆盖）|
| `lib/utils/audio_util.dart` | VAD 静音自动断句（RMS + 2 秒阈值）；新增 `_hasSpoken` 守卫防通话空音频断句；**新增打断检测** `bargeInEnabled`/`bargeInGain`/`onSpeechStart`（监听模式下音量突增触发，防小智回声误触发）|
| `lib/services/xiaozhi_service.dart` | TTS 状态计数修复：`tts stop` 权威复位（`_isAssistantSpeaking` 归零并触发 `assistantSpeakingStop`），解决多句回复时卡在「小智正在说话」、麦克风不回来 |
| `lib/screens/voice_call_screen.dart` | 进通话前 suspend 唤醒（防抢麦）；视频模式接入本地相机 + 端侧物体识别；退出 resume 唤醒；**新增打断小智（barge-in）**：小智播报时持续监听麦克风、音量突增即打断并转聆听；**新增息屏锁屏保活**：进通话拉起 `CallForegroundService` |
| `lib/services/call_keep_alive.dart` | **新增**：通话保活 MethodChannel（`com.lhht.ai_assistant/call`）封装 |
| `android/app/.../MainActivity.kt` | MethodChannel `com.lhht.ai_assistant/wake`：`startWakeService`/`stopWakeService`/`bringToFront`；**新增** `com.lhht.ai_assistant/call`：`startCallService`/`stopCallService`/`bringToFront` |
| `android/app/.../WakeForegroundService.kt` | 前台服务保活（`microphone` 类型 + `PARTIAL_WAKE_LOCK`）|
| `android/app/.../CallForegroundService.kt` | **新增**：通话保活前台服务（`microphone` 类型 + `PARTIAL_WAKE_LOCK`，通知“小智AI 语音通话中”）|
| `android/app/src/main/AndroidManifest.xml` | 唤醒前台服务 + 通话前台服务 + 权限；加 `tools:replace` 解决与 camera 插件的 `maxSdkVersion` 冲突 |
| `android/build.gradle.kts` / `settings.gradle.kts` | Gradle 仓库换国内镜像 |
| `assets/models/` | 内置 wenetspeech KWS 模型（int8 量化）+ 默认关键词 `小智` |
| `pubspec.yaml` | 新增 `camera ^0.11.0`、`google_mlkit_object_detection ^0.14.0`（按 Dart 3.7.2 锁版本）；版本 2.0.17+19 |
| `lib/utils/audio_util.dart` | **修复「语音通话说完话静音满 1 秒不发送、卡在『正在说』」**：`startRecording()` 幂等分支（已在录音时）改为调用新增 `_rearmSilenceTimer()`，依据当前 `vadEnabled`/`onSilenceAutoStop`/`silenceTimeoutMs` 重新装备静音断句定时器；并重置 `_hasSpoken=false` 确保必须检测到本轮真实语音才允许断句发送。全新启动路径同样走 `_rearmSilenceTimer()` |

---

## 六、已知边界
- 粤语唤醒需自备粤语 KWS 模型（官方暂无）。
- 唤醒词命中依赖模型词表覆盖；生僻字或模型未收录的发音可能不触发，可在设置换一个名字。
- 打断小智靠「用户音量明显高于小智自身回声/环境噪声」判定；若手机扬声器开得很大且离嘴很近，偶可能误打断。可在 `lib/utils/audio_util.dart` 调大 `bargeInGain`（默认 3.0，越大越保守）。小智回声较小时也可能漏打断，此时可用页面「手掌打断」按钮。
- 息屏/锁屏通话保活依赖前台服务 + `PARTIAL_WAKE_LOCK`；部分国产 ROM（小米/华为/OPPO 等）会强杀后台，需到系统设置手动授予本应用「自启动 / 后台运行无限制 / 电池优化忽略」等权限，否则息屏后可能被回收。
- 首次 `pub get` 若报某个依赖要求更高 Dart，请升级 Flutter 到 3.29.3+（已验证可全量解析）。
- 视频通话的「物体识别」为**端侧本地识别**，不上传视频帧。要让云端小智真正"看到你"，官方走的是 MCP 摄像头工具（`camera.take_photo`/视觉理解 MCP）：由云端 LLM 按需调用、客户端抓一张图回传分析，并非持续视频流，且需在控制台绑定视觉 MCP；本期未做上行。
- 构建踩坑：`camera` 插件会声明 `WRITE_EXTERNAL_STORAGE@maxSdkVersion=28`，与 App 的 `maxSdkVersion=32` 冲突，已在 `AndroidManifest.xml` 用 `tools:replace` 解决；若 Gradle 报 `flutter.bat finished with non-zero exit value 1`，多为残留守护进程环境不一致，先 `android/gradlew --stop` 或 `GRADLE_OPTS=-Dorg.gradle.daemon=false` 重试。
