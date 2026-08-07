import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/screens/chat_screen.dart';

class ConversationTypeScreen extends StatefulWidget {
  const ConversationTypeScreen({super.key});

  @override
  State<ConversationTypeScreen> createState() => _ConversationTypeScreenState();
}

class _ConversationTypeScreenState extends State<ConversationTypeScreen> {
  XiaozhiConfig? _selectedXiaozhiConfig;

  @override
  void initState() {
    super.initState();
    final configs =
        Provider.of<ConfigProvider>(context, listen: false).xiaozhiConfigs;
    if (configs.isNotEmpty) _selectedXiaozhiConfig = configs.first;
  }

  @override
  Widget build(BuildContext context) {
    final xiaozhiConfigs = Provider.of<ConfigProvider>(context).xiaozhiConfigs;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        toolbarHeight: 70,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black, size: 26),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '新建对话',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 8,
                            spreadRadius: 0,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '小智语音对话',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(height: 6),
                                Text(
                                  '选择要连接的小智服务，开始语音对话',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: Color(0xFF757575),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFFEEEEEE)),
                          const SizedBox(height: 16),
                          if (xiaozhiConfigs.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.info_outline,
                                      color: Colors.grey.shade600,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Text(
                                        '还没有小智服务，请先到「设置 → 小智」添加服务配置。',
                                        style: TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            _buildXiaozhiSelectionCard(xiaozhiConfigs),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _buildBottomButton(xiaozhiConfigs),
        ],
      ),
    );
  }

  Widget _buildXiaozhiSelectionCard(List<XiaozhiConfig> configs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildXiaozhiDropdown(configs),
          const SizedBox(height: 16),
          if (_selectedXiaozhiConfig != null)
            _buildXiaozhiDetailsPanel(_selectedXiaozhiConfig!),
        ],
      ),
    );
  }

  Widget _buildXiaozhiDropdown(List<XiaozhiConfig> configs) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            spreadRadius: 0,
            offset: const Offset(0, 3),
          ),
          BoxShadow(
            color: Colors.purple.withOpacity(0.04),
            blurRadius: 12,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(color: Colors.grey.shade200, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<XiaozhiConfig>(
            value: _selectedXiaozhiConfig,
            isExpanded: true,
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.purple,
                size: 24,
              ),
            ),
            iconSize: 24,
            itemHeight: 60,
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(16),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
            items:
                configs.map((XiaozhiConfig config) {
                  return DropdownMenuItem<XiaozhiConfig>(
                    value: config,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.purple.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.mic,
                              color: Colors.purple,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                config.name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black,
                                ),
                              ),
                              Text(
                                config.websocketUrl.split('/').last,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF757575),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
            onChanged: (XiaozhiConfig? newValue) {
              setState(() {
                _selectedXiaozhiConfig = newValue;
              });
            },
          ),
        ),
      ),
    );
  }

  Widget _buildXiaozhiDetailsPanel(XiaozhiConfig config) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            spreadRadius: 0,
            offset: const Offset(0, 3),
          ),
          BoxShadow(
            color: Colors.purple.withOpacity(0.04),
            blurRadius: 12,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
        ],
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.purple.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.purple.withOpacity(0.1),
                      blurRadius: 8,
                      spreadRadius: 0,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.info_outline,
                  color: Colors.purple.shade400,
                  size: 22,
                ),
              ),
              const SizedBox(width: 16),
              const Text(
                '服务详情',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildDetailItemXiaozhi('WebSocket', config.websocketUrl),
          const SizedBox(height: 12),
          _buildDetailItemXiaozhi(
            'MAC地址',
            config.macAddress.isEmpty ? '自动生成' : config.macAddress,
          ),
          const SizedBox(height: 12),
          _buildDetailItemXiaozhi(
            'Token',
            config.token.isEmpty ? 'test-token' : config.token,
          ),
        ],
      ),
    );
  }

  Widget _buildDetailItemXiaozhi(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.purple.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.purple.shade700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomButton(List<XiaozhiConfig> configs) {
    final canCreate = _selectedXiaozhiConfig != null;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        left: 20,
        top: 20,
        right: 20,
        bottom: 20 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: canCreate ? _createConversation : null,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: canCreate ? 4 : 0,
          shadowColor:
              canCreate ? Colors.black.withOpacity(0.3) : Colors.transparent,
        ),
        child: const Text(
          '创建对话',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  void _createConversation() async {
    if (_selectedXiaozhiConfig == null) return;
    final config = _selectedXiaozhiConfig!;
    final conversation = await Provider.of<ConversationProvider>(
      context,
      listen: false,
    ).createConversation(
      title: '与 ${config.name} 的对话',
      type: ConversationType.xiaozhi,
      configId: config.id,
    );

    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(conversation: conversation),
        ),
      );
    }
  }
}
