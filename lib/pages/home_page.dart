import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';
import '../services/v2ray_service.dart';
import '../services/ad_service.dart';
import '../services/location_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _slideController;
  late AnimationController _loadingController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _loadingAnimation;
  
  String _uploadTotal = '0 KB';
  String _downloadTotal = '0 KB';
  String _connectedTime = '00:00:00';
  Timer? _connectedTimeTimer;
  StreamSubscription<V2RayStatus>? _statusSubscription;
  
  bool _isProcessing = false;
  bool _isDisconnecting = false;
  
  int _previousServerCount = 0;

  @override
  void initState() {
    super.initState();
    
    // 添加生命周期观察者
    WidgetsBinding.instance.addObserver(this);
    
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
    
    // 延迟设置监听器，确保context准备好
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 记录初始化日志（非阻塞）
      LogService.instance.info('HomePage初始化开始', tag: 'home');
      
      // 监听V2Ray状态流
      _statusSubscription = V2RayService.statusStream.listen((status) {
        if (mounted) {
          setState(() {
            _uploadTotal = UIUtils.formatBytes(status.upload);
            _downloadTotal = UIUtils.formatBytes(status.download);
          });
          
          // 同步连接状态（处理通知栏断开）
          final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
          if (status.state == V2RayConnectionState.disconnected && connectionProvider.isConnected) {
            // 记录日志（非阻塞）
            LogService.instance.warn('检测到VPN意外断开，同步状态', tag: 'home');
            connectionProvider.syncDisconnectedState();
            _stopConnectedTimeTimer();
          } else if (status.state == V2RayConnectionState.connected && !connectionProvider.isConnected) {
            // 记录日志（非阻塞）
            LogService.instance.info('检测到VPN已连接，同步状态', tag: 'home');
            connectionProvider.syncConnectedState();
            _startConnectedTimeTimer();
          }
        }
      });
      
      final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
      final serverProvider = Provider.of<ServerProvider>(context, listen: false);
      
      connectionProvider.setDialogContext(context);
      connectionProvider.addListener(_onConnectionChanged);
      serverProvider.addListener(_onServerListChanged);
      
      _previousServerCount = serverProvider.servers.length;
      
      _onConnectionChanged();
      
      // 初始化时同步VPN状态
      _syncVpnStatus();
      
      _checkAndShowImageAd();
      LocationService().sendAnalytics(context, 'home');
    });
  }

  @override
  void dispose() {
    // 记录日志（非异步）
    LogService.instance.info('HomePage销毁', tag: 'home');
    WidgetsBinding.instance.removeObserver(this);
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
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 记录日志（非阻塞）
      LogService.instance.info('应用从后台恢复', tag: 'home');
      // 应用从后台恢复，同步VPN状态
      _syncVpnStatus();
      
      // 如果已连接，触发一次流量更新
      if (mounted) {
        final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
        if (connectionProvider.isConnected) {
          V2RayService.queryConnectionState().then((state) {
            if (state == V2RayConnectionState.connected) {
              // 触发流量统计更新
              if (Platform.isAndroid || Platform.isIOS) {
                const channel = MethodChannel('com.example.cfvpn/v2ray');
                channel.invokeMethod('getTrafficStats').then((stats) {
                  if (stats != null && mounted) {
                    final upload = stats['uploadTotal'] ?? 0;
                    final download = stats['downloadTotal'] ?? 0;
                    // 记录流量统计日志（非阻塞）
                    LogService.instance.debug(
                      '流量统计更新 - 上传: ${UIUtils.formatBytes(upload)}, 下载: ${UIUtils.formatBytes(download)}', 
                      tag: 'home'
                    );
                    setState(() {
                      _uploadTotal = UIUtils.formatBytes(upload);
                      _downloadTotal = UIUtils.formatBytes(download);
                    });
                  }
                });
              }
            }
          });
        }
      }
    }
  }
  
  Future<void> _syncVpnStatus() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    try {
      final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
      final actualState = await V2RayService.queryConnectionState();
      
      if (actualState == V2RayConnectionState.connected && !connectionProvider.isConnected) {
        // 实际已连接但显示未连接
        await LogService.instance.info('同步VPN状态: 实际已连接，更新UI状态', tag: 'home');
        connectionProvider.syncConnectedState();
        _startConnectedTimeTimer();
      } else if (actualState == V2RayConnectionState.disconnected && connectionProvider.isConnected) {
        // 实际已断开但显示已连接
        await LogService.instance.info('同步VPN状态: 实际已断开，更新UI状态', tag: 'home');
        connectionProvider.syncDisconnectedState();
        _stopConnectedTimeTimer();
      }
    } catch (e) {
      await LogService.instance.error('同步VPN状态失败', tag: 'home', error: e);
    }
  }

  void _onConnectionChanged() {
    final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
    
    if (connectionProvider.disconnectReason != null && mounted) {
      final l10n = AppLocalizations.of(context);
      String message = '';
      
      switch (connectionProvider.disconnectReason) {
        case 'unexpected_exit':
          message = l10n.vpnDisconnected;
          // 记录日志（非阻塞）
          LogService.instance.warn('VPN意外退出', tag: 'home');
          break;
        default:
          message = l10n.connectionLost;
          // 记录日志（非阻塞）
          LogService.instance.warn('连接丢失: ${connectionProvider.disconnectReason}', tag: 'home');
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
    } else {
      _stopConnectedTimeTimer();
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
    
    if (_previousServerCount == 0 && currentServerCount > 0) {
      // 记录日志（非阻塞）
      LogService.instance.info('服务器列表更新，数量: $currentServerCount', tag: 'home');
      if (connectionProvider.currentServer == null) {
        final bestServer = serverProvider.servers.reduce((a, b) => a.ping < b.ping ? a : b);
        connectionProvider.setCurrentServer(bestServer);
        // 记录日志（非阻塞）
        LogService.instance.info('自动选择最优节点: ${bestServer.name} (${bestServer.ping}ms)', tag: 'home');
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.autoSelectedBestNode(bestServer.name, bestServer.ping)),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    else if (serverProvider.servers.isEmpty && !serverProvider.isInitializing && serverProvider.initMessage.isNotEmpty) {
      // 记录日志（非阻塞）
      LogService.instance.error('获取节点失败: ${serverProvider.initMessage}', tag: 'home');
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
    _updateConnectedTime();
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

  void _checkAndShowImageAd() async {
    final adService = context.read<AdService>();
    final imageAd = await adService.getImageAdForPageAsync('home');
    
    if (imageAd != null) {
      final imageUrl = imageAd.content.imageUrl;
      
      if (imageUrl == null || imageUrl.isEmpty) {
        return;
      }
      
      try {
        if (imageUrl.startsWith('assets/')) {
          await precacheImage(AssetImage(imageUrl), context);
        } else {
          await precacheImage(NetworkImage(imageUrl), context);
        }
        
        await Future.delayed(const Duration(milliseconds: 500));
        
        if (mounted) {
          _showImageAdOverlay(imageAd);
        }
      } catch (e) {
        await LogService.instance.error('广告图片预加载失败', tag: 'home', error: e);
      }
    }
  }

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

  Widget _buildConnectionButton(bool isConnected, ConnectionProvider provider, AppLocalizations l10n) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _isProcessing ? null : () async {
          Feedback.forTap(context);
          
          // 如果未连接，先检查是否有可用节点
          if (!isConnected) {
            final serverProvider = Provider.of<ServerProvider>(context, listen: false);
            if (serverProvider.servers.isEmpty) {
              // 没有节点，显示提示
              await LogService.instance.warn('尝试连接但没有可用节点', tag: 'home');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.noNodesHint),
                  backgroundColor: Colors.orange,
                  action: SnackBarAction(
                    label: l10n.addServer,
                    textColor: Colors.white,
                    onPressed: () {
                      // 直接导航到添加服务器对话框
                      _showAddServerDialog();
                    },
                  ),
                  duration: const Duration(seconds: 4),
                ),
              );
              return;
            }
            
            // 检查当前是否选中了服务器
            if (provider.currentServer == null && serverProvider.servers.isNotEmpty) {
              // 自动选择最优服务器
              final bestServer = serverProvider.servers.reduce((a, b) => a.ping < b.ping ? a : b);
              provider.setCurrentServer(bestServer);
              await LogService.instance.info('自动选择服务器: ${bestServer.name}', tag: 'home');
            }
          }
          
          setState(() {
            _isProcessing = true;
            if (isConnected) {
              _isDisconnecting = true;
            }
          });
          
          _loadingController.repeat();
          
          try {
            if (isConnected) {
              await LogService.instance.info('开始断开VPN连接', tag: 'home');
              await provider.disconnect();
              await LogService.instance.info('VPN已断开连接', tag: 'home');
            } else {
              final server = provider.currentServer;
              await LogService.instance.info('开始连接VPN - 服务器: ${server?.name ?? "未知"}', tag: 'home');
              await provider.connect();
              // 连接成功后请求电池优化豁免（仅Android）
              if (Platform.isAndroid && provider.isConnected) {
                await LogService.instance.info('VPN连接成功 - 服务器: ${server?.name ?? "未知"}', tag: 'home');
                _requestBatteryOptimizationExemption();
              } else if (provider.isConnected) {
                await LogService.instance.info('VPN连接成功 - 服务器: ${server?.name ?? "未知"}', tag: 'home');
              }
            }
          } catch (e) {
            await LogService.instance.error(
              isConnected ? '断开VPN失败' : '连接VPN失败',
              tag: 'home',
              error: e
            );
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
                      ? [Colors.red.shade400, Colors.red.shade600]
                      : [Colors.orange.shade400, Colors.orange.shade600]
                    : isConnected
                      ? [Colors.green.shade400, Colors.green.shade600]
                      : [Colors.blue.shade400, Colors.blue.shade600],
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
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
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
  
  Future<void> _requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    
    try {
      const channel = MethodChannel('com.example.cfvpn/v2ray');
      final needRequest = await channel.invokeMethod<bool>('requestBatteryOptimization');
      if (needRequest == true) {
        await LogService.instance.info('已请求电池优化豁免', tag: 'home');
      } else {
        await LogService.instance.info('已有电池优化豁免权限', tag: 'home');
      }
    } catch (e) {
      await LogService.instance.error('请求电池优化豁免失败', tag: 'home', error: e);
    }
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

  // 修改：处理 ServerProvider 的国际化显示，添加完整的detailKey处理
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
      
      // 根据 detailKey 显示本地化详情，添加完整的处理
      if (serverProvider.initDetail.isNotEmpty) {
        switch (serverProvider.initDetail) {
          case 'initializing':
            detail = l10n.initializing;
            break;
          case 'startingTraceTest':
            detail = l10n.startingTraceTest;
            break;
          case 'preparingTestEnvironment':
            detail = l10n.preparingTestEnvironment;
            break;
          case 'nodeProgress':
            // 处理nodeProgress，显示进度信息
            detail = '${l10n.testing}...';
            break;
          case 'ipRanges':
            // 处理ipRanges
            detail = l10n.samplingFromRanges(0);  // 这里简化处理，不显示具体数量
            break;
          case 'foundQualityNodes':
            // 处理foundQualityNodes
            detail = l10n.foundNodes(0);  // 这里简化处理，不显示具体数量
            break;
          default:
            // 对于其他未处理的key，不直接显示，而是显示通用提示
            if (serverProvider.initDetail.contains('progress') || 
                serverProvider.initDetail.contains('node')) {
              detail = '${l10n.testing}...';
            } else {
              detail = '';  // 不显示未知的key
            }
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
          // 重试按钮 - 使用isRefreshing防止重复点击
          TextButton.icon(
            onPressed: serverProvider.isRefreshing ? null : () async {
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
      // 其他情况（正常显示暂无节点）- 使用isRefreshing防止重复点击
      content = InkWell(
        onTap: serverProvider.isRefreshing ? null : () async {
          await serverProvider.refreshFromCloudflare();
        },
        borderRadius: BorderRadius.circular(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_download,
              size: 24,  // 与加载动画一样大
              color: serverProvider.isRefreshing 
                  ? theme.hintColor.withOpacity(0.5)  // 如果正在刷新，显示灰色
                  : theme.primaryColor,
            ),
            const SizedBox(width: 12),
            Text(
              l10n.noNodesHint,
              style: TextStyle(
                fontSize: 16,
                color: serverProvider.isRefreshing 
                    ? theme.hintColor.withOpacity(0.5)  // 如果正在刷新，显示灰色
                    : theme.primaryColor,  // 蓝色文字
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
              await LogService.instance.info('手动选择最优节点: ${bestServer.name} (${bestServer.ping}ms)', tag: 'home');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${l10n.selectServer}: ${bestServer.name}'),
                ),
              );
            } else {
              await LogService.instance.warn('尝试选择最优节点但服务器列表为空', tag: 'home');
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
              await LogService.instance.warn('尝试测速但未选择服务器', tag: 'home');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.noServers)),
              );
              return;
            }
            
            await LogService.instance.info('开始测速 - 服务器: ${currentServer.name}', tag: 'home');
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
              await LogService.instance.debug('手动刷新流量统计', tag: 'home');
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

  void _showAddServerDialog() {
    // TODO: 实现添加服务器对话框
    // 这里需要根据您的具体实现来添加
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return Consumer2<ConnectionProvider, ServerProvider>(
      builder: (context, connectionProvider, serverProvider, child) {
        final isConnected = connectionProvider.isConnected;
        final currentServer = connectionProvider.currentServer;
        
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.appTitle),
            centerTitle: true,
            elevation: 0,
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: Column(
                        children: [
                          // 连接按钮
                          _buildConnectionButton(isConnected, connectionProvider, l10n),
                          const SizedBox(height: 30),
                          
                          // 服务器信息卡片
                          if (currentServer != null)
                            _buildServerInfoCard(currentServer, isConnected, l10n)
                          else
                            _buildEmptyServerCard(l10n, serverProvider),
                          const SizedBox(height: 20),
                          
                          // 流量统计
                          if (isConnected)
                            _buildTrafficCard(l10n),
                          const SizedBox(height: 20),
                          
                          // 快速操作
                          _buildQuickActions(serverProvider, connectionProvider, l10n),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
      
      await LogService.instance.info('开始HTTPing测速 - ${testServer.name} (${testServer.ip}:80)', tag: 'home');
      
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
        
        await LogService.instance.info('测速完成 - ${testServer.name}: ${latency}ms', tag: 'home');
        
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
      await LogService.instance.error('测速失败', tag: 'home', error: e);
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

// ImageAdOverlay widget需要单独定义
class ImageAdOverlay extends StatelessWidget {
  final dynamic ad;
  final AdService adService;
  final VoidCallback onClose;

  const ImageAdOverlay({
    super.key,
    required this.ad,
    required this.adService,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // TODO: 实现广告覆盖层UI
    return Container();
  }
}
