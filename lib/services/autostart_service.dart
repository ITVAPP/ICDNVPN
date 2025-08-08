import 'dart:io';
import '../app_config.dart';

class AutoStartService {
  static const String _registryPath = r'Software\Microsoft\Windows\CurrentVersion\Run';
  // 修改：使用AppConfig.appName
  static String get _appName => AppConfig.appName;

  static bool isAutoStartEnabled() {
    // 只有Windows支持通过注册表设置自启动
    if (!Platform.isWindows) {
      return false;
    }
    
    try {
      // 使用reg命令查询注册表
      final result = Process.runSync('reg', [
        'query',
        'HKCU\\$_registryPath',
        '/v',
        _appName,
      ]);
      
      // 如果找到了键值，说明自启动已启用
      return result.exitCode == 0 && result.stdout.toString().contains(_appName);
    } catch (e) {
      return false;
    }
  }

  static Future<bool> setAutoStart(bool enable) async {
    // 只有Windows支持通过注册表设置自启动
    if (!Platform.isWindows) {
      return false;
    }
    
    try {
      if (enable) {
        // 获取可执行文件路径
        final exePath = Platform.resolvedExecutable;
        
        // 使用reg命令添加注册表项
        final result = await Process.run('reg', [
          'add',
          'HKCU\\$_registryPath',
          '/v',
          _appName,
          '/t',
          'REG_SZ',
          '/d',
          '"$exePath"',
          '/f', // 强制覆盖
        ]);
        
        return result.exitCode == 0;
      } else {
        // 使用reg命令删除注册表项
        final result = await Process.run('reg', [
          'delete',
          'HKCU\\$_registryPath',
          '/v',
          _appName,
          '/f', // 强制删除，不提示
        ]);
        
        // 删除命令可能返回1（键不存在），这也算成功
        return result.exitCode == 0 || result.exitCode == 1;
      }
    } catch (e) {
      return false;
    }
  }
  
  // 提示用户如何在不同平台设置自启动
  static String getAutoStartInstructions() {
    if (Platform.isAndroid) {
      return '请在系统设置 > 应用管理 > ${AppConfig.appName} > 自启动管理中开启';
    } else if (Platform.isIOS) {
      return 'iOS不支持应用自启动';
    } else if (Platform.isWindows) {
      return '可以在设置中开启开机自启动';
    } else if (Platform.isMacOS) {
      return '请在系统偏好设置 > 用户与群组 > 登录项中添加${AppConfig.appName}';
    } else if (Platform.isLinux) {
      return '请将应用添加到系统的自启动应用列表中';
    } else {
      return '当前平台不支持自启动设置';
    }
  }
}