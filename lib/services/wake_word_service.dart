import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:ai_assistant/services/wake_audio_hub.dart';
import 'package:ai_assistant/utils/wake_keyword.dart';

/// 单个唤醒引擎配置（一个声学模型 + 一个关键词文件）
class _WakeProfile {
  final String id;
  final String docFolder;
  sherpa.KeywordSpotter spotter;
  sherpa.OnlineStream stream;

  _WakeProfile({
    required this.id,
    required this.docFolder,
    required this.spotter,
    required this.stream,
  });
}

/// 离线唤醒词服务（基于 sherpa_onnx KeywordSpotter，普通话 KWS）
///
/// 设计要点：
/// 1. 国语模型以 assets 形式打包（assets/models/，首次运行拷贝到
///    应用私有目录 documents/kws_model）。
/// 2. 唤醒名（自定义）在运行时由 [WakeKeyword] 转换为对应模型的关键词行：
///    - 国语：Hanyu 拼音（ppinyin）
///    命中即触发 [onWake]。
/// 3. 命中后自动 [suspend] 自身麦克风监听，避免小智回复语音造成回声误触发；
///    对话结束后由调用方（聊天页）调用 [resume] 恢复监听。
/// 4. 模型缺失或初始化失败均优雅降级（不抛异常、不阻塞 UI）。
/// 5. 麦克风通过 [WakeAudioHub] 共享，统一持有唯一录音会话，避免重复开 recorder。
class WakeWordService {
  static const String _TAG = 'WakeWordService';
  static const int sampleRate = 16000;

  // 命中后冷却时间，避免同一句话重复触发
  static const Duration _cooldown = Duration(seconds: 2);

  static final WakeWordService _instance = WakeWordService._internal();
  factory WakeWordService() => _instance;
  WakeWordService._internal();

  bool _initialized = false;
  bool _enabled = false; // 用户是否在设置中开启（决定是否重新注册 Hub）
  bool _running = false;
  bool _suspended = false; // 对话进行中由外部标记为挂起

  String _name = '小智';

  /// 唤醒灵敏度阈值（越小越灵敏，2.0.18 起默认 0.15 以提升召回）
  static double sensitivity = 0.15;

  // 与原生前台服务通信，实现后台语音唤醒保活（息屏/退后台仍采集麦克风）与命中回前台。
  // 通道名必须与 MainActivity.kt / WakeForegroundService.kt 中声明的一致。
  static const MethodChannel _wakeChannel = MethodChannel(
    'com.lhht.ai_assistant/wake',
  );

  /// 启动原生前台保活服务（仅 Android 有效；非 Android 或通道不可用时静默忽略）。
  /// 真正的唤醒检测仍在 Dart 主 isolate 运行，本服务只负责「保活」：持锁 + 常驻通知，
  /// 让系统在后台/锁屏时不回收主 isolate，从而麦克风监听不中断。
  static Future<void> startNativeWakeService() async {
    try {
      await _wakeChannel.invokeMethod<void>('startWakeService');
    } catch (e) {
      print('$_TAG: 启动原生唤醒服务失败(可忽略): $e');
    }
  }

  /// 停止原生前台保活服务。
  static Future<void> stopNativeWakeService() async {
    try {
      await _wakeChannel.invokeMethod<void>('stopWakeService');
    } catch (e) {
      print('$_TAG: 停止原生唤醒服务失败(可忽略): $e');
    }
  }

  /// 命中唤醒词后把退到后台的 App 重新提到前台，让用户看到聆听界面。
  static Future<void> bringAppToFront() async {
    try {
      await _wakeChannel.invokeMethod<void>('bringToFront');
    } catch (e) {
      print('$_TAG: 回前台调用失败(可忽略): $e');
    }
  }

  final List<_WakeProfile> _profiles = [];

  int _lastWakeMs = 0;

  // ---- 诊断状态（设置页自检面板使用）----
  int _frameCount = 0; // 已处理的音频帧数，为 0 说明麦克风没数据
  double _lastRms = 0.0; // 最近一帧音量
  String _lastError = ''; // 最近一次错误信息
  int _wakeCount = 0; // 累计命中次数
  String _currentKeywords = ''; // 当前生效的关键词行

  /// 唤醒命中回调（UI 层在此启动一次聆听会话）
  Function()? onWake;

  /// 状态/日志回调（可选，便于调试）
  Function(String)? onStatus;

  /// 实时音量回调（设置页音量条使用）
  void Function(double rms)? onLevel;

  bool get isRunning => _running;
  bool get isInitialized => _initialized;
  bool get isSuspended => _suspended;
  int get profileCount => _profiles.length;
  int get frameCount => _frameCount;
  double get lastRms => _lastRms;
  String get lastError => _lastError;
  int get wakeCount => _wakeCount;
  String get currentKeywords => _currentKeywords;
  String get wakeName => _name;

  /// 初始化：加载模型并拷贝资源。重复调用安全（已初始化则直接返回）。
  /// [name] 为自定义唤醒名；为空则使用默认 '小智'。
  Future<void> init({String? name}) async {
    if (_initialized) return;
    if (name != null && name.trim().isNotEmpty) _name = name.trim();
    try {
      sherpa.initBindings();

      final dir = await getApplicationDocumentsDirectory();
      // 国语模型（内置）
      await _buildProfile(
        dir.path,
        id: 'mandarin',
        assetFolder: 'models',
        docFolder: 'kws_model',
      );

      if (_profiles.isEmpty) {
        onStatus?.call('未找到唤醒词模型，请检查 assets/models/');
        print('$_TAG: 未找到任何可用唤醒模型');
        return;
      }

      _initialized = true;
      onStatus?.call('唤醒词引擎初始化成功（${_profiles.length} 个模型）');
      print('$_TAG: 初始化成功，唤醒名="$_name"，模型数=${_profiles.length}');
    } catch (e, st) {
      _initialized = false;
      onStatus?.call('唤醒词初始化失败: $e');
      print('$_TAG: init 失败: $e\n$st');
    }
  }

  /// 拷贝 assets/<assetFolder>/* 到 <dir>/<docFolder>/（assetFolder 不存在则跳过）
  Future<void> _copyAssets(String assetFolder, String docFolder) async {
    final manifestStr = await rootBundle.loadString('AssetManifest.json');
    final manifest = json.decode(manifestStr) as Map<String, dynamic>;
    final prefix = 'assets/$assetFolder/';
    bool found = false;
    for (final key in manifest.keys) {
      if (key.startsWith(prefix)) {
        final data = await rootBundle.load(key);
        final name = key.substring(prefix.length);
        if (name.isEmpty) continue;
        final out = File('$docFolder/$name');
        await out.writeAsBytes(data.buffer.asUint8List());
        found = true;
      }
    }
    if (found) print('$_TAG: 已从 assets/$assetFolder 拷贝模型到 $docFolder');
  }

  /// 尝试用多种 modelType 构造 KeywordSpotter。
  ///
  /// ⚠️ 关键：wenetspeech 等 zipformer2 中文 KWS 模型**必须显式指定 modelType**，
  /// 否则 sherpa_onnx 的 createKeywordSpotter 返回 null → 抛异常 → 被上层 try/catch
  /// 吞掉 → 引擎永不初始化 → 唤醒「完全没用」。这也是此前多次修改都无效的真因。
  /// 这里按 ['zipformer2','zipformer',''（自动）] 顺序尝试，返回首个成功的实例；
  /// 全部失败返回 null，由调用方跳过该模型并记录日志，便于真机排查。
  static sherpa.KeywordSpotter? _createSpotter(
    String base,
    String kwFile,
    double threshold,
  ) {
    const candidates = ['zipformer2', 'zipformer', ''];
    for (final mt in candidates) {
      try {
        final config = sherpa.KeywordSpotterConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '$base/encoder.onnx',
              decoder: '$base/decoder.onnx',
              joiner: '$base/joiner.onnx',
            ),
            tokens: '$base/tokens.txt',
            numThreads: 2,
            provider: 'cpu',
            debug: false,
            modelType: mt,
          ),
          keywordsFile: kwFile,
          keywordsThreshold: threshold,
          numTrailingBlanks: 1,
          maxActivePaths: 4,
        );
        final spotter = sherpa.KeywordSpotter(config);
        print('$_TAG: KeywordSpotter 构造成功（modelType=\'$mt\'）');
        return spotter;
      } catch (e) {
        print('$_TAG: KeywordSpotter 构造失败（modelType=\'$mt\'）: $e');
      }
    }
    return null;
  }

  /// 构建一个唤醒引擎配置（若模型齐全则加入 [_profiles]）
  Future<void> _buildProfile(
    String baseDir, {
    required String id,
    required String assetFolder,
    required String docFolder,
  }) async {
    final modelDir = Directory('$baseDir/$docFolder');
    if (!await modelDir.exists()) {
      await modelDir.create(recursive: true);
    }

    // 尝试从 assets 拷贝（国语内置；粤语若无 assets 目录则跳过）
    await _copyAssets(assetFolder, modelDir.path);

    final base = modelDir.path;
    final required = [
      '$base/encoder.onnx',
      '$base/decoder.onnx',
      '$base/joiner.onnx',
      '$base/tokens.txt',
    ];
    final missing =
        required.where((p) => !File(p).existsSync()).toList();
    if (missing.isNotEmpty) {
      print('$_TAG: [$id] 模型不完整，跳过：${missing.join(', ')}');
      return;
    }

    // 依据自定义唤醒名生成对应关键词文件（含变体，提高短词命中率）
    final kwLines = _buildKeywordLines();
    if (kwLines.trim().isEmpty) {
      print('$_TAG: [$id] 唤醒名「$_name」无法转换为关键词，跳过该引擎');
      return;
    }
    final kwFile = File('$base/keywords.txt');
    await kwFile.writeAsString('$kwLines\n');
    _currentKeywords = kwLines;
    print('$_TAG: [$id] 关键词:\n$kwLines');

    final spotter = _createSpotter(base, '$base/keywords.txt', sensitivity);
    if (spotter == null) {
      print('$_TAG: [$id] 引擎构造失败，跳过该模型');
      return;
    }
    _profiles.add(
      _WakeProfile(
        id: id,
        docFolder: modelDir.path,
        spotter: spotter,
        stream: spotter.createStream(),
      ),
    );
    print('$_TAG: [$id] 引擎已加载');
  }

  /// 把用户填写的唤醒名拆成多个「基础唤醒词」。
  ///
  /// 用户可能在设置里填 `小智小智,你好小智` 或 `小智 你好小智` 这种多词，
  /// 旧代码把整串当成一个关键词交给拼音转换，逗号/空格直接进了 token 序列，
  /// 导致生成的行永远不在词表里 → 唤醒失效。现按中英文逗号、空格、换行拆分。
  List<String> _splitNames(String raw) {
    return raw
        .split(RegExp(r'[,，\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
  }

  /// 生成关键词文件内容：每个基础唤醒词 + 其常见变体，各自一行纯 token 序列。
  ///
  /// KWS 对 2 字短词的命中率明显偏低（官方建议 3 字以上），因此当某个基础词
  /// 较短时自动补充「你好X」「XX」两种说法，任一命中即可唤醒，提升可用性。
  String _buildKeywordLines() {
    final bases = _splitNames(_name);
    final expanded = <String>{};
    for (final base in bases) {
      expanded.add(base);
      if (base.runes.length <= 2) {
        expanded.add('你好$base');
        expanded.add('$base$base');
      }
    }

    final lines = <String>[];
    for (final v in expanded) {
      final line = WakeKeyword.mandarinLine(v);
      // 只保留「全部都是模型 token」的行；若拼音转换出空串或含非 token 字符，
      // 跳过该行（不写进 keywords.txt），避免污染其它有效关键词。
      if (line.trim().isNotEmpty && _isAllTokens(line) && !lines.contains(line)) {
        lines.add(line);
      } else if (line.trim().isNotEmpty) {
        print('$_TAG: 关键词「$v」->「$line」含非词表字符，已跳过');
      }
    }

    // 兜底：若所有词都因格式问题被跳过，至少保留原生「小智」关键词，
    // 避免 keywords.txt 为空导致「永远唤不醒」。
    if (lines.isEmpty) {
      print('$_TAG: 无有效关键词，回退到原生「小智」');
      final fb = WakeKeyword.mandarinLine('小智');
      if (fb.trim().isNotEmpty) lines.add(fb);
    }
    return lines.join('\n');
  }

  /// 粗略校验一行关键词是否仅由模型词表 token 组成（空格分隔、无 @ / 中文）。
  /// 仅用于过滤明显错误的行，不保证每个 token 一定存在（那需要解析 tokens.txt）。
  bool _isAllTokens(String line) {
    if (line.contains('@')) return false;
    if (RegExp(r'[一-龥]').hasMatch(line)) return false;
    for (final t in line.trim().split(RegExp(r'\s+'))) {
      if (t.isEmpty) return false;
    }
    return true;
  }

  /// 更换唤醒名：重新生成各模型关键词并重建引擎（模型文件不变，速度快）。
  Future<void> reloadKeywords(String name) async {
    if (name.trim().isNotEmpty) _name = name.trim();
    if (!_initialized) {
      await init();
      return;
    }
    try {
      for (final p in _profiles) {
        final kwLine = _buildKeywordLines();
        if (kwLine.trim().isEmpty) {
          print('$_TAG: [${p.id}] 唤醒名「$_name」无法转换，保持原关键词');
          continue;
        }
        await File('${p.docFolder}/keywords.txt').writeAsString('$kwLine\n');
        _currentKeywords = kwLine;
        final spotter = _createSpotter(
          p.docFolder,
          '${p.docFolder}/keywords.txt',
          sensitivity,
        );
        if (spotter == null) {
          print('$_TAG: [${p.id}] 重建引擎失败，保留原引擎');
          continue;
        }
        p.stream.free();
        p.spotter.free();
        p.spotter = spotter;
        p.stream = p.spotter.createStream();
      }
      onStatus?.call('唤醒名已更新为「$_name」');
      print('$_TAG: 唤醒名已更新为 "$_name"');
    } catch (e) {
      print('$_TAG: reloadKeywords 失败: $e');
    }
  }

  /// 开始持续监听唤醒词。
  ///
  /// [force] 为 true 时会清除挂起标记强制启动——用户在设置中主动开启唤醒时必须
  /// 使用，否则若此前调用过 [suspend]（例如把开关关掉过一次），`_suspended`
  /// 会一直为 true，导致 start 被静默忽略、唤醒永远起不来。
  Future<void> start({bool force = false}) async {
    if (force) _suspended = false;
    if (!_initialized) {
      _lastError = '引擎未初始化';
      return;
    }
    if (_running) return;
    if (_suspended) {
      print('$_TAG: 处于挂起状态，跳过启动');
      return;
    }

    _enabled = true;

    // 没有麦克风权限时无法监听，给出明确错误
    try {
      if (!await WakeAudioHub().hasPermission()) {
        _lastError = '未获得麦克风权限';
        onStatus?.call('唤醒失败：未获得麦克风权限');
        print('$_TAG: 无麦克风权限，无法启动唤醒监听');
        return;
      }
    } catch (e) {
      print('$_TAG: 权限检查异常: $e');
    }

    try {
      _running = true;
      _frameCount = 0;
      _lastError = '';
      // 通过共享 Hub 注册帧监听；Hub 自动开始唯一一条录音并扇出给本引擎，
      // 统一持有 recorder，避免重复开录音会话。
      WakeAudioHub().register(_onSamples);
      WakeAudioHub().resumeAll();
      onStatus?.call('唤醒监听已启动');
      print('$_TAG: 唤醒监听已启动（${_profiles.length} 个引擎）');
    } catch (e) {
      print('$_TAG: start 失败: $e');
      _lastError = '启动失败: $e';
      _running = false;
    }
  }

  /// 由 [WakeAudioHub] 扇出的音频帧（已是归一化 Float32）。
  void _onSamples(Float32List samples) {
    if (_profiles.isEmpty) return;

    // 诊断埋点：帧数与音量。frameCount 长期为 0 = 麦克风没拿到数据
    _frameCount++;
    double sumSq = 0;
    for (final s in samples) sumSq += s * s;
    _lastRms = samples.isNotEmpty ? sqrt(sumSq / samples.length) : 0.0;
    onLevel?.call(_lastRms);

    try {
      for (final p in _profiles) {
        p.stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
        // ⚠️ 关键修复（GitHub sherpa_onnx issue #1248 + 官方 KWS dart 示例）：
        // getResult() 必须放在 while(isReady) 循环「内部、每次 decode 之后」。
        // 旧代码在循环外只调用一次 getResult，维护者明确指出这种写法会
        // 「永远检测不到关键词」——这是 modelType 修复之后唤醒仍时灵时不灵、
        // 甚至完全不命中的第二大根因。每次 decode 后轮询结果，命中才重建流。
        while (p.spotter.isReady(p.stream)) {
          p.spotter.decode(p.stream);
          final result = p.spotter.getResult(p.stream);
          if (result.keyword.isNotEmpty) {
            // 命中：重建该引擎流，触发回调
            p.stream.free();
            p.stream = p.spotter.createStream();
            print('$_TAG: 命中关键词「${result.keyword}」');
            _handleWake();
            return; // 单次只触发一次
          }
        }
      }
    } catch (e) {
      print('$_TAG: 推理异常: $e');
      _lastError = '推理异常: $e';
    }
  }

  Future<void> _handleWake() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWakeMs < _cooldown.inMilliseconds) return;
    _lastWakeMs = now;
    _wakeCount++;

    // 必须等待麦克风完全释放后再回调，否则聊天页立刻开始录音会与本服务抢占
    // 麦克风，在 Android 上导致录音启动失败（表现为「唤醒了但没在听」）。
    // 这里用临时释放（保留启用状态），对话结束后由 resume() 恢复。
    await _releaseForChat();
    // 命中后若 App 已被切到后台，把它提到前台（用户才能看到聆听界面并开口）
    await bringAppToFront();
    onWake?.call();
  }

  /// 对话进行中临时释放麦克风（保留 _enabled，对话结束 resume 可恢复）。
  Future<void> _releaseForChat() async {
    WakeAudioHub().releaseAll();
    _running = false;
    _suspended = true;
  }

  /// 关闭唤醒监听（用户在设置中关闭时调用）：注销 Hub 帧监听并标记未启用。
  Future<void> suspend() async {
    WakeAudioHub().unregister(_onSamples);
    _running = false;
    _suspended = true;
    _enabled = false;
  }

  /// 对话结束后调用：恢复持续监听。
  /// 重新注册本引擎（若仍启用）并恢复全局录音。
  Future<void> resume() async {
    _suspended = false;
    if (_enabled) {
      WakeAudioHub().register(_onSamples);
      _running = true;
    }
    WakeAudioHub().resumeAll();
  }

  /// 应用新的灵敏度并重建引擎（0.10 最灵敏 ~ 0.45 最保守）
  Future<void> applySensitivity(double value) async {
    sensitivity = value.clamp(0.05, 0.6);
    print('$_TAG: 灵敏度更新为 $sensitivity');
    if (_initialized) {
      await reloadKeywords(_name);
    }
  }

  /// 供设置页自检使用：重启监听并清零统计
  Future<void> restartForDiagnostics() async {
    await suspend();
    _frameCount = 0;
    _lastRms = 0.0;
    _lastError = '';
    await start(force: true);
  }

  /// 完全停止并释放资源。
  Future<void> dispose() async {
    WakeAudioHub().unregister(_onSamples);
    _running = false;
    _enabled = false;
    for (final p in _profiles) {
      try {
        p.stream.free();
        p.spotter.free();
      } catch (_) {}
    }
    _profiles.clear();
    _initialized = false;
  }
}
