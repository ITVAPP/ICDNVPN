import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;
import 'package:flutter_v2ray/flutter_v2ray.dart' as v2ray;  // 使用别名避免类名冲突
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
  
  // 移动平台flutter_v2ray插件相关
  static v2ray.FlutterV2ray? _flutterV2ray;  // 使用带别名的类型
  static bool _isFlutterV2rayInitialized = false;  // 标记是否已初始化
  
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
  
  // 确保flutter_v2ray已初始化（移动平台）
  static Future<void> _ensureFlutterV2rayInitialized() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    if (_flutterV2ray == null || !_isFlutterV2rayInitialized) {
      await _log.info('初始化flutter_v2ray插件', tag: _logTag);
      
      _flutterV2ray = v2ray.FlutterV2ray(
        onStatusChanged: (v2ray.V2RayStatus status) {  // 明确类型
          _handleV2RayStatusChange(status);
        },
      );
      
      try {
        await _flutterV2ray!.initializeV2Ray(
          notificationIconResourceType: "mipmap",
          notificationIconResourceName: "ic_launcher",
        );
        _isFlutterV2rayInitialized = true;
        await _log.info('flutter_v2ray初始化成功', tag: _logTag);
      } catch (e) {
        await _log.error('flutter_v2ray初始化失败: $e', tag: _logTag);
        _flutterV2ray = null;
        _isFlutterV2rayInitialized = false;
        throw e;
      }
    }
  }
  
  // 请求Android VPN权限
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    
    try {
      await _log.info('请求Android VPN权限', tag: _logTag);
      
      // 确保flutter_v2ray已初始化
      await _ensureFlutterV2rayInitialized();
      
      // 请求VPN权限
      final hasPermission = await _flutterV2ray!.requestPermission();
      await _log.info('VPN权限请求结果: $hasPermission', tag: _logTag);
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
  
  // 映射flutter_v2ray的状态字符串到我们的状态枚举
  // 修复：接收String参数而不是不存在的V2RayState枚举
  static V2RayConnectionState _mapPluginState(String stateString) {
    final upperState = stateString.toUpperCase();
    // 处理各种可能的状态字符串格式
    if (upperState.contains('CONNECTED') && !upperState.contains('DISCONNECTED')) {
      return V2RayConnectionState.connected;
    } else if (upperState.contains('CONNECTING')) {
      return V2RayConnectionState.connecting;
    } else if (upperState.contains('ERROR')) {
      return V2RayConnectionState.error;
    } else {
      return V2RayConnectionState.disconnected;
    }
  }
  
  // 处理flutter_v2ray状态变化
  static void _handleV2RayStatusChange(v2ray.V2RayStatus pluginStatus) {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    try {
      // 映射插件状态到我们的状态 - pluginStatus.state已经是String
      final mappedState = _mapPluginState(pluginStatus.state);
      
      // 更新流量统计
      _uploadTotal = pluginStatus.upload;
      _downloadTotal = pluginStatus.download;
      
      // 创建我们的状态对象
      final ourStatus = V2RayStatus(
        duration: pluginStatus.duration,
        uploadSpeed: pluginStatus.uploadSpeed,
        downloadSpeed: pluginStatus.downloadSpeed,
        upload: pluginStatus.upload,
        download: pluginStatus.download,
        state: mappedState,
      );
      
      _updateStatus(ourStatus);
      
      // 同步运行状态
      final wasRunning = _isRunning;
      if (mappedState == V2RayConnectionState.connected && !_isRunning) {
        _isRunning = true;
        _connectionStartTime = DateTime.now();
      } else if (mappedState == V2RayConnectionState.disconnected && _isRunning) {
        _isRunning = false;
        _connectionStartTime = null;
      }
      
      // 记录状态变化
      if (wasRunning != _isRunning) {
        _log.info('V2Ray状态变化: ${_isRunning ? "已连接" : "已断开"}', tag: _logTag);
      }
      
    } catch (e) {
      _log.error('处理V2Ray状态变化失败: $e', tag: _logTag);
    }
  }
  
  // 查询当前V2Ray状态（移动平台）
  static Future<V2RayConnectionState> queryConnectionState() async {
    // 直接返回当前状态，不主动查询
    // 状态通过onStatusChanged回调自动更新
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
      
      // 移动端特殊处理：确保配置简洁
      if (Platform.isAndroid || Platform.isIOS) {
        // 移除可能存在的不兼容配置
        _cleanMobileConfig(config);
      }
      
      return config;
    } catch (e) {
      await _log.error('加载配置模板失败: $e', tag: _logTag);
      throw '无法加载V2Ray配置模板';
    }
  }
  
  // 清理移动端配置，移除不兼容的特性
  static void _cleanMobileConfig(Map<String, dynamic> config) {
    // 移除Stats API相关
    config.remove('stats');
    config.remove('api');
    config.remove('policy');
    
    // 移除API入站
    if (config['inbounds'] is List) {
      (config['inbounds'] as List).removeWhere(
        (inbound) => inbound['tag'] == 'api'
      );
    }
    
    // 移除fragment相关出站
    if (config['outbounds'] is List) {
      final outbounds = config['outbounds'] as List;
      
      // 移除proxy3等额外出站
      outbounds.removeWhere(
        (outbound) => outbound['tag'] == 'proxy3'
      );
      
      // 清理proxy出站的dialerProxy
      for (var outbound in outbounds) {
        if (outbound['tag'] == 'proxy') {
          // 移除sockopt中的dialerProxy
          if (outbound['streamSettings']?['sockopt']?['dialerProxy'] != null) {
            (outbound['streamSettings']['sockopt'] as Map).remove('dialerProxy');
            
            // 如果sockopt为空，则移除整个sockopt
            if ((outbound['streamSettings']['sockopt'] as Map).isEmpty) {
              (outbound['streamSettings'] as Map).remove('sockopt');
            }
          }
        }
      }
    }
    
    // 移除API相关路由规则
    if (config['routing']?['rules'] is List) {
      (config['routing']['rules'] as List).removeWhere(
        (rule) => rule['inboundTag']?.contains('api') == true
      );
    }
  }
  
  // 生成配置（统一处理） - 优化版，支持动态参数
  static Future<Map<String, dynamic>> _generateConfigMap({
    required String serverIp,
    required int serverPort,
    String? serverName,
    int localPort = 7898,
    int httpPort = 7899,
  }) async {
    // 加载配置模板（已根据平台自动选择）
    Map<String, dynamic> config = await _loadConfigTemplate();
    
    // 检查服务器群组配置（从AppConfig读取）
    final groupServer = AppConfig.getRandomServer();
    if (groupServer != null) {
      serverIp = groupServer['address'];
      serverPort = groupServer['port'] ?? 443;
      serverName = groupServer['serverName'];
      await _log.info('使用服务器群组: $serverIp:$serverPort', tag: _logTag);
    }
    
    // 更新入站端口
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
    
    // 更新出站服务器信息
    if (config['outbounds'] is List) {
      for (var outbound in config['outbounds']) {
        if (outbound is Map && 
            outbound['tag'] == 'proxy' && 
            outbound['settings'] is Map) {
          
          // 更新服务器地址和端口
          var vnext = outbound['settings']['vnext'];
          if (vnext is List && vnext.isNotEmpty && vnext[0] is Map) {
            vnext[0]['address'] = serverIp;
            vnext[0]['port'] = serverPort;
            await _log.info('配置服务器: $serverIp:$serverPort', tag: _logTag);
          }
          
          // 更新TLS和WebSocket配置
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
        }
      }
    }
    
    // 移动端额外验证
    if (Platform.isAndroid || Platform.isIOS) {
      // 再次确保移动端配置的简洁性
      _cleanMobileConfig(config);
      
      // 记录最终配置概要
      await _log.info('移动端配置概要:', tag: _logTag);
      await _log.info('  - 入站数量: ${(config['inbounds'] as List?)?.length ?? 0}', tag: _logTag);
      await _log.info('  - 出站数量: ${(config['outbounds'] as List?)?.length ?? 0}', tag: _logTag);
      await _log.info('  - 路由规则数: ${(config['routing']?['rules'] as List?)?.length ?? 0}', tag: _logTag);
      
      // 检查是否有fragment或dialerProxy
      bool hasFragment = false;
      bool hasDialerProxy = false;
      
      if (config['outbounds'] is List) {
        for (var outbound in config['outbounds']) {
          if (outbound['settings']?['fragment'] != null) {
            hasFragment = true;
          }
          if (outbound['streamSettings']?['sockopt']?['dialerProxy'] != null) {
            hasDialerProxy = true;
          }
        }
      }
      
      if (hasFragment || hasDialerProxy) {
        await _log.warn('警告：移动端配置包含不兼容特性 - Fragment: $hasFragment, DialerProxy: $hasDialerProxy', 
                       tag: _logTag);
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
  
  // 启动V2Ray服务 - 修改：添加proxyOnly参数
  static Future<bool> start({
    required String serverIp,
    int serverPort = 443,
    String? serverName,
    bool proxyOnly = false,  // 新增参数
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
      
      await _log.info('开始启动V2Ray服务 - 服务器: $serverIp:$serverPort, 代理模式: $proxyOnly', tag: _logTag);
      
      // 更新状态为连接中
      _updateStatus(V2RayStatus(state: V2RayConnectionState.connecting));
      
      // ============ Android/iOS平台 ============
      if (Platform.isAndroid || Platform.isIOS) {
        return await _startMobilePlatform(
          serverIp: serverIp,
          serverPort: serverPort,
          serverName: serverName,
          proxyOnly: proxyOnly,  // 传递参数
        );
      }
      
      // ============ Windows/桌面平台 ============
      return await _startDesktopPlatform(
        serverIp: serverIp,
        serverPort: serverPort,
        serverName: serverName,
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
  
  // 移动平台启动逻辑 - 优化版，使用移动端专用配置
  static Future<bool> _startMobilePlatform({
    required String serverIp,
    required int serverPort,
    String? serverName,
    bool proxyOnly = false,  // 新增参数
  }) async {
    await _log.info('移动平台：启动V2Ray (代理模式: $proxyOnly)', tag: _logTag);
    
    try {
      // 1. 确保flutter_v2ray已初始化
      await _ensureFlutterV2rayInitialized();
      
      // 2. 请求权限（Android）- 代理模式不需要VPN权限
      if (Platform.isAndroid && !proxyOnly) {
        final hasPermission = await _flutterV2ray!.requestPermission();
        if (!hasPermission) {
          await _log.error('VPN权限被拒绝', tag: _logTag);
          _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
          return false;
        }
        await _log.info('VPN权限已授予', tag: _logTag);
      }
      
      // 3. 生成配置（会自动使用移动端配置模板）
      final configMap = await _generateConfigMap(
        serverIp: serverIp,
        serverPort: serverPort,
        serverName: serverName,
        localPort: AppConfig.v2raySocksPort,
        httpPort: AppConfig.v2rayHttpPort,
      );
      
      final configJson = jsonEncode(configMap);
      await _log.info('配置已生成，长度: ${configJson.length}', tag: _logTag);
      
      // 在调试模式下，输出配置的关键信息
      if (kDebugMode) {
        await _log.debug('配置详情:', tag: _logTag);
        await _log.debug('  - 协议: ${configMap['outbounds']?[0]?['protocol']}', tag: _logTag);
        await _log.debug('  - 服务器: $serverIp:$serverPort', tag: _logTag);
        await _log.debug('  - ServerName: $serverName', tag: _logTag);
      }
      
      // 4. 启动V2Ray - 移除不存在的参数
      await _flutterV2ray!.startV2Ray(
        remark: serverName ?? "Proxy Server",
        config: configJson,
        blockedApps: null,  // 可以后续添加应用分流功能
        bypassSubnets: null,  // 可以后续添加子网绕过功能
        proxyOnly: proxyOnly,  // 使用传入的参数
      );
      
      await _log.info('V2Ray启动命令已发送', tag: _logTag);
      
      // 5. 等待连接建立 - 依赖状态回调，不主动查询
      await Future.delayed(AppConfig.v2rayCheckDelay);
      
      // 6. 检查状态（通过回调更新的_currentStatus）
      if (_currentStatus.state == V2RayConnectionState.connected) {
        _isRunning = true;
        await _log.info('V2Ray已连接', tag: _logTag);
      } else if (_currentStatus.state == V2RayConnectionState.connecting) {
        // 7. 如果还在连接中，再等待一次
        await _log.info('V2Ray连接中，再等待2秒', tag: _logTag);
        await Future.delayed(const Duration(seconds: 2));
        
        // 再次检查状态
        if (_currentStatus.state == V2RayConnectionState.connected) {
          _isRunning = true;
          await _log.info('V2Ray连接成功', tag: _logTag);
        }
      }
      
      // 8. 更新最终状态
      if (_isRunning) {
        _connectionStartTime = DateTime.now();
        _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
        await _log.info('V2Ray连接成功', tag: _logTag);
      } else {
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        await _log.warn('V2Ray连接失败', tag: _logTag);
        
        // 输出更多调试信息
        if (kDebugMode) {
          await _log.debug('连接失败详情:', tag: _logTag);
          await _log.debug('  - 配置长度: ${configJson.length}', tag: _logTag);
          await _log.debug('  - ProxyOnly: $proxyOnly', tag: _logTag);
        }
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
  
  // 桌面平台启动逻辑（Windows）
  static Future<bool> _startDesktopPlatform({
    required String serverIp,
    required int serverPort,
    String? serverName,
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
  
  // 停止V2Ray服务 - 修复版
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
          if (_flutterV2ray != null && _isFlutterV2rayInitialized) {
            await _flutterV2ray!.stopV2Ray();
            await _log.info('移动平台：V2Ray已停止', tag: _logTag);
          }
        } catch (e) {
          await _log.error('移动平台停止失败: $e', tag: _logTag);
        }
        // 移动端不使用计时器，所以不需要停止
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
    
    // 清理flutter_v2ray引用
    _flutterV2ray = null;
    _isFlutterV2rayInitialized = false;
    
    // 关闭状态流
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
