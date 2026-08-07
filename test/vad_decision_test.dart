import 'package:ai_assistant/utils/vad_decision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 与 audio_util.dart 中 MIN_RECORD_BEFORE_AUTOSTOP_MS 一致的常量
  const int minRecordMs = 500;
  const int timeoutMs = 1000;

  group('vadShouldAutoStop（语音通话「毫无反应」关键修复）', () {
    test('没说过话 -> 绝不自动断句（避免把空音频发给服务器）', () {
      final r = vadShouldAutoStop(
        hasSpoken: false,
        silenceMs: 9999,
        silenceTimeoutMs: timeoutMs,
        recordMs: 9999,
        minRecordMs: minRecordMs,
      );
      expect(r, isFalse);
    });

    test('说过话但录音过短 -> 不自动断句', () {
      final r = vadShouldAutoStop(
        hasSpoken: true,
        silenceMs: 9999,
        silenceTimeoutMs: timeoutMs,
        recordMs: 300, // < 500ms
        minRecordMs: minRecordMs,
      );
      expect(r, isFalse);
    });

    test('说过话、录音够长、但静音未达阈值 -> 不自动断句', () {
      final r = vadShouldAutoStop(
        hasSpoken: true,
        silenceMs: 600, // < 1000ms
        silenceTimeoutMs: timeoutMs,
        recordMs: 2000,
        minRecordMs: minRecordMs,
      );
      expect(r, isFalse);
    });

    test('说过话、录音够长、静音达到阈值 -> 自动断句发送', () {
      final r = vadShouldAutoStop(
        hasSpoken: true,
        silenceMs: 1000, // == 阈值
        silenceTimeoutMs: timeoutMs,
        recordMs: 2000,
        minRecordMs: minRecordMs,
      );
      expect(r, isTrue);
    });

    test('静音远超阈值 -> 自动断句', () {
      final r = vadShouldAutoStop(
        hasSpoken: true,
        silenceMs: 1500,
        silenceTimeoutMs: timeoutMs,
        recordMs: 3000,
        minRecordMs: minRecordMs,
      );
      expect(r, isTrue);
    });
  });

  group('Opus 帧样本数（60ms @ 16kHz 应为 960）', () {
    test('帧样本数计算正确', () {
      const int sampleRate = 16000;
      const int frameDurationMs = 60;
      final samplesPerFrame = (sampleRate * frameDurationMs) ~/ 1000;
      expect(samplesPerFrame, 960);
    });
  });
}
