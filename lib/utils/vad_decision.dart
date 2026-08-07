/// 静音自动断句（VAD）的纯逻辑判定，抽成独立文件以便单元测试，
/// 避免单元测试引入 audio_util 的本地音频/Opus 原生依赖。
bool vadShouldAutoStop({
  required bool hasSpoken,
  required int silenceMs, // 当前已连续静音时长
  required int silenceTimeoutMs,
  required int recordMs, // 已录音总时长
  required int minRecordMs,
}) {
  if (!hasSpoken) return false; // 还没说过话，绝不自动断句（持续聆听）
  if (recordMs < minRecordMs) return false; // 录音太短，避免误断
  if (silenceMs < silenceTimeoutMs) return false; // 静音时长不够
  return true;
}
