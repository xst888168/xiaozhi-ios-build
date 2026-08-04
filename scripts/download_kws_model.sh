#!/usr/bin/env bash
#
# 下载并配置离线唤醒词（KWS）模型
# --------------------------------------------------------------
# 该脚本会：
#   1. 下载 sherpa-onnx 中文 Zipformer KWS 模型（仅 3.3M，支持“你好小智”等自定义唤醒词）
#   2. 将 encoder/decoder/joiner .onnx 与 tokens.txt 拷贝到 assets/models/
#   3. 把 keywords_raw.txt（中文）转换成模型所需的拼音 tokens，生成 keywords.txt
#
# 适用环境：Windows(Git Bash) / macOS / Linux
# 依赖：bash、curl、tar；可选 python3（用于生成拼音 tokens，脚本会自动尝试安装）
#
# 用法：
#   bash scripts/download_kws_model.sh
# 然后重新构建 APK：flutter pub get && flutter build apk --release
#
set -euo pipefail

# 项目根目录（本脚本位于 <root>/scripts/ 下）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$ROOT_DIR/assets/models"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2"
MODEL_NAME="sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01"

echo "==> 创建工作目录: $MODELS_DIR"
mkdir -p "$MODELS_DIR"

echo "==> 下载模型: $MODEL_URL"
curl -L --fail --show-error -o "$TMP_DIR/${MODEL_NAME}.tar.bz2" "$MODEL_URL"

echo "==> 解压模型"
tar -xvf "$TMP_DIR/${MODEL_NAME}.tar.bz2" -C "$TMP_DIR"

SRC="$TMP_DIR/${MODEL_NAME}"
echo "==> 拷贝模型文件到 $MODELS_DIR"
cp -v "$SRC/encoder.onnx"        "$MODELS_DIR/"
cp -v "$SRC/decoder.onnx"        "$MODELS_DIR/"
cp -v "$SRC/joiner.onnx"         "$MODELS_DIR/"
cp -v "$SRC/tokens.txt"          "$MODELS_DIR/"

echo "==> 生成 keywords.txt（中文 -> 拼音 tokens）"
if command -v python3 >/dev/null 2>&1; then
  # 确保 sherpa-onnx 可用（提供 text2token 工具）
  if ! python3 -c "import sherpa_onnx" >/dev/null 2>&1; then
    echo "    未检测到 sherpa_onnx，尝试 pip 安装（如需跳过可 Ctrl+C）..."
    pip3 install -q sherpa-onnx || pip install -q sherpa_onnx
  fi
  python3 -m sherpa_onnx.cli text2token \
    --tokens "$MODELS_DIR/tokens.txt" \
    --tokens-type ppinyin \
    "$MODELS_DIR/keywords_raw.txt" \
    "$MODELS_DIR/keywords.txt"
  echo "    已生成 $MODELS_DIR/keywords.txt"
else
  echo "!! 未找到 python3，无法自动生成拼音 tokens。"
  echo "   请手动执行（需要 pip install sherpa-onnx）："
  echo "   python3 -m sherpa_onnx.cli text2token \\"
  echo "     --tokens $MODELS_DIR/tokens.txt --tokens-type ppinyin \\"
  echo "     $MODELS_DIR/keywords_raw.txt $MODELS_DIR/keywords.txt"
  echo "   当前保留的 keywords.txt 为原始中文，唤醒可能不生效，请尽快生成拼音版本。"
fi

echo ""
echo "✅ 完成！现在 assets/models/ 已包含完整 KWS 模型。"
echo "   重新构建： flutter pub get && flutter build apk --release"
