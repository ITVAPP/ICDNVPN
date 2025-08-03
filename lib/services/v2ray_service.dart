import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';

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
  
  // 从原始状态字符串转换
  static V2RayConnectionState parseState(String stateStr) {
    switch (stateStr.toUpperCase()) {
      case 'CONNECTED':
        return V2RayConnectionState.connected;
      case 'CONNECTING':
        return V2RayConnectionState.connecting;
      case 'ERROR':
        return V2RayConnectionState.error;
      case 'DISCONNECTED':
      default:
        return V2RayConnectionState.disconnected;
    }
  }
}

/// V2Ray服务管理类
class V2RayService {
  static Process? _v2rayProcess;
  static bool _isRunning = false;
  static Function? _onProcessExit;
  
  // 流量统计相关
  static int _uploadTotal = 0;
  static int _downloadTotal = 0;
  static Timer? _statsTimer;
  
  // 速度计算相关
  static int _lastUpdateTime = 0;
  static int _lastUploadBytes = 0;
  static int _lastDownloadBytes = 0;
  
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
  
  // 移动平台通道
  static const MethodChannel _methodChannel = MethodChannel('flutter_v2ray');
  static const EventChannel _eventChannel = EventChannel('flutter_v2ray/status');
  static StreamSubscription? _statusSubscription;
  
  // 记录是否已记录V2Ray目录信息
  static bool _hasLoggedV2RayInfo = false;
  
  // 根据平台获取可执行文件名
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
  
  static Future<String> getExecutablePath(String executableName) async {
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
      throw UnsupportedError('Mobile platforms use native integration');
    }
  }
  
  static Future<String> _getV2RayPath() async {
    return getExecutablePath(path.join('v2ray', _v2rayExecutableName));
  }
  
  // 设置进程退出回调
  static void setOnProcessExit(Function callback) {
    _onProcessExit = callback;
  }
  
  // 获取当前状态
  static V2RayStatus get currentStatus => _currentStatus;
  
  // 获取连接状态
  static V2RayConnectionState get connectionState => _currentStatus.state;
  
  // 是否已连接
  static bool get isConnected => _currentStatus.state == V2RayConnectionState.connected;
  
  // 安全解析整数
  static int _parseIntSafely(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }
  
  // 请求Android VPN权限
  static Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      try {
        await _log.info('请求Android VPN权限', tag: _logTag);
        final result = await _methodChannel.invokeMethod('requestPermission');
        final hasPermission = result ?? false;
        await _log.info('VPN权限请求结果: $hasPermission', tag: _logTag);
        return hasPermission;
      } catch (e) {
        await _log.error('请求VPN权限失败: $e', tag: _logTag);
        return false;
      }
    }
    return true; // 非Android平台默认返回true
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
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final result = await _methodChannel.invokeMethod('getV2rayStatus');
        if (result != null) {
          final resultStr = result.toString();
          // 处理多种可能的格式
          String stateStr;
          if (resultStr.contains('_')) {
            final parts = resultStr.split('_');
            stateStr = parts.isNotEmpty ? parts.last : 'DISCONNECTED';
          } else {
            stateStr = resultStr;
          }
          return V2RayStatus.parseState(stateStr);
        }
      } catch (e) {
        await _log.error('查询连接状态失败: $e', tag: _logTag);
        // 返回当前缓存的状态而不是默认值
        return _currentStatus.state;
      }
    }
    return _currentStatus.state;
  }
  
  // 检查端口是否在监听
  static Future<bool> isPortListening(int port) async {
    try {
      final client = await Socket.connect('127.0.0.1', port, 
        timeout: const Duration(seconds: 1));
      await client.close();
      return true;
    } catch (e) {
      return false;
    }
  }
  
  static Future<Map<String, dynamic>> _loadConfigTemplate() async {
    try {
      // 从assets加载配置模板
      final String jsonString = await rootBundle.loadString('assets/js/v2ray_config.json');
      return jsonDecode(jsonString);
    } catch (e) {
      await _log.error('加载配置模板失败: $e', tag: _logTag);
      throw '无法加载V2Ray配置模板';
    }
  }
  
  static Future<void> generateConfig({
    required String serverIp,
    int serverPort = 443,
    String? serverName,  // 新增可选参数
    int localPort = 7898,
    int httpPort = 7899,
  }) async {
    final v2rayPath = await _getV2RayPath();
    final configPath = path.join(
      path.dirname(v2rayPath),
      'config.json'
    );

    try {
      // 加载配置模板
      Map<String, dynamic> config = await _loadConfigTemplate();
      
      // 替换动态参数
      // 更新入站端口 - 添加类型检查
      if (config['inbounds'] is List) {
        for (var inbound in config['inbounds']) {
          if (inbound is Map && inbound['tag'] == 'socks') {
            inbound['port'] = localPort;
          } else if (inbound is Map && inbound['tag'] == 'http') {
            inbound['port'] = httpPort;
          }
        }
      }
      
      // 更新出站服务器信息 - 添加类型检查
      if (config['outbounds'] is List) {
        for (var outbound in config['outbounds']) {
          if (outbound is Map && 
              outbound['tag'] == 'proxy' && 
              outbound['settings'] is Map) {
            var vnext = outbound['settings']['vnext'];
            if (vnext is List && vnext.isNotEmpty && vnext[0] is Map) {
              vnext[0]['address'] = serverIp;
              vnext[0]['port'] = serverPort;
            }
            
            // 更新 serverName 和 Host（如果提供了且不为空）
            if (serverName != null && serverName.isNotEmpty && outbound['streamSettings'] is Map) {
              var streamSettings = outbound['streamSettings'] as Map;
              
              // 更新 TLS serverName
              if (streamSettings['tlsSettings'] is Map) {
                streamSettings['tlsSettings']['serverName'] = serverName;
              }
              
              // 更新 WebSocket Host header
              if (streamSettings['wsSettings'] is Map && 
                  streamSettings['wsSettings']['headers'] is Map) {
                streamSettings['wsSettings']['headers']['Host'] = serverName;
              }
            }
          }
        }
      }

      // 写入配置文件
      await File(configPath).writeAsString(jsonEncode(config));
      await _log.info('配置文件已生成: $configPath', tag: _logTag);
    } catch (e) {
      await _log.error('生成配置文件失败: $e', tag: _logTag);
      throw '生成V2Ray配置失败: $e';
    }
  }

  static Future<bool> isPortAvailable(int port) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return true;
      }
      
      final socket = await ServerSocket.bind('127.0.0.1', port, shared: true);
      await socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }
  
  static Future<bool> start({
    required String serverIp,
    int serverPort = 443,
    String? serverName,  // 新增可选参数
  }) async {
    // 并发控制
    if (_isStarting || _isStopping) {
      await _log.warn('V2Ray正在启动或停止中，忽略请求', tag: _logTag);
      return false;
    }
    
    _isStarting = true;
    
    try {
      if (_isRunning) {
        await stop();
      }

      await _log.info('开始启动V2Ray服务 - 服务器: $serverIp:$serverPort', tag: _logTag);
      
      // 更新状态为连接中
      _updateStatus(V2RayStatus(state: V2RayConnectionState.connecting));
      
      // 移动平台使用flutter_v2ray插件
      if (Platform.isAndroid || Platform.isIOS) {
        await _log.info('移动平台：初始化flutter_v2ray', tag: _logTag);
        
        // Android平台请求权限
        if (Platform.isAndroid) {
          final hasPermission = await requestPermission();
          if (!hasPermission) {
            await _log.error('VPN权限被拒绝', tag: _logTag);
            _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
            throw 'VPN permission denied';
          }
        }
        
        // 设置流量和状态监听
        _statusSubscription?.cancel();
        _statusSubscription = _eventChannel.receiveBroadcastStream().distinct().cast().listen((event) {
          if (event != null && event is List && event.length >= 6) {
            try {
              // 解析状态数据
              final status = V2RayStatus(
                duration: event[0]?.toString() ?? "00:00:00",
                uploadSpeed: _parseIntSafely(event[1]),
                downloadSpeed: _parseIntSafely(event[2]),
                upload: _parseIntSafely(event[3]),
                download: _parseIntSafely(event[4]),
                state: V2RayStatus.parseState(event[5]?.toString() ?? "DISCONNECTED"),
              );
              
              _uploadTotal = status.upload;
              _downloadTotal = status.download;
              
              // 更新状态
              _updateStatus(status);
              
              // 如果连接成功，更新运行状态
              if (status.state == V2RayConnectionState.connected) {
                _isRunning = true;
              }
              
            } catch (e) {
              _log.error('解析状态数据失败: $e', tag: _logTag);
            }
          }
        }, onError: (error) {
          _log.error('状态监听错误: $error', tag: _logTag);
          _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        });
        
        // 初始化V2Ray
        try {
          await _methodChannel.invokeMethod('initializeV2Ray', {
            "notificationIconResourceType": "mipmap",
            "notificationIconResourceName": "ic_launcher",
          });
        } catch (e) {
          await _log.error('初始化V2Ray失败: $e', tag: _logTag);
          _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
          throw 'Failed to initialize V2Ray: $e';
        }
        
        // 生成配置
        try {
          // 加载配置模板（移动端也使用同一个配置文件）
          final String jsonString = await rootBundle.loadString('assets/js/v2ray_config.json');
          Map<String, dynamic> configMap = jsonDecode(jsonString);
          
          // 更新服务器信息
          if (configMap['outbounds'] is List) {
            for (var outbound in configMap['outbounds']) {
              if (outbound is Map && 
                  outbound['tag'] == 'proxy' && 
                  outbound['settings'] is Map) {
                var vnext = outbound['settings']['vnext'];
                if (vnext is List && vnext.isNotEmpty && vnext[0] is Map) {
                  vnext[0]['address'] = serverIp;
                  vnext[0]['port'] = serverPort;
                }
                
                // 更新 serverName 和 Host（如果提供了且不为空）
                if (serverName != null && serverName.isNotEmpty && outbound['streamSettings'] is Map) {
                  var streamSettings = outbound['streamSettings'] as Map;
                  
                  // 更新 TLS serverName
                  if (streamSettings['tlsSettings'] is Map) {
                    streamSettings['tlsSettings']['serverName'] = serverName;
                  }
                  
                  // 更新 WebSocket Host header
                  if (streamSettings['wsSettings'] is Map && 
                      streamSettings['wsSettings']['headers'] is Map) {
                    streamSettings['wsSettings']['headers']['Host'] = serverName;
                  }
                }
              }
            }
          }
          
          // 启动V2Ray
          await _methodChannel.invokeMethod('startV2Ray', {
            "remark": "代理服务器",
            "config": jsonEncode(configMap),
            "blocked_apps": null,
            "bypass_subnets": null,
            "proxy_only": false,
            "notificationDisconnectButtonName": "断开",
            "notificationTitle": "V2Ray运行中",
          });
        } catch (e) {
          await _log.error('启动V2Ray失败: $e', tag: _logTag);
          _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
          throw 'Failed to start V2Ray: $e';
        }
        
        // 等待一段时间后查询实际状态
        await Future.delayed(const Duration(seconds: 2));
        final actualState = await queryConnectionState();
        _updateStatus(V2RayStatus(state: actualState));
        
        _isRunning = actualState == V2RayConnectionState.connected;
        
        await _log.info('移动平台：V2Ray启动完成，状态: $actualState', tag: _logTag);
        return _isRunning;
      }
      
      // 桌面平台原有逻辑
      if (!await isPortAvailable(7898) || !await isPortAvailable(7899)) {
        await _log.error('端口 7898 或 7899 已被占用', tag: _logTag);
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        throw 'Port 7898 or 7899 is already in use';
      }

      // 只在桌面平台生成配置文件
      await generateConfig(serverIp: serverIp, serverPort: serverPort, serverName: serverName);

      final v2rayPath = await _getV2RayPath();
      if (!await File(v2rayPath).exists()) {
        await _log.error('$_v2rayExecutableName 未找到: $v2rayPath', tag: _logTag);
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        throw '$_v2rayExecutableName not found at: $v2rayPath';
      }

      await _log.info('启动V2Ray进程: $v2rayPath', tag: _logTag);
      
      final Map<String, String> environment = {};
      
      if (Platform.isAndroid) {
        final libDir = path.dirname(v2rayPath);
        environment['LD_LIBRARY_PATH'] = libDir;
      }
      
      _v2rayProcess = await Process.start(
        v2rayPath,
        ['run'],
        workingDirectory: path.dirname(v2rayPath),
        runInShell: true,
        environment: environment.isNotEmpty ? environment : null,
      );

      await Future.delayed(const Duration(seconds: 2));
      
      if (_v2rayProcess == null) {
        await _log.error('V2Ray进程启动失败', tag: _logTag);
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        throw 'Failed to start V2Ray process';
      }

      // 监听进程输出 - 优化日志
      bool hasStarted = false;
      _v2rayProcess!.stdout.transform(utf8.decoder).listen((data) {
        // 只记录重要信息
        if (data.toLowerCase().contains('started') || 
            data.toLowerCase().contains('listening')) {
          _log.info('V2Ray启动成功', tag: _logTag);
          hasStarted = true;
        } else if (data.toLowerCase().contains('failed') || 
                   data.toLowerCase().contains('error') ||
                   data.toLowerCase().contains('panic:')) {
          _isRunning = false;
          _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
          _log.error('V2Ray错误: $data', tag: _logTag);
        }
        // 忽略WebSocket警告和accepted连接日志
        else if (!data.toLowerCase().contains('websocket: close') &&
                 !data.toLowerCase().contains('accepted')) {
          // 其他可能重要的日志
          _log.debug('V2Ray: $data', tag: _logTag);
        }
      });

      _v2rayProcess!.stderr.transform(utf8.decoder).listen((data) {
        // 只记录非websocket相关的错误
        if (!data.toLowerCase().contains('websocket')) {
          _log.warn('V2Ray stderr: $data', tag: _logTag);
        }
      });

      // 监听进程退出
      _v2rayProcess!.exitCode.then((code) {
        _log.info('V2Ray进程退出，退出码: $code', tag: _logTag);
        _isRunning = false;
        _stopStatsTimer();
        _updateStatus(V2RayStatus(state: V2RayConnectionState.disconnected));
        if (_onProcessExit != null) {
          _onProcessExit!();
        }
      });

      // 等待并验证启动
      await Future.delayed(const Duration(seconds: 3));
      
      // 检查端口是否真的在监听
      if (await isPortListening(7898)) {
        _isRunning = true;
        _uploadTotal = 0;
        _downloadTotal = 0;
        _lastUpdateTime = 0;
        _lastUploadBytes = 0;
        _lastDownloadBytes = 0;
        
        _updateStatus(V2RayStatus(state: V2RayConnectionState.connected));
        _startStatsTimer();
        await _log.info('V2Ray服务启动成功，端口监听正常', tag: _logTag);
        return true;
      } else {
        await _log.error('V2Ray启动但端口未监听', tag: _logTag);
        _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
        await stop();
        throw 'V2Ray started but port not listening';
      }
      
    } catch (e, stackTrace) {
      await _log.error('启动V2Ray失败', tag: _logTag, error: e, stackTrace: stackTrace);
      _updateStatus(V2RayStatus(state: V2RayConnectionState.error));
      await stop();
      return false;
    } finally {
      _isStarting = false;
    }
  }

  static Future<void> stop() async {
    if (_isStopping) {
      await _log.warn('V2Ray正在停止中，忽略重复请求', tag: _logTag);
      return;
    }
    
    _isStopping = true;
    
    try {
      await _log.info('开始停止V2Ray服务', tag: _logTag);
      
      // 更新状态
      _updateStatus(V2RayStatus(state: V2RayConnectionState.disconnected));
      
      // 停止流量统计定时器
      _stopStatsTimer();
      
      // 取消状态订阅
      _statusSubscription?.cancel();
      _statusSubscription = null;
      
      // 重置标记
      _hasLoggedV2RayInfo = false;
      
      // 移动平台停止
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await _methodChannel.invokeMethod('stopV2Ray');
          _isRunning = false;
          await _log.info('移动平台：V2Ray已停止', tag: _logTag);
        } catch (e) {
          await _log.error('移动平台停止失败: $e', tag: _logTag);
        }
        return;
      }
      
      // 桌面平台停止进程
      if (_v2rayProcess != null) {
        try {
          _v2rayProcess!.kill(ProcessSignal.sigterm);
          
          bool processExited = false;
          for (int i = 0; i < 6; i++) {
            await Future.delayed(const Duration(milliseconds: 500));
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
              // 进程还在运行
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
          _isRunning = false;
        }
      }

      // 清理残留进程
      if (Platform.isWindows) {
        try {
          final result = await Process.run('taskkill', ['/F', '/IM', _v2rayExecutableName], 
            runInShell: true,
          );
          if (result.exitCode == 0) {
            await _log.info('成功清理残留的V2Ray进程', tag: _logTag);
          }
        } catch (e) {
          // 忽略错误
        }
      } else if (Platform.isLinux || Platform.isMacOS) {
        try {
          await Process.run('pkill', ['-f', _v2rayExecutableName], 
            runInShell: true,
          );
        } catch (e) {
          // 忽略错误
        }
      }
      
      await _log.info('V2Ray服务已停止', tag: _logTag);
    } finally {
      _isStopping = false;
    }
  }

  static bool get isRunning => _isRunning;
  
  static void _startStatsTimer() {
    _stopStatsTimer();
    
    if (Platform.isAndroid || Platform.isIOS) {
      _log.info('移动平台：流量统计通过EventChannel自动更新', tag: _logTag);
      return;
    }
    
    Future.delayed(const Duration(seconds: 5), () {
      if (_isRunning) {
        _log.info('开始流量统计监控', tag: _logTag);
        
        _updateTrafficStatsFromAPI();
        
        _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          if (_isRunning) {
            _updateTrafficStatsFromAPI();
          }
        });
      }
    });
  }
  
  static void _stopStatsTimer() {
    if (_statsTimer != null) {
      _statsTimer?.cancel();
      _statsTimer = null;
    }
  }
  
  static Future<void> _updateTrafficStatsFromAPI() async {
    if (!_isRunning) return;
    
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
          '--server=127.0.0.1:10085',
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
            // 只在失败时记录
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
        apiCmd = ['api', 'statsquery', '--server=127.0.0.1:10085'];
        
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
  
  // 记录上次的流量值，用于判断是否需要记录日志
  static int _lastLoggedUpload = -1;
  static int _lastLoggedDownload = -1;
  
  // 解析流量统计输出 - 只统计代理流量
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
  
  static Future<Map<String, int>> getTrafficStats() async {
    if (!_isRunning) {
      return {
        'uploadTotal': 0,
        'downloadTotal': 0,
      };
    }
    
    return {
      'uploadTotal': _uploadTotal,
      'downloadTotal': _downloadTotal,
    };
  }
  
  // 释放资源
  static void dispose() {
    if (!_statusController.isClosed) {
      _statusController.close();
    }
  }
}
