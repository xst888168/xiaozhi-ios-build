import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:math';
import 'dart:io';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/message.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/models/dify_config.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/models/minimax_config.dart';
import 'package:ai_assistant/services/dify_service.dart';
import 'package:ai_assistant/services/xiaozhi_service.dart';
import 'package:ai_assistant/services/minimax_service.dart';
import 'package:ai_assistant/services/wake_word_service.dart';
import 'package:ai_assistant/services/wake_router.dart';
import 'package:ai_assistant/utils/audio_util.dart';
import 'package:ai_assistant/widgets/message_bubble.dart';
import 'package:ai_assistant/screens/voice_call_screen.dart';
import 'package:ai_assistant/screens/console_screen.dart';
import 'dart:convert';
import 'dart:async';
import 'package:path_provider/path_provider.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;

  const ChatScreen({
    super.key,
    required this.conversation,
    this.autoListen = false,
  });

  /// 由全局唤醒路由（WakeRouter）唤起时置 true：进入会话即自动开始聆听，
  /// 让用户喊完"小智"后直接开口，无需再点麦克风。
  final bool autoListen;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  XiaozhiService? _xiaozhiService; // 保持XiaozhiService实例
  DifyService? _difyService; // 保持DifyService实例
  MiniMaxService? _minimaxService; // 保持MiniMaxService实例

  // 语音输入相关
  bool _isVoiceInputMode = false;
  bool _isRecording = false;
  bool _isCancelling = false;
  bool _isStopping = false; // 防止 VAD 自动断句与手动停止重复触发
  double _startDragY = 0.0;
  final double _cancelThreshold = 50.0; // 上滑超过这个距离认为是取消
  Timer? _waveAnimationTimer;
  final List<double> _waveHeights = List.filled(20, 0.0);
  double _minWaveHeight = 5.0;
  double _maxWaveHeight = 30.0;
  final Random _random = Random();

  // VAD 实时反馈（让用户看得见「还有几秒自动发送」）
  Timer? _vadUiTimer;
  int _vadRemainMs = 0; // 距离自动发送的剩余毫秒；0 表示正在说话
  double _vadLevel = 0.0; // 当前音量 RMS

  /// 启动 VAD 状态刷新（每 120ms 更新一次倒计时与音量）
  void _startVadUiTimer() {
    _vadUiTimer?.cancel();
    _vadUiTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted || !_isRecording) return;
      final silentFor = AudioUtil.silentForMs;
      final remain =
          silentFor <= 0 ? 0 : (AudioUtil.silenceTimeoutMs - silentFor);
      setState(() {
        _vadRemainMs = remain > 0 ? remain : 0;
        _vadLevel = AudioUtil.currentRms;
      });
    });
  }

  void _stopVadUiTimer() {
    _vadUiTimer?.cancel();
    _vadUiTimer = null;
    if (mounted) {
      setState(() {
        _vadRemainMs = 0;
        _vadLevel = 0.0;
      });
    }
  }

  @override
  void initState() {
    super.initState();

    // 设置状态栏为透明并使图标为黑色
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    // 在帧绘制后再次设置系统UI样式，避免被覆盖
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );

      Provider.of<ConversationProvider>(
        context,
        listen: false,
      ).markConversationAsRead(widget.conversation.id);

      // 如果是小智对话，初始化服务
      if (widget.conversation.type == ConversationType.xiaozhi) {
        _initXiaozhiService();

        // 默认启用语音输入模式 (针对小智对话)
        setState(() {
          _isVoiceInputMode = true;
        });

        // 启用 VAD 静音自动断句（痛点#2：点击即说，2秒静音自动发送）
        AudioUtil.vadEnabled = true;
        AudioUtil.onSilenceAutoStop = _onVadAutoStop;
        // 绑定离线唤醒词命中回调（痛点#1：说“你好小智”自动开始聆听）
        WakeWordService().onWake = _onWake;
      } else if (widget.conversation.type == ConversationType.dify) {
        // 初始化 DifyService
        _initDifyService();
      } else if (widget.conversation.type == ConversationType.minimax) {
        // 初始化 MiniMaxService
        _initMiniMaxService();
      }
    });
  }

  // 重连完全由 XiaozhiWebSocketManager 内部负责（指数退避 + 抖动），
  // 这里不再自行 disconnect+connect，避免双重复连造成"已断开→又连接"的闪烁/风暴。

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    // 取消所有定时器
    _waveAnimationTimer?.cancel();
    _vadUiTimer?.cancel();

    // 清理唤醒词 / VAD 绑定，并确保全局唤醒监听恢复
    AudioUtil.vadEnabled = false;
    AudioUtil.onSilenceAutoStop = null;
    // 离开聊天页：恢复全局兜底唤醒回调，保证息屏/回到首页后语音唤醒仍可用
    WakeWordService().onWake = WakeRouter.globalWake;
    WakeWordService().resume();

    // 在销毁前确保停止所有音频播放
    if (_xiaozhiService != null) {
      _xiaozhiService!.stopPlayback();
      _xiaozhiService!.disconnect();
    }

    super.dispose();
  }

  // 初始化小智服务
  Future<void> _initXiaozhiService() async {
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);
    final xiaozhiConfig = configProvider.xiaozhiConfigs.firstWhere(
      (config) => config.id == widget.conversation.configId,
    );

    _xiaozhiService = XiaozhiService(
      websocketUrl: xiaozhiConfig.websocketUrl,
      macAddress: xiaozhiConfig.macAddress,
      token: xiaozhiConfig.token,
    );

    // 添加消息监听器
    _xiaozhiService!.addListener(_handleXiaozhiMessage);

    // 连接服务
    await _xiaozhiService!.connect();

    // 连接后刷新UI状态
    if (mounted) {
      setState(() {});
    }

    // 由语音唤醒唤起：连接建立后自动开始聆听，用户喊完"小智"可直接开口。
    if (widget.autoListen && mounted && !_isRecording) {
      _onWake();
    }
  }

  // 处理小智消息
  void _handleXiaozhiMessage(XiaozhiServiceEvent event) {
    if (!mounted) return;

    final conversationProvider = Provider.of<ConversationProvider>(
      context,
      listen: false,
    );

    if (event.type == XiaozhiServiceEventType.textMessage) {
      // 直接使用文本内容
      String content = event.data as String;
      print('收到消息内容: $content');

      // 忽略空消息
      if (content.isNotEmpty) {
        conversationProvider.addMessage(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: content,
        );
      }
    } else if (event.type == XiaozhiServiceEventType.userMessage) {
      // 处理用户的语音识别文本
      String content = event.data as String;
      print('收到用户语音识别内容: $content');

      // 只有在语音输入模式下才添加用户消息
      if (content.isNotEmpty && _isVoiceInputMode) {
        // 语音消息可能有延迟，使用Future.microtask确保UI已更新
        Future.microtask(() {
          conversationProvider.addMessage(
            conversationId: widget.conversation.id,
            role: MessageRole.user,
            content: content,
          );
        });
      }
    } else if (event.type == XiaozhiServiceEventType.connected ||
        event.type == XiaozhiServiceEventType.disconnected ||
        event.type == XiaozhiServiceEventType.reconnecting) {
      // 当连接状态发生变化时，更新UI
      setState(() {});
    }
  }

  // 初始化 DifyService
  Future<void> _initDifyService() async {
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);
    final String? configId = widget.conversation.configId;
    DifyConfig? difyConfig;

    if (configId != null && configId.isNotEmpty) {
      difyConfig =
          configProvider.difyConfigs
              .where((config) => config.id == configId)
              .firstOrNull;
    }

    if (difyConfig == null) {
      if (configProvider.difyConfigs.isEmpty) {
        throw Exception("未设置Dify配置，请先在设置中配置Dify API");
      }
      difyConfig = configProvider.difyConfigs.first;
    }

    _difyService = await DifyService.create(
      apiKey: difyConfig.apiKey,
      apiUrl: difyConfig.apiUrl,
    );
  }

  // 初始化 MiniMaxService
  void _initMiniMaxService() {
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);
    final String? configId = widget.conversation.configId;
    MiniMaxConfig? minimaxConfig;

    if (configId != null && configId.isNotEmpty) {
      minimaxConfig =
          configProvider.minimaxConfigs
              .where((config) => config.id == configId)
              .firstOrNull;
    }

    if (minimaxConfig == null) {
      if (configProvider.minimaxConfigs.isEmpty) {
        throw Exception("未设置MiniMax配置，请先在设置中配置MiniMax API");
      }
      minimaxConfig = configProvider.minimaxConfigs.first;
    }

    _minimaxService = MiniMaxService(
      apiKey: minimaxConfig.apiKey,
      model: minimaxConfig.model,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 确保状态栏设置正确
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        toolbarHeight: 70,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        actions: [
          if (widget.conversation.type == ConversationType.dify ||
              widget.conversation.type == ConversationType.minimax)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.black, size: 24),
              tooltip: '开始新对话',
              onPressed: _resetConversation,
            ),
          if (widget.conversation.type == ConversationType.xiaozhi)
            Container(
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _navigateToVoiceCall,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.phone, color: Colors.black, size: 16),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.conversation.type == ConversationType.xiaozhi)
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.black, size: 24),
              tooltip: '配置中心',
              onPressed: () {
                if (_xiaozhiService != null) {
                  _xiaozhiService!.stopPlayback();
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ConsoleScreen(),
                  ),
                );
              },
            ),
        ],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black, size: 26),
          onPressed: () {
            // 返回前停止播放
            if (_xiaozhiService != null) {
              _xiaozhiService!.stopPlayback();
            }
            Navigator.of(context).pop();
          },
        ),
        title:
            widget.conversation.type == ConversationType.xiaozhi
                ? Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFFE8DFF7),
                      child: const Text(
                        '智',
                        style: TextStyle(
                          color: Color(0xFF5E3FA3),
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '小智 AI',
                          style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                          ),
                        ),
                        Text(
                          (_xiaozhiService == null)
                              ? '空闲'
                              : _xiaozhiService!.isReconnecting
                              ? '重连中…'
                              : (_xiaozhiService!.isConnected ? '已连接' : '空闲'),
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                )
                : Consumer<ConfigProvider>(
                  builder: (context, configProvider, child) {
                    final String? configId = widget.conversation.configId;
                    String configName = widget.conversation.title;
                    final bool isMinimax =
                        widget.conversation.type == ConversationType.minimax;
                    final MaterialColor themeColor =
                        isMinimax ? Colors.teal : Colors.blue;

                    // 查找此会话对应的配置
                    if (configId != null && configId.isNotEmpty) {
                      if (isMinimax) {
                        final minimaxConfig =
                            configProvider.minimaxConfigs
                                .where((config) => config.id == configId)
                                .firstOrNull;
                        if (minimaxConfig != null) {
                          configName = minimaxConfig.name;
                        }
                      } else {
                        final difyConfig =
                            configProvider.difyConfigs
                                .where((config) => config.id == configId)
                                .firstOrNull;
                        if (difyConfig != null) {
                          configName = difyConfig.name;
                        }
                      }
                    }

                    return Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: themeColor.withOpacity(0.3),
                                blurRadius: 8,
                                spreadRadius: 0,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: CircleAvatar(
                            radius: 20,
                            backgroundColor: themeColor.shade400,
                            child: Icon(
                              isMinimax
                                  ? Icons.auto_awesome
                                  : Icons.chat_bubble_outline,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              configName,
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: themeColor.shade50,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.03),
                                    blurRadius: 1,
                                    spreadRadius: 0,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              child: Text(
                                isMinimax ? 'MiniMax' : '文本',
                                style: TextStyle(
                                  color: themeColor,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
      ),
      body: Column(
        children: [
          if (widget.conversation.type == ConversationType.xiaozhi)
            _buildXiaozhiInfo(),
          Expanded(child: _buildMessageList()),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildXiaozhiInfo() {
    final configProvider = Provider.of<ConfigProvider>(context);
    final xiaozhiConfig = configProvider.xiaozhiConfigs.firstWhere(
      (config) => config.id == widget.conversation.configId,
      orElse:
          () => XiaozhiConfig(
            id: '',
            name: '未知服务',
            websocketUrl: '',
            macAddress: '',
            token: '',
          ),
    );

    final bool isConnected = _xiaozhiService?.isConnected ?? false;
    final bool isReconnecting = _xiaozhiService?.isReconnecting ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 连接状态指示器
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  isReconnecting
                      ? Colors.orange
                      : (isConnected ? Colors.green : Colors.red),
              boxShadow: [
                BoxShadow(
                  color:
                      (isReconnecting
                              ? Colors.orange
                              : (isConnected ? Colors.green : Colors.red))
                          .withOpacity(0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isReconnecting ? '重连中…' : (isConnected ? '已连接' : '未连接'),
            style: TextStyle(
              fontSize: 13,
              color:
                  isReconnecting
                      ? Colors.orange
                      : (isConnected ? Colors.green : Colors.red),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),

          // 分隔线
          Container(width: 1, height: 16, color: Colors.grey.withOpacity(0.3)),
          const SizedBox(width: 12),

          // WebSocket信息
          Expanded(
            child: Text(
              '${xiaozhiConfig.websocketUrl}',
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          if (xiaozhiConfig.macAddress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 4,
                      spreadRadius: 0,
                      offset: const Offset(0, 1),
                    ),
                    BoxShadow(
                      color: Colors.white.withOpacity(0.9),
                      blurRadius: 3,
                      spreadRadius: 0,
                      offset: const Offset(0, -1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.devices, size: 12, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      '${xiaozhiConfig.macAddress}',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return Consumer<ConversationProvider>(
      builder: (context, provider, child) {
        final messages = provider.getMessages(widget.conversation.id);

        if (messages.isEmpty) {
          return Center(
            child: Text(
              '开始新对话',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
            ),
          );
        }

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          reverse: true,
          itemCount: messages.length + (_isLoading ? 1 : 0),
          cacheExtent: 1000.0,
          addRepaintBoundaries: true,
          addAutomaticKeepAlives: true,
          physics: const ClampingScrollPhysics(),
          itemBuilder: (context, index) {
            if (_isLoading && index == 0) {
              return MessageBubble(
                message: Message(
                  id: 'loading',
                  conversationId: '',
                  role: MessageRole.assistant,
                  content: '思考中...',
                  timestamp: DateTime.now(),
                ),
                isThinking: true,
                conversationType: widget.conversation.type,
              );
            }

            final adjustedIndex = _isLoading ? index - 1 : index;
            final message = messages[messages.length - 1 - adjustedIndex];

            return RepaintBoundary(
              child: MessageBubble(
                key: ValueKey(message.id),
                message: message,
                conversationType: widget.conversation.type,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInputArea() {
    final bool hasText = _textController.text.trim().isNotEmpty;

    // 根据状态决定显示文本输入还是语音输入
    if (_isVoiceInputMode &&
        widget.conversation.type == ConversationType.xiaozhi) {
      return _buildVoiceInputArea();
    } else {
      return _buildTextInputArea(hasText);
    }
  }

  // 文本输入区域
  Widget _buildTextInputArea(bool hasText) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 16,
        top: 16,
        right: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7F9),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.07),
                  blurRadius: 8,
                  spreadRadius: 0,
                  offset: const Offset(0, 3),
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.8),
                  blurRadius: 5,
                  spreadRadius: 0,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: '输入消息...',
                      hintStyle: TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 16,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                    ),
                    style: const TextStyle(
                      color: Color(0xFF1F2937),
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                if (widget.conversation.type == ConversationType.dify &&
                    !hasText)
                  IconButton(
                    icon: const Icon(
                      Icons.add_circle_outline,
                      color: Color(0xFF9CA3AF), // 使用紫色，与小智的麦克风按钮风格一致
                      size: 24,
                    ),
                    onPressed: _showImagePickerOptions,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    constraints: const BoxConstraints(),
                    splashRadius: 22,
                  ),
                _buildSendButton(hasText),
                if (widget.conversation.type == ConversationType.xiaozhi &&
                    !hasText)
                  IconButton(
                    icon: const Icon(
                      Icons.mic,
                      color: Color.fromARGB(255, 108, 108, 112),
                      size: 24,
                    ),
                    onPressed: () {
                      setState(() {
                        _isVoiceInputMode = true;
                      });
                    },
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    constraints: const BoxConstraints(),
                    splashRadius: 22,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 语音输入区域
  Widget _buildVoiceInputArea() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 16,
        top: 16,
        right: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () {
                // 点击即说：再次点击 = 立即结束并发送（静音 N 秒也会自动发送）
                if (_isRecording) {
                  _stopWaveAnimation();
                  _stopRecording();
                } else {
                  _startRecording();
                  _startWaveAnimation();
                }
              },
              // 长按 = 放弃本次录音（不发送）
              onLongPress: () {
                if (_isRecording) {
                  _stopWaveAnimation();
                  _cancelRecording();
                }
              },
              child: Container(
                height: 54,
                decoration: BoxDecoration(
                  color:
                      _isRecording
                          ? Colors.blue.shade50
                          : const Color(0xFFF5F7F9),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.07),
                      blurRadius: 8,
                      spreadRadius: 0,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 波纹动画效果
                    if (_isRecording) _buildWaveAnimationIndicator(),

                    // 文字提示（录音中显示静音倒计时，让「自动发送」可感知）
                    Center(
                      child: Text(
                        _isRecording
                            ? (_vadRemainMs > 0
                                ? "${(_vadRemainMs / 1000).toStringAsFixed(1)}s 后自动发送 · 点击立即发送"
                                : "聆听中… 点击结束并发送")
                            : "点击说话 · 停顿${(AudioUtil.silenceTimeoutMs / 1000).toStringAsFixed(0)}秒自动发送",
                        style: TextStyle(
                          color:
                              _isRecording
                                  ? (_vadRemainMs > 0
                                      ? Colors.orange.shade800
                                      : Colors.blue.shade700)
                                  : const Color.fromARGB(255, 9, 9, 9),
                          fontSize: 15,
                          fontWeight:
                              _isRecording
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 键盘按钮 (切换回文本模式)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  spreadRadius: 0,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.8),
                  blurRadius: 4,
                  spreadRadius: 0,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              shape: CircleBorder(),
              child: InkWell(
                borderRadius: BorderRadius.circular(25),
                onTap: () {
                  // 如果正在录音，先取消录音
                  if (_isRecording) {
                    _cancelRecording();
                    _stopWaveAnimation();
                  }
                  // 切换回文本输入模式
                  setState(() {
                    _isVoiceInputMode = false;
                    _isRecording = false;
                    _isCancelling = false;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Icon(
                    Icons.keyboard,
                    color: Colors.grey.shade700,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSendButton(bool hasText) {
    return IconButton(
      key: const ValueKey('send_button'),
      icon: Icon(
        Icons.send_rounded,
        color: hasText ? Colors.black : const Color(0xFFC4C9D2),
        size: 24,
      ),
      onPressed: hasText ? _sendMessage : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      constraints: const BoxConstraints(),
      splashRadius: 22,
    );
  }

  // 开始录音（点击说话）
  void _startRecording() async {
    if (widget.conversation.type != ConversationType.xiaozhi ||
        _xiaozhiService == null) {
      _showCustomSnackbar('语音功能仅适用于小智对话');
      setState(() {
        _isVoiceInputMode = false;
      });
      return;
    }

    // 标记录音状态（VAD 自动断句依赖此标志）
    setState(() {
      _isRecording = true;
      _isCancelling = false;
      _vadRemainMs = 0;
    });
    _startVadUiTimer();

    // 录音期间暂停全局唤醒监听，避免小智回复语音造成回声误触发
    await WakeWordService().suspend();

    try {
      // 震动反馈
      HapticFeedback.mediumImpact();

      // 开始录音
      await _xiaozhiService!.startListening();
    } catch (e) {
      print('开始录音失败: $e');
      _showCustomSnackbar('无法开始录音: ${e.toString()}');
      setState(() {
        _isRecording = false;
        _isVoiceInputMode = false;
      });
      // 恢复唤醒监听
      await WakeWordService().resume();
    }
  }

  // VAD 静音自动断句回调：等同于松手发送
  void _onVadAutoStop() {
    if (mounted && _isRecording && !_isStopping) {
      _stopRecording();
    }
  }

  // 离线唤醒词命中回调：等同于点击麦克风开始聆听
  void _onWake() async {
    if (!mounted || _isRecording) return;
    print('唤醒词命中，自动开始聆听');

    // 唤醒服务刚释放麦克风，Android 上需要一点时间才能被再次占用，
    // 否则录音会启动失败（表现为「唤醒了但没在听」）。
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted || _isRecording) return;

    // 切换到语音输入模式，让用户看到聆听状态
    if (!_isVoiceInputMode) {
      setState(() => _isVoiceInputMode = true);
    }
    _startRecording();
    _startWaveAnimation();
  }

  // 停止录音并发送
  void _stopRecording() async {
    if (_isStopping) return;
    _isStopping = true;
    _stopVadUiTimer();
    try {
      setState(() {
        _isLoading = true;
        _isRecording = false;
        // 不要立即关闭语音输入模式，让用户可以看到识别结果
        // _isVoiceInputMode = false;
      });

      // 震动反馈
      HapticFeedback.mediumImpact();

      // 停止录音
      await _xiaozhiService?.stopListening();

      _scrollToBottom();
    } catch (e) {
      print('停止录音失败: $e');
      _showCustomSnackbar('语音发送失败: ${e.toString()}');

      // 出错时关闭语音输入模式
      setState(() {
        _isVoiceInputMode = false;
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
      _isStopping = false;
      // 一轮对话结束，恢复全局唤醒监听
      await WakeWordService().resume();
    }
  }

  // 取消录音
  void _cancelRecording() async {
    if (_isStopping) return;
    _isStopping = true;
    _stopVadUiTimer();
    try {
      setState(() {
        _isRecording = false;
      });

      // 震动反馈
      HapticFeedback.heavyImpact();

      // 取消录音
      await _xiaozhiService?.abortListening();

      // 使用自定义的拟物化提示，显示在顶部且带有圆角
      _showCustomSnackbar('已取消发送');
    } catch (e) {
      print('取消录音失败: $e');
    } finally {
      _isStopping = false;
      // 取消后恢复全局唤醒监听
      await WakeWordService().resume();
    }
  }

  // 显示自定义Snackbar
  void _showCustomSnackbar(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final snackBar = SnackBar(
      content: Text(
        message,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black.withOpacity(0.7),
      duration: const Duration(seconds: 2),
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

  void _resetConversation() async {
    // 给用户一个清晰的提示
    _showCustomSnackbar('正在开始新对话...');

    final conversationProvider = Provider.of<ConversationProvider>(
      context,
      listen: false,
    );

    if (widget.conversation.type == ConversationType.minimax) {
      final sessionId = widget.conversation.id;
      _minimaxService?.clearConversation(sessionId);

      await conversationProvider.addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.system,
        content: '--- 开始新对话 ---',
      );

      _showCustomSnackbar('已开始新对话');
    } else if (_difyService != null) {
      // 使用会话的ID作为sessionId，确保与发送消息时使用相同的标识符
      final sessionId = widget.conversation.id;

      // 清除当前会话的conversation_id
      await _difyService!.clearConversation(sessionId);

      // 添加系统消息表明这是一个新对话
      await conversationProvider.addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.system,
        content: '--- 开始新对话 ---',
      );

      _showCustomSnackbar('已开始新对话');
    } else {
      _showCustomSnackbar('配置未设置，无法重置对话');
    }
  }

  void _sendMessage() async {
    final message = _textController.text.trim();
    if (message.isEmpty || _isLoading) return;

    _textController.clear();

    final conversationProvider = Provider.of<ConversationProvider>(
      context,
      listen: false,
    );

    // Add user message
    await conversationProvider.addMessage(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: message,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    _scrollToBottom();

    try {
      if (widget.conversation.type == ConversationType.minimax) {
        if (_minimaxService == null) {
          _initMiniMaxService();
        }

        if (_minimaxService == null) {
          throw Exception("未设置MiniMax配置，请先在设置中配置MiniMax API");
        }

        final sessionId = widget.conversation.id;

        final response = await _minimaxService!.sendMessage(
          message,
          sessionId: sessionId,
          forceNewConversation: false,
        );

        if (!mounted) return;

        await conversationProvider.addMessage(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: response,
        );
      } else if (widget.conversation.type == ConversationType.dify) {
        if (_difyService == null) {
          await _initDifyService();
        }

        if (_difyService == null) {
          throw Exception("未设置Dify配置，请先在设置中配置Dify API");
        }

        // 使用会话的ID作为sessionId，使每次请求保持相同的对话上下文
        final sessionId = widget.conversation.id;

        // 使用阻塞式响应
        final response = await _difyService!.sendMessage(
          message,
          sessionId: sessionId, // 使用一致的会话ID
          // 永远不要在普通消息中使用forceNewConversation，除非用户明确请求开始新对话
          forceNewConversation: false,
        );

        if (!mounted) return; // 再次检查组件是否还在widget树中

        // 添加助手回复
        await conversationProvider.addMessage(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: response,
        );
      } else {
        // 确保服务已连接
        if (_xiaozhiService == null) {
          await _initXiaozhiService();
        } else if (!_xiaozhiService!.isConnected) {
          // 如果未连接，尝试重新连接
          print('聊天屏幕: 服务未连接，尝试重新连接');
          await _xiaozhiService!.connect();

          // 如果重连失败，提示用户
          if (!_xiaozhiService!.isConnected) {
            throw Exception("无法连接到小智服务，请检查网络或服务配置");
          }

          // 刷新UI显示连接状态
          setState(() {});
        }

        // 发送消息
        await _xiaozhiService!.sendTextMessage(message);
      }
    } catch (e) {
      print('聊天屏幕: 发送消息错误: $e');

      if (!mounted) return;

      // Add error message
      await conversationProvider.addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: '发生错误: ${e.toString()}',
      );
    } finally {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _navigateToVoiceCall() {
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);
    final xiaozhiConfig = configProvider.xiaozhiConfigs.firstWhere(
      (config) => config.id == widget.conversation.configId,
    );

    // 导航前停止当前音频播放
    if (_xiaozhiService != null) {
      _xiaozhiService!.stopPlayback();
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => VoiceCallScreen(
              conversation: widget.conversation,
              xiaozhiConfig: xiaozhiConfig,
            ),
      ),
    ).then((_) {
      // 页面返回后，确保重新初始化服务以恢复正常对话功能
      if (_xiaozhiService != null &&
          widget.conversation.type == ConversationType.xiaozhi) {
        // 重新连接服务
        _xiaozhiService!.connect();
      }
    });
  }

  // 启动波形动画
  void _startWaveAnimation() {
    _waveAnimationTimer?.cancel();
    _waveAnimationTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_isRecording && !_isCancelling) {
        setState(() {
          for (int i = 0; i < _waveHeights.length; i++) {
            _waveHeights[i] = 0.5 + _random.nextDouble() * 0.5;
          }
        });
      }
    });
  }

  // 停止波形动画
  void _stopWaveAnimation() {
    _waveAnimationTimer?.cancel();
    _waveAnimationTimer = null;
  }

  // 构建波形动画指示器
  Widget _buildWaveAnimationIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(
          16,
          (index) => AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 3,
            height: 20 * _waveHeights[index],
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.6),
              borderRadius: BorderRadius.circular(1.5),
            ),
            curve: Curves.easeInOut,
          ),
        ),
      ),
    );
  }

  // 显示图片选择器选项
  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      elevation: 20,
      barrierColor: Colors.black.withOpacity(0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖动条
              Container(
                width: 36,
                height: 5,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 1,
                      spreadRadius: 0,
                      offset: const Offset(0, 0.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // 从相册选择选项
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 10,
                        spreadRadius: 0,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withOpacity(0.1),
                              blurRadius: 4,
                              spreadRadius: 0,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.photo_library,
                          color: Colors.blue.shade600,
                          size: 24,
                        ),
                      ),
                      title: const Text(
                        '从相册选择',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      subtitle: Text(
                        '选择已有照片',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _pickImage(true);
                      },
                    ),
                  ),
                ),
              ),

              // 拍照选项
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 10,
                        spreadRadius: 0,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green.withOpacity(0.1),
                              blurRadius: 4,
                              spreadRadius: 0,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.camera_alt,
                          color: Colors.green.shade600,
                          size: 24,
                        ),
                      ),
                      title: const Text(
                        '拍照',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      subtitle: Text(
                        '拍摄新照片',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        _pickImage(false);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickImage(bool fromGallery) async {
    if (widget.conversation.type != ConversationType.dify) {
      _showCustomSnackbar('图片上传功能仅适用于Dify对话');
      return;
    }

    try {
      setState(() {
        _isLoading = true;
      });

      if (_difyService == null) {
        await _initDifyService();
      }

      if (_difyService == null) {
        throw Exception("未设置Dify配置，请先在设置中配置Dify API");
      }

      final ImagePicker picker = ImagePicker();
      final XFile? pickedFile = await picker.pickImage(
        source: fromGallery ? ImageSource.gallery : ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1500,
      );

      if (pickedFile == null) {
        _showCustomSnackbar('已取消选择');
        setState(() {
          _isLoading = false;
        });
        return;
      }

      // 获取应用的文档目录
      final appDir = await getApplicationDocumentsDirectory();
      final conversationDir = Directory(
        '${appDir.path}/conversations/${widget.conversation.id}/images',
      );
      await conversationDir.create(recursive: true);

      // 生成唯一的文件名
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = pickedFile.path.split('.').last;
      final fileName = 'image_$timestamp.$extension';
      final localPath = '${conversationDir.path}/$fileName';

      // 复制图片到永久存储
      final File imageFile = File(pickedFile.path);
      await imageFile.copy(localPath);

      print('图片已保存到永久存储: $localPath');

      final sessionId = widget.conversation.id;

      // 在消息列表中显示用户上传的图片消息
      final conversationProvider = Provider.of<ConversationProvider>(
        context,
        listen: false,
      );

      // 添加用户消息，使用永久存储的路径
      await conversationProvider.addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.user,
        content: "[图片上传中...]",
        isImage: true,
        imageLocalPath: localPath,
      );

      _scrollToBottom();

      // 上传图片到Dify API
      final response = await _difyService!.uploadFile(File(localPath));

      if (response.containsKey('id')) {
        final fileId = response['id'];
        final messageContent = "";

        // 更新最后一条用户消息为实际的图片消息
        await conversationProvider.updateLastUserMessage(
          conversationId: widget.conversation.id,
          content: messageContent,
          fileId: fileId,
          isImage: true,
          imageLocalPath: localPath,
        );

        final textPrompt = "分析这张图片";
        final chatResponse = await _difyService!.sendMessage(
          textPrompt,
          sessionId: sessionId,
          fileIds: [fileId],
        );

        await conversationProvider.addMessage(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: chatResponse,
        );
      } else {
        throw Exception("上传成功但服务器未返回文件ID: $response");
      }

      _showCustomSnackbar('图片上传成功');
    } catch (e) {
      print('图片上传失败: $e');

      final conversationProvider = Provider.of<ConversationProvider>(
        context,
        listen: false,
      );
      await conversationProvider.addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: '图片上传失败: ${e.toString()}',
      );

      _showCustomSnackbar('图片上传失败: ${e.toString()}');
    } finally {
      setState(() {
        _isLoading = false;
      });
      _scrollToBottom();
    }
  }
}
