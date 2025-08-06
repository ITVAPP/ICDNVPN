import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_config.dart';
import '../utils/log_service.dart'; 

/// 用户信息内部类
class UserInfo {
  final String ip;
  final String country;
  final String region;
  final String city;
  final String deviceInfo;
  final String userAgent;
  final String screenSize;
  final DateTime timestamp;
  
  UserInfo({
    required this.ip,
    required this.country,
    required this.region,
    required this.city,
    required this.deviceInfo,
    required this.userAgent,
    required this.screenSize,
    required this.timestamp,
  });
  
  Map<String, dynamic> toJson() => {
    'ip': ip,
    'country': country,
    'region': region,
    'city': city,
    'deviceInfo': deviceInfo,
    'userAgent': userAgent,
    'screenSize': screenSize,
    'timestamp': timestamp.toIso8601String(),
  };
  
  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
    ip: json['ip'] ?? 'Unknown',
    country: json['country'] ?? 'Unknown',
    region: json['region'] ?? 'Unknown',
    city: json['city'] ?? 'Unknown',
    deviceInfo: json['deviceInfo'] ?? 'Unknown',
    userAgent: json['userAgent'] ?? 'Unknown',
    screenSize: json['screenSize'] ?? 'Unknown',
    timestamp: DateTime.parse(json['timestamp'] ?? DateTime.now().toIso8601String()),
  );
}

/// 位置和统计服务
class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();
  
  // 缓存键
  static const String _userInfoCacheKey = 'user_info_cache';
  static const String _lastAnalyticsKey = 'last_analytics_time';
  
  // 设备信息插件
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  
  // 内存缓存
  UserInfo? _cachedUserInfo;
  
  // IP定位API配置（从原项目复制）
  static const List<Map<String, dynamic>> _ipApis = [
    {
      'url': 'https://myip.ipip.net/json',
      'parser': 'ipip',
    },
    {
      'url': 'https://open.saintic.com/ip/rest',
      'parser': 'saintic',
    },
    {
      'url': 'https://yun.thecover.cn/fmio/ip',
      'parser': 'thecover',
    },
  ];
  
  /// 获取用户完整信息
  Future<UserInfo> getUserInfo(BuildContext context) async {
    // 检查内存缓存 - 使用AppConfig的缓存过期时间
    if (_cachedUserInfo != null) {
      final age = DateTime.now().difference(_cachedUserInfo!.timestamp);
      if (age < AppConfig.userInfoCacheExpiry) {
        return _cachedUserInfo!;
      }
    }
    
    // 检查本地缓存
    final prefs = await SharedPreferences.getInstance();
    final cachedJson = prefs.getString(_userInfoCacheKey);
    if (cachedJson != null) {
      try {
        final cached = UserInfo.fromJson(jsonDecode(cachedJson));
        final age = DateTime.now().difference(cached.timestamp);
        // 使用AppConfig的缓存过期时间
        if (age < AppConfig.userInfoCacheExpiry) {
          _cachedUserInfo = cached;
          return cached;
        }
      } catch (e) {
        LogService.instance.error('缓存解析失败', error: e);
      }
    }
    
    // 获取新数据
    final userInfo = await _fetchUserInfo(context);
    
    // 保存缓存
    _cachedUserInfo = userInfo;
    await prefs.setString(_userInfoCacheKey, jsonEncode(userInfo.toJson()));
    
    return userInfo;
  }
  
  /// 获取用户信息
  Future<UserInfo> _fetchUserInfo(BuildContext context) async {
    // 并发获取位置和设备信息
    final results = await Future.wait([
      _fetchLocationInfo(),
      _fetchDeviceInfo(),
    ]);
    
    final location = results[0] as Map<String, String>;
    final device = results[1] as Map<String, String>;
    
    // 获取屏幕尺寸
    final size = MediaQuery.of(context).size;
    final screenSize = '${size.width.toInt()}x${size.height.toInt()}';
    
    return UserInfo(
      ip: location['ip'] ?? 'Unknown',
      country: location['country'] ?? 'Unknown',
      region: location['region'] ?? 'Unknown',
      city: location['city'] ?? 'Unknown',
      deviceInfo: device['device'] ?? 'Unknown',
      userAgent: device['userAgent'] ?? 'Unknown',
      screenSize: screenSize,
      timestamp: DateTime.now(),
    );
  }
  
  /// 获取位置信息
  Future<Map<String, String>> _fetchLocationInfo() async {
    // 尝试所有API，返回第一个成功的
    for (final api in _ipApis) {
      try {
        final response = await http.get(
          Uri.parse(api['url']),
        ).timeout(const Duration(seconds: 5));
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final parsed = _parseLocationData(data, api['parser']);
          if (parsed != null) {
            return parsed;
          }
        }
      } catch (e) {
        // 继续尝试下一个API
        continue;
      }
    }
    
    // 所有API失败，返回默认值
    return {
      'ip': 'Unknown',
      'country': 'Unknown',
      'region': 'Unknown',
      'city': 'Unknown',
    };
  }
  
  /// 解析位置数据
  Map<String, String>? _parseLocationData(Map<String, dynamic> data, String parser) {
    try {
      switch (parser) {
        case 'ipip':
          if (data['ret'] == 'ok' && data['data'] != null) {
            final location = data['data']['location'] as List;
            return {
              'ip': data['data']['ip'] ?? 'Unknown',
              'country': location.isNotEmpty ? location[0] : 'Unknown',
              'region': location.length > 1 ? location[1] : 'Unknown',
              'city': location.length > 2 ? location[2] : 'Unknown',
            };
          }
          break;
          
        case 'saintic':
          if (data['data'] != null) {
            return {
              'ip': data['data']['ip'] ?? 'Unknown',
              'country': data['data']['country'] ?? 'Unknown',
              'region': data['data']['province'] ?? 'Unknown',
              'city': data['data']['city'] ?? 'Unknown',
            };
          }
          break;
          
        case 'thecover':
          if (data['rspcode'] == 200 && data['data'] != null) {
            return {
              'ip': data['data']['ip'] ?? 'Unknown',
              'country': '中国',
              'region': data['data']['province'] ?? 'Unknown',
              'city': data['data']['city'] ?? 'Unknown',
            };
          }
          break;
      }
    } catch (e) {
      LogService.instance.error('位置解析失败', error: e);
    }
    return null;
  }
  
  /// 获取设备信息
  Future<Map<String, String>> _fetchDeviceInfo() async {
    try {
      String deviceInfo = 'Unknown Device';
      String userAgent = '${AppConfig.appName}/${AppConfig.currentVersion}';  // 使用AppConfig
      
      if (Platform.isAndroid) {
        final android = await _deviceInfo.androidInfo;
        deviceInfo = '${android.model} (Android ${android.version.release})';
        userAgent = '${AppConfig.appName}/${AppConfig.currentVersion} (Android ${android.version.release})';  // 使用AppConfig
      } else if (Platform.isIOS) {
        final ios = await _deviceInfo.iosInfo;
        deviceInfo = '${ios.utsname.machine} (iOS ${ios.systemVersion})';
        userAgent = '${AppConfig.appName}/${AppConfig.currentVersion} (iOS ${ios.systemVersion})';  // 使用AppConfig
      } else if (Platform.isWindows) {
        deviceInfo = 'Windows PC';
        userAgent = '${AppConfig.appName}/${AppConfig.currentVersion} (Windows)';  // 使用AppConfig
      } else if (Platform.isMacOS) {
        deviceInfo = 'Mac';
        userAgent = '${AppConfig.appName}/${AppConfig.currentVersion} (macOS)';  // 使用AppConfig
      } else if (Platform.isLinux) {
        deviceInfo = 'Linux PC';
        userAgent = '${AppConfig.appName}/${AppConfig.currentVersion} (Linux)';  // 使用AppConfig
      }
      
      return {
        'device': deviceInfo,
        'userAgent': userAgent,
      };
    } catch (e) {
      LogService.instance.error('设备信息获取失败', error: e);
      return {
        'device': 'Unknown Device',
        'userAgent': '${AppConfig.appName}/${AppConfig.currentVersion}',  // 使用AppConfig
      };
    }
  }
  
  /// 发送统计数据（优化：增加前置判断）
  Future<void> sendAnalytics(BuildContext context, String page) async {
    // 优化：检查是否配置了统计API，如果未配置直接返回
    if (AppConfig.analyticsApiUrl.isEmpty) {
      // 不需要统计，直接返回，避免不必要的用户信息获取
      return;
    }
    
    // 检查24小时限制 - 使用AppConfig的统计间隔
    final prefs = await SharedPreferences.getInstance();
    final lastTime = prefs.getInt(_lastAnalyticsKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    if (now - lastTime < AppConfig.analyticsInterval.inMilliseconds) {
      return; // 未到时间
    }
    
    try {
      // 只有在需要统计时才获取用户信息
      final userInfo = await getUserInfo(context);
      
      // 构建统计数据
      final data = {
        'page': page,
        'timestamp': DateTime.now().toIso8601String(),
        'ip': userInfo.ip,
        'location': {
          'country': userInfo.country,
          'region': userInfo.region,
          'city': userInfo.city,
        },
        'device': userInfo.deviceInfo,
        'userAgent': userInfo.userAgent,
        'screenSize': userInfo.screenSize,
        'version': AppConfig.currentVersion,
      };
      
      // 异步发送，不等待响应
      http.post(
        Uri.parse(AppConfig.analyticsApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(data),
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => http.Response('', 408),
      ).then((_) {
        // 成功后更新时间
        prefs.setInt(_lastAnalyticsKey, now);
      }).catchError((e) {
        // 静默处理错误
        LogService.instance.error('统计上报失败', error: e);
      });
    } catch (e) {
      // 静默处理错误
      LogService.instance.error('统计处理失败', error: e);
    }
  }
}