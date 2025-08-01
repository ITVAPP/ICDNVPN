import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/cloudflare_test_service.dart';
import '../models/server_model.dart';
import '../providers/connection_provider.dart';
import '../providers/server_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/cloudflare_test_dialog.dart';
import '../l10n/app_localizations.dart';
import '../utils/location_utils.dart';
import '../utils/ui_utils.dart';

class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  bool _isAscending = true;
  bool _isTesting = false;

  void _addCloudflareServer(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.cloud_download, color: Colors.blue),
            const SizedBox(width: 8),
            Text(l10n.addFromCloudflare),
          ],
        ),
        content: const CloudflareTestDialog(),
      ),
    );
  }

  Future<void> _testAllServersLatency() async {
    final l10n = AppLocalizations.of(context);
    final serverProvider = context.read<ServerProvider>();
    
    if (serverProvider.servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.noServers)),
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
        title: Text(l10n.testLatency),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('${l10n.testing} ${serverProvider.servers.length} ${l10n.servers.toLowerCase()}...'),
          ],
        ),
      ),
    );

    try {
      // 收集所有服务器的IP地址
      final ips = serverProvider.servers.map((server) => server.ip).toList();

      // 使用 CloudflareTestService 的 testLatency 方法
      final latencyMap = await CloudflareTestService.testLatency(ips);

      // 更新服务器延迟
      int updatedCount = 0;
      for (final server in serverProvider.servers) {
        final latency = latencyMap[server.ip];
        if (latency != null) {
          await serverProvider.updatePing(server.id, latency);
          updatedCount++;
        }
      }

      if (!mounted) return;
      
      // 关闭进度对话框
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.testCompleted}，${l10n.refresh} $updatedCount ${l10n.servers.toLowerCase()}')),
      );
    } catch (e) {
      if (!mounted) return;
      
      // 关闭进度对话框
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.testFailed}: $e')),
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
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serverList),
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
            tooltip: l10n.testLatency,
            onPressed: _isTesting ? null : _testAllServersLatency,
          ),
          // 排序按钮
          IconButton(
            icon: Icon(
              _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
            ),
            tooltip: _isAscending ? l10n.sortAscending : l10n.sortDescending,
            onPressed: () {
              setState(() {
                _isAscending = !_isAscending;
              });
            },
          ),
          // 从cloudflare添加按钮
          IconButton(
            icon: const Icon(Icons.cloud),
            tooltip: l10n.fromCloudflare,
            onPressed: () => _addCloudflareServer(context),
          ),
          // 更多选项
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'reset') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l10n.resetServerList),
                    content: Text(l10n.confirmReset),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(l10n.disconnect),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        child: Text(l10n.confirmDelete),
                      ),
                    ],
                  ),
                ) ?? false;

                if (confirm) {
                  await context.read<ServerProvider>().resetServers();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.allServersDeleted)),
                  );
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'reset',
                child: Row(
                  children: [
                    const Icon(Icons.refresh, color: Colors.red),
                    const SizedBox(width: 8),
                    Text(l10n.resetServerList),
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
                  Text(
                    l10n.gettingNodes,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
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
                  Icon(
                    Icons.cloud_off,
                    size: 80,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.noServers,
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _addCloudflareServer(context),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.addServer),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
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
              final isConnected = connectionProvider.isConnected && isSelected;
              
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: ServerListItem(
                  server: server,
                  isSelected: isSelected,
                  isConnected: isConnected,
                  onTap: () {
                    connectionProvider.setCurrentServer(server);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('${l10n.selectServer} ${server.name}'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  onDelete: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(l10n.confirmDelete),
                        content: Text('${l10n.confirmDelete} ${server.name}？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(l10n.disconnect),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: Text(l10n.deleteServer),
                          ),
                        ],
                      ),
                    ) ?? false;

                    if (confirm) {
                      serverProvider.deleteServer(server.id);
                      if (connectionProvider.currentServer?.id == server.id) {
                        connectionProvider.setCurrentServer(null);
                      }
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${l10n.serverDeleted} ${server.name}')),
                      );
                    }
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ServerListItem extends StatefulWidget {
  final ServerModel server;
  final bool isSelected;
  final bool isConnected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const ServerListItem({
    super.key,
    required this.server,
    required this.isSelected,
    required this.isConnected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<ServerListItem> createState() => _ServerListItemState();
}

class _ServerListItemState extends State<ServerListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.98,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final locationInfo = LocationUtils.getLocationInfo(widget.server.location);
    
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTapDown: (_) => _animationController.forward(),
        onTapUp: (_) => _animationController.reverse(),
        onTapCancel: () => _animationController.reverse(),
        onTap: widget.onTap,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: widget.isSelected
                ? theme.primaryColor.withOpacity(0.15)
                : theme.cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: widget.isSelected
                  ? theme.primaryColor.withOpacity(0.5)
                  : Colors.transparent,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.isSelected
                    ? theme.primaryColor.withOpacity(0.2)
                    : Colors.black.withOpacity(0.05),
                  blurRadius: widget.isSelected ? 20 : 10,
                  offset: const Offset(0, 4),
                ),
                if (_isHovering)
                  BoxShadow(
                    color: theme.primaryColor.withOpacity(0.1),
                    blurRadius: 20,
                    spreadRadius: -5,
                  ),
              ],
            ),
            child: Dismissible(
              key: Key(widget.server.id),
              direction: DismissDirection.endToStart,
              onDismissed: (_) => widget.onDelete(),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.delete,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // 服务器图标
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: widget.isConnected
                            ? [Colors.green[400]!, Colors.green[600]!]
                            : widget.isSelected
                              ? [theme.primaryColor.withOpacity(0.8), theme.primaryColor]
                              : [Colors.grey[400]!, Colors.grey[600]!],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          if (widget.isConnected)
                            BoxShadow(
                              color: Colors.green.withOpacity(0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                        ],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          UIUtils.buildCountryFlag(
                            widget.server.location,
                            size: 40,
                          ),
                          if (widget.isConnected)
                            Positioned(
                              right: 4,
                              top: 4,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    
                    // 服务器信息
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.server.name,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: widget.isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w600,
                                    color: widget.isSelected
                                      ? theme.primaryColor
                                      : null,
                                    shadows: widget.isSelected
                                      ? [
                                          Shadow(
                                            color: theme.brightness == Brightness.dark
                                              ? Colors.black54
                                              : Colors.white70,
                                            blurRadius: 2,
                                            offset: const Offset(1, 1),
                                          ),
                                        ]
                                      : null,
                                  ),
                                ),
                              ),
                              if (widget.isConnected)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    l10n.connected,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.green,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.location_on,
                                size: 14,
                                color: widget.isSelected
                                  ? theme.primaryColor
                                  : Colors.grey[600],
                              ),
                              const SizedBox(width: 4),
                              Text(
                                locationInfo['country'] ?? widget.server.location,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: widget.isSelected
                                    ? theme.primaryColor
                                    : Colors.grey[600],
                                  shadows: widget.isSelected
                                    ? [
                                        Shadow(
                                          color: theme.brightness == Brightness.dark
                                            ? Colors.black54
                                            : Colors.white70,
                                          blurRadius: 2,
                                          offset: const Offset(0.5, 0.5),
                                        ),
                                      ]
                                    : null,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Icon(
                                Icons.network_ping,
                                size: 14,
                                color: UIUtils.getPingColor(widget.server.ping),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${widget.server.ping}ms',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: UIUtils.getPingColor(widget.server.ping),
                                  fontWeight: FontWeight.w600,
                                  shadows: widget.isSelected
                                    ? [
                                        Shadow(
                                          color: theme.brightness == Brightness.dark
                                            ? Colors.black87
                                            : Colors.white,
                                          blurRadius: 3,
                                          offset: const Offset(0, 0),
                                        ),
                                        Shadow(
                                          color: theme.brightness == Brightness.dark
                                            ? Colors.black54
                                            : Colors.white70,
                                          blurRadius: 2,
                                          offset: const Offset(1, 1),
                                        ),
                                      ]
                                    : null,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${widget.server.ip}:${widget.server.port}',
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.isSelected
                                ? theme.primaryColor.withOpacity(0.8)
                                : Colors.grey[500],
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // 信号强度指示器
                    _buildSignalIndicator(widget.server.ping),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignalIndicator(int ping) {
    final strength = ping < 50 ? 5 : 
                    ping < 100 ? 4 : 
                    ping < 150 ? 3 : 
                    ping < 200 ? 2 : 1;
    
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (index) {
          final isActive = index < strength;
          final color = isActive ? UIUtils.getPingColor(ping) : Colors.grey.withOpacity(0.2);
          
          return Container(
            width: 4,
            height: 8 + (index * 3),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                if (isActive && widget.isSelected)
                  BoxShadow(
                    color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.black.withOpacity(0.8)
                      : Colors.white.withOpacity(0.8),
                    spreadRadius: 1,
                    blurRadius: 2,
                  ),
                if (isActive)
                  BoxShadow(
                    color: UIUtils.getPingColor(ping).withOpacity(0.5),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }
}