import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';
import '../app_config.dart';

/// V2Ray连接状态
enum V2RayConnectionState {
  disconnected,
  connecting,
  connected,
  error
}

/// V2Ray状态信息 - 我们自己的状态类
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
  
  // 移动平台Method Channel
  static const _platform = MethodChannel('com.example.cfvpn/v2ray');
  
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
  
  // 初始化移动平台Method Channel监听
  static bool _isMethodChannelInitialized = false;
  
  static void _initMobilePlatform() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_isMethodChannelInitialized) return; // 防止重复初始化
    
    _isMethodChannelInitialized = true;
    _platform.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onVpnPermissionGranted':
          await _log.info('VPN权限已授予', tag: _logTag);
          _updateStatus(V2RayStatus(state: V2RayConnectionState.connecting));
          break;
        case 'onVpnPermissionDenied':
          await _log.error('VPN权限被拒绝', tag: _logTag);
          _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
          break;
        case 'onVpnConnected':
          await _log.info('VPN已连接', tag: _logTag);
          _isRunning = true;
          _connectionStartTime = DateTime.now();
          _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
          _startMobileStatsTimer();
          break;
        case 'onVpnDisconnected':
          await _log.info('VPN已断开', tag: _logTag);
          _isRunning = false;
          _connectionStartTime = null;
          _updateStatus(V2RayStatus(state: V2RayConnectionState.disconnected));
          _stopStatsTimer();
          break;
        default:
          await _log.warn('未知的方法调用: ${call.method}', tag: _logTag);
      }
    });
  }
  
  // 请求Android VPN权限
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    
    try {
      await _log.info('请求Android VPN权限', tag: _logTag);
      
      final hasPermission = await _platform.invokeMethod<bool>('checkPermission') ?? false;
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
    // 直接返回当前状态
    return _currentStatus.state;
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
  
  // 启动V2Ray服务
  static Future<bool> start({
    required String serverIp,
    int serverPort = 443,
    String? serverName,
    bool globalProxy = false,
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
      
      await _log.info('开始启动V2Ray服务 - CDN IP: $serverIp:$serverPort, 全局代理: $globalProxy', tag: _logTag);
      
      // 更新状态为连接中
      _updateStatus(V2RayStatus(state: V2RayConnectionState.connecting));
      
      // ============ Android/iOS平台 ============
      if (Platform.isAndroid || Platform.isIOS) {
        return await _startMobilePlatform(
          serverIp: serverIp,
          serverPort: serverPort,
          serverName: serverName,
          globalProxy: globalProxy,
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
  
  // 移动平台启动逻辑
  static Future<bool> _startMobilePlatform({
    required String serverIp,
    required int serverPort,
    String? serverName,
    bool globalProxy = false,
  }) async {
    await _log.info('移动平台：启动V2Ray (全局代理: $globalProxy)', tag: _logTag);
    
    try {
      // 初始化Method Channel监听（必须在调用前初始化）
      _initMobilePlatform();
      
      // 生成配置（与Windows完全一致的逻辑）
      final configMap = await _generateConfigMap(
        serverIp: serverIp,
        serverPort: serverPort,
        serverName: serverName,
        localPort: AppConfig.v2raySocksPort,  // 使用AppConfig
        httpPort: AppConfig.v2rayHttpPort,     // 使用AppConfig
        globalProxy: globalProxy,
      );
      
      final configJson = jsonEncode(configMap);
      await _log.info('配置已生成，长度: ${configJson.length}', tag: _logTag);
      
      // 在调试模式下，输出配置的关键信息（与Windows一致）
      if (kDebugMode) {
        await _log.debug('配置详情:', tag: _logTag);
        await _log.debug('  - 协议: ${configMap['outbounds']?[0]?['protocol']}', tag: _logTag);
        await _log.debug('  - CDN IP: $serverIp:$serverPort', tag: _logTag);
        await _log.debug('  - ServerName: $serverName', tag: _logTag);
        await _log.debug('  - 全局代理: $globalProxy', tag: _logTag);
        
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
      
      // 调用原生方法启动VPN
      // 注意：这个调用可能因为权限请求而返回false，但服务会在权限授予后启动
      final result = await _platform.invokeMethod<bool>('startVpn', {
        'config': configJson,
        'globalProxy': globalProxy,
      }).catchError((e) {
        _log.error('调用startVpn失败: $e', tag: _logTag);
        return false;
      });
      
      await _log.info('VPN启动调用结果: $result', tag: _logTag);
      
      // 如果返回true，说明直接启动成功（已有权限）
      if (result == true) {
        // 等待服务启动（使用AppConfig的等待时间）
        await Future.delayed(AppConfig.v2rayCheckDelay);
        
        // 检查连接状态（与Windows的端口检查对应）
        final isConnected = await _platform.invokeMethod<bool>('isVpnConnected') ?? false;
        if (!isConnected) {
          // 如果还未连接，使用AppConfig的启动等待时间再等待
          await _log.info('V2Ray连接中，继续等待', tag: _logTag);
          await Future.delayed(AppConfig.v2rayStartupWait);
          
          // 再次检查
          final isConnectedRetry = await _platform.invokeMethod<bool>('isVpnConnected') ?? false;
          if (isConnectedRetry && !_isRunning) {
            // 状态可能还未通过回调更新，手动更新
            _isRunning = true;
            _connectionStartTime = DateTime.now();
            _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
            _startMobileStatsTimer();
          }
        }
      } else {
        // 返回false可能是需要权限或启动失败
        // 如果是权限问题，会通过onVpnPermissionGranted/onVpnConnected回调处理
        await _log.info('VPN启动需要权限或失败', tag: _logTag);
        
        // 等待权限授予和连接建立（最多等待AppConfig定义的时间）
        int waitCount = 0;
        const maxWaitCount = 10; // 最多等待10秒
        while (waitCount < maxWaitCount && !_isRunning) {
          await Future.delayed(const Duration(seconds: 1));
          waitCount++;
          
          // 检查是否已经连接（通过回调更新的状态）
          if (_currentStatus.state == V2RayConnectionState.connected) {
            _isRunning = true;
            break;
          } else if (_currentStatus.state == V2RayConnectionState.error) {
            // 如果出错，立即退出
            break;
          }
        }
      }
      
      // 最终状态检查
      if (_isRunning) {
        await _log.info('V2Ray连接成功', tag: _logTag);
        return true;
      } else {
        // 最后尝试查询一次原生端状态
        final finalConnected = await _platform.invokeMethod<bool>('isVpnConnected') ?? false;
        if (finalConnected && !_isRunning) {
          // 补救：如果原生端已连接但Flutter端状态未更新
          _isRunning = true;
          _connectionStartTime = DateTime.now();
          _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
          _startMobileStatsTimer();
          await _log.info('V2Ray连接成功（状态同步）', tag: _logTag);
          return true;
        }
        
        await _log.warn('V2Ray连接失败', tag: _logTag);
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        return false;
      }
      
    } catch (e, stackTrace) {
      await _log.error('启动V2Ray失败', tag: _logTag, error: e, stackTrace: stackTrace);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      return false;
    }
  }
  
  // 移动平台流量统计定时器
  static void _startMobileStatsTimer() {
    _stopStatsTimer();
    
    // 延迟5秒开始（与Windows一致）
    Future.delayed(const Duration(seconds: 5), () {
      if (!_isRunning) return;
      
      _log.info('开始流量统计监控', tag: _logTag);
      
      // 使用AppConfig.trafficStatsInterval（与Windows一致）
      _statsTimer = Timer.periodic(AppConfig.trafficStatsInterval, (_) async {
        if (!_isRunning) {
          _stopStatsTimer();
          return;
        }
        
        try {
          // 获取流量统计
          final stats = await _platform.invokeMethod<Map>('getTrafficStats');
          if (stats != null) {
            final uploadTotal = _parseIntSafely(stats['uploadTotal']);
            final downloadTotal = _parseIntSafely(stats['downloadTotal']);
            
            // 计算速度（与Windows一致的逻辑）
            final now = DateTime.now().millisecondsSinceEpoch;
            int uploadSpeed = 0;
            int downloadSpeed = 0;
            
            if (_lastUpdateTime > 0) {
              final timeDiff = (now - _lastUpdateTime) / 1000.0; // 秒
              if (timeDiff > 0) {
                uploadSpeed = ((uploadTotal - _lastUploadBytes) / timeDiff).round();
                downloadSpeed = ((downloadTotal - _lastDownloadBytes) / timeDiff).round();
                
                // 防止负数速度
                if (uploadSpeed < 0) uploadSpeed = 0;
                if (downloadSpeed < 0) downloadSpeed = 0;
              }
            }
            
            _lastUpdateTime = now;
            _lastUploadBytes = uploadTotal;
            _lastDownloadBytes = downloadTotal;
            
            _uploadTotal = uploadTotal;
            _downloadTotal = downloadTotal;
            
            // 更新状态
            _updateStatus(_currentStatus.copyWith(
              upload: uploadTotal,
              download: downloadTotal,
              uploadSpeed: uploadSpeed,
              downloadSpeed: downloadSpeed,
              duration: _calculateDuration(),
            ));
            
            // 只在流量变化时记录日志（与Windows一致）
            if (uploadSpeed > 0 || downloadSpeed > 0) {
              _log.info(
                '流量: ↑${UIUtils.formatBytes(uploadTotal)} ↓${UIUtils.formatBytes(downloadTotal)} ' +
                '速度: ↑${UIUtils.formatBytes(uploadSpeed)}/s ↓${UIUtils.formatBytes(downloadSpeed)}/s',
                tag: _logTag
              );
            }
          }
        } catch (e) {
          // 忽略统计错误，不影响VPN运行
        }
      });
    });
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
          await _platform.invokeMethod('stopVpn');
          await _log.info('移动平台：V2Ray已停止', tag: _logTag);
        } catch (e) {
          await _log.error('移动平台停止失败: $e', tag: _logTag);
        }
        // 停止统计定时器
        _stopStatsTimer();
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
    
    // 重置状态
    _isRunning = false;
    _hasLoggedV2RayInfo = false;
    _uploadTotal = 0;
    _downloadTotal = 0;
    
    // 关闭状态流
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
