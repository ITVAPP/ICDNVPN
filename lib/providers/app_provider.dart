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
import '../services/version_service.dart';  // 导入版本服务，使用其中的VersionInfo类
import '../utils/log_service.dart';  // 导入日志服务
import '../app_config.dart';

// ===== 连接状态管理（原 connection_provider.dart） =====
class ConnectionProvider with ChangeNotifier {
  static const String _logTag = 'ConnectionProvider';  // 日志标签
  static final LogService _log = LogService.instance;  // 日志服务实例
  
  bool _isConnected = false;
  ServerModel? _currentServer;
  final String _storageKey = 'current_server';
  bool _autoConnect = false;
  bool _isDisposed = false;
  DateTime? _connectStartTime; // 添加连接开始时间
  String? _disconnectReason; // 添加断开原因
  
  bool get isConnected => _isConnected;
  ServerModel? get currentServer => _currentServer;
  bool get autoConnect => _autoConnect;
  DateTime? get connectStartTime => _connectStartTime; // 添加getter
  String? get disconnectReason => _disconnectReason; // 添加getter
  
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
        _log.error('dispose时断开连接失败', tag: _logTag, error: e);
      });
    }
    super.dispose();
  }
  
  // 处理V2Ray进程意外退出
  void _handleV2RayProcessExit() {
    if (_isDisposed) return;
    
    if (_isConnected) {
      _log.warn('V2Ray process exited unexpectedly, updating connection status...', tag: _logTag);
      _isConnected = false;
      _connectStartTime = null; // 清除连接时间
      _disconnectReason = 'unexpected_exit'; // 设置断开原因
      // 清理系统代理设置
      ProxyService.disableSystemProxy().catchError((e) {
        _log.error('Error disabling system proxy after process exit', tag: _logTag, error: e);
      });
      if (!_isDisposed) {
        notifyListeners();
      }
    }
  }
  
  // 清除断开原因
  void clearDisconnectReason() {
    _disconnectReason = null;
    if (!_isDisposed) {
      notifyListeners();
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
  
  // 获取最优服务器 - 使用AppConfig
  ServerModel? _getBestServer(List<ServerModel> servers) {
    if (servers.isEmpty) return null;
    
    // 按延迟排序
    final sortedServers = List<ServerModel>.from(servers)
      ..sort((a, b) => a.ping.compareTo(b.ping));
    
    // 获取延迟最低的服务器
    final bestServer = sortedServers.first;
    
    // 如果最优服务器延迟小于阈值，从延迟相近的服务器中随机选择 - 使用AppConfig
    if (bestServer.ping < AppConfig.autoSelectLatencyThreshold) {
      // 找出所有延迟在最优服务器+范围以内的服务器 - 使用AppConfig
      final threshold = bestServer.ping + AppConfig.autoSelectRangeThreshold;
      final goodServers = sortedServers
          .where((s) => s.ping <= threshold && s.ping < AppConfig.autoSelectLatencyThreshold)
          .toList();
      
      // 从优质服务器中随机选择
      if (goodServers.isNotEmpty) {
        final random = math.Random();
        return goodServers[random.nextInt(goodServers.length)];
      }
    }
    
    // 如果没有优质服务器，返回延迟最低的
    return bestServer;
  }
  
  Future<void> connect() async {
    if (_isDisposed) return;
    
    // 清除之前的断开原因
    _disconnectReason = null;
    
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
      await _log.info('使用用户选择的服务器: ${serverToConnect!.name} (${serverToConnect.ping}ms)', tag: _logTag);
    } else if (availableServers.length == 1) {
      // 如果只有一个服务器，直接使用
      serverToConnect = availableServers.first;
      await _log.info('使用唯一可用服务器: ${serverToConnect.name} (${serverToConnect.ping}ms)', tag: _logTag);
    } else if (availableServers.length > 1) {
      // 如果有多个服务器，自动选择最优
      serverToConnect = _getBestServer(availableServers);
      if (serverToConnect != null) {
        await _log.info('自动选择最优服务器: ${serverToConnect!.name} (${serverToConnect.ping}ms)', tag: _logTag);
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
            _connectStartTime = DateTime.now(); // 记录连接开始时间
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
        await _log.error('Connection failed', tag: _logTag, error: e);
        // 确保状态一致性
        _isConnected = false;
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
    try {
      await V2RayService.stop();
      // 禁用系统代理
      await ProxyService.disableSystemProxy();
      _isConnected = false;
      _connectStartTime = null; // 清除连接时间
      _disconnectReason = null; // 主动断开不设置原因
      if (!_isDisposed) {
        notifyListeners();
      }
    } catch (e) {
      await _log.error('Error during disconnect', tag: _logTag, error: e);
      // 即使出错也要更新状态
      _isConnected = false;
      _connectStartTime = null; // 清除连接时间
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
  static const String _logTag = 'ServerProvider';  // 日志标签
  static final LogService _log = LogService.instance;  // 日志服务实例
  
  List<ServerModel> _servers = [];
  final String _storageKey = 'servers';
  bool _isInitializing = false;
  bool _isRefreshing = false; // 添加刷新标志
  String _initMessage = '';
  String _initDetail = ''; // 新增详情字段
  double _progress = 0.0; // 新增进度字段
  
  List<ServerModel> get servers => _servers;
  bool get isInitializing => _isInitializing;
  String get initMessage => _initMessage;
  String get initDetail => _initDetail; // 新增getter
  double get progress => _progress; // 新增getter

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
          await _log.info('服务器列表为空，自动获取节点', tag: _logTag);
          // 不要在这里设置 _isInitializing，让 refreshFromCloudflare 自己管理
          await refreshFromCloudflare();
        } else {
          await _log.info('已加载 ${_servers.length} 个服务器', tag: _logTag);
        }
        
        notifyListeners();
      } catch (e) {
        await _log.error('加载服务器列表失败', tag: _logTag, error: e);
        // 清空损坏的数据，重新初始化
        _servers.clear();
        // 不要在这里设置 _isInitializing
        await refreshFromCloudflare();
      }
    } else {
      // 首次运行，自动获取节点
      await _log.info('首次运行，开始获取节点', tag: _logTag);
      // 不要在这里设置 _isInitializing
      await refreshFromCloudflare();
    }
  }

  // 添加一个专门的标志防止重复调用
  Future<void> refreshFromCloudflare() async {
    // 防止重复调用 - 使用独立的标志
    if (_isRefreshing) {
      await _log.warn('已经在获取节点中，忽略重复调用', tag: _logTag);
      return;
    }
    
    _isRefreshing = true; // 设置刷新标志
    _isInitializing = true;
    _initMessage = 'gettingBestNodes';  // 使用国际化键值
    _initDetail = 'preparingTestEnvironment';  // 使用国际化键值
    _progress = 0.0;
    
    // 立即清空现有节点列表
    _servers.clear();
    await _saveServers();  // 立即保存到本地，确保清空缓存
    notifyListeners();

    try {
      await _log.info('开始从Cloudflare获取节点', tag: _logTag);
      
      // 创建 StreamController
      final controller = StreamController<TestProgress>();
      
      // 使用公共的 executeTestWithProgress 方法
      final completer = Completer<List<ServerModel>>();
      final subscription = controller.stream.listen(
        (progress) {
          // 更新进度消息 - 使用本地化消息
          if (!progress.hasError) {
            _initMessage = _getLocalizedMessage(progress);
            _initDetail = _getLocalizedDetail(progress);
            _progress = progress.progress;
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
      
      // 调用公共方法 - 修改：移除speed参数
      CloudflareTestService.executeTestWithProgress(
        controller: controller,
        count: AppConfig.defaultTestNodeCount,
        maxLatency: AppConfig.defaultMaxLatency,
        testCount: AppConfig.defaultSampleCount,
        location: 'AUTO',
        useHttping: false,
      );
      
      // 等待结果
      final servers = await completer.future;
      await subscription.cancel();
      
      if (servers.isEmpty) {
        throw 'noValidNodes';  // 使用国际化键值
      }
      
      // 直接替换服务器列表（不是追加）
      _servers = _generateNamedServers(servers);
      await _saveServers();
      
      // 成功消息主要用于日志，保持中文即可
      _initMessage = '';  // 成功时清空消息
      _progress = 1.0;
      await _log.info('成功获取 ${_servers.length} 个节点', tag: _logTag);
      
    } catch (e) {
      await _log.error('获取节点失败', tag: _logTag, error: e);
      _initMessage = 'failed';  // 使用标记表示失败，UI层会显示国际化文字
      _progress = 0.0;
      // 清空服务器列表
      _servers.clear();
      await _saveServers();
    } finally {
      await Future.delayed(const Duration(seconds: 1));
      _isInitializing = false;
      _isRefreshing = false; // 重置刷新标志
      // 修改：在失败时不清空 _initMessage，让UI能够判断是否失败
      if (_servers.isNotEmpty) {
        // 只有成功时才清空消息
        _initMessage = '';
      }
      _initDetail = '';
      _progress = 0.0;
      notifyListeners();
    }
  }

  // 获取本地化的消息 - 需要修改以支持新的键
  String _getLocalizedMessage(TestProgress progress) {
    // 这里简化处理，实际使用时需要通过context获取本地化
    switch (progress.messageKey) {
      case 'preparingTestEnvironment':
        return '准备测试环境';
      case 'generatingTestIPs':
        return '生成测试IP';
      case 'testingDelay':
        return '测试延迟';
      case 'testingResponseSpeed':  // 新增
        return '测试响应速度';
      case 'testCompleted':
        return '测试完成';
      default:
        return progress.messageKey;
    }
  }

  // 获取本地化的详情 - 需要修改以支持新的键
  String _getLocalizedDetail(TestProgress progress) {
    if (progress.detailKey == null) return '';
    
    switch (progress.detailKey!) {
      case 'initializing':
        return '正在初始化';
      case 'startingTraceTest':  // 新增
        return '开始Trace测试';
      case 'ipRanges':
        final count = progress.detailParams?['count'] ?? 0;
        return '从 $count 个IP段采样';
      case 'nodeProgress':
        final current = progress.detailParams?['current'] ?? 0;
        final total = progress.detailParams?['total'] ?? 0;
        return '$current/$total';
      case 'foundQualityNodes':
        final count = progress.detailParams?['count'] ?? 0;
        return '找到 $count 个优质节点';
      default:
        return progress.detailKey!;
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

  // 清空所有服务器
  Future<void> clearAllServers() async {
    _servers.clear();
    await _saveServers();
    notifyListeners();
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

// ===== 语言管理（修改：添加系统语言检测） =====
class LocaleProvider extends ChangeNotifier {
  static const String _localeKey = 'app_locale';
  static const String _isUserSetKey = 'is_user_set_locale'; // 新增：标记是否用户手动设置
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
      // 用户已保存语言设置
      final parts = localeCode.split('_');
      if (parts.length == 2) {
        _locale = Locale(parts[0], parts[1]);
      } else {
        _locale = Locale(localeCode);
      }
    } else if (!isUserSet) {
      // 首次运行，自动检测系统语言
      _locale = _detectSystemLocale();
      
      // 保存检测到的语言（但不标记为用户设置）
      if (_locale != null) {
        final code = _locale!.countryCode != null 
            ? '${_locale!.languageCode}_${_locale!.countryCode}'
            : _locale!.languageCode;
        await prefs.setString(_localeKey, code);
      }
    } else {
      // 默认中文
      _locale = const Locale('zh', 'CN');
    }
    
    notifyListeners();
  }
  
  // 检测系统语言
  Locale? _detectSystemLocale() {
    // 获取系统语言
    final systemLocales = WidgetsBinding.instance.platformDispatcher.locales;
    if (systemLocales.isEmpty) return const Locale('zh', 'CN');
    
    final systemLocale = systemLocales.first;
    
    // 支持的语言列表（从AppLocalizations复制）
    const supportedLocales = [
      Locale('zh', 'CN'),
      Locale('en', 'US'),
      Locale('zh', 'TW'),
      Locale('es', 'ES'),
      Locale('ru', 'RU'),
      Locale('ar', 'SA'),
    ];
    
    // 精确匹配
    for (final supported in supportedLocales) {
      if (supported.languageCode == systemLocale.languageCode &&
          supported.countryCode == systemLocale.countryCode) {
        return supported;
      }
    }
    
    // 语言代码匹配
    for (final supported in supportedLocales) {
      if (supported.languageCode == systemLocale.languageCode) {
        return supported;
      }
    }
    
    // 特殊处理中文变体
    if (systemLocale.languageCode == 'zh') {
      // 根据地区码判断简繁体
      if (['HK', 'MO', 'TW'].contains(systemLocale.countryCode)) {
        return const Locale('zh', 'TW');
      }
      return const Locale('zh', 'CN');
    }
    
    // 默认中文
    return const Locale('zh', 'CN');
  }
  
  Future<void> setLocale(Locale locale) async {
    _locale = locale;
    
    final prefs = await SharedPreferences.getInstance();
    final localeCode = locale.countryCode != null 
        ? '${locale.languageCode}_${locale.countryCode}'
        : locale.languageCode;
    
    await prefs.setString(_localeKey, localeCode);
    await prefs.setBool(_isUserSetKey, true); // 标记为用户手动设置
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

// ===== 新增：APK下载管理 =====
class DownloadProvider extends ChangeNotifier {
  double _progress = 0.0;
  bool _isDownloading = false;
  String? _error;
  String? _downloadedFilePath;  // 新增：保存下载文件路径
  
  double get progress => _progress;
  bool get isDownloading => _isDownloading;
  String? get error => _error;
  
  // 使用http包下载APK - 优化Android平台处理
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
      
      // 获取文件大小
      final contentLength = response.contentLength ?? 0;
      
      // 获取保存路径 - Android优化
      Directory saveDir;
      String fileName = 'update.apk';
      
      if (Platform.isAndroid) {
        // Android: 优先使用外部存储下载目录
        try {
          // 先尝试获取外部存储目录
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            // 创建下载子目录
            saveDir = Directory('${externalDir.path}/Download');
            if (!await saveDir.exists()) {
              await saveDir.create(recursive: true);
            }
          } else {
            // 如果外部存储不可用，使用应用文档目录
            saveDir = await getApplicationDocumentsDirectory();
          }
        } catch (e) {
          // 出错时使用临时目录
          saveDir = await getTemporaryDirectory();
        }
        
        // 生成唯一文件名避免冲突
        fileName = 'cfvpn_update_${DateTime.now().millisecondsSinceEpoch}.apk';
      } else {
        // 其他平台使用文档目录
        saveDir = await getApplicationDocumentsDirectory();
      }
      
      final file = File('${saveDir.path}/$fileName');
      
      // 创建文件写入流
      final sink = file.openWrite();
      int received = 0;
      
      // 监听下载进度
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
      
      // 保存文件路径
      _downloadedFilePath = file.path;
      
      _isDownloading = false;
      _progress = 1.0;
      notifyListeners();
      
      // Android: 确保文件可读
      if (Platform.isAndroid) {
        try {
          // 设置文件权限为可读
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
  
  // 清理下载的文件
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