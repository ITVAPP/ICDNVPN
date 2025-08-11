import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';
import '../app_config.dart';

/// V2Ray连接模式
enum V2RayConnectionMode {
  vpnTun,      // VPN隧道模式（全局）
  proxyOnly    // 仅代理模式（局部，不创建VPN）
}

/// 应用代理模式
enum AppProxyMode {
  exclude,     // 排除模式：指定的应用不走代理
  include      // 包含模式：仅指定的应用走代理
}

/// V2Ray连接状态
enum V2RayConnectionState {
  disconnected,
  connecting,
  connected,
  error
}

/// V2Ray状态信息
class V2RayStatus {
  final String duration;
  final int uploadSpeed;
  final int downloadSpeed;
  final int upload;
  final int download;
  final V2RayConnectionState state;

  V2RayStatus({
    this.duration = "00:00:00",
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
    this.state = V2RayConnectionState.disconnected,
  });
  
  // 从原始状态字符串转换 - 处理多种格式
  static V2RayConnectionState parseState(String stateStr) {
    final upperStr = stateStr.toUpperCase();
    // 处理V2RAY_前缀格式和普通格式
    if (upperStr.contains('CONNECTED') && !upperStr.contains('DISCONNECTED')) {
      return V2RayConnectionState.connected;
    } else if (upperStr.contains('CONNECTING')) {
      return V2RayConnectionState.connecting;
    } else if (upperStr.contains('ERROR')) {
      return V2RayConnectionState.error;
    } else {
      return V2RayConnectionState.disconnected;
    }
  }
  
  // 复制并更新部分字段
  V2RayStatus copyWith({
    String? duration,
    int? uploadSpeed,
    int? downloadSpeed,
    int? upload,
    int? download,
    V2RayConnectionState? state,
  }) {
    return V2RayStatus(
      duration: duration ?? this.duration,
      uploadSpeed: uploadSpeed ?? this.uploadSpeed,
      downloadSpeed: downloadSpeed ?? this.downloadSpeed,
      upload: upload ?? this.upload,
      download: download ?? this.download,
      state: state ?? this.state,
    );
  }
}

/// V2Ray服务管理类 - 统一Windows和移动端实现
class V2RayService {
  // Windows平台进程管理
  static Process? _v2rayProcess;
  
  // 服务状态管理
  static bool _isRunning = false;
  
  // 回调函数
  static Function? _onProcessExit;
  
  // 流量统计
  static int _uploadTotal = 0;
  static int _downloadTotal = 0;
  static Timer? _statsTimer;
  
  // 速度计算
  static int _lastUpdateTime = 0;
  static int _lastUploadBytes = 0;
  static int _lastDownloadBytes = 0;
  
  // 连接时长
  static DateTime? _connectionStartTime;
  static Timer? _durationTimer;
  
  // 状态管理
  static V2RayStatus _currentStatus = V2RayStatus();
  static final StreamController<V2RayStatus> _statusController = 
      StreamController<V2RayStatus>.broadcast(sync: true);
  static Stream<V2RayStatus> get statusStream => _statusController.stream;
  
  // 并发控制
  static bool _isStarting = false;
  static bool _isStopping = false;
  
  // 日志服务
  static final LogService _log = LogService.instance;
  static const String _logTag = 'V2RayService';
  
  // 原生平台通信通道
  static const MethodChannel _channel = MethodChannel('com.example.cfvpn/v2ray');
  static bool _isChannelInitialized = false;
  static Timer? _statusCheckTimer;  // 移动端状态检查定时器
  
  // 记录是否已记录V2Ray目录信息
  static bool _hasLoggedV2RayInfo = false;
  
  // 配置文件路径 - 根据平台选择
  static String get _CONFIG_PATH {
    if (Platform.isAndroid || Platform.isIOS) {
      return 'assets/js/v2ray_config_mobile.json';  // 移动端配置
    } else {
      return 'assets/js/v2ray_config.json';  // 桌面端配置
    }
  }
  
  // 平台相关的可执行文件名
  static String get _v2rayExecutableName {
    if (Platform.isWindows) {
      return 'v2ray.exe';
    } else {
      return 'v2ray';
    }
  }
  
  static String get _v2ctlExecutableName {
    if (Platform.isWindows) {
      return 'v2ctl.exe';
    } else {
      return 'v2ctl';
    }
  }
  
  // 获取可执行文件路径（仅桌面平台）
  static Future<String> getExecutablePath(String executableName) async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError('Mobile platforms use native V2Ray integration');
    }
    
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final directory = path.dirname(exePath);
      return path.join(directory, executableName);
    } else if (Platform.isMacOS || Platform.isLinux) {
      final systemPath = path.join('/usr/local/bin', executableName);
      if (await File(systemPath).exists()) {
        return systemPath;
      }
      
      final exePath = Platform.resolvedExecutable;
      final directory = path.dirname(exePath);
      return path.join(directory, executableName);
    } else {
      throw UnsupportedError('Platform not supported');
    }
  }
  
  static Future<String> _getV2RayPath() async {
    return getExecutablePath(path.join('v2ray', _v2rayExecutableName));
  }
  
  // 设置进程退出回调（仅Windows）
  static void setOnProcessExit(Function callback) {
    _onProcessExit = callback;
  }
  
  // 获取当前状态
  static V2RayStatus get currentStatus => _currentStatus;
  
  // 获取连接状态
  static V2RayConnectionState get connectionState => _currentStatus.state;
  
  // 是否已连接
  static bool get isConnected => _currentStatus.state == V2RayConnectionState.connected;
  
  // 是否正在运行
  static bool get isRunning => _isRunning;
  
  // 安全解析整数
  static int _parseIntSafely(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }
  
  // 初始化原生通道监听器（移动平台）
  static void _initializeChannelListeners() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_isChannelInitialized) return;
    
    _log.info('初始化原生通道监听器', tag: _logTag);
    
    // 设置方法调用处理器，接收从原生端发来的调用
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onVpnConnected':
          _handleNativeStatusChange(V2RayConnectionState.connected);
          break;
        case 'onVpnDisconnected':
          _handleNativeStatusChange(V2RayConnectionState.disconnected);
          break;
        case 'onVpnStatusChanged':
          final status = call.arguments['status'] as String?;
          final error = call.arguments['error'] as String?;
          if (status != null) {
            _handleNativeStatusString(status, error);
          }
          break;
        case 'onVpnPermissionGranted':
          _log.info('VPN权限已授予', tag: _logTag);
          break;
        case 'onVpnPermissionDenied':
          _log.info('VPN权限被拒绝', tag: _logTag);
          break;
        case 'onNotificationPermissionGranted':
          _log.info('通知权限已授予', tag: _logTag);
          break;
        case 'onNotificationPermissionDenied':
          _log.info('通知权限被拒绝', tag: _logTag);
          break;
        case 'onVpnStatusUpdate':
          final message = call.arguments as String?;
          if (message != null) {
            _log.info('VPN状态: $message', tag: _logTag);
          }
          break;
      }
    });
    
    _isChannelInitialized = true;
  }
  
  // 处理原生端状态字符串
  static void _handleNativeStatusString(String status, String? error) {
    V2RayConnectionState state;
    
    switch (status.toLowerCase()) {
      case 'connecting':
        state = V2RayConnectionState.connecting;
        break;
      case 'connected':
        state = V2RayConnectionState.connected;
        break;
      case 'disconnecting':
      case 'disconnected':
        state = V2RayConnectionState.disconnected;
        break;
      case 'error':
        state = V2RayConnectionState.error;
        if (error != null) {
          _log.error('VPN错误: $error', tag: _logTag);
        }
        break;
      default:
        state = V2RayConnectionState.disconnected;
    }
    
    _handleNativeStatusChange(state);
  }
  
  // 处理原生端状态变化
  static void _handleNativeStatusChange(V2RayConnectionState newState) {
    _log.info('原生状态变化: $newState', tag: _logTag);
    
    // 更新运行状态
    final wasRunning = _isRunning;
    _isRunning = (newState == V2RayConnectionState.connected);
    
    // 更新连接时间
    if (newState == V2RayConnectionState.connected && !wasRunning) {
      _connectionStartTime = DateTime.now();
      _startMobileStatusTimer();  // 启动状态更新定时器
    } else if (newState == V2RayConnectionState.disconnected && wasRunning) {
      _connectionStartTime = null;
      _stopMobileStatusTimer();  // 停止状态更新定时器
    }
    
    // 更新状态
    _updateStatus(_currentStatus.copyWith(state: newState));
  }
  
  // 启动移动端状态定时器
  static void _startMobileStatusTimer() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    _stopMobileStatusTimer();
    
    // 立即更新一次
    _updateMobileStatus();
    
    // 定期更新状态
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_isRunning) {
        _updateMobileStatus();
      }
    });
  }
  
  // 停止移动端状态定时器
  static void _stopMobileStatusTimer() {
    _statusCheckTimer?.cancel();
    _statusCheckTimer = null;
  }
  
  // 更新移动端状态（包括流量统计）
  static Future<void> _updateMobileStatus() async {
    if (!_isRunning) return;
    
    try {
      // 获取流量统计
      final stats = await _channel.invokeMethod<Map>('getTrafficStats');
      if (stats != null) {
        _uploadTotal = _parseIntSafely(stats['uploadTotal']);
        _downloadTotal = _parseIntSafely(stats['downloadTotal']);
        
        // 计算速度
        final now = DateTime.now().millisecondsSinceEpoch;
        int uploadSpeed = 0;
        int downloadSpeed = 0;
        
        if (_lastUpdateTime > 0) {
          final timeDiff = (now - _lastUpdateTime) / 1000.0;
          if (timeDiff > 0) {
            uploadSpeed = ((_uploadTotal - _lastUploadBytes) / timeDiff).round();
            downloadSpeed = ((_downloadTotal - _lastDownloadBytes) / timeDiff).round();
            
            if (uploadSpeed < 0) uploadSpeed = 0;
            if (downloadSpeed < 0) downloadSpeed = 0;
          }
        }
        
        _lastUpdateTime = now;
        _lastUploadBytes = _uploadTotal;
        _lastDownloadBytes = _downloadTotal;
        
        // 计算时长
        final duration = _calculateDuration();
        
        // 更新状态
        _updateStatus(V2RayStatus(
          state: _currentStatus.state,
          duration: duration,
          upload: _uploadTotal,
          download: _downloadTotal,
          uploadSpeed: uploadSpeed,
          downloadSpeed: downloadSpeed,
        ));
      }
    } catch (e) {
      _log.warn('更新移动端状态失败: $e', tag: _logTag);
    }
  }
  
  // 请求Android VPN权限
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    
    try {
      await _log.info('请求Android VPN权限', tag: _logTag);
      
      // 初始化通道监听
      _initializeChannelListeners();
      
      // 通过原生通道请求权限
      final hasPermission = await _channel.invokeMethod<bool>('checkPermission') ?? false;
      await _log.info('VPN权限状态: $hasPermission', tag: _logTag);
      return hasPermission;
    } catch (e) {
      await _log.error('请求权限失败: $e', tag: _logTag);
      return false;
    }
  }
  
  // 更新状态并通知监听者
  static void _updateStatus(V2RayStatus status) {
    _currentStatus = status;
    if (!_statusController.isClosed && _statusController.hasListener) {
      _statusController.add(status);
    }
  }
  
  // 查询当前V2Ray状态（移动平台）
  static Future<V2RayConnectionState> queryConnectionState() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return _currentStatus.state;
    }
    
    try {
      final isConnected = await _channel.invokeMethod<bool>('isVpnConnected') ?? false;
      return isConnected ? V2RayConnectionState.connected : V2RayConnectionState.disconnected;
    } catch (e) {
      _log.warn('查询连接状态失败: $e', tag: _logTag);
      return _currentStatus.state;
    }
  }
  
  // 检查端口是否在监听（仅桌面平台）
  static Future<bool> isPortListening(int port) async {
    if (Platform.isAndroid || Platform.isIOS) return true;
    
    try {
      final client = await Socket.connect('127.0.0.1', port, 
        timeout: AppConfig.portCheckTimeout);
      await client.close();
      return true;
    } catch (e) {
      return false;
    }
  }
  
  // 检查端口是否可用（仅桌面平台）
  static Future<bool> isPortAvailable(int port) async {
    if (Platform.isAndroid || Platform.isIOS) return true;
    
    try {
      final socket = await ServerSocket.bind('127.0.0.1', port, shared: true);
      await socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }
  
  // 加载配置模板 - 优化版，根据平台选择配置
  static Future<Map<String, dynamic>> _loadConfigTemplate() async {
    try {
      final String configPath = _CONFIG_PATH;
      await _log.info('加载配置文件: $configPath', tag: _logTag);
      
      final String jsonString = await rootBundle.loadString(configPath);
      final config = jsonDecode(jsonString);
      
      return config;
    } catch (e) {
      await _log.error('加载配置模板失败: $e', tag: _logTag);
      throw '无法加载V2Ray配置模板';
    }
  }
  
  // 生成配置（统一处理） - 简化版：只更新必要的动态参数
  static Future<Map<String, dynamic>> _generateConfigMap({
    required String serverIp,
    required int serverPort,
    String? serverName,
    int localPort = 7898,
    int httpPort = 7899,
    bool globalProxy = false,
  }) async {
    // 加载配置模板（已根据平台自动选择）
    Map<String, dynamic> config = await _loadConfigTemplate();
    
    // 检查服务器群组配置（从AppConfig读取）
    String? userId;  // 存储UUID
    final groupServer = AppConfig.getRandomServer();
    if (groupServer != null) {
      // 使用群组配置覆盖参数
      if (groupServer['serverName'] != null) {
        serverName = groupServer['serverName'];
      }
      if (groupServer['uuid'] != null) {
        userId = groupServer['uuid'];
        // 安全显示UUID（防止substring越界）
        final displayUuid = userId!.length > 8 ? '${userId.substring(0, 8)}...' : userId;
        await _log.info('使用服务器群组UUID: $displayUuid', tag: _logTag);
      }
      await _log.info('使用服务器配置: CDN=$serverIp:$serverPort, ServerName=$serverName', tag: _logTag);
    }
    
    // 确保serverName有默认值
    if (serverName == null || serverName.isEmpty) {
      // 尝试从配置模板中获取默认值
      try {
        final outbounds = config['outbounds'] as List?;
        if (outbounds != null) {
          for (var outbound in outbounds) {
            if (outbound['tag'] == 'proxy') {
              serverName = outbound['streamSettings']?['tlsSettings']?['serverName'] ??
                          outbound['streamSettings']?['wsSettings']?['headers']?['Host'];
              if (serverName != null && serverName.isNotEmpty) {
                await _log.info('使用配置模板中的默认ServerName: $serverName', tag: _logTag);
                break;
              }
            }
          }
        }
      } catch (e) {
        await _log.warn('无法从配置模板获取默认ServerName: $e', tag: _logTag);
      }
      
      // 如果还是没有，使用硬编码的默认值
      if (serverName == null || serverName.isEmpty) {
        serverName = 'pages-vless-a9f.pages.dev';
        await _log.info('使用硬编码的默认ServerName: $serverName', tag: _logTag);
      }
    }
    
    // 更新入站端口（移动端配置可能没有socks/http入站，需要判断）
    if (config['inbounds'] is List) {
      for (var inbound in config['inbounds']) {
        if (inbound is Map) {
          if (inbound['tag'] == 'socks') {
            inbound['port'] = localPort;
            await _log.debug('设置SOCKS端口: $localPort', tag: _logTag);
          } else if (inbound['tag'] == 'http') {
            inbound['port'] = httpPort;
            await _log.debug('设置HTTP端口: $httpPort', tag: _logTag);
          }
        }
      }
    }
    
    // 更新出站服务器信息 - 只更新proxy出站
    if (config['outbounds'] is List) {
      for (var outbound in config['outbounds']) {
        if (outbound is Map && outbound['tag'] == 'proxy') {
          // 更新服务器地址和端口
          if (outbound['settings']?['vnext'] is List) {
            var vnext = outbound['settings']['vnext'] as List;
            if (vnext.isNotEmpty && vnext[0] is Map) {
              vnext[0]['address'] = serverIp;  // 使用CDN IP
              vnext[0]['port'] = serverPort;
              
              // 更新用户UUID（如果提供）
              if (userId != null && userId.isNotEmpty) {
                if (vnext[0]['users'] is List && (vnext[0]['users'] as List).isNotEmpty) {
                  vnext[0]['users'][0]['id'] = userId;
                }
              }
            }
          }
          
          // 更新TLS和WebSocket配置 - 使用serverName
          if (serverName != null && serverName.isNotEmpty && 
              outbound['streamSettings'] is Map) {
            var streamSettings = outbound['streamSettings'] as Map;
            
            // 更新TLS serverName
            if (streamSettings['tlsSettings'] is Map) {
              streamSettings['tlsSettings']['serverName'] = serverName;
              await _log.debug('设置TLS ServerName: $serverName', tag: _logTag);
            }
            
            // 更新WebSocket Host
            if (streamSettings['wsSettings'] is Map && 
                streamSettings['wsSettings']['headers'] is Map) {
              streamSettings['wsSettings']['headers']['Host'] = serverName;
              await _log.debug('设置WebSocket Host: $serverName', tag: _logTag);
            }
          }
          
          break;  // 只有一个proxy出站，更新后退出
        }
      }
    }
    
    // 全局代理模式：只删除直连路由规则，保留其他所有规则
    if (globalProxy) {
      await _log.info('配置全局代理模式', tag: _logTag);
      
      if (config['routing'] is Map && config['routing']['rules'] is List) {
        final rules = config['routing']['rules'] as List;
        
        // 只删除直连规则，保留API路由和默认代理规则
        rules.removeWhere((rule) {
          if (rule is Map) {
            // 保留API路由（如果有）
            if (rule['inboundTag'] != null && 
                (rule['inboundTag'] is List) &&
                (rule['inboundTag'] as List).contains('api')) {
              return false;  // 保留API路由
            }
            // 删除直连规则
            if (rule['outboundTag'] == 'direct') {
              return true;  // 删除直连规则
            }
          }
          return false;  // 保留其他规则
        });
        
        await _log.debug('全局代理路由: 已删除直连规则', tag: _logTag);
      }
    }
    
    // 记录最终配置概要
    if (kDebugMode) {
      await _log.debug('配置概要:', tag: _logTag);
      await _log.debug('  - CDN IP: $serverIp:$serverPort', tag: _logTag);
      await _log.debug('  - ServerName: $serverName', tag: _logTag);
      await _log.debug('  - 全局代理: $globalProxy', tag: _logTag);
      if (userId != null && userId.isNotEmpty) {
        final displayUuid = userId.length > 8 ? '${userId.substring(0, 8)}...' : userId;
        await _log.debug('  - UUID: $displayUuid', tag: _logTag);
      }
    }
    
    return config;
  }
  
  // 生成配置文件（仅Windows平台）
  static Future<void> _generateConfigFile({
    required String serverIp,
    required int serverPort,
    String? serverName,
    int localPort = 7898,
    int httpPort = 7899,
    bool globalProxy = false,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    
    final v2rayPath = await _getV2RayPath();
    final configPath = path.join(path.dirname(v2rayPath), 'config.json');
    
    try {
      final config = await _generateConfigMap(
        serverIp: serverIp,
        serverPort: serverPort,
        serverName: serverName,
        localPort: localPort,
        httpPort: httpPort,
        globalProxy: globalProxy,
      );
      
      await File(configPath).writeAsString(jsonEncode(config));
      await _log.info('配置文件已生成: $configPath', tag: _logTag);
    } catch (e) {
      await _log.error('生成配置文件失败: $e', tag: _logTag);
      throw '生成V2Ray配置失败: $e';
    }
  }
  
  // 计算连接时长
  static String _calculateDuration() {
    if (_connectionStartTime == null) return "00:00:00";
    
    final duration = DateTime.now().difference(_connectionStartTime!);
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    
    return "$hours:$minutes:$seconds";
  }
  
  // 启动时长计时器（仅Windows平台）
  static void _startDurationTimer() {
    if (Platform.isAndroid || Platform.isIOS) return;
    
    _stopDurationTimer();
    _connectionStartTime = DateTime.now();
    
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isRunning) {
        final duration = _calculateDuration();
        _updateStatus(_currentStatus.copyWith(duration: duration));
      }
    });
  }
  
  static void _stopDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _connectionStartTime = null;
  }
  
  // 启动V2Ray服务（增强版，支持新功能）
  static Future<bool> start({
    required String serverIp,
    int serverPort = 443,
    String? serverName,
    bool globalProxy = false,
    // 新增参数（移动端特有）
    V2RayConnectionMode mode = V2RayConnectionMode.vpnTun,
    List<String>? blockedApps,
    List<String>? allowedApps,
    AppProxyMode appProxyMode = AppProxyMode.exclude,
    List<String>? bypassSubnets,
    String disconnectButtonName = '停止',
  }) async {
    // 并发控制
    if (_isStarting || _isStopping) {
      await _log.warn('V2Ray正在启动或停止中，忽略请求', tag: _logTag);
      return false;
    }
    _isStarting = true;
    
    try {
      // 如果已在运行，先停止
      if (_isRunning) {
        await stop();
        await Future.delayed(const Duration(seconds: 1));
      }
      
      await _log.info('开始启动V2Ray服务 - CDN IP: $serverIp:$serverPort, 全局代理: $globalProxy, 模式: $mode', tag: _logTag);
      
      // 更新状态为连接中
      _updateStatus(V2RayStatus(state: V2RayConnectionState.connecting));
      
      // ============ Android/iOS平台 ============
      if (Platform.isAndroid || Platform.isIOS) {
        return await _startMobilePlatform(
          serverIp: serverIp,
          serverPort: serverPort,
          serverName: serverName,
          globalProxy: globalProxy,
          mode: mode,
          blockedApps: blockedApps,
          allowedApps: allowedApps,
          appProxyMode: appProxyMode,
          bypassSubnets: bypassSubnets,
          disconnectButtonName: disconnectButtonName,
        );
      }
      
      // ============ Windows/桌面平台 ============
      return await _startDesktopPlatform(
        serverIp: serverIp,
        serverPort: serverPort,
        serverName: serverName,
        globalProxy: globalProxy,
      );
      
    } catch (e, stackTrace) {
      await _log.error('启动V2Ray失败', tag: _logTag, error: e, stackTrace: stackTrace);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    } finally {
      _isStarting = false;
    }
  }
  
  // 移动平台启动逻辑 - 增强版，支持新功能
  static Future<bool> _startMobilePlatform({
    required String serverIp,
    required int serverPort,
    String? serverName,
    bool globalProxy = false,
    V2RayConnectionMode mode = V2RayConnectionMode.vpnTun,
    List<String>? blockedApps,
    List<String>? allowedApps,
    AppProxyMode appProxyMode = AppProxyMode.exclude,
    List<String>? bypassSubnets,
    String disconnectButtonName = '停止',
  }) async {
    await _log.info('移动平台：启动V2Ray (全局代理: $globalProxy, 模式: $mode)', tag: _logTag);
    
    try {
      // 1. 初始化通道监听
      _initializeChannelListeners();
      
      // 2. 生成配置（会自动使用移动端配置模板）
      final configMap = await _generateConfigMap(
        serverIp: serverIp,
        serverPort: serverPort,
        serverName: serverName,
        localPort: AppConfig.v2raySocksPort,
        httpPort: AppConfig.v2rayHttpPort,
        globalProxy: globalProxy,
      );
      
      final configJson = jsonEncode(configMap);
      await _log.info('配置已生成，长度: ${configJson.length}', tag: _logTag);
      
      // 在调试模式下，输出配置的关键信息
      if (kDebugMode) {
        await _log.debug('配置详情:', tag: _logTag);
        await _log.debug('  - 协议: ${configMap['outbounds']?[0]?['protocol']}', tag: _logTag);
        await _log.debug('  - CDN IP: $serverIp:$serverPort', tag: _logTag);
        await _log.debug('  - ServerName: $serverName', tag: _logTag);
        await _log.debug('  - 全局代理: $globalProxy', tag: _logTag);
        await _log.debug('  - 连接模式: $mode', tag: _logTag);
        await _log.debug('  - 应用代理模式: $appProxyMode', tag: _logTag);
        if (blockedApps != null && blockedApps.isNotEmpty) {
          await _log.debug('  - 排除应用: ${blockedApps.length}个', tag: _logTag);
        }
        if (allowedApps != null && allowedApps.isNotEmpty) {
          await _log.debug('  - 包含应用: ${allowedApps.length}个', tag: _logTag);
        }
        if (bypassSubnets != null && bypassSubnets.isNotEmpty) {
          await _log.debug('  - 绕过子网: ${bypassSubnets.length}个', tag: _logTag);
        }
        
        // 输出UUID信息（安全显示）
        final users = configMap['outbounds']?[0]?['settings']?['vnext']?[0]?['users'];
        if (users is List && users.isNotEmpty) {
          final uuid = users[0]['id'] as String?;
          if (uuid != null && uuid.isNotEmpty) {
            final displayUuid = uuid.length > 8 ? '${uuid.substring(0, 8)}...' : uuid;
            await _log.debug('  - UUID: $displayUuid', tag: _logTag);
          }
        }
      }
      
      // 3. 通过原生通道启动V2Ray（增强版）
      final result = await _channel.invokeMethod<bool>('startVpn', {
        'config': configJson,
        'mode': mode == V2RayConnectionMode.vpnTun ? 'VPN_TUN' : 'PROXY_ONLY',
        'globalProxy': globalProxy,
        'blockedApps': blockedApps,
        'allowedApps': allowedApps,
        'appProxyMode': appProxyMode == AppProxyMode.exclude ? 'EXCLUDE' : 'INCLUDE',
        'bypassSubnets': bypassSubnets,
        'disconnectButtonName': disconnectButtonName,
      });
      
      if (result == true) {
        await _log.info('V2Ray启动命令已发送，等待连接建立', tag: _logTag);
        
        // 4. 等待连接建立（PROXY_ONLY模式可能更快）
        final waitTime = mode == V2RayConnectionMode.proxyOnly 
            ? const Duration(seconds: 1) 
            : AppConfig.v2rayCheckDelay;
        await Future.delayed(waitTime);
        
        // 5. 检查连接状态
        final isConnected = await _channel.invokeMethod<bool>('isVpnConnected') ?? false;
        
        if (isConnected) {
          _isRunning = true;
          _connectionStartTime = DateTime.now();
          _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
          _startMobileStatusTimer();  // 启动状态更新定时器
          await _log.info('V2Ray连接成功', tag: _logTag);
        } else {
          // 6. 如果还未连接，再等待一次
          await _log.info('V2Ray连接中，再等待2秒', tag: _logTag);
          await Future.delayed(const Duration(seconds: 2));
          
          final isConnectedRetry = await _channel.invokeMethod<bool>('isVpnConnected') ?? false;
          if (isConnectedRetry) {
            _isRunning = true;
            _connectionStartTime = DateTime.now();
            _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
            _startMobileStatusTimer();  // 启动状态更新定时器
            await _log.info('V2Ray连接成功（重试）', tag: _logTag);
          } else {
            _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
            await _log.warn('V2Ray连接失败', tag: _logTag);
          }
        }
      } else {
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        await _log.error('V2Ray启动失败', tag: _logTag);
      }
      
      await _log.info('移动平台：V2Ray启动流程完成，最终状态: ${_isRunning ? "已连接" : "未连接"}', 
                      tag: _logTag);
      return _isRunning;
      
    } catch (e, stackTrace) {
      await _log.error('启动V2Ray失败', tag: _logTag, error: e, stackTrace: stackTrace);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      return false;
    }
  }
  
  // 获取已安装应用列表（Android）
  static Future<List<Map<String, dynamic>>> getInstalledApps() async {
    if (!Platform.isAndroid) return [];
    
    try {
      final apps = await _channel.invokeMethod<List>('getInstalledApps');
      if (apps != null) {
        return apps.map((app) => Map<String, dynamic>.from(app as Map)).toList();
      }
    } catch (e) {
      _log.error('获取应用列表失败: $e', tag: _logTag);
    }
    
    return [];
  }
  
  // 保存代理配置（分应用代理、子网绕过等）
  static Future<void> saveProxyConfig({
    List<String>? blockedApps,
    List<String>? bypassSubnets,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    try {
      await _channel.invokeMethod('saveProxyConfig', {
        'blockedApps': blockedApps ?? [],
        'bypassSubnets': bypassSubnets ?? [],
      });
      _log.info('代理配置已保存', tag: _logTag);
    } catch (e) {
      _log.error('保存代理配置失败: $e', tag: _logTag);
    }
  }
  
  // 加载代理配置
  static Future<Map<String, List<String>>> loadProxyConfig() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return {
        'blockedApps': [],
        'bypassSubnets': [],
      };
    }
    
    try {
      final config = await _channel.invokeMethod<Map>('loadProxyConfig');
      if (config != null) {
        return {
          'blockedApps': List<String>.from(config['blockedApps'] ?? []),
          'bypassSubnets': List<String>.from(config['bypassSubnets'] ?? []),
        };
      }
    } catch (e) {
      _log.error('加载代理配置失败: $e', tag: _logTag);
    }
    
    return {
      'blockedApps': [],
      'bypassSubnets': [],
    };
  }
  
  // 测试服务器延迟（Android）
  static Future<int> testServerDelay({
    required String config,
    String testUrl = 'https://www.google.com/generate_204',
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return -1;
    
    try {
      final delay = await _channel.invokeMethod<int>('testServerDelay', {
        'config': config,
        'url': testUrl,
      });
      return delay ?? -1;
    } catch (e) {
      _log.error('测试服务器延迟失败: $e', tag: _logTag);
      return -1;
    }
  }
  
  // 测试已连接服务器延迟（Android）
  static Future<int> testConnectedDelay({
    String testUrl = 'https://www.google.com/generate_204',
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return -1;
    if (!_isRunning) return -1;
    
    try {
      final delay = await _channel.invokeMethod<int>('testConnectedDelay', {
        'url': testUrl,
      });
      return delay ?? -1;
    } catch (e) {
      _log.error('测试已连接服务器延迟失败: $e', tag: _logTag);
      return -1;
    }
  }
  
  // 桌面平台启动逻辑（Windows）
  static Future<bool> _startDesktopPlatform({
    required String serverIp,
    required int serverPort,
    String? serverName,
    bool globalProxy = false,
  }) async {
    // 检查端口
    if (!await isPortAvailable(AppConfig.v2raySocksPort) || 
        !await isPortAvailable(AppConfig.v2rayHttpPort)) {
      await _log.error('端口已被占用', tag: _logTag);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      throw 'Port already in use';
    }
    
    // 生成配置文件
    await _generateConfigFile(
      serverIp: serverIp,
      serverPort: serverPort,
      serverName: serverName,
      localPort: AppConfig.v2raySocksPort,
      httpPort: AppConfig.v2rayHttpPort,
      globalProxy: globalProxy,
    );
    
    // 启动进程
    final v2rayPath = await _getV2RayPath();
    if (!await File(v2rayPath).exists()) {
      await _log.error('V2Ray可执行文件未找到: $v2rayPath', tag: _logTag);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      throw 'V2Ray executable not found';
    }
    
    await _log.info('启动V2Ray进程: $v2rayPath', tag: _logTag);
    
    _v2rayProcess = await Process.start(
      v2rayPath,
      ['run'],
      workingDirectory: path.dirname(v2rayPath),
      runInShell: true,
    );
    
    // 设置进程监听
    _v2rayProcess!.stdout.transform(utf8.decoder).listen((data) {
      if (data.toLowerCase().contains('started') || 
          data.toLowerCase().contains('listening')) {
        _log.info('V2Ray启动成功', tag: _logTag);
      }
    });
    
    _v2rayProcess!.stderr.transform(utf8.decoder).listen((data) {
      if (!data.toLowerCase().contains('websocket: close') &&
          !data.toLowerCase().contains('failed to process outbound traffic')) {
        _log.debug('V2Ray: $data', tag: _logTag);
      }
    });
    
    _v2rayProcess!.exitCode.then((code) {
      _log.info('V2Ray进程退出，退出码: $code', tag: _logTag);
      _isRunning = false;
      _stopStatsTimer();
      _stopDurationTimer();
      _updateStatus(V2RayStatus(state: V2RayConnectionState.disconnected));
      if (_onProcessExit != null) {
        _onProcessExit!();
      }
    });
    
    // 等待并验证
    await Future.delayed(AppConfig.v2rayStartupWait);
    
    if (await isPortListening(AppConfig.v2raySocksPort)) {
      _isRunning = true;
      _uploadTotal = 0;
      _downloadTotal = 0;
      _lastUpdateTime = 0;
      _lastUploadBytes = 0;
      _lastDownloadBytes = 0;
      
      _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
      _startStatsTimer();
      _startDurationTimer();
      
      await _log.info('V2Ray服务启动成功', tag: _logTag);
      return true;
    } else {
      await _log.error('V2Ray启动但端口未监听', tag: _logTag);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    }
  }
  
  // 停止V2Ray服务
  static Future<void> stop() async {
    // 并发控制
    if (_isStopping) {
      await _log.warn('V2Ray正在停止中，忽略重复请求', tag: _logTag);
      return;
    }
    _isStopping = true;
    
    try {
      await _log.info('开始停止V2Ray服务', tag: _logTag);
      
      // 更新状态为断开
      _updateStatus(V2RayStatus(state: V2RayConnectionState.disconnected));
      
      // 重置运行标志
      _isRunning = false;
      _hasLoggedV2RayInfo = false;
      
      // 移动平台停止
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          // 停止状态更新定时器
          _stopMobileStatusTimer();
          
          // 通过原生通道停止V2Ray
          await _channel.invokeMethod('stopVpn');
          await _log.info('移动平台：V2Ray已停止', tag: _logTag);
        } catch (e) {
          await _log.error('移动平台停止失败: $e', tag: _logTag);
        }
      } else {
        // Windows平台停止
        // 停止计时器（仅Windows使用）
        _stopStatsTimer();
        _stopDurationTimer();
        
        if (_v2rayProcess != null) {
          try {
            _v2rayProcess!.kill(ProcessSignal.sigterm);
            
            // 等待进程退出
            bool processExited = false;
            for (int i = 0; i < AppConfig.v2rayTerminateRetries; i++) {
              await Future.delayed(AppConfig.v2rayTerminateInterval);
              try {
                final exitCode = await _v2rayProcess!.exitCode.timeout(
                  const Duration(milliseconds: 100),
                  onTimeout: () => -1,
                );
                if (exitCode != -1) {
                  processExited = true;
                  await _log.info('V2Ray进程已退出', tag: _logTag);
                  break;
                }
              } catch (e) {
                // 继续等待
              }
            }
            
            if (!processExited) {
              await _log.warn('V2Ray进程未能优雅退出，强制终止', tag: _logTag);
              _v2rayProcess!.kill(ProcessSignal.sigkill);
            }
          } catch (e) {
            await _log.error('停止V2Ray进程时出错', tag: _logTag, error: e);
          } finally {
            _v2rayProcess = null;
          }
        }
        
        // 清理残留进程（Windows）
        if (Platform.isWindows) {
          try {
            await Process.run('taskkill', ['/F', '/IM', _v2rayExecutableName], 
              runInShell: true);
          } catch (e) {
            // 忽略
          }
        }
      }
      
      await _log.info('V2Ray服务已停止', tag: _logTag);
      
    } finally {
      _isStopping = false;
    }
  }
  
  // Windows平台流量统计
  static void _startStatsTimer() {
    if (Platform.isAndroid || Platform.isIOS) return;  // 移动端不使用
    
    _stopStatsTimer();
    
    Future.delayed(const Duration(seconds: 5), () {
      if (_isRunning) {
        _log.info('开始流量统计监控', tag: _logTag);
        
        _updateTrafficStatsFromAPI();
        
        _statsTimer = Timer.periodic(AppConfig.trafficStatsInterval, (_) {
          if (_isRunning) {
            _updateTrafficStatsFromAPI();
          }
        });
      }
    });
  }
  
  static void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }
  
  // Windows平台流量统计API调用
  static Future<void> _updateTrafficStatsFromAPI() async {
    if (!_isRunning || Platform.isAndroid || Platform.isIOS) return;
    
    try {
      final v2rayPath = await _getV2RayPath();
      final v2rayDir = path.dirname(v2rayPath);
      
      final v2ctlPath = path.join(v2rayDir, _v2ctlExecutableName);
      final hasV2ctl = await File(v2ctlPath).exists();
      
      // 只记录一次
      if (!_hasLoggedV2RayInfo) {
        await _log.debug('V2Ray目录: $v2rayDir, v2ctl存在: $hasV2ctl', tag: _logTag);
        _hasLoggedV2RayInfo = true;
      }
      
      final apiExe = hasV2ctl ? v2ctlPath : v2rayPath;
      
      List<String> apiCmd;
      
      if (hasV2ctl) {
        apiCmd = [
          'api',
          '--server=127.0.0.1:${AppConfig.v2rayApiPort}',
          'StatsService.QueryStats',
          'pattern: "" reset: false'
        ];
        
        if (Platform.isWindows) {
          final processResult = await Process.run(
            apiExe,
            apiCmd,
            runInShell: true,
            workingDirectory: v2rayDir,
          );
          
          if (processResult.exitCode == 0) {
            String output;
            if (processResult.stdout is String) {
              output = processResult.stdout as String;
            } else if (processResult.stdout is List<int>) {
              output = utf8.decode(processResult.stdout as List<int>);
            } else {
              output = processResult.stdout.toString();
            }
            
            _parseStatsOutput(output);
          } else {
            String error;
            if (processResult.stderr is String) {
              error = processResult.stderr as String;
            } else if (processResult.stderr is List<int>) {
              error = utf8.decode(processResult.stderr as List<int>);
            } else {
              error = processResult.stderr.toString();
            }
            await _log.warn('获取流量统计失败: $error', tag: _logTag);
          }
        } else {
          final processResult = await Process.run(
            apiExe,
            apiCmd,
            runInShell: false,
            workingDirectory: v2rayDir,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          
          if (processResult.exitCode == 0) {
            _parseStatsOutput(processResult.stdout.toString());
          } else {
            await _log.warn('获取流量统计失败: ${processResult.stderr}', tag: _logTag);
          }
        }
      } else {
        apiCmd = ['api', 'statsquery', '--server=127.0.0.1:${AppConfig.v2rayApiPort}'];
        
        final processResult = await Process.run(
          apiExe,
          apiCmd,
          runInShell: false,
          workingDirectory: v2rayDir,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        
        if (processResult.exitCode == 0) {
          _parseStatsOutput(processResult.stdout.toString());
        } else {
          await _log.warn('获取流量统计失败: ${processResult.stderr}', tag: _logTag);
        }
      }
    } catch (e, stackTrace) {
      await _log.error('更新流量统计时出错', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 记录上次的流量值
  static int _lastLoggedUpload = -1;
  static int _lastLoggedDownload = -1;
  
  // 解析流量统计输出
  static void _parseStatsOutput(String output) {
    try {
      int proxyUplink = 0;
      int proxyDownlink = 0;
      
      final statBlocks = output.split('stat:');
      
      for (final block in statBlocks) {
        if (block.trim().isEmpty) continue;
        
        final nameMatch = RegExp(r'name:\s*"([^"]+)"').firstMatch(block);
        final valueMatch = RegExp(r'value:\s*(\d+)').firstMatch(block);
        
        if (nameMatch != null) {
          final name = nameMatch.group(1)!;
          final value = valueMatch != null ? int.parse(valueMatch.group(1)!) : 0;
          
          // 只统计proxy出站流量
          if (name == "outbound>>>proxy>>>traffic>>>uplink") {
            proxyUplink = value;
          } else if (name == "outbound>>>proxy>>>traffic>>>downlink") {
            proxyDownlink = value;
          }
        }
      }
      
      // 更新流量值
      _uploadTotal = proxyUplink;
      _downloadTotal = proxyDownlink;
      
      // 计算速度
      final now = DateTime.now().millisecondsSinceEpoch;
      int uploadSpeed = 0;
      int downloadSpeed = 0;
      
      if (_lastUpdateTime > 0) {
        final timeDiff = (now - _lastUpdateTime) / 1000.0; // 秒
        if (timeDiff > 0) {
          uploadSpeed = ((_uploadTotal - _lastUploadBytes) / timeDiff).round();
          downloadSpeed = ((_downloadTotal - _lastDownloadBytes) / timeDiff).round();
          
          // 防止负数速度
          if (uploadSpeed < 0) uploadSpeed = 0;
          if (downloadSpeed < 0) downloadSpeed = 0;
        }
      }
      
      _lastUpdateTime = now;
      _lastUploadBytes = _uploadTotal;
      _lastDownloadBytes = _downloadTotal;
      
      // 只有流量变化或速度不为0时才记录日志
      if (_uploadTotal != _lastLoggedUpload || _downloadTotal != _lastLoggedDownload || 
          uploadSpeed > 0 || downloadSpeed > 0) {
        _log.info(
          '流量: ↑${UIUtils.formatBytes(_uploadTotal)} ↓${UIUtils.formatBytes(_downloadTotal)} ' +
          '速度: ↑${UIUtils.formatBytes(uploadSpeed)}/s ↓${UIUtils.formatBytes(downloadSpeed)}/s',
          tag: _logTag
        );
        _lastLoggedUpload = _uploadTotal;
        _lastLoggedDownload = _downloadTotal;
      }
      
      // 更新状态
      _updateStatus(V2RayStatus(
        state: _currentStatus.state,
        upload: _uploadTotal,
        download: _downloadTotal,
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed,
        duration: _currentStatus.duration,
      ));
      
      // 基于流量判断连接状态
      if ((_uploadTotal > 0 || _downloadTotal > 0) && 
          _currentStatus.state != V2RayConnectionState.connected) {
        _updateStatus(V2RayStatus(
          state: V2RayConnectionState.connected,
          upload: _uploadTotal,
          download: _downloadTotal,
          uploadSpeed: uploadSpeed,
          downloadSpeed: downloadSpeed,
        ));
        _log.info('检测到流量，更新状态为已连接', tag: _logTag);
      }
      
    } catch (e, stackTrace) {
      _log.error('解析流量统计失败', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 获取流量统计
  static Future<Map<String, int>> getTrafficStats() async {
    if (!_isRunning) {
      return {
        'uploadTotal': 0,
        'downloadTotal': 0,
        'uploadSpeed': 0,
        'downloadSpeed': 0,
      };
    }
    
    return {
      'uploadTotal': _uploadTotal,
      'downloadTotal': _downloadTotal,
      'uploadSpeed': _currentStatus.uploadSpeed,
      'downloadSpeed': _currentStatus.downloadSpeed,
    };
  }
  
  // 释放资源 - 清理所有资源
  static void dispose() {
    _stopStatsTimer();
    _stopDurationTimer();
    _stopMobileStatusTimer();
    
    // 重置状态
    _isRunning = false;
    _hasLoggedV2RayInfo = false;
    _uploadTotal = 0;
    _downloadTotal = 0;
    
    // 清理通道监听
    _isChannelInitialized = false;
    
    // 关闭状态流
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
