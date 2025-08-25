import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
/// 简化版本：移除AppProxyMode，只使用allowedApps列表
class V2RayService {
  // ============ Windows平台专用变量 ============
  // Windows平台进程管理
  static Process? _v2rayProcess;
  
  // 回调函数
  static Function? _onProcessExit;
  
  // 记录是否已记录V2Ray目录信息（仅Windows）
  static bool _hasLoggedV2RayInfo = false;
  
  // ============ 通用状态管理 ============
  // 服务状态管理
  static bool _isRunning = false;
  
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
  
  // ============ 统一配置路径 ============
  // 配置文件路径 - 统一使用一个配置文件
  static const String CONFIG_PATH = 'assets/js/v2ray_config.json';
  
  // ============ Windows平台专用方法 ============
  // 平台相关的可执行文件名（仅Windows使用）
  static String get _v2rayExecutableName {
    if (Platform.isWindows) {
      return 'v2ray.exe';
    }
    throw UnsupportedError('仅Windows平台需要可执行文件');
  }
  
  static String get _v2ctlExecutableName {
    if (Platform.isWindows) {
      return 'v2ctl.exe';
    }
    throw UnsupportedError('仅Windows平台需要可执行文件');
  }
  
  // 获取可执行文件路径（仅Windows平台）
  static Future<String> getExecutablePath(String executableName) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('仅Windows平台支持');
    }
    
    final exePath = Platform.resolvedExecutable;
    final directory = path.dirname(exePath);
    return path.join(directory, executableName);
  }
  
  static Future<String> _getV2RayPath() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('仅Windows平台需要V2Ray路径');
    }
    return getExecutablePath(path.join('v2ray', _v2rayExecutableName));
  }
  
  // 设置进程退出回调（仅Windows）
  static void setOnProcessExit(Function callback) {
    if (!Platform.isWindows) {
      _log.warn('setOnProcessExit仅在Windows平台有效', tag: _logTag);
      return;
    }
    _onProcessExit = callback;
  }
  
  // ============ 通用接口方法 ============
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
  
  // 更新通知栏文字（语言切换时调用）
  static Future<void> updateNotificationStrings(Map<String, String> localizedStrings) async {
    // 平台检查
    if (!Platform.isAndroid && !Platform.isIOS) {
      await _log.debug('非移动平台，跳过通知栏更新', tag: _logTag);
      return;
    }
    
    // 状态检查
    if (!_isRunning) {
      await _log.debug('V2Ray未运行，跳过通知栏更新', tag: _logTag);
      return;
    }
    
    try {
      await _log.info('开始更新通知栏本地化文字', tag: _logTag);
      
      // 确保通道已初始化
      if (!_isChannelInitialized) {
        _initializeChannelListeners();
      }
      
      // 通过原生通道更新通知栏文字
      final result = await _channel.invokeMethod<bool>('updateNotificationStrings', localizedStrings);
      
      if (result == true) {
        await _log.info('通知栏文字更新成功', tag: _logTag);
      } else {
        await _log.warn('通知栏文字更新失败：原生端返回false', tag: _logTag);
      }
    } catch (e) {
      await _log.error('更新通知栏文字异常', tag: _logTag, error: e);
      // 不抛出异常，避免影响正常功能
    }
  }
  
  // ============ 新增：移动端连接状态恢复方法 ============
  /// 恢复移动端连接状态（应用从后台恢复时调用）
  /// 此方法会恢复V2RayService的内部状态并启动流量统计定时器
  /// 
  /// @param connectTime 连接开始时间
  static Future<void> restoreMobileConnectionState(DateTime connectTime) async {
    // 仅在移动平台执行
    if (!Platform.isAndroid && !Platform.isIOS) {
      await _log.debug('非移动平台，跳过状态恢复', tag: _logTag);
      return;
    }
    
    await _log.info('恢复移动端V2Ray连接状态', tag: _logTag);
    
    // 恢复运行状态
    _isRunning = true;
    
    // 恢复连接时间
    _connectionStartTime = connectTime;
    
    // 更新连接状态
    _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
    
    // 确保通道已初始化
    if (!_isChannelInitialized) {
      _initializeChannelListeners();
    }
    
    // 启动移动端状态定时器（会自动停止旧的定时器）
    _startMobileStatusTimer();
    
    // 立即更新一次状态，确保UI能立即显示流量数据
    await _updateMobileStatus();
    
    await _log.info('移动端V2Ray状态恢复完成', tag: _logTag);
  }
  
  // ============ 移动平台方法 ============
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
  
  // 启动移动端状态定时器 - 修复：使用AppConfig.trafficStatsInterval
  static void _startMobileStatusTimer() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    _stopMobileStatusTimer();
    
    // 立即更新一次
    _updateMobileStatus();
    
    // 定期更新状态 - 修复：使用AppConfig的配置而不是硬编码
    _statusCheckTimer = Timer.periodic(AppConfig.trafficStatsInterval, (_) {
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
  
  // ============ 通用方法 ============
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
  
  // 清理JSON注释（修复关键函数）
  static String _removeJsonComments(String jsonString) {
    // 保存字符串内的内容，避免误删
    final stringPattern = RegExp(r'"(?:[^"\\]|\\.)*"');
    final strings = <String>[];
    var placeholder = '__STRING_PLACEHOLDER_';
    var index = 0;
    
    // 替换所有字符串为占位符
    String processed = jsonString.replaceAllMapped(stringPattern, (match) {
      final key = '$placeholder${index++}__';
      strings.add(match.group(0)!);
      return key;
    });
    
    // 移除单行注释
    processed = processed.replaceAll(RegExp(r'//[^\n\r]*'), '');
    
    // 移除多行注释
    processed = processed.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    
    // 恢复字符串
    for (var i = 0; i < strings.length; i++) {
      processed = processed.replaceFirst('$placeholder${i}__', strings[i]);
    }
    
    // 移除尾部逗号（JSON标准不允许）
    processed = processed.replaceAllMapped(
      RegExp(r',(\s*[}\]])'),
      (match) => match.group(1)!,
    );
    
    return processed;
  }
  
  // 加载配置模板 - 修复：添加注释清理
  static Future<Map<String, dynamic>> _loadConfigTemplate() async {
    try {
      await _log.info('加载配置文件: $CONFIG_PATH', tag: _logTag);
      
      // 读取原始文件内容
      String jsonString = await rootBundle.loadString(CONFIG_PATH);
      
      // 关键修复：清理JSON注释
      jsonString = _removeJsonComments(jsonString);
      
      // 解析清理后的JSON
      final config = jsonDecode(jsonString);
      
      return config;
    } catch (e) {
      await _log.error('加载配置模板失败: $e', tag: _logTag);
      throw '无法加载V2Ray配置模板';
    }
  }
  
// 生成配置（统一处理） - 优化全局代理实现
static Future<Map<String, dynamic>> _generateConfigMap({
  required String serverIp,
  required int serverPort,
  String? serverName,
  int localPort = AppConfig.v2raySocksPort,
  int httpPort = AppConfig.v2rayHttpPort,
  bool globalProxy = false,
}) async {
  // 加载配置模板
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
    await _log.info('使用服务器配置: CDN=$serverIp, ServerName=$serverName', tag: _logTag);
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
  
  // 记录实际使用的端口（用于日志）
  int actualPort = serverPort;  // 默认使用传入的端口
  
  // 更新出站服务器信息 - 只更新proxy出站
  if (config['outbounds'] is List) {
    for (var outbound in config['outbounds']) {
      if (outbound is Map && outbound['tag'] == 'proxy') {
        // 更新服务器地址，但保留配置文件中的端口
        if (outbound['settings']?['vnext'] is List) {
          var vnext = outbound['settings']['vnext'] as List;
          if (vnext.isNotEmpty && vnext[0] is Map) {
            vnext[0]['address'] = serverIp;  // 使用CDN IP
            
            // 🔧 关键修改：不覆盖端口，使用配置文件中的端口
            // 获取配置文件中的原始端口
            if (vnext[0]['port'] != null && vnext[0]['port'] > 0) {
              actualPort = vnext[0]['port'];
              await _log.info('使用配置文件中的端口: $actualPort', tag: _logTag);
            } else {
              // 只有当配置文件中没有端口时，才使用传入的端口
              vnext[0]['port'] = serverPort;
              actualPort = serverPort;
              await _log.info('配置文件未定义端口，使用传入端口: $actualPort', tag: _logTag);
            }
            
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
  
  // 优化后的全局代理模式处理
  if (globalProxy) {
    await _log.info('配置全局代理模式', tag: _logTag);
    
    if (config['routing'] is Map && config['routing']['rules'] is List) {
      final rules = config['routing']['rules'] as List;
      
      // 创建新的规则列表，只保留必要的规则
      final newRules = <Map<String, dynamic>>[];
      
      // 1. 保留API路由规则（如果有）
      for (var rule in rules) {
        if (rule is Map) {
          // 检查是否是API路由
          if (rule['inboundTag'] != null && 
              (rule['inboundTag'] is List) &&
              (rule['inboundTag'] as List).contains('api')) {
            // 将Map<dynamic, dynamic>转换为Map<String, dynamic>
            final convertedRule = <String, dynamic>{};
            rule.forEach((key, value) {
              convertedRule[key.toString()] = value;
            });
            newRules.add(convertedRule);
            await _log.debug('保留API路由规则', tag: _logTag);
          }
        }
      }
      
      // 2. 添加一个明确的全局代理规则（确保所有流量走proxy）
      newRules.add({
        'type': 'field',
        'port': '0-65535',
        'outboundTag': 'proxy'
      });
      await _log.debug('添加全局代理规则: 0-65535 -> proxy', tag: _logTag);
      
      // 3. 替换原有规则
      config['routing']['rules'] = newRules;
      
      await _log.info('全局代理配置完成，规则数量: ${newRules.length}', tag: _logTag);
    }
  } else {
    // 智能分流模式：保持原有规则不变
    await _log.info('使用智能分流模式，保留所有路由规则', tag: _logTag);
  }
  
  // 记录最终配置概要
    await _log.debug('配置概要:', tag: _logTag);
    await _log.debug('  - CDN IP: $serverIp:$actualPort', tag: _logTag);  // 使用实际端口
    await _log.debug('  - ServerName: $serverName', tag: _logTag);
    await _log.debug('  - 代理模式: ${globalProxy ? "全局代理" : "智能分流"}', tag: _logTag);
    if (userId != null && userId.isNotEmpty) {
      final displayUuid = userId.length > 8 ? '${userId.substring(0, 8)}...' : userId;
      await _log.debug('  - UUID: $displayUuid', tag: _logTag);
    }
    
    // 输出路由规则数量
    if (config['routing'] is Map && config['routing']['rules'] is List) {
      final ruleCount = (config['routing']['rules'] as List).length;
      await _log.debug('  - 路由规则数: $ruleCount', tag: _logTag);
    }
  
  return config;
}
  
  // 生成配置文件（仅Windows平台）
  static Future<void> _generateConfigFile({
    required String serverIp,
    required int serverPort,
    String? serverName,
    int localPort = AppConfig.v2raySocksPort,
    int httpPort = AppConfig.v2rayHttpPort,
    bool globalProxy = false,
  }) async {
    if (!Platform.isWindows) return;
    
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
  
  // 清理DNS缓存（可选功能）
  static Future<void> clearDnsCache() async {
    try {
      if (Platform.isWindows) {
        // Windows: 使用 ipconfig /flushdns
        final result = await Process.run('ipconfig', ['/flushdns'], runInShell: true);
        if (result.exitCode == 0) {
          await _log.info('Windows DNS缓存已清理', tag: _logTag);
        } else {
          await _log.warn('DNS缓存清理失败: ${result.stderr}', tag: _logTag);
        }
      } 
      else if (Platform.isAndroid || Platform.isIOS) {
        // 移动平台：需要原生端支持
        // 暂时不实现，因为需要原生端配合
        await _log.debug('移动平台DNS缓存清理暂未实现', tag: _logTag);
      }
      else if (Platform.isMacOS) {
        // macOS: 使用 dscacheutil
        await Process.run('dscacheutil', ['-flushcache'], runInShell: true);
        await _log.info('macOS DNS缓存已清理', tag: _logTag);
      }
      else if (Platform.isLinux) {
        // Linux: 重启 systemd-resolved 或 nscd
        try {
          await Process.run('systemctl', ['restart', 'systemd-resolved'], runInShell: true);
        } catch (e) {
          // 如果systemd-resolved不存在，尝试nscd
          try {
            await Process.run('service', ['nscd', 'restart'], runInShell: true);
          } catch (e2) {
            await _log.debug('Linux DNS缓存清理失败', tag: _logTag);
          }
        }
        await _log.info('Linux DNS缓存已清理', tag: _logTag);
      }
    } catch (e) {
      await _log.warn('清理DNS缓存失败: $e', tag: _logTag);
    }
  }
  
  // 测试远程连接（Windows平台专用）
  static Future<bool> _testRemoteConnection() async {
    try {
      await _log.info('测试远程服务器连接...', tag: _logTag);
      
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      
      // 设置HTTP代理
      client.findProxy = (uri) => 'PROXY 127.0.0.1:${AppConfig.v2rayHttpPort}';
      
      // 测试Google 204端点（与Android端保持一致）
      final request = await client.getUrl(Uri.parse('http://www.google.com/generate_204'));
      final response = await request.close();
      client.close();
      
      final success = (response.statusCode == 204 || response.statusCode == 200);
      
      if (success) {
        await _log.info('✅ 远程连接测试成功，响应码: ${response.statusCode}', tag: _logTag);
      } else {
        await _log.error('❌ 远程连接测试失败，响应码: ${response.statusCode}', tag: _logTag);
      }
      
      return success;
      
    } catch (e) {
      await _log.error('❌ 远程连接测试异常: ${e.toString().split('\n').first}', tag: _logTag);
      return false;
    }
  }
  
  // 启动V2Ray服务（增强版，支持新功能）
  static Future<bool> start({
    required String serverIp,
    int serverPort = AppConfig.v2rayDefaultServerPort,
    String? serverName,
    bool globalProxy = false,
    // 新增参数（移动端特有）
    List<String>? allowedApps,  // 简化：只保留允许列表
    List<String>? bypassSubnets,
    String disconnectButtonName = '停止',
    // 新增：国际化文字
    Map<String, String>? localizedStrings,
    // 新增：虚拟DNS开关
    bool enableVirtualDns = false,
  }) async {
    // 平台支持检查
    if (!Platform.isWindows && !Platform.isAndroid && !Platform.isIOS) {
      await _log.error('不支持的平台: ${Platform.operatingSystem}', tag: _logTag);
      throw UnsupportedError('V2Ray服务仅支持Windows、Android和iOS平台');
    }
    
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
      
      // 清理DNS缓存（可选，仅在Windows平台有效）
      if (Platform.isWindows) {
        await clearDnsCache();
      }
      
      await _log.info('开始启动V2Ray服务 - CDN IP: $serverIp:$serverPort, 全局代理: $globalProxy, 虚拟DNS: $enableVirtualDns', tag: _logTag);
      
      // 更新状态为连接中
      _updateStatus(V2RayStatus(state: V2RayConnectionState.connecting));
      
      // ============ Android/iOS平台 ============
      if (Platform.isAndroid || Platform.isIOS) {
        return await _startMobilePlatform(
          serverIp: serverIp,
          serverPort: serverPort,
          serverName: serverName,
          globalProxy: globalProxy,
          allowedApps: allowedApps,
          bypassSubnets: bypassSubnets,
          disconnectButtonName: disconnectButtonName,
          localizedStrings: localizedStrings,
          enableVirtualDns: enableVirtualDns,  // 传递虚拟DNS参数
        );
      }
      
      // ============ Windows平台 ============
      if (Platform.isWindows) {
        return await _startDesktopPlatform(
          serverIp: serverIp,
          serverPort: serverPort,
          serverName: serverName,
          globalProxy: globalProxy,
        );
      }
      
      // 不应该到达这里
      throw UnsupportedError('未知平台错误');
      
    } catch (e, stackTrace) {
      await _log.error('启动V2Ray失败', tag: _logTag, error: e, stackTrace: stackTrace);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    } finally {
      _isStarting = false;
    }
  }
  
  // 移动平台启动逻辑 - 增强版，支持新功能（简化版）
  static Future<bool> _startMobilePlatform({
    required String serverIp,
    required int serverPort,
    String? serverName,
    bool globalProxy = false,
    List<String>? allowedApps,
    List<String>? bypassSubnets,
    String disconnectButtonName = '停止',
    Map<String, String>? localizedStrings,
    bool enableVirtualDns = false,  // 新增参数
  }) async {
    await _log.info('移动平台：启动V2Ray (全局代理: $globalProxy, 虚拟DNS: $enableVirtualDns)', tag: _logTag);
    
    try {
      // 1. 初始化通道监听
      _initializeChannelListeners();
      
      // 2. 生成配置
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
      
        await _log.debug('配置详情:', tag: _logTag);
        await _log.debug('  - 协议: ${configMap['outbounds']?[0]?['protocol']}', tag: _logTag);
        await _log.debug('  - CDN IP: $serverIp:$serverPort', tag: _logTag);
        await _log.debug('  - ServerName: $serverName', tag: _logTag);
        await _log.debug('  - 全局代理: $globalProxy', tag: _logTag);
        await _log.debug('  - 虚拟DNS: $enableVirtualDns', tag: _logTag);
        if (allowedApps != null && allowedApps.isNotEmpty) {
          await _log.debug('  - 允许应用: ${allowedApps.length}个', tag: _logTag);
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
      
      // 3. 准备调用参数（简化版） - 添加虚拟DNS参数
      final params = <String, dynamic>{
        'config': configJson,
        'globalProxy': globalProxy,
        'allowedApps': allowedApps,  // 简化：只传递允许列表
        'bypassSubnets': bypassSubnets,
        'disconnectButtonName': disconnectButtonName,
        'enableVirtualDns': enableVirtualDns,  // 传递虚拟DNS开关
        'virtualDnsPort': AppConfig.virtualDnsPort,  // 传递虚拟DNS端口配置
      };
      
      // 添加国际化文字（如果提供）
      if (localizedStrings != null) {
        params.addAll(localizedStrings);
      }
      
      // 3. 通过原生通道启动V2Ray（增强版）
      final result = await _channel.invokeMethod<bool>('startVpn', params);
      
      if (result == true) {
        await _log.info('V2Ray启动命令已发送，等待连接建立', tag: _logTag);
        
        // 4. 等待连接建立
        await Future.delayed(AppConfig.v2rayCheckDelay);
        
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
  
  // 保存代理配置（分应用代理、子网绕过等） - 简化版
  static Future<void> saveProxyConfig({
    List<String>? allowedApps,
    List<String>? bypassSubnets,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    try {
      await _channel.invokeMethod('saveProxyConfig', {
        'allowedApps': allowedApps ?? [],
        'bypassSubnets': bypassSubnets ?? [],
      });
      _log.info('代理配置已保存', tag: _logTag);
    } catch (e) {
      _log.error('保存代理配置失败: $e', tag: _logTag);
    }
  }
  
  // 加载代理配置 - 简化版
  static Future<Map<String, List<String>>> loadProxyConfig() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return {
        'allowedApps': [],
        'bypassSubnets': [],
      };
    }
    
    try {
      final config = await _channel.invokeMethod<Map>('loadProxyConfig');
      if (config != null) {
        return {
          'allowedApps': List<String>.from(config['allowedApps'] ?? []),
          'bypassSubnets': List<String>.from(config['bypassSubnets'] ?? []),
        };
      }
    } catch (e) {
      _log.error('加载代理配置失败: $e', tag: _logTag);
    }
    
    return {
      'allowedApps': [],
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
  
  // 桌面平台启动逻辑（Windows） - 添加远程连接测试
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
      
      // 重置流量统计（防止进程异常退出时资源未清理）
      _uploadTotal = 0;
      _downloadTotal = 0;
      _lastUploadBytes = 0;
      _lastDownloadBytes = 0;
      _lastUpdateTime = 0;
      
      _stopStatsTimer();
      _stopDurationTimer();
      _updateStatus(V2RayStatus(state: V2RayConnectionState.disconnected));
      if (_onProcessExit != null) {
        _onProcessExit!();
      }
    });
    
    // 等待V2Ray启动
    await Future.delayed(AppConfig.v2rayStartupWait);
    
    // 检查端口监听（同时检查SOCKS和HTTP端口）
    if (!await isPortListening(AppConfig.v2raySocksPort)) {
      await _log.error('V2Ray SOCKS端口未监听', tag: _logTag);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    }
    
    if (!await isPortListening(AppConfig.v2rayHttpPort)) {
      await _log.error('V2Ray HTTP端口未监听', tag: _logTag);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    }
    
    await _log.info('V2Ray端口已监听，测试远程连接...', tag: _logTag);
    
    // 测试远程连接（与Android端逻辑一致）
    await Future.delayed(const Duration(milliseconds: 500)); // 等待服务稳定
    
    bool connectionTestSuccess = await _testRemoteConnection();
    
    if (!connectionTestSuccess) {
      // 重试一次（与Android端一致）
      await _log.info('连接测试失败，2秒后重试', tag: _logTag);
      await Future.delayed(const Duration(seconds: 2));
      connectionTestSuccess = await _testRemoteConnection();
    }
    
    if (!connectionTestSuccess) {
      await _log.error('Unable to connect to remote server', tag: _logTag);  // 与Android端保持一致的错误消息
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    }
    
    // 测试通过，设置状态
    await _log.info('✅ V2Ray服务完全就绪', tag: _logTag);
    
    _isRunning = true;
    _uploadTotal = 0;
    _downloadTotal = 0;
    _lastUpdateTime = 0;
    _lastUploadBytes = 0;
    _lastDownloadBytes = 0;
    
    _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
    _startStatsTimer();
    _startDurationTimer();
    
    return true;
  }
  
  // 停止V2Ray服务 - 修复：添加资源清理
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
      
      // 【修复】重置流量统计
      _uploadTotal = 0;
      _downloadTotal = 0;
      _lastUploadBytes = 0;
      _lastDownloadBytes = 0;
      _lastUpdateTime = 0;
      
      // 【修复】重置连接时间
      _connectionStartTime = null;
      
      // ============ 移动平台停止 ============
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
      } 
      // ============ Windows平台停止 ============
      else if (Platform.isWindows) {
        // 重置Windows专用标志
        _hasLoggedV2RayInfo = false;
        
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
        try {
          await Process.run('taskkill', ['/F', '/IM', _v2rayExecutableName], 
            runInShell: true);
        } catch (e) {
          // 忽略错误
        }
      }
      // ============ 其他平台 ============
      else {
        await _log.warn('停止V2Ray：不支持的平台 ${Platform.operatingSystem}', tag: _logTag);
      }
      
      await _log.info('V2Ray服务已停止', tag: _logTag);
      
    } finally {
      _isStopping = false;
    }
  }
  
  // Windows平台流量统计
  static void _startStatsTimer() {
    if (!Platform.isWindows) return;  // 仅Windows使用
    
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
    if (!_isRunning || !Platform.isWindows) return;
    
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
          
          // 只统计proxy出站流量（真正的代理流量）
          // 不统计direct（直连）和block（屏蔽）流量
          if (name == "outbound>>>proxy>>>traffic>>>uplink") {
            proxyUplink = value;
          } else if (name == "outbound>>>proxy>>>traffic>>>downlink") {
            proxyDownlink = value;
          }
          // 忽略其他标签如：
          // - outbound>>>direct>>>traffic>>>* （直连流量）
          // - outbound>>>block>>>traffic>>>* （屏蔽流量）
          // - outbound>>>proxy3>>>traffic>>>* （fragment流量）
        }
      }
      
      // 更新流量值（只包含代理流量）
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
          '代理流量: ↑${UIUtils.formatBytes(_uploadTotal)} ↓${UIUtils.formatBytes(_downloadTotal)} ' +
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
  
  // 获取流量统计（只包含代理流量，不包含直连流量）
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
      'uploadTotal': _uploadTotal,        // 代理上传流量
      'downloadTotal': _downloadTotal,    // 代理下载流量
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
    _uploadTotal = 0;
    _downloadTotal = 0;
    
    // 重置Windows专用标志
    if (Platform.isWindows) {
      _hasLoggedV2RayInfo = false;
    }
    
    // 清理通道监听
    _isChannelInitialized = false;
    
    // 关闭状态流
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
