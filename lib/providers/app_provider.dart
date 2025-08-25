import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../models/server_model.dart';
import '../services/v2ray_service.dart';
import '../services/proxy_service.dart';
import '../services/cloudflare_test_service.dart';
import '../services/version_service.dart';
import '../utils/log_service.dart';
import '../app_config.dart';
import '../l10n/app_localizations.dart';

// ===== 连接状态管理 =====
class ConnectionProvider with ChangeNotifier {
  static const String _logTag = 'ConnectionProvider';
  static final LogService _log = LogService.instance;
  
  bool _isConnected = false;
  ServerModel? _currentServer;
  final String _storageKey = 'current_server';
  bool _autoConnect = false;
  bool _isDisposed = false;
  DateTime? _connectStartTime;
  String? _disconnectReason;
  bool _globalProxy = false;
  
  // 添加：应用白名单管理
  List<String> _allowedApps = [];
  
  Map<String, String>? _localizedStrings;
  BuildContext? _dialogContext;
  
  // 新增成员变量
  StreamSubscription<V2RayStatus>? _v2rayStatusSubscription;
  bool _isStopping = false;
  
  bool get isConnected => _isConnected;
  ServerModel? get currentServer => _currentServer;
  bool get autoConnect => _autoConnect;
  DateTime? get connectStartTime => _connectStartTime;
  String? get disconnectReason => _disconnectReason;
  bool get globalProxy => _globalProxy;
  bool _isUpdatingNotification = false;
  
  // 添加：getter for allowedApps
  List<String> get allowedApps => _allowedApps;
  
  ConnectionProvider() {
    V2RayService.setOnProcessExit(_handleV2RayProcessExit);
    
    // 只在移动端监听V2RayService状态流
    if (Platform.isAndroid || Platform.isIOS) {
      _v2rayStatusSubscription = V2RayService.statusStream.listen((status) {
        if (status.state == V2RayConnectionState.disconnected && 
            _isConnected && 
            !_isStopping) {
          _log.info('移动端：检测到VPN从通知栏断开', tag: _logTag);
          _isConnected = false;
          _connectStartTime = null;
          _disconnectReason = 'service_stopped';
          
          if (!_isDisposed) {
            notifyListeners();
          }
        }
      });
    }
    
    _loadSettings();
    _loadCurrentServer();
    _loadAllowedApps();  // 添加：加载应用白名单
  }
  
  @override
  void dispose() {
    _isDisposed = true;
    _v2rayStatusSubscription?.cancel();
    _v2rayStatusSubscription = null;
    
    if (_isConnected) {
      disconnect().catchError((e) {
        _log.error('dispose时断开连接失败', tag: _logTag, error: e);
      });
    }
    super.dispose();
  }
  
  // 新增：恢复移动端连接状态（不触发重连，只同步状态）
  Future<void> restoreMobileConnectionState(DateTime connectTime) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    _isConnected = true;
    _connectStartTime = connectTime;
    
    // 不需要调用connect()，因为VPN已经在运行
    // 只是恢复Dart端的状态显示
    
    if (!_isDisposed) {
      notifyListeners();
    }
    
    await _log.info('移动端连接状态已恢复，连接时间: $connectTime', tag: _logTag);
  }
  
  Future<void> updateLocalizedStrings(BuildContext context) async {
    if (_isUpdatingNotification) {
      await _log.debug('正在更新通知，跳过重复调用', tag: _logTag);
      return;
    }
    
    try {
      _isUpdatingNotification = true;
      
      setLocalizedStrings(context);
      
      if (_isConnected && (Platform.isAndroid || Platform.isIOS)) {
        if (_localizedStrings != null && _localizedStrings!.isNotEmpty) {
          await _log.info('语言切换，更新通知栏文字', tag: _logTag);
          await V2RayService.updateNotificationStrings(_localizedStrings!);
          await _log.info('通知栏文字更新完成', tag: _logTag);
        } else {
          await _log.warn('本地化字符串为空，跳过通知栏更新', tag: _logTag);
        }
      }
    } catch (e) {
      await _log.error('更新通知栏文字失败', tag: _logTag, error: e);
    } finally {
      _isUpdatingNotification = false;
    }
  }
  
  void setLocalizedStrings(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _localizedStrings = {
      'appName': AppConfig.appName,
      'notificationChannelName': l10n.notificationChannelName,
      'notificationChannelDesc': l10n.notificationChannelDesc,
      'globalProxyMode': l10n.globalProxyMode,
      'smartProxyMode': l10n.smartProxyMode,
      'proxyOnlyMode': l10n.proxyOnlyMode,
      'disconnectButtonName': l10n.disconnect,
      'trafficStatsFormat': l10n.trafficStats,
      'connecting': l10n.connecting, 
    };
  }
  
  void setDialogContext(BuildContext context) {
    _dialogContext = context;
  }
  
  void _handleV2RayProcessExit() {
    if (_isDisposed) return;
    
    if (_isConnected) {
      _log.warn('V2Ray process exited unexpectedly, updating connection status...', tag: _logTag);
      _isConnected = false;
      _connectStartTime = null;
      _disconnectReason = 'unexpected_exit';
      
      if (Platform.isWindows) {
        ProxyService.disableSystemProxy().catchError((e) {
          _log.error('Error disabling system proxy after process exit', tag: _logTag, error: e);
        });
      }
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }
  
  void clearDisconnectReason() {
    _disconnectReason = null;
    if (!_isDisposed) {
      notifyListeners();
    }
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _autoConnect = prefs.getBool('auto_connect') ?? false;
    _globalProxy = prefs.getBool('global_proxy') ?? false;
  }
  
  // 添加：加载已保存的应用白名单
  Future<void> _loadAllowedApps() async {
    try {
      final config = await V2RayService.loadProxyConfig();
      _allowedApps = config['allowedApps'] ?? [];
      await _log.info('加载应用白名单: ${_allowedApps.length}个应用', tag: _logTag);
    } catch (e) {
      await _log.error('加载应用白名单失败', tag: _logTag, error: e);
      _allowedApps = [];
    }
  }
  
  // 添加：设置应用白名单
  Future<void> setAllowedApps(List<String> apps) async {
    _allowedApps = apps;
    
    // 保存到原生端
    await V2RayService.saveProxyConfig(
      allowedApps: apps,
      bypassSubnets: [],  // 保持原有的子网配置
    );
    
    await _log.info('保存应用白名单: ${apps.length}个应用', tag: _logTag);
    
    if (!_isDisposed) {
      notifyListeners();
    }
  }
  
  Future<void> tryAutoConnect() async {
    if (_autoConnect && !_isDisposed && !_isConnected) {
      await _log.info('执行自动连接', tag: _logTag);
      final prefs = await SharedPreferences.getInstance();
      final String? serversJson = prefs.getString('servers');
      if (serversJson != null) {
        try {
          final List<dynamic> decoded = jsonDecode(serversJson);
          if (decoded.isNotEmpty) {
            await _connectWithoutDialog();
          } else {
            await _log.info('自动连接失败：没有可用的服务器', tag: _logTag);
          }
        } catch (e) {
          await _log.error('自动连接失败', tag: _logTag, error: e);
        }
      }
    }
  }
  
  Future<void> setAutoConnect(bool value) async {
    _autoConnect = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_connect', value);
    if (!_isDisposed) {
      notifyListeners();
    }
  }
  
  Future<void> setGlobalProxy(bool value) async {
    _globalProxy = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('global_proxy', value);
    if (!_isDisposed) {
      notifyListeners();
    }
  }
  
  Future<void> _loadCurrentServer() async {
    final prefs = await SharedPreferences.getInstance();
    final String? serverJson = prefs.getString(_storageKey);
    
    if (serverJson != null) {
      _currentServer = ServerModel.fromJson(Map<String, dynamic>.from(
        Map.castFrom(json.decode(serverJson))
      ));
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }
  
  Future<void> _saveCurrentServer() async {
    final prefs = await SharedPreferences.getInstance();
    if (_currentServer != null) {
      await prefs.setString(_storageKey, json.encode(_currentServer!.toJson()));
    } else {
      await prefs.remove(_storageKey);
    }
  }
  
  ServerModel? _getBestServer(List<ServerModel> servers) {
    if (servers.isEmpty) return null;
    
    final sortedServers = List<ServerModel>.from(servers)
      ..sort((a, b) => a.ping.compareTo(b.ping));
    
    final bestServer = sortedServers.first;
    
    if (bestServer.ping < AppConfig.autoSelectLatencyThreshold) {
      final threshold = bestServer.ping + AppConfig.autoSelectRangeThreshold;
      final goodServers = sortedServers
          .where((s) => s.ping <= threshold && s.ping < AppConfig.autoSelectLatencyThreshold)
          .toList();
      
      if (goodServers.isNotEmpty) {
        final random = math.Random();
        return goodServers[random.nextInt(goodServers.length)];
      }
    }
    
    return bestServer;
  }
  
  Future<void> _showRegistryErrorDialog(String error) async {
    if (!Platform.isWindows || _dialogContext == null) return;
    
    final l10n = AppLocalizations.of(_dialogContext!);
    
    await showDialog(
      context: _dialogContext!,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red),
            SizedBox(width: 8),
            Text(l10n.systemProxySettings),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.systemProxySettingsError(AppConfig.appName)),
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.3)),
              ),
              child: Text(
                error,
                style: TextStyle(fontSize: 12, color: Colors.red[700]),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }
  
  Future<void> _connectWithoutDialog() async {
    await _connectInternal();
  }
  
  Future<void> connect({bool? enableVirtualDns}) async {
    await _connectInternal(enableVirtualDns: enableVirtualDns);
  }
  
  Future<void> _connectInternal({bool? enableVirtualDns}) async {
    if (_isDisposed) return;
    
    _disconnectReason = null;
    
    if (_localizedStrings == null || _localizedStrings!.isEmpty) {
      _localizedStrings = {
        'appName': AppConfig.appName,
        'notificationChannelName': 'VPN Service',
        'notificationChannelDesc': 'VPN connection status',
        'globalProxyMode': 'Global Proxy',
        'smartProxyMode': 'Smart Proxy',
        'proxyOnlyMode': 'Proxy Only',
        'disconnectButtonName': 'Disconnect',
        'trafficStatsFormat': 'Traffic: ↑%upload ↓%download',
      };
      await _log.info('使用默认国际化文字（自动连接时可能还未设置）', tag: _logTag);
    }
    
    ServerModel? serverToConnect;
    
    final prefs = await SharedPreferences.getInstance();
    final String? serversJson = prefs.getString('servers');
    List<ServerModel> availableServers = [];
    
    if (serversJson != null) {
      final List<dynamic> decoded = jsonDecode(serversJson);
      availableServers = decoded.map((item) => ServerModel.fromJson(item)).toList();
    }
    
    if (_currentServer != null && availableServers.any((s) => s.id == _currentServer!.id)) {
      serverToConnect = _currentServer;
      await _log.info('使用用户选择的服务器: ${serverToConnect!.name} (${serverToConnect.ping}ms)', tag: _logTag);
    } else if (availableServers.length == 1) {
      serverToConnect = availableServers.first;
      await _log.info('使用唯一可用服务器: ${serverToConnect.name} (${serverToConnect.ping}ms)', tag: _logTag);
    } else if (availableServers.length > 1) {
      serverToConnect = _getBestServer(availableServers);
      if (serverToConnect != null) {
        await _log.info('自动选择最优服务器: ${serverToConnect!.name} (${serverToConnect.ping}ms)', tag: _logTag);
        _currentServer = serverToConnect;
        if (!_isDisposed) {
          notifyListeners();
        }
      }
    }
    
    if (serverToConnect != null) {
      try {
        if (Platform.isWindows) {
          await _log.info('Windows平台：先设置系统代理', tag: _logTag);
          try {
            await ProxyService.enableSystemProxy();
            await _log.info('系统代理设置成功', tag: _logTag);
          } catch (e) {
            await _log.error('系统代理设置失败，中止连接', tag: _logTag, error: e);
            
            if (_dialogContext != null) {
              await _showRegistryErrorDialog(e.toString());
            }
            
            _isConnected = false;
            _connectStartTime = null;
            if (!_isDisposed) {
              notifyListeners();
            }
            
            return;
          }
        }
        
        bool v2rayStarted = false;
        try {
          // 记录应用白名单状态
          if (_allowedApps.isNotEmpty) {
            await _log.info('启用应用白名单模式: ${_allowedApps.length}个应用', tag: _logTag);
          } else {
            await _log.info('未启用应用白名单，所有应用使用VPN', tag: _logTag);
          }
          
          await _log.info('开始启动V2Ray服务', tag: _logTag);
          v2rayStarted = await V2RayService.start(
            serverIp: serverToConnect.ip,
            serverPort: serverToConnect.port,
            globalProxy: _globalProxy,
            localizedStrings: _localizedStrings,
            enableVirtualDns: enableVirtualDns ?? AppConfig.enableVirtualDns,
            allowedApps: _allowedApps.isEmpty ? null : _allowedApps,  // 修改：传递应用白名单
          );

          if (v2rayStarted) {
            _isConnected = true;
            _connectStartTime = DateTime.now();
            if (!_isDisposed) {
              notifyListeners();
            }
            await _log.info('连接成功建立', tag: _logTag);
          } else {
            throw Exception('Failed to start V2Ray service');
          }
          
        } catch (e) {
          await _log.error('V2Ray启动失败', tag: _logTag, error: e);
          
          if (Platform.isWindows) {
            await _log.info('回滚系统代理设置', tag: _logTag);
            try {
              await ProxyService.disableSystemProxy();
            } catch (rollbackError) {
              await _log.error('回滚系统代理失败', tag: _logTag, error: rollbackError);
            }
          }
          
          _isConnected = false;
          _connectStartTime = null;
          if (!_isDisposed) {
            notifyListeners();
          }
          
          throw e;
        }
        
      } catch (e) {
        await _log.error('Connection failed', tag: _logTag, error: e);
        _isConnected = false;
        _connectStartTime = null;
        if (!_isDisposed) {
          notifyListeners();
        }
        rethrow;
      }
    } else {
      await _log.error('没有可用的服务器', tag: _logTag);
      throw Exception('No available server');
    }
  }
  
  Future<void> disconnect() async {
    _isStopping = true;
    try {
      await V2RayService.stop();
      
      if (Platform.isWindows) {
        await _log.info('Windows平台：禁用系统代理', tag: _logTag);
        await ProxyService.disableSystemProxy();
      } else {
        await _log.info('非Windows平台：跳过系统代理禁用', tag: _logTag);
      }
      
      _isConnected = false;
      _connectStartTime = null;
      _disconnectReason = null;
      if (!_isDisposed) {
        notifyListeners();
      }
    } catch (e) {
      await _log.error('Error during disconnect', tag: _logTag, error: e);
      _isConnected = false;
      _connectStartTime = null;
      if (!_isDisposed) {
        notifyListeners();
      }
      rethrow;
    } finally {
      _isStopping = false;
    }
  }
  
  Future<void> setCurrentServer(ServerModel? server) async {
    _currentServer = server;
    await _saveCurrentServer();
    if (!_isDisposed) {
      notifyListeners();
    }
  }
}

// ===== 服务器管理 =====
class ServerProvider with ChangeNotifier {
  static const String _logTag = 'ServerProvider';
  static final LogService _log = LogService.instance;
  
  List<ServerModel> _servers = [];
  final String _storageKey = 'servers';
  bool _isInitializing = false;
  bool _isRefreshing = false;
  String _initMessage = '';
  String _initDetail = '';
  double _progress = 0.0;
  
  ConnectionProvider? _connectionProvider;
  
  List<ServerModel> get servers => _servers;
  bool get isInitializing => _isInitializing;
  bool get isRefreshing => _isRefreshing;
  String get initMessage => _initMessage;
  String get initDetail => _initDetail;
  double get progress => _progress;

  ServerProvider() {
    _loadServers();
  }
  
  void setConnectionProvider(ConnectionProvider provider) {
    _connectionProvider = provider;
  }

  Future<void> _loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    final String? serversJson = prefs.getString(_storageKey);
    
    if (serversJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(serversJson);
        _servers = decoded.map((item) => ServerModel.fromJson(item)).toList();
        
        if (_servers.isEmpty) {
          await _log.info('服务器列表为空，自动获取节点', tag: _logTag);
          await refreshFromCloudflare();
        } else {
          await _log.info('已加载 ${_servers.length} 个服务器', tag: _logTag);
          _tryAutoConnect();
        }
        
        notifyListeners();
      } catch (e) {
        await _log.error('加载服务器列表失败', tag: _logTag, error: e);
        _servers.clear();
        await refreshFromCloudflare();
      }
    } else {
      await _log.info('首次运行，开始获取节点', tag: _logTag);
      await refreshFromCloudflare();
    }
  }
  
  void _tryAutoConnect() {
    if (_connectionProvider != null && _servers.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 500), () {
        _connectionProvider?.tryAutoConnect();
      });
    }
  }

  Future<void> refreshFromCloudflare() async {
    if (_isRefreshing) {
      await _log.warn('已经在获取节点中，忽略重复调用', tag: _logTag);
      return;
    }
    
    _isRefreshing = true;
    _isInitializing = true;
    _initMessage = 'gettingBestNodes';
    _initDetail = 'preparingTestEnvironment';
    _progress = 0.0;
    
    _servers.clear();
    await _saveServers();
    notifyListeners();

    try {
      await _log.info('开始从Cloudflare获取节点', tag: _logTag);
      
      final controller = StreamController<TestProgress>();
      
      final completer = Completer<List<ServerModel>>();
      final subscription = controller.stream.listen(
        (progress) {
          if (!progress.hasError) {
            _initMessage = progress.messageKey;
            _initDetail = progress.detailKey ?? '';
            _progress = progress.progress;
            notifyListeners();
          }
          
          if (progress.isCompleted && progress.servers != null) {
            completer.complete(progress.servers);
          } else if (progress.hasError) {
            completer.completeError(progress.error);
          }
        },
        onError: (error) {
          completer.completeError(error);
        },
      );
      
      CloudflareTestService.executeTestWithProgress(
        controller: controller,
        count: AppConfig.defaultTestNodeCount,
        maxLatency: AppConfig.defaultMaxLatency,
        testCount: AppConfig.defaultSampleCount,
        location: 'AUTO',
        useHttping: false,
      );
      
      final servers = await completer.future;
      await subscription.cancel();
      
      if (servers.isEmpty) {
        throw 'noValidNodes';
      }
      
      _servers = _generateNamedServers(servers);
      await _saveServers();
      
      _initMessage = '';
      _progress = 1.0;
      await _log.info('成功获取 ${_servers.length} 个节点', tag: _logTag);
      
      _tryAutoConnect();
      
    } catch (e) {
      await _log.error('获取节点失败', tag: _logTag, error: e);
      _initMessage = 'failed';
      _progress = 0.0;
      _servers.clear();
      await _saveServers();
    } finally {
      await Future.delayed(const Duration(seconds: 1));
      _isInitializing = false;
      _isRefreshing = false;
      if (_servers.isNotEmpty) {
        _initMessage = '';
      }
      _initDetail = '';
      _progress = 0.0;
      notifyListeners();
    }
  }

  List<ServerModel> _generateNamedServers(List<ServerModel> servers) {
    final namedServers = <ServerModel>[];
    final countryCountMap = <String, int>{};
    
    for (final server in servers) {
      final countryCode = server.location.toUpperCase();
      final currentCount = countryCountMap[countryCode] ?? 0;
      countryCountMap[countryCode] = currentCount + 1;
      
      final name = '$countryCode${(currentCount + 1).toString().padLeft(2, '0')}';
      
      namedServers.add(ServerModel(
        id: server.id,
        name: name,
        location: server.location,
        ip: server.ip,
        port: server.port,
        ping: server.ping,
      ));
    }
    
    return namedServers;
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_servers.map((s) => s.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  Future<void> clearAllServers() async {
    _servers.clear();
    await _saveServers();
    notifyListeners();
  }

  Future<void> addServer(ServerModel server) async {
    final existingIndex = _servers.indexWhere((s) => s.ip == server.ip);
    if (existingIndex != -1) {
      _servers[existingIndex].ping = server.ping;
    } else {
      if (server.name == server.ip || server.name.isEmpty) {
        final countryCode = server.location.toUpperCase();
        final maxNumber = _getMaxNumberForCountry(countryCode);
        server = ServerModel(
          id: server.id,
          name: '$countryCode${(maxNumber + 1).toString().padLeft(2, '0')}',
          location: server.location,
          ip: server.ip,
          port: server.port,
          ping: server.ping,
        );
      }
      _servers.add(server);
    }
    
    await _saveServers();
    notifyListeners();
  }

  int _getMaxNumberForCountry(String countryCode) {
    int maxNumber = 0;
    for (final server in _servers) {
      final match = RegExp(r'^([A-Z]{2})(\d+)').firstMatch(server.name);
      if (match != null && match.group(1) == countryCode) {
        final number = int.parse(match.group(2)!);
        if (number > maxNumber) {
          maxNumber = number;
        }
      }
    }
    return maxNumber;
  }

  Future<void> updateServer(ServerModel server) async {
    final index = _servers.indexWhere((s) => s.id == server.id);
    if (index != -1) {
      _servers[index] = server;
      await _saveServers();
      notifyListeners();
    }
  }

  Future<void> deleteServer(String id) async {
    _servers.removeWhere((s) => s.id == id);
    await _saveServers();
    notifyListeners();
  }

  Future<void> updatePing(String id, int ping) async {
    final index = _servers.indexWhere((s) => s.id == id);
    if (index != -1) {
      _servers[index].ping = ping;
      await _saveServers();
      notifyListeners();
    }
  }
}

// ===== 主题管理 =====
class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'theme_mode';
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  ThemeProvider() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeIndex = prefs.getInt(_themeKey) ?? ThemeMode.system.index;
    _themeMode = ThemeMode.values[themeModeIndex];
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeKey, mode.index);
    notifyListeners();
  }
}

// ===== 语言管理 =====
class LocaleProvider extends ChangeNotifier {
  static const String _localeKey = 'app_locale';
  static const String _isUserSetKey = 'is_user_set_locale';
  Locale? _locale;
  
  Locale? get locale => _locale;
  
  LocaleProvider() {
    _loadLocale();
  }
  
  Future<void> _loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final isUserSet = prefs.getBool(_isUserSetKey) ?? false;
    final localeCode = prefs.getString(_localeKey);
    
    if (localeCode != null) {
      final parts = localeCode.split('_');
      if (parts.length == 2) {
        _locale = Locale(parts[0], parts[1]);
      } else {
        _locale = Locale(localeCode);
      }
    } else if (!isUserSet) {
      _locale = _detectSystemLocale();
      
      if (_locale != null) {
        final code = _locale!.countryCode != null 
            ? '${_locale!.languageCode}_${_locale!.countryCode}'
            : _locale!.languageCode;
        await prefs.setString(_localeKey, code);
      }
    } else {
      _locale = const Locale('zh', 'CN');
    }
    
    notifyListeners();
  }
  
  Locale? _detectSystemLocale() {
    final systemLocales = WidgetsBinding.instance.platformDispatcher.locales;
    if (systemLocales.isEmpty) return const Locale('zh', 'CN');
    
    final systemLocale = systemLocales.first;
    
    const supportedLocales = [
      Locale('zh', 'CN'),
      Locale('en', 'US'),
      Locale('zh', 'TW'),
      Locale('es', 'ES'),
      Locale('ru', 'RU'),
      Locale('ar', 'SA'),
    ];
    
    for (final supported in supportedLocales) {
      if (supported.languageCode == systemLocale.languageCode &&
          supported.countryCode == systemLocale.countryCode) {
        return supported;
      }
    }
    
    for (final supported in supportedLocales) {
      if (supported.languageCode == systemLocale.languageCode) {
        return supported;
      }
    }
    
    if (systemLocale.languageCode == 'zh') {
      if (['HK', 'MO', 'TW'].contains(systemLocale.countryCode)) {
        return const Locale('zh', 'TW');
      }
      return const Locale('zh', 'CN');
    }
    
    return const Locale('zh', 'CN');
  }
  
  Future<void> setLocale(Locale locale) async {
    _locale = locale;
    
    final prefs = await SharedPreferences.getInstance();
    final localeCode = locale.countryCode != null 
        ? '${locale.languageCode}_${locale.countryCode}'
        : locale.languageCode;
    
    await prefs.setString(_localeKey, localeCode);
    await prefs.setBool(_isUserSetKey, true);
    notifyListeners();
  }
  
  void clearLocale() async {
    _locale = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localeKey);
    await prefs.remove(_isUserSetKey);
    notifyListeners();
  }
}

// ===== APK下载管理 =====
class DownloadProvider extends ChangeNotifier {
  double _progress = 0.0;
  bool _isDownloading = false;
  String? _error;
  String? _downloadedFilePath;
  
  double get progress => _progress;
  bool get isDownloading => _isDownloading;
  String? get error => _error;
  
  Future<String?> downloadApk(String url) async {
    if (_isDownloading) return null;
    
    _isDownloading = true;
    _progress = 0.0;
    _error = null;
    notifyListeners();
    
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);
      
      if (response.statusCode != 200) {
        throw Exception('下载失败: ${response.statusCode}');
      }
      
      final contentLength = response.contentLength ?? 0;
      
      Directory saveDir;
      String fileName = 'update.apk';
      
      if (Platform.isAndroid) {
        try {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            saveDir = Directory('${externalDir.path}/Download');
            if (!await saveDir.exists()) {
              await saveDir.create(recursive: true);
            }
          } else {
            saveDir = await getApplicationDocumentsDirectory();
          }
        } catch (e) {
          saveDir = await getTemporaryDirectory();
        }
        
        fileName = 'cfvpn_update_${DateTime.now().millisecondsSinceEpoch}.apk';
      } else {
        saveDir = await getApplicationDocumentsDirectory();
      }
      
      final file = File('${saveDir.path}/$fileName');
      
      final sink = file.openWrite();
      int received = 0;
      
      await response.stream.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        
        if (contentLength > 0) {
          _progress = received / contentLength;
          notifyListeners();
        }
      });
      
      await sink.close();
      client.close();
      
      _downloadedFilePath = file.path;
      
      _isDownloading = false;
      _progress = 1.0;
      notifyListeners();
      
      if (Platform.isAndroid) {
        try {
          await Process.run('chmod', ['644', file.path]);
        } catch (e) {
          // 忽略权限设置失败
        }
      }
      
      return file.path;
    } catch (e) {
      _error = e.toString();
      _isDownloading = false;
      _progress = 0.0;
      notifyListeners();
      return null;
    }
  }
  
  Future<void> cleanupDownloadedFile() async {
    if (_downloadedFilePath != null) {
      try {
        final file = File(_downloadedFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        // 忽略删除失败
      }
      _downloadedFilePath = null;
    }
  }
}
