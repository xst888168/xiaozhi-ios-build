#!/usr/bin/env bash
# 在当前工作区一键构建 Android arm64 Release APK
# 工具链路径已固定为 2026-08-04 工作区内的 Flutter / JDK / Android SDK

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

export JAVA_HOME="C:/Users/Administrator/WorkBuddy/2026-08-04-12-53-27/.tools/jdk17/jdk-17.0.20+8"
export ANDROID_HOME="C:/Users/Administrator/WorkBuddy/2026-08-04-12-53-27/.tools/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$PATH"
export PATH="C:/Users/Administrator/WorkBuddy/2026-08-04-12-53-27/.tools/flutter329/flutter/bin:$PATH"
export PUB_HOSTED_URL="https://pub.flutter-io.cn"

echo "==> [1/4] flutter pub get"
flutter pub get

echo "==> [2/4] flutter analyze"
flutter analyze || echo "⚠️ analyze 有警告，请查看上方输出"

echo "==> [3/4] flutter build apk --release --split-per-abi --target-platform=android-arm64"
flutter build apk --release --split-per-abi --target-platform=android-arm64

echo "==> [4/4] 复制产物到 outputs/"
mkdir -p "$ROOT_DIR/outputs"
APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
OUT="$ROOT_DIR/outputs/小智AI-v2.0.13-arm64.apk"
cp "$APK" "$OUT"

echo ""
echo "✅ 构建成功！"
echo "   原始产物: $APK"
echo "   发布产物: $OUT"
