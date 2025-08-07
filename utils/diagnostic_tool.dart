import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../services/v2ray_service.dart';
import '../l10n/app_localizations.dart';

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
      
      // 3. 检查 ip.txt 文件
      final exePath = Platform.resolvedExecutable;
      final appDir = path.dirname(exePath);
      final ipFilePath = path.join(appDir, 'ip.txt');
      results['ipFilePath'] = ipFilePath;
      results['ipFileExists'] = await File(ipFilePath).exists();
      
      if (results['ipFileExists']) {
        final ipFile = File(ipFilePath);
        results['ipFileSize'] = await ipFile.length();
        final lines = await ipFile.readAsLines();
        
        // 统计有效的 IP 段数量
        int validIpRanges = 0;
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
            validIpRanges++;
          }
        }
        results['ipFileLines'] = lines.length;
        results['validIpRanges'] = validIpRanges;
        
        // 显示前几个 IP 段
        final sampleRanges = <String>[];
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
            sampleRanges.add(trimmed);
            if (sampleRanges.length >= 3) break;
          }
        }
        results['ipFileSample'] = sampleRanges.join('\n');
      }
      
      // 4. 检查网络连接
      results['networkTest'] = await _testNetworkConnection();
      
      // 5. 检查系统信息
      results['platform'] = Platform.operatingSystem;
      results['platformVersion'] = Platform.operatingSystemVersion;
      results['dartVersion'] = Platform.version;
      
      // 6. 测试 Cloudflare 连接
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
    final l10n = AppLocalizations.of(context);
    
    return AlertDialog(
      title: Text(l10n.diagnosticTool),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _isRunning
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.runDiagnostics),
                ],
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDiagnosticSection(l10n.fileCheck),
                    _buildDiagnosticItem(
                      'v2ray.exe',
                      _diagnosticResults!['v2rayPath'],
                      success: _diagnosticResults!['v2rayExists'] == true,
                    ),
                    if (_diagnosticResults!['v2rayExists'] == true) ...[
                      _buildDiagnosticItem(
                        l10n.size,
                        '${(_diagnosticResults!['v2raySize'] / 1024 / 1024).toStringAsFixed(2)} MB',
                      ),
                      _buildDiagnosticItem(
                        l10n.modified,
                        _diagnosticResults!['v2rayModified'],
                      ),
                    ],
                    
                    const Divider(),
                    _buildDiagnosticSection(l10n.config),
                    _buildDiagnosticItem(
                      'ip.txt',
                      _diagnosticResults!['ipFileExists'] == true ? 'OK' : l10n.missing,
                      success: _diagnosticResults!['ipFileExists'] == true,
                    ),
                    if (_diagnosticResults!['ipFileExists'] == true) ...[
                      _buildDiagnosticItem(
                        l10n.ipRangesCount,
                        '${_diagnosticResults!['validIpRanges']}',
                      ),
                      if (_diagnosticResults!['ipFileSample'] != null)
                        _buildCodeBlock(l10n.sample, _diagnosticResults!['ipFileSample']),
                    ],
                    
                    const Divider(),
                    _buildDiagnosticSection(l10n.networkTest),
                    if (_diagnosticResults!['networkTest'] != null)
                      ..._buildNetworkTestResults(_diagnosticResults!['networkTest']),
                    
                    const Divider(),
                    _buildDiagnosticSection(l10n.cloudflareTest),
                    if (_diagnosticResults!['cloudflareTest'] != null)
                      ..._buildCloudflareTestResults(_diagnosticResults!['cloudflareTest']),
                    
                    const Divider(),
                    _buildDiagnosticSection(l10n.systemInfo),
                    _buildDiagnosticItem(l10n.os, _diagnosticResults!['platform']),
                    _buildDiagnosticItem(l10n.version, _diagnosticResults!['platformVersion']),
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
            child: Text(l10n.refresh),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
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
    final l10n = AppLocalizations.of(context);
    
    cloudflareTest.forEach((ip, result) {
      if (ip != 'error' && result is Map) {
        final isOk = result['status'] == 'OK';
        final latency = result['latency'] ?? 'N/A';
        widgets.add(
          _buildDiagnosticItem(
            'IP: $ip',
            isOk ? '${l10n.latency}: $latency' : result['error'] ?? l10n.failed,
            success: isOk,
          ),
        );
      }
    });
    
    return widgets;
  }
  
  Widget _buildCodeBlock(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            content,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}