import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:ai_assistant/utils/wake_keyword.dart';

/// 单个唤醒引擎配置（一个声学模型 + 一个关键词文件）
class _WakeProfile {
  final String id;
  final String docFolder;
  final bool useCantonese;
  sherpa.KeywordSpotter spotter;
  sherpa.OnlineStream stream;

  _WakeProfile({
    required this.id,
    required this.docFolder,
    required this.useCantonese,
    required this.spotter,
    required this.stream,
  });
}

/// 离线唤醒词服务（基于 sherpa_onnx KeywordSpotter）
///
/// 设计要点：
/// 1. 模型以 assets 形式打包（国语模型在 assets/models/，首次运行拷贝到
///    应用私有目录 documents/kws_model；粤语模型可选，放在 assets/models_cantonese/
///    或用户手动放入 documents/kws_model_cantonese）。
/// 2. 唤醒名（自定义）在运行时由 [WakeKeyword] 转换为对应模型的关键词行：
///    - 国语：Hanyu 拼音（ppinyin）
///    - 粤语：Jyutping
///    任一模型命中即触发 [onWake]。
/// 3. 命中后自动 [suspend] 自身麦克风监听，避免小智回复语音造成回声误触发；
///    对话结束后由调用方（聊天页）调用 [resume] 恢复监听。
/// 4. 模型缺失或初始化失败均优雅降级（不抛异常、不阻塞 UI）。
class WakeWordService {
  static const String _TAG = 'WakeWordService';
  static const int sampleRate = 16000;

  // 命中后冷却时间，避免同一句话重复触发
  static const Duration _cooldown = Duration(seconds: 2);

  static final WakeWordService _instance = WakeWordService._internal();
  factory WakeWordService() => _instance;
  WakeWordService._internal();

  bool _initialized = false;
  bool _running = false;
  bool _suspended = false; // 对话进行中由外部标记为挂起

  String _name = '小智';

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recSub;
  final List<_WakeProfile> _profiles = [];

  int _lastWakeMs = 0;

  /// 唤醒命中回调（UI 层在此启动一次聆听会话）
  Function()? onWake;

  /// 状态/日志回调（可选，便于调试）
  Function(String)? onStatus;

  bool get isRunning => _running;
  bool get isInitialized => _initialized;

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
        useCantonese: false,
      );
      // 粤语模型（可选）
      await _buildProfile(
        dir.path,
        id: 'cantonese',
        assetFolder: 'models_cantonese',
        docFolder: 'kws_model_cantonese',
        useCantonese: true,
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

  /// 构建一个唤醒引擎配置（若模型齐全则加入 [_profiles]）
  Future<void> _buildProfile(
    String baseDir, {
    required String id,
    required String assetFolder,
    required String docFolder,
    required bool useCantonese,
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
      // 粤语模型缺失属正常（官方暂无），仅打印日志
      print('$_TAG: [$id] 模型不完整，跳过：${missing.join(', ')}');
      return;
    }

    // 依据自定义唤醒名生成对应关键词文件
    final kwLine = useCantonese
        ? WakeKeyword.cantoneseLine(_name)
        : WakeKeyword.mandarinLine(_name);
    if (kwLine.trim().isEmpty) {
      print('$_TAG: [$id] 唤醒名「$_name」无法转换为关键词，跳过该引擎');
      return;
    }
    final kwFile = File('$base/keywords.txt');
    await kwFile.writeAsString('$kwLine\n');
    print('$_TAG: [$id] 关键词: $kwLine');

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
      ),
      keywordsFile: '$base/keywords.txt',
      keywordsThreshold: useCantonese ? 0.35 : 0.25,
      numTrailingBlanks: 1,
      maxActivePaths: 4,
    );

    final spotter = sherpa.KeywordSpotter(config);
    _profiles.add(
      _WakeProfile(
        id: id,
        docFolder: modelDir.path,
        useCantonese: useCantonese,
        spotter: spotter,
        stream: spotter.createStream(),
      ),
    );
    print('$_TAG: [$id] 引擎已加载');
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
        final kwLine = p.useCantonese
            ? WakeKeyword.cantoneseLine(_name)
            : WakeKeyword.mandarinLine(_name);
        if (kwLine.trim().isEmpty) {
          print('$_TAG: [${p.id}] 唤醒名「$_name」无法转换，保持原关键词');
          continue;
        }
        p.stream.free();
        await File('${p.docFolder}/keywords.txt').writeAsString('$kwLine\n');
        p.spotter.free();
        final config = sherpa.KeywordSpotterConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '${p.docFolder}/encoder.onnx',
              decoder: '${p.docFolder}/decoder.onnx',
              joiner: '${p.docFolder}/joiner.onnx',
            ),
            tokens: '${p.docFolder}/tokens.txt',
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          keywordsFile: '${p.docFolder}/keywords.txt',
          keywordsThreshold: p.useCantonese ? 0.35 : 0.25,
          numTrailingBlanks: 1,
          maxActivePaths: 4,
        );
        p.spotter = sherpa.KeywordSpotter(config);
        p.stream = p.spotter.createStream();
      }
      onStatus?.call('唤醒名已更新为「$_name」');
      print('$_TAG: 唤醒名已更新为 "$_name"');
    } catch (e) {
      print('$_TAG: reloadKeywords 失败: $e');
    }
  }

  /// 开始持续监听唤醒词。已运行或挂起时直接返回。
  Future<void> start() async {
    if (!_initialized || _running || _suspended) return;
    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
        ),
      );
      _running = true;
      _recSub = stream.listen(
        _onAudioChunk,
        onError: (e) {
          print('$_TAG: 音频流错误: $e');
          _running = false;
        },
        onDone: () {
          print('$_TAG: 音频流结束');
          _running = false;
        },
      );
      print('$_TAG: 唤醒监听已启动（${_profiles.length} 个引擎）');
    } catch (e) {
      print('$_TAG: start 失败: $e');
      _running = false;
    }
  }

  void _onAudioChunk(Uint8List data) {
    if (_profiles.isEmpty) return;
    if (data.isEmpty || data.length % 2 != 0) return;

    // record 输出 PCM16 字节流 -> 转为 Float32 并归一化到 [-1,1]
    // （sherpa_onnx 的 acceptWaveform 要求 Float32List）
    final n = data.length ~/ 2;
    final samples = Float32List(n);
    for (int i = 0; i < n; i++) {
      // 小端序无符号 -> 有符号 int16 -> 归一化
      int s = data[i * 2] | (data[i * 2 + 1] << 8);
      if (s >= 32768) s -= 65536;
      samples[i] = s / 32768.0;
    }

    try {
      for (final p in _profiles) {
        p.stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
        while (p.spotter.isReady(p.stream)) {
          p.spotter.decode(p.stream);
        }
        final result = p.spotter.getResult(p.stream);
        if (result.keyword.isNotEmpty) {
          // 命中：重建该引擎流，触发回调
          p.stream.free();
          p.stream = p.spotter.createStream();
          _handleWake();
          return; // 单次只触发一次
        }
      }
    } catch (e) {
      print('$_TAG: 推理异常: $e');
    }
  }

  void _handleWake() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWakeMs < _cooldown.inMilliseconds) return;
    _lastWakeMs = now;

    // 暂停自身监听，避免小智回复回声误触发；对话结束后由调用方 resume
    suspend();
    onWake?.call();
  }

  /// 对话进行中调用：停止麦克风监听（释放给小智录音用）。
  Future<void> suspend() async {
    if (!_running) {
      _suspended = true;
      return;
    }
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _running = false;
    _suspended = true;
  }

  /// 对话结束后调用：恢复持续监听。
  Future<void> resume() async {
    _suspended = false;
    await start();
  }

  /// 完全停止并释放资源。
  Future<void> dispose() async {
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _running = false;
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
