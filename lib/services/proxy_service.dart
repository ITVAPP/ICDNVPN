import 'dart:io';
import 'package:win32_registry/win32_registry.dart';

class ProxyService {
  static const _registryPath = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _proxyServer = '127.0.0.1:7899'; // HTTP 代理地址

  static Future<void> enableSystemProxy() async {
    if (!Platform.isWindows) return;

    try {
      final key = Registry.openPath(RegistryHive.currentUser, path: _registryPath, desiredAccessRights: AccessRights.allAccess);
      
      // 启用代理
      key.createValue(RegistryValue('ProxyEnable', RegistryValueType.int32, 1));
      // 设置代理服务器地址
      key.createValue(RegistryValue('ProxyServer', RegistryValueType.string, _proxyServer));
      // 设置不走代理的地址
      key.createValue(RegistryValue('ProxyOverride', RegistryValueType.string, 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>'));
      
      key.close();

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
    } catch (e) {
      print('Error enabling system proxy: $e');
      rethrow;
    }
  }

  static Future<void> disableSystemProxy() async {
    if (!Platform.isWindows) return;

    try {
      final key = Registry.openPath(RegistryHive.currentUser, path: _registryPath, desiredAccessRights: AccessRights.allAccess);
      
      // 禁用代理
      key.createValue(RegistryValue('ProxyEnable', RegistryValueType.int32, 0));
      
      key.close();

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
    } catch (e) {
      print('Error disabling system proxy: $e');
      rethrow;
    }
  }

  static Future<void> _refreshSystemProxy() async {
    try {
      // 刷新系统代理设置
      await Process.run('ipconfig', ['/flushdns']);
      
      // 使用 netsh 命令刷新代理设置
      await Process.run(
        'netsh',
        ['winhttp', 'import', 'proxy', 'source=ie'],
        runInShell: true
      );

      // 通知系统代理设置已更改
      await Process.run(
        'netsh',
        ['winhttp', 'reset', 'proxy'],
        runInShell: true
      );
    } catch (e) {
      print('Error refreshing system proxy: $e');
    }
  }
} 