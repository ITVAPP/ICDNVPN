import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/connection_provider.dart';
import '../providers/server_provider.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';
import '../l10n/app_localizations.dart';
import 'dart:math' as math;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _slideController;
  late AnimationController _loadingController;
  late Animation<double> _pulseAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _loadingAnimation;
  
  // 流量统计（模拟数据，实际应从V2Ray获取）
  String _uploadSpeed = '0 KB/s';
  String _downloadSpeed = '0 KB/s';
  String _connectedTime = '00:00:00';
  
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    
    // 脉冲动画控制器
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    
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
    _pulseAnimation = Tween<double>(
      begin: 0.95,
      end: 1.05,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));
    
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
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _slideController.dispose();
    _loadingController.dispose();
    super.dispose();
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
                      const SizedBox(height: 40),
                      
                      // 主连接按钮
                      SlideTransition(
                        position: _slideAnimation,
                        child: _buildConnectionButton(isConnected, connectionProvider, l10n),
                      ),
                      const SizedBox(height: 40),
                      
                      // 服务器信息卡片
                      if (currentServer != null)
                        _buildServerInfoCard(currentServer, isConnected, l10n),
                      
                      // 流量统计卡片
                      if (isConnected) ...[
                        const SizedBox(height: 20),
                        _buildTrafficCard(l10n),
                      ],
                      
                      // 快速操作按钮
                      const SizedBox(height: 30),
                      _buildQuickActions(serverProvider, l10n),
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
      cursor: SystemMouseCursors.click, // 鼠标悬停时显示手势
      child: GestureDetector(
        onTap: _isProcessing ? null : () async {
          // 触感反馈
          Feedback.forTap(context);
          
          setState(() {
            _isProcessing = true;
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
              });
              _loadingController.stop();
              _loadingController.reset();
            }
          }
        },
        child: AnimatedBuilder(
          animation: Listenable.merge([
            isConnected ? _pulseAnimation : _slideAnimation,
            _loadingAnimation,
          ]),
          builder: (context, child) {
            return Transform.scale(
              scale: isConnected && !_isProcessing ? _pulseAnimation.value : 1.0,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: _isProcessing
                      ? [
                          Colors.grey.shade400,
                          Colors.grey.shade600,
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
                        ? Colors.grey 
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
                    // 外圈动画
                    if (isConnected && !_isProcessing)
                      ...List.generate(3, (index) {
                        return AnimatedContainer(
                          duration: Duration(milliseconds: 1000 + (index * 500)),
                          width: 200 + (index * 40),
                          height: 200 + (index * 40),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.green.withOpacity(0.2 - (index * 0.05)),
                              width: 2,
                            ),
                          ),
                        );
                      }),
                    
                    // 中心图标 - 加载时旋转
                    Transform.rotate(
                      angle: _isProcessing ? _loadingAnimation.value : 0,
                      child: Icon(
                        _isProcessing 
                          ? Icons.sync
                          : (isConnected ? Icons.shield : Icons.shield_outlined),
                        size: 80,
                        color: Colors.white,
                      ),
                    ),
                    
                    // 状态文字 - 调整位置
                    Positioned(
                      bottom: 35, // 文字位置下移
                      child: AnimatedOpacity(
                        opacity: _isProcessing ? 0.7 : 1.0,
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _isProcessing 
                            ? (isConnected ? l10n.disconnecting : l10n.connecting)
                            : (isConnected ? l10n.clickToDisconnect : l10n.clickToConnect),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 16, // 文字增大
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildServerInfoCard(ServerModel server, bool isConnected, AppLocalizations l10n) {
    final theme = Theme.of(context);
    
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.symmetric(horizontal: 10),
      padding: const EdgeInsets.all(20),
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
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: theme.primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.dns, color: theme.primaryColor),
              ),
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
                          server.location,
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
          const SizedBox(height: 15),
          // IP地址栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                ? Colors.grey.shade800.withOpacity(0.5)
                : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'IP',
                  style: TextStyle(
                    color: theme.hintColor,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '${server.ip}:${server.port}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPingIndicator(int ping, bool isConnected) {
    final color = ping < 100 ? Colors.green : ping < 200 ? Colors.orange : Colors.red;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
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
            '${ping}ms',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrafficCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    
    return Container(
      padding: const EdgeInsets.all(20),
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
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildTrafficItem(
                icon: Icons.upload,
                label: l10n.upload,
                value: _uploadSpeed,
                color: Colors.orange,
              ),
              Container(
                width: 1,
                height: 40,
                color: theme.dividerColor,
              ),
              _buildTrafficItem(
                icon: Icons.download,
                label: l10n.download,
                value: _downloadSpeed,
                color: Colors.blue,
              ),
            ],
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
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).hintColor,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActions(ServerProvider serverProvider, AppLocalizations l10n) {
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
              context.read<ConnectionProvider>().setCurrentServer(bestServer);
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
            final connectionProvider = context.read<ConnectionProvider>();
            if (!connectionProvider.isConnected) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.noAvailableServer)),
              );
              return;
            }
            
            // 显示测速对话框
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (context) => _SpeedTestDialog(),
            );
          },
        ),
        _buildActionButton(
          icon: Icons.refresh,
          label: l10n.refresh,
          onTap: () async {
            // 刷新服务器列表延迟
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${l10n.refresh}...')),
            );
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
            Icon(icon, color: theme.primaryColor),
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

// 速度测试对话框 - 使用统一的testLatency方法
class _SpeedTestDialog extends StatefulWidget {
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
      final connectionProvider = context.read<ConnectionProvider>();
      final currentServer = connectionProvider.currentServer;
      
      if (currentServer == null) {
        throw l10n.noAvailableServer;
      }
      
      // 使用统一的testLatency方法测试当前服务器
      final latencyMap = await CloudflareTestService.testLatency([currentServer.ip]);
      final latency = latencyMap[currentServer.ip] ?? 999;
      
      if (mounted) {
        setState(() {
          _testResults = {
            'success': true,
            'latency': latency,
            'serverName': currentServer.name,
            'serverLocation': currentServer.location,
          };
          _isTesting = false;
        });
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
                  '',
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
                      color: _getPingColor(_testResults!['latency']),
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
            child: Text(l10n.disconnect), // 使用"断开"作为关闭按钮文字
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
  
  Color _getPingColor(int ping) {
    if (ping < 50) return Colors.green;
    if (ping < 100) return Colors.lightGreen;
    if (ping < 150) return Colors.orange;
    if (ping < 200) return Colors.deepOrange;
    return Colors.red;
  }
}