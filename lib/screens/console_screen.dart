import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/services/wake_word_service.dart';
import 'package:ai_assistant/services/xiaozhi_ota_service.dart';
import 'package:ai_assistant/services/xiaozhi_service.dart';

/// 配置中心（对应截图「配置中心」）
class ConsoleScreen extends StatefulWidget {
  const ConsoleScreen({super.key});

  @override
  State<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends State<ConsoleScreen> {
  late final TextEditingController _otaUrlCtrl;
  late final TextEditingController _deviceIdCtrl;
  late final TextEditingController _clientIdCtrl;
  late final TextEditingController _wsUrlCtrl;
  late final TextEditingController _tokenCtrl;
  late final TextEditingController _protocolCtrl;
  late final TextEditingController _wakeWordsCtrl;
  late final TextEditingController _pythonPathCtrl;
  late final TextEditingController _pythonScriptCtrl;
  late final TextEditingController _workDirCtrl;
  late final TextEditingController _termuxCmdCtrl;
  late final TextEditingController _termuxArgsCtrl;
  late final TextEditingController _mcpPayloadCtrl;

  bool _wakeEnabled = false;
  bool _pythonMcpEnabled = false;
  bool _debugLogEnabled = false;
  bool _ttsExportEnabled = false;
  bool _devToolsExpanded = false;
  bool _isLoading = false;
  String _statusText = '';
  Timer? _connTimer;
  bool _connected = false;
  String _sessionId = '';

  static const int _sampleRate = 16000;
  static const int _frameDuration = 60;

  @override
  void initState() {
    super.initState();
    _otaUrlCtrl = TextEditingController();
    _deviceIdCtrl = TextEditingController();
    _clientIdCtrl = TextEditingController();
    _wsUrlCtrl = TextEditingController();
    _tokenCtrl = TextEditingController();
    _protocolCtrl = TextEditingController();
    _wakeWordsCtrl = TextEditingController(text: '小智小智,你好小智');
    _pythonPathCtrl = TextEditingController(
      text: '/data/data/com.termux/files/usr/bin/python',
    );
    _pythonScriptCtrl = TextEditingController(
      text: '/data/data/com.termux/files/home/mcp_server.py',
    );
    _workDirCtrl = TextEditingController(
      text: '/data/data/com.termux/files/home',
    );
    _termuxCmdCtrl = TextEditingController(
      text: '/data/data/com.termux/files/usr/bin/termux-api',
    );
    _termuxArgsCtrl = TextEditingController();
    _mcpPayloadCtrl = TextEditingController(
      text: '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}',
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadConfig();
      await _loadPrefs();
      _startConnWatcher();
    });
  }

  @override
  void dispose() {
    _connTimer?.cancel();
    _otaUrlCtrl.dispose();
    _deviceIdCtrl.dispose();
    _clientIdCtrl.dispose();
    _wsUrlCtrl.dispose();
    _tokenCtrl.dispose();
    _protocolCtrl.dispose();
    _wakeWordsCtrl.dispose();
    _pythonPathCtrl.dispose();
    _pythonScriptCtrl.dispose();
    _workDirCtrl.dispose();
    _termuxCmdCtrl.dispose();
    _termuxArgsCtrl.dispose();
    _mcpPayloadCtrl.dispose();
    super.dispose();
  }

  void _startConnWatcher() {
    _connTimer?.cancel();
    _connTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final svc = XiaozhiService.instance;
      final now = svc?.isConnected ?? false;
      final sid = svc?.sessionId ?? '';
      if (now != _connected || sid != _sessionId) {
        setState(() {
          _connected = now;
          _sessionId = sid;
        });
      }
    });
  }

  Future<void> _loadConfig() async {
    final provider = Provider.of<ConfigProvider>(context, listen: false);
    final cfg = provider.defaultXiaozhiConfig;
    if (cfg == null) return;
    _otaUrlCtrl.text = cfg.otaUrl;
    _deviceIdCtrl.text = cfg.macAddress;
    _clientIdCtrl.text = cfg.clientId;
    _wsUrlCtrl.text = cfg.websocketUrl;
    _tokenCtrl.text = cfg.token;
    _protocolCtrl.text = cfg.protocolVersion.toString();
    setState(() {});
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _wakeEnabled = prefs.getBool('wake_word_enabled') ?? false;
      _wakeWordsCtrl.text = prefs.getString('wake_word_name') ?? '小智';
      _pythonMcpEnabled = prefs.getBool('python_mcp_enabled') ?? false;
      _debugLogEnabled = prefs.getBool('debug_log_enabled') ?? false;
      _ttsExportEnabled = prefs.getBool('tts_export_enabled') ?? false;
      _pythonPathCtrl.text =
          prefs.getString('python_path') ?? _pythonPathCtrl.text;
      _pythonScriptCtrl.text =
          prefs.getString('python_script') ?? _pythonScriptCtrl.text;
      _workDirCtrl.text = prefs.getString('work_dir') ?? _workDirCtrl.text;
      _termuxCmdCtrl.text =
          prefs.getString('termux_cmd') ?? _termuxCmdCtrl.text;
      _termuxArgsCtrl.text = prefs.getString('termux_args') ?? '';
    });
  }

  Future<void> _saveConfigFromFields() async {
    final provider = Provider.of<ConfigProvider>(context, listen: false);
    final cfg = provider.defaultXiaozhiConfig;
    if (cfg == null) return;
    final updated = cfg.copyWith(
      otaUrl: _otaUrlCtrl.text.trim(),
      macAddress: _deviceIdCtrl.text.trim(),
      clientId: _clientIdCtrl.text.trim(),
      websocketUrl: _wsUrlCtrl.text.trim(),
      token: _tokenCtrl.text.trim(),
      protocolVersion: int.tryParse(_protocolCtrl.text.trim()) ?? 1,
    );
    await provider.updateXiaozhiConfig(updated);
  }

  Future<void> _onFetchConfig() async {
    setState(() => _isLoading = true);
    try {
      final result = await XiaozhiOtaService.fetchConfig(
        deviceId: _deviceIdCtrl.text.trim(),
        clientId: _clientIdCtrl.text.trim(),
        otaUrl: _otaUrlCtrl.text.trim(),
      );
      if (!mounted) return;
      if (result.success) {
        setState(() {
          if (result.websocketUrl != null && result.websocketUrl!.isNotEmpty) {
            _wsUrlCtrl.text = result.websocketUrl!;
          }
          if (result.token != null && result.token!.isNotEmpty) {
            _tokenCtrl.text = result.token!;
          }
        });
        await _saveConfigFromFields();
        _showSnack('获取配置成功');
      } else {
        _showSnack('获取配置失败: ${result.error}');
      }
    } catch (e) {
      _showSnack('获取配置异常: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onConnect() async {
    await _saveConfigFromFields();
    final cfg = Provider.of<ConfigProvider>(context, listen: false)
        .defaultXiaozhiConfig;
    if (cfg == null) return;
    setState(() => _isLoading = true);
    try {
      var svc = XiaozhiService.instance;
      if (svc == null) {
        svc = XiaozhiService(
          websocketUrl: cfg.websocketUrl,
          macAddress: cfg.macAddress,
          token: cfg.token,
          clientId: cfg.clientId,
        );
      }
      await svc.connect();
      if (!mounted) return;
      _showSnack(svc.isConnected ? '连接成功' : '连接失败');
    } catch (e) {
      _showSnack('连接异常: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _onDisconnect() async {
    final svc = XiaozhiService.instance;
    if (svc != null) await svc.disconnect();
    _showSnack('已断开');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    setState(() => _statusText = msg);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _toggleWake(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wake_word_enabled', value);
    setState(() => _wakeEnabled = value);
    if (value) {
      // 保存完整文本（支持逗号/空格分隔多个唤醒词），由 WakeWordService 自行拆分
      final raw = _wakeWordsCtrl.text.trim();
      await prefs.setString('wake_word_name', raw.isEmpty ? '小智' : raw);
      WakeWordService.sensitivity = prefs.getDouble('wake_sensitivity') ?? 0.20;
      await WakeWordService().init(name: raw.isEmpty ? '小智' : raw);
      await WakeWordService().start(force: true);
      // 启动原生前台保活服务：息屏/退后台也能持续监听唤醒词
      if (WakeWordService().isRunning) {
        await WakeWordService.startNativeWakeService();
      }
      _showSnack('语音唤醒已开启');
    } else {
      await WakeWordService().suspend();
      await WakeWordService.stopNativeWakeService();
      _showSnack('语音唤醒已关闭');
    }
  }

  Future<void> _onWakeWordsChanged(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = value.trim();
    await prefs.setString('wake_word_name', raw.isEmpty ? '小智' : raw);
    if (_wakeEnabled && WakeWordService().isInitialized) {
      await WakeWordService().reloadKeywords(raw.isEmpty ? '小智' : raw);
    }
  }

  Future<void> _togglePythonMcp(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('python_mcp_enabled', value);
    setState(() => _pythonMcpEnabled = value);
  }

  Future<void> _saveLocalExt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('python_path', _pythonPathCtrl.text.trim());
    await prefs.setString('python_script', _pythonScriptCtrl.text.trim());
    await prefs.setString('work_dir', _workDirCtrl.text.trim());
    await prefs.setString('termux_cmd', _termuxCmdCtrl.text.trim());
    await prefs.setString('termux_args', _termuxArgsCtrl.text.trim());
    _showSnack('本地扩展设置已保存');
  }

  Future<void> _runPython() async {
    _showSnack('启动本地 Python：${_pythonScriptCtrl.text.trim()}');
    // 实际 Termux 拉起需要原生通道或 url_launcher；此处保留 UI 与持久化。
  }

  Future<void> _runTermuxApi() async {
    _showSnack('执行 termux-api：${_termuxCmdCtrl.text.trim()}');
  }

  Future<void> _toggleDebugLog(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('debug_log_enabled', value);
    setState(() => _debugLogEnabled = value);
  }

  Future<void> _toggleTtsExport(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tts_export_enabled', value);
    setState(() => _ttsExportEnabled = value);
  }

  Future<void> _sendMcp() async {
    final svc = XiaozhiService.instance;
    if (svc == null || !svc.isConnected) {
      _showSnack('请先连接小智服务');
      return;
    }
    try {
      final payload = jsonDecode(_mcpPayloadCtrl.text.trim());
      // 通过现有服务发送 JSON 文本消息；若后端支持 MCP 会处理。
      // svc.sendMessage(payload); // 如需公开方法可解注
      _showSnack('MCP 请求已发送');
    } catch (e) {
      _showSnack('JSON 格式错误: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5F5F7),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black, size: 26),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '配置中心',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle('当前会话'),
                _buildCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  _connected
                                      ? const Color(0xFFDDF5E8)
                                      : const Color(0xFFFFE5E5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _connected ? '已连接' : '连接失败',
                              style: TextStyle(
                                color:
                                    _connected
                                        ? const Color(0xFF2E7D52)
                                        : const Color(0xFFB33A3A),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _sessionId.isEmpty
                                  ? 'Session --'
                                  : 'Session ${_sessionId.substring(0, _sessionId.length > 8 ? 8 : _sessionId.length)}',
                              style: const TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildInfoGrid([
                        _InfoItem('服务器采样率', '$_sampleRate'),
                        _InfoItem('帧时长', '$_frameDuration'),
                        _InfoItem('音频路由', '媒体输出：蓝牙耳机 / 输入：机身麦克风'),
                        _InfoItem('唤醒状态', _wakeEnabled ? '待命中' : '已关闭'),
                      ]),
                    ],
                  ),
                ),
                _buildSectionTitle('官方接入'),
                _buildCard(
                  child: Column(
                    children: [
                      _buildTextField(
                        label: 'OTA 地址',
                        hint: '官方配置入口',
                        icon: Icons.language,
                        ctrl: _otaUrlCtrl,
                      ),
                      _buildTextField(
                        label: '设备 ID',
                        hint: "握手头里的 Device-Id",
                        icon: Icons.devices,
                        ctrl: _deviceIdCtrl,
                      ),
                      _buildTextField(
                        label: '客户端 ID',
                        hint: "握手头里的 Client-Id",
                        icon: Icons.perm_identity,
                        ctrl: _clientIdCtrl,
                      ),
                      _buildTextField(
                        label: 'WebSocket 地址',
                        hint: '官方实时会话地址',
                        icon: Icons.link,
                        ctrl: _wsUrlCtrl,
                      ),
                      _buildTextField(
                        label: '授权 Token',
                        hint: 'OTA 返回的 Bearer Token',
                        icon: Icons.lock,
                        ctrl: _tokenCtrl,
                      ),
                      _buildTextField(
                        label: '协议版本',
                        hint: '官方 WebSocket 二进制协议版本',
                        icon: Icons.format_list_numbered,
                        ctrl: _protocolCtrl,
                        keyboard: TextInputType.number,
                      ),
                      const SizedBox(height: 16),
                      _buildPrimaryButton('获取配置', _onFetchConfig),
                      const SizedBox(height: 12),
                      _buildOutlineButton('连接', _onConnect),
                      const SizedBox(height: 12),
                      _buildOutlineButton('断开', _onDisconnect),
                    ],
                  ),
                ),
                _buildSectionTitle('语音体验'),
                _buildCard(
                  child: Column(
                    children: [
                      _buildSwitchTile(
                        icon: Icons.mic,
                        title: '语音唤醒',
                        subtitle: _wakeEnabled ? '待命中' : '已关闭',
                        value: _wakeEnabled,
                        onChanged: _toggleWake,
                      ),
                      _buildTextField(
                        label: '唤醒词',
                        hint: '多个唤醒词用英文逗号分隔',
                        icon: Icons.record_voice_over,
                        ctrl: _wakeWordsCtrl,
                        onChanged: _onWakeWordsChanged,
                      ),
                      _buildInfoTile(
                        icon: Icons.speaker,
                        title: '当前音频路由',
                        subtitle: '媒体输出：蓝牙耳机 / 输入：机身麦克风',
                      ),
                      _buildInfoTile(
                        icon: Icons.cloud,
                        title: '连接状态',
                        subtitle: _connected ? '已连接' : '未连接',
                      ),
                    ],
                  ),
                ),
                _buildSectionTitle('本地扩展'),
                _buildCard(
                  child: Column(
                    children: [
                      _buildSwitchTile(
                        icon: Icons.code,
                        title: 'Python / MCP 运行入口',
                        subtitle: '已安装，需要在 Termux 打开 allow-external-apps',
                        value: _pythonMcpEnabled,
                        onChanged: _togglePythonMcp,
                      ),
                      _buildTextField(
                        label: 'Python 可执行文件',
                        hint: '推荐使用 Termux 里的 Python',
                        icon: Icons.terminal,
                        ctrl: _pythonPathCtrl,
                      ),
                      _buildTextField(
                        label: 'Python 脚本',
                        hint: '要启动的本地 MCP Python 文件',
                        icon: Icons.description,
                        ctrl: _pythonScriptCtrl,
                      ),
                      _buildTextField(
                        label: '工作目录',
                        hint: '可留空，默认由 Termux 决定',
                        icon: Icons.folder,
                        ctrl: _workDirCtrl,
                      ),
                      _buildActionTile(
                        icon: Icons.play_arrow,
                        title: '启动本地 Python',
                        subtitle: '通过 Termux 拉起脚本，用于本地 MCP 服务',
                        actionLabel: '运行',
                        onTap: _runPython,
                      ),
                      _buildTextField(
                        label: 'Termux API 命令',
                        hint: '缺少 Termux:API 应用',
                        icon: Icons.phone_android,
                        ctrl: _termuxCmdCtrl,
                      ),
                      _buildTextField(
                        label: 'Termux API 参数',
                        hint: '空格分隔，支持引号',
                        icon: Icons.format_quote,
                        ctrl: _termuxArgsCtrl,
                      ),
                      _buildActionTile(
                        icon: Icons.settings,
                        title: '执行 termux-api',
                        subtitle: '例如 termux-battery-status 或 termux-toast',
                        actionLabel: '执行',
                        onTap: _runTermuxApi,
                      ),
                    ],
                  ),
                ),
                _buildSectionTitle('开发者工具'),
                _buildCard(
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '开发者工具',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          '调试日志、TTS 音频导出和 MCP 调试都收在这里',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: TextButton(
                          onPressed:
                              () => setState(
                                () => _devToolsExpanded = !_devToolsExpanded,
                              ),
                          child: Text(_devToolsExpanded ? '收起' : '展开'),
                        ),
                      ),
                      if (_devToolsExpanded) ...[
                        _buildSwitchTile(
                          icon: Icons.bug_report,
                          title: '调试日志',
                          subtitle: '仅在需要排查问题时开启',
                          value: _debugLogEnabled,
                          onChanged: _toggleDebugLog,
                        ),
                        _buildSwitchTile(
                          icon: Icons.headphones,
                          title: 'TTS 音频导出',
                          subtitle: '把播报 PCM 导出为 WAV 文件用于排查',
                          value: _ttsExportEnabled,
                          onChanged: _toggleTtsExport,
                        ),
                        _buildTextField(
                          label: 'MCP 请求',
                          hint: '发送到当前会话的 MCP JSON 负载',
                          icon: Icons.api,
                          ctrl: _mcpPayloadCtrl,
                          maxLines: 4,
                        ),
                        const SizedBox(height: 12),
                        _buildPrimaryButton('发送 MCP', _sendMcp),
                        const SizedBox(height: 12),
                        _buildOutlineButton('清空日志', () {
                          _showSnack('日志已清空');
                        }),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
          if (_isLoading)
            Container(
              color: Colors.black12,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 16, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _buildInfoGrid(List<_InfoItem> items) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      childAspectRatio: 2.0,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      children:
          items.map((item) {
            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F0FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    item.label,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.value,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            );
          }).toList(),
    );
  }

  Widget _buildTextField({
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController ctrl,
    TextInputType keyboard = TextInputType.text,
    int maxLines = 1,
    void Function(String)? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF7E57C2)),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: ctrl,
            keyboardType: keyboard,
            maxLines: maxLines,
            onChanged: onChanged,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF7E57C2)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF7E57C2)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF7E57C2),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF7E57C2)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionLabel,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF7E57C2)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF7E57C2),
              side: const BorderSide(color: Color(0xFF7E57C2)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryButton(String label, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF7E57C2),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(label, style: const TextStyle(fontSize: 15)),
      ),
    );
  }

  Widget _buildOutlineButton(String label, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: _isLoading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF7E57C2),
          side: const BorderSide(color: Color(0xFF7E57C2)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(label, style: const TextStyle(fontSize: 15)),
      ),
    );
  }
}

class _InfoItem {
  final String label;
  final String value;
  _InfoItem(this.label, this.value);
}
