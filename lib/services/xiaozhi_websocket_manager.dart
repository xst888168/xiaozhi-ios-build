import 'dart:async';
import 'dart:convert';
import 'dart:math';
// 尝试导入io.dart，但在web平台会抛出异常
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/io.dart'
    if (dart.library.html) 'package:web_socket_channel/html.dart';

/// 小智WebSocket事件类型
enum XiaozhiEventType {
  connected,
  disconnected,
  reconnecting, // 掉线后正在尝试重连（UI 应显示"重连中…"，避免"已断开/已连接"闪烁）
  message,
  error,
  binaryMessage,
}

/// 小智WebSocket事件
class XiaozhiEvent {
  final XiaozhiEventType type;
  final dynamic data;

  XiaozhiEvent({required this.type, this.data});
}

/// 小智WebSocket监听器接口
typedef XiaozhiWebSocketListener = void Function(XiaozhiEvent event);

/// 小智WebSocket管理器
///
/// 连接稳定性设计（修复"已断开→又连接"反复闪烁）：
/// 1. **单一重连权威**：本类是唯一负责自动重连的地方。UI / 聊天页不要再自行
///    disconnect+connect，否则会与这里的重连叠加形成"重连风暴"。
/// 2. **诚实的 isConnected**：只有 WebSocket 真正握手成功（_channel.ready）后才置
///    true；握手前/重连中均为 false，杜绝"假连接"造成的状态闪烁。
/// 3. **指数退避 + 抖动**：首次 1.5s，之后 ×2（3s/6s/12s…上限 30s），并叠加 0~500ms
///    随机抖动，避免网络抖动时疯狂重连、也避免多端同时重连的惊群效应。
/// 4. **reconnecting 事件**：掉线后先广播 reconnecting（UI 显示"重连中…"），连接成功
///    才广播 connected，因此用户看到的是「重连中…→已连接」，而不是「已断开→已连接」。
/// 5. **通话静默掉线看门狗**：语音通话期间若 15s 内无任何数据（服务器静默掐线），
///    主动判定掉线并触发重连；非通话空闲时不启用，避免误杀正常空闲连接。
class XiaozhiWebSocketManager {
  static const String TAG = "XiaozhiWebSocket";
  static const int _reconnectBaseMs = 1500; // 首次重连延迟
  static const int _reconnectMaxMs = 30000; // 重连延迟上限
  static const int _staleTimeoutMs = 20000; // 通话期间静默超过该时长判定掉线（放宽到 20s，容忍用户较长独白）

  WebSocketChannel? _channel;
  String? _serverUrl;
  String? _deviceId;
  String? _clientId;
  String? _token;
  bool _enableToken;

  final List<XiaozhiWebSocketListener> _listeners = [];
  bool _connected = false;
  bool _pendingReconnect = false; // 已处于"掉线→等待重连"状态，避免 onDone 重复触发
  bool _staleWatchdog = false; // 通话期间是否启用静默掉线看门狗
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _staleTimer;
  StreamSubscription? _streamSubscription;
  DateTime? _lastDataTime;

  /// 构造函数
  XiaozhiWebSocketManager({
    required String deviceId,
    String? clientId,
    bool enableToken = false,
  }) : _deviceId = deviceId,
       _clientId = clientId ?? deviceId,
       _enableToken = enableToken;

  /// 添加事件监听器
  void addListener(XiaozhiWebSocketListener listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// 移除事件监听器
  void removeListener(XiaozhiWebSocketListener listener) {
    _listeners.remove(listener);
  }

  /// 分发事件到所有监听器
  void _dispatchEvent(XiaozhiEvent event) {
    for (var listener in _listeners) {
      listener(event);
    }
  }

  /// 是否真正连接（仅握手成功后为真）
  bool get isConnected => _connected;

  /// 通话期间开启静默掉线看门狗；非通话时关闭，避免空闲连接被误杀。
  void enableStaleWatchdog(bool enable) {
    _staleWatchdog = enable;
    if (!enable) {
      _staleTimer?.cancel();
      _staleTimer = null;
    } else if (_connected) {
      _armStaleWatchdog();
    }
  }

  /// 连接到WebSocket服务器
  Future<void> connect(String url, String token) async {
    // 取消可能存在的旧重连定时器，避免手动连接与自动重连叠加导致重连风暴
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (url.isEmpty) {
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.error, data: "WebSocket地址不能为空"),
      );
      return;
    }

    // 保存连接参数
    _serverUrl = url;
    _token = token;

    // 如果已连接，先断开
    if (_channel != null) {
      await disconnect();
    }

    try {
      // 创建WebSocket连接
      Uri uri = Uri.parse(url);

      print('$TAG: 正在连接 $url');
      print('$TAG: 设备ID: $_deviceId');
      print('$TAG: Token启用: $_enableToken');

      if (_enableToken) {
        print('$TAG: 使用Token: $token');
      }

      // 尝试使用headers (这在非Web平台上有效)
      try {
        // 创建headers
        Map<String, dynamic> headers = {
          'device-id': _deviceId ?? '',
          'client-id': _clientId ?? _deviceId ?? '',
          'protocol-version': '1',
        };

        // 添加Authorization头，参考Java实现
        if (_enableToken && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
          print('$TAG: 添加Authorization头: Bearer $token');
        } else {
          headers['Authorization'] = 'Bearer test-token';
          print('$TAG: 添加默认Authorization头: Bearer test-token');
        }

        // 使用IOWebSocketChannel并传递headers
        _channel = IOWebSocketChannel.connect(uri, headers: headers);

        print('$TAG: 使用headers方式连接WebSocket成功');
      } catch (e) {
        // 如果不支持IOWebSocketChannel（web平台），则回退到使用基本连接
        print('$TAG: 不支持使用headers方式，回退到基本连接: $e');

        // 创建基本连接
        _channel = WebSocketChannel.connect(uri);

        // 在连接成功后作为第一条消息发送认证信息
        Timer(const Duration(milliseconds: 100), () {
          if (_channel != null && isConnected) {
            // 发送认证信息作为第一条消息
            String authMessage =
                'Authorization: Bearer ${_enableToken && token.isNotEmpty ? token : "test-token"}';
            _channel!.sink.add(authMessage);
            print('$TAG: 发送认证消息: $authMessage');

            // 发送设备ID信息
            String deviceIdMessage = 'Device-ID: $_deviceId';
            _channel!.sink.add(deviceIdMessage);
            print('$TAG: 发送设备ID消息: $deviceIdMessage');
          }
        });
      }

      // 监听WebSocket事件
      _streamSubscription = _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: _onError,
        cancelOnError: false,
      );

      // 等待 WebSocket 真正握手成功后再上报 connected，避免“假连接”
      try {
        // iOS 等平台偶发握手既不成功也不回调，加 15s 超时兜底，
        // 避免上层（语音通话准备）无限“正在准备…”。
        await _channel!.ready.timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('WebSocket 握手超时(15s)'),
        );
      } catch (e) {
        print('$TAG: WebSocket 握手失败/超时: $e');
        _dispatchEvent(
          XiaozhiEvent(type: XiaozhiEventType.error, data: 'WebSocket 握手失败: $e'),
        );
        // 握手失败也要继续重连，而不是放弃（否则会永远断线）
        _scheduleReconnect();
        rethrow; // 让上层（通话准备）感知并提示“准备失败”，而非无限转圈
      }

      // 握手成功：只有此刻才认为"已连接"
      _connected = true;
      _reconnectAttempts = 0;
      _pendingReconnect = false;
      _lastDataTime = DateTime.now();

      // 连接成功后发送Hello消息
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.connected, data: null),
      );

      // 在发送认证信息之后发送Hello消息
      Timer(const Duration(milliseconds: 200), () {
        _sendHelloMessage();
        if (_staleWatchdog) _armStaleWatchdog();
      });

      print('$TAG: 已连接到 $uri');
    } catch (e) {
      print('$TAG: 连接失败: $e');
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.error, data: "创建WebSocket失败: $e"),
      );
      _scheduleReconnect();
    }
  }

  /// 断开WebSocket连接（手动）
  Future<void> disconnect() async {
    // 取消重连与看门狗
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    _connected = false;
    _pendingReconnect = false;
    _reconnectAttempts = 0;

    // 取消订阅
    await _streamSubscription?.cancel();
    _streamSubscription = null;

    // 关闭连接
    if (_channel != null) {
      try {
        await _channel!.sink.close(status.normalClosure);
      } catch (_) {
        // 忽略关闭异常
      }
      _channel = null;
      print('$TAG: 连接已断开');
    }
  }

  /// 发送Hello消息
  void _sendHelloMessage() {
    final hello = {
      "type": "hello",
      "version": 1,
      "transport": "websocket",
      "audio_params": {
        "format": "opus",
        "sample_rate": 16000,
        "channels": 1,
        "frame_duration": 60,
      },
    };

    sendMessage(jsonEncode(hello));
  }

  /// 发送文本消息
  void sendMessage(String message) {
    if (_channel != null && isConnected) {
      _channel!.sink.add(message);
    } else {
      print('$TAG: 发送失败，连接未建立');
    }
  }

  /// 发送二进制数据
  void sendBinaryMessage(List<int> data) {
    if (_channel != null && isConnected) {
      try {
        _channel!.sink.add(data);
        // 客户端正在上传音频（如语音通话用户说话）：刷新最后数据时间，
        // 避免静默掉线看门狗在「用户长段独白」期间误判掉线而掐断连接
        //（表现为「一直说话都没用 / 偶尔断开 / 跳回已连接提示」）。
        _lastDataTime = DateTime.now();
      } catch (e) {
        print('$TAG: 二进制数据发送失败: $e');
      }
    } else {
      print('$TAG: 发送失败，连接未建立');
    }
  }

  /// 发送文本请求
  void sendTextRequest(String text) {
    if (!isConnected) {
      print('$TAG: 发送失败，连接未建立');
      return;
    }

    try {
      // 构造消息格式，与Java实现保持一致
      final jsonMessage = {
        "type": "listen",
        "state": "detect",
        "text": text,
        "source": "text",
      };

      print('$TAG: 发送文本请求: ${jsonEncode(jsonMessage)}');
      sendMessage(jsonEncode(jsonMessage));
    } catch (e) {
      print('$TAG: 发送文本请求失败: $e');
    }
  }

  /// 处理收到的消息
  void _onMessage(dynamic message) {
    _lastDataTime = DateTime.now();
    if (_staleWatchdog) _armStaleWatchdog(); // 有数据流动则重置看门狗

    if (message is String) {
      // 文本消息
      print('$TAG: 收到消息: $message');
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.message, data: message),
      );
    } else if (message is List<int>) {
      // 二进制消息
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.binaryMessage, data: message),
      );
    }
  }

  /// 处理断开连接事件（onDone）
  void _onDisconnected() {
    // 已经处于"掉线→等待重连"流程中则忽略重复触发（onDone 可能多次回调）
    if (_pendingReconnect) return;

    print('$TAG: 连接已断开');
    _connected = false;
    _staleTimer?.cancel();
    _staleTimer = null;
    _dispatchEvent(
      XiaozhiEvent(type: XiaozhiEventType.disconnected, data: null),
    );
    _scheduleReconnect();
  }

  /// 处理错误事件（按掉线处理并触发重连）
  void _onError(error) {
    print('$TAG: 错误: $error');
    _dispatchEvent(
      XiaozhiEvent(type: XiaozhiEventType.error, data: error.toString()),
    );
    _onDisconnected();
  }

  /// 安排自动重连（指数退避 + 抖动）
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _pendingReconnect = true;
    _reconnectAttempts++;

    // 退避：1.5s, 3s, 6s, 12s, 24s, 30s(封顶)…  叠加 0~500ms 抖动
    final base = _reconnectBaseMs * (1 << (_reconnectAttempts - 1));
    final delay = min(base, _reconnectMaxMs) + Random().nextInt(500);

    print('$TAG: 第 $_reconnectAttempts 次重连将在 ${delay}ms 后尝试');
    _dispatchEvent(
      XiaozhiEvent(
        type: XiaozhiEventType.reconnecting,
        data: {'attempt': _reconnectAttempts, 'delayMs': delay},
      ),
    );

    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      _reconnectTimer = null;
      if (_serverUrl != null && _token != null) {
        connect(_serverUrl!, _token!);
      }
    });
  }

  /// 武装静默掉线看门狗（收到数据 / 成功连接后调用）
  void _armStaleWatchdog() {
    _staleTimer?.cancel();
    _staleTimer = Timer(const Duration(milliseconds: _staleTimeoutMs), _onStale);
  }

  /// 看门狗触发：通话期间长时间无数据，主动判定掉线并重连
  void _onStale() {
    if (!_connected) return;
    final since = _lastDataTime;
    if (since != null &&
        DateTime.now().difference(since).inMilliseconds < _staleTimeoutMs) {
      // 期间已有数据（竞态），重新武装
      _armStaleWatchdog();
      return;
    }
    print('$TAG: 通话静默超时，判定掉线，主动重连');
    _connected = false;
    _dispatchEvent(
      XiaozhiEvent(type: XiaozhiEventType.disconnected, data: null),
    );
    _scheduleReconnect();
  }
}
