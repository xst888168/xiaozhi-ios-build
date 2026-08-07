import 'package:ai_assistant/utils/wake_keyword.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WakeKeyword 关键词生成', () {
    test('小智 -> 纯 token 序列（无 @ 显示名，唤醒失效根因已修复）', () {
      final line = WakeKeyword.mandarinLine('小智');
      // 期望: x iǎo zh ì
      expect(line, isNotEmpty);
      expect(line.contains('@'), isFalse, reason: '@ 会导致关键词永远无法命中');
      expect(line.contains(RegExp(r'[一-龥]')), isFalse,
          reason: '中文不应出现在 token 序列里');
      // 4 个 token：x / iǎo / zh / ì
      expect(line.split(' '), hasLength(4));
      expect(line, 'x iǎo zh ì');
    });

    test('多个唤醒名分别生成合法 token 行', () {
      for (final name in ['你好小智', '小智小智', '小明']) {
        final line = WakeKeyword.mandarinLine(name);
        expect(line.contains('@'), isFalse);
        expect(line.contains(RegExp(r'[一-龥]')), isFalse);
        expect(line.trim().isNotEmpty, isTrue);
      }
    });
  });
}
