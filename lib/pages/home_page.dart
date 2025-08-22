import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';
import '../services/v2ray_service.dart';
import '../services/ad_service.dart';
import '../services/location_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/ui_utils.dart';
import '../app_config.dart';

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
    
    _slideController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _loadingController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
    
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
      _statusSubscription = V2RayService.statusStream.listen((status) {
        if (mounted && status.state == V2RayConnectionState.connected) {
          setState(() {
            _uploadTotal = UIUtils.formatBytes(status.upload);
            _downloadTotal = UIUtils.formatBytes(status.download);
          });
        }
      });
    } else if (Platform.isWindows) {
      _statusSubscription = V2RayService.statusStream.listen((status) {
        if (mounted) {
          setState(() {
            _uploadTotal = UIUtils.formatBytes(status.upload);
            _downloadTotal = UIUtils.formatBytes(status.download);
          });
        }
      });
    }
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final connectionProvider = Provider.of<ConnectionProvider>(context, listen: false);
      final serverProvider = Provider.of<ServerProvider>(context, listen: false);
      
      connectionProvider.setDialogContext(context);
      
      connectionProvider.addListener(_onConnectionChanged);
      serverProvider.addListener(_onServerListChanged);
      
      _previousServerCount = serverProvider.servers.length;
      
      _onConnectionChanged();
      
      _checkAndShowImageAd();
      
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
  
  Future<void> _checkAndRequestBatteryOptimization() async {
    if (!Platform.isAndroid) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasPrompted = prefs.getBool('battery_optimization_prompted') ?? false;
      if (hasPrompted) return;
      
      final channel = const MethodChannel('com.example.cfvpn/v2ray');
      final needsOptimization = await channel.invokeMethod<bool>('requestBatteryOptimization');
      
      if (needsOptimization == true && mounted) {
        await prefs.setBool('battery_optimization_prompted', true);
        
        await Future.delayed(const Duration(seconds: 3));
        
        if (!mounted) return;
        
        final l10n = AppLocalizations.of(context);
        
        final shouldRequest = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.battery_charging_full, color: Colors.green, size: 48),
            title: Text(l10n.batteryOptimization),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.batteryOptimizationHintFormat(AppConfig.appName)),
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
                          l10n.recommended,
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
                child: Text(l10n.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.openSettings),
              ),
            ],
          ),
        );
        
        if (shouldRequest == true) {
          await channel.invokeMethod('requestBatteryOptimization');
        }
      }
    } catch (e) {
      debugPrint('检查电池优化失败: $e');
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
          break;
        case 'service_stopped':
          message = l10n.vpnDisconnected;
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
      if (connectionProvider.currentServer == null) {
        final bestServer = serverProvider.servers.reduce((a, b) => a.ping < b.ping ? a : b);
        connectionProvider.setCurrentServer(bestServer);
        
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
        debugPrint('广告图片预加载失败: $e');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
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
              connectionProvider.setDialogContext(context);
              
              final isConnected = connectionProvider.isConnected;
              final currentServer = connectionProvider.currentServer;
              
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 20.0,
                    right: 20.0,
                    top: 52.0,
                    bottom: 20.0,
                  ),
                  child: Column(
                    children: [
                      _buildStatusBar(isConnected, l10n),
                      const SizedBox(height: 30),
                      
                      SlideTransition(
                        position: _slideAnimation,
                        child: _buildConnectionButton(isConnected, connectionProvider, l10n),
                      ),
                      const SizedBox(height: 30),
                      
                      SlideTransition(
                        position: _slideAnimation,
                        child: currentServer != null
                          ? _buildServerInfoCard(currentServer, isConnected, l10n)
                          : _buildEmptyServerCard(l10n, serverProvider),
                      ),
                      
                      if (isConnected) ...[
                        const SizedBox(height: 20),
                        _buildTrafficCard(l10n),
                      ],
                      
                      const SizedBox(height: 20),
                      _buildQuickActions(serverProvider, connectionProvider, l10n),
                      
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
          Feedback.forTap(context);
          
          // 未连接时检查节点
          if (!isConnected) {
            final serverProvider = Provider.of<ServerProvider>(context, listen: false);
            
            if (serverProvider.isInitializing) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.gettingNodes),
                  backgroundColor: Colors.blue,
                  duration: const Duration(seconds: 2),
                ),
              );
              return;
            }
            
            if (serverProvider.servers.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.noServers),
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
              return;
            }
            
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
                      ? [
                          Colors.red.shade400,
                          Colors.red.shade600,
                        ]
                      : [
                          Colors.orange.shade400,
                          Colors.orange.shade600,
                        ]
                    : isConnected
                      ? [
                          Colors.green.shade400,
                          Colors.green.shade600,
                        ]
                      : [
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

  Widget _buildServerInfoCard(ServerModel server, bool isConnected, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final locationInfo = UIUtils.getLocalizedLocationInfo(server.location, context);
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark 
            ? const Color(0xFF1E1E1E)
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
              _buildPingIndicator(server.ping, isConnected),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyServerCard(AppLocalizations l10n, ServerProvider serverProvider) {
    final theme = Theme.of(context);
    
    Widget content;
    Color? borderColor;
    
    if (serverProvider.isInitializing) {
      String message = l10n.gettingNodes;
      String detail = '';
      
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
              size: 24,
              color: theme.primaryColor,
            ),
            const SizedBox(width: 12),
            Text(
              l10n.noNodesHint,
              style: TextStyle(
                fontSize: 16,
                color: theme.primaryColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark 
            ? const Color(0xFF1E1E1E)
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

  Widget _buildTrafficCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
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
          Expanded(
            child: _buildTrafficItem(
              icon: Icons.upload,
              label: l10n.upload,
              value: _uploadTotal,
              color: Colors.orange,
            ),
          ),
          Container(
            width: 1,
            height: 50,
            color: theme.dividerColor.withOpacity(0.3),
          ),
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
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              isLight
                ? Stack(
                    children: [
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
              isLight
                ? Stack(
                    children: [
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
          isLight
            ? Stack(
                children: [
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
            final currentServer = connectionProvider.currentServer;
            
            if (currentServer == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.noServers)),
              );
              return;
            }
            
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
              ? const Color(0xFF1E1E1E)
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
      
      final testServer = widget.currentServer ?? servers.first;
      
      final results = await CloudflareTestService.testLatencyUnified(
        ips: [testServer.ip],
        port: 80,
        useHttping: true,
        singleTest: true,
      );
      
      if (results.isNotEmpty) {
        final result = results.first;
        final latency = result['latency'] ?? 999;
        
        await serverProvider.updatePing(testServer.id, latency);
        
        final connectionProvider = context.read<ConnectionProvider>();
        if (connectionProvider.currentServer?.id == testServer.id) {
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
