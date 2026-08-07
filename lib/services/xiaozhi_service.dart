import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/xiaozhi_websocket_manager.dart';
import '../utils/device_util.dart';
import '../utils/audio_util.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 小智服务事件类型
enum XiaozhiServiceEventType {
  connected,
  disconnected,
  reconnecting, // 掉线后正在重连（UI 显示"重连中…"，避免"已断开/已连接"闪烁）
  textMessage,
  audioData,
  error,
  voiceCallStart,
  voiceCallEnd,
  userMessage,
  assistantSpeakingStart, // 小智开始说话（用于连续对话：静音麦克风、进入等待）
  assistantSpeakingStop, // 小智说完（用于连续对话：自动重新进入聆听）
  recordingStarted, // 本地录音已开始
  recordingStopped, // 本地录音已停止
}

/// 小智服务事件
class XiaozhiServiceEvent {
  final XiaozhiServiceEventType type;
  final dynamic data;

  XiaozhiServiceEvent(this.type, this.data);
}

/// 小智服务监听器
typedef XiaozhiServiceListener = void Function(XiaozhiServiceEvent event);

/// 消息监听器
typedef MessageListener = void Function(dynamic message);

/// 小智服务
class XiaozhiService {
  static const String TAG = "XiaozhiService";
  static const String DEFAULT_SERVER = "wss://api.tenclass.net/xiaozhi/v1/";

  // 单例实例
  static XiaozhiService? _instance;

  final String websocketUrl;
  final String macAddress;
  final String token;
  final String clientId;
  String? _sessionId; // 会话ID将由服务器提供

  XiaozhiWebSocketManager? _webSocketManager;
  bool _isConnected = false;
  bool _isReconnecting = false; // 掉线后正在重连（UI 显示"重连中…"）
  bool _isMuted = false;
  final List<XiaozhiServiceListener> _listeners = [];
  StreamSubscription? _audioStreamSubscription;
  bool _isVoiceCallActive = false;
  bool _isAssistantSpeaking = false; // 小智是否正在说话（用于断线重连时避免抢话）
  int _ttsActiveCount = 0; // 当前正在播放的 TTS 句子数（服务端可能分多句发送）
  WebSocketChannel? _ws;
  bool _hasStartedCall = false;
  MessageListener? _messageListener;

  /// 工厂构造函数，实现单例模式
  factory XiaozhiService({
    required String websocketUrl,
    required String macAddress,
    required String token,
    String? clientId,
    String? sessionId,
  }) {
    _instance ??= XiaozhiService._internal(
      websocketUrl: websocketUrl,
      macAddress: macAddress,
      token: token,
      clientId: clientId ?? macAddress,
      sessionId: sessionId,
    );
    return _instance!;
  }

  /// 内部构造函数
  XiaozhiService._internal({
    required this.websocketUrl,
    required this.macAddress,
    required this.token,
    required this.clientId,
    String? sessionId,
  }) {
    _sessionId = sessionId;
    _init();
  }

  /// 获取实例
  static XiaozhiService? get instance => _instance;

  /// 当前会话 ID
  String? get sessionId => _sessionId;

  /// 切换到语音通话模式
  Future<void> switchToVoiceCallMode() async {
    // 如果已经在语音通话模式，直接返回
    if (_isVoiceCallActive) return;

    AudioUtil.callMode = true; // 通话播放走听筒（playAndRecord/voiceChat）

    try {
      print('$TAG: 正在切换到语音通话模式');

      // 简化初始化流程，确保干净状态
      await AudioUtil.stopPlaying();
      await AudioUtil.initRecorder();
      await AudioUtil.initPlayer();

      _isVoiceCallActive = true;
      print('$TAG: 已切换到语音通话模式');
    } catch (e) {
      print('$TAG: 切换到语音通话模式失败: $e');
      rethrow;
    }
  }

  /// 切换到普通聊天模式
  Future<void> switchToChatMode() async {
    // 如果已经在普通聊天模式，直接返回
    if (!_isVoiceCallActive) return;

    AudioUtil.callMode = false; // 切回聊天：播放走扬声器

    try {
      print('$TAG: 正在切换到普通聊天模式');

      // 停止语音通话相关的活动
      await stopListeningCall();

      // 离开通话：彻底停止"通话全程不断"的麦克风采集（仅在此处真正停麦，
      // 通话过程中不再 stopRecording，避免息屏后重启麦克风失败 / 重新校准噪声）
      await AudioUtil.stopRecording();

      // 确保播放器停止
      await AudioUtil.stopPlaying();

      _isVoiceCallActive = false;
      print('$TAG: 已切换到普通聊天模式');
    } catch (e) {
      print('$TAG: 切换到普通聊天模式失败: $e');
      _isVoiceCallActive = false;
    }
  }

  /// 初始化
  Future<void> _init() async {
    // 使用配置中的MAC地址作为设备ID
    print('$TAG: 初始化完成，使用MAC地址作为设备ID: $macAddress');

    // 初始化WebSocket管理器，启用 token
    _webSocketManager = XiaozhiWebSocketManager(
      deviceId: macAddress,
      clientId: clientId,
      enableToken: true,
    );

    // 添加WebSocket事件监听
    _webSocketManager!.addListener(_onWebSocketEvent);

    // 初始化音频工具
    await AudioUtil.initRecorder();
    await AudioUtil.initPlayer();
  }

  /// 设置消息监听器
  void setMessageListener(MessageListener listener) {
    _messageListener = listener;
  }

  /// 添加事件监听器
  void addListener(XiaozhiServiceListener listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// 移除事件监听器
  void removeListener(XiaozhiServiceListener listener) {
    _listeners.remove(listener);
  }

  /// 分发事件到所有监听器
  void _dispatchEvent(XiaozhiServiceEvent event) {
    for (var listener in _listeners) {
      listener(event);
    }
  }

  /// 连接到小智服务
  Future<void> connect() async {
    if (_isConnected) return;

    try {
      print('$TAG: 开始连接服务器...');

      // 先释放可能存在的旧连接（取消其重连定时器），避免旧连接泄漏/重连风暴。
      // 新建 manager 时不传 clientId，保持 client-id 头 = deviceId(设备MAC)，
      // 与已验证可用的 v2.0.6 行为一致。
      if (_webSocketManager != null) {
        await _webSocketManager!.disconnect();
        _webSocketManager = null;
      }

      _webSocketManager = XiaozhiWebSocketManager(
        deviceId: macAddress,
        enableToken: true,
      );
      _webSocketManager!.addListener(_onWebSocketEvent);

      // 连接WebSocket（内部已等待握手真正成功）
      await _webSocketManager!.connect(websocketUrl, token);
    } catch (e) {
      print('$TAG: 连接失败: $e');
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.error, '连接小智服务失败: $e'),
      );
    }
  }

  /// 断开小智服务连接
  Future<void> disconnect() async {
    if (!_isConnected || _webSocketManager == null) return;

    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止音频录制
      if (AudioUtil.isRecording) {
        await AudioUtil.stopRecording();
      }

      // 断开WebSocket连接
      await _webSocketManager!.disconnect();
      _webSocketManager = null;
      _isConnected = false;
    } catch (e) {
      print('$TAG: 断开连接失败: $e');
    }
  }

  /// 发送文本消息
  Future<String> sendTextMessage(String message) async {
    if (!_isConnected && _webSocketManager == null) {
      await connect();
    }

    try {
      // 创建一个Completer来等待响应
      final completer = Completer<String>();
      bool hasResponse = false;

      print('$TAG: 开始发送文本消息: $message');

      // 添加消息监听器，监听所有可能的回复
      void onceListener(XiaozhiServiceEvent event) {
        if (event.type == XiaozhiServiceEventType.textMessage) {
          // 忽略echo消息（即我们发送的消息）
          if (event.data == message) {
            print('$TAG: 忽略echo消息: ${event.data}');
            return;
          }

          print('$TAG: 收到服务器响应: ${event.data}');
          if (!completer.isCompleted) {
            hasResponse = true;
            completer.complete(event.data as String);
            removeListener(onceListener);
          }
        } else if (event.type == XiaozhiServiceEventType.error &&
            !completer.isCompleted) {
          print('$TAG: 收到错误响应: ${event.data}');
          completer.completeError(event.data.toString());
          removeListener(onceListener);
        }
      }

      // 先添加监听器，确保不会错过任何消息
      addListener(onceListener);

      // 发送文本请求
      print('$TAG: 发送文本请求: $message');
      _webSocketManager!.sendTextRequest(message);

      // 设置超时，15秒比10秒更宽松一些
      final timeoutTimer = Timer(const Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          print('$TAG: 请求超时，15秒内没有收到响应');
          completer.completeError('请求超时');
          removeListener(onceListener);
        }
      });

      // 等待响应
      try {
        final result = await completer.future;
        // 取消超时定时器
        timeoutTimer.cancel();
        return result;
      } catch (e) {
        // 取消超时定时器
        timeoutTimer.cancel();
        rethrow;
      }
    } catch (e) {
      print('$TAG: 发送消息失败: $e');
      rethrow;
    }
  }

  /// 连接语音通话
  Future<void> connectVoiceCall() async {
    try {
      // 简化流程，确保权限和音频准备就绪
      if (Platform.isIOS || Platform.isAndroid) {
        final status = await Permission.microphone.request();
        if (status != PermissionStatus.granted) {
          print('$TAG: 麦克风权限被拒绝');
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'),
          );
          return;
        }
      }

      // 初始化音频系统
      await AudioUtil.stopPlaying();
      await AudioUtil.initRecorder();
      await AudioUtil.initPlayer();

      print('$TAG: 正在连接 $websocketUrl');
      print('$TAG: 设备ID: $macAddress');
      print('$TAG: Token启用: true');
      print('$TAG: 使用Token: $token');

      // 复用已存在的 WebSocket 管理器
      if (_webSocketManager != null) {
        await _webSocketManager!.disconnect();
        _webSocketManager = null;
      }
      _webSocketManager = XiaozhiWebSocketManager(
        deviceId: macAddress,
        enableToken: true,
      );
      _webSocketManager!.addListener(_onWebSocketEvent);
      await _webSocketManager!.connect(websocketUrl, token);
      // 通话期间启用"静默掉线看门狗"：服务器静默掐线时能主动重连
      _webSocketManager!.enableStaleWatchdog(true);
    } catch (e) {
      print('$TAG: 连接失败: $e');
      rethrow;
    }
  }

  /// 结束语音通话
  Future<void> disconnectVoiceCall() async {
    if (_webSocketManager == null) return;

    // 关闭通话静默掉线看门狗
    try {
      _webSocketManager!.enableStaleWatchdog(false);
    } catch (_) {}

    try {
      // 停止音频录制
      if (AudioUtil.isRecording) {
        await AudioUtil.stopRecording();
      }

      // 停止音频播放
      await AudioUtil.stopPlaying();

      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 直接断开连接
      await disconnect();
    } catch (e) {
      // 忽略断开连接时的错误
      print('$TAG: 结束语音通话时发生错误: $e');
    }
  }

  /// 开始说话
  Future<void> startSpeaking() async {
    try {
      final message = {'type': 'speak', 'state': 'start', 'mode': 'auto'};
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送开始说话消息');
    } catch (e) {
      print('$TAG: 开始说话失败: $e');
    }
  }

  /// 停止说话
  Future<void> stopSpeaking() async {
    try {
      final message = {'type': 'speak', 'state': 'stop', 'mode': 'auto'};
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送停止说话消息');
    } catch (e) {
      print('$TAG: 停止说话失败: $e');
    }
  }

  /// 发送listen消息
  void _sendListenMessage() async {
    try {
      // 避免自动流程与UI重复触发录音
      if (_audioStreamSubscription != null) {
        print('$TAG: 已在录音中，跳过自动listen');
        return;
      }

      // 直接复用 startListeningCall；它会按正确顺序订阅广播流→启动录音→发送 listen start。
      // 之前这里是裸调 AudioUtil.startRecording + sendMessage，没有订阅，
      // 服务端响应 `start` 触发的兜底路径会把音频放进无人订阅的广播流，全部丢弃。
      await startListeningCall();
    } catch (e) {
      print('$TAG: 发送listen消息失败: $e');
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.error, '发送listen消息失败: $e'),
      );
    }
  }

  /// 开始听说（语音通话模式）
  ///
  /// 关键顺序：先订阅广播流 → 再启动录音 → 最后发送 listen start。
  /// 之前的顺序是「先 startRecording 再订阅」，导致录音器早期产出的 PCM
  /// 经过 Opus 编码后被 `_audioStreamController.add()` 丢进广播流，
  /// 但订阅还没接上 → 那部分音频直接被丢弃。第一轮靠冷启动延迟侥幸工作，
  /// 从第二轮起录音器是"热"状态、几乎立刻吐 PCM，于是第二句听不见。
  Future<void> startListeningCall() async {
    try {
      // 避免重复开始录音
      if (_audioStreamSubscription != null) {
        print('$TAG: 已经在录音中，忽略重复开始');
        return;
      }

      // 确保已经有会话ID
      if (_sessionId == null) {
        print('$TAG: 没有会话ID，无法开始监听，等待会话ID初始化...');
        // 等待短暂时间，然后重新检查会话ID
        await Future.delayed(const Duration(milliseconds: 500));
        if (_sessionId == null) {
          print('$TAG: 会话ID仍然为空，放弃开始监听');
          throw Exception('会话ID为空，无法开始录音');
        }
      }

      print('$TAG: 使用会话ID开始录音: $_sessionId');

      // 请求麦克风权限
      if (Platform.isIOS) {
        final micStatus = await Permission.microphone.status;
        if (micStatus != PermissionStatus.granted) {
          final result = await Permission.microphone.request();
          if (result != PermissionStatus.granted) {
            print('$TAG: 麦克风权限被拒绝');
            _dispatchEvent(
              XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'),
            );
            return;
          }
        }

        // 确保音频会话已初始化
        await AudioUtil.initRecorder();
      } else {
        // Android权限请求
        final status = await Permission.microphone.request();
        if (status.isDenied) {
          print('$TAG: 麦克风权限被拒绝');
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'),
          );
          return;
        }
      }

      // ① 停止所有播放并清空缓冲（关键！防止扬声器里的 TTS 回声被麦克风录入，
      //    导致服务器收到自己的声音 → ASR 乱码 → 卡死在"思考中"）
      await AudioUtil.stopPlaying();

      // 如果小智正在说话，先向服务端发送打断信号，确保它停止下发后续 TTS
      if (_isAssistantSpeaking || _ttsActiveCount > 0) {
        await sendAbortSignal();
      }

      // ② 先订阅广播流（必须先于 startRecording，避免早期帧丢失）
      _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
        _webSocketManager?.sendBinaryMessage(opusData);
      });

      // ③ 再启动录音
      await AudioUtil.startRecording();

      // ④ 最后发送 listen start。
      //    mode='manual'：由客户端显式控制 listen start/stop，不依赖服务端 VAD。
      //    mode='auto' 会让服务端自己也做 VAD，与客户端 VAD 双轨冲突。
      final message = {
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'start',
        'mode': 'manual',
      };
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送开始监听消息 (语音通话模式, manual)');

      // 通知 UI 录音已开始，用于同步通话界面状态
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.recordingStarted, null),
      );
    } catch (e) {
      // 启动失败时清理已创建的订阅，避免漏听
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;
      print('$TAG: 开始监听失败: $e');
      throw Exception('开始语音输入失败: $e');
    }
  }

  /// 停止听说（语音通话模式）
  ///
  /// 注意：本方法**不再调用 [AudioUtil.stopRecording]**。语音通话全程保持麦克风
  /// 采集不断开（仅在 [switchToChatMode] / [disconnect] 真正离会时才停麦）。
  /// 这样可避免两个老问题：(1) 息屏/锁屏后"重新启动麦克风"不可靠导致听不到用户；
  /// (2) 每轮重启都会重新做噪声校准，把小智回声当成安静阈值，使打断检测失效。
  /// 此处只是取消"发往服务端"的订阅并通知服务端停止本段 listen。
  Future<void> stopListeningCall() async {
    try {
      // 取消音频流订阅（停止把音频发往服务端，但麦克风仍持续采集用于插话监听）
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 发送停止监听命令
      if (_sessionId != null && _webSocketManager != null) {
        final message = {
          'session_id': _sessionId,
          'type': 'listen',
          'state': 'stop',
          'mode': 'manual',
        };
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('$TAG: 已发送停止监听消息 (语音通话模式, manual)');
      }

      // 通知 UI 录音已停止
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.recordingStopped, null),
      );
    } catch (e) {
      print('$TAG: 停止监听失败: $e');
    }
  }

  /// 取消发送（上滑取消）
  Future<void> abortListening() async {
    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止录音
      await AudioUtil.stopRecording();

      // 发送中止命令
      if (_sessionId != null && _webSocketManager != null) {
        final message = {'session_id': _sessionId, 'type': 'abort'};
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('$TAG: 已发送中止消息');
      }
    } catch (e) {
      print('$TAG: 中止监听失败: $e');
    }
  }

  /// 切换静音状态
  void toggleMute() {
    _isMuted = !_isMuted;

    if (_webSocketManager == null || !_webSocketManager!.isConnected) return;

    try {
      final request = {'type': _isMuted ? 'voice_mute' : 'voice_unmute'};

      _webSocketManager!.sendMessage(jsonEncode(request));
    } catch (e) {
      print('$TAG: 切换静音状态失败: $e');
    }
  }

  /// 处理WebSocket事件
  void _onWebSocketEvent(XiaozhiEvent event) {
    switch (event.type) {
      case XiaozhiEventType.connected:
        _isConnected = true;
        _isReconnecting = false;
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.connected, null),
        );
        break;

      case XiaozhiEventType.disconnected:
        _isConnected = false;
        _isReconnecting = false;
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.disconnected, null),
        );
        break;

      case XiaozhiEventType.reconnecting:
        _isReconnecting = true;
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.reconnecting, null),
        );
        break;

      case XiaozhiEventType.message:
        _handleTextMessage(event.data as String);
        break;

      case XiaozhiEventType.binaryMessage:
        // 处理二进制音频数据
        // 如果当前用户正在录音（插话状态），丢弃服务端下发的音频，
        // 避免"小智打断用户说话"。
        if (_audioStreamSubscription != null) {
          print('$TAG: 用户正在说话，丢弃服务端音频');
          return;
        }
        final audioData = event.data as List<int>;
        AudioUtil.playOpusData(Uint8List.fromList(audioData));
        break;

      case XiaozhiEventType.error:
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.error, event.data),
        );
        break;
    }
  }

  /// 处理文本消息
  void _handleTextMessage(String message) {
    print('$TAG: 收到文本消息: $message');
    try {
      final Map<String, dynamic> jsonData = json.decode(message);
      final String type = jsonData['type'] ?? '';

      // 先更新会话ID（服务器在hello消息中会提供新的会话ID），
      // 确保 messageListener 拿到的是已填充 session_id 的新会话。
      if (jsonData['session_id'] != null) {
        _sessionId = jsonData['session_id'];
        print('$TAG: 更新会话ID: $_sessionId');
      }

      // 然后调用消息监听器，让通话页在 session_id 就绪后启动录音
      if (_messageListener != null) {
        _messageListener!(jsonData);
      }

      // 根据消息类型分发事件（通话页的录音由 _messageListener 触发，
      // 服务层不再强行插一脚）
      switch (type) {
        case 'hello':
          // 非语音通话模式时使用原有的文本自动说话流程
          if (!_isVoiceCallActive && !_hasStartedCall) {
            _hasStartedCall = true;
            startSpeaking();
          }
          break;

        case 'start':
          // 非语音通话模式时使用原有的 listen 流程
          if (!_isVoiceCallActive) {
            _sendListenMessage();
          }
          break;

        case 'tts':
          // TTS消息处理
          final String state = jsonData['state'] ?? '';
          final String text = jsonData['text'] ?? '';

          if (state == 'sentence_start' && text.isNotEmpty) {
            // 单句开始：标记"小智正在说话"，并把这句文本推给 UI 做字幕
            _isAssistantSpeaking = true;
            _ttsActiveCount++;
            print('$TAG: 收到TTS句子($_ttsActiveCount): $text');
            _dispatchEvent(
              XiaozhiServiceEvent(XiaozhiServiceEventType.textMessage, text),
            );
            _dispatchEvent(
              XiaozhiServiceEvent(
                XiaozhiServiceEventType.assistantSpeakingStart,
                null,
              ),
            );
          } else if (state == 'start') {
            // 服务端在 sentence_start 之前先发 tts start（整体 TTS 会话开始）
            // 关键：每轮 TTS 会话开始都要重建 Opus 解码器并重置预缓冲，
            // 否则上一句尾帧的残留状态会让本句开头首帧失真（「前两个字不清晰」）。
            AudioUtil.resetTtsSession();
            _isAssistantSpeaking = true;
            print('$TAG: TTS开始');
            _dispatchEvent(
              XiaozhiServiceEvent(
                XiaozhiServiceEventType.assistantSpeakingStart,
                null,
              ),
            );
          } else if (state == 'sentence_end') {
            // 单句结束，但仍处于整体 TTS 会话中：仅递减句子计数（仅供调试），
            // 不翻转动画——要等整体 stop 才回到"聆听"。
            if (_ttsActiveCount > 0) _ttsActiveCount--;
          } else if (state == 'stop') {
            // 整体 TTS 会话结束：无条件把"正在说话"置否并通知 UI 重新聆听。
            // 关键修复：旧逻辑按"每句递减"计数，若服务端发了多句 sentence_start
            // 却没发等量 sentence_end，计数永远 >0，_isAssistantSpeaking 卡在
            // true —— UI 永久显示"小智正在说话"且麦克风不回来。改为 stop 直接归零。
            final bool wasSpeaking = _isAssistantSpeaking;
            _ttsActiveCount = 0;
            _isAssistantSpeaking = false;
            print('$TAG: TTS结束，重新聆听');
            if (wasSpeaking) {
              _dispatchEvent(
                XiaozhiServiceEvent(
                  XiaozhiServiceEventType.assistantSpeakingStop,
                  null,
                ),
              );
            }
          }
          break;

        case 'stt':
          // 处理语音识别结果
          final String text = jsonData['text'] ?? '';
          if (text.isNotEmpty) {
            print('$TAG: 收到语音识别结果: $text');
            // 先分发用户消息事件
            _dispatchEvent(
              XiaozhiServiceEvent(XiaozhiServiceEventType.userMessage, text),
            );
          }
          break;

        case 'emotion':
          // 处理表情消息
          final String emotion = jsonData['emotion'] ?? '';
          if (emotion.isNotEmpty) {
            print('$TAG: 收到表情消息: $emotion');
            _dispatchEvent(
              XiaozhiServiceEvent(
                XiaozhiServiceEventType.textMessage,
                '表情: $emotion',
              ),
            );
          }
          break;

        default:
          // 对于其他类型的消息，直接忽略
          print('$TAG: 收到未知类型消息: $type, 原始数据: $message');
      }
    } catch (e) {
      print('$TAG: 解析消息失败: $e, 原始消息: $message');
    }
  }

  /// 开始通话
  void _startCall() {
    try {
      // 发送开始通话消息
      final startMessage = {
        'type': 'start',
        'mode': 'auto',
        'audio_params': {
          'format': 'opus',
          'sample_rate': 16000,
          'channels': 1,
          'frame_duration': 60,
        },
      };
      _webSocketManager?.sendMessage(jsonEncode(startMessage));
      print('$TAG: 已发送开始通话消息');
    } catch (e) {
      print('$TAG: 开始通话失败: $e');
    }
  }

  /// 中断音频播放并清空 TTS 状态
  Future<void> stopPlayback() async {
    try {
      print('$TAG: 正在停止音频播放');

      // 停止播放并清空缓冲
      await AudioUtil.stopPlaying();

      // 重置 TTS 状态，防止状态机错乱
      _isAssistantSpeaking = false;
      _ttsActiveCount = 0;

      print('$TAG: 音频播放已停止');
    } catch (e) {
      print('$TAG: 停止音频播放失败: $e');
    }
  }

  /// 判断是否已连接
  bool get isConnected =>
      _isConnected &&
      _webSocketManager != null &&
      _webSocketManager!.isConnected;

  /// 是否正在重连中（掉线后等待重连期间为 true，UI 可显示"重连中…"）
  bool get isReconnecting => _isReconnecting;

  /// 判断是否静音
  bool get isMuted => _isMuted;

  /// 判断语音通话是否活跃
  bool get isVoiceCallActive => _isVoiceCallActive;

  /// 判断是否正在录音
  bool get isRecording => _audioStreamSubscription != null;

  /// 释放资源
  Future<void> dispose() async {
    await disconnect();
    await AudioUtil.dispose();
    _listeners.clear();
    print('$TAG: 资源已释放');
  }

  /// 开始监听（按住说话模式）
  Future<void> startListening({String mode = 'manual'}) async {
    if (!_isConnected || _webSocketManager == null) {
      await connect();
    }

    try {
      // 确保已经有会话ID
      if (_sessionId == null) {
        print('$TAG: 没有会话ID，无法开始监听');
        return;
      }

      // 同 startListeningCall：先订阅、再启动录音、最后发送 listen start，
      // 避免录音器早期 PCM 编码后被 add 进广播流但订阅尚未接上 → 音频被丢。
      _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
        // 发送音频数据
        _webSocketManager?.sendBinaryMessage(opusData);
      });

      // 开始录音
      await AudioUtil.startRecording();

      // 发送开始监听命令
      final message = {
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'start',
        'mode': mode,
      };
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送开始监听消息 (按住说话)');
    } catch (e) {
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;
      print('$TAG: 开始监听失败: $e');
      throw Exception('开始语音输入失败: $e');
    }
  }

  /// 停止监听（按住说话模式）
  Future<void> stopListening() async {
    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止录音
      await AudioUtil.stopRecording();

      // 发送停止监听命令
      if (_sessionId != null && _webSocketManager != null) {
        final message = {
          'session_id': _sessionId,
          'type': 'listen',
          'state': 'stop',
        };
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('$TAG: 已发送停止监听消息');
      }
    } catch (e) {
      print('$TAG: 停止监听失败: $e');
    }
  }

  /// 发送中断消息
  Future<void> sendAbortMessage() async {
    try {
      if (_webSocketManager != null && _isConnected && _sessionId != null) {
        final abortMessage = {
          'session_id': _sessionId,
          'type': 'abort',
          'reason': 'wake_word_detected',
        };
        _webSocketManager?.sendMessage(jsonEncode(abortMessage));
        print('$TAG: 发送中断消息: $abortMessage');

        // 如果当前正在录音，短暂停顿后继续
        if (_isSpeaking) {
          await stopListeningCall();
          await Future.delayed(const Duration(milliseconds: 500));
          await startListeningCall();
        }
      }
    } catch (e) {
      print('$TAG: 发送中断消息失败: $e');
    }
  }

  /// 轻量中断信号：通知服务端停止 TTS，并立即停止本地播放。
  /// 连续对话打断小智时使用。
  Future<void> sendAbortSignal() async {
    try {
      // 立即清空本地播放缓冲，避免用户已经开始说话后还听到旧 TTS
      await AudioUtil.stopPlaying();
      _isAssistantSpeaking = false;
      _ttsActiveCount = 0;

      if (_webSocketManager != null && _isConnected && _sessionId != null) {
        final abortMessage = {
          'session_id': _sessionId,
          'type': 'abort',
          'reason': 'user_interrupt',
        };
        _webSocketManager?.sendMessage(jsonEncode(abortMessage));
        print('$TAG: 发送打断信号(用户插话)');
      }
    } catch (e) {
      print('$TAG: 发送打断信号失败: $e');
    }
  }

  /// 判断是否正在说话
  bool get _isSpeaking => _audioStreamSubscription != null;
}
