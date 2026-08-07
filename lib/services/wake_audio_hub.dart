import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:record/record.dart';

/// 单帧音频回调：把归一化到 [-1,1] 的 Float32 采样喂给订阅者。
typedef WakeFrameCallback = void Function(Float32List samples);

/// 实时音量(RMS)回调，供设置页音量条使用。
typedef WakeLevelCallback = void Function(double rms);

/// 共享录音中枢。
///
/// 原生的 [AudioRecorder] 在同一时刻只能有一个活跃录音会话（Android 上两个
/// 同时 start 会互相抢麦克风、后者把前者顶掉）。而本 App 同时可能运行两套离线
/// 唤醒引擎：普通话 KeywordSpotter + 粤语 SenseVoice ASR。若各自起一个 recorder
/// 必然冲突。
///
/// 因此这里用单例持有一个 recorder，把 PCM16 字节流统一转成 Float32 后扇出给
/// 所有已注册的引擎。引擎只负责"听帧"，不碰麦克风。
///
/// 另外提供全局的 [releaseAll]/[resumeAll]：对话进行中调用 [releaseAll] 暂停整条
/// 录音（让出麦克风给小智对话用），对话结束 [resumeAll] 恢复——无论当前有几套
/// 引擎在监听，都一并暂停/恢复，避免一方唤醒后另一方仍占麦克风。
class WakeAudioHub {
  static const int sampleRate = 16000;

  static final WakeAudioHub _instance = WakeAudioHub._internal();
  factory WakeAudioHub() => _instance;
  WakeAudioHub._internal();

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  /// 正在监听的引擎（= 用户开启的引擎集合，成员关系不因临时释放而改变）。
  final Set<WakeFrameCallback> _listeners = {};

  /// 音量订阅者（诊断用，不影响成员关系）。
  final Set<WakeLevelCallback> _levelListeners = {};

  /// 录音是否真正在跑（受"是否有人监听"与"是否被全局释放"共同控制）。
  bool _recording = false;

  /// 对话进行中临时释放麦克风时为 true；此时即使有监听者也不录音。
  bool _globallyReleased = false;

  bool get isRecording => _recording;
  bool get isGloballyReleased => _globallyReleased;

  /// 检查麦克风权限（供引擎启动时判断）。
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (e) {
      print('WakeAudioHub: 权限检查异常: $e');
      return false;
    }
  }

  /// 注册一个引擎监听者；首个监听者到来时自动开始录音。
  void register(WakeFrameCallback cb) {
    final wasEmpty = _listeners.isEmpty;
    _listeners.add(cb);
    if (wasEmpty) _maybeStart();
  }

  /// 注销一个引擎监听者；最后一个离开时停止录音。
  void unregister(WakeFrameCallback cb) {
    _listeners.remove(cb);
    if (_listeners.isEmpty) _stopRecorder();
  }

  /// 对话开始：暂停整条录音（让出麦克风）。
  void releaseAll() {
    _globallyReleased = true;
    _stopRecorder();
  }

  /// 对话结束：恢复录音（前提是仍有监听者）。
  void resumeAll() {
    _globallyReleased = false;
    _maybeStart();
  }

  void addLevelListener(WakeLevelCallback cb) => _levelListeners.add(cb);
  void removeLevelListener(WakeLevelCallback cb) => _levelListeners.remove(cb);

  void _maybeStart() {
    if (_recording || _globallyReleased || _listeners.isEmpty) return;
    _startRecorder();
  }

  Future<void> _startRecorder() async {
    if (_recording) return;
    try {
      if (!(await hasPermission())) {
        print('WakeAudioHub: 无麦克风权限，无法启动共享录音');
        return;
      }
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
        ),
      );
      _recording = true;
      _sub = stream.listen(
        _onChunk,
        onError: (e) {
          print('WakeAudioHub: 音频流错误: $e');
          _recording = false;
        },
        onDone: () {
          print('WakeAudioHub: 音频流结束');
          _recording = false;
        },
      );
      print('WakeAudioHub: 共享录音已启动（${_listeners.length} 个监听者）');
    } catch (e) {
      print('WakeAudioHub: 启动失败: $e');
      _recording = false;
    }
  }

  void _onChunk(Uint8List data) {
    if (data.isEmpty || data.length % 2 != 0) return;

    // record 输出 PCM16 字节流 -> 转 Float32 并归一化到 [-1,1]
    final n = data.length ~/ 2;
    final samples = Float32List(n);
    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      int s = data[i * 2] | (data[i * 2 + 1] << 8);
      if (s >= 32768) s -= 65536;
      final v = s / 32768.0;
      samples[i] = v;
      sumSq += v * v;
    }

    final rms = n > 0 ? sqrt(sumSq / n) : 0.0;
    for (final l in _levelListeners) {
      l(rms);
    }
    // 扇出给所有引擎（拷贝一份，避免某引擎持有引用后改动）
    for (final l in _listeners) {
      l(Float32List.fromList(samples));
    }
  }

  Future<void> _stopRecorder() async {
    if (!_recording) return;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    _recording = false;
  }

  /// 完全释放（App 退出时）。
  Future<void> dispose() async {
    _listeners.clear();
    _levelListeners.clear();
    _globallyReleased = false;
    await _stopRecorder();
  }
}
