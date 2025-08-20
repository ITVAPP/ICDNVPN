import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import '../utils/log_service.dart';
import '../app_config.dart';

class ProxyService {
  static const String _logTag = 'ProxyService';  // 日志标签
  static final LogService _log = LogService.instance;  // 日志服务实例
  
  static const _registryPath = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  // 修改：使用AppConfig构建代理服务器地址
  static String get _proxyServer => '127.0.0.1:${AppConfig.v2rayHttpPort}';
  
  // 添加：注册表备份变量
  static int? _originalProxyEnable;
  static String? _originalProxyServer;
  static String? _originalProxyOverride;

  // ============ 从win32_registry复制的核心代码 ============
  // 只在Windows平台编译和执行，移动端会跳过
  
  /// 打开注册表路径（简化版本，从win32_registry的Registry.openPath复制）
  static int? _openRegistryKey(String path, int accessRights) {
    if (!Platform.isWindows) return null;
    
    final phKey = calloc<HKEY>();
    final lpSubKey = path.toNativeUtf16();
    try {
      final lStatus = RegOpenKeyEx(
        HKEY_CURRENT_USER,  // 固定使用CURRENT_USER
        lpSubKey,
        0,
        accessRights,
        phKey,
      );
      if (lStatus == ERROR_SUCCESS) {
        // 重要修正：先保存句柄值，再释放phKey指针
        final hkeyValue = phKey.value;
        free(phKey);  // 释放指针本身，但句柄值已保存
        return hkeyValue;
      } else {
        free(phKey);  // 失败时也要释放
        throw Exception('Failed to open registry key: $lStatus');
      }
    } finally {
      free(lpSubKey);  // 始终释放字符串
    }
  }
  
  /// 设置注册表DWORD值（从win32_registry的createValue简化）
  static void _setRegistryDwordValue(int hkey, String valueName, int value) {
    if (!Platform.isWindows) return;
    
    final lpValueName = valueName.toNativeUtf16();
    final lpData = calloc<DWORD>()..value = value;
    try {
      final retcode = RegSetValueEx(
        hkey,
        lpValueName,
        0,  // Reserved, must be 0
        REG_DWORD,  // Type: DWORD
        lpData.cast<BYTE>(),
        sizeOf<DWORD>(),
      );
      if (retcode != ERROR_SUCCESS) {
        throw Exception('Failed to set DWORD value: $retcode');
      }
    } finally {
      free(lpValueName);
      free(lpData);
    }
  }
  
  /// 设置注册表字符串值（从win32_registry的createValue简化）
  static void _setRegistryStringValue(int hkey, String valueName, String value) {
    if (!Platform.isWindows) return;
    
    final lpValueName = valueName.toNativeUtf16();
    final lpData = value.toNativeUtf16();
    try {
      // 计算字符串长度（UTF-16，每个字符2字节，加上null终止符）
      // 这与 win32_registry 的 RegistryValueExtension.toWin32() 完全一致
      final dataLength = (value.length + 1) * 2;
      
      final retcode = RegSetValueEx(
        hkey,
        lpValueName,
        0,  // Reserved, must be 0
        REG_SZ,  // Type: String
        lpData.cast<BYTE>(),
        dataLength,
      );
      if (retcode != ERROR_SUCCESS) {
        throw Exception('Failed to set string value: $retcode');
      }
    } finally {
      free(lpValueName);
      free(lpData);
    }
  }
  
  /// 删除注册表值
  static void _deleteRegistryValue(int hkey, String valueName) {
    if (!Platform.isWindows) return;
    
    final lpValueName = valueName.toNativeUtf16();
    try {
      final retcode = RegDeleteValue(hkey, lpValueName);
      if (retcode != ERROR_SUCCESS && retcode != ERROR_FILE_NOT_FOUND) {
        throw Exception('Failed to delete value: $retcode');
      }
    } finally {
      free(lpValueName);
    }
  }
  
  /// 读取注册表DWORD值
  static int? _getRegistryDwordValue(int hkey, String valueName) {
    if (!Platform.isWindows) return null;
    
    final lpValueName = valueName.toNativeUtf16();
    final lpType = calloc<DWORD>();
    final lpData = calloc<DWORD>();
    final lpcbData = calloc<DWORD>()..value = sizeOf<DWORD>();
    
    try {
      final retcode = RegQueryValueEx(
        hkey,
        lpValueName,
        nullptr,
        lpType,
        lpData.cast<BYTE>(),
        lpcbData,
      );
      
      if (retcode == ERROR_SUCCESS && lpType.value == REG_DWORD) {
        return lpData.value;
      }
      return null;
    } finally {
      free(lpValueName);
      free(lpType);
      free(lpData);
      free(lpcbData);
    }
  }
  
  /// 读取注册表字符串值
  static String? _getRegistryStringValue(int hkey, String valueName) {
    if (!Platform.isWindows) return null;
    
    final lpValueName = valueName.toNativeUtf16();
    final lpType = calloc<DWORD>();
    final lpcbData = calloc<DWORD>();
    
    try {
      // 第一次调用获取所需缓冲区大小
      var retcode = RegQueryValueEx(
        hkey,
        lpValueName,
        nullptr,
        lpType,
        nullptr,
        lpcbData,
      );
      
      if (retcode != ERROR_SUCCESS) return null;
      
      // 分配缓冲区并读取数据
      final lpData = calloc<BYTE>(lpcbData.value);
      try {
        retcode = RegQueryValueEx(
          hkey,
          lpValueName,
          nullptr,
          lpType,
          lpData,
          lpcbData,
        );
        
        if (retcode == ERROR_SUCCESS && 
            (lpType.value == REG_SZ || lpType.value == REG_EXPAND_SZ)) {
          return lpData.cast<Utf16>().toDartString();
        }
        return null;
      } finally {
        free(lpData);
      }
    } finally {
      free(lpValueName);
      free(lpType);
      free(lpcbData);
    }
  }
  
  /// 关闭注册表键
  static void _closeRegistryKey(int hkey) {
    if (!Platform.isWindows) return;
    RegCloseKey(hkey);
  }
  
  // ============ 新增DNS相关方法 ============
  
  /// 获取活动网络适配器列表
  static Future<List<String>> _getActiveNetworkAdapters() async {
    if (!Platform.isWindows) return [];
    
    try {
      // 使用wmic获取活动的网络适配器
      final result = await Process.run(
        'wmic',
        ['nic', 'where', 'NetEnabled=true', 'get', 'NetConnectionID', '/value'],
        runInShell: true
      );
      
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final adapters = <String>[];
        
        // 解析输出
        for (final line in output.split('\n')) {
          if (line.startsWith('NetConnectionID=')) {
            final name = line.substring('NetConnectionID='.length).trim();
            if (name.isNotEmpty) {
              adapters.add(name);
            }
          }
        }
        
        if (adapters.isNotEmpty) {
          await _log.debug('检测到活动网络适配器: ${adapters.join(', ')}', tag: _logTag);
          return adapters;
        }
      }
    } catch (e) {
      await _log.warn('使用wmic获取网络适配器失败: $e', tag: _logTag);
    }
    
    // 备用方案：返回常见的适配器名称（改进：添加更多中文名称）
    final defaultAdapters = [
      '以太网', '以太网 2', '以太网 3',
      'WLAN', 'WLAN 2', 
      'Wi-Fi', 'Wi-Fi 2',
      '无线网络连接', '无线网络连接 2',
      '本地连接', '本地连接 2',
      '有线',
      'Ethernet', 'Ethernet 2',
      'Wireless'
    ];
    await _log.debug('使用默认网络适配器列表: ${defaultAdapters.join(', ')}', tag: _logTag);
    return defaultAdapters;
  }
  
  /// 设置DNS指向V2Ray的虚拟DNS
  static Future<void> _setupDnsRedirection() async {
    if (!Platform.isWindows) return;
    
    try {
      await _log.info('开始设置DNS重定向到V2Ray虚拟DNS', tag: _logTag);
      
      // 从AppConfig读取虚拟DNS端口
      final virtualDnsPort = AppConfig.virtualDnsPort;
      await _log.info('V2Ray虚拟DNS端口: $virtualDnsPort', tag: _logTag);
      
      // 1. 如果虚拟DNS不在标准53端口，设置端口转发
      if (virtualDnsPort != 53) {
        await _log.info('设置端口转发: 53 -> $virtualDnsPort', tag: _logTag);
        
        // 先删除可能存在的旧规则
        await Process.run('netsh', [
          'interface', 'portproxy', 'delete', 'v4tov4',
          'listenport=53',
          'listenaddress=127.0.0.1'
        ], runInShell: true);
        
        // 添加新的端口转发规则
        final addResult = await Process.run('netsh', [
          'interface', 'portproxy', 'add', 'v4tov4',
          'listenport=53',
          'listenaddress=127.0.0.1',
          'connectport=$virtualDnsPort',
          'connectaddress=127.0.0.1'
        ], runInShell: true);
        
        if (addResult.exitCode == 0) {
          await _log.info('端口转发规则添加成功', tag: _logTag);
        } else {
          await _log.warn('端口转发规则添加失败: ${addResult.stderr}', tag: _logTag);
        }
        
        // 显示当前的端口转发规则（用于调试）
        final showResult = await Process.run('netsh', [
          'interface', 'portproxy', 'show', 'v4tov4'
        ], runInShell: true);
        
        if (showResult.exitCode == 0) {
          await _log.debug('当前端口转发规则:\n${showResult.stdout}', tag: _logTag);
        }
      }
      
      // 2. 获取活动网络适配器
      final adapters = await _getActiveNetworkAdapters();
      
      // 3. 为每个适配器设置DNS为127.0.0.1
      for (final adapter in adapters) {
        try {
          // 设置主DNS服务器
          final result = await Process.run('netsh', [
            'interface', 'ip', 'set', 'dns',
            'name="$adapter"',
            'source=static',
            'address=127.0.0.1'
          ], runInShell: true);
          
          if (result.exitCode == 0) {
            await _log.info('已设置适配器 "$adapter" 的DNS为127.0.0.1', tag: _logTag);
          } else {
            await _log.warn('设置适配器 "$adapter" 的DNS失败: ${result.stderr}', tag: _logTag);
          }
        } catch (e) {
          await _log.warn('设置适配器 "$adapter" 的DNS时出错: $e', tag: _logTag);
        }
      }
      
      await _log.info('DNS重定向设置完成', tag: _logTag);
      
    } catch (e) {
      await _log.error('设置DNS重定向失败', tag: _logTag, error: e);
    }
  }
  
  /// 恢复DNS设置（增强版：添加刷新命令）
  static Future<void> _restoreDnsSettings() async {
    if (!Platform.isWindows) return;
    
    try {
      await _log.info('开始恢复DNS设置', tag: _logTag);
      
      // 1. 移除端口转发规则
      final virtualDnsPort = AppConfig.virtualDnsPort;
      if (virtualDnsPort != 53) {
        final result = await Process.run('netsh', [
          'interface', 'portproxy', 'delete', 'v4tov4',
          'listenport=53',
          'listenaddress=127.0.0.1'
        ], runInShell: true);
        
        if (result.exitCode == 0) {
          await _log.info('端口转发规则已移除', tag: _logTag);
        } else {
          await _log.debug('移除端口转发规则失败（可能不存在）: ${result.stderr}', tag: _logTag);
        }
      }
      
      // 2. 恢复网络适配器的DNS为自动获取
      final adapters = await _getActiveNetworkAdapters();
      
      for (final adapter in adapters) {
        try {
          final result = await Process.run('netsh', [
            'interface', 'ip', 'set', 'dns',
            'name="$adapter"',
            'source=dhcp'
          ], runInShell: true);
          
          if (result.exitCode == 0) {
            await _log.info('已恢复适配器 "$adapter" 的DNS为自动获取', tag: _logTag);
          } else {
            await _log.warn('恢复适配器 "$adapter" 的DNS失败: ${result.stderr}', tag: _logTag);
          }
        } catch (e) {
          await _log.warn('恢复适配器 "$adapter" 的DNS时出错: $e', tag: _logTag);
        }
      }
      
      // 3. 添加：刷新DNS缓存和网络配置
      await _log.info('刷新DNS缓存', tag: _logTag);
      await Process.run('ipconfig', ['/flushdns']);
      
      // 4. 添加：注册DNS
      await _log.info('注册DNS', tag: _logTag);
      await Process.run('ipconfig', ['/registerdns']);
      
      await _log.info('DNS设置恢复完成', tag: _logTag);
      
    } catch (e) {
      await _log.error('恢复DNS设置失败', tag: _logTag, error: e);
    }
  }
  
  // ============ ProxyService 主要方法 ============
  
  static Future<void> enableSystemProxy() async {
    if (!Platform.isWindows) {
      await _log.info('非Windows平台，跳过系统代理设置', tag: _logTag);
      return;
    }

    int? hkey;
    try {
      await _log.info('正在启用系统代理...', tag: _logTag);
      await _log.info('目标代理服务器: $_proxyServer', tag: _logTag);
      
      // 打开注册表键（使用从win32_registry复制的代码）
      hkey = _openRegistryKey(_registryPath, KEY_ALL_ACCESS);
      if (hkey == null) {
        throw Exception('无法打开注册表键');
      }
      
      // 添加：备份原始值
      _originalProxyEnable = _getRegistryDwordValue(hkey, 'ProxyEnable');
      _originalProxyServer = _getRegistryStringValue(hkey, 'ProxyServer');
      _originalProxyOverride = _getRegistryStringValue(hkey, 'ProxyOverride');
      await _log.info('已备份原始代理设置', tag: _logTag);
      
      // 1. 启用代理 - 设置ProxyEnable为1 (DWORD类型)
      _setRegistryDwordValue(hkey, 'ProxyEnable', 1);
      await _log.info('ProxyEnable已设置为1', tag: _logTag);
      
      // 2. 设置代理服务器地址 - ProxyServer (字符串类型)
      _setRegistryStringValue(hkey, 'ProxyServer', _proxyServer);
      await _log.info('ProxyServer已设置为: $_proxyServer', tag: _logTag);
      
      // 3. 设置代理白名单 - ProxyOverride (字符串类型)
      const proxyOverride = 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>';
      _setRegistryStringValue(hkey, 'ProxyOverride', proxyOverride);
      await _log.info('ProxyOverride已设置', tag: _logTag);
      
      // 关闭注册表键
      _closeRegistryKey(hkey);
      hkey = null;
      
      // 4. 设置DNS重定向到V2Ray虚拟DNS（防止DNS泄露）
      await _setupDnsRedirection();

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
      if (hkey != null) {
        _closeRegistryKey(hkey);
      }
      throw '无法设置系统代理: $e';
    }
  }

  static Future<void> disableSystemProxy() async {
    if (!Platform.isWindows) {
      await _log.info('非Windows平台，跳过系统代理禁用', tag: _logTag);
      return;
    }

    int? hkey;
    try {
      await _log.info('正在禁用系统代理...', tag: _logTag);
      
      // 打开注册表键
      hkey = _openRegistryKey(_registryPath, KEY_ALL_ACCESS);
      if (hkey == null) {
        throw Exception('无法打开注册表键');
      }
      
      // 修改：恢复原始值而不是简单删除
      if (_originalProxyEnable != null) {
        _setRegistryDwordValue(hkey, 'ProxyEnable', _originalProxyEnable!);
        await _log.info('ProxyEnable已恢复为原始值: $_originalProxyEnable', tag: _logTag);
      } else {
        _setRegistryDwordValue(hkey, 'ProxyEnable', 0);
        await _log.info('ProxyEnable已设置为0', tag: _logTag);
      }
      
      if (_originalProxyServer != null && _originalProxyServer!.isNotEmpty) {
        _setRegistryStringValue(hkey, 'ProxyServer', _originalProxyServer!);
        await _log.info('ProxyServer已恢复为原始值', tag: _logTag);
      } else {
        try {
          _deleteRegistryValue(hkey, 'ProxyServer');
          await _log.info('ProxyServer设置已删除', tag: _logTag);
        } catch (e) {
          // 如果删除失败，尝试设置为空字符串
          try {
            _setRegistryStringValue(hkey, 'ProxyServer', '');
            await _log.info('ProxyServer设置已清空', tag: _logTag);
          } catch (e2) {
            await _log.debug('清空ProxyServer失败（非致命）: $e2', tag: _logTag);
          }
        }
      }
      
      if (_originalProxyOverride != null && _originalProxyOverride!.isNotEmpty) {
        _setRegistryStringValue(hkey, 'ProxyOverride', _originalProxyOverride!);
        await _log.info('ProxyOverride已恢复为原始值', tag: _logTag);
      } else {
        try {
          _deleteRegistryValue(hkey, 'ProxyOverride');
          await _log.info('ProxyOverride设置已删除', tag: _logTag);
        } catch (e) {
          // 如果删除失败，尝试设置为空字符串
          try {
            _setRegistryStringValue(hkey, 'ProxyOverride', '');
            await _log.info('ProxyOverride设置已清空', tag: _logTag);
          } catch (e2) {
            await _log.debug('清空ProxyOverride失败（非致命）: $e2', tag: _logTag);
          }
        }
      }
      
      // 清空备份值
      _originalProxyEnable = null;
      _originalProxyServer = null;
      _originalProxyOverride = null;
      
      // 关闭注册表键
      _closeRegistryKey(hkey);
      hkey = null;
      
      // 恢复DNS设置
      await _restoreDnsSettings();

      // 通知系统代理设置已更改
      await _refreshSystemProxy();
      
      await _log.info('系统代理禁用成功', tag: _logTag);
    } catch (e) {
      await _log.error('禁用系统代理失败', tag: _logTag, error: e);
      if (hkey != null) {
        _closeRegistryKey(hkey);
      }
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
  
  // 获取当前代理状态（使用复制的注册表读取代码）
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
    
    int? hkey;
    try {
      // 打开注册表键（只读）
      hkey = _openRegistryKey(_registryPath, KEY_READ);
      if (hkey == null) {
        throw Exception('无法打开注册表键');
      }
      
      bool isEnabled = false;
      String server = '';
      String override = '';
      
      // 读取ProxyEnable
      final enableValue = _getRegistryDwordValue(hkey, 'ProxyEnable');
      if (enableValue != null) {
        isEnabled = enableValue == 1;
      }
      await _log.debug('ProxyEnable读取结果: $isEnabled', tag: _logTag);
      
      // 读取ProxyServer
      final serverValue = _getRegistryStringValue(hkey, 'ProxyServer');
      if (serverValue != null) {
        server = serverValue;
      }
      await _log.debug('ProxyServer读取结果: $server', tag: _logTag);
      
      // 读取ProxyOverride
      final overrideValue = _getRegistryStringValue(hkey, 'ProxyOverride');
      if (overrideValue != null) {
        override = overrideValue;
      }
      if (override.isNotEmpty) {
        await _log.debug('ProxyOverride读取结果: ${override.substring(0, override.length > 50 ? 50 : override.length)}...', tag: _logTag);
      }
      
      // 关闭注册表键
      _closeRegistryKey(hkey);
      hkey = null;  // 清空引用
      
      final status = {
        'enabled': isEnabled,
        'server': server,
        'override': override,
      };
      
      await _log.debug('代理状态查询完成', tag: _logTag);
      
      return status;
    } catch (e) {
      await _log.error('查询代理状态时发生错误', tag: _logTag, error: e);
      if (hkey != null) {
        _closeRegistryKey(hkey);
      }
      return {
        'enabled': false,
        'server': '',
        'override': '',
        'error': e.toString(),
      };
    }
  }
}
