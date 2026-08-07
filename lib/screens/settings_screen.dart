import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:ai_assistant/utils/audio_util.dart';
import 'package:ai_assistant/providers/theme_provider.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/widgets/settings_section.dart';
import 'package:ai_assistant/services/wake_word_service.dart';
import 'package:ai_assistant/services/xiaozhi_ota_service.dart';
import 'package:ai_assistant/services/xiaozhi_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

// 引入main.dart中定义的常量
import 'package:ai_assistant/main.dart' show enableDebugTools;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _currentTabIndex = 0;

  // 离线唤醒词开关状态
  bool _wakeWordEnabled = false;
  bool _fullDuplexEnabled = true; // 全双工（可打断）开关，默认开启
  bool _wakeWordBusy = false;
  String _wakeWordName = '小智'; // 自定义唤醒名
  double _wakeSensitivity = 0.10; // 唤醒灵敏度阈值（越小越灵敏）
  int _vadSilenceMs = 700; // 静音自动发送时长（默认 700ms；后台可调 400~3000）

  // 唤醒自检状态
  bool _diagRunning = false;
  Timer? _diagTimer;
  double _diagLevel = 0.0;
  int _diagFrames = 0;
  int _diagWakes = 0;

  @override
  void initState() {
    super.initState();
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);

    // 保存Provider引用，以便在dispose中安全使用
    _configProvider = configProvider;

    // 读取离线唤醒词开关
    _loadWakePref();
    _loadWakeName();
    _loadAudioTuning();

    // 初始化选项卡控制器（只保留「通用」与「小智」两个标签页）
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        setState(() {
          _currentTabIndex = _tabController.index;
        });
      }
    });

    // 删除旧的单个配置初始化代码

    // 加载上次获取到的激活码（持久化在设置页，方便查看/复制）
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('otaActivationCode');
      if (mounted && saved != null && saved.isNotEmpty) {
        setState(() => _activationCode = saved);
      }
    });
  }

  // 存储ConfigProvider引用，避免在dispose中访问context
  late final ConfigProvider _configProvider;

  @override
  void dispose() {
    _tabController.dispose();

    // 停止自检定时器；若唤醒未启用则释放麦克风
    _diagTimer?.cancel();
    _diagTimer = null;
    if (_diagRunning && !_wakeWordEnabled) {
      WakeWordService().suspend();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        toolbarHeight: 70,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black, size: 26),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '设置',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: Column(
        children: [
          _buildTabBar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGeneralTab(),
                _buildXiaozhiConfigTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: const Color(0xFFF8F9FA),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0xFFE8E8E8),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 2,
              spreadRadius: 0,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: TabBar(
          controller: _tabController,
          indicator: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          indicatorPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 3,
          ),
          labelPadding: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          indicatorSize: TabBarIndicatorSize.tab,
          labelColor: Colors.black,
          unselectedLabelColor: Colors.grey.shade700,
          dividerColor: Colors.transparent,
          overlayColor: MaterialStateProperty.all(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
          unselectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 16,
          ),
          tabs: const [Tab(text: '通用'), Tab(text: '小智')],
        ),
      ),
    );
  }

  Widget _buildGeneralTab() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCard(
              title: '外观',
              subtitle: '调整应用的外观设置',
              child: Column(
                children: [
                  Consumer<ThemeProvider>(
                    builder: (context, themeProvider, child) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 20,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 24,
                                  height: 24,
                                  child: const Icon(
                                    Icons.dark_mode,
                                    color: Colors.black,
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  '深色模式',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            Switch.adaptive(
                              value: themeProvider.isDarkMode,
                              onChanged: (value) {
                                themeProvider.toggleTheme();
                              },
                              activeColor: Colors.black,
                              inactiveTrackColor: const Color(0xFFE0E0E0),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            _buildCard(
              title: '离线唤醒词',
              subtitle: '自定义唤醒名，说出口即自动开始对话（国语离线模型内置）',
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                '启用离线唤醒',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '完全本地运行，不依赖网络',
                                style: TextStyle(fontSize: 13, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        if (_wakeWordBusy)
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Switch.adaptive(
                            value: _wakeWordEnabled,
                            onChanged: _onToggleWake,
                            activeColor: Colors.black,
                            inactiveTrackColor: const Color(0xFFE0E0E0),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '唤醒名（自定义）',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: TextEditingController(text: _wakeWordName),
                      decoration: InputDecoration(
                        hintText: '例如：小智 / 你好小智 / 老师 / 宝宝',
                        suffixText: '国语',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: _onChangeWakeName,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '建议用 3 个字以上、发音独特的词。2 字唤醒名会自动附加'
                      '「你好XX」「XXXX」两种说法以提高命中率。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),

                    const SizedBox(height: 18),
                    // ---- 灵敏度 ----
                    Row(
                      children: [
                        const Text(
                          '唤醒灵敏度',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _sensitivityLabel(_wakeSensitivity),
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.blue,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _wakeSensitivity,
                      min: 0.10,
                      max: 0.45,
                      divisions: 7,
                      activeColor: Colors.black,
                      label: _sensitivityLabel(_wakeSensitivity),
                      onChanged:
                          (v) => setState(() => _wakeSensitivity = v),
                      onChangeEnd: _onChangeSensitivity,
                    ),
                    const Text(
                      '喊了没反应就往「灵敏」调；容易被电视/说话声误唤醒就往「保守」调。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),

                    const SizedBox(height: 14),
                    // ---- 全双工（可打断）----
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Text(
                                '全双工打断',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                '小智讲话时你可直接插话打断它（豆包式，已默认开启）。'
                                '用本机播放音量估计回声，若误触可在此关闭。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: _fullDuplexEnabled,
                          onChanged: _onToggleFullDuplex,
                          activeColor: Colors.black,
                          inactiveTrackColor: const Color(0xFFE0E0E0),
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),
                    const Divider(height: 1),
                    const SizedBox(height: 14),

                    // ---- 唤醒自检 ----
                    Row(
                      children: [
                        const Text(
                          '唤醒自检',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _toggleWakeDiagnostics,
                          child: Text(_diagRunning ? '停止自检' : '开始自检'),
                        ),
                      ],
                    ),
                    if (_diagRunning) ...[
                      _diagRow(
                        '模型引擎',
                        WakeWordService().profileCount > 0
                            ? '已加载 ${WakeWordService().profileCount} 个'
                            : '未加载（模型缺失）',
                        WakeWordService().profileCount > 0,
                      ),
                      _diagRow(
                        '麦克风',
                        _diagFrames > 0
                            ? '正常，已收到 $_diagFrames 帧'
                            : '没有收到音频数据',
                        _diagFrames > 0,
                      ),
                      _diagRow(
                        '命中次数',
                        '$_diagWakes 次',
                        _diagWakes > 0,
                      ),
                      if (WakeWordService().lastError.isNotEmpty)
                        _diagRow('错误', WakeWordService().lastError, false),
                      const SizedBox(height: 8),
                      const Text(
                        '实时音量（说话时应有明显起伏）',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (_diagLevel / 6000).clamp(0.0, 1.0),
                          minHeight: 8,
                          backgroundColor: const Color(0xFFE8EAED),
                          valueColor: AlwaysStoppedAnimation(
                            _diagLevel > 800
                                ? Colors.green
                                : Colors.blueGrey.shade300,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '当前关键词：\n${WakeWordService().currentKeywords}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '对着手机喊出唤醒名，命中次数会 +1。若音量条有反应但命中始终为 0，'
                        '把灵敏度调高或换一个更长的唤醒名。',
                        style: TextStyle(fontSize: 12, color: Colors.orange),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ---- 语音断句设置 ----
            _buildCard(
              title: '语音断句',
              subtitle: '点击说话后，停顿多久自动发送（位置：主设置页 › 通用）',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '静音自动发送',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${(_vadSilenceMs / 1000).toStringAsFixed(1)} 秒',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.blue,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _vadSilenceMs.toDouble(),
                      min: 400,
                      max: 3000,
                      divisions: 26,
                      activeColor: Colors.black,
                      label: '${(_vadSilenceMs / 1000).toStringAsFixed(1)}s',
                      onChanged:
                          (v) => setState(() => _vadSilenceMs = v.round()),
                      onChangeEnd: _onChangeVadSilence,
                    ),
                    const Text(
                      '说完话停顿这么久就自动发送。可在 0.4~3.0 秒之间自定义。\n'
                      '• 调长（如 1.0~1.5s）：说话中间正常换气/思考不会被误判断句或抢话，更稳。\n'
                      '• 调短（如 0.4~0.7s）：反应更快，但你可能话没说完就被截断。\n'
                      '默认 0.7 秒。录音中随时再点一下按钮可立即发送，长按放弃本次录音。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadWakePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('wake_word_enabled') ?? true;
      final fd = prefs.getBool('full_duplex_enabled') ?? true;
      if (mounted) {
        setState(() {
          _wakeWordEnabled = enabled;
          _fullDuplexEnabled = fd;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadWakeName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString('wake_word_name');
      if (name != null && name.trim().isNotEmpty && mounted) {
        setState(() => _wakeWordName = name.trim());
      }
    } catch (_) {}
  }

  Future<void> _onChangeWakeName(String value) async {
    _wakeWordName = value.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wake_word_name', _wakeWordName);
      // 若已启用，立即用新名字重建关键词
      if (_wakeWordEnabled && WakeWordService().isInitialized) {
        await WakeWordService().reloadKeywords(_wakeWordName);
      }
    } catch (_) {}
  }

  /// 读取灵敏度 / 静音断句时长
  Future<void> _loadAudioTuning() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sens = prefs.getDouble('wake_sensitivity') ?? 0.10;
      final vad = prefs.getInt('vad_silence_ms') ?? 700;
      WakeWordService.sensitivity = sens;
      AudioUtil.applyVadSettings(timeoutMs: vad);
      if (mounted) {
        setState(() {
          _wakeSensitivity = sens;
          _vadSilenceMs = vad;
        });
      }
    } catch (_) {}
  }


  String _sensitivityLabel(double v) {
    if (v <= 0.15) return '很灵敏';
    if (v <= 0.22) return '灵敏';
    if (v <= 0.30) return '标准';
    if (v <= 0.38) return '保守';
    return '很保守';
  }

  Future<void> _onChangeSensitivity(double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('wake_sensitivity', value);
      await WakeWordService().applySensitivity(value);
    } catch (e) {
      print('设置灵敏度失败: $e');
    }
  }

  Future<void> _onChangeVadSilence(double value) async {
    final ms = value.round();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('vad_silence_ms', ms);
      AudioUtil.applyVadSettings(timeoutMs: ms);
    } catch (e) {
      print('设置静音时长失败: $e');
    }
  }

  /// 唤醒自检：启动监听并实时展示麦克风帧数、音量、命中次数
  Future<void> _toggleWakeDiagnostics() async {
    if (_diagRunning) {
      _diagTimer?.cancel();
      _diagTimer = null;
      setState(() => _diagRunning = false);
      // 若唤醒开关本身没打开，自检结束后不要继续占用麦克风
      if (!_wakeWordEnabled) {
        await WakeWordService().suspend();
      }
      return;
    }

    setState(() {
      _diagRunning = true;
      _diagFrames = 0;
      _diagWakes = 0;
      _diagLevel = 0.0;
    });

    if (!WakeWordService().isInitialized) {
      await WakeWordService().init(name: _wakeWordName);
    }
    await WakeWordService().restartForDiagnostics();

    _diagTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() {
        _diagLevel = WakeWordService().lastRms;
        _diagFrames = WakeWordService().frameCount;
        _diagWakes = WakeWordService().wakeCount;
      });
    });
  }

  Widget _diagRow(String label, String value, bool ok) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            size: 16,
            color: ok ? Colors.green : Colors.redAccent,
          ),
          const SizedBox(width: 6),
          Text(
            '$label：',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: ok ? Colors.black87 : Colors.redAccent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _onToggleWake(bool value) async {
    setState(() {
      _wakeWordEnabled = value;
      _wakeWordBusy = true;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('wake_word_enabled', value);
      if (value) {
        await WakeWordService().init(name: _wakeWordName);
        // 必须 force：若此前关过一次开关，_suspended 仍为 true，
        // start() 会被静默忽略，导致唤醒再也起不来。
        await WakeWordService().start(force: true);
        // 启动原生前台保活服务：息屏/退后台也能持续监听唤醒词
        if (mounted && WakeWordService().isRunning) {
          await WakeWordService.startNativeWakeService();
        }
        if (mounted && WakeWordService().lastError.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('唤醒启动失败：${WakeWordService().lastError}')),
          );
        }
      } else {
        await WakeWordService().suspend();
        await WakeWordService.stopNativeWakeService();
      }
    } catch (e) {
      print('切换唤醒词失败: $e');
    } finally {
      if (mounted) setState(() => _wakeWordBusy = false);
    }
  }

  Future<void> _onToggleFullDuplex(bool value) async {
    setState(() => _fullDuplexEnabled = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('full_duplex_enabled', value);
      // 立即对当前/下次语音通话生效（通话中会实时读取该开关）。
      AudioUtil.fullDuplexEnabled = value;
    } catch (e) {
      print('切换全双工失败: $e');
    }
  }


  // ========== 小智配置中心 ==========

  Widget _buildXiaozhiConfigTab() {
    return Consumer<ConfigProvider>(
      builder: (context, configProvider, child) {
        final config = configProvider.defaultXiaozhiConfig;
        if (config == null) {
          // 首次安装或未激活：不显示“已配置”，只展示获取配置入口
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _buildUnconfiguredState(configProvider),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSessionStatusCard(config),
              const SizedBox(height: 20),
              _buildOfficialAccessCard(config, configProvider),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSessionStatusCard(XiaozhiConfig config) {
    final isConfigured = config.isConfigured;
    return _buildCard(
      title: '当前会话',
      subtitle: '连接状态与音频信息',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isConfigured
                        ? const Color(0xFFE8F5E9)
                        : const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    isConfigured ? '已配置' : '未配置',
                    style: TextStyle(
                      color: isConfigured
                          ? const Color(0xFF2E7D32)
                          : const Color(0xFFE65100),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    config.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _buildSessionInfoChip('服务器采样率', '16000'),
                _buildSessionInfoChip('帧时长', '60'),
                _buildSessionInfoChip('音频路由', '机身麦克风'),
                _buildSessionInfoChip('唤醒状态', '待命中'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 首次安装/未激活状态的简化面板：只显示「获取配置」入口，
  /// 避免新装 App 一打开就显示“已配置”。
  Widget _buildUnconfiguredState(ConfigProvider provider) {
    return _buildCard(
      title: '官方接入',
      subtitle: '小智官方服务配置',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.info, color: Colors.orange.shade700, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '未配置：请点击下方「获取配置」取得激活码，并在官网绑定设备',
                      style: TextStyle(fontSize: 13, color: Colors.deepOrange),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _otaBusy
                    ? null
                    : () async {
                        setState(() => _otaBusy = true);
                        try {
                          final config =
                              await provider.ensureDefaultXiaozhiConfig();
                          if (mounted) {
                            setState(() {});
                            await _fetchOtaConfig(provider, config);
                          }
                        } finally {
                          if (mounted) setState(() => _otaBusy = false);
                        }
                      },
                icon: _otaBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.cloud_download, color: Colors.white),
                label: Text(
                  _otaBusy ? '获取配置中...' : '获取配置',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C4DFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            _buildOtaResultCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionInfoChip(String label, String value) {
    return Container(
      width: (MediaQuery.of(context).size.width - 64) / 2 - 6,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfficialAccessCard(
    XiaozhiConfig config,
    ConfigProvider provider,
  ) {
    return _buildCard(
      title: '官方接入',
      subtitle: '小智官方服务配置',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: config.isConfigured
                      ? Colors.green.shade50
                      : Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: config.isConfigured
                        ? Colors.green.shade200
                        : Colors.orange.shade200,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      config.isConfigured ? Icons.check_circle : Icons.info,
                      color: config.isConfigured
                          ? Colors.green.shade700
                          : Colors.orange.shade700,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        config.isConfigured
                            ? '已配置：可点击「连接」开始使用'
                            : '未配置：请先点击下方「获取配置」取得激活码，并在官网绑定设备',
                        style: TextStyle(
                          fontSize: 13,
                          color: config.isConfigured
                              ? Colors.green.shade800
                              : Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _buildConfigTextField(
                icon: Icons.language,
                label: 'OTA 地址',
                hint: '官方配置入口',
                value: config.otaUrl,
                onChanged: (v) => _updateConfig(
                  provider,
                  config.copyWith(otaUrl: v),
                ),
              ),
              _buildConfigTextField(
                icon: Icons.settings_ethernet,
                label: '设备 ID',
                hint: '握手头里的 Device-Id（MAC 地址）',
                value: config.macAddress,
                onChanged: (v) => _updateConfig(
                  provider,
                  config.copyWith(macAddress: v),
                ),
              ),
              _buildConfigTextField(
                icon: Icons.perm_identity,
                label: '客户端 ID',
                hint: '握手头里的 Client-Id',
                value: config.clientId.isEmpty ? provider.clientId : config.clientId,
                onChanged: (v) => _updateConfig(
                  provider,
                  config.copyWith(clientId: v),
                ),
              ),
              _buildConfigTextField(
                icon: Icons.link,
                label: 'WebSocket 地址',
                hint: config.isConfigured
                    ? '官方实时会话地址'
                    : '未配置，获取配置后自动填入',
                value: config.websocketUrl,
                onChanged: (v) => _updateConfig(
                  provider,
                  config.copyWith(websocketUrl: v),
                ),
              ),
              _buildConfigTextField(
                icon: Icons.lock,
                label: '授权 Token',
                hint: config.isConfigured
                    ? 'OTA 返回的 Bearer Token'
                    : '未配置，获取配置后自动填入',
                value: config.token,
                onChanged: (v) => _updateConfig(
                  provider,
                  config.copyWith(token: v),
                ),
              ),
            _buildConfigTextField(
              icon: Icons.confirmation_number,
              label: '协议版本',
              hint: '官方 WebSocket 二进制协议版本',
              value: config.protocolVersion.toString(),
              keyboardType: TextInputType.number,
              onChanged: (v) => _updateConfig(
                provider,
                config.copyWith(protocolVersion: int.tryParse(v) ?? 1),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _otaBusy ? null : () => _fetchOtaConfig(provider, config),
                icon: _otaBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.cloud_download, color: Colors.white),
                label: Text(
                  _otaBusy ? '获取配置中...' : '获取配置',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C4DFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _connectBusy ? null : () => _testConnection(provider, config),
                icon: _connectBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF7C4DFF),
                        ),
                      )
                    : const Icon(Icons.power_settings_new, color: Color(0xFF7C4DFF)),
                label: Text(
                  _connectBusy ? '连接中...' : '连接',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF7C4DFF),
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: TextButton.icon(
                onPressed: _otaBusy ? null : () => _onRegenerateIdentity(provider, config),
                icon: const Icon(Icons.refresh, size: 18, color: Colors.redAccent),
                label: const Text(
                  '重新生成设备身份（换 MAC 重新领激活码）',
                  style: TextStyle(fontSize: 13, color: Colors.redAccent),
                ),
              ),
            ),
            _buildOtaResultCard(),
          ],
        ),
      ),
    );
  }

  bool _otaBusy = false;
  bool _connectBusy = false;

  // OTA 获取结果（持久化显示到设置页，方便查看/复制激活码、排查错误）
  String? _activationCode;
  String? _activationMessage;
  Map<String, dynamic>? _otaRawResponse;
  bool _otaHasError = false;
  String? _otaErrorMsg;

  void _updateConfig(ConfigProvider provider, XiaozhiConfig updated) {
    provider.updateXiaozhiConfig(updated);
  }

  Future<void> _fetchOtaConfig(ConfigProvider provider, XiaozhiConfig config) async {
    setState(() => _otaBusy = true);
    try {
      final result = await XiaozhiOtaService.fetchConfig(
        deviceId: config.macAddress.isEmpty
            ? provider.clientId.replaceAll('-', ':')
            : config.macAddress,
        clientId: config.clientId.isEmpty ? provider.clientId : config.clientId,
        otaUrl: config.otaUrl,
      );

      if (!mounted) return;

      // 持久化保存获取结果，便于在设置页查看/复制激活码、排查错误
      await SharedPreferences.getInstance().then((prefs) async {
        if (result.success && result.needsActivation) {
          _activationCode = result.activationCode;
          _activationMessage = result.activationMessage;
          _otaHasError = false;
          _otaErrorMsg = null;
          _otaRawResponse = result.rawResponse;
          if (_activationCode != null) {
            await prefs.setString('otaActivationCode', _activationCode!);
          }
        } else if (result.success) {
          // 已绑定/已配置：清空旧激活码显示
          _activationCode = null;
          _activationMessage = null;
          _otaHasError = false;
          _otaErrorMsg = null;
          _otaRawResponse = result.rawResponse;
          await prefs.remove('otaActivationCode');
        } else {
          _activationCode = null;
          _otaHasError = true;
          _otaErrorMsg = result.error ?? '未知错误';
          _otaRawResponse = null;
          await prefs.remove('otaActivationCode');
        }
        if (mounted) setState(() {});
      });

      if (result.success && result.needsActivation) {
        _showActivationDialog(result.activationCode, result.activationMessage);
        return;
      }

      if (!result.success) {
        // 用对话框明确弹出错误，避免只闪一下 SnackBar 被忽略
        _showOtaErrorDialog(_otaErrorMsg ?? '未知错误');
        return;
      }

      await provider.updateDefaultXiaozhiFromOta(
        websocketUrl: result.websocketUrl,
        token: result.token,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '配置已更新\n地址：' + (result.websocketUrl ?? '未变'),
          ),
          backgroundColor: Colors.green.shade600,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(10),
        ),
      );
    } finally {
      if (mounted) setState(() => _otaBusy = false);
    }
  }

  /// 重新生成设备身份：服务器把当前 MAC 视为“已绑定”不再发激活码时，换一套新 ID
  /// 让服务器认为是新设备，重新下发 6 位激活码。
  Future<void> _onRegenerateIdentity(ConfigProvider provider, XiaozhiConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Text('重新生成设备身份'),
          ],
        ),
        content: const Text(
          '点击确定后，App 会生成新的 MAC 地址和 Client-ID。\n'
          '这会让小智服务器认为这是一台全新的设备，从而重新下发激活码。\n'
          '旧的绑定关系不会自动解绑，你可能需要在官网删除旧设备。',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定重新生成'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    setState(() => _otaBusy = true);
    try {
      final newConfig = await provider.regenerateDeviceIdentity();
      if (!mounted) return;
      if (newConfig == null) {
        _showOtaErrorDialog('没有可重置的小智配置');
        return;
      }
      // 清掉旧的 OTA 结果显示
      _activationCode = null;
      _activationMessage = null;
      _otaRawResponse = null;
      _otaHasError = false;
      _otaErrorMsg = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('otaActivationCode');
      setState(() {});

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('设备身份已重置，请立即点「获取配置」领取新激活码'),
          backgroundColor: Color(0xFF7C4DFF),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.all(10),
        ),
      );
    } catch (e) {
      if (mounted) _showOtaErrorDialog('重置设备身份失败：$e');
    } finally {
      if (mounted) setState(() => _otaBusy = false);
    }
  }

  Future<void> _testConnection(ConfigProvider provider, XiaozhiConfig config) async {
    if (!config.isConfigured) {
      _showOtaErrorDialog('当前未配置，请先点击下方「获取配置」领取激活码，并在小智官网绑定设备后再连接。');
      return;
    }
    setState(() => _connectBusy = true);
    try {
      final service = XiaozhiService(
        websocketUrl: config.websocketUrl,
        macAddress: config.macAddress.isEmpty
            ? provider.clientId.replaceAll('-', ':')
            : config.macAddress,
        token: config.token,
        clientId: config.clientId.isEmpty ? provider.clientId : config.clientId,
      );
      await service.connect();

      if (!mounted) return;
      if (service.isConnected) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('连接成功'),
            backgroundColor: Colors.green.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.all(10),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('连接失败，请检查网络或 Token'),
            backgroundColor: Colors.red.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.all(10),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('连接异常：' + e.toString()),
          backgroundColor: Colors.red.shade600,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          margin: const EdgeInsets.all(10),
        ),
      );
    } finally {
      if (mounted) setState(() => _connectBusy = false);
    }
  }

  void _showActivationDialog(String? code, String? message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('设备需要激活'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请使用电脑或手机浏览器访问小智官网绑定设备：',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            const Text(
              'https://xiaozhi.me',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF7C4DFF),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '激活码',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    code ?? '',
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 8,
                      color: Color(0xFF7C4DFF),
                    ),
                  ),
                  if (message != null && message.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      message,
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '步骤：先创建/选择一个智能体 → 添加设备 → 输入上方激活码 → 回到 APP 点击「连接」。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code ?? ''));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('激活码已复制'),
                  behavior: SnackBarBehavior.floating,
                  margin: EdgeInsets.all(10),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制激活码'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showOtaErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red),
            SizedBox(width: 8),
            Text('获取配置失败'),
          ],
        ),
        content: SelectableText(
          error,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 设置页常驻的「激活码/获取结果」卡片：满足"把激活码写在设置里"，可复制、可排查
  Widget _buildOtaResultCard() {
    if (_activationCode != null && _activationCode!.isNotEmpty) {
      return Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF3EEFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF7C4DFF).withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('本机激活码（已获取）',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _activationCode!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('激活码已复制'),
                        behavior: SnackBarBehavior.floating,
                        margin: EdgeInsets.all(10),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              _activationCode!,
              style: const TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
                color: Color(0xFF7C4DFF),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '复制后前往 https://xiaozhi.me → 新建/选择智能体 → 添加设备 → 输入此激活码 → 回到本 App 点「连接」。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }
    if (_otaHasError) {
      return Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('获取配置失败',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SelectableText(_otaErrorMsg ?? '未知错误',
                style: const TextStyle(fontSize: 13, color: Colors.red)),
            const SizedBox(height: 6),
            const Text('多为网络无法访问 api.tenclass.net，或设备已被视为已绑定。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }
    if (_otaRawResponse != null) {
      final ws = _otaRawResponse!['websocket'];
      final url = ws is Map ? (ws['url']?.toString() ?? '') : '';
      return Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.green.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.shade200),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('设备已配置（无需激活码）',
                style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('服务器已返回连接配置，说明本机已被视为已绑定。直接点「连接」即可。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            if (url.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText('地址：' + url, style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildConfigTextField({
    Key? key,
    required IconData icon,
    required String label,
    required String hint,
    required String value,
    required ValueChanged<String> onChanged,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: const Color(0xFF7C4DFF)),
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
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: key ?? ValueKey(label + value),
            initialValue: value,
            keyboardType: keyboardType,
            onChanged: onChanged,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
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
                borderSide: const BorderSide(color: Color(0xFF7C4DFF), width: 1.5),
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }
  Widget _buildCard({
    required String title,
    required String subtitle,
    required Widget child,
    Widget? actionButton,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 6,
            spreadRadius: 0,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
                if (actionButton != null) actionButton,
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          child,
        ],
      ),
    );
  }

  void _showAddXiaozhiConfigDialog() {
    final nameController = TextEditingController();
    final websocketUrlController = TextEditingController();
    final tokenController = TextEditingController();
    final macAddressController = TextEditingController();

    showDialog(
      context: context,
      builder:
          (context) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            elevation: 8,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 12,
                    spreadRadius: 0,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '添加小智服务',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.close, size: 22),
                            onPressed: () => Navigator.pop(context),
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '添加新的小智语音服务配置',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '服务名称',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          hintText: '例如：家庭小智',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'WebSocket地址',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: websocketUrlController,
                        decoration: InputDecoration(
                          hintText: '例如：wss://example.com',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'MAC地址 (可选)',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        enabled: true,
                        controller: macAddressController,
                        decoration: InputDecoration(
                          hintText: '留空将自动生成',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '留空将根据设备ID自动生成',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Token',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '默认开启',
                            style: TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: tokenController,
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        final name = nameController.text.trim();
                        final websocketUrl = websocketUrlController.text.trim();
                        final macAddress = macAddressController.text.trim();
                        final token = tokenController.text.trim();

                        if (name.isEmpty || websocketUrl.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('请填写所有必填字段'),
                              backgroundColor: Colors.red.shade600,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              margin: const EdgeInsets.all(10),
                            ),
                          );
                          return;
                        }

                        Provider.of<ConfigProvider>(
                          context,
                          listen: false,
                        ).addXiaozhiConfig(
                          name,
                          websocketUrl,
                          customMacAddress:
                              macAddress.isNotEmpty ? macAddress : null,
                          token: token.isNotEmpty ? token : null,
                        );

                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('小智服务已添加'),
                            backgroundColor: Colors.green.shade600,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            margin: const EdgeInsets.all(10),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 4,
                        shadowColor: Colors.black.withOpacity(0.3),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '添加',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.black,
                        side: const BorderSide(color: Colors.grey),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  void _showEditXiaozhiConfigDialog(XiaozhiConfig config) {
    final nameController = TextEditingController(text: config.name);
    final websocketUrlController = TextEditingController(
      text: config.websocketUrl,
    );
    final macAddressController = TextEditingController(text: config.macAddress);
    final tokenController = TextEditingController(text: config.token);

    showDialog(
      context: context,
      builder:
          (context) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            elevation: 8,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 12,
                    spreadRadius: 0,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '编辑小智服务',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '修改小智语音服务配置',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '服务名称',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: nameController,
                        decoration: InputDecoration(
                          hintText: '例如：家庭小智',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'WebSocket地址',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: websocketUrlController,
                        decoration: InputDecoration(
                          hintText: '例如：wss://example.com',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'MAC地址',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: TextField(
                        controller: macAddressController,
                        enabled: true,
                        decoration: InputDecoration(
                          hintText: '留空将自动生成',
                          hintStyle: TextStyle(color: Colors.grey.shade400),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '留空将根据设备ID自动生成',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Token',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '默认开启',
                            style: TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.03),
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextField(
                        controller: tokenController,
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        final name = nameController.text.trim();
                        final websocketUrl = websocketUrlController.text.trim();
                        final macAddress = macAddressController.text.trim();
                        final token = tokenController.text.trim();

                        if (name.isEmpty || websocketUrl.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text('请填写所有必填字段'),
                              backgroundColor: Colors.red.shade600,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              margin: const EdgeInsets.all(10),
                            ),
                          );
                          return;
                        }

                        final updatedConfig = config.copyWith(
                          name: name,
                          websocketUrl: websocketUrl,
                          macAddress:
                              macAddress.isNotEmpty
                                  ? macAddress
                                  : config.macAddress,
                          token: token.isNotEmpty ? token : config.token,
                        );

                        Provider.of<ConfigProvider>(
                          context,
                          listen: false,
                        ).updateXiaozhiConfig(updatedConfig);

                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('小智服务已更新'),
                            backgroundColor: Colors.green.shade600,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            margin: const EdgeInsets.all(10),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 4,
                        shadowColor: Colors.black.withOpacity(0.3),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '保存',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.black,
                        side: const BorderSide(color: Colors.grey),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  void _showDeleteXiaozhiConfigDialog(XiaozhiConfig config) {
    showDialog(
      context: context,
      builder:
          (context) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 12,
                    spreadRadius: 0,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '删除小智服务',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '确定要删除 ${config.name} 吗？',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () {
                        Provider.of<ConfigProvider>(
                          context,
                          listen: false,
                        ).deleteXiaozhiConfig(config.id);

                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('小智服务已删除'),
                            backgroundColor: Colors.green.shade600,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            margin: const EdgeInsets.all(10),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        elevation: 4,
                        shadowColor: Colors.black.withOpacity(0.3),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '删除',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.black,
                        side: const BorderSide(color: Colors.grey),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }
}
