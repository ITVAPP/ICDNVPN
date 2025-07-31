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
      final List<dynamic> decoded = jsonDecode(serversJson);
      _servers = decoded.map((item) => ServerModel.fromJson(item)).toList();
      notifyListeners();
    } else {
      // 首次运行，自动从Cloudflare获取节点
      await _initializeWithCloudflareServers();
    }
  }

  // 自动初始化Cloudflare服务器
  Future<void> _initializeWithCloudflareServers() async {
    _isInitializing = true;
    _initMessage = '正在获取最优节点...';
    notifyListeners();

    try {
      // 使用优化的参数自动获取5个节点
      _initMessage = '正在测试节点延迟...';
      notifyListeners();
      
      final servers = await CloudflareTestService.testServers(
        count: 5,           // 获取5个节点
        maxLatency: 200,    // 降低延迟要求到200ms
        speed: 5,           // 提高速度要求到5MB/s
        testCount: 20,      // 减少测试数量，加快速度
        location: 'HKG',
      );

      if (servers.isNotEmpty) {
        // 为服务器生成友好的名称，创建新的ServerModel实例
        final namedServers = <ServerModel>[];
        int index = 1;
        for (var server in servers) {
          namedServers.add(ServerModel(
            id: server.id,
            name: 'CF节点 ${index.toString().padLeft(2, '0')}',
            location: server.location,
            ip: server.ip,
            port: server.port,
            ping: server.ping,
          ));
          index++;
        }
        
        _servers = namedServers;
        await _saveServers();
        _initMessage = '成功添加 ${namedServers.length} 个优质节点';
      } else {
        // 如果获取失败，添加备用服务器
        _servers = _getDefaultServers();
        await _saveServers();
        _initMessage = '使用默认节点';
      }
    } catch (e) {
      print('Failed to initialize Cloudflare servers: $e');
      // 出错时使用默认服务器
      _servers = _getDefaultServers();
      await _saveServers();
      _initMessage = '初始化失败，使用默认节点';
    } finally {
      // 延迟一下让用户看到结果
      await Future.delayed(const Duration(seconds: 1));
      _isInitializing = false;
      _initMessage = '';
      notifyListeners();
    }
  }

  // 获取默认服务器列表
  List<ServerModel> _getDefaultServers() {
    return [
      ServerModel(
        id: DateTime.now().millisecondsSinceEpoch.toString() + '1',
        name: '默认节点 01',
        location: '香港',
        ip: '104.19.45.12',  // 使用Cloudflare的公共IP段
        port: 443,
        ping: 80,
      ),
      ServerModel(
        id: DateTime.now().millisecondsSinceEpoch.toString() + '2',
        name: '默认节点 02',
        location: '香港',
        ip: '104.19.46.12',  // 使用Cloudflare的公共IP段
        port: 443,
        ping: 90,
      ),
    ];
  }

  Future<void> _saveServers() async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(_servers.map((s) => s.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  Future<void> addServer(ServerModel server) async {
    // 检查是否已存在相同IP的服务器
    final existingIndex = _servers.indexWhere((s) => s.ip == server.ip);
    if (existingIndex != -1) {
      // 如果已存在，更新延迟信息
      _servers[existingIndex].ping = server.ping;
    } else {
      _servers.add(server);
    }
    await _saveServers();
    notifyListeners();
  }

  // 批量添加服务器（带去重）
  Future<int> addServers(List<ServerModel> servers) async {
    int addedCount = 0;
    for (var server in servers) {
      final existingIndex = _servers.indexWhere((s) => s.ip == server.ip);
      if (existingIndex == -1) {
        _servers.add(server);
        addedCount++;
      } else {
        // 更新已存在服务器的延迟
        _servers[existingIndex].ping = server.ping;
      }
    }
    if (addedCount > 0 || servers.isNotEmpty) {
      await _saveServers();
      notifyListeners();
    }
    return addedCount;
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

  // 清空所有服务器并重新初始化
  Future<void> resetServers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    _servers.clear();
    notifyListeners();
    await _initializeWithCloudflareServers();
  }
}