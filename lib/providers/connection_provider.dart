import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_model.dart';
import '../services/v2ray_service.dart';
import '../services/proxy_service.dart';

class ConnectionProvider with ChangeNotifier {
  bool _isConnected = false;
  ServerModel? _currentServer;
  final String _storageKey = 'current_server';
  bool _autoConnect = false;
  bool _tunMode = false;
  bool get isConnected => _isConnected;
  ServerModel? get currentServer => _currentServer;
  bool get autoConnect => _autoConnect;
  bool get tunMode => _tunMode;
  
  ConnectionProvider() {
    // 设置V2Ray进程退出回调
    V2RayService.setOnProcessExit(_handleV2RayProcessExit);
    _loadSettings();
    _loadCurrentServer();
  }
  
  // 处理V2Ray进程意外退出
  void _handleV2RayProcessExit() {
    if (_isConnected) {
      print('V2Ray process exited unexpectedly, updating connection status...');
      _isConnected = false;
      // 清理系统代理设置
      if (!_tunMode) {
        ProxyService.disableSystemProxy().catchError((e) {
          print('Error disabling system proxy after process exit: $e');
        });
      }
      notifyListeners();
    }
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _autoConnect = prefs.getBool('auto_connect') ?? false;
    _tunMode = prefs.getBool('tun_mode') ?? false;
    if (_autoConnect) {
      connect();
    }
  }
  
  Future<void> setTunMode(bool value) async {
    if (_isConnected) {
      await disconnect();
    }
    _tunMode = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tun_mode', value);
    notifyListeners();
    if (_isConnected) {
      await connect();
    }
  }
  
  Future<void> setAutoConnect(bool value) async {
    _autoConnect = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_connect', value);
    notifyListeners();
  }
  
  Future<void> _loadCurrentServer() async {
    final prefs = await SharedPreferences.getInstance();
    final String? serverJson = prefs.getString(_storageKey);
    
    if (serverJson != null) {
      _currentServer = ServerModel.fromJson(Map<String, dynamic>.from(
        Map.castFrom(json.decode(serverJson))
      ));
      notifyListeners();
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
      print('使用用户选择的服务器: ${serverToConnect.name} (${serverToConnect.ping}ms)');
    } else if (availableServers.length == 1) {
      // 如果只有一个服务器，直接使用
      serverToConnect = availableServers.first;
      print('使用唯一可用服务器: ${serverToConnect.name} (${serverToConnect.ping}ms)');
    } else if (availableServers.length > 1) {
      // 如果有多个服务器，自动选择最优
      serverToConnect = _getBestServer(availableServers);
      if (serverToConnect != null) {
        print('自动选择最优服务器: ${serverToConnect.name} (${serverToConnect.ping}ms)');
        // 更新当前服务器显示，但不保存（临时选择）
        _currentServer = serverToConnect;
        notifyListeners();
      }
    }
    
    if (serverToConnect != null) {
      try {
        final success = await V2RayService.start(
          serverIp: serverToConnect.ip,
          serverPort: serverToConnect.port,
          tunMode: _tunMode,
        );

        if (success) {
          try {
            // 仅在非TUN模式下启用系统代理
            if (!_tunMode) {
              await ProxyService.enableSystemProxy();
            }
            _isConnected = true;
            notifyListeners();
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
        notifyListeners();
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
      // 仅在非TUN模式下禁用系统代理
      if (!_tunMode) {
        await ProxyService.disableSystemProxy();
      }
      _isConnected = false;
      notifyListeners();
    } catch (e) {
      print('Error during disconnect: $e');
      // 即使出错也要更新状态
      _isConnected = false;
      notifyListeners();
      rethrow;
    }
  }
  
  Future<void> setCurrentServer(ServerModel? server) async {
    _currentServer = server;
    await _saveCurrentServer();
    notifyListeners();
  }
}