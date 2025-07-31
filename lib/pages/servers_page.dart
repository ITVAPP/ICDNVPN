import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_app/services/v2ray_service.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'dart:convert';
import '../models/server_model.dart';
import '../providers/connection_provider.dart';
import '../providers/server_provider.dart';
import '../widgets/cloudflare_test_dialog.dart';

class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  bool _isAscending = true;
  bool _isTesting = false;

  static Future<String> _getExecutablePath() async {
    return V2RayService.getExecutablePath('cftest.exe');
  }

  void _addCloudflareServer(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.cloud_download, color: Colors.blue),
            SizedBox(width: 8),
            Text('从Cloudflare添加'),
          ],
        ),
        content: const CloudflareTestDialog(),
      ),
    );
  }

  Future<void> _testAllServersLatency() async {
    final serverProvider = context.read<ServerProvider>();
    if (serverProvider.servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可测试的服务器')),
      );
      return;
    }

    setState(() {
      _isTesting = true;
    });

    // 显示测试进度对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('测试延迟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('正在测试 ${serverProvider.servers.length} 个服务器的延迟...'),
          ],
        ),
      ),
    );

    try {
      // 收集所有服务器的IP地址
      final ips = serverProvider.servers.map((server) => server.ip).join(',');

      // 执行测试命令
      final exePath = await _getExecutablePath();
      
      final process = await Process.start(
        exePath,
        ['-ip', ips],
        workingDirectory: path.dirname(exePath),
        mode: ProcessStartMode.inheritStdio,
      );

      // 等待进程完成
      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw '测试进程退出，错误代码：$exitCode';
      }

      // 读取测试结果
      final resultFile = File(path.join(path.dirname(exePath), 'result.json'));
      if (!await resultFile.exists()) {
        throw '未找到测试结果文件';
      }

      final String jsonContent = await resultFile.readAsString();
      final List<dynamic> results = jsonDecode(jsonContent);

      // 更新服务器延迟
      int updatedCount = 0;
      for (var result in results) {
        final ip = result['ip'];
        final delay = result['delay'];
        final server = serverProvider.servers.firstWhere(
          (server) => server.ip == ip,
          orElse: () => ServerModel(
            id: '',
            name: '',
            location: '',
            ip: '',
            port: 0,
          ),
        );
        if (server.id.isNotEmpty) {
          await serverProvider.updatePing(server.id, delay);
          updatedCount++;
        }
      }

      if (!mounted) return;
      
      // 关闭进度对话框
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('延迟测试完成，更新了 $updatedCount 个服务器')),
      );
    } catch (e) {
      if (!mounted) return;
      
      // 关闭进度对话框
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('测试失败: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTesting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器列表'),
        centerTitle: true,
        actions: [
          // 测试延迟按钮
          IconButton(
            icon: _isTesting 
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Icon(Icons.speed),
            tooltip: '测试延迟',
            onPressed: _isTesting ? null : _testAllServersLatency,
          ),
          // 排序按钮
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: _isAscending ? '延迟从低到高' : '延迟从高到低',
            onPressed: () {
              setState(() {
                _isAscending = !_isAscending;
              });
            },
          ),
          // 从cloudflare添加按钮
          IconButton(
            icon: const Icon(Icons.cloud),
            tooltip: '从Cloudflare添加',
            onPressed: () => _addCloudflareServer(context),
          ),
          // 重置按钮（清空并重新获取）
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'reset') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('重置服务器列表'),
                    content: const Text('这将清空所有服务器并重新从Cloudflare获取，确定继续吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                ) ?? false;

                if (confirm) {
                  await context.read<ServerProvider>().resetServers();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('服务器列表已重置')),
                  );
                }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reset',
                child: Row(
                  children: [
                    Icon(Icons.refresh, color: Colors.red),
                    SizedBox(width: 8),
                    Text('重置服务器列表'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Consumer2<ServerProvider, ConnectionProvider>(
        builder: (context, serverProvider, connectionProvider, child) {
          // 显示初始化进度
          if (serverProvider.isInitializing) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    serverProvider.initMessage,
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '首次运行需要获取可用节点，请稍候...',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          var servers = List<ServerModel>.from(serverProvider.servers);
          if (_isAscending) {
            servers.sort((a, b) => a.ping.compareTo(b.ping));
          } else {
            servers.sort((a, b) => b.ping.compareTo(a.ping));
          }

          if (servers.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.cloud_off,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '暂无服务器',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () => _addCloudflareServer(context),
                    icon: const Icon(Icons.add),
                    label: const Text('添加服务器'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final server = servers[index];
              final isSelected = connectionProvider.currentServer?.id == server.id;
              
              return ServerListItem(
                server: server,
                isSelected: isSelected,
                onTap: () {
                  connectionProvider.setCurrentServer(server);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已选择 ${server.name}'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class ServerListItem extends StatelessWidget {
  final ServerModel server;
  final bool isSelected;
  final VoidCallback onTap;

  const ServerListItem({
    super.key,
    required this.server,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      elevation: isSelected ? 4 : 1,
      color: isSelected ? Theme.of(context).primaryColor.withOpacity(0.1) : null,
      child: Dismissible(
        key: Key(server.id),
        direction: DismissDirection.endToStart,
        confirmDismiss: (direction) async {
          return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('确认删除'),
              content: Text('是否删除服务器 ${server.name}？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('删除'),
                ),
              ],
            ),
          ) ?? false;
        },
        onDismissed: (direction) {
          context.read<ServerProvider>().deleteServer(server.id);
          final connectionProvider = context.read<ConnectionProvider>();
          if (connectionProvider.currentServer?.id == server.id) {
            connectionProvider.setCurrentServer(null);
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除 ${server.name}')),
          );
        },
        background: Container(
          color: Colors.red,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: const Icon(
            Icons.delete,
            color: Colors.white,
          ),
        ),
        child: ListTile(
          onTap: onTap,
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isSelected 
                ? Theme.of(context).primaryColor.withOpacity(0.2)
                : Colors.blue.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.public,
              color: isSelected ? Theme.of(context).primaryColor : Colors.blue,
            ),
          ),
          title: Text(
            server.name,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed,
                    size: 14,
                    color: _getPingColor(server.ping),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${server.ping}ms',
                    style: TextStyle(
                      color: _getPingColor(server.ping),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${server.ip}:${server.port}',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (server.location.isNotEmpty)
                Row(
                  children: [
                    const Icon(Icons.location_on, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      server.location,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.check_circle,
                    color: Colors.green,
                  ),
                ),
              _buildPingIndicator(server.ping),
            ],
          ),
          isThreeLine: true,
        ),
      ),
    );
  }

  Color _getPingColor(int ping) {
    if (ping < 80) return Colors.green;
    if (ping < 150) return Colors.orange;
    return Colors.red;
  }

  Widget _buildPingIndicator(int ping) {
    Color color;
    int bars;

    if (ping < 80) {
      color = Colors.green;
      bars = 3;
    } else if (ping < 150) {
      color = Colors.orange;
      bars = 2;
    } else {
      color = Colors.red;
      bars = 1;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        return Container(
          width: 3,
          height: 8 + (index * 4),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: index < bars ? color : Colors.grey.withOpacity(0.3),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}