import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/cloudflare_test_service.dart';
import '../providers/server_provider.dart';
import '../providers/connection_provider.dart';

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

    final connectionProvider = context.read<ConnectionProvider>();
    if (connectionProvider.isConnected) {
      if (!mounted) return;
      
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('警告'),
          content: const Text('测试前需要断开当前连接，是否继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      ) ?? false;

      if (!shouldContinue) return;

      await connectionProvider.disconnect();
    }

    setState(() {
      _isLoading = true;
      _statusMessage = '正在准备测试...';
      _progress = 0.1;
    });

    try {
      // 模拟进度更新
      setState(() {
        _statusMessage = '正在连接Cloudflare节点...';
        _progress = 0.3;
      });
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      setState(() {
        _statusMessage = '正在测试节点延迟...';
        _progress = 0.5;
      });

      final servers = await CloudflareTestService.testServers(
        count: int.parse(_countController.text),
        maxLatency: int.parse(_latencyController.text),
        speed: int.parse(_speedController.text),
        testCount: int.parse(_testCountController.text),
      );

      setState(() {
        _statusMessage = '正在处理测试结果...';
        _progress = 0.8;
      });

      if (!mounted) return;

      // 为服务器生成友好的名称，创建新的ServerModel实例
      final existingCount = context.read<ServerProvider>().servers
          .where((s) => s.name.startsWith('CF节点')).length;
      
      final namedServers = <ServerModel>[];
      int index = existingCount + 1;
      for (var server in servers) {
        namedServers.add(ServerModel(
          id: server.id,
          name: 'CF节点 ${index.toString().padLeft(2, '0')}',
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
        _statusMessage = '测试完成！';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;
      Navigator.of(context).pop();
      
      String message;
      if (addedCount == servers.length) {
        message = '成功添加 $addedCount 个新节点';
      } else if (addedCount > 0) {
        message = '添加了 $addedCount 个新节点，${servers.length - addedCount} 个节点已存在';
      } else {
        message = '所有节点已存在，已更新延迟信息';
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
        SnackBar(content: Text('测试失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
                decoration: const InputDecoration(
                  labelText: '添加数量',
                  helperText: '要添加的节点数量（建议3-5个）',
                  prefixIcon: Icon(Icons.add_circle_outline),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入数量';
                  final num = int.tryParse(value);
                  if (num == null) return '请输入有效数字';
                  if (num < 1 || num > 10) return '数量应在1-10之间';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _latencyController,
                decoration: const InputDecoration(
                  labelText: '延迟上限',
                  helperText: '最大可接受延迟（毫秒）',
                  prefixIcon: Icon(Icons.speed),
                  suffixText: 'ms',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入延迟上限';
                  final num = int.tryParse(value);
                  if (num == null) return '请输入有效数字';
                  if (num < 50 || num > 500) return '延迟应在50-500ms之间';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _speedController,
                decoration: const InputDecoration(
                  labelText: '最低网速',
                  helperText: '最低下载速度要求',
                  prefixIcon: Icon(Icons.download),
                  suffixText: 'MB/s',
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入网速要求';
                  final num = int.tryParse(value);
                  if (num == null) return '请输入有效数字';
                  if (num < 1 || num > 100) return '网速应在1-100MB/s之间';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _testCountController,
                decoration: const InputDecoration(
                  labelText: '测试样本数',
                  helperText: '测试IP数量（越多越准确但耗时更长）',
                  prefixIcon: Icon(Icons.analytics),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入测试次数';
                  final num = int.tryParse(value);
                  if (num == null) return '请输入有效数字';
                  if (num < 10 || num > 100) return '测试次数应在10-100之间';
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
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _startTest,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('开始测试'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}