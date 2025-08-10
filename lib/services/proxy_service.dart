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
      await _log.info('目标代理服务器: $_proxyServer', tag: _logTag);
      
      // 记录完整的注册表路径，验证字符串插值是否正确
      final fullPath = "HKCU\\$_registryPath";
      await _log.debug('注册表完整路径: $fullPath', tag: _logTag);
      
      // 使用reg命令设置代理 - 避免win32_registry依赖
      // 修复：使用双引号进行字符串插值
      
      // 1. 启用代理
      await _log.debug('执行: reg add "$fullPath" /v ProxyEnable /t REG_DWORD /d 1 /f', tag: _logTag);
      final enableResult = await Process.run('reg', [
        'add',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyEnable',
        '/t', 'REG_DWORD',
        '/d', '1',
        '/f'
      ]);
      
      if (enableResult.exitCode != 0) {
        await _log.error('设置ProxyEnable失败: ${enableResult.stderr}', tag: _logTag);
        throw '设置ProxyEnable失败';
      }
      await _log.info('ProxyEnable已设置为1', tag: _logTag);
      
      // 2. 设置代理服务器地址
      await _log.debug('执行: reg add "$fullPath" /v ProxyServer /t REG_SZ /d $_proxyServer /f', tag: _logTag);
      final serverResult = await Process.run('reg', [
        'add',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyServer',
        '/t', 'REG_SZ',
        '/d', _proxyServer,
        '/f'
      ]);
      
      if (serverResult.exitCode != 0) {
        await _log.error('设置ProxyServer失败: ${serverResult.stderr}', tag: _logTag);
        throw '设置ProxyServer失败';
      }
      await _log.info('ProxyServer已设置为: $_proxyServer', tag: _logTag);
      
      // 3. 设置代理白名单
      await _log.debug('设置代理白名单（ProxyOverride）', tag: _logTag);
      final overrideResult = await Process.run('reg', [
        'add',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyOverride',
        '/t', 'REG_SZ',
        '/d', 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>',
        '/f'
      ]);
      
      if (overrideResult.exitCode != 0) {
        await _log.warn('设置ProxyOverride失败（非致命）: ${overrideResult.stderr}', tag: _logTag);
      } else {
        await _log.info('ProxyOverride已设置', tag: _logTag);
      }

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
      
      // 验证代理是否设置成功
      final verifyResult = await _verifyProxySettings();
      if (!verifyResult) {
        await _log.warn('代理设置验证失败，但可能仍然有效', tag: _logTag);
      }
      
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
      
      // 记录完整的注册表路径
      final fullPath = "HKCU\\$_registryPath";
      await _log.debug('注册表完整路径: $fullPath', tag: _logTag);
      
      // 使用reg命令禁用代理
      await _log.debug('执行: reg add "$fullPath" /v ProxyEnable /t REG_DWORD /d 0 /f', tag: _logTag);
      final disableResult = await Process.run('reg', [
        'add',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyEnable',
        '/t', 'REG_DWORD',
        '/d', '0',
        '/f'
      ]);
      
      if (disableResult.exitCode != 0) {
        await _log.error('禁用ProxyEnable失败: ${disableResult.stderr}', tag: _logTag);
        throw '禁用ProxyEnable失败';
      }
      await _log.info('ProxyEnable已设置为0', tag: _logTag);
      
      // 删除代理服务器设置（可选，不影响禁用效果）
      try {
        await _log.debug('尝试删除ProxyServer设置', tag: _logTag);
        await Process.run('reg', [
          'delete',
          "HKCU\\$_registryPath",  // 修复：单引号改为双引号
          '/v', 'ProxyServer',
          '/f'
        ], runInShell: true);
        await _log.info('ProxyServer设置已删除', tag: _logTag);
      } catch (e) {
        await _log.debug('删除ProxyServer失败（非致命）: $e', tag: _logTag);
      }

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
    
    await _log.debug('开始刷新系统代理设置', tag: _logTag);
    
    try {
      // 重要修复：使用与版本1完全相同的刷新方法
      
      // 1. 刷新DNS缓存
      await _log.debug('刷新DNS缓存', tag: _logTag);
      final flushDnsResult = await Process.run('ipconfig', ['/flushdns']);
      if (flushDnsResult.exitCode == 0) {
        await _log.debug('DNS缓存已刷新', tag: _logTag);
      } else {
        await _log.debug('DNS缓存刷新失败: ${flushDnsResult.stderr}', tag: _logTag);
      }
      
      // 2. 使用 netsh 命令导入IE代理设置到WinHTTP
      await _log.debug('导入IE代理设置到WinHTTP', tag: _logTag);
      final importResult = await Process.run(
        'netsh',
        ['winhttp', 'import', 'proxy', 'source=ie'],
        runInShell: true
      );
      if (importResult.exitCode == 0) {
        await _log.debug('WinHTTP代理导入成功', tag: _logTag);
      } else {
        await _log.debug('WinHTTP代理导入失败: ${importResult.stderr}', tag: _logTag);
      }
      
      // 3. 重置WinHTTP代理（清除缓存，使其重新读取）
      await _log.debug('重置WinHTTP代理', tag: _logTag);
      final resetResult = await Process.run(
        'netsh',
        ['winhttp', 'reset', 'proxy'],
        runInShell: true
      );
      if (resetResult.exitCode == 0) {
        await _log.debug('WinHTTP代理重置成功', tag: _logTag);
      } else {
        await _log.debug('WinHTTP代理重置失败: ${resetResult.stderr}', tag: _logTag);
      }
      
      await _log.debug('系统代理设置刷新完成', tag: _logTag);
      
    } catch (e) {
      await _log.warn('刷新系统代理设置时出现警告: $e', tag: _logTag);
      // 不抛出错误，因为主要设置可能已经成功
    }
  }

  // 验证代理设置
  static Future<bool> _verifyProxySettings() async {
    if (!Platform.isWindows) return false;
    
    await _log.debug('开始验证代理设置', tag: _logTag);
    
    try {
      final status = await getProxyStatus();
      final isEnabled = status['enabled'] == true && status['server'] == _proxyServer;
      
      await _log.info('代理验证结果: ${isEnabled ? "已启用" : "未启用"}', tag: _logTag);
      await _log.debug('ProxyEnable: ${status['enabled']}', tag: _logTag);
      await _log.debug('ProxyServer: ${status['server']}', tag: _logTag);
      await _log.debug('期望ProxyServer: $_proxyServer', tag: _logTag);
      
      if (status['enabled'] == true && status['server'] != _proxyServer) {
        await _log.warn('代理已启用但服务器地址不匹配', tag: _logTag);
        await _log.warn('当前: ${status['server']}, 期望: $_proxyServer', tag: _logTag);
      }
      
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
    
    await _log.debug('查询当前代理状态', tag: _logTag);
    
    try {
      // 记录完整路径用于调试
      final fullPath = "HKCU\\$_registryPath";
      await _log.debug('查询注册表路径: $fullPath', tag: _logTag);
      
      // 查询ProxyEnable
      // 修复：使用双引号进行字符串插值
      await _log.debug('查询ProxyEnable', tag: _logTag);
      final enableResult = await Process.run('reg', [
        'query',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyEnable'
      ]);
      
      if (enableResult.exitCode != 0) {
        await _log.debug('ProxyEnable不存在或查询失败', tag: _logTag);
      }
      
      // 查询ProxyServer
      await _log.debug('查询ProxyServer', tag: _logTag);
      final serverResult = await Process.run('reg', [
        'query',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyServer'
      ]);
      
      if (serverResult.exitCode != 0) {
        await _log.debug('ProxyServer不存在或查询失败', tag: _logTag);
      }
      
      // 查询ProxyOverride
      await _log.debug('查询ProxyOverride', tag: _logTag);
      final overrideResult = await Process.run('reg', [
        'query',
        "HKCU\\$_registryPath",  // 修复：单引号改为双引号
        '/v', 'ProxyOverride'
      ]);
      
      if (overrideResult.exitCode != 0) {
        await _log.debug('ProxyOverride不存在或查询失败', tag: _logTag);
      }
      
      // 解析结果
      final isEnabled = enableResult.stdout.toString().contains('0x1');
      await _log.debug('ProxyEnable解析结果: $isEnabled', tag: _logTag);
      
      final serverMatch = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)').firstMatch(serverResult.stdout.toString());
      final server = serverMatch?.group(1)?.trim() ?? '';
      await _log.debug('ProxyServer解析结果: $server', tag: _logTag);
      
      final overrideMatch = RegExp(r'ProxyOverride\s+REG_SZ\s+(.+)').firstMatch(overrideResult.stdout.toString());
      final override = overrideMatch?.group(1)?.trim() ?? '';
      if (override.isNotEmpty) {
        await _log.debug('ProxyOverride解析结果: ${override.substring(0, override.length > 50 ? 50 : override.length)}...', tag: _logTag);
      }
      
      final status = {
        'enabled': isEnabled,
        'server': server,
        'override': override,
      };
      
      await _log.debug('代理状态查询完成', tag: _logTag);
      
      return status;
    } catch (e) {
      await _log.error('查询代理状态时发生错误', tag: _logTag, error: e);
      return {
        'enabled': false,
        'server': '',
        'override': '',
        'error': e.toString(),
      };
    }
  }
}
