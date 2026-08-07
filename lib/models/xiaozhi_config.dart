class XiaozhiConfig {
  final String id;
  final String name;
  final String websocketUrl;
  final String macAddress;
  final String token;
  final String clientId;
  final String otaUrl;
  final int protocolVersion;

  // 不再内置默认 URL/token；首次启动保持未配置状态，强制用户走激活流程。
  static const String defaultWebsocketUrl = '';
  static const String defaultToken = '';
  static const String defaultOtaUrl = 'https://api.tenclass.net/xiaozhi/ota/';
  static const int defaultProtocolVersion = 1;

  /// 是否已完成配置：OTA 返回了非空的 WebSocket 地址和 Token。
  /// 注意：小智官方 OTA 返回的 URL/token 就是 `wss://api.tenclass.net/xiaozhi/v1/`
  /// 与 `test-token`，这些也是有效配置，不能排除。
  bool get isConfigured {
    return websocketUrl.isNotEmpty && token.isNotEmpty;
  }

  /// 是否是占位默认（未激活）配置
  bool get isPlaceholder {
    return websocketUrl.isEmpty && token.isEmpty;
  }

  XiaozhiConfig({
    required this.id,
    required this.name,
    required this.websocketUrl,
    required this.macAddress,
    required this.token,
    this.clientId = '',
    this.otaUrl = defaultOtaUrl,
    this.protocolVersion = defaultProtocolVersion,
  });

  factory XiaozhiConfig.fromJson(Map<String, dynamic> json) {
    return XiaozhiConfig(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      websocketUrl: json['websocketUrl'] ?? defaultWebsocketUrl,
      macAddress: json['macAddress'] ?? '',
      token: json['token'] ?? defaultToken,
      clientId: json['clientId'] ?? '',
      otaUrl: json['otaUrl'] ?? defaultOtaUrl,
      protocolVersion: json['protocolVersion'] ?? defaultProtocolVersion,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'websocketUrl': websocketUrl,
      'macAddress': macAddress,
      'token': token,
      'clientId': clientId,
      'otaUrl': otaUrl,
      'protocolVersion': protocolVersion,
    };
  }

  XiaozhiConfig copyWith({
    String? name,
    String? websocketUrl,
    String? macAddress,
    String? token,
    String? clientId,
    String? otaUrl,
    int? protocolVersion,
  }) {
    return XiaozhiConfig(
      id: id,
      name: name ?? this.name,
      websocketUrl: websocketUrl ?? this.websocketUrl,
      macAddress: macAddress ?? this.macAddress,
      token: token ?? this.token,
      clientId: clientId ?? this.clientId,
      otaUrl: otaUrl ?? this.otaUrl,
      protocolVersion: protocolVersion ?? this.protocolVersion,
    );
  }
}
