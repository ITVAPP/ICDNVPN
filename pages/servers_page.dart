import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/cloudflare_test_service.dart';
import '../services/ad_service.dart';
import '../models/server_model.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';  // 新增：导入日志服务
import 'package:url_launcher/url_launcher.dart';  // 新增：导入 url_launcher

class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  static const String _logTag = 'ServersPage';  // 新增：日志标签
  static final LogService _log = LogService.instance;  // 新增：日志服务实例
  
  bool _isAscending = true;
  bool _isTesting = false;
  bool _isSwitching = false; // 添加切换状态标志

  @override
  void initState() {
    super.initState();
    
    // 新增：检查是否显示图片广告
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndShowImageAd();
    });
  }

  // 修改：先预加载图片，成功后再显示广告遮罩
  void _checkAndShowImageAd() async {
    final adService = context.read<AdService>();
    final imageAd = await adService.getImageAdForPageAsync('servers');
    
    if (imageAd != null) {
      final imageUrl = imageAd.content.imageUrl;
      
      // 如果没有图片URL，不显示广告
      if (imageUrl == null || imageUrl.isEmpty) {
        return;
      }
      
      try {
        // 先预加载图片
        if (imageUrl.startsWith('assets/')) {
          await precacheImage(AssetImage(imageUrl), context);
        } else {
          await precacheImage(NetworkImage(imageUrl), context);
        }
        
        // 图片加载成功后，延迟显示（等页面完全加载）
        await Future.delayed(const Duration(milliseconds: 500));
        
        // 确认组件仍然挂载后再显示广告
        if (mounted) {
          _showImageAdOverlay(imageAd);
        }
      } catch (e) {
        // 图片加载失败，不显示广告（静默处理）
        debugPrint('广告图片预加载失败: $e');
      }
    }
  }

  // 显示图片广告遮罩（图片已预加载完成）
  void _showImageAdOverlay(dynamic ad) {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (context) => ImageAdOverlay(
        ad: ad,
        adService: context.read<AdService>(),
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

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
            Text(l10n.testingServersCount(serverProvider.servers.length)),
            const SizedBox(height: 8),
            const Text(
              'HTTPing 80',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );

    try {
      // 收集所有服务器的IP地址
      final ips = serverProvider.servers.map((server) => server.ip).toList();

      // 使用HTTPing测试，端口80
      final results = await CloudflareTestService.testLatencyUnified(
        ips: ips,
        port: 80,  // 使用80端口
        useHttping: true,  // 使用HTTPing
      );

      // 更新服务器延迟
      int updatedCount = 0;
      for (final result in results) {
        final ip = result['ip'] as String;
        final latency = result['latency'] as int;
        
        // 查找对应的服务器并更新延迟
        final serverIndex = serverProvider.servers.indexWhere((s) => s.ip == ip);
        if (serverIndex != -1) {
          await serverProvider.updatePing(serverProvider.servers[serverIndex].id, latency);
          updatedCount++;
        }
      }

      if (!mounted) return;
      
      // 关闭进度对话框
      Navigator.of(context).pop();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.testCompletedCount(updatedCount))),
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

  // 获取国际化的消息文本
  String _getLocalizedMessage(BuildContext context, String messageKey) {
    final l10n = AppLocalizations.of(context);
    
    // 根据消息键返回对应的国际化文本
    switch (messageKey) {
      case 'gettingBestNodes':
        return l10n.gettingBestNodes;
      case 'preparingTestEnvironment':
        return l10n.preparingTestEnvironment;
      case 'generatingTestIPs':
        return l10n.generatingTestIPs;
      case 'testingDelay':
        return l10n.testingDelay;
      case 'testingResponseSpeed':
        return l10n.testingResponseSpeed;
      case 'testCompleted':
        return l10n.testCompleted;
      default:
        // 如果是中文文本，直接返回（兼容旧版本）
        if (messageKey.contains('正在') || messageKey.contains('测试')) {
          return messageKey;
        }
        // 否则返回键值本身
        return messageKey;
    }
  }

  // 获取国际化的详情文本
  String _getLocalizedDetail(BuildContext context, String detailKey, ServerProvider serverProvider) {
    final l10n = AppLocalizations.of(context);
    
    switch (detailKey) {
      case 'initializing':
        return l10n.initializing;
      case 'startingTraceTest':
        return l10n.startingTraceTest;
      case 'preparingTestEnvironment':
        return l10n.preparingTestEnvironment;
      default:
        // 如果是中文文本，直接返回（兼容旧版本）
        if (detailKey.contains('初始') || detailKey.contains('测') || detailKey.contains('从')) {
          return detailKey;
        }
        // 对于包含参数的详情，使用原始的详情文本
        return serverProvider.initDetail;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serverList),
        centerTitle: false,  // 标题居左
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
          // 添加右边距
          const SizedBox(width: 8),
        ],
      ),
      body: Consumer3<ServerProvider, ConnectionProvider, AdService>(
        builder: (context, serverProvider, connectionProvider, adService, child) {
          // 显示初始化进度
          if (serverProvider.isInitializing) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 60,
                    height: 60,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: serverProvider.progress,
                          strokeWidth: 4,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).primaryColor,
                          ),
                        ),
                        Text(
                          '${(serverProvider.progress * 100).round()}%',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _getLocalizedMessage(context, serverProvider.initMessage),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _getLocalizedDetail(context, serverProvider.initDetail, serverProvider),
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                    textAlign: TextAlign.center,
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

          // 新增：获取服务器页面的文字广告（最多2条）
          final textAds = adService.getTextAdsForPage('servers', limit: 2);

          // 如果服务器列表为空，显示空状态
          if (servers.isEmpty && textAds.isEmpty) {
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

          // 构建混合列表（服务器 + 广告）- 优化插入逻辑
          final List<dynamic> mixedItems = [];
          
          // 根据服务器数量决定广告插入位置
          if (servers.isEmpty) {
            // 如果没有服务器，只显示广告
            mixedItems.addAll(textAds);
          } else if (servers.length <= 2 && textAds.isNotEmpty) {
            // 服务器少于3个，在末尾添加广告
            mixedItems.addAll(servers);
            mixedItems.addAll(textAds);
          } else if (servers.length <= 5 && textAds.isNotEmpty) {
            // 服务器3-5个，在第3个位置插入第一个广告
            mixedItems.addAll(servers.take(2));
            if (textAds.isNotEmpty) {
              mixedItems.add(textAds[0]);
            }
            mixedItems.addAll(servers.skip(2));
            // 如果有第二个广告，添加到末尾
            if (textAds.length > 1) {
              mixedItems.add(textAds[1]);
            }
          } else {
            // 服务器6个以上，在第3和第6个位置插入广告
            int serverIndex = 0;
            int adIndex = 0;
            
            for (int i = 0; i < servers.length + textAds.length; i++) {
              // 在第3个(index=2)和第6个(index=5)位置插入广告
              if ((i == 2 || i == 5) && adIndex < textAds.length) {
                mixedItems.add(textAds[adIndex]);
                adIndex++;
              } else if (serverIndex < servers.length) {
                mixedItems.add(servers[serverIndex]);
                serverIndex++;
              }
            }
            
            // 如果还有剩余的广告，添加到末尾
            while (adIndex < textAds.length) {
              mixedItems.add(textAds[adIndex]);
              adIndex++;
            }
          }

          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: mixedItems.length,
            itemBuilder: (context, index) {
              final item = mixedItems[index];
              
              // 判断是广告还是服务器
              if (item is ServerModel) {
                final server = item;
                final isSelected = connectionProvider.currentServer?.id == server.id;
                final isConnected = connectionProvider.isConnected && isSelected;
                
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),  // 修改：从 8 改为 6
                  child: ServerListItem(
                    server: server,
                    isSelected: isSelected,
                    isConnected: isConnected,
                    onTap: () async {
                      // 如果正在切换中，忽略点击
                      if (_isSwitching) {
                        return;
                      }
                      
                      // 如果选择的是当前已连接的服务器，不做任何操作
                      if (connectionProvider.currentServer?.id == server.id) {
                        return;
                      }
                      
                      // 如果当前已连接，询问是否切换
                      if (connectionProvider.isConnected) {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(l10n.switchNode),
                            content: Text(l10n.switchToNodeConfirm(server.name) + '\n' + l10n.switchNodeDesc),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: Text(l10n.cancel),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: Text(l10n.switching),
                              ),
                            ],
                          ),
                        ) ?? false;
                        
                        if (!confirmed) return;
                        
                        // 设置切换状态
                        setState(() {
                          _isSwitching = true;
                        });
                        
                        // 显示切换进度
                        if (!context.mounted) return;
                        showDialog(
                          context: context,
                          barrierDismissible: false,
                          builder: (context) => AlertDialog(
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 16),
                                Text(l10n.switchingNode),
                              ],
                            ),
                          ),
                        );
                        
                        try {
                          // 先设置新服务器
                          await connectionProvider.setCurrentServer(server);
                          // 断开当前连接
                          await connectionProvider.disconnect();
                          // 等待一下确保断开完成
                          await Future.delayed(const Duration(milliseconds: 500));
                          // 连接到新服务器
                          await connectionProvider.connect();
                          
                          if (!context.mounted) return;
                          
                          // 关闭进度对话框
                          Navigator.pop(context);
                          
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.switchedTo(server.name)),
                              backgroundColor: Colors.green,
                            ),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          
                          // 关闭进度对话框
                          Navigator.pop(context);
                          
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(l10n.switchFailedError(e.toString())),
                              backgroundColor: Colors.red,
                            ),
                          );
                        } finally {
                          // 重置切换状态，延迟2秒防止快速重复点击
                          Future.delayed(const Duration(milliseconds: 2000), () {
                            if (mounted) {
                              setState(() {
                                _isSwitching = false;
                              });
                            }
                          });
                        }
                      } else {
                        // 未连接状态，直接选择
                        connectionProvider.setCurrentServer(server);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${l10n.selectServer} ${server.name}'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      }
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
                              child: Text(l10n.cancel),
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
              } else {
                // 显示广告卡片
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),  // 修改：从 8 改为 6
                  child: TextAdCard(ad: item),
                );
              }
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
    final locationInfo = UIUtils.getLocationInfo(widget.server.location);
    
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
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: widget.isSelected
                ? (theme.brightness == Brightness.dark 
                    ? theme.colorScheme.primary.withOpacity(0.1)  // 深色主题使用更浅的透明度
                    : theme.primaryColor.withOpacity(0.15))       // 浅色主题保持原样
                : (theme.brightness == Brightness.dark 
                    ? const Color(0xFF1E1E1E)  // 修改：深色主题使用固定背景色
                    : theme.cardColor),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: widget.isSelected
                  ? (theme.brightness == Brightness.dark 
                      ? theme.colorScheme.primary.withOpacity(0.5)  // 深色主题使用主题色
                      : theme.primaryColor.withOpacity(0.5))        // 浅色主题使用主色
                  : Colors.transparent,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: widget.isSelected
                    ? (theme.brightness == Brightness.dark 
                        ? theme.colorScheme.primary.withOpacity(0.2)  // 深色主题使用主题色
                        : theme.primaryColor.withOpacity(0.2))        // 浅色主题使用主色
                    : Colors.black.withOpacity(0.05),
                  blurRadius: widget.isSelected ? 20 : 10,
                  offset: const Offset(0, 4),
                ),
                if (_isHovering)
                  BoxShadow(
                    color: theme.brightness == Brightness.dark 
                      ? theme.colorScheme.primary.withOpacity(0.1)  // 深色主题使用主题色
                      : theme.primaryColor.withOpacity(0.1),        // 浅色主题使用主色
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
                child: Row(
                  children: [
                    // 服务器图标 - 直接使用圆形国旗设计
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        UIUtils.buildCountryFlag(
                          widget.server.location,
                          size: 56, // 直接使用完整尺寸
                        ),
                        if (widget.isConnected)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.green.withOpacity(0.5),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
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
                                child: widget.isSelected || widget.isConnected
                                  ? Stack(
                                      children: [
                                        // 淡白色描边
                                        Text(
                                          widget.server.name,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: widget.isSelected
                                              ? FontWeight.bold
                                              : FontWeight.w600,
                                            foreground: Paint()
                                              ..style = PaintingStyle.stroke
                                              ..strokeWidth = 1
                                              ..color = Colors.white.withOpacity(0.7), // 淡白色
                                          ),
                                        ),
                                        // 实际文字
                                        Text(
                                          widget.server.name,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: widget.isSelected
                                              ? FontWeight.bold
                                              : FontWeight.w600,
                                            color: widget.isSelected
                                              ? (theme.brightness == Brightness.dark 
                                                  ? theme.colorScheme.primary
                                                  : theme.primaryColor)
                                              : theme.textTheme.bodyLarge?.color,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      widget.server.name,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: theme.textTheme.bodyLarge?.color,
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
                                    border: Border.all(
                                      color: Colors.green.withOpacity(0.5),
                                      width: 1,
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      // 白色描边效果 - 使用多个阴影实现
                                      Text(
                                        l10n.connected,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          foreground: Paint()
                                            ..style = PaintingStyle.stroke
                                            ..strokeWidth = 1
                                            ..color = Colors.white,
                                        ),
                                      ),
                                      // 深绿色文字
                                      Text(
                                        l10n.connected,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.green[800], // 深绿色
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              // 位置图标
                              widget.isSelected || widget.isConnected
                                ? Stack(
                                    children: [
                                      // 淡白色描边
                                      Icon(
                                        Icons.location_on,
                                        size: 15,
                                        color: Colors.white.withOpacity(0.7),
                                      ),
                                      // 实际图标
                                      Icon(
                                        Icons.location_on,
                                        size: 14,
                                        color: widget.isSelected
                                          ? (theme.brightness == Brightness.dark 
                                              ? theme.colorScheme.primary
                                              : theme.primaryColor)
                                          : Colors.grey[600],
                                      ),
                                    ],
                                  )
                                : Icon(
                                    Icons.location_on,
                                    size: 14,
                                    color: Colors.grey[600],
                                  ),
                              const SizedBox(width: 4),
                              // 位置文字
                              widget.isSelected || widget.isConnected
                                ? Stack(
                                    children: [
                                      // 淡白色描边
                                      Text(
                                        locationInfo['country'] ?? widget.server.location,
                                        style: TextStyle(
                                          fontSize: 13,
                                          foreground: Paint()
                                            ..style = PaintingStyle.stroke
                                            ..strokeWidth = 1
                                            ..color = Colors.white.withOpacity(0.7),
                                        ),
                                      ),
                                      // 实际文字
                                      Text(
                                        locationInfo['country'] ?? widget.server.location,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: widget.isSelected
                                            ? (theme.brightness == Brightness.dark 
                                                ? theme.colorScheme.primary.withOpacity(0.8)
                                                : theme.primaryColor.withOpacity(0.8))
                                            : Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    locationInfo['country'] ?? widget.server.location,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                              const SizedBox(width: 16),
                              // 延迟图标
                              widget.isSelected || widget.isConnected
                                ? Stack(
                                    children: [
                                      // 淡白色描边
                                      Icon(
                                        Icons.network_ping,
                                        size: 15,
                                        color: Colors.white.withOpacity(0.7),
                                      ),
                                      // 实际图标
                                      Icon(
                                        Icons.network_ping,
                                        size: 14,
                                        color: UIUtils.getPingColor(widget.server.ping),
                                      ),
                                    ],
                                  )
                                : Icon(
                                    Icons.network_ping,
                                    size: 14,
                                    color: UIUtils.getPingColor(widget.server.ping),
                                  ),
                              const SizedBox(width: 4),
                              // 延迟文字
                              widget.isSelected || widget.isConnected
                                ? Stack(
                                    children: [
                                      // 淡白色描边
                                      Text(
                                        '${widget.server.ping}ms',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          foreground: Paint()
                                            ..style = PaintingStyle.stroke
                                            ..strokeWidth = 1
                                            ..color = Colors.white.withOpacity(0.7),
                                        ),
                                      ),
                                      // 实际文字
                                      Text(
                                        '${widget.server.ping}ms',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: UIUtils.getPingColor(widget.server.ping),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    '${widget.server.ping}ms',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: UIUtils.getPingColor(widget.server.ping),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                            ],
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
          
          // 如果是选中或已连接状态，添加描边效果
          if ((widget.isSelected || widget.isConnected) && isActive) {
            return Stack(
              children: [
                // 淡白色描边 - 稍微放大一点
                Container(
                  width: 5,
                  height: 9 + (index * 3),
                  margin: const EdgeInsets.symmetric(horizontal: 0.5),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                // 实际的信号条
                Container(
                  width: 4,
                  height: 8 + (index * 3),
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            );
          } else {
            // 普通状态
            return Container(
              width: 4,
              height: 8 + (index * 3),
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }
        }),
      ),
    );
  }
}

// ==================== 文字广告卡片组件 ====================

/// 文字广告卡片组件 - 用于服务器列表页面
class TextAdCard extends StatelessWidget {
  static const String _logTag = 'TextAdCard';  // 新增：日志标签
  static final LogService _log = LogService.instance;  // 新增：日志服务实例
  
  final AdModel ad;

  const TextAdCard({
    Key? key,
    required this.ad,
  }) : super(key: key);

  Future<void> _openUrl(String? url) async {
    if (url == null || url.isEmpty) return;

    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      await _log.error('打开广告链接失败', tag: _logTag, error: e);  // 修改：使用日志服务
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      cursor: ad.content.url != null 
          ? SystemMouseCursors.click 
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: ad.content.url != null 
            ? () => _openUrl(ad.content.url) 
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 8),  // 修改：从 4 改为 8
          decoration: BoxDecoration(
            // 修改：深色主题使用纯色背景
            color: isDark ? const Color(0xFF1E1E1E) : null,
            gradient: isDark ? null : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.primaryColor.withOpacity(0.15),
                theme.primaryColor.withOpacity(0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(16), // 与节点卡片相同的圆角
            border: Border.all(
              color: theme.primaryColor.withOpacity(0.3),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: theme.brightness == Brightness.dark
                  ? Colors.black.withOpacity(0.2)
                  : Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
            child: Row(
              children: [
                // 广告图标容器 - 与节点卡片的国旗样式一致
                Container(
                  width: 56, // 与服务器列表页的国旗大小一致
                  height: 56,
                  decoration: BoxDecoration(
                    color: theme.primaryColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.8),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                      BoxShadow(
                        color: theme.primaryColor.withOpacity(0.4),
                        blurRadius: 8,
                        spreadRadius: -2,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      'AD',
                      style: TextStyle(
                        fontSize: 56 * 0.35, // 与国旗组件的字号比例一致
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Colors.black.withOpacity(0.5),
                            offset: const Offset(1, 1),
                            blurRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // 广告内容
                Expanded(
                  child: Text(
                    ad.content.text ?? '',
                    style: TextStyle(
                      fontSize: 14, // 与节点名称字号一致
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 链接指示器
                if (ad.content.url != null) ...[
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: theme.brightness == Brightness.dark
                        ? Colors.white.withOpacity(0.7)  // 深色主题使用白色
                        : theme.primaryColor.withOpacity(0.6),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}