import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';
import '../providers/server_provider.dart';
import '../providers/connection_provider.dart';
import '../l10n/app_localizations.dart';

class CloudflareTestDialog extends StatefulWidget {
  const CloudflareTestDialog({super.key});

  @override
  State<CloudflareTestDialog> createState() => _CloudflareTestDialogState();
}

class _CloudflareTestDialogState extends State<CloudflareTestDialog> {
  final _formKey = GlobalKey<FormState>();
  // 优化默认参数
  final _countController = TextEditingController(text: '3');       // 默认添加3个
  final _latencyController = TextEditingController(text: '200');   // 降低延迟要求
  final _speedController = TextEditingController(text: '5');       // 提高速度要求
  final _testCountController = TextEditingController(text: '30');  // 适中的测试数量
  
  bool _isLoading = false;
  String _statusMessage = '';
  double _progress = 0.0;

  @override
  void dispose() {
    _countController.dispose();
    _latencyController.dispose();
    _speedController.dispose();
    _testCountController.dispose();
    super.dispose();
  }

  Future<void> _startTest() async {
    if (!_formKey.currentState!.validate()) return;

    final l10n = AppLocalizations.of(context);
    final connectionProvider = context.read<ConnectionProvider>();
    
    if (connectionProvider.isConnected) {
      if (!mounted) return;
      
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.testLatency),
          content: Text(l10n.gettingNodes),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.disconnect), // 使用"断开"作为取消
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.connect), // 使用"连接"作为继续
            ),
          ],
        ),
      ) ?? false;

      if (!shouldContinue) return;

      await connectionProvider.disconnect();
    }

    setState(() {
      _isLoading = true;
      _statusMessage = l10n.preparing;
      _progress = 0.1;
    });

    try {
      // 模拟进度更新
      setState(() {
        _statusMessage = l10n.connectingNodes;
        _progress = 0.3;
      });
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      setState(() {
        _statusMessage = l10n.testingLatency;
        _progress = 0.5;
      });

      final servers = await CloudflareTestService.testServers(
        count: int.parse(_countController.text),
        maxLatency: int.parse(_latencyController.text),
        speed: int.parse(_speedController.text),
        testCount: int.parse(_testCountController.text),
      );

      setState(() {
        _statusMessage = l10n.processingResults;
        _progress = 0.8;
      });

      if (!mounted) return;

      // 为服务器生成友好的名称，创建新的ServerModel实例
      final existingCount = context.read<ServerProvider>().servers
          .where((s) => s.name.startsWith(l10n.cfNode)).length;
      
      final namedServers = <ServerModel>[];
      int index = existingCount + 1;
      for (var server in servers) {
        namedServers.add(ServerModel(
          id: server.id,
          name: '${l10n.cfNode} ${index.toString().padLeft(2, '0')}',
          location: server.location,
          ip: server.ip,
          port: server.port,
          ping: server.ping,
        ));
        index++;
      }

      final serverProvider = context.read<ServerProvider>();
      final addedCount = await serverProvider.addServers(namedServers);

      setState(() {
        _progress = 1.0;
        _statusMessage = '${l10n.testCompleted}！';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;
      Navigator.of(context).pop();
      
      String message;
      if (addedCount == servers.length) {
        message = '${l10n.serverAdded} $addedCount';
      } else if (addedCount > 0) {
        message = '${l10n.serverAdded} $addedCount';
      } else {
        message = l10n.alreadyLatestVersion;
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = '';
        _progress = 0.0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.testFailed}: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading) ...[
              // 进度显示
              const SizedBox(height: 20),
              CircularProgressIndicator(value: _progress),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
            ] else ...[
              // 表单输入
              TextFormField(
                controller: _countController,
                decoration: InputDecoration(
                  labelText: l10n.nodeCount,
                  helperText: '${l10n.nodeCount} (3-5)',
                  prefixIcon: const Icon(Icons.add_circle_outline),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return l10n.operationFailed;
                  final num = int.tryParse(value);
                  if (num == null) return l10n.operationFailed;
                  if (num < 1 || num > 10) return '1-10';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _latencyController,
                decoration: InputDecoration(
                  labelText: l10n.maxLatency,
                  helperText: '${l10n.maxLatency} (ms)',
                  prefixIcon: const Icon(Icons.speed),
                  suffixText: 'ms',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return l10n.operationFailed;
                  final num = int.tryParse(value);
                  if (num == null) return l10n.operationFailed;
                  if (num < 50 || num > 500) return '50-500ms';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _speedController,
                decoration: InputDecoration(
                  labelText: l10n.minSpeed,
                  helperText: '${l10n.minSpeed} (MB/s)',
                  prefixIcon: const Icon(Icons.download),
                  suffixText: 'MB/s',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return l10n.operationFailed;
                  final num = int.tryParse(value);
                  if (num == null) return l10n.operationFailed;
                  if (num < 1 || num > 100) return '1-100MB/s';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _testCountController,
                decoration: InputDecoration(
                  labelText: l10n.testSamples,
                  helperText: l10n.testSamples,
                  prefixIcon: const Icon(Icons.analytics),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return l10n.operationFailed;
                  final num = int.tryParse(value);
                  if (num == null) return l10n.operationFailed;
                  if (num < 10 || num > 100) return '10-100';
                  return null;
                },
              ),
            ],
            const SizedBox(height: 20),
            if (!_isLoading)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.disconnect), // 使用"断开"作为取消
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _startTest,
                    icon: const Icon(Icons.cloud_download),
                    label: Text(l10n.startTest),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}