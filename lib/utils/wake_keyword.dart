import 'package:pinyin/pinyin.dart';

/// 把用户自定义的「唤醒名」（中文）转换为 sherpa-onnx KeywordSpotter 所需的
/// 关键词行（每行格式：`token token ...`，即模型词表中的拼音 token 序列）。
///
/// ⚠️ 关键点（之前唤醒完全失效的根因）：sherpa-onnx 的 KeywordSpotter 只认
/// 「空格分隔的 token 序列」，token 必须全部存在于模型的 `tokens.txt` 里。
/// 旧实现额外追加了 ` @显示名`（如 `x iǎo zh ì @小智`），而 `@` 与中文显示名
/// 都不在词表中，导致该关键词永远无法命中 —— 表现就是「喊破喉咙也唤不醒」。
/// 现已去掉 `@显示名`，只保留纯 token 序列。
///
/// 国语：使用 Hanyu 拼音（带声调），并拆成「声母 + 带声调韵母」的子 token，
/// 以匹配 wenetspeech ppinyin KWS 模型的词表（参考官方 keywords.txt 格式）。
class WakeKeyword {
  // 普通话声母（含 y/w；zh/ch/sh 为两字母，单独优先匹配）
  static const Set<String> _initials = {
    'b', 'p', 'm', 'f', 'd', 't', 'n', 'l', 'g', 'k', 'h', 'j', 'q', 'x',
    'z', 'c', 's', 'r', 'y', 'w',
  };

  static const List<String> _twoLetterInitials = ['zh', 'ch', 'sh'];

  /// 国语：中文名 -> ppinyin 关键词行（纯 token 序列，无 @ 显示名）
  /// 例：'小智' -> 'x iǎo zh ì'
  static String mandarinLine(String name) {
    final py = PinyinHelper.getPinyin(
      name,
      separator: ' ',
      format: PinyinFormat.WITH_TONE_MARK,
    );
    final tokens = <String>[];
    for (final raw in py.split(' ')) {
      final syl = raw.trim().toLowerCase();
      if (syl.isEmpty) continue;
      tokens.addAll(_splitSyllable(syl));
    }
    return tokens.join(' ');
  }

  /// 把单个拼音音节拆成 [声母, 带声调韵母]（零声母则整体作为一个 token）
  static List<String> _splitSyllable(String syl) {
    for (final ini in _twoLetterInitials) {
      if (syl.startsWith(ini) && syl.length > ini.length) {
        return [ini, syl.substring(ini.length)];
      }
    }
    final first = syl[0];
    if (_initials.contains(first) && syl.length > 1) {
      return [first, syl.substring(1)];
    }
    // 零声母音节（a/o/e/ai/ao/ou/an/ang/er ...）整体作为一个 token
    return [syl];
  }
}
