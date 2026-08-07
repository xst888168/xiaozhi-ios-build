import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/message.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/services/xiaozhi_service.dart';
import 'package:ai_assistant/services/wake_word_service.dart';
import 'package:ai_assistant/services/call_keep_alive.dart';
import 'package:ai_assistant/services/object_detection_service.dart';
import 'package:ai_assistant/utils/audio_util.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

class VoiceCallScreen extends StatefulWidget {
  final Conversation conversation;
  final XiaozhiConfig xiaozhiConfig;

  const VoiceCallScreen({
    super.key,
    required this.conversation,
    required this.xiaozhiConfig,
  });

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen>
    with SingleTickerProviderStateMixin {
  late XiaozhiService _xiaozhiService;
  bool _isConnected = false;
  bool _isSpeaking = false;
  bool _isAssistantSpeaking = false;
  bool _isWaitingResponse = false;
  String _statusText = '正在连接...';
  Timer? _callTimer;
  Duration _callDuration = Duration.zero;
  bool _serverReady = false;
  Timer? _thinkingTimeout; // 思考超时保护：超过 12s 无响应自动重听
  bool _isStartingSpeaking = false; // 防止 _startSpeaking 并发调用
  Timer? _relistenDelayTimer; // 小智说完后自动重听的延迟定时器
  bool _isVideoMode = false; // 视频通话模式（本地相机预览 + 端侧物体识别）
  bool _wakeWasRunning = false; // 进入通话前唤醒服务是否在运行（退出时恢复）

  // 全双工（可打断）相关：小智讲话期间检测用户插话并打断它。
  Timer? _bargeInTimer; // 插话检测轮询定时器（每 60ms）
  int _bargeInAboveMs = 0; // 去回声后的用户语音持续高于阈值的累计时长
  static const double _bargeInEchoCoupling = 1.2; // 回声耦合系数（真机调参）
  static const double _bargeInUserThreshold = 900.0; // 去回声后用户语音 RMS 阈值（越低越易打断）
  static const int _bargeInSustainMs = 180; // 持续该时长才判定插话，防误触

  // 视频模式相关
  CameraController? _cameraController;
  bool _cameraInitializing = false;
  bool _cameraError = false;
  String _cameraErrorMsg = '';
  List<DetectedObject> _detectedObjects = []; // 当前识别到的物体（标签+置信度+包围框）

  late AnimationController _animationController;
  final List<double> _audioLevels = List.filled(30, 0.05);
  Timer? _audioVisualizerTimer;

  @override
  void initState() {
    super.initState();

    // 设置状态栏为透明并使图标为白色
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    // 在帧绘制后再次设置系统UI样式，避免被覆盖
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );
    });

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    // 获取XiaozhiService实例
    _xiaozhiService = XiaozhiService(
      websocketUrl: widget.xiaozhiConfig.websocketUrl,
      macAddress: widget.xiaozhiConfig.macAddress,
      token: widget.xiaozhiConfig.token,
      sessionId: widget.conversation.id,
    );

    // 设置消息监听器
    _xiaozhiService.setMessageListener(_handleServerMessage);

    // 监听服务事件：用于连续对话状态流转
    _xiaozhiService.addListener(_handleServiceEvent);

    // 连接并切换到语音通话模式
    _connectToVoiceService();
    _startAudioVisualizer();
  }

  void _handleServerMessage(dynamic message) {
    // 处理服务器发来的消息
    if (message is Map<String, dynamic> && message['type'] == 'hello') {
      print('收到服务器hello消息: $message');
      setState(() {
        _serverReady = true;
      });

      // 服务器准备好且尚未录音时，由 UI 主动开始第一轮聆听。
      if (!_isSpeaking) {
        _startSpeaking();
      }
    }
  }

  /// 处理 XiaozhiService 事件，驱动语音通话连续对话状态流转
  Future<void> _handleServiceEvent(XiaozhiServiceEvent event) async {
    if (!mounted) return;

    switch (event.type) {
      case XiaozhiServiceEventType.connected:
        _thinkingTimeout?.cancel();
        _thinkingTimeout = null;
        setState(() {
          _isConnected = true;
          _statusText = '已连接';
        });
        // 断线重连后自动恢复连续对话：只有完全空闲时才自动开始聆听，
        // 避免重连时正好小智在说话或用户在等回复导致状态错乱。
        if (!_isSpeaking &&
            !_isWaitingResponse &&
            !_isAssistantSpeaking &&
            !_isStartingSpeaking) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted &&
                _isConnected &&
                !_isSpeaking &&
                !_isAssistantSpeaking &&
                !_isWaitingResponse) {
              _startSpeaking();
            }
          });
        }
        break;

      case XiaozhiServiceEventType.disconnected:
        _thinkingTimeout?.cancel();
        _thinkingTimeout = null;
        setState(() {
          _isConnected = false;
          _isSpeaking = false;
          _isAssistantSpeaking = false;
          _isWaitingResponse = false;
          _statusText = '连接已断开，重连中...';
        });
        break;

      case XiaozhiServiceEventType.reconnecting:
        // 掉线后正在重连：保持"重连中"提示，避免状态闪烁
        setState(() {
          _isConnected = false;
          _isSpeaking = false;
          _isAssistantSpeaking = false;
          _isWaitingResponse = false;
          _statusText = '连接已断开，重连中...';
        });
        break;

      case XiaozhiServiceEventType.recordingStarted:
        _thinkingTimeout?.cancel();
        _thinkingTimeout = null;
        _relistenDelayTimer?.cancel();
        _relistenDelayTimer = null;
        setState(() {
          _isSpeaking = true;
          _isAssistantSpeaking = false;
          _isWaitingResponse = false;
          _statusText = '正在录音';
        });
        break;

      case XiaozhiServiceEventType.recordingStopped:
        setState(() {
          _isSpeaking = false;
          _isWaitingResponse = true;
          _statusText = '正在思考...';
        });
        // 思考超时保护：超过 12 秒无响应，自动停止等待并重听。
        // 服务端正常响应通常在 1~3 秒内，12 秒足够；太久会让用户觉得"卡住"。
        _thinkingTimeout?.cancel();
        _thinkingTimeout = Timer(const Duration(seconds: 12), () {
          if (mounted && _isWaitingResponse) {
            print('语音通话: 思考超时 12s，自动重新聆听');
            _xiaozhiService.stopPlayback();
            _startSpeaking();
          }
        });
        break;

      case XiaozhiServiceEventType.assistantSpeakingStart:
        // 如果用户正在录音，说明是插话状态，忽略小智开始说话的事件，
        // 保证"小智不能打断用户说话"。
        if (_isSpeaking) {
          print('语音通话: 用户正在说话，忽略小智说话事件');
          return;
        }
        _thinkingTimeout?.cancel();
        _thinkingTimeout = null;
        _relistenDelayTimer?.cancel();
        _relistenDelayTimer = null;
        setState(() {
          _isAssistantSpeaking = true;
          _isSpeaking = false;
          _isWaitingResponse = false;
          _statusText = '小智正在说话';
        });
        // 小智播报期间：关闭自动断句发送，避免把小智自己的回声当作用户输入发出去。
        // （不打断模式：保持正常「你一句我一句」轮替，用户说完等小智讲完再开口。）
        AudioUtil.onSilenceAutoStop = null;
        // 全双工模式：小智讲话期间启动插话检测（用自身播放音量估计回声）。
        if (AudioUtil.fullDuplexEnabled) {
          _startBargeInMonitor();
        }
        break;

      case XiaozhiServiceEventType.assistantSpeakingStop:
        _thinkingTimeout?.cancel();
        _thinkingTimeout = null;
        _relistenDelayTimer?.cancel();
        // 小智说完：停止全双工插话检测。
        _bargeInTimer?.cancel();
        _bargeInTimer = null;
        _bargeInAboveMs = 0;
        // 小智已说完（接下来 400ms 后自动回到聆听）。
        setState(() {
          _isAssistantSpeaking = false;
          _isWaitingResponse = false;
        });
        // 小智说完后立即清空本地播放缓冲，把尚未播完的 TTS 残音掐掉，
        // 避免下一轮麦克风录到"小智自己的声音"→ 服务端 ASR 串音 → 思考卡死。
        // 随后仅留极短间隔（400ms，覆盖扬声器/蓝牙管线延迟）就重新开启聆听。
        // 原先 2s 等待是连续对话最大的"死时间"，会让用户感觉反应慢、卡顿；
        // 现在小智一停，麦克风几乎立刻回来，对话衔接接近豆包的实时感。
        await AudioUtil.stopPlaying();
        _relistenDelayTimer = Timer(const Duration(milliseconds: 250), () {
          _relistenDelayTimer = null;
          if (mounted &&
              _isConnected &&
              !_isSpeaking &&
              !_isAssistantSpeaking &&
              !_isWaitingResponse &&
              !_isStartingSpeaking) {
            print('语音通话: 小智说完，自动进入聆听');
            _startSpeaking();
          }
        });
        break;

      case XiaozhiServiceEventType.userMessage:
        final text = event.data as String? ?? '';
        if (text.isNotEmpty) {
          Provider.of<ConversationProvider>(context, listen: false).addMessage(
            conversationId: widget.conversation.id,
            role: MessageRole.user,
            content: text,
          );
        }
        break;

      case XiaozhiServiceEventType.textMessage:
        final text = event.data as String? ?? '';
        if (text.isNotEmpty) {
          Provider.of<ConversationProvider>(context, listen: false).addMessage(
            conversationId: widget.conversation.id,
            role: MessageRole.assistant,
            content: text,
          );
        }
        break;

      default:
        break;
    }
  }

  @override
  void dispose() {
    // 切换回普通聊天模式
    _xiaozhiService.switchToChatMode();
    _callTimer?.cancel();
    _audioVisualizerTimer?.cancel();
    _thinkingTimeout?.cancel();
    _relistenDelayTimer?.cancel();
    _bargeInTimer?.cancel();
    _bargeInTimer = null;
    _animationController.dispose();

    // 确保停止所有音频播放
    _xiaozhiService.stopPlayback();

    // 移除服务事件监听并关闭通话模式的 VAD
    _xiaozhiService.removeListener(_handleServiceEvent);
    AudioUtil.vadEnabled = false;
    AudioUtil.onSilenceAutoStop = null;

    // 退出通话：停止"通话保活"前台服务与唤醒锁。
    CallKeepAlive.stopCallService();

    // 退出通话：若进入前唤醒服务在运行，恢复它（后台持续监听唤醒词）。
    // dispose 必须同步执行，故不 await（fire-and-forget）。
    if (_wakeWasRunning) {
      unawaited(WakeWordService().resume());
      _wakeWasRunning = false;
    }

    // 释放相机资源（物体识别引擎为单例，随 App 生命周期，此处不关闭）
    try {
      unawaited(_cameraController?.stopImageStream());
    } catch (_) {}
    unawaited(_cameraController?.dispose());
    _cameraController = null;

    super.dispose();
  }

  void _connectToVoiceService() async {
    setState(() {
      _statusText = '正在准备...';
    });

    try {
      // 进入通话前，若离线唤醒正在占用麦克风，先挂起它，
      // 否则两个 AudioRecord 争抢麦克风会导致通话录音拿到静音/失败（"说话毫无反应"）。
      if (WakeWordService().isRunning) {
        _wakeWasRunning = true;
        await WakeWordService().suspend();
      }

      // 切换到语音通话模式
      await _xiaozhiService.switchToVoiceCallMode();

      // 确保 WebSocket 已连接（单例可能已被聊天页连接过，也可能尚未连接）
      final wasAlreadyConnected = _xiaozhiService.isConnected;
      if (!wasAlreadyConnected) {
        await _xiaozhiService.connect();
      }

      setState(() {
        _statusText = '已连接';
        _isConnected = true;
      });

      // 显示连接成功的提示
      if (mounted) {
        _showCustomSnackbar(
          message: '已进入语音通话模式',
          icon: Icons.check_circle,
          iconColor: Colors.greenAccent,
        );
      }

      // 拉起"通话保活"前台服务（麦克风类型 + 唤醒锁）：
      // 息屏 / 锁屏 / 退后台时 CPU 不休眠、麦克风持续采集，对话不中断。
      await CallKeepAlive.startCallService();

      _startCallTimer();

      // 添加会话消息
      Provider.of<ConversationProvider>(context, listen: false).addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: '语音通话已开始',
      );

      // 启用通话模式 VAD：静音自动断句，实现连续对话。
      AudioUtil.vadEnabled = true;
      AudioUtil.onSilenceAutoStop = _onSilenceAutoStop;

      // 读取全双工（可打断）开关：默认开启，用户可在设置中关闭。
      try {
        final prefs = await SharedPreferences.getInstance();
        AudioUtil.fullDuplexEnabled = prefs.getBool('full_duplex_enabled') ?? true;
      } catch (_) {
        AudioUtil.fullDuplexEnabled = true;
      }

      // 已连接的情况下（复用聊天页的连接），
      // session_id 已就绪，直接开始第一轮聆听，无需等 hello
      if (wasAlreadyConnected) {
        _startSpeaking();
      }
      // 新建连接的情况，_handleServerMessage 会在收到 hello 后触发 _startSpeaking
    } catch (e) {
      setState(() {
        _statusText = '准备失败';
        _isConnected = false;
      });
      print('准备失败: $e');

      if (mounted) {
        _showCustomSnackbar(
          message: '进入语音通话模式失败: $e',
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
        );
      }
    }
  }

  void _startCallTimer() {
    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _callDuration = Duration(seconds: timer.tick);
      });
    });
  }

  void _startAudioVisualizer() {
    _audioVisualizerTimer = Timer.periodic(const Duration(milliseconds: 80), (
      timer,
    ) {
      if (_isConnected) {
        setState(() {
          // 滚动历史电平
          for (int i = 0; i < _audioLevels.length - 1; i++) {
            _audioLevels[i] = _audioLevels[i + 1];
          }

          double level;
          if (_isSpeaking) {
            // 真实麦克风 RMS（PCM16，范围 0~32768）→ 归一化到 0~1。
            // 语音通话模式已启用 VAD，AudioUtil.currentRms 会被实时更新。
            final rms = AudioUtil.currentRms;
            level = (rms / 4000.0).clamp(0.05, 1.0);
          } else if (_isAssistantSpeaking) {
            // 小智说话时做轻微起伏，反馈"正在播报"
            level = 0.3 + 0.25 * _animationController.value;
          } else {
            level = 0.05 + 0.03 * _animationController.value;
          }
          _audioLevels[_audioLevels.length - 1] = level;
        });
      }
    });
  }

  // 全双工：小智讲话期间，周期性检测用户是否在插话。
  // 用「当前外放音量 × 耦合系数」估计回声，从麦克风 RMS 中扣除；
  // 去回声后的残差持续超过用户阈值一段时间，即判定为真实插话 → 打断小智。
  void _startBargeInMonitor() {
    _bargeInAboveMs = 0;
    _bargeInTimer?.cancel();
    _bargeInTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (!mounted || !_isAssistantSpeaking) return;
      final micRms = AudioUtil.currentRms;
      final echo = AudioUtil.playbackLevel * _bargeInEchoCoupling;
      final cleaned = micRms - echo;
      if (cleaned > _bargeInUserThreshold) {
        _bargeInAboveMs += 60;
      } else {
        _bargeInAboveMs = 0;
      }
      if (_bargeInAboveMs >= _bargeInSustainMs) {
        print('语音通话: 检测到用户插话，打断小智');
        _interruptAssistant();
      }
    });
  }

  // 全双工：打断小智——停止本地播放 + 发送 abort + 立即开始聆听。
  Future<void> _interruptAssistant() async {
    _bargeInTimer?.cancel();
    _bargeInTimer = null;
    _bargeInAboveMs = 0;
    try {
      await _xiaozhiService.sendAbortSignal();
    } catch (e) {
      print('语音通话: 打断信号发送失败: $e');
    }
    _startSpeaking();
  }

  // 开始录音（连续对话：正常「你一句我一句」轮替，静音后自动发送）
  Future<void> _startSpeaking() async {
    if (!mounted || !_isConnected) return;
    if (_isSpeaking || _isStartingSpeaking) return;
    _isStartingSpeaking = true;

    try {
      // 停止所有播放，防止扬声器里的 TTS 回声被麦克风录入
      await _xiaozhiService.stopPlayback();
      await AudioUtil.stopPlaying();

      // 如果小智正在说话，先打断它
      if (_isAssistantSpeaking) {
        await _xiaozhiService.sendAbortSignal();
      }

      // 确保通话模式 VAD 已启用
      AudioUtil.vadEnabled = true;
      AudioUtil.onSilenceAutoStop = _onSilenceAutoStop;

      await _xiaozhiService.startListeningCall();
      // 录音实际开始状态由 recordingStarted 事件同步
      if (mounted) {
        _showCustomSnackbar(
          message: '正在录音，请说话',
          icon: Icons.mic,
          iconColor: Colors.greenAccent,
        );
      }
    } catch (e) {
      print('开始录音失败: $e');
      if (mounted) {
        _showCustomSnackbar(
          message: '开始录音失败: $e',
          icon: Icons.error,
          iconColor: Colors.redAccent,
        );
      }
    } finally {
      _isStartingSpeaking = false;
    }
  }

  // VAD 检测到连续静音后自动停止录音并发送
  Future<void> _onSilenceAutoStop() async {
    if (!_isSpeaking) return;

    try {
      await _xiaozhiService.stopListeningCall();
      // 录音停止状态由 recordingStopped 事件同步
    } catch (e) {
      print('停止录音失败: $e');
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  String _buildStatusText() {
    if (_isSpeaking) return '$_statusText · 听我讲';
    if (_isAssistantSpeaking) return '$_statusText · 小智讲';
    if (_isWaitingResponse) return _statusText;
    return _statusText;
  }

  /// 语音模式下的头像（保留原 Hero 动画）
  Widget _buildAvatarView() {
    return Hero(
      tag: 'avatar_${widget.conversation.id}',
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 15,
              spreadRadius: 2,
            ),
          ],
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary.withOpacity(0.9),
              Theme.of(context).colorScheme.primaryContainer,
            ],
          ),
        ),
      ),
    );
  }

  /// 视频模式视图：本地相机预览（小智看到的"我这边"）+ 实时物体识别标签
  Widget _buildVideoModeView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        // 本地相机预览
        Container(
          width: 240,
          height: 300,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(0.3),
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: _buildCameraPreview(),
        ),
        const SizedBox(height: 12),
        // 识别到的物体标签
        _buildDetectionLabels(),
        const SizedBox(height: 6),
        Text(
          '小智正在识别你这边的物体',
          style: TextStyle(
            color: Colors.white.withOpacity(0.75),
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview() {
    if (_cameraInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_cameraError ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.videocam_off,
                color: Colors.white70,
                size: 40,
              ),
              const SizedBox(height: 8),
              Text(
                _cameraErrorMsg.isEmpty ? '相机不可用' : _cameraErrorMsg,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return CameraPreview(_cameraController!);
  }

  Widget _buildDetectionLabels() {
    if (_detectedObjects.isEmpty) {
      return Text(
        '将镜头对准物体…',
        style: TextStyle(
          color: Colors.white.withOpacity(0.6),
          fontSize: 14,
        ),
      );
    }
    // 合并同一标签（取最高置信度），按置信度排序后取前 5
    final best = <String, double>{};
    for (final obj in _detectedObjects) {
      for (final label in obj.labels) {
        final text = label.text.isNotEmpty ? label.text : '物体';
        final conf = (label.confidence * 100).toDouble();
        if (!best.containsKey(text) || best[text]! < conf) {
          best[text] = conf;
        }
      }
    }
    final sorted =
        best.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children:
          sorted.take(5).map((e) {
            return Chip(
              backgroundColor: Colors.white.withOpacity(0.9),
              label: Text(
                '${e.key} ${e.value.toStringAsFixed(0)}%',
                style: const TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }).toList(),
    );
  }

  /// 进入视频模式：请求相机权限并初始化相机 + 物体识别引擎，开启图像流。
  Future<void> _initCamera() async {
    if (_cameraController != null) return;
    if (!mounted) return;
    setState(() => _cameraInitializing = true);
    try {
      final status = await Permission.camera.request();
      if (status != PermissionStatus.granted) {
        if (mounted) {
          setState(() {
            _cameraInitializing = false;
            _cameraError = true;
            _cameraErrorMsg = '需要相机权限才能识别物体';
          });
        }
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _cameraInitializing = false;
            _cameraError = true;
            _cameraErrorMsg = '未检测到相机';
          });
        }
        return;
      }

      // 优先后置摄像头（识别"我这边"的环境物体）；无后置则用前置
      final desc = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _cameraController = CameraController(
        desc,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      await ObjectDetectionService().init();
      await _cameraController!.startImageStream(_onCameraImage);

      if (mounted) {
        setState(() {
          _cameraInitializing = false;
          _cameraError = false;
          _cameraErrorMsg = '';
        });
      }
    } catch (e) {
      print('相机初始化失败: $e');
      if (mounted) {
        setState(() {
          _cameraInitializing = false;
          _cameraError = true;
          _cameraErrorMsg = '相机初始化失败: $e';
        });
      }
    }
  }

  /// 收到一帧相机图像 → 送入端侧物体识别
  void _onCameraImage(CameraImage image) async {
    final rotation = _cameraController?.description.sensorOrientation ?? 0;
    final objects = await ObjectDetectionService().processCameraImage(
      image,
      rotation,
    );
    // 只在有结果时更新，跳过"推理中/无人"的空帧，避免标签频繁闪烁
    if (mounted && objects.isNotEmpty) {
      setState(() => _detectedObjects = objects);
    }
  }

  /// 退出视频模式：停止图像流并释放相机
  Future<void> _disposeCamera() async {
    try {
      await _cameraController?.stopImageStream();
    } catch (_) {}
    await _cameraController?.dispose();
    _cameraController = null;
    if (mounted) setState(() => _detectedObjects = []);
  }

  @override
  Widget build(BuildContext context) {
    // 确保状态栏设置正确
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.primary,
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        leading: Container(
          margin: const EdgeInsets.only(left: 8, top: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
            onPressed: () {
              // 返回前停止播放
              _xiaozhiService.stopPlayback();
              Navigator.pop(context);
            },
          ),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 渐变背景
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.primary.withOpacity(0.8),
                  Theme.of(context).colorScheme.primary.withOpacity(0.6),
                ],
              ),
            ),
          ),

          // 水波纹背景
          Positioned.fill(
            child: Opacity(
              opacity: 0.1,
              child: Image.asset(
                'assets/images/wave_pattern.png',
                fit: BoxFit.cover,
              ),
            ),
          ),

          // 主要内容
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 头像 / 视频通话（本地相机预览 + 物体识别）
                _isVideoMode ? _buildVideoModeView() : _buildAvatarView(),
                const SizedBox(height: 24),

                // 名称显示
                Text(
                  widget.conversation.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                // 状态显示 - 使用拟物化样式
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _isConnected
                            ? Colors.green.withOpacity(0.2)
                            : Colors.red.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color:
                          _isConnected
                              ? Colors.green.withOpacity(0.6)
                              : Colors.red.withOpacity(0.6),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            _isConnected
                                ? Colors.green.withOpacity(0.2)
                                : Colors.red.withOpacity(0.2),
                        blurRadius: 8,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isConnected ? Icons.check_circle : Icons.error_outline,
                        color: _isConnected ? Colors.green : Colors.red,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _buildStatusText(),
                        style: TextStyle(
                          color: _isConnected ? Colors.green : Colors.red,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 通话时长
                Text(
                  '通话时长: ${_formatDuration(_callDuration)}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 40),

                // 音频可视化
                _buildAudioVisualizer(),
                const SizedBox(height: 60),

                // 通话控制按钮
                Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom + 20,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // 视频/语音切换
                      _buildControlButton(
                        icon: _isVideoMode ? Icons.videocam : Icons.videocam_off,
                        color: Colors.white,
                        backgroundColor: Colors.blue.shade600,
                        onPressed: () async {
                          final next = !_isVideoMode;
                          setState(() => _isVideoMode = next);
                          if (next) {
                            await _initCamera();
                            _showCustomSnackbar(
                              message:
                                  '已开启视频识别：本地相机预览 + 端侧物体识别',
                              icon: Icons.info_outline,
                              iconColor: Colors.blueAccent,
                            );
                          } else {
                            await _disposeCamera();
                            _showCustomSnackbar(
                              message: '已切换回语音模式',
                              icon: Icons.info_outline,
                              iconColor: Colors.blueAccent,
                            );
                          }
                        },
                      ),
                      const SizedBox(width: 24),
                      // 手掌打断：小智说话时显示，点击后停止播放并立即听我说
                      if (_isAssistantSpeaking)
                        _buildControlButton(
                          icon: Icons.pan_tool,
                          color: Colors.white,
                          backgroundColor: Colors.orange.shade600,
                          size: 64,
                          onPressed: () async {
                            print('语音通话: 用户点击手掌打断');
                            await _xiaozhiService.stopPlayback();
                            await _xiaozhiService.sendAbortSignal();
                            _startSpeaking();
                          },
                        ),
                      if (_isAssistantSpeaking) const SizedBox(width: 24),
                      _buildEndCallButton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioVisualizer() {
    return Container(
      width: 240,
      height: 100,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.2),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(
          _audioLevels.length,
          (index) => AnimatedContainer(
            duration: const Duration(milliseconds: 50),
            curve: Curves.easeInOut,
            width: 4,
            height: 80 * _audioLevels[index],
            decoration: BoxDecoration(
              color: _getBarColor(index, _audioLevels[index]),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Color _getBarColor(int index, double level) {
    if (_isSpeaking) {
      // 用户说话时：渐变从蓝色到绿色
      double position = index / _audioLevels.length;
      return Color.lerp(
        Colors.blue.shade400,
        Colors.green.shade400,
        position,
      )!.withOpacity(0.7 + 0.3 * level);
    } else if (_isAssistantSpeaking) {
      // 小智说话时：暖色渐变
      double position = index / _audioLevels.length;
      return Color.lerp(
        Colors.orange.shade400,
        Colors.yellow.shade400,
        position,
      )!.withOpacity(0.7 + 0.3 * level);
    } else {
      // 非说话状态时使用柔和的蓝色
      return Colors.blue.shade200.withOpacity(0.3 + 0.4 * level);
    }
  }

  Widget _buildControlButton({
    required IconData icon,
    required Color color,
    required Color backgroundColor,
    double size = 56,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: backgroundColor.withOpacity(0.4),
            blurRadius: 12,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Center(child: Icon(icon, color: color, size: size * 0.45)),
        ),
      ),
    );
  }

  Widget _buildEndCallButton() {
    return GestureDetector(
      onTap: () async {
        // 先发送打断消息
        await _xiaozhiService.sendAbortMessage();
        // 然后返回上一级页面
        Navigator.pop(context);
      },
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.red.shade400.withOpacity(0.3),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.call_end_rounded,
          color: Colors.white,
          size: 32,
        ),
      ),
    );
  }

  // 显示自定义Snackbar
  void _showCustomSnackbar({
    required String message,
    required IconData icon,
    required Color iconColor,
  }) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final snackBar = SnackBar(
      content: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black87,
      duration: const Duration(seconds: 3),
      margin: EdgeInsets.only(
        bottom: MediaQuery.of(context).size.height - 120,
        left: 16,
        right: 16,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
    );

    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }
}
