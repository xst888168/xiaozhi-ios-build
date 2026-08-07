import 'package:flutter/services.dart';

/// 语音通话保活服务。
///
/// 通过 MethodChannel 拉起一个「麦克风前台服务 + PARTIAL_WAKE_LOCK」，
/// 让语音通话在息屏 / 锁屏 / 退到后台时仍能持续采集麦克风、CPU 不休眠，
/// 对话不中断。原生实现见 android/.../CallForegroundService.kt。
class CallKeepAlive {
  static const MethodChannel _channel = MethodChannel(
    'com.lhht.ai_assistant/call',
  );

  /// 开始通话保活：前台服务(麦克风类型) + 唤醒锁。
  static Future<void> startCallService() async {
    try {
      await _channel.invokeMethod<void>('startCallService');
    } catch (e) {
      print('CallKeepAlive: 启动通话保活失败(可忽略): $e');
    }
  }

  /// 结束通话保活：释放前台服务与唤醒锁。
  static Future<void> stopCallService() async {
    try {
      await _channel.invokeMethod<void>('stopCallService');
    } catch (e) {
      print('CallKeepAlive: 停止通话保活失败(可忽略): $e');
    }
  }

  /// 把被锁屏/后台的 App 拉回前台。
  static Future<void> bringAppToFront() async {
    try {
      await _channel.invokeMethod<void>('bringToFront');
    } catch (e) {
      print('CallKeepAlive: 拉回前台失败(可忽略): $e');
    }
  }
}
