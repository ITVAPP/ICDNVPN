import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_model.dart';
import '../services/v2ray_service.dart';
import '../services/proxy_service.dart';
import '../services/cloudflare_test_service.dart';

// ===== 连接状态管理（原 connection_provider.dart） =====
class ConnectionProvider with ChangeNotifier {
  bool _isConnected = false;
  ServerModel? _currentServer;
  final String _storageKey = 'current_server';
  bool _autoConnect = false;
  bool _isDisposed = false;
  
  bool get isConnected => _isConnected;
  ServerModel? get currentServer => _currentServer;
  bool get autoConnect => _autoConnect;
  
  ConnectionProvider() {
    // 设置V2Ray进程退出回调
    V2RayService.setOnProcessExit(_handleV2RayProcessExit);
    _loadSettings();
    _loadCurrentServer();
  }
  
  @override
  void dispose() {
    _isDisposed = true;
    // 如果还在连接状态，断开连接
    if (_isConnected) {
      disconnect().catchError((e) {
        print('dispose时断开连接失败: $e');
      });
    }
    super.dispose();
  }
  
  // 处理V2Ray进程意外退出
  void _handleV2RayProcessExit() {
    if (_isDisposed) return;
    
    if (_isConnected) {
      print('V2Ray process exited unexpectedly, updating connection status...');
      _isConnected = false;
      // 清理系统代理设置
      ProxyService.disableSystemProxy().catchError((e) {
        print('Error disabling system proxy after process exit: $e');
      });
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _autoConnect = prefs.getBool('auto_connect') ?? false;
    if (_autoConnect && !_isDisposed) {
      connect();
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
  
  // 获取最优服务器
  ServerModel? _getBestServer(List<ServerModel> servers) {
    if (servers.isEmpty) return null;
    
    // 按延迟排序
    final sortedServers = List<ServerModel>.from(servers)
      ..sort((a, b) => a.ping.compareTo(b.ping));
    
    // 获取延迟最低的服务器
    final bestServer = sortedServers.first;
    
    // 如果最优服务器延迟小于200ms，从延迟相近的服务器中随机选择
    if (bestServer.ping < 200) {
      // 找出所有延迟在最优服务器+30ms以内的服务器
      final threshold = bestServer.ping + 30;
      final goodServers = sortedServers
          .where((s) => s.ping <= threshold && s.ping < 200)
          .toList();
      
      // 从优质服务器中随机选择
      if (goodServers.isNotEmpty) {
        final random = Random();
        return goodServers[random.nextInt(goodServers.length)];
      }
    }
    
    // 如果没有优质服务器，返回延迟最低的
    return bestServer;
  }
  
  Future<void> connect() async {
    if (_isDisposed) return;
    
    ServerModel? serverToConnect;
    
    // 获取所有可用服务器
    final prefs = await SharedPreferences.getInstance();
    final String? serversJson = prefs.getString('servers');
    List<ServerModel> availableServers = [];
    
    if (serversJson != null) {
      final List<dynamic> decoded = jsonDecode(serversJson);
      availableServers = decoded.map((item) => ServerModel.fromJson(item)).toList();
    }
    
    // 决定使用哪个服务器
    if (_currentServer != null && availableServers.any((s) => s.id == _currentServer!.id)) {
      // 如果用户手动选择了服务器，且该服务器仍然存在，优先使用
      serverToConnect = _currentServer;
      print('使用用户选择的服务器: ${serverToConnect!.name} (${serverToConnect.ping}ms)');
    } else if (availableServers.length == 1) {
      // 如果只有一个服务器，直接使用
      serverToConnect = availableServers.first;
      print('使用唯一可用服务器: ${serverToConnect.name} (${serverToConnect.ping}ms)');
    } else if (availableServers.length > 1) {
      // 如果有多个服务器，自动选择最优
      serverToConnect = _getBestServer(availableServers);
      if (serverToConnect != null) {
        print('自动选择最优服务器: ${serverToConnect!.name} (${serverToConnect.ping}ms)');
        // 更新当前服务器显示，但不保存（临时选择）
        _currentServer = serverToConnect;
        if (!_isDisposed) {
          notifyListeners();
        }
      }
    }
    
    if (serverToConnect != null) {
      try {
        final success = await V2RayService.start(
          serverIp: serverToConnect.ip,
          serverPort: serverToConnect.port,
        );

        if (success) {
          try {
            // 启用系统代理
            await ProxyService.enableSystemProxy();
            _isConnected = true;
            if (!_isDisposed) {
              notifyListeners();
            }
          } catch (e) {
            // 如果系统代理设置失败，停止V2Ray
            await V2RayService.stop();
            rethrow;
          }
        } else {
          throw Exception('Failed to start V2Ray service');
        }
      } catch (e) {
        print('Connection failed: $e');
        // 确保状态一致性
        _isConnected = false;
        if (!_isDisposed) {
          notifyListeners();
        }
        rethrow;
      }
    } else {
      print('没有可用的服务器');
      throw Exception('No available server');
    }
  }
  
  Future<void> disconnect() async {
    try {
      await V2RayService.stop();
      // 禁用系统代理
      await ProxyService.disableSystemProxy();
      _isConnected = false;
      if (!_isDisposed) {
        notifyListeners();
      }
    } catch (e) {
      print('Error during disconnect: $e');
      // 即使出错也要更新状态
      _isConnected = false;
      if (!_isDisposed) {
        notifyListeners();
      }
      rethrow;
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

// ===== 服务器管理（原 server_provider.dart） =====
class ServerProvider with ChangeNotifier {
  List<ServerModel> _servers = [];
  final String _storageKey = 'servers';
  bool _isInitializing = false;
  String _initMessage = '';
  
  List<ServerModel> get servers => _servers;
  bool get isInitializing => _isInitializing;
  String get initMessage => _initMessage;

  ServerProvider() {
    _loadServers();
  }

  Future<void> _loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    final String? serversJson = prefs.getString(_storageKey);
    
    if (serversJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(serversJson);
        _servers = decoded.map((item) => ServerModel.fromJson(item)).toList();
        
        // 如果没有服务器，自动获取
        if (_servers.isEmpty) {
          print('服务器列表为空，自动获取节点');
          await refreshFromCloudflare();
        } else {
          print('已加载 ${_servers.length} 个服务器');
        }
        
        notifyListeners();
      } catch (e) {
        print('加载服务器列表失败: $e');
        // 清空损坏的数据，重新初始化
        _servers.clear();
        await refreshFromCloudflare();
      }
    } else {
      // 首次运行，自动获取节点
      print('首次运行，开始获取节点');
      await refreshFromCloudflare();
    }
  }

  // 统一的从Cloudflare刷新服务器的方法 - 修改为使用新的公共方法
  Future<void> refreshFromCloudflare() async {
    _isInitializing = true;
    _initMessage = '正在获取最优节点...';
    notifyListeners();

    try {
      print('开始从Cloudflare获取节点');
      
      _initMessage = '正在测试节点延迟...';
      notifyListeners();
      
      // 创建 StreamController
      final controller = StreamController<TestProgress>();
      
      // 使用公共的 executeTestWithProgress 方法
      final completer = Completer<List<ServerModel>>();
      final subscription = controller.stream.listen(
        (progress) {
          // 更新进度消息
          if (!progress.hasError) {
            _initMessage = progress.message;
            notifyListeners();
          }
          
          // 如果完成，返回结果
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
      
      // 调用公共方法
      CloudflareTestService.executeTestWithProgress(
        controller: controller,
        count: 6,
        maxLatency: 200,
        speed: 5,
        testCount: 500,
        location: 'AUTO',
        useHttping: false,
      );
      
      // 等待结果
      final servers = await completer.future;
      await subscription.cancel();
      
      if (servers.isEmpty) {
        throw '无法获取有效节点，请检查网络连接';
      }
      
      // 直接替换服务器列表（不是追加）
      _servers = _generateNamedServers(servers);
      await _saveServers();
      
      _initMessage = '成功获取 ${_servers.length} 个节点';
      print('成功获取 ${_servers.length} 个节点');
      
    } catch (e) {
      print('获取节点失败: $e');
      _initMessage = '获取节点失败: $e';
      // 清空服务器列表
      _servers.clear();
      await _saveServers();
    } finally {
      await Future.delayed(const Duration(seconds: 1));
      _isInitializing = false;
      _initMessage = '';
      notifyListeners();
    }
  }

  // 生成带有正确名称的服务器列表
  List<ServerModel> _generateNamedServers(List<ServerModel> servers) {
    final namedServers = <ServerModel>[];
    
    // 按国家分组计数
    final countryCountMap = <String, int>{};
    
    for (final server in servers) {
      final countryCode = server.location.toUpperCase();
      
      // 获取该国家的当前计数
      final currentCount = countryCountMap[countryCode] ?? 0;
      countryCountMap[countryCode] = currentCount + 1;
      
      // 生成名称，格式：国家代码+编号，如 US01, HK02
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

  // 添加单个服务器
  Future<void> addServer(ServerModel server) async {
    // 检查是否已存在相同IP的服务器
    final existingIndex = _servers.indexWhere((s) => s.ip == server.ip);
    if (existingIndex != -1) {
      // 更新延迟信息
      _servers[existingIndex].ping = server.ping;
    } else {
      // 生成正确的名称
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

  // 获取特定国家的最大编号
  int _getMaxNumberForCountry(String countryCode) {
    int maxNumber = 0;
    for (final server in _servers) {
      final match = RegExp(r'^([A-Z]{2})(\d+)$').firstMatch(server.name);
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

// ===== 主题管理（原 theme_provider.dart） =====
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

// ===== 语言管理（原 locale_provider.dart） =====
class LocaleProvider extends ChangeNotifier {
  static const String _localeKey = 'app_locale';
  Locale? _locale;
  
  Locale? get locale => _locale;
  
  LocaleProvider() {
    _loadLocale();
  }
  
  Future<void> _loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final localeCode = prefs.getString(_localeKey);
    
    if (localeCode != null) {
      final parts = localeCode.split('_');
      if (parts.length == 2) {
        _locale = Locale(parts[0], parts[1]);
      } else {
        _locale = Locale(localeCode);
      }
    } else {
      // 如果没有保存的语言偏好，默认使用中文
      _locale = const Locale('zh', 'CN');
      // 保存默认选择
      await prefs.setString(_localeKey, 'zh_CN');
    }
    notifyListeners();
  }
  
  Future<void> setLocale(Locale locale) async {
    _locale = locale;
    
    final prefs = await SharedPreferences.getInstance();
    final localeCode = locale.countryCode != null 
        ? '${locale.languageCode}_${locale.countryCode}'
        : locale.languageCode;
    
    await prefs.setString(_localeKey, localeCode);
    notifyListeners();
  }
  
  void clearLocale() async {
    _locale = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localeKey);
    notifyListeners();
  }
}