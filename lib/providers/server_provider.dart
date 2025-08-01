import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_model.dart';
import '../services/cloudflare_test_service.dart';

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
        
        // 确保至少有5个节点
        if (_servers.length < 5) {
          print('当前有 ${_servers.length} 个服务器，需要补充到5个');
          await _ensureMinimumServers();
        } else {
          print('已加载 ${_servers.length} 个服务器');
        }
        
        notifyListeners();
      } catch (e) {
        print('加载服务器列表失败: $e');
        // 清空损坏的数据，重新初始化
        _servers.clear();
        await _initializeWithCloudflareServers();
      }
    } else {
      // 首次运行，自动获取节点
      print('首次运行，开始获取节点');
      await _initializeWithCloudflareServers();
    }
  }

  // 确保至少有5个服务器
  Future<void> _ensureMinimumServers() async {
    if (_servers.length >= 5) return;
    
    final needed = 5 - _servers.length;
    _isInitializing = true;
    _initMessage = '正在补充节点...';
    notifyListeners();
    
    try {
      // 从 Cloudflare 获取节点
      print('需要补充 $needed 个节点');
      List<ServerModel> newServers = [];
      
      try {
        newServers = await CloudflareTestService.testServers(
          count: needed,
          maxLatency: 300,
          speed: 1,
          testCount: 10,
          location: 'HK',
        );
      } catch (e) {
        print('从 Cloudflare 获取失败: $e');
        _initMessage = '补充节点失败';
        // 不再使用备用节点，直接失败
        throw e;
      }
      
      // 为新服务器生成正确的名称
      await _addServersWithProperNames(newServers);
      
      _initMessage = '成功补充 ${newServers.length} 个节点';
    } catch (e) {
      print('补充节点失败: $e');
      _initMessage = '补充节点失败';
    } finally {
      await Future.delayed(const Duration(seconds: 1));
      _isInitializing = false;
      _initMessage = '';
      notifyListeners();
    }
  }

  // 自动初始化 Cloudflare 服务器
  Future<void> _initializeWithCloudflareServers() async {
    _isInitializing = true;
    _initMessage = '正在获取最优节点...';
    notifyListeners();

    try {
      print('开始获取5个最优节点');
      
      List<ServerModel> servers = [];
      bool success = false;
      
      // 尝试3次，逐步降低要求
      for (int attempt = 0; attempt < 3 && !success; attempt++) {
        try {
          final maxLatency = 200 + (attempt * 100);
          final minSpeed = 5 - (attempt * 2);
          
          _initMessage = attempt == 0 
            ? '正在测试节点延迟...' 
            : '正在重试 (${attempt + 1}/3)...';
          notifyListeners();
          
          print('第 ${attempt + 1} 次尝试，参数: maxLatency=$maxLatency, speed=${minSpeed.clamp(1, 10)}');
          
          servers = await CloudflareTestService.testServers(
            count: 5,
            maxLatency: maxLatency,
            speed: minSpeed.clamp(1, 10),
            testCount: 20,
            location: 'HK',
          );
          
          if (servers.isNotEmpty) {
            success = true;
            print('成功获取 ${servers.length} 个节点');
          }
        } catch (e) {
          print('第 ${attempt + 1} 次尝试失败: $e');
          if (attempt < 2) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }
      
      // 如果都失败了，抛出异常
      if (!success || servers.isEmpty) {
        throw '无法获取有效节点，请检查网络连接';
      }
      
      // 为服务器生成友好的名称
      _servers = _generateNamedServers(servers);
      await _saveServers();
      
      _initMessage = '成功添加 ${_servers.length} 个节点';
      print('初始化完成，共 ${_servers.length} 个节点');
      
    } catch (e) {
      print('初始化失败: $e');
      _initMessage = '初始化失败: $e';
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
    
    for (int i = 0; i < servers.length; i++) {
      final server = servers[i];
      namedServers.add(ServerModel(
        id: server.id,
        name: 'CF节点 ${(i + 1).toString().padLeft(2, '0')}',
        location: server.location,
        ip: server.ip,
        port: server.port,
        ping: server.ping,
      ));
    }
    
    return namedServers;
  }

  // 添加服务器时生成正确的名称
  Future<void> _addServersWithProperNames(List<ServerModel> newServers) async {
    // 获取当前最大的CF节点编号
    int maxCfNumber = 0;
    for (final server in _servers) {
      if (server.name.startsWith('CF节点')) {
        final match = RegExp(r'CF节点\s*(\d+)').firstMatch(server.name);
        if (match != null) {
          final number = int.tryParse(match.group(1)!) ?? 0;
          if (number > maxCfNumber) {
            maxCfNumber = number;
          }
        }
      }
    }
    
    // 为新服务器生成名称
    for (int i = 0; i < newServers.length; i++) {
      final server = newServers[i];
      
      // 检查是否已存在相同IP
      final existingIndex = _servers.indexWhere((s) => s.ip == server.ip);
      if (existingIndex == -1) {
        maxCfNumber++;
        _servers.add(ServerModel(
          id: server.id,
          name: 'CF节点 ${maxCfNumber.toString().padLeft(2, '0')}',
          location: server.location,
          ip: server.ip,
          port: server.port,
          ping: server.ping,
        ));
      } else {
        // 更新已存在服务器的延迟
        _servers[existingIndex].ping = server.ping;
      }
    }
    
    await _saveServers();
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
        final maxNumber = _getMaxCfNumber();
        server = ServerModel(
          id: server.id,
          name: 'CF节点 ${(maxNumber + 1).toString().padLeft(2, '0')}',
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

  // 批量添加服务器
  Future<int> addServers(List<ServerModel> servers) async {
    int addedCount = 0;
    await _addServersWithProperNames(servers);
    notifyListeners();
    return addedCount;
  }

  // 获取当前最大的CF节点编号
  int _getMaxCfNumber() {
    int maxNumber = 0;
    for (final server in _servers) {
      if (server.name.startsWith('CF节点')) {
        final match = RegExp(r'CF节点\s*(\d+)').firstMatch(server.name);
        if (match != null) {
          final number = int.tryParse(match.group(1)!) ?? 0;
          if (number > maxNumber) {
            maxNumber = number;
          }
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
    
    // 删除后确保至少有5个节点
    if (_servers.length < 5) {
      await _ensureMinimumServers();
    } else {
      notifyListeners();
    }
  }

  Future<void> updatePing(String id, int ping) async {
    final index = _servers.indexWhere((s) => s.id == id);
    if (index != -1) {
      _servers[index].ping = ping;
      await _saveServers();
      notifyListeners();
    }
  }

  // 清空所有服务器并重新初始化
  Future<void> resetServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    _servers.clear();
    notifyListeners();
    await _initializeWithCloudflareServers();
  }
}