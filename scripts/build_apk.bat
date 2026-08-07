@echo off
REM 一键构建 Android Release APK（Windows 原生 CMD）
REM 前置：已安装 Flutter 3.24+ 与 Android SDK（含 NDK，本项目已指定 ndkVersion=27）
REM       已运行 scripts/download_kws_model.sh 补全唤醒词模型（否则唤醒功能优雅降级）

cd /d "%~dp0\.."

echo ==^> [1/3] flutter pub get
call flutter pub get

echo ==^> [2/3] flutter analyze
call flutter analyze

echo ==^> [3/3] flutter build apk --release
call flutter build apk --release

if exist "build\app\outputs\flutter-apk\app-release.apk" (
  echo.
  echo ✅ 构建成功！APK 位于：
  echo    %CD%\build\app\outputs\flutter-apk\app-release.apk
) else (
  echo ❌ 未找到 APK，请检查上面的构建日志
  exit /b 1
)
