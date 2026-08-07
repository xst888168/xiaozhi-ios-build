import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_player/flutter_pcm_player.dart';
import 'package:ai_assistant/utils/vad_decision.dart';

/// 音频工具类，用于处理Opus音频编解码和录制播放
class AudioUtil {
  static const String TAG = "AudioUtil";
  static const int SAMPLE_RATE = 16000;
  static const int CHANNELS = 1;
  static const int FRAME_DURATION = 60; // 毫秒

  static final AudioRecorder _audioRecorder = AudioRecorder();
  static bool _isRecorderInitialized = false;
  static bool _isPlayerInitialized = false;
  static bool _isRecording = false;
  static bool _isPlaying = false;
  static final StreamController<Uint8List> _audioStreamController =
      StreamController<Uint8List>.broadcast();
  // VAD 静音自动断句相关（仅聊天页点击即说模式启用）
  static bool vadEnabled = false; // 是否启用静音自动断句

  /// 静音判定的最低 RMS 阈值（PCM16 有符号，理论范围 0~32768）。
  /// 实际阈值 = max(minSilenceRms, 噪声底 × noiseMultiplier)，以适应嘈杂环境。
  static double minSilenceRms = 350.0;

  /// 噪声底倍数：音量需超过「环境噪声 × 该倍数」才判定为正在说话
  static double noiseMultiplier = 2.2;

  /// 连续静音达到该时长则自动断句（毫秒），可在设置中调整（400~3000）。
  /// 默认 700ms：说完话停顿 0.7 秒即自动发送，减少"等半天才回"的延迟感；
  /// 设太短会在正常停顿（如思考措辞）时误断句（抢话），可在设置里调长。
  static int silenceTimeoutMs = 700;

  /// 最短录音时长，避免刚点开就误断句。
  /// 必须 <= MIN(silenceTimeoutMs 下限 1000ms)。
  static const int MIN_RECORD_BEFORE_AUTOSTOP_MS = 500;

  /// 噪声底校准窗口：录音开始后这段时间用于估计环境噪声
  static const int NOISE_CALIBRATION_MS = 400;

  static Timer? _silenceTimer;
  static int? _silenceStartMs;
  static int? _recordStartMs;
  static bool _autoStopping = false;
  static bool _hasSpoken = false; // 是否已检测到真实语音（用于避免初始静音误断句）
  static VoidCallback? onSilenceAutoStop; // 静音自动断句触发回调（UI 层用于发送）

  // 噪声底自适应状态
  static double _noiseFloor = 0.0;
  static int _noiseSampleCount = 0;
  static double _noiseSum = 0.0;
  static bool _noiseCalibrated = false;
  static double _lastRms = 0.0;

  /// 实时电平回调：(rms, 是否判定为静音)。UI 层可用于显示音量条 / 倒计时。
  static void Function(double rms, bool isSilent)? onLevel;

  /// 当前已持续静音的毫秒数（UI 可据此显示「还有 N 秒自动发送」）
  static int get silentForMs {
    if (_silenceStartMs == null) return 0;
    return DateTime.now().millisecondsSinceEpoch - _silenceStartMs!;
  }

  /// 最近一次计算出的 RMS 音量
  static double get currentRms => _lastRms;

  /// 当前生效的静音阈值（校准完成后为自适应值）
  static double get effectiveSilenceThreshold {
    if (!_noiseCalibrated) return minSilenceRms;
    final adaptive = _noiseFloor * noiseMultiplier;
    return adaptive > minSilenceRms ? adaptive : minSilenceRms;
  }

  /// 纯函数：判断当前是否应当触发「静音自动断句」。
  ///
  /// 关键修复（语音通话「说话毫无反应」根因之一）：必须「已经检测到真实语音」
  /// 才允许自动断句。否则用户刚进入通话、还没开口时的初始静音会被立刻断句，
  /// 把一段空音频发给服务器 → 服务器 ASR 无结果 → 看起来「毫无反应」。
  /// 改为：没说过话就持续聆听；说过话且停顿超过静音阈值才发送。
  ///
  /// 逻辑实现在 [vadShouldAutoStop]（独立纯文件，便于单元测试）。
  static bool shouldAutoStop({
    required bool hasSpoken,
    required int silenceMs, // 当前已连续静音时长
    required int silenceTimeoutMs,
    required int recordMs, // 已录音总时长
    required int minRecordMs,
  }) =>
      vadShouldAutoStop(
        hasSpoken: hasSpoken,
        silenceMs: silenceMs,
        silenceTimeoutMs: silenceTimeoutMs,
        recordMs: recordMs,
        minRecordMs: minRecordMs,
      );

  /// 从设置中加载 VAD 参数（静音时长、灵敏度）
  static void applyVadSettings({int? timeoutMs, double? minRms}) {
    if (timeoutMs != null && timeoutMs >= 400 && timeoutMs <= 3000) {
      silenceTimeoutMs = timeoutMs;
    }
    if (minRms != null && minRms > 0) {
      minSilenceRms = minRms;
    }
    print('$TAG: VAD 参数 -> 静音${silenceTimeoutMs}ms, 最低阈值$minSilenceRms');
  }

  // Opus相关
  static final _encoder = SimpleOpusEncoder(
    sampleRate: SAMPLE_RATE,
    channels: CHANNELS,
    application: Application.voip,
  );
  // 注意：解码器不能是 final —— 它是有状态的。上一句 TTS 的尾帧会残留在
  // 解码器内部上下文中，若直接复用到下一句开头，首帧会因 overlap-add 拿到
  // 错误上下文而失真，表现为「每句前一两字发闷/卡顿/不清晰」。因此每轮 TTS
  // 会话开始都要重建一次（见 [_recreateDecoder] / [resetTtsSession]）。
  static SimpleOpusDecoder _decoder = SimpleOpusDecoder(
    sampleRate: SAMPLE_RATE,
    channels: CHANNELS,
  );

  // FlutterPcmPlayer实例
  static FlutterPcmPlayer? _pcmPlayer;

  // TTS 预缓冲：PCM 播放器刚 play() 时 AudioTrack 需填充缓冲，开头的 ~150ms
  // 会被吞掉（表现为「小智说」已出现但前几个字没声音）。攒够 _prerollBytes
  // 再开始 feed，确保启动后不丢开头；极短语音在 stopPlaying 时 flush 余量。
  static Uint8List? _prerollBuffer;
  static bool _prerollPrimed = false;
  static final int _prerollBytes = (0.20 * SAMPLE_RATE * 2).ceil(); // 200ms @16k/16bit/mono，避免 TTS 开头吞字
  // 前导静音：预缓冲最前方补一段静音，让 AudioTrack 先跑稳再放真实语音，
  // 消除刚 play() 时的预热咔哒/起始失真（配合解码器重建，根治「前两个字卡/不清晰」）。
  static final int _primingSilenceBytes = (0.08 * SAMPLE_RATE * 2).ceil(); // 80ms @16k/16bit/mono

  /// 全双工（可打断）开关。默认开启：小智讲话时你可直接插话打断它（豆包式）。
  /// 打开后，小智讲话期间会用「自身播放音量估计回声」来判断你是否在插话，
  /// 检测到真实插话则发送 abort 打断小智（依赖真机调参，效果以实测为准）。
  static bool fullDuplexEnabled = true;

  /// 当前正在播放的 PCM 音量（RMS，PCM16 量纲），用于全双工时估计回声强度。
  static double _playbackLevel = 0.0;
  static double get playbackLevel => _playbackLevel;

  /// 计算一段 PCM16 的 RMS（PCM16 有符号，理论范围 0~32768）。
  static double _pcmRms(Int16List pcm) {
    if (pcm.isEmpty) return 0.0;
    double sum = 0.0;
    for (final s in pcm) {
      final d = s.toDouble();
      sum += d * d;
    }
    return sqrt(sum / pcm.length);
  }

  static void _updatePlaybackLevel(Int16List pcm) {
    // 指数平滑，反映「当前正在外放」的音量，供全双工回声估计使用。
    _playbackLevel = _playbackLevel * 0.7 + _pcmRms(pcm) * 0.3;
  }

  /// 获取音频流
  static Stream<Uint8List> get audioStream => _audioStreamController.stream;

  /// 初始化音频录制器
  static Future<void> initRecorder() async {
    if (_isRecorderInitialized) return;

    print('$TAG: 开始初始化录音器');

    // 更积极地请求所有可能需要的权限
    if (Platform.isAndroid) {
      print('$TAG: 请求Android所需的所有权限');
      Map<Permission, PermissionStatus> statuses =
          await [
            Permission.microphone,
            Permission.storage,
            Permission.manageExternalStorage,
            Permission.bluetooth,
            Permission.bluetoothConnect,
            Permission.bluetoothScan,
          ].request();

      print('$TAG: 权限状态:');
      statuses.forEach((permission, status) {
        print('$TAG: $permission: $status');
      });

      if (statuses[Permission.microphone] != PermissionStatus.granted) {
        print('$TAG: 麦克风权限被拒绝');
        throw Exception('需要麦克风权限');
      }
    } else {
      // iOS/其他平台只请求麦克风权限
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        print('$TAG: 麦克风权限被拒绝');
        throw Exception('需要麦克风权限');
      }
    }

    // 检查是否可用
    print('$TAG: 检查PCM16编码是否支持');
    final isAvailable = await _audioRecorder.isEncoderSupported(
      AudioEncoder.pcm16bits,
    );
    print('$TAG: PCM16编码支持状态: $isAvailable');

    // 设置音频模式 - 参考Android原生实现
    print('$TAG: 配置音频会话');
    final session = await AudioSession.instance;

    // 使用与原生Android实现更接近的配置
    if (Platform.isAndroid) {
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
            flags: AndroidAudioFlags.audibilityEnforced,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientExclusive,
          androidWillPauseWhenDucked: false,
        ),
      );
    } else {
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
        ),
      );
      await session.setActive(true);
    }

    _isRecorderInitialized = true;
    print('$TAG: 录音器初始化成功');
  }

  /// 通话模式标志：true 时播放保持 playAndRecord（听筒路由），false 时走扬声器。
  static bool _callMode = false;
  static set callMode(bool v) => _callMode = v;

  /// iOS 专用：把音频会话切到「播放」路由。
  /// - 聊天/播报(_callMode=false)：playback + defaultToSpeaker → 扬声器，确保听得到小智。
  /// - 通话(_callMode=true)：playAndRecord(听筒) 由录音器配好，这里仅激活。
  /// 必须在「每次开始播放 TTS」前调用：聊天里用户录音会把会话切成 playAndRecord(听筒)，
  /// 若不切回 playback，TTS 就会走听筒 → 表现为"小智回应了但没外放声音"。
  static Future<void> _configureIosSession() async {
    if (!Platform.isIOS) return;
    try {
      final session = await AudioSession.instance;
      if (_callMode) {
        await session.setActive(true);
      } else {
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker,
        ));
        await session.setActive(true);
      }
    } catch (e) {
      print('$TAG: iOS 音频会话配置失败(播放): $e');
    }
  }

  /// iOS 专用：把音频会话切回「录音」路由(playAndRecord + voiceChat)。
  /// 在 startRecording 时调用，确保上一轮 TTS 把会话切成 playback 后，
  /// 新一轮录音能正确回到录音模式（否则可能出现录不到音 / 一直准备）。
  static Future<void> _configureIosRecordSession() async {
    if (!Platform.isIOS) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
      ));
      await session.setActive(true);
    } catch (e) {
      print('$TAG: iOS 音频会话配置失败(录音): $e');
    }
  }

  /// 初始化音频播放器
  static Future<void> initPlayer() async {
    // 确保任何旧播放器被释放
    await stopPlaying();

    try {
      print('$TAG: 使用简单方式初始化PCM播放器');

      // iOS 必须显式配置并激活音频会话，否则 RawSoundPlayer(AVAudioEngine)
      // 没有正确的 category/输出路由，会完全无声或仅路由到听筒（"对话没声音"）。
      // 统一交给 [_configureIosSession]（按 _callMode 选 扬声器/听筒），
      // 该方法在每次开始播放 TTS 时也会再次调用，保证路由正确。
      if (Platform.isIOS) {
        await _configureIosSession();
      }

      // 创建新的播放器实例 - 完全按照官方示例的简单方式
      _pcmPlayer = FlutterPcmPlayer();
      await _pcmPlayer!.initialize();
      // 重建 Opus 解码器：播放器重启意味着新的一轮播放，旧解码器残留状态
      // 会让本句开头失真（见 [_decoder] 注释）。
      _recreateDecoder();
      await _pcmPlayer!.play();

      _isPlayerInitialized = true;
      _prerollBuffer = null;
      _prerollPrimed = false;
      print('$TAG: PCM播放器初始化成功');
    } catch (e) {
      print('$TAG: PCM播放器初始化失败: $e');
      _isPlayerInitialized = false;
    }
  }

  /// 播放Opus音频数据
  static Future<void> playOpusData(Uint8List opusData) async {
    try {
      // 如果播放器未初始化，先初始化
      if (!_isPlayerInitialized || _pcmPlayer == null) {
        await initPlayer();
      }
      if (_pcmPlayer == null) return;

      // 解码Opus数据
      final Int16List pcmData = _decoder.decode(input: opusData);

      // 准备PCM数据（按照示例直接方式）
      final Uint8List pcmBytes = Uint8List(pcmData.length * 2);
      ByteData bytes = ByteData.view(pcmBytes.buffer);

      // 使用小端字节序
      for (int i = 0; i < pcmData.length; i++) {
        bytes.setInt16(i * 2, pcmData[i], Endian.little);
      }

      // 已启动播放：直接喂入（不 buffering，避免引入延迟）
      if (_prerollPrimed) {
        await _pcmPlayer!.feed(pcmBytes);
        _updatePlaybackLevel(pcmData);
        return;
      }

      // 每轮 TTS 首个 chunk：确保 iOS 会话已切到正确播放路由
      // （聊天里上一轮录音把会话切成了 playAndRecord 听筒，不切回则没外放）。
      if (Platform.isIOS) {
        await _configureIosSession();
      }

      // 未启动：先攒预缓冲，攒够 _prerollBytes 再一次性喂入，避免开头被吞。
      // 新会话的首帧会在前方补一段前导静音（_primingSilenceBytes），
      // 让 AudioTrack 先跑稳再放真实语音，消除刚 play() 时的起始咔哒/失真。
      final Uint8List base;
      if (_prerollBuffer == null) {
        base = Uint8List(_primingSilenceBytes); // 全 0 = 静音，用于预热音频输出
      } else {
        base = _prerollBuffer!;
      }
      final merged = Uint8List(base.length + pcmBytes.length);
      merged.setRange(0, base.length, base);
      merged.setRange(base.length, merged.length, pcmBytes);
      _prerollBuffer = merged;
      if (_prerollBuffer!.length < _prerollBytes) return; // 还没攒够，等下一帧
      await _pcmPlayer!.feed(_prerollBuffer!);
      _updatePlaybackLevel(pcmData);
      _prerollBuffer = null;
      _prerollPrimed = true;
    } catch (e) {
      print('$TAG: 播放失败: $e');

      // 简单重置并重新初始化
      await stopPlaying();
      await initPlayer();
    }
  }

  /// 重建 Opus 解码器并释放旧资源。
  /// 解码器是有状态的：上一句 TTS 的尾帧残留在内部上下文中，若直接复用到下一句
  /// 开头，首帧会因 overlap-add 拿到错误上下文而失真 —— 表现为「每句前一两字
  /// 发闷/卡顿/不清晰」。每次新 TTS 会话（或播放器重建）时调用一次即可根治。
  static void _recreateDecoder() {
    try {
      _decoder.destroy();
    } catch (_) {
      // 旧版本或异常情况下 destroy 可能不可用，忽略即可（仅多一次泄漏，影响极小）
    }
    _decoder = SimpleOpusDecoder(
      sampleRate: SAMPLE_RATE,
      channels: CHANNELS,
    );
  }

  /// 新一轮 TTS 会话开始：重建解码器并重置预缓冲状态，
  /// 确保本句开头不再被上一句的残留状态污染（根治「前两个字不清晰/卡」）。
  /// 由 [XiaozhiService] 在收到服务端 `tts state=start` 时调用；
  /// 即使上一轮播放器仍在播尾音也不影响 —— 新会话会重新攒预缓冲后顺序接入。
  static void resetTtsSession() {
    _recreateDecoder();
    _prerollBuffer = null;
    _prerollPrimed = false;
    // 新一轮 TTS：立即把 iOS 会话切到正确播放路由（见 [_configureIosSession]）。
    // 关键：用户刚录完音，会话处于 playAndRecord(听筒)；不等到首个音频 chunk
    // 才切，而是 tts start 时就切，保证整句都走扬声器(聊天)/听筒(通话)。
    if (Platform.isIOS) {
      _configureIosSession();
    }
  }

  /// 停止播放
  static Future<void> stopPlaying() async {
    // 极短 TTS：预缓冲未达阈值时先把剩余喂入，避免整段丢失（可能略裁尾，可接受）。
    if (_prerollBuffer != null && _prerollBuffer!.isNotEmpty) {
      try {
        await _pcmPlayer?.feed(_prerollBuffer!);
      } catch (_) {}
      _prerollBuffer = null;
    }
    if (_pcmPlayer != null) {
      try {
        await _pcmPlayer!.stop();
        print('$TAG: 播放器已停止');
      } catch (e) {
        print('$TAG: 停止播放失败: $e');
      }
      _pcmPlayer = null;
      _isPlayerInitialized = false;
    }
    _prerollPrimed = false;
    _playbackLevel = 0.0;
  }

  /// 释放资源
  static Future<void> dispose() async {
    _silenceTimer?.cancel();
    await stopPlaying();
    _isRecording = false;
    _isPlaying = false;
    _isRecorderInitialized = false;
    _isPlayerInitialized = false;
    await _audioStreamController.close();
    print('$TAG: 资源已释放');
  }

  /// 开始录音
  static Future<void> startRecording() async {
    if (!_isRecorderInitialized) {
      await initRecorder();
    }

    // iOS：确保会话处于录音路由(playAndRecord)。上一轮 TTS 可能已把会话切到
    // playback，不切回会导致本次录音无声 / 听写失败。
    if (Platform.isIOS) {
      await _configureIosRecordSession();
    }

    if (_isRecording) {
      // 已在录音（如「打断监听」已在采集麦克风）：重新依据当前
      // vadEnabled / onSilenceAutoStop 配置装备静音断句定时器。
      // 否则说话后静音永远不会触发自动发送 → 卡在「正在说」。
      _rearmSilenceTimer();
      return;
    }

    try {
      print('$TAG: 尝试启动录音');

      // 确保麦克风权限已获取 - 使用不同方式检查权限
      final status = await Permission.microphone.status;
      print('$TAG: 麦克风权限状态: $status');

      if (status != PermissionStatus.granted) {
        final result = await Permission.microphone.request();
        print('$TAG: 请求麦克风权限结果: $result');
        if (result != PermissionStatus.granted) {
          print('$TAG: 麦克风权限被拒绝');
          return;
        }
      }

      // 尝试直接使用音频流
      try {
        print('$TAG: 尝试启动流式录音');
        final stream = await _audioRecorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: SAMPLE_RATE,
            numChannels: CHANNELS,
          ),
        );

        _isRecording = true;
        print('$TAG: 流式录音启动成功');

        // 初始化 VAD 静音断句状态
        _autoStopping = false;
        _hasSpoken = false; // 新一轮录音：尚未检测到真实语音
        _pcmBuffer.clear(); // 清空 Opus 缓冲，避免混入上一轮残留样本
        _recordStartMs = DateTime.now().millisecondsSinceEpoch;
        _silenceStartMs = null; // 校准完成后再开始计时
        _noiseFloor = 0.0;
        _noiseSum = 0.0;
        _noiseSampleCount = 0;
        _noiseCalibrated = false;
        _lastRms = 0.0;

        // 全新启动时，依据当前配置装备静音断句定时器（逻辑见 _rearmSilenceTimer）。
        _rearmSilenceTimer();

        // 直接从流中处理数据
        stream.listen(
          (data) async {
            if (data.isNotEmpty && data.length % 2 == 0) {
              _updateVad(data);
              final opusData = await encodeToOpus(data);
              if (opusData != null) {
                _audioStreamController.add(opusData);
              }
            }
          },
          onError: (error) {
            print('$TAG: 音频流错误: $error');
            _isRecording = false;
          },
          onDone: () {
            print('$TAG: 音频流结束');
            _isRecording = false;
          },
        );
      } catch (e) {
        print('$TAG: 流式录音失败: $e');
        _isRecording = false;
        rethrow;
      }
    } catch (e, stackTrace) {
      print('$TAG: 启动录音失败: $e');
      print(stackTrace);
      _isRecording = false;
    }
  }

  /// (重新)装备静音自动断句定时器。
  ///
  /// 依据当前 [vadEnabled] / [onSilenceAutoStop] / [silenceTimeoutMs] 等静态配置
  /// 启动静音检测定时器。语音通话中麦克风通常只启动一次（「打断监听」时就已开始），
  /// 随后切换到真实聆听时不会再走「全新 startRecording」分支，若此处不重新装备，
  /// [onSilenceAutoStop] 永远不会被触发 → 用户说完话、静音满 1 秒也不会发送、
  /// UI 卡在「正在说」。这就是本 bug 的根因。
  static void _rearmSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    if (!(_isRecording && vadEnabled && onSilenceAutoStop != null)) return;
    _silenceStartMs = null; // 新一轮聆听：静音计时从头开始
    _autoStopping = false;
    _hasSpoken = false; // 重置：必须检测到本轮真实语音才允许断句发送
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_isRecording || _autoStopping || _silenceTimer == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_recordStartMs == null) return;
      final recordMs = now - _recordStartMs!;
      if (recordMs < MIN_RECORD_BEFORE_AUTOSTOP_MS) return;
      final silenceMs = _silenceStartMs == null ? 0 : (now - _silenceStartMs!);
      // 只在「已检测到真实语音」后，且连续静音达到阈值才断句发送，
      // 避免初始静音把空音频发给服务器（语音通话「毫无反应」根因）。
      if (shouldAutoStop(
        hasSpoken: _hasSpoken,
        silenceMs: silenceMs,
        silenceTimeoutMs: silenceTimeoutMs,
        recordMs: recordMs,
        minRecordMs: MIN_RECORD_BEFORE_AUTOSTOP_MS,
      )) {
        _autoStopping = true;
        print('$TAG: 检测到语音后静音 ${silenceTimeoutMs}ms，自动断句发送');
        onSilenceAutoStop?.call();
      }
    });
    print('$TAG: VAD 已启用，静音 ${silenceTimeoutMs}ms 自动发送');
  }

  /// 停止录音
  static Future<String?> stopRecording() async {
    if (!_isRecorderInitialized || !_isRecording) return null;

    // 取消定时器（含 VAD 静音检测）并重置自适应状态
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _silenceStartMs = null;
    _recordStartMs = null;
    _autoStopping = false;
    _hasSpoken = false;
    _pcmBuffer.clear(); // 清空 Opus 缓冲
    _noiseCalibrated = false;
    _noiseFloor = 0.0;
    _noiseSum = 0.0;
    _noiseSampleCount = 0;
    _lastRms = 0.0;

    // 停止录音
    try {
      final path = await _audioRecorder.stop();
      _isRecording = false;
      print('$TAG: 停止录音: $path');
      return path;
    } catch (e) {
      print('$TAG: 停止录音失败: $e');
      _isRecording = false;
      return null;
    }
  }

  /// 根据 PCM16 数据更新 VAD 静音计时（连续静音由 _silenceTimer 判定断句）
  ///
  /// 注意：PCM16 必须按**有符号小端**解析。此前误用无符号解析，导致所有负样本
  /// 被读成 65535 附近的巨值，RMS 恒高于阈值 → 永远判定为「有人在说话」→
  /// 静音自动断句从不触发。这是「静音 2 秒不停止」的根因。
  static void _updateVad(Uint8List pcm) {
    if (!vadEnabled) return;
    final int n = pcm.length ~/ 2;
    if (n == 0) return;

    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      // 小端读取后转换为有符号 int16（-32768 ~ 32767）
      int s = pcm[i * 2] | (pcm[i * 2 + 1] << 8);
      if (s >= 32768) s -= 65536;
      sumSq += s.toDouble() * s.toDouble();
    }
    final double rms = sqrt(sumSq / n);
    _lastRms = rms;

    final int now = DateTime.now().millisecondsSinceEpoch;
    final int elapsed = _recordStartMs == null ? 0 : now - _recordStartMs!;

    // 前 NOISE_CALIBRATION_MS 用于估计环境噪声底，期间不做静音判定
    if (!_noiseCalibrated) {
      _noiseSum += rms;
      _noiseSampleCount++;
      if (elapsed >= NOISE_CALIBRATION_MS && _noiseSampleCount > 0) {
        _noiseFloor = _noiseSum / _noiseSampleCount;
        _noiseCalibrated = true;
        print(
          '$TAG: 噪声底校准完成 floor=${_noiseFloor.toStringAsFixed(1)} '
          '阈值=${effectiveSilenceThreshold.toStringAsFixed(1)}',
        );
      }
      onLevel?.call(rms, false);
      return;
    }

    final double threshold = effectiveSilenceThreshold;
    final bool isSilent = rms <= threshold;

    if (!isSilent) {
      _silenceStartMs = null; // 有声音，重置静音计时
      _hasSpoken = true; // 检测到真实语音：后续静音才允许断句
    } else if (_silenceStartMs == null) {
      _silenceStartMs = now; // 进入静音区间，开始计时
    }

    onLevel?.call(rms, isSilent);
  }

  /// PCM 缓冲：跨 chunk 累积，确保只编码完整 60ms 帧，避免丢帧
  static final List<int> _pcmBuffer = [];

  /// 将PCM数据编码为Opus格式
  ///
  /// 关键修复（v2.0.5）：旧实现每次只编码 chunk 的**前 60ms 帧**、丢弃其余样本
  /// （或不足一帧时用静音填充），导致约 80%+ 的语音被丢掉，服务器收到残缺音频 →
  /// ASR 识别错误/串意（「识别能力不高，识别错误意思」的根因）。
  /// 现改为跨 chunk 缓冲：先把本 chunk 的 16bit 样本追加到缓冲，攒够完整 60ms 帧
  /// 再逐帧编码，剩余不足一帧的部分留到下一个 chunk，绝不丢弃。
  static Uint8List? encodeToOpus(Uint8List pcmData) {
    try {
      final int n = pcmData.length ~/ 2;
      if (n == 0) return null;

      // 小端读取 16bit 样本，写入 Int16List 时按位解释为有符号（自动还原符号）
      for (int i = 0; i < n; i++) {
        final int s = pcmData[i * 2] | (pcmData[i * 2 + 1] << 8);
        _pcmBuffer.add(s);
      }

      final int samplesPerFrame = (SAMPLE_RATE * FRAME_DURATION) ~/ 1000; // 960
      if (_pcmBuffer.length < samplesPerFrame) {
        return null; // 不足一帧，等下一个 chunk
      }

      final int frameCount = _pcmBuffer.length ~/ samplesPerFrame;
      final int consume = frameCount * samplesPerFrame;

      final Int16List frame = Int16List(consume);
      for (int i = 0; i < consume; i++) {
        frame[i] = _pcmBuffer[i];
      }
      _pcmBuffer.removeRange(0, consume);

      // 逐帧编码（SimpleOpusEncoder 配置为 60ms 帧）
      final List<int> out = [];
      for (int f = 0; f < frameCount; f++) {
        final chunk = frame.sublist(f * samplesPerFrame, (f + 1) * samplesPerFrame);
        out.addAll(_encoder.encode(input: chunk));
      }
      return Uint8List.fromList(out);
    } catch (e, stackTrace) {
      print('$TAG: Opus编码失败: $e');
      print(stackTrace);
      return null;
    }
  }

  /// 检查是否正在录音
  static bool get isRecording => _isRecording;

  /// 检查是否正在播放
  static bool get isPlaying => _isPlaying;
}
