import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';
import '../services/v2ray_service.dart';
import '../services/ad_service.dart';
import '../services/location_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/ui_utils.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late AnimationController _slideController;
  late AnimationController _loadingController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _loadingAnimation;
  
  // 流量统计 - 修改为显示总量
  String _uploadTotal = '0 KB';
  String _downloadTotal = '0 KB';
  String _connectedTime = '00:00:00';
  Timer? _connectedTimeTimer;
  StreamSubscription<V2RayStatus>? _statusSubscription;
  
  bool _isProcessing = false;
  bool _isDisconnecting = false;  // 新增：跟踪是否正在断开连接
  
  // 用于跟踪服务器列表变化
  int _previousServerCount = 0;

  @override
  void initState() {
    super.initState();
    
    // 滑动动画控制器
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    // 加载动画控制器
    _loadingController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
    
    // 动画配置
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOut,
    ));
    
    _loadingAnimation = Tween<double>(
      begin: 0,
      end: 2 * math.pi,
    ).animate(CurvedAnimation(
      parent: _loadingController,
      curve: Curves.linear,
    ));
    
  _slideController.forward();
  
  // 根据平台监听流量统计
  if (Platform.isAndroid || Platform.isIOS) {
    // 移动端：监听V2RayService状态流获取流量数据
    _statusSubscription = V2RayService.statusStream.listen((status) {
      if (mounted && status.state == V2RayConnectionState.connected) {
        setState(() {
          _uploadTotal = UIUtils.formatBytes(status.upload);
          _downloadTotal = UIUtils.formatBytes(status.download);
        });
      }
    });
  } else if (Platform.isWindows) {
    // Windows平台：同样监听状态流（由V2RayService的API更新）
    _statusSubscription = V2RayService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _uploadTotal = UIUtils.formatBytes(status.upload);
          _downloadTotal = UIUtils.formatBytes(status.download);
        });
      }
    });
  }
    
    // 监听连接状态变化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
      final serverProvider = Provider.of<ServerProvider>(context, listen: false);
      
      // 新增：设置对话框上下文，供Windows平台显示注册表修改提示
      connectionProvider.setDialogContext(context);
      
      connectionProvider.addListener(_onConnectionChanged);
      serverProvider.addListener(_onServerListChanged);
      
      // 初始化服务器数量
      _previousServerCount = serverProvider.servers.length;
      
      _onConnectionChanged();
      
      // 新增：检查是否显示图片广告
      _checkAndShowImageAd();
      
      // 新增：发送页面统计（异步，不阻塞）
      LocationService().sendAnalytics(context, 'home');
    });
  }

  @override
  void dispose() {
    final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
    final serverProvider = Provider.of<ServerProvider>(context, listen: false);
    connectionProvider.removeListener(_onConnectionChanged);
    serverProvider.removeListener(_onServerListChanged);
    _slideController.dispose();
    _loadingController.dispose();
    _statusSubscription?.cancel();
    _connectedTimeTimer?.cancel();
    super.dispose();
  }
  
  // 使用SharedPreferences持久化，避免重启后重复提示
  Future<void> _checkAndRequestBatteryOptimization() async {
    // 仅Android平台需要
    if (!Platform.isAndroid) return;
    
    try {
      // 检查是否已经提示过（使用SharedPreferences持久化）
      final prefs = await SharedPreferences.getInstance();
      final hasPrompted = prefs.getBool('battery_optimization_prompted') ?? false;
      if (hasPrompted) return;
      
      // 通过原生通道检查是否需要电池优化豁免
      final channel = const MethodChannel('com.example.cfvpn/v2ray');
      final needsOptimization = await channel.invokeMethod<bool>('requestBatteryOptimization');
      
      // 返回true表示需要请求权限，false表示已有权限
      if (needsOptimization == true && mounted) {
        // 标记已提示（持久化）
        await prefs.setBool('battery_optimization_prompted', true);
        
        // 延迟显示，确保连接稳定
        await Future.delayed(const Duration(seconds: 3));
        
        if (!mounted) return;
        
        final l10n = AppLocalizations.of(context);
        
        // 显示提示对话框
        final shouldRequest = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.battery_charging_full, color: Colors.green, size: 48),
            title: Text(l10n.optimizeBattery),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.optimizeBatteryDesc),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Colors.green[700]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.recommendedSetting,
                          style: TextStyle(fontSize: 12, color: Colors.green[700]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.later),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.goToSettings),
              ),
            ],
          ),
        );
        
        if (shouldRequest == true) {
          // 调用原生方法打开电池优化设置
          await channel.invokeMethod('requestBatteryOptimization');
        }
      }
    } catch (e) {
      debugPrint('检查电池优化失败: $e');
    }
  }
  
  void _onConnectionChanged() {
    final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
    
    // 检查是否有断开原因（意外断开）
    if (connectionProvider.disconnectReason != null && mounted) {
      final l10n = AppLocalizations.of(context);
      String message = '';
      
      switch (connectionProvider.disconnectReason) {
        case 'unexpected_exit':
          message = l10n.vpnDisconnected;
          break;
        case 'service_stopped':
          message = l10n.vpnDisconnected;  // 使用已有的键
          break;
        default:
          message = l10n.connectionLost;
      }
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
          connectionProvider.clearDisconnectReason();
        }
      });
    }
    
    if (connectionProvider.isConnected) {
      _startConnectedTimeTimer();
      // 仅Android平台检查电池优化
      if (Platform.isAndroid) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && connectionProvider.isConnected) {
            _checkAndRequestBatteryOptimization();
          }
        });
      }
    } else {
      _stopConnectedTimeTimer();
      // 断开时重置流量显示
      if (mounted) {
        setState(() {
          _uploadTotal = '0 KB';
          _downloadTotal = '0 KB';
        });
      }
    }
  }
  
  void _onServerListChanged() {
    if (!mounted) return;
    
    final serverProvider = Provider.of<ServerProvider>(context, listen: false);
    final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
    final currentServerCount = serverProvider.servers.length;
    final l10n = AppLocalizations.of(context);
    
    // 检测服务器列表从空变为非空（获取成功）
    if (_previousServerCount == 0 && currentServerCount > 0) {
      // 如果当前没有选中的服务器，自动选择最优的
      if (connectionProvider.currentServer == null) {
        final bestServer = serverProvider.servers.reduce((a, b) => a.ping < b.ping ? a : b);
        connectionProvider.setCurrentServer(bestServer);
        
        // 显示提示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.autoSelectedBestNode(bestServer.name, bestServer.ping)),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    // 检测获取失败（从正在获取变为空）
    else if (serverProvider.servers.isEmpty && !serverProvider.isInitializing && serverProvider.initMessage.isNotEmpty) {
      // 显示失败提示
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.getNodeFailedWithRetry),
          backgroundColor: Colors.red,
          action: SnackBarAction(
            label: l10n.retry,
            textColor: Colors.white,
            onPressed: () {
              serverProvider.refreshFromCloudflare();
            },
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
    
    _previousServerCount = currentServerCount;
  }
  
  void _startConnectedTimeTimer() {
    _connectedTimeTimer?.cancel();
    // 立即更新一次
    _updateConnectedTime();
    // 每秒更新
    _connectedTimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateConnectedTime();
    });
  }
  
  void _stopConnectedTimeTimer() {
    _connectedTimeTimer?.cancel();
    if (mounted) {
      setState(() {
        _connectedTime = '00:00:00';
      });
    }
  }
  
  void _updateConnectedTime() {
    final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
    final connectStartTime = connectionProvider.connectStartTime;
    
    if (connectStartTime != null && mounted) {
      final duration = DateTime.now().difference(connectStartTime);
      final hours = duration.inHours.toString().padLeft(2, '0');
      final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
      setState(() {
        _connectedTime = '$hours:$minutes:$seconds';
      });
    }
  }

  // 修改：先预加载图片，成功后再显示广告遮罩
  void _checkAndShowImageAd() async {
    final adService = context.read<AdService>();
    final imageAd = await adService.getImageAdForPageAsync('home');
    
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Scaffold(
      body: Container(
        width: double.infinity,  // 修复：确保容器填满整个宽度
        height: double.infinity, // 修复：确保容器填满整个高度，避免背景渐变断层
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
              ? [
                  const Color(0xFF1E1E1E),
                  const Color(0xFF2C2C2C),
                ]
              : [
                  const Color(0xFFF5F5F5),
                  const Color(0xFFE8E8E8),
                ],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Consumer2<ConnectionProvider, ServerProvider>(
            builder: (context, connectionProvider, serverProvider, child) {
              // 重要：每次重建时更新对话框上下文
              connectionProvider.setDialogContext(context);
              
              final isConnected = connectionProvider.isConnected;
              final currentServer = connectionProvider.currentServer;
              
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 20.0,
                    right: 20.0,
                    top: 52.0, // 距离屏幕顶部
                    bottom: 20.0,
                  ),
                  child: Column(
                    children: [
                      // 顶部状态栏
                      _buildStatusBar(isConnected, l10n),
                      const SizedBox(height: 30), // 距离下方连接按钮像素
                      
                      // 主连接按钮
                      SlideTransition(
                        position: _slideAnimation,
                        child: _buildConnectionButton(isConnected, connectionProvider, l10n),
                      ),
                      const SizedBox(height: 30), // 减少间距
                      
                      // 服务器信息卡片 - 修改：传递serverProvider以获取状态
                      SlideTransition(
                        position: _slideAnimation,
                        child: currentServer != null
                          ? _buildServerInfoCard(currentServer, isConnected, l10n)
                          : _buildEmptyServerCard(l10n, serverProvider),  // 传递serverProvider
                      ),
                      
                      // 流量统计卡片
                      if (isConnected) ...[
                        const SizedBox(height: 20),
                        _buildTrafficCard(l10n),
                      ],
                      
                      // 快速操作按钮
                      const SizedBox(height: 20),
                      _buildQuickActions(serverProvider, connectionProvider, l10n),
                      
                      // 新增：文字广告轮播
                      Consumer<AdService>(
                        builder: (context, adService, child) {
                          final textAds = adService.getTextAdsForPage('home');
                          if (textAds.isEmpty) return const SizedBox.shrink();
                          
                          return Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: TextAdCarousel(
                              ads: textAds,
                              height: 60,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar(bool isConnected, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: isConnected 
          ? Colors.green.withOpacity(0.1) 
          : Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: isConnected 
            ? Colors.green.withOpacity(0.3) 
            : Colors.red.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isConnected ? Colors.green : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isConnected ? l10n.connected : l10n.disconnected,
            style: TextStyle(
              color: isConnected ? Colors.green : Colors.red,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (isConnected) ...[
            const SizedBox(width: 8),
            Text(
              '• $_connectedTime',
              style: TextStyle(
                color: Colors.green[700],
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 修改：优化权限请求时机
Widget _buildConnectionButton(bool isConnected, ConnectionProvider provider, AppLocalizations l10n) {
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: _isProcessing ? null : () async {
        // 触感反馈
        Feedback.forTap(context);
        
        // 未连接时检查节点情况
        if (!isConnected) {
          final serverProvider = Provider.of<ServerProvider>(context, listen: false);
          
          // 情况1：正在获取节点
          if (serverProvider.isInitializing) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.gettingNodes),  // 使用已有的国际化键
                backgroundColor: Colors.blue,
                duration: const Duration(seconds: 2),
              ),
            );
            return;
          }
          
          // 情况2：没有节点
          if (serverProvider.servers.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.noServers),  // 使用已有的国际化键
                backgroundColor: Colors.orange,
                action: SnackBarAction(
                  label: l10n.refresh,
                  textColor: Colors.white,
                  onPressed: () async {
                    await serverProvider.refreshFromCloudflare();
                  },
                ),
                duration: const Duration(seconds: 4),
              ),
            );
            return;  // 阻止连接
          }
          
          // 情况3：有节点但未选择
          if (provider.currentServer == null) {
            final bestServer = serverProvider.servers.reduce((a, b) => a.ping < b.ping ? a : b);
            provider.setCurrentServer(bestServer);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.autoSelectedBestNode(bestServer.name, bestServer.ping)),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );
            // 继续连接流程
          }
        }
          
          setState(() {
            _isProcessing = true;
            // 如果是断开操作，设置断开标志
            if (isConnected) {
              _isDisconnecting = true;
            }
          });
          
          // 启动加载动画
        _loadingController.repeat();
        
        try {
          if (isConnected) {
            await provider.disconnect();
          } else {
            await provider.connect();
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${l10n.operationFailed}: ${e.toString()}'),
                backgroundColor: Colors.red,
              ),
            );
          }
        } finally {
          if (mounted) {
            setState(() {
              _isProcessing = false;
              _isDisconnecting = false;
            });
            _loadingController.stop();
            _loadingController.reset();
          }
        }
      },
      child: AnimatedBuilder(
          animation: _loadingAnimation,
          builder: (context, child) {
            return Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: _isProcessing
                    ? _isDisconnecting
                      ? [  // 正在断开 - 红色
                          Colors.red.shade400,
                          Colors.red.shade600,
                        ]
                      : [  // 正在连接 - 橙色
                          Colors.orange.shade400,
                          Colors.orange.shade600,
                        ]
                    : isConnected
                      ? [  // 已连接，准备断开 - 绿色
                          Colors.green.shade400,
                          Colors.green.shade600,
                        ]
                      : [  // 未连接，准备连接 - 蓝色
                          Colors.blue.shade400,
                          Colors.blue.shade600,
                        ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: (_isProcessing 
                      ? (_isDisconnecting ? Colors.red : Colors.orange)
                      : (isConnected ? Colors.green : Colors.blue)
                    ).withOpacity(0.3),
                    blurRadius: 30,
                    spreadRadius: 10,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 中心内容容器
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 中心图标 - 使用火箭图标
                      Transform.rotate(
                        angle: _isProcessing ? _loadingAnimation.value : 0,
                        child: Icon(
                          _isProcessing 
                            ? Icons.sync
                            : (isConnected ? Icons.rocket_launch : Icons.rocket),
                          size: 80,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 状态文字
                      AnimatedOpacity(
                        opacity: _isProcessing ? 0.7 : 1.0,
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _isProcessing 
                            ? (_isDisconnecting ? l10n.disconnecting : l10n.connecting)
                            : (isConnected ? l10n.clickToDisconnect : l10n.clickToConnect),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildServerInfoCard(ServerModel server, bool isConnected, AppLocalizations l10n) {
    final theme = Theme.of(context);
    // 修改：使用国际化版本的方法
    final locationInfo = UIUtils.getLocalizedLocationInfo(server.location, context);
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark 
            ? const Color(0xFF1E1E1E)  // 修改：深色主题使用固定背景色
            : theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: theme.brightness == Brightness.dark
              ? Colors.black.withOpacity(0.2)
              : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // 直接使用圆形国旗设计
              UIUtils.buildCountryFlag(server.location, size: 50),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.location_on, size: 14, color: theme.hintColor),
                        const SizedBox(width: 4),
                        Text(
                          locationInfo['country'] ?? server.location,
                          style: TextStyle(
                            fontSize: 14,
                            color: theme.hintColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 延迟指示器
              _buildPingIndicator(server.ping, isConnected),
            ],
          ),
        ],
      ),
    );
  }

  // 修改：处理 ServerProvider 的国际化显示
  Widget _buildEmptyServerCard(AppLocalizations l10n, ServerProvider serverProvider) {
    final theme = Theme.of(context);
    
    // 根据状态显示不同内容
    Widget content;
    Color? borderColor;
    
    if (serverProvider.isInitializing) {
      // 正在初始化/获取节点
      // 获取本地化的消息
      String message = l10n.gettingNodes;
      String detail = '';
      
      // 根据 messageKey 显示本地化文字
      if (serverProvider.initMessage.isNotEmpty) {
        switch (serverProvider.initMessage) {
          case 'gettingBestNodes':
            message = l10n.gettingBestNodes;
            break;
          case 'preparingTestEnvironment':
            message = l10n.preparingTestEnvironment;
            break;
          case 'generatingTestIPs':
            message = l10n.generatingTestIPs;
            break;
          case 'testingDelay':
            message = l10n.testingDelay;
            break;
          case 'testingResponseSpeed':
            message = l10n.testingResponseSpeed;
            break;
          case 'testCompleted':
            message = l10n.testCompleted;
            break;
          default:
            message = serverProvider.initMessage;
        }
      }
      
      // 根据 detailKey 显示本地化详情
      if (serverProvider.initDetail.isNotEmpty) {
        switch (serverProvider.initDetail) {
          case 'initializing':
            detail = l10n.initializing;
            break;
          case 'startingTraceTest':
            detail = l10n.startingTraceTest;
            break;
          default:
            detail = serverProvider.initDetail;
        }
      }
      
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    theme.primaryColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                message,
                style: TextStyle(
                  fontSize: 16,
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              style: TextStyle(
                fontSize: 14,
                color: theme.hintColor.withOpacity(0.7),
              ),
            ),
          ],
        ],
      );
    } else if (serverProvider.servers.isEmpty && serverProvider.initMessage.isNotEmpty) {
      // 获取失败 - 通过检查initMessage是否不为空来判断（成功时会清空）
      borderColor = Colors.orange.withOpacity(0.3);
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.getNodesFailed,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.orange[700],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 重试按钮 - 添加防重复点击保护
          TextButton.icon(
            onPressed: serverProvider.isInitializing ? null : () async {
              await serverProvider.refreshFromCloudflare();
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(l10n.refresh),
            style: TextButton.styleFrom(
              foregroundColor: theme.primaryColor,
            ),
          ),
        ],
      );
    } else {
      // 其他情况（正常显示暂无节点）- 与正在获取节点时保持一致的布局
      content = InkWell(
        onTap: serverProvider.isInitializing ? null : () async {
          await serverProvider.refreshFromCloudflare();
        },
        borderRadius: BorderRadius.circular(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_download,
              size: 24,  // 与加载动画一样大
              color: theme.primaryColor,
            ),
            const SizedBox(width: 12),
            Text(
              l10n.noNodesHint,
              style: TextStyle(
                fontSize: 16,
                color: theme.primaryColor,  // 蓝色文字
                fontWeight: FontWeight.w500,
                // 不带下划线
              ),
            ),
          ],
        ),
      );
    }
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark 
            ? const Color(0xFF1E1E1E)  // 修改：深色主题使用固定背景色
            : theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: borderColor ?? theme.dividerColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.brightness == Brightness.dark
              ? Colors.black.withOpacity(0.2)
              : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: content,
    );
  }

  Widget _buildPingIndicator(int ping, bool isConnected) {
    final color = UIUtils.getPingColor(ping);
    final l10n = AppLocalizations.of(context);
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isConnected)
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              Text(
                l10n.latency,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${ping}ms',
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // 修改流量统计卡片 - 添加margin使宽度与节点卡片一致
  Widget _buildTrafficCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8), // 添加与节点卡片相同的margin
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
      decoration: BoxDecoration(
        // 修改：深色主题使用纯色背景
        color: theme.brightness == Brightness.dark 
            ? const Color(0xFF1E1E1E)
            : null,
        gradient: theme.brightness == Brightness.dark
            ? null
            : LinearGradient(
                colors: [
                  theme.primaryColor.withOpacity(0.1),
                  theme.primaryColor.withOpacity(0.05),
                ],
              ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: theme.brightness == Brightness.dark
              ? Colors.black.withOpacity(0.2)
              : Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 上传部分
          Expanded(
            child: _buildTrafficItem(
              icon: Icons.upload,
              label: l10n.upload,
              value: _uploadTotal,
              color: Colors.orange,
            ),
          ),
          // 分隔符
          Container(
            width: 1,
            height: 50,
            color: theme.dividerColor.withOpacity(0.3),
          ),
          // 下载部分
          Expanded(
            child: _buildTrafficItem(
              icon: Icons.download,
              label: l10n.download,
              value: _downloadTotal,
              color: Colors.blue,
            ),
          ),
        ],
      ),
    );
  }

  // 修改流量项布局 - 改为水平布局，左侧图标+文字，右侧数值（只在浅色主题显示白色描边）
  Widget _buildTrafficItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final isLight = theme.brightness == Brightness.light;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 左侧：图标和标签（垂直排列）
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标 - 只在浅色主题添加淡白色描边
              isLight
                ? Stack(
                    children: [
                      // 淡白色描边效果
                      Icon(
                        icon,
                        color: Colors.white.withOpacity(0.7),
                        size: 29,
                      ),
                      Icon(
                        icon,
                        color: color,
                        size: 28,
                      ),
                    ],
                  )
                : Icon(
                    icon,
                    color: color,
                    size: 28,
                  ),
              const SizedBox(height: 6),
              // 标签文字 - 只在浅色主题添加淡白色描边
              isLight
                ? Stack(
                    children: [
                      // 淡白色描边
                      Text(
                        label,
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
                        label,
                        style: TextStyle(
                          color: theme.hintColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  )
                : Text(
                    label,
                    style: TextStyle(
                      color: theme.hintColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
            ],
          ),
          // 右侧：流量数值 - 只在浅色主题添加淡白色描边
          isLight
            ? Stack(
                children: [
                  // 淡白色描边
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      foreground: Paint()
                        ..style = PaintingStyle.stroke
                        ..strokeWidth = 1
                        ..color = Colors.white.withOpacity(0.7),
                    ),
                  ),
                  // 实际文字
                  Text(
                    value,
                    style: TextStyle(
                      color: color,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              )
            : Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(ServerProvider serverProvider, ConnectionProvider connectionProvider, AppLocalizations l10n) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildActionButton(
          icon: Icons.flash_on,
          label: l10n.autoSelectNode,
          onTap: () async {
            // 选择最优服务器
            final servers = serverProvider.servers;
            if (servers.isNotEmpty) {
              final bestServer = servers.reduce((a, b) => a.ping < b.ping ? a : b);
              connectionProvider.setCurrentServer(bestServer);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${l10n.selectServer}: ${bestServer.name}'),
                ),
              );
            }
          },
        ),
        _buildActionButton(
          icon: Icons.speed,
          label: l10n.speedTest,
          onTap: () async {
            // 获取当前显示的服务器
            final currentServer = connectionProvider.currentServer;
            
            if (currentServer == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.noServers)),
              );
              return;
            }
            
            // 显示测速对话框 - 测试当前显示的服务器
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) => _SpeedTestDialog(currentServer: currentServer),
            );
          },
        ),
        _buildActionButton(
          icon: Icons.refresh,
          label: l10n.refresh,
          onTap: () async {
            // 手动触发V2Ray统计更新
            if (connectionProvider.isConnected) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('${l10n.refresh}...')),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.disconnected)),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: theme.brightness == Brightness.dark 
              ? const Color(0xFF1E1E1E)  // 修改：深色主题使用固定背景色
              : theme.cardColor,
          borderRadius: BorderRadius.circular(15),
          boxShadow: [
            BoxShadow(
              color: theme.brightness == Brightness.dark
                ? Colors.black.withOpacity(0.2)
                : Colors.black.withOpacity(0.05),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(
              icon, 
              color: theme.brightness == Brightness.dark
                ? Colors.white
                : theme.primaryColor
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// 速度测试对话框 - 修改为使用HTTPing
class _SpeedTestDialog extends StatefulWidget {
  final ServerModel? currentServer;
  
  const _SpeedTestDialog({
    this.currentServer,
  });
  
  @override
  State<_SpeedTestDialog> createState() => _SpeedTestDialogState();
}

class _SpeedTestDialogState extends State<_SpeedTestDialog> {
  bool _isTesting = true;
  Map<String, dynamic>? _testResults;
  
  @override
  void initState() {
    super.initState();
    _runSpeedTest();
  }
  
  Future<void> _runSpeedTest() async {
    final l10n = AppLocalizations.of(context);
    
    try {
      final serverProvider = context.read<ServerProvider>();
      final servers = serverProvider.servers;
      
      if (servers.isEmpty) {
        throw l10n.noServers;
      }
      
      // 如果有当前服务器，优先测试当前服务器
      final testServer = widget.currentServer ?? servers.first;
      
      // 使用HTTPing测试，端口80
      final results = await CloudflareTestService.testLatencyUnified(
        ips: [testServer.ip],
        port: 80,  // 使用80端口
        useHttping: true,  // 使用HTTPing
        singleTest: true,
      );
      
      if (results.isNotEmpty) {
        final result = results.first;
        final latency = result['latency'] ?? 999;
        
        // 修复：更新服务器的延迟值
        await serverProvider.updatePing(testServer.id, latency);
        
        // 如果这是当前选中的服务器，也更新ConnectionProvider中的引用
        final connectionProvider = context.read<ConnectionProvider>();
        if (connectionProvider.currentServer?.id == testServer.id) {
          // 重新设置当前服务器以触发UI更新
          final updatedServer = serverProvider.servers.firstWhere(
            (s) => s.id == testServer.id,
            orElse: () => testServer,
          );
          connectionProvider.setCurrentServer(updatedServer);
        }
        
        if (mounted) {
          setState(() {
            _testResults = {
              'success': true,
              'latency': latency,
              'serverName': testServer.name,
              'serverLocation': testServer.location,
            };
            _isTesting = false;
          });
        }
      } else {
        throw l10n.testFailed;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResults = {
            'success': false,
            'error': e.toString(),
          };
          _isTesting = false;
        });
      }
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.speed, color: Colors.blue),
          const SizedBox(width: 8),
          Text(l10n.speedTest),
        ],
      ),
      content: SizedBox(
        width: 300,
        child: _isTesting
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(l10n.testingLatency),
                const SizedBox(height: 8),
                const Text(
                  'HTTPing 80',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            )
          : _testResults != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_testResults!['success'] == true) ...[
                    Icon(
                      Icons.check_circle,
                      size: 48,
                      color: Colors.green[400],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _testResults!['serverName'] ?? l10n.currentServer,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      UIUtils.getLocalizedLocationInfo(_testResults!['serverLocation'] ?? '', context)['country'] ?? 
                      _testResults!['serverLocation'] ?? '',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _buildResultItem(
                      icon: Icons.network_ping,
                      label: l10n.latency,
                      value: '${_testResults!['latency']} ms',
                      color: UIUtils.getPingColor(_testResults!['latency']),
                    ),
                  ] else ...[
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red[400],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n.testFailed,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.red[700],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _testResults!['error'] ?? '',
                      style: const TextStyle(fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              )
          : const SizedBox.shrink(),
      ),
      actions: [
        if (!_isTesting) ...[
          TextButton(
            onPressed: () {
              setState(() {
                _isTesting = true;
                _testResults = null;
              });
              _runSpeedTest();
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
  
  Widget _buildResultItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
