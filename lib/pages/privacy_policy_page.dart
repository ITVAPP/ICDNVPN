import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../app_config.dart';
import '../utils/log_service.dart';

/// 隐私政策章节
class PolicySection {
  final String title;
  final String content;

  PolicySection({
    required this.title,
    required this.content,
  });

  factory PolicySection.fromJson(Map<String, dynamic> json) {
    return PolicySection(
      title: json['title'] ?? '',
      content: json['content'] ?? '',
    );
  }
}

/// 隐私政策数据
class PrivacyPolicyData {
  final String title;
  final List<PolicySection> sections;
  final String? lastUpdated;
  final String? version;

  PrivacyPolicyData({
    required this.title,
    required this.sections,
    this.lastUpdated,
    this.version,
  });

  factory PrivacyPolicyData.fromJson(Map<String, dynamic> json, String locale) {
    // 获取对应语言的政策内容，如果没有则使用中文
    final policies = json['policies'] as Map<String, dynamic>?;
    final policyData = policies?[locale] ?? policies?['zh_CN'] ?? {};
    
    return PrivacyPolicyData(
      title: policyData['title'] ?? '隐私政策',
      sections: (policyData['sections'] as List<dynamic>?)
              ?.map((s) => PolicySection.fromJson(s))
              .toList() ??
          [],
      lastUpdated: json['lastUpdated'],
      version: json['version'],
    );
  }
}

/// 隐私政策页面
class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({super.key});

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage> {
  static const String _logTag = 'PrivacyPolicyPage';
  static final LogService _log = LogService.instance;
  
  bool _isLoading = true;
  PrivacyPolicyData? _policyData;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPrivacyPolicy();
  }

  /// 加载隐私政策
  Future<void> _loadPrivacyPolicy() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      String jsonStr;
      
      // 判断是本地还是远程
      if (AppConfig.privacyPolicyUrl.startsWith('assets/')) {
        // 本地文件
        jsonStr = await rootBundle.loadString(AppConfig.privacyPolicyUrl);
      } else {
        // 远程API
        final response = await http.get(
          Uri.parse(AppConfig.privacyPolicyUrl),
          headers: {'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 10));
        
        if (response.statusCode != 200) {
          throw Exception('加载失败: ${response.statusCode}');
        }
        
        jsonStr = response.body;
      }
      
      // 解析JSON
      final json = jsonDecode(jsonStr);
      
      // 获取当前语言
      final locale = Localizations.localeOf(context);
      final localeString = '${locale.languageCode}_${locale.countryCode ?? locale.languageCode.toUpperCase()}';
      
      // 解析政策数据
      final policyData = PrivacyPolicyData.fromJson(json, localeString);
      
      if (mounted) {
        setState(() {
          _policyData = policyData;
          _isLoading = false;
        });
      }
    } catch (e) {
      await _log.error('加载隐私政策失败', tag: _logTag, error: e);
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(_policyData?.title ?? '隐私政策'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }
    
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red[400],
            ),
            const SizedBox(height: 16),
            Text(
              '加载失败',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.red[700],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadPrivacyPolicy,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    
    if (_policyData == null || _policyData!.sections.isEmpty) {
      return const Center(
        child: Text('暂无内容'),
      );
    }
    
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 版本和更新时间信息
        if (_policyData!.version != null || _policyData!.lastUpdated != null)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: isDark 
                  ? const Color(0xFF1E1E1E)
                  : Colors.grey[100],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.grey[300]!,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_policyData!.version != null)
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).hintColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '版本: ${_policyData!.version}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                if (_policyData!.lastUpdated != null)
                  Row(
                    children: [
                      Icon(
                        Icons.update,
                        size: 16,
                        color: Theme.of(context).hintColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '更新: ${_policyData!.lastUpdated}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        
        // 政策章节
        ..._policyData!.sections.map((section) => _buildSection(section, isDark)),
      ],
    );
  }

  Widget _buildSection(PolicySection section, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark 
            ? const Color(0xFF1E1E1E)
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withOpacity(0.2)
                : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 章节标题
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: Theme.of(context).primaryColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  section.title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? Colors.white
                        : Theme.of(context).textTheme.titleLarge?.color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 章节内容
          Text(
            section.content,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: isDark
                  ? Colors.white.withOpacity(0.8)
                  : Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ],
      ),
    );
  }
}