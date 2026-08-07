import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// OTA 获取配置结果
class XiaozhiOtaResult {
  final bool success;
  final String? error;
  final String? websocketUrl;
  final String? token;
  final String? activationCode;
  final String? activationMessage;
  final Map<String, dynamic>? rawResponse;

  XiaozhiOtaResult({
    required this.success,
    this.error,
    this.websocketUrl,
    this.token,
    this.activationCode,
    this.activationMessage,
    this.rawResponse,
  });

  bool get needsActivation => activationCode != null && activationCode!.isNotEmpty;

  factory XiaozhiOtaResult.error(String message) =>
      XiaozhiOtaResult(success: false, error: message);

  factory XiaozhiOtaResult.success({
    String? websocketUrl,
    String? token,
    String? activationCode,
    String? activationMessage,
    Map<String, dynamic>? rawResponse,
  }) => XiaozhiOtaResult(
        success: true,
        websocketUrl: websocketUrl,
        token: token,
        activationCode: activationCode,
        activationMessage: activationMessage,
        rawResponse: rawResponse,
      );
}

/// 小智官方 OTA 服务
class XiaozhiOtaService {
  static const String defaultOtaUrl = 'https://api.tenclass.net/xiaozhi/ota/';

  /// 向 OTA 服务器请求配置（对齐 me.xiaozhi.androidclient 参考实现）
  static Future<XiaozhiOtaResult> fetchConfig({
    required String deviceId,
    required String clientId,
    String otaUrl = defaultOtaUrl,
    String firmwareVersion = '2.0.0',
    String boardType = 'wifi',
    String boardName = 'xiaozhi-android',
  }) async {
    try {
      final uri = Uri.parse(otaUrl);

      // 构造请求体，对齐 me.xiaozhi.androidclient：
      // application.version + elf_sha256；board.type/name/ssid/rssi/channel/ip/mac。
      // 关键：board.mac 与 Device-Id 头一致，让服务器把该 MAC 当作设备身份。
      final body = jsonEncode({
        'application': {
          'version': firmwareVersion,
          'elf_sha256':
              'c8a8ecb6d6fbcda682494d9675cd1ead240ecf38bdde75282a42365a0e396033',
        },
        'board': {
          'type': boardType,
          'name': boardName,
          'ssid': '',
          'rssi': -55,
          'channel': 1,
          'ip': '192.168.1.11',
          'mac': deviceId,
        },
      });

      print('[XiaozhiOta] POST $otaUrl');
      print('[XiaozhiOta] Device-Id: $deviceId');
      print('[XiaozhiOta] Client-Id: $clientId');

      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Device-Id': deviceId,
              'Client-Id': clientId,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      print('[XiaozhiOta] HTTP ${response.statusCode}');
      print('[XiaozhiOta] BODY ${response.body}');

      if (response.statusCode != 200) {
        return XiaozhiOtaResult.error('OTA 请求失败: HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      if (data is! Map) {
        return XiaozhiOtaResult.error('OTA 返回格式异常');
      }

      if (data.containsKey('error')) {
        return XiaozhiOtaResult.error('OTA 错误: ${data['error']}');
      }

      final websocket = data['websocket'];
      final activation = data['activation'];

      return XiaozhiOtaResult.success(
        websocketUrl: websocket is Map ? websocket['url']?.toString() : null,
        token: websocket is Map ? websocket['token']?.toString() : null,
        activationCode: activation is Map ? activation['code']?.toString() : null,
        activationMessage: activation is Map ? activation['message']?.toString() : null,
        rawResponse: data.cast<String, dynamic>(),
      );
    } on SocketException catch (e) {
      return XiaozhiOtaResult.error('网络错误: $e');
    } on FormatException catch (e) {
      return XiaozhiOtaResult.error('解析失败: $e');
    } catch (e) {
      return XiaozhiOtaResult.error('请求异常: $e');
    }
  }
}
