import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../app_config.dart';

/// 版本信息实体类
class VersionInfo {
  final String version;
  final String? minVersion;
  final String downloadUrl;
  final String updateContent;
  final String? downloadUrlWindows;  // Windows下载链接
  final String? downloadUrlMac;      // macOS下载链接
  final String? downloadUrlLinux;    // Linux下载链接
  
  VersionInfo({
    required this.version,
    this.minVersion,
    required this.downloadUrl,
    required this.updateContent,
    this.downloadUrlWindows,
    this.downloadUrlMac,
    this.downloadUrlLinux,
  });
  
  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    return VersionInfo(
      version: json['version'] ?? '',
      minVersion: json['minVersion'],
      downloadUrl: json['downloadUrl'] ?? '',
      updateContent: json['updateContent'] ?? '',
      downloadUrlWindows: json['downloadUrlWindows'],
      downloadUrlMac: json['downloadUrlMac'],
      downloadUrlLinux: json['downloadUrlLinux'],
    );
  }
  
  /// 获取当前平台的下载链接
  String getPlatformDownloadUrl() {
    // 根据平台返回对应的下载链接
    if (Platform.isAndroid) {
      // Android使用通用downloadUrl或模板
      if (downloadUrl.isNotEmpty && !downloadUrl.contains('{version}')) {
        return downloadUrl;
      }
      // 使用AppConfig中的模板，替换版本号
      return AppConfig.androidDownloadUrlTemplate.replaceAll('{version}', version);
    } else if (Platform.isIOS) {
      // iOS使用App Store链接
      return AppConfig.getIosAppStoreUrl() ?? downloadUrl;
    } else if (Platform.isWindows) {
      // Windows优先使用专用链接
      if (downloadUrlWindows != null && downloadUrlWindows!.isNotEmpty) {
        return downloadUrlWindows!;
      }
      // 使用AppConfig中的模板，替换版本号
      return AppConfig.windowsDownloadUrlTemplate.replaceAll('{version}', version);
    } else if (Platform.isMacOS) {
      // macOS优先使用专用链接或App Store
      if (downloadUrlMac != null && downloadUrlMac!.isNotEmpty) {
        return downloadUrlMac!;
      }
      // 如果有Mac App Store ID，使用App Store链接
      final macAppStoreUrl = AppConfig.getMacAppStoreUrl();
      if (macAppStoreUrl != null) {
        return macAppStoreUrl;
      }
      // 使用AppConfig中的模板，替换版本号
      return AppConfig.macosDownloadUrlTemplate.replaceAll('{version}', version);
    } else if (Platform.isLinux) {
      // Linux优先使用专用链接
      if (downloadUrlLinux != null && downloadUrlLinux!.isNotEmpty) {
        return downloadUrlLinux!;
      }
      // 使用AppConfig中的模板，替换版本号
      return AppConfig.linuxDownloadUrlTemplate.replaceAll('{version}', version);
    }
    
    // 默认返回通用下载链接
    return downloadUrl;
  }
}

/// 语义化版本比较
class SemanticVersion {
  final List<int> _version;
  final String _originalString;
  
  SemanticVersion._(this._version, this._originalString);
  
  static SemanticVersion? parse(String versionString) {
    if (versionString.isEmpty) return null;
    
    String cleanVersion = versionString;
    if (cleanVersion.startsWith('v') || cleanVersion.startsWith('V')) {
      cleanVersion = cleanVersion.substring(1);
    }
    
    // 移除构建号和预发布标识
    if (cleanVersion.contains('+')) {
      cleanVersion = cleanVersion.split('+')[0];
    }
    if (cleanVersion.contains('-')) {
      cleanVersion = cleanVersion.split('-')[0];
    }
    
    final segments = cleanVersion.split('.');
    final versionNumbers = <int>[];
    
    for (final segment in segments) {
      final num = int.tryParse(segment);
      if (num == null) return null;
      versionNumbers.add(num);
    }
    
    if (versionNumbers.isEmpty) return null;
    
    // 补齐到3位
    while (versionNumbers.length < 3) {
      versionNumbers.add(0);
    }
    
    return SemanticVersion._(versionNumbers, versionString);
  }
  
  int compareTo(SemanticVersion other) {
    final minLength = _version.length < other._version.length 
        ? _version.length 
        : other._version.length;
    
    for (int i = 0; i < minLength; i++) {
      final comparison = _version[i].compareTo(other._version[i]);
      if (comparison != 0) return comparison;
    }
    
    return _version.length.compareTo(other._version.length);
  }
  
  bool isLessThan(SemanticVersion other) => compareTo(other) < 0;
  bool isGreaterThan(SemanticVersion other) => compareTo(other) > 0;
  bool equals(SemanticVersion other) => compareTo(other) == 0;
  
  @override
  String toString() => _originalString;
}

/// 版本更新服务 - 统一管理版本检查和更新逻辑
class VersionService {
  static final VersionService _instance = VersionService._internal();
  factory VersionService() => _instance;
  VersionService._internal();
  
  // 缓存的版本信息
  VersionInfo? _latestVersionInfo;
  DateTime? _lastCheckTime;
  
  // 获取缓存的最新版本信息
  VersionInfo? get latestVersionInfo => _latestVersionInfo;
  
  // 判断是否有新版本
  bool get hasNewVersion {
    if (_latestVersionInfo == null) return false;
    
    final current = SemanticVersion.parse(AppConfig.currentVersion);
    final latest = SemanticVersion.parse(_latestVersionInfo!.version);
    
    if (current == null || latest == null) return false;
    
    return latest.isGreaterThan(current);
  }
  
  // 判断是否需要强制更新
  bool get isForceUpdate {
    if (_latestVersionInfo == null || _latestVersionInfo!.minVersion == null) {
      return false;
    }
    
    final current = SemanticVersion.parse(AppConfig.currentVersion);
    final min = SemanticVersion.parse(_latestVersionInfo!.minVersion!);
    
    if (current == null || min == null) return false;
    
    return current.isLessThan(min);
  }
  
  /// 检查版本更新
  /// @param forceCheck 是否强制检查（忽略时间间隔）
  /// @param silent 是否静默检查（不更新提示时间）
  Future<VersionCheckResult> checkVersion({
    bool forceCheck = false,
    bool silent = false,
  }) async {
    // 检查是否需要从网络获取
    if (!forceCheck) {
      // 如果有缓存且在配置的缓存时间内，直接返回缓存 - 使用AppConfig
      if (_latestVersionInfo != null && 
          _lastCheckTime != null &&
          DateTime.now().difference(_lastCheckTime!) < AppConfig.versionCheckCacheExpiry) {
        return VersionCheckResult(
          hasUpdate: hasNewVersion,
          isForceUpdate: isForceUpdate,
          versionInfo: _latestVersionInfo,
        );
      }
      
      // 检查更新间隔限制 - 使用AppConfig
      final prefs = await SharedPreferences.getInstance();
      final lastCheck = prefs.getInt('last_version_check') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      
      if (now - lastCheck < AppConfig.updateCheckInterval.inMilliseconds) {
        return VersionCheckResult(
          hasUpdate: false,
          isForceUpdate: false,
          versionInfo: null,
        );
      }
    }
    
    try {
      // 获取版本信息
      final versionInfo = await _fetchVersionInfo();
      if (versionInfo == null) {
        return VersionCheckResult(
          hasUpdate: false,
          isForceUpdate: false,
          versionInfo: null,
          error: '获取版本信息失败',
        );
      }
      
      // 更新缓存
      _latestVersionInfo = versionInfo;
      _lastCheckTime = DateTime.now();
      
      // 比较版本
      final current = SemanticVersion.parse(AppConfig.currentVersion);
      final latest = SemanticVersion.parse(versionInfo.version);
      
      if (current == null || latest == null) {
        return VersionCheckResult(
          hasUpdate: false,
          isForceUpdate: false,
          versionInfo: null,
          error: '版本号解析失败',
        );
      }
      
      // 检查是否需要更新
      final needUpdate = latest.isGreaterThan(current);
      
      // 检查是否强制更新
      bool forceUpdate = false;
      if (needUpdate && versionInfo.minVersion != null) {
        final min = SemanticVersion.parse(versionInfo.minVersion!);
        if (min != null && current.isLessThan(min)) {
          forceUpdate = true;
        }
      }
      
      // 更新检查时间
      if (!silent) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('last_version_check', DateTime.now().millisecondsSinceEpoch);
      }
      
      return VersionCheckResult(
        hasUpdate: needUpdate,
        isForceUpdate: forceUpdate,
        versionInfo: needUpdate ? versionInfo : null,
      );
    } catch (e) {
      print('版本检查失败: $e');
      return VersionCheckResult(
        hasUpdate: false,
        isForceUpdate: false,
        versionInfo: null,
        error: e.toString(),
      );
    }
  }
  
  /// 记录更新提示时间
  Future<void> recordUpdatePrompt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('last_update_prompt', DateTime.now().millisecondsSinceEpoch);
  }
  
  /// 检查是否应该显示更新提示 - 使用AppConfig
  Future<bool> shouldShowUpdatePrompt() async {
    final prefs = await SharedPreferences.getInstance();
    final lastPrompt = prefs.getInt('last_update_prompt') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    return now - lastPrompt >= AppConfig.updatePromptInterval.inMilliseconds;
  }
  
  /// 获取版本信息
  Future<VersionInfo?> _fetchVersionInfo() async {
    try {
      String jsonStr;
      
      // 判断是本地还是远程 - 使用AppConfig
      if (AppConfig.versionApiUrl.startsWith('assets/')) {
        // 本地文件
        jsonStr = await rootBundle.loadString(AppConfig.versionApiUrl);
      } else {
        // 远程API - 使用Future.any实现主备地址
        final futures = <Future<String>>[];
        
        futures.add(
          http.get(Uri.parse(AppConfig.versionApiUrl))
              .timeout(const Duration(seconds: 5))
              .then((response) {
                if (response.statusCode == 200) {
                  return response.body;
                }
                throw Exception('请求失败');
              })
        );
        
        if (AppConfig.versionApiBackupUrl != null) {
          futures.add(
            http.get(Uri.parse(AppConfig.versionApiBackupUrl!))
                .timeout(const Duration(seconds: 5))
                .then((response) {
                  if (response.statusCode == 200) {
                    return response.body;
                  }
                  throw Exception('备用地址请求失败');
                })
          );
        }
        
        jsonStr = await Future.any(futures);
      }
      
      final json = jsonDecode(jsonStr);
      return VersionInfo.fromJson(json);
    } catch (e) {
      print('获取版本信息失败: $e');
      return null;
    }
  }
}

/// 版本检查结果
class VersionCheckResult {
  final bool hasUpdate;
  final bool isForceUpdate;
  final VersionInfo? versionInfo;
  final String? error;
  
  VersionCheckResult({
    required this.hasUpdate,
    required this.isForceUpdate,
    this.versionInfo,
    this.error,
  });
}