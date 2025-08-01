import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../services/v2ray_service.dart';

class CloudflareDiagnosticTool {
  static Future<Map<String, dynamic>> runDiagnostics() async {
    final results = <String, dynamic>{};
    
    try {
      // 1. 检查 V2Ray 是否存在
      final v2rayPath = await V2RayService.getExecutablePath(path.join('v2ray', 'v2ray.exe'));
      results['v2rayPath'] = v2rayPath;
      results['v2rayExists'] = await File(v2rayPath).exists();
      
      if (results['v2rayExists']) {
        final v2rayFile = File(v2rayPath);
        results['v2raySize'] = await v2rayFile.length();
        results['v2rayModified'] = (await v2rayFile.lastModified()).toString();
      }
      
      // 2. 检查工作目录
      final workDir = path.dirname(v2rayPath);
      results['workDir'] = workDir;
      results['workDirExists'] = await Directory(workDir).exists();
      
      // 3. 检查网络连接
      results['networkTest'] = await _testNetworkConnection();
      
      // 4. 检查系统信息
      results['platform'] = Platform.operatingSystem;
      results['platformVersion'] = Platform.operatingSystemVersion;
      results['dartVersion'] = Platform.version;
      
      // 5. 测试 Cloudflare 连接
      results['cloudflareTest'] = await _testCloudflareConnection();
      
    } catch (e) {
      results['error'] = e.toString();
    }
    
    return results;
  }
  
  // 测试网络连接
  static Future<Map<String, dynamic>> _testNetworkConnection() async {
    final result = <String, dynamic>{};
    
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 5);
      
      // 测试连接到常见网站
      final testUrls = [
        'https://www.google.com',
        'https://www.cloudflare.com',
        'https://1.1.1.1',
      ];
      
      for (final url in testUrls) {
        try {
          final uri = Uri.parse(url);
          final request = await httpClient.getUrl(uri);
          final response = await request.close();
          await response.drain();
          result[url] = response.statusCode == 200 ? 'OK' : 'Failed (${response.statusCode})';
        } catch (e) {
          result[url] = 'Error: ${e.toString().split('\n').first}';
        }
      }
      
      httpClient.close();
    } catch (e) {
      result['error'] = e.toString();
    }
    
    return result;
  }
  
  // 测试 Cloudflare 连接
  static Future<Map<String, dynamic>> _testCloudflareConnection() async {
    final result = <String, dynamic>{};
    
    try {
      // 测试几个 Cloudflare IP
      final testIps = ['172.67.182.2', '104.21.48.84', '104.25.191.12'];
      
      for (final ip in testIps) {
        try {
          final httpClient = HttpClient();
          httpClient.connectionTimeout = const Duration(seconds: 3);
          
          final uri = Uri(
            scheme: 'https',
            host: ip,
            port: 443,
            path: '/cdn-cgi/trace',
          );
          
          final request = await httpClient.getUrl(uri);
          request.headers.set('Host', 'cloudflare.com');
          
          final startTime = DateTime.now();
          final response = await request.close();
          await response.drain();
          final endTime = DateTime.now();
          
          final latency = endTime.difference(startTime).inMilliseconds;
          
          result[ip] = {
            'status': response.statusCode == 200 ? 'OK' : 'Failed',
            'latency': '${latency}ms',
          };
          
          httpClient.close();
        } catch (e) {
          result[ip] = {
            'status': 'Error',
            'error': e.toString().split('\n').first,
          };
        }
      }
    } catch (e) {
      result['error'] = e.toString();
    }
    
    return result;
  }
  
  // 显示诊断对话框
  static void showDiagnosticDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DiagnosticDialog(),
    );
  }
}

class _DiagnosticDialog extends StatefulWidget {
  @override
  State<_DiagnosticDialog> createState() => _DiagnosticDialogState();
}

class _DiagnosticDialogState extends State<_DiagnosticDialog> {
  Map<String, dynamic>? _diagnosticResults;
  bool _isRunning = true;
  
  @override
  void initState() {
    super.initState();
    _runDiagnostics();
  }
  
  Future<void> _runDiagnostics() async {
    final results = await CloudflareDiagnosticTool.runDiagnostics();
    if (mounted) {
      setState(() {
        _diagnosticResults = results;
        _isRunning = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloudflare 连接诊断'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _isRunning
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在运行诊断...'),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDiagnosticSection('V2Ray 检查'),
                    _buildDiagnosticItem(
                      'v2ray.exe',
                      _diagnosticResults!['v2rayPath'],
                      success: _diagnosticResults!['v2rayExists'] == true,
                    ),
                    if (_diagnosticResults!['v2rayExists'] == true) ...[
                      _buildDiagnosticItem(
                        '文件大小',
                        '${(_diagnosticResults!['v2raySize'] / 1024 / 1024).toStringAsFixed(2)} MB',
                      ),
                      _buildDiagnosticItem(
                        '修改时间',
                        _diagnosticResults!['v2rayModified'],
                      ),
                    ],
                    
                    const Divider(),
                    _buildDiagnosticSection('网络连接测试'),
                    if (_diagnosticResults!['networkTest'] != null)
                      ..._buildNetworkTestResults(_diagnosticResults!['networkTest']),
                    
                    const Divider(),
                    _buildDiagnosticSection('Cloudflare 节点测试'),
                    if (_diagnosticResults!['cloudflareTest'] != null)
                      ..._buildCloudflareTestResults(_diagnosticResults!['cloudflareTest']),
                    
                    const Divider(),
                    _buildDiagnosticSection('系统信息'),
                    _buildDiagnosticItem('操作系统', _diagnosticResults!['platform']),
                    _buildDiagnosticItem('系统版本', _diagnosticResults!['platformVersion']),
                  ],
                ),
              ),
      ),
      actions: [
        if (!_isRunning) ...[
          TextButton(
            onPressed: () {
              setState(() {
                _isRunning = true;
              });
              _runDiagnostics();
            },
            child: const Text('重新诊断'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ],
    );
  }
  
  Widget _buildDiagnosticSection(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).primaryColor,
        ),
      ),
    );
  }
  
  Widget _buildDiagnosticItem(String label, String? value, {bool? success}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (success != null)
            Icon(
              success ? Icons.check_circle : Icons.error,
              size: 16,
              color: success ? Colors.green : Colors.red,
            ),
          if (success != null) const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (value != null)
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade700,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  List<Widget> _buildNetworkTestResults(Map<String, dynamic> networkTest) {
    final widgets = <Widget>[];
    
    networkTest.forEach((url, result) {
      if (url != 'error') {
        final isOk = result.toString().startsWith('OK');
        widgets.add(
          _buildDiagnosticItem(
            url.replaceAll('https://', ''),
            result.toString(),
            success: isOk,
          ),
        );
      }
    });
    
    return widgets;
  }
  
  List<Widget> _buildCloudflareTestResults(Map<String, dynamic> cloudflareTest) {
    final widgets = <Widget>[];
    
    cloudflareTest.forEach((ip, result) {
      if (ip != 'error' && result is Map) {
        final isOk = result['status'] == 'OK';
        final latency = result['latency'] ?? 'N/A';
        widgets.add(
          _buildDiagnosticItem(
            'IP: $ip',
            isOk ? '延迟: $latency' : result['error'] ?? 'Failed',
            success: isOk,
          ),
        );
      }
    });
    
    return widgets;
  }
}
