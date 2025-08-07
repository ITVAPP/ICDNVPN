import 'dart:io';
import 'package:win32_registry/win32_registry.dart';
import '../utils/log_service.dart';
import '../app_config.dart';

class ProxyService {
  static const String _logTag = 'ProxyService';  // 日志标签
  static final LogService _log = LogService.instance;  // 日志服务实例
  
  static const _registryPath = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  // 修改：使用AppConfig构建代理服务器地址
  static String get _proxyServer => '127.0.0.1:${AppConfig.v2rayHttpPort}';

  static Future<void> enableSystemProxy() async {
    if (!Platform.isWindows) return;

    try {
      await _log.info('正在启用系统代理...', tag: _logTag);
      
      final key = Registry.openPath(
        RegistryHive.currentUser, 
        path: _registryPath,
        desiredAccessRights: AccessRights.allAccess
      );
      
      // 启用代理
      key.createValue(RegistryValue('ProxyEnable', RegistryValueType.int32, 1));
      
      // 设置代理服务器地址
      key.createValue(RegistryValue('ProxyServer', RegistryValueType.string, _proxyServer));
      
      // 设置不走代理的地址（本地地址）
      key.createValue(RegistryValue(
        'ProxyOverride', 
        RegistryValueType.string, 
        'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>'
      ));
      
      key.close();

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
    if (!Platform.isWindows) return;

    try {
      await _log.info('正在禁用系统代理...', tag: _logTag);
      
      final key = Registry.openPath(
        RegistryHive.currentUser, 
        path: _registryPath,
        desiredAccessRights: AccessRights.allAccess
      );
      
      // 禁用代理
      key.createValue(RegistryValue('ProxyEnable', RegistryValueType.int32, 0));
      
      // 清除代理服务器设置
      try {
        key.deleteValue('ProxyServer');
      } catch (e) {
        // 忽略删除错误
      }
      
      key.close();

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
      
      await _log.info('系统代理禁用成功', tag: _logTag);
    } catch (e) {
      await _log.error('禁用系统代理失败', tag: _logTag, error: e);
      throw '无法禁用系统代理: $e';
    }
  }

  static Future<void> _refreshSystemProxy() async {
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
      await _log.warn('刷新系统代理设置时出现警告', tag: _logTag, error: e);
      // 不抛出错误，因为主要设置可能已经成功
    }
  }

  // 验证代理设置
  static Future<bool> _verifyProxySettings() async {
    try {
      final key = Registry.openPath(
        RegistryHive.currentUser,
        path: _registryPath,
        desiredAccessRights: AccessRights.readOnly
      );
      
      final proxyEnable = key.getValue('ProxyEnable')?.data as int?;
      final proxyServer = key.getValue('ProxyServer')?.data as String?;
      
      key.close();
      
      final isEnabled = proxyEnable == 1 && proxyServer == _proxyServer;
      await _log.info('代理验证结果: ${isEnabled ? "已启用" : "未启用"}', tag: _logTag);
      await _log.debug('ProxyEnable: $proxyEnable', tag: _logTag);
      await _log.debug('ProxyServer: $proxyServer', tag: _logTag);
      
      return isEnabled;
    } catch (e) {
      await _log.error('验证代理设置失败', tag: _logTag, error: e);
      return false;
    }
  }
  
  // 获取当前代理状态
  static Future<Map<String, dynamic>> getProxyStatus() async {
    try {
      final key = Registry.openPath(
        RegistryHive.currentUser,
        path: _registryPath,
        desiredAccessRights: AccessRights.readOnly
      );
      
      final proxyEnable = key.getValue('ProxyEnable')?.data as int? ?? 0;
      final proxyServer = key.getValue('ProxyServer')?.data as String? ?? '';
      final proxyOverride = key.getValue('ProxyOverride')?.data as String? ?? '';
      
      key.close();
      
      return {
        'enabled': proxyEnable == 1,
        'server': proxyServer,
        'override': proxyOverride,
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