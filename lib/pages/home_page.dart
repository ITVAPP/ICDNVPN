import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';
import '../services/v2ray_service.dart';
import '../services/ad_service.dart';
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
    
    // 监听V2Ray状态流
    _statusSubscription = V2RayService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _uploadTotal = UIUtils.formatBytes(status.upload);
          _downloadTotal = UIUtils.formatBytes(status.download);
        });
      }
    });
    
    // 监听连接状态变化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
      final serverProvider = Provider.of<ServerProvider>(context, listen: false);
      
      connectionProvider.addListener(_onConnectionChanged);
      serverProvider.addListener(_onServerListChanged);
      
      // 初始化服务器数量
      _previousServerCount = serverProvider.servers.length;
      
      _onConnectionChanged();
      
      // 新增：检查是否显示图片广告
      _checkAndShowImageAd();
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
  
  void _onConnectionChanged() {
    final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
    if (connectionProvider.isConnected) {
      _startConnectedTimeTimer();
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
    
    // 检测服务器列表从空变为非空（获取成功）
    if (_previousServerCount == 0 && currentServerCount > 0) {
      // 如果当前没有选中的服务器，自动选择最优的
      if (connectionProvider.currentServer == null) {
        final bestServer = serverProvider.servers.reduce((a, b) => a.ping < b.ping ? a : b);
        connectionProvider.setCurrentServer(bestServer);
        
        // 显示提示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已自动选择最优节点: ${bestServer.name} (${bestServer.ping}ms)'),
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
          content: const Text('获取节点失败，请检查网络连接后重试'),
          backgroundColor: Colors.red,
          action: SnackBarAction(
            label: '重试',
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

  // 新增：检查并显示图片广告
  void _checkAndShowImageAd() async {
    final adService = context.read<AdService>();
    final imageAd = await adService.getImageAdForPageAsync('home');
    
    if (imageAd != null) {
      // 延迟显示，等页面完全加载
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _showImageAdOverlay(imageAd);
        }
      });
    }
  }

  // 新增：显示图片广告遮罩
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
              final isConnected = connectionProvider.isConnected;
              final currentServer = connectionProvider.currentServer;
              
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 20.0,
                    right: 20.0,
                    top: 60.0, // 增加顶部内边距，为自定义标题栏留出空间
                    bottom: 20.0,
                  ),
                  child: Column(
                    children: [
                      // 顶部状态栏
                      _buildStatusBar(isConnected, l10n),
                      const SizedBox(height: 28), // 减少间距
                      
                      // 主连接按钮
                      SlideTransition(
                        position: _slideAnimation,
                        child: _buildConnectionButton(isConnected, connectionProvider, l10n),
                      ),
                      const SizedBox(height: 28), // 减少间距
                      
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
                      const SizedBox(height: 30),
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

  Widget _buildConnectionButton(bool isConnected, ConnectionProvider provider, AppLocalizations l10n) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _isProcessing ? null : () async {
          // 触感反馈
          Feedback.forTap(context);
          
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
    final locationInfo = UIUtils.getLocationInfo(server.location);
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
      decoration: BoxDecoration(
        color: theme.cardColor,
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

  // 修改：添加serverProvider参数以获取状态
  Widget _buildEmptyServerCard(AppLocalizations l10n, ServerProvider serverProvider) {
    final theme = Theme.of(context);
    
    // 根据状态显示不同内容
    Widget content;
    Color? borderColor;
    
    if (serverProvider.isInitializing) {
      // 正在初始化/获取节点
      content = Row(
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
            l10n.gettingNodes,
            style: TextStyle(
              fontSize: 16,
              color: theme.hintColor,
            ),
          ),
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
      // 其他情况（正常显示暂无节点）
      content = InkWell(
        onTap: serverProvider.isInitializing ? null : () async {
          await serverProvider.refreshFromCloudflare();
        },
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: theme.hintColor.withOpacity(0.5),
            ),
            const SizedBox(height: 12),
            // 文字本身作为可点击链接
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    l10n.noNodesHint,
                    style: TextStyle(
                      fontSize: 16,
                      color: serverProvider.isInitializing 
                          ? theme.hintColor 
                          : theme.primaryColor, // 非初始化时使用主题色表示可点击
                      fontWeight: FontWeight.w500,
                      decoration: serverProvider.isInitializing 
                          ? null 
                          : TextDecoration.underline, // 添加下划线表示链接
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                if (!serverProvider.isInitializing) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.cloud_download,
                    size: 18,
                    color: theme.primaryColor,
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
      decoration: BoxDecoration(
        color: theme.cardColor,
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
      margin: const EdgeInsets.symmetric(horizontal: 10), // 添加与节点卡片相同的margin
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // 统一内边距
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: theme.brightness == Brightness.dark
            ? [
                theme.primaryColor.withOpacity(0.2),
                theme.primaryColor.withOpacity(0.1),
              ]
            : [
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

  // 修改流量项布局 - 改为水平布局，左侧图标+文字，右侧数值（添加白色描边）
  Widget _buildTrafficItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 左侧：图标和标签（垂直排列）
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标添加淡白色描边
              Stack(
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
              ),
              const SizedBox(height: 6),
              // 标签文字添加淡白色描边
              Stack(
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
                      color: Theme.of(context).hintColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // 右侧：流量数值 - 添加淡白色描边
          Stack(
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
          color: theme.cardColor,
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
                const SizedBox(height: 16),
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
                    const SizedBox(height: 16),
                    Text(
                      _testResults!['serverName'] ?? l10n.currentServer,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      UIUtils.getLocationInfo(_testResults!['serverLocation'] ?? '')['country'] ?? 
                      _testResults!['serverLocation'] ?? '',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 16),
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
                    const SizedBox(height: 16),
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
            child: Text(l10n.close ?? '关闭'),
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