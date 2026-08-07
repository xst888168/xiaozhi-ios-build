import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/models/dify_config.dart';
import 'package:ai_assistant/models/minimax_config.dart';

class ConfigProvider extends ChangeNotifier {
  List<XiaozhiConfig> _xiaozhiConfigs = [];
  List<DifyConfig> _difyConfigs = [];
  List<MiniMaxConfig> _minimaxConfigs = [];
  bool _isLoaded = false;
  String _clientId = '';

  List<XiaozhiConfig> get xiaozhiConfigs => _xiaozhiConfigs;
  List<DifyConfig> get difyConfigs => _difyConfigs;
  List<MiniMaxConfig> get minimaxConfigs => _minimaxConfigs;
  DifyConfig? get difyConfig =>
      _difyConfigs.isNotEmpty ? _difyConfigs.first : null;
  bool get isLoaded => _isLoaded;
  String get clientId => _clientId;

  /// 当前默认小智配置（取第一个；不存在则返回 null，表示尚未激活）
  XiaozhiConfig? get defaultXiaozhiConfig {
    if (_xiaozhiConfigs.isEmpty) return null;
    return _xiaozhiConfigs.first;
  }

  ConfigProvider() {
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();

    // Load Xiaozhi configs
    final xiaozhiConfigsJson = prefs.getStringList('xiaozhiConfigs') ?? [];
    _xiaozhiConfigs =
        xiaozhiConfigsJson
            .map((json) => XiaozhiConfig.fromJson(jsonDecode(json)))
            .toList();

    // 读取或生成客户端 ID（UUID，用于 OTA 与 WebSocket 握手）
    _clientId = prefs.getString('xiaozhiClientId') ?? '';
    if (_clientId.isEmpty) {
      _clientId = const Uuid().v4();
      await prefs.setString('xiaozhiClientId', _clientId);
    }

    // 首次安装：保持 _xiaozhiConfigs 为空，不要自动创建并持久化默认配置。
    // 这样新装 App 不会一打开就显示“已配置”，用户必须点「获取配置」走激活流程，
    // 服务器返回 websocket/token 后才会真正保存配置。
    if (_xiaozhiConfigs.isNotEmpty) {
      // 兼容旧配置：补全 clientId/otaUrl/protocolVersion
      bool needSave = false;
      for (int i = 0; i < _xiaozhiConfigs.length; i++) {
        final cfg = _xiaozhiConfigs[i];
        if (cfg.clientId.isEmpty || cfg.otaUrl.isEmpty) {
          _xiaozhiConfigs[i] = cfg.copyWith(
            clientId: cfg.clientId.isEmpty ? _clientId : cfg.clientId,
            otaUrl: cfg.otaUrl.isEmpty ? XiaozhiConfig.defaultOtaUrl : cfg.otaUrl,
            protocolVersion: cfg.protocolVersion == 0
                ? XiaozhiConfig.defaultProtocolVersion
                : cfg.protocolVersion,
          );
          needSave = true;
        }
      }
      if (needSave) await _saveConfigs();
    }

    // 加载多个Dify配置
    final difyConfigsJson = prefs.getStringList('difyConfigs') ?? [];
    _difyConfigs =
        difyConfigsJson
            .map((json) => DifyConfig.fromJson(jsonDecode(json)))
            .toList();

    // Load MiniMax configs
    final minimaxConfigsJson = prefs.getStringList('minimaxConfigs') ?? [];
    _minimaxConfigs =
        minimaxConfigsJson
            .map((json) => MiniMaxConfig.fromJson(jsonDecode(json)))
            .toList();

    // 向后兼容：加载旧版单个Dify配置
    final oldDifyConfigJson = prefs.getString('difyConfig');
    if (oldDifyConfigJson != null && _difyConfigs.isEmpty) {
      final oldConfig = DifyConfig.fromJson(jsonDecode(oldDifyConfigJson));
      // 添加ID和名称，转换为新格式
      final updatedConfig = DifyConfig(
        id: const Uuid().v4(),
        name: "默认Dify",
        apiUrl: oldConfig.apiUrl,
        apiKey: oldConfig.apiKey,
      );
      _difyConfigs.add(updatedConfig);

      // 保存为新格式并删除旧数据
      await _saveConfigs();
      await prefs.remove('difyConfig');
    }

    _isLoaded = true;
    notifyListeners();
  }

  Future<void> _saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();

    // Save Xiaozhi configs
    final xiaozhiConfigsJson =
        _xiaozhiConfigs.map((config) => jsonEncode(config.toJson())).toList();
    await prefs.setStringList('xiaozhiConfigs', xiaozhiConfigsJson);

    // 保存多个Dify配置
    final difyConfigsJson =
        _difyConfigs.map((config) => jsonEncode(config.toJson())).toList();
    await prefs.setStringList('difyConfigs', difyConfigsJson);

    // Save MiniMax configs
    final minimaxConfigsJson =
        _minimaxConfigs.map((config) => jsonEncode(config.toJson())).toList();
    await prefs.setStringList('minimaxConfigs', minimaxConfigsJson);
  }

  Future<void> addXiaozhiConfig(
    String name,
    String websocketUrl, {
    String? customMacAddress,
    String? token,
    String? clientId,
    String? otaUrl,
    int? protocolVersion,
  }) async {
    // 如果提供了自定义MAC地址，直接使用；否则使用设备ID生成
    final macAddress = customMacAddress ?? await _getDeviceMacAddress();

    final newConfig = XiaozhiConfig(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      websocketUrl: websocketUrl.isNotEmpty
          ? websocketUrl
          : XiaozhiConfig.defaultWebsocketUrl,
      macAddress: macAddress,
      // 用户填写的 Token 优先；留空则回退官方默认值
      token: (token != null && token.trim().isNotEmpty)
          ? token.trim()
          : XiaozhiConfig.defaultToken,
      clientId: clientId ?? _clientId,
      otaUrl: otaUrl ?? XiaozhiConfig.defaultOtaUrl,
      protocolVersion: protocolVersion ?? XiaozhiConfig.defaultProtocolVersion,
    );

    _xiaozhiConfigs.add(newConfig);
    await _saveConfigs();
    notifyListeners();
  }

  /// 创建一个未激活的默认配置（不保存，仅用于展示或按需持久化）
  XiaozhiConfig createDefaultXiaozhiConfig({String? macAddress}) {
    final mac = macAddress ?? _generateMacFromDeviceId(_clientId);
    return XiaozhiConfig(
      id: const Uuid().v4(),
      name: '小智官方',
      websocketUrl: XiaozhiConfig.defaultWebsocketUrl,
      macAddress: mac,
      token: XiaozhiConfig.defaultToken,
      clientId: _clientId,
      otaUrl: XiaozhiConfig.defaultOtaUrl,
      protocolVersion: XiaozhiConfig.defaultProtocolVersion,
    );
  }

  /// 确保至少存在一条小智官方默认配置（未激活状态，URL/token 为空）。
  /// 仅在用户主动点「获取配置」时调用，避免首次启动就持久化默认配置。
  Future<XiaozhiConfig> ensureDefaultXiaozhiConfig() async {
    if (_xiaozhiConfigs.isNotEmpty) return _xiaozhiConfigs.first;

    final config = createDefaultXiaozhiConfig();
    _xiaozhiConfigs.add(config);
    await _saveConfigs();
    notifyListeners();
    return config;
  }

  /// 重新生成设备身份：新 clientId + 新 MAC，并保存。用于服务器已把当前设备视为
  /// “已绑定”不再发激活码时，让服务器认为是全新设备，重新下发激活码。
  Future<XiaozhiConfig?> regenerateDeviceIdentity() async {
    if (_xiaozhiConfigs.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();

    // 新生成全局 clientId
    _clientId = const Uuid().v4();
    await prefs.setString('xiaozhiClientId', _clientId);

    // 基于新 clientId 生成新 MAC
    final newMac = _generateMacFromDeviceId(_clientId);

    final first = _xiaozhiConfigs.first;
    _xiaozhiConfigs[0] = first.copyWith(
      clientId: _clientId,
      macAddress: newMac,
      websocketUrl: XiaozhiConfig.defaultWebsocketUrl,
      token: XiaozhiConfig.defaultToken,
    );
    await _saveConfigs();
    notifyListeners();
    return _xiaozhiConfigs.first;
  }

  /// 用 OTA 结果更新默认小智配置
  Future<void> updateDefaultXiaozhiFromOta({
    String? websocketUrl,
    String? token,
    String? otaUrl,
  }) async {
    if (_xiaozhiConfigs.isEmpty) return;

    final config = _xiaozhiConfigs.first;
    _xiaozhiConfigs[0] = config.copyWith(
      websocketUrl: (websocketUrl != null && websocketUrl.isNotEmpty)
          ? websocketUrl
          : config.websocketUrl,
      token: (token != null && token.isNotEmpty) ? token : config.token,
      otaUrl: (otaUrl != null && otaUrl.isNotEmpty) ? otaUrl : config.otaUrl,
      clientId: config.clientId.isEmpty ? _clientId : config.clientId,
    );
    await _saveConfigs();
    notifyListeners();
  }

  Future<void> updateXiaozhiConfig(XiaozhiConfig updatedConfig) async {
    final index = _xiaozhiConfigs.indexWhere(
      (config) => config.id == updatedConfig.id,
    );
    if (index != -1) {
      _xiaozhiConfigs[index] = updatedConfig;
      await _saveConfigs();
      notifyListeners();
    }
  }

  Future<void> deleteXiaozhiConfig(String id) async {
    _xiaozhiConfigs.removeWhere((config) => config.id == id);
    await _saveConfigs();
    notifyListeners();
  }

  // 添加Dify配置
  Future<void> addDifyConfig(String name, String apiKey, String apiUrl) async {
    final newConfig = DifyConfig(
      id: const Uuid().v4(),
      name: name,
      apiUrl: apiUrl,
      apiKey: apiKey,
    );

    _difyConfigs.add(newConfig);
    await _saveConfigs();
    notifyListeners();
  }

  // 更新Dify配置
  Future<void> updateDifyConfig(DifyConfig updatedConfig) async {
    final index = _difyConfigs.indexWhere(
      (config) => config.id == updatedConfig.id,
    );
    if (index != -1) {
      _difyConfigs[index] = updatedConfig;
      await _saveConfigs();
      notifyListeners();
    }
  }

  // 删除Dify配置
  Future<void> deleteDifyConfig(String id) async {
    _difyConfigs.removeWhere((config) => config.id == id);
    await _saveConfigs();
    notifyListeners();
  }

  // 添加MiniMax配置
  Future<void> addMiniMaxConfig(
    String name,
    String apiKey, {
    String model = 'MiniMax-M2.7',
  }) async {
    final newConfig = MiniMaxConfig(
      id: const Uuid().v4(),
      name: name,
      apiKey: apiKey,
      model: model,
    );

    _minimaxConfigs.add(newConfig);
    await _saveConfigs();
    notifyListeners();
  }

  // 更新MiniMax配置
  Future<void> updateMiniMaxConfig(MiniMaxConfig updatedConfig) async {
    final index = _minimaxConfigs.indexWhere(
      (config) => config.id == updatedConfig.id,
    );
    if (index != -1) {
      _minimaxConfigs[index] = updatedConfig;
      await _saveConfigs();
      notifyListeners();
    }
  }

  // 删除MiniMax配置
  Future<void> deleteMiniMaxConfig(String id) async {
    _minimaxConfigs.removeWhere((config) => config.id == id);
    await _saveConfigs();
    notifyListeners();
  }

  // 向后兼容的旧方法，设置第一个Dify配置
  Future<void> setDifyConfig(String apiKey, String apiUrl) async {
    if (_difyConfigs.isEmpty) {
      await addDifyConfig("默认Dify", apiKey, apiUrl);
    } else {
      final updated = _difyConfigs.first.copyWith(
        apiKey: apiKey,
        apiUrl: apiUrl,
      );
      await updateDifyConfig(updated);
    }
  }

  // 简化版的设备ID获取方法，不依赖上下文
  Future<String> _getSimpleDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    String deviceId = '';

    try {
      // 简单地尝试获取Android或iOS设备ID，不依赖平台判断
      try {
        final androidInfo = await deviceInfo.androidInfo;
        deviceId = androidInfo.id;
      } catch (_) {
        try {
          final iosInfo = await deviceInfo.iosInfo;
          deviceId = iosInfo.identifierForVendor ?? '';
        } catch (_) {
          final webInfo = await deviceInfo.webBrowserInfo;
          deviceId = webInfo.userAgent ?? '';
        }
      }
    } catch (e) {
      // 出现任何错误，使用时间戳
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    }

    // 如果ID为空，使用时间戳
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
    }

    return deviceId;
  }

  String _generateMacFromDeviceId(String deviceId) {
    final bytes = utf8.encode(deviceId);
    final digest = md5.convert(bytes);
    final hash = digest.toString();

    // Format as MAC address (XX:XX:XX:XX:XX:XX)
    final List<String> macParts = [];
    for (int i = 0; i < 6; i++) {
      macParts.add(hash.substring(i * 2, i * 2 + 2));
    }

    return macParts.join(':');
  }

  // 获取设备MAC地址
  Future<String> _getDeviceMacAddress() async {
    final deviceId = await _getSimpleDeviceId();

    // 如果设备ID本身就是MAC地址格式，直接使用
    if (_isMacAddress(deviceId)) {
      return deviceId;
    }

    // 否则生成一个MAC地址
    return _generateMacFromDeviceId(deviceId);
  }

  // 检查字符串是否是MAC地址格式
  bool _isMacAddress(String str) {
    final macRegex = RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$');
    return macRegex.hasMatch(str);
  }
}
