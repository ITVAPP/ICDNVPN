import 'dart:io';
import '../utils/log_service.dart';
import '../app_config.dart';

class ProxyService {
  static const String _logTag = 'ProxyService';  // 日志标签
  static final LogService _log = LogService.instance;  // 日志服务实例
  
  static const _registryPath = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  // 修改：使用AppConfig构建代理服务器地址
  static String get _proxyServer => '127.0.0.1:${AppConfig.v2rayHttpPort}';

  static Future<void> enableSystemProxy() async {
    if (!Platform.isWindows) {
      await _log.info('非Windows平台，跳过系统代理设置', tag: _logTag);
      return;
    }

    try {
      await _log.info('正在启用系统代理...', tag: _logTag);
      
      // 使用reg命令设置代理 - 避免win32_registry依赖
      await Process.run('reg', [
        'add',
        'HKCU\\$_registryPath',
        '/v', 'ProxyEnable',
        '/t', 'REG_DWORD',
        '/d', '1',
        '/f'
      ]);
      
      await Process.run('reg', [
        'add',
        'HKCU\\$_registryPath',
        '/v', 'ProxyServer',
        '/t', 'REG_SZ',
        '/d', _proxyServer,
        '/f'
      ]);
      
      await Process.run('reg', [
        'add',
        'HKCU\\$_registryPath',
        '/v', 'ProxyOverride',
        '/t', 'REG_SZ',
        '/d', 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>',
        '/f'
      ]);

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
      
      // 验证代理是否设置成功
      await _verifyProxySettings();
      
      await _log.info('系统代理启用成功', tag: _logTag);
    } catch (e) {
      await _log.error('启用系统代理失败', tag: _logTag, error: e);
      throw '无法设置系统代理: $e';
    }
  }

  static Future<void> disableSystemProxy() async {
    if (!Platform.isWindows) {
      await _log.info('非Windows平台，跳过系统代理禁用', tag: _logTag);
      return;
    }

    try {
      await _log.info('正在禁用系统代理...', tag: _logTag);
      
      // 使用reg命令禁用代理
      await Process.run('reg', [
        'add',
        'HKCU\\$_registryPath',
        '/v', 'ProxyEnable',
        '/t', 'REG_DWORD',
        '/d', '0',
        '/f'
      ]);
      
      // 删除代理服务器设置
      await Process.run('reg', [
        'delete',
        'HKCU\\$_registryPath',
        '/v', 'ProxyServer',
        '/f'
      ], runInShell: true);

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
      
      await _log.info('系统代理禁用成功', tag: _logTag);
    } catch (e) {
      await _log.error('禁用系统代理失败', tag: _logTag, error: e);
      throw '无法禁用系统代理: $e';
    }
  }

  static Future<void> _refreshSystemProxy() async {
    if (!Platform.isWindows) return;
    
    try {
      // 方法1: 使用 WinINet API 刷新
      await Process.run('powershell', [
        '-Command',
        r'[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int lpdwBufferLength); $INTERNET_OPTION_REFRESH = 37; $INTERNET_OPTION_SETTINGS_CHANGED = 39; [IntPtr]::Zero | % { [Win32.NativeMethods]::InternetSetOption($_, $INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0) }; [IntPtr]::Zero | % { [Win32.NativeMethods]::InternetSetOption($_, $INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0) }'
      ], runInShell: true);
      
      // 方法2: 重启 WinHTTP 服务
      await Process.run('net', ['stop', 'WinHttpAutoProxySvc'], runInShell: true);
      await Process.run('net', ['start', 'WinHttpAutoProxySvc'], runInShell: true);
      
      // 方法3: 刷新 DNS
      await Process.run('ipconfig', ['/flushdns'], runInShell: true);
      
    } catch (e) {
      await _log.warn('刷新系统代理设置时出现警告: $e', tag: _logTag);
      // 不抛出错误，因为主要设置可能已经成功
    }
  }

  // 验证代理设置
  static Future<bool> _verifyProxySettings() async {
    if (!Platform.isWindows) return false;
    
    try {
      final status = await getProxyStatus();
      final isEnabled = status['enabled'] == true && status['server'] == _proxyServer;
      
      await _log.info('代理验证结果: ${isEnabled ? "已启用" : "未启用"}', tag: _logTag);
      await _log.debug('ProxyEnable: ${status['enabled']}', tag: _logTag);
      await _log.debug('ProxyServer: ${status['server']}', tag: _logTag);
      
      return isEnabled;
    } catch (e) {
      await _log.error('验证代理设置失败', tag: _logTag, error: e);
      return false;
    }
  }
  
  // 获取当前代理状态
  static Future<Map<String, dynamic>> getProxyStatus() async {
    if (!Platform.isWindows) {
      return {
        'enabled': false,
        'server': '',
        'override': '',
        'platform': Platform.operatingSystem,
      };
    }
    
    try {
      // 查询ProxyEnable
      final enableResult = await Process.run('reg', [
        'query',
        'HKCU\\$_registryPath',
        '/v', 'ProxyEnable'
      ]);
      
      // 查询ProxyServer
      final serverResult = await Process.run('reg', [
        'query',
        'HKCU\\$_registryPath',
        '/v', 'ProxyServer'
      ]);
      
      // 查询ProxyOverride
      final overrideResult = await Process.run('reg', [
        'query',
        'HKCU\\$_registryPath',
        '/v', 'ProxyOverride'
      ]);
      
      // 解析结果
      final isEnabled = enableResult.stdout.toString().contains('0x1');
      
      final serverMatch = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)').firstMatch(serverResult.stdout.toString());
      final server = serverMatch?.group(1)?.trim() ?? '';
      
      final overrideMatch = RegExp(r'ProxyOverride\s+REG_SZ\s+(.+)').firstMatch(overrideResult.stdout.toString());
      final override = overrideMatch?.group(1)?.trim() ?? '';
      
      return {
        'enabled': isEnabled,
        'server': server,
        'override': override,
      };
    } catch (e) {
      return {
        'enabled': false,
        'server': '',
        'override': '',
        'error': e.toString(),
      };
    }
  }
}