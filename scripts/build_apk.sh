#!/usr/bin/env bash
#
# 一键构建 Android Release APK（需在已安装 Flutter 的环境运行）
# 适用：Windows(Git Bash) / macOS / Linux
#
# 前置：
#   - 已安装 Flutter 3.24+ 与 Android SDK（含 NDK，本项目已指定 ndkVersion=27）
#   - 已运行 scripts/download_kws_model.sh 补全唤醒词模型（否则唤醒功能优雅降级）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "==> [1/3] flutter pub get"
flutter pub get

echo "==> [2/3] flutter analyze（仅检查，不阻断构建）"
flutter analyze || echo "⚠️ analyze 有警告，请查看上方输出"

echo "==> [3/3] flutter build apk --release"
flutter build apk --release

APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK" ]; then
  echo ""
  echo "✅ 构建成功！APK 位于："
  echo "   $APK"
else
  echo "❌ 未找到 APK，请检查上面的构建日志"
  exit 1
fi
