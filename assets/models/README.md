# 离线唤醒词模型（KWS）

本目录用于存放 sherpa-onnx 离线关键词唤醒（Keyword Spotter）模型，使 App 支持
**完全本地、不依赖网络** 的“你好小智”语音唤醒（痛点 #1）。

## 模型

- 名称：`sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01`
- 体积：约 3.3M 参数，非常适合手机端实时运行
- 下载地址：
  `https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01.tar.bz2`
- 该模型基于拼音（ppinyin）tokens，因此 `keywords.txt` 必须是**拼音 token 序列**，
  不能直接写中文。请务必运行 `scripts/download_kws_model.sh` 自动生成。

## 目录内容

| 文件 | 说明 |
| --- | --- |
| `encoder.onnx` | 模型编码器 |
| `decoder.onnx` | 模型解码器 |
| `joiner.onnx`  | 模型联合器 |
| `tokens.txt`   | 模型词表（拼音） |
| `keywords_raw.txt` | 原始中文唤醒词（每行一个），如 `你好小智` |
| `keywords.txt` | 由脚本把 `keywords_raw.txt` 转换成的拼音 token 文件（**必须存在且正确**） |

> ⚠️ 如果仅放 `keywords.txt`（原始中文）而缺少上面的 `.onnx` 文件，唤醒功能会优雅降级
> （不崩溃，但“你好小智”不会触发）。请先运行下载脚本补全模型。

## 自定义唤醒词

1. 编辑 `keywords_raw.txt`，每行一个中文唤醒词（例如追加 `小智小智`）。
2. 重新运行 `bash scripts/download_kws_model.sh`。
3. 重新构建 APK。

## 如何下载

```bash
# 在项目根目录（含 pubspec.yaml 的目录）
bash scripts/download_kws_model.sh
```

脚本会自动下载、解压、拷贝模型文件，并用 `sherpa-onnx` 的 `text2token`
工具把 `keywords_raw.txt` 转成 `keywords.txt`。
