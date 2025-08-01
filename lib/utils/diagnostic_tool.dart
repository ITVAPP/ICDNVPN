import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import '../services/v2ray_service.dart';

class CloudflareDiagnosticTool {
  static Future<Map<String, dynamic>> runDiagnostics() async {
    final results = <String, dynamic>{};
    
    try {
      // 1. 检查 cftest.exe 是否存在
      final exePath = await V2RayService.getExecutablePath('cftest.exe');
      results['exePath'] = exePath;
      results['exeExists'] = await File(exePath).exists();
      
      if (results['exeExists']) {
        final exeFile = File(exePath);
        results['exeSize'] = await exeFile.length();
        results['exeModified'] = (await exeFile.lastModified()).toString();
      }
      
      // 2. 检查工作目录
      final workDir = path.dirname(exePath);
      results['workDir'] = workDir;
      results['workDirExists'] = await Directory(workDir).exists();
      
      // 3. 检查 ip.txt 文件
      final ipFilePath = path.join(workDir, 'ip.txt');
      results['ipFilePath'] = ipFilePath;
      results['ipFileExists'] = await File(ipFilePath).exists();
      
      if (results['ipFileExists']) {
        final ipFile = File(ipFilePath);
        results['ipFileSize'] = await ipFile.length();
        final lines = await ipFile.readAsLines();
        results['ipFileLines'] = lines.length;
        
        // 检查前几行内容
        results['ipFileSample'] = lines.take(3).join('\n');
      }
      
      // 4. 检查 result.csv 文件
      final resultPath = path.join(workDir, 'result.csv');
      results['resultFileExists'] = await File(resultPath).exists();
      
      // 5. 检查权限（尝试创建测试文件）
      try {
        final testFile = File(path.join(workDir, 'test_permission.txt'));
        await testFile.writeAsString('test');
        await testFile.delete();
        results['writePermission'] = true;
      } catch (e) {
        results['writePermission'] = false;
        results['permissionError'] = e.toString();
      }
      
      // 6. 尝试运行 cftest.exe -h 获取帮助信息
      if (results['exeExists']) {
        try {
          final helpResult = await Process.run(
            exePath,
            ['-h'],
            workingDirectory: workDir,
            runInShell: true,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          results['helpExitCode'] = helpResult.exitCode;
          results['helpOutput'] = helpResult.stdout.toString();
          results['helpError'] = helpResult.stderr.toString();
          
          // 分析输出以确定正确的参数格式
          final helpText = '${helpResult.stdout}\n${helpResult.stderr}';
          results['supportsFile'] = helpText.contains('-f') || helpText.contains('-file');
          results['supportsOutput'] = helpText.contains('-o');
          results['supportsTl'] = helpText.contains('-tl');
          results['supportsSl'] = helpText.contains('-sl');
        } catch (e) {
          results['helpError'] = e.toString();
        }
      }
      
      // 7. 检查系统信息
      results['platform'] = Platform.operatingSystem;
      results['platformVersion'] = Platform.operatingSystemVersion;
      results['dartVersion'] = Platform.version;
      
    } catch (e) {
      results['error'] = e.toString();
    }
    
    return results;
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
      title: const Text('Cloudflare 测试诊断'),
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
                    _buildDiagnosticSection('可执行文件检查'),
                    _buildDiagnosticItem(
                      'cftest.exe',
                      _diagnosticResults!['exePath'],
                      success: _diagnosticResults!['exeExists'] == true,
                    ),
                    if (_diagnosticResults!['exeExists'] == true) ...[
                      _buildDiagnosticItem(
                        '文件大小',
                        '${(_diagnosticResults!['exeSize'] / 1024 / 1024).toStringAsFixed(2)} MB',
                      ),
                      _buildDiagnosticItem(
                        '修改时间',
                        _diagnosticResults!['exeModified'],
                      ),
                    ],
                    
                    const Divider(),
                    _buildDiagnosticSection('配置文件检查'),
                    _buildDiagnosticItem(
                      'ip.txt',
                      _diagnosticResults!['ipFileExists'] == true ? '存在' : '不存在',
                      success: _diagnosticResults!['ipFileExists'] == true,
                    ),
                    if (_diagnosticResults!['ipFileExists'] == true) ...[
                      _buildDiagnosticItem(
                        'IP行数',
                        '${_diagnosticResults!['ipFileLines']} 行',
                      ),
                      if (_diagnosticResults!['ipFileSample'] != null)
                        _buildCodeBlock('前几行内容', _diagnosticResults!['ipFileSample']),
                    ],
                    
                    const Divider(),
                    _buildDiagnosticSection('权限检查'),
                    _buildDiagnosticItem(
                      '写入权限',
                      _diagnosticResults!['writePermission'] == true ? '正常' : '无权限',
                      success: _diagnosticResults!['writePermission'] == true,
                    ),
                    
                    if (_diagnosticResults!['helpOutput'] != null || 
                        _diagnosticResults!['helpError'] != null) ...[
                      const Divider(),
                      _buildDiagnosticSection('程序输出'),
                      _buildCodeBlock(
                        '帮助信息',
                        _diagnosticResults!['helpOutput']?.toString().isNotEmpty == true
                            ? _diagnosticResults!['helpOutput'].toString()
                            : _diagnosticResults!['helpError'].toString(),
                      ),
                      
                      // 参数支持情况
                      const SizedBox(height: 8),
                      const Text('参数支持:', style: TextStyle(fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          _buildSupportChip('-f', _diagnosticResults!['supportsFile'] ?? false),
                          _buildSupportChip('-o', _diagnosticResults!['supportsOutput'] ?? false),
                          _buildSupportChip('-tl', _diagnosticResults!['supportsTl'] ?? false),
                          _buildSupportChip('-sl', _diagnosticResults!['supportsSl'] ?? false),
                        ],
                      ),
                    ],
                    
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
  
  Widget _buildCodeBlock(String title, String code) {
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
            code,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildSupportChip(String param, bool supported) {
    return Container(
      margin: const EdgeInsets.only(right: 8, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: supported ? Colors.green.shade100 : Colors.red.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            supported ? Icons.check : Icons.close,
            size: 12,
            color: supported ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 4),
          Text(
            param,
            style: TextStyle(
              fontSize: 12,
              color: supported ? Colors.green.shade700 : Colors.red.shade700,
            ),
          ),
        ],
      ),
    );
  }
}
