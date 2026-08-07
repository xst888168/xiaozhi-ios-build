import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/screens/chat_screen.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/services/wake_word_service.dart';

/// 全局唤醒路由：让"离线唤醒词"在任意界面（含息屏 / 锁屏后回到首页）都能
/// 打开最近的小智会话并自动开始聆听，而不是只能在聊天页才生效。
///
/// 设计：聊天页 [ChatScreen] 在前台时会临时把 [WakeWordService.onWake] 覆盖为
/// 自己的 [_onWake]（直接在本会话里聆听）；离开聊天页时再恢复为 [globalWake]，
/// 保证离开后唤醒依旧可用。
class WakeRouter {
  /// 全局导航键，由 main 注入到 MaterialApp，用于在唤醒时跳转。
  static GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// 全局兜底唤醒回调：当前不在聊天页时，打开最近的小智会话并自动聆听。
  static void globalWake() {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    final ctx = nav.context;
    try {
      final convProvider = Provider.of<ConversationProvider>(ctx, listen: false);
      final xiaozhi = convProvider.conversations
          .where((c) => c.type == ConversationType.xiaozhi)
          .toList();
      if (xiaozhi.isEmpty) {
        // 没有小智会话：至少把 App 提到前台，让用户可见
        WakeWordService.bringAppToFront();
        return;
      }
      xiaozhi.sort((a, b) => b.lastMessageTime.compareTo(a.lastMessageTime));
      // 若当前已在对应聊天页，则交给聊天页自己的 onWake 处理，避免重复跳转
      nav.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(conversation: xiaozhi.first, autoListen: true),
        ),
      );
    } catch (e) {
      print('WakeRouter: 全局唤醒跳转失败: $e');
    }
  }

  /// 在 main 中调用一次：绑定全局兜底唤醒回调。
  static void init() {
    WakeWordService().onWake = globalWake;
  }
}
