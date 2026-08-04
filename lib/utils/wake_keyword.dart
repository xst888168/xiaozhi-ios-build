import 'package:pinyin/pinyin.dart';
import 'package:jyutping/jyutping.dart';

/// 把用户自定义的「唤醒名」（中文）转换为 sherpa-onnx KeywordSpotter 所需的
/// 关键词行（每行格式：`token token ... @显示名`）。
///
/// - 国语：使用 Hanyu 拼音（带声调），并拆成「声母 + 带声调韵母」的子 token，
///   以匹配 wenetspeech ppinyin KWS 模型的词表（参考官方 keywords.txt 格式）。
/// - 粤语：使用 Jyutping（带声调数字），整音节作为一个 token。
///   仅在额外放入粤语 KWS 模型时生效（官方目前无独立粤语 KWS 模型）。
class WakeKeyword {
  // 普通话声母（含 y/w；zh/ch/sh 为两字母，单独优先匹配）
  static const Set<String> _initials = {
    'b', 'p', 'm', 'f', 'd', 't', 'n', 'l', 'g', 'k', 'h', 'j', 'q', 'x',
    'z', 'c', 's', 'r', 'y', 'w',
  };

  static const List<String> _twoLetterInitials = ['zh', 'ch', 'sh'];

  /// 国语：中文名 -> ppinyin 关键词行
  /// 例：'小智' -> 'x iǎo zh ì @小智'
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
    return '${tokens.join(' ')} @$name';
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

  /// 粤语：中文名 -> Jyutping 关键词行
  /// 例：'小智' -> 'siu2 zi3 @小智'（具体发音取决于字库）
  /// 若字库缺字或整串都不是中文，返回空字符串（调用方需跳过该行）。
  static String cantoneseLine(String name) {
    final syllables = <String>[];
    for (int i = 0; i < name.length; i++) {
      final ch = name[i];
      if (!JyutpingHelper.isChinese(ch)) continue;
      try {
        final syl = JyutpingHelper.getJyutpingAsString(ch, false).trim();
        if (syl.isNotEmpty) syllables.add(syl);
      } catch (_) {
        // 该字不在 Jyutping 字库内，忽略
      }
    }
    if (syllables.isEmpty) return '';
    return '${syllables.join(' ')} @$name';
  }
}
