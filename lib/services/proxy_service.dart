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
  
  /// 检查注册表值是否存在
  static bool _registryValueExists(int hkey, String valueName) {
    if (!Platform.isWindows) return false;
    
    final lpValueName = valueName.toNativeUtf16();
    try {
      final retcode = RegQueryValueEx(
        hkey,
        lpValueName,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
      );
      return retcode == ERROR_SUCCESS;
    } finally {
      free(lpValueName);
    }
  }
  
  // ============ 新增备份恢复方法 ============
  
  /// 备份注册表值（通过重命名）
  static Future<void> _backupRegistryValue(int hkey, String valueName) async {
    if (!Platform.isWindows) return;
    
    final backupName = '${valueName}_bak';
    
    // 先删除旧的备份（如果存在）
    try {
      _deleteRegistryValue(hkey, backupName);
    } catch (e) {
      // 忽略删除失败
    }
    
    // 读取当前值
    final dwordValue = _getRegistryDwordValue(hkey, valueName);
    if (dwordValue != null) {
      // 是DWORD类型，创建备份
      _setRegistryDwordValue(hkey, backupName, dwordValue);
      await _log.debug('已备份DWORD值 $valueName -> $backupName: $dwordValue', tag: _logTag);
      return;
    }
    
    final stringValue = _getRegistryStringValue(hkey, valueName);
    if (stringValue != null) {
      // 是字符串类型，创建备份
      _setRegistryStringValue(hkey, backupName, stringValue);
      await _log.debug('已备份字符串值 $valueName -> $backupName', tag: _logTag);
      return;
    }
    
    // 值不存在，不需要备份
    await _log.debug('值 $valueName 不存在，无需备份', tag: _logTag);
  }
  
  /// 恢复注册表值（从备份）
  static Future<void> _restoreRegistryValue(int hkey, String valueName) async {
    if (!Platform.isWindows) return;
    
    final backupName = '${valueName}_bak';
    
    // 先删除当前值
    try {
      _deleteRegistryValue(hkey, valueName);
    } catch (e) {
      // 忽略删除失败
    }
    
    // 读取备份值
    final dwordValue = _getRegistryDwordValue(hkey, backupName);
    if (dwordValue != null) {
      // 恢复DWORD值
      _setRegistryDwordValue(hkey, valueName, dwordValue);
      // 删除备份
      _deleteRegistryValue(hkey, backupName);
      await _log.debug('已恢复DWORD值 $backupName -> $valueName: $dwordValue', tag: _logTag);
      return;
    }
    
    final stringValue = _getRegistryStringValue(hkey, backupName);
    if (stringValue != null) {
      // 恢复字符串值
      _setRegistryStringValue(hkey, valueName, stringValue);
      // 删除备份
      _deleteRegistryValue(hkey, backupName);
      await _log.debug('已恢复字符串值 $backupName -> $valueName', tag: _logTag);
      return;
    }
    
    // 备份不存在，值保持删除状态
    await _log.debug('备份 $backupName 不存在，值 $valueName 保持删除状态', tag: _logTag);
  }
  
  /// 检查并恢复异常退出的备份
  static Future<void> checkAndRestoreBackup() async {
    if (!Platform.isWindows) return;
    
    await _log.info('检查是否存在异常退出的备份...', tag: _logTag);
    
    int? hkey;
    try {
      hkey = _openRegistryKey(_registryPath, KEY_ALL_ACCESS);
      if (hkey == null) return;
      
      // 检查是否存在备份
      bool hasBackup = false;
      if (_registryValueExists(hkey, 'ProxyEnable_bak')) {
        hasBackup = true;
        await _log.warn('发现ProxyEnable备份，表示上次异常退出', tag: _logTag);
        await _restoreRegistryValue(hkey, 'ProxyEnable');
      }
      
      if (_registryValueExists(hkey, 'ProxyServer_bak')) {
        hasBackup = true;
        await _log.warn('发现ProxyServer备份，表示上次异常退出', tag: _logTag);
        await _restoreRegistryValue(hkey, 'ProxyServer');
      }
      
      if (_registryValueExists(hkey, 'ProxyOverride_bak')) {
        hasBackup = true;
        await _log.warn('发现ProxyOverride备份，表示上次异常退出', tag: _logTag);
        await _restoreRegistryValue(hkey, 'ProxyOverride');
      }
      
      if (hasBackup) {
        await _log.info('已恢复异常退出前的代理设置', tag: _logTag);
        
        // 恢复DNS设置
        await _restoreDnsSettings();
        
        // 刷新系统代理
        await _refreshSystemProxy();
      } else {
        await _log.info('未发现备份，系统正常', tag: _logTag);
        
        // 检查是否有DNS备份（可能代理备份已恢复但DNS还未恢复）
        const dnsBackupPath = r'Software\CFVpn\DnsBackup';
        final dnsBackupKey = _openRegistryKey(dnsBackupPath, KEY_READ);
        if (dnsBackupKey != null) {
          _closeRegistryKey(dnsBackupKey);
          await _log.warn('发现DNS备份，恢复DNS设置', tag: _logTag);
          await _restoreDnsSettings();
        }
      }
      
      _closeRegistryKey(hkey);
    } catch (e) {
      await _log.error('检查备份失败', tag: _logTag, error: e);
      if (hkey != null) _closeRegistryKey(hkey);
    }
  }
  
  // ============ 新增DNS相关方法 ============
  
  /// 备份DNS设置到注册表
  static Future<void> _backupDnsSettings() async {
    if (!Platform.isWindows) return;
    
    await _log.info('备份DNS设置', tag: _logTag);
    
    // 创建备份路径
    const dnsBackupPath = r'Software\CFVpn\DnsBackup';
    
    int? hkey;
    try {
      // 创建或打开备份键
      final phKey = calloc<HKEY>();
      final lpSubKey = dnsBackupPath.toNativeUtf16();
      
      try {
        // 使用RegOpenKeyEx尝试打开，如果失败则创建
        var result = RegOpenKeyEx(
          HKEY_CURRENT_USER,
          lpSubKey,
          0,
          KEY_ALL_ACCESS,
          phKey,
        );
        
        if (result != ERROR_SUCCESS) {
          // 键不存在，创建新键
          final lpClass = ''.toNativeUtf16();
          try {
            result = RegCreateKeyEx(
              HKEY_CURRENT_USER,
              lpSubKey,
              0,
              lpClass,
              REG_OPTION_NON_VOLATILE,
              KEY_ALL_ACCESS,
              nullptr,
              phKey,
              nullptr,
            );
          } finally {
            free(lpClass);
          }
        }
        
        if (result == ERROR_SUCCESS) {
          hkey = phKey.value;
        }
      } finally {
        free(lpSubKey);
        free(phKey);
      }
      
      if (hkey == null) {
        await _log.error('无法创建DNS备份注册表键', tag: _logTag);
        return;
      }
      
      // 获取所有网络适配器
      final adapters = await _getActiveNetworkAdapters();
      
      for (final adapter in adapters) {
        try {
          // 获取当前DNS设置
          final result = await Process.run('netsh', [
            'interface', 'ip', 'show', 'dns',
            'name="$adapter"'
          ], runInShell: true);
          
          if (result.exitCode == 0) {
            final output = result.stdout.toString();
            
            // 判断是DHCP还是静态
            if (output.contains('DHCP') || output.contains('自动配置')) {
              // DHCP模式
              _setRegistryStringValue(hkey, '${adapter}_source', 'dhcp');
              await _log.info('适配器 "$adapter" 原DNS: DHCP', tag: _logTag);
            } else {
              // 静态模式，提取DNS服务器
              _setRegistryStringValue(hkey, '${adapter}_source', 'static');
              
              final dnsServers = <String>[];
              final lines = output.split('\n');
              for (final line in lines) {
                final ipMatch = RegExp(r'(\d+\.\d+\.\d+\.\d+)').firstMatch(line);
                if (ipMatch != null && !line.contains('配置') && !line.contains('Configuration')) {
                  dnsServers.add(ipMatch.group(1)!);
                }
              }
              
              if (dnsServers.isNotEmpty) {
                // 保存DNS服务器列表
                _setRegistryStringValue(hkey, '${adapter}_servers', dnsServers.join(','));
                await _log.info('适配器 "$adapter" 原DNS: ${dnsServers.join(", ")}', tag: _logTag);
              }
            }
          }
        } catch (e) {
          await _log.warn('备份适配器 "$adapter" DNS失败: $e', tag: _logTag);
        }
      }
      
      _closeRegistryKey(hkey);
      
    } catch (e) {
      await _log.error('备份DNS设置失败', tag: _logTag, error: e);
      if (hkey != null) _closeRegistryKey(hkey);
    }
  }
  
  /// 从注册表恢复DNS设置
  static Future<void> _restoreDnsFromBackup() async {
    if (!Platform.isWindows) return;
    
    await _log.info('从备份恢复DNS设置', tag: _logTag);
    
    const dnsBackupPath = r'Software\CFVpn\DnsBackup';
    
    int? hkey;
    try {
      // 打开备份键
      hkey = _openRegistryKey(dnsBackupPath, KEY_READ);
      if (hkey == null) {
        await _log.warn('没有找到DNS备份，恢复为DHCP', tag: _logTag);
        await _restoreDnsToDefault();
        return;
      }
      
      // 获取所有网络适配器
      final adapters = await _getActiveNetworkAdapters();
      
      for (final adapter in adapters) {
        try {
          // 读取备份的DNS源类型
          final source = _getRegistryStringValue(hkey, '${adapter}_source');
          
          if (source == 'static') {
            // 恢复静态DNS
            final servers = _getRegistryStringValue(hkey, '${adapter}_servers');
            if (servers != null && servers.isNotEmpty) {
              final dnsServerList = servers.split(',');
              
              // 设置主DNS
              var result = await Process.run('netsh', [
                'interface', 'ip', 'set', 'dns',
                'name="$adapter"',
                'source=static',
                'address=${dnsServerList[0]}'
              ], runInShell: true);
              
              if (result.exitCode == 0) {
                await _log.info('恢复适配器 "$adapter" 主DNS: ${dnsServerList[0]}', tag: _logTag);
              }
              
              // 设置备用DNS
              for (int i = 1; i < dnsServerList.length; i++) {
                result = await Process.run('netsh', [
                  'interface', 'ip', 'add', 'dns',
                  'name="$adapter"',
                  'address=${dnsServerList[i]}',
                  'index=${i + 1}'
                ], runInShell: true);
                
                if (result.exitCode == 0) {
                  await _log.info('恢复适配器 "$adapter" 备用DNS: ${dnsServerList[i]}', tag: _logTag);
                }
              }
            }
          } else if (source == 'dhcp') {
            // 恢复DHCP
            final result = await Process.run('netsh', [
              'interface', 'ip', 'set', 'dns',
              'name="$adapter"',
              'source=dhcp'
            ], runInShell: true);
            
            if (result.exitCode == 0) {
              await _log.info('恢复适配器 "$adapter" DNS为DHCP', tag: _logTag);
            }
          } else {
            // 没有备份，默认恢复为DHCP
            await _log.warn('适配器 "$adapter" 无DNS备份，恢复为DHCP', tag: _logTag);
            await Process.run('netsh', [
              'interface', 'ip', 'set', 'dns',
              'name="$adapter"',
              'source=dhcp'
            ], runInShell: true);
          }
        } catch (e) {
          await _log.warn('恢复适配器 "$adapter" DNS失败: $e', tag: _logTag);
        }
      }
      
      _closeRegistryKey(hkey);
      
      // 清理备份
      await _clearDnsBackup();
      
    } catch (e) {
      await _log.error('恢复DNS设置失败', tag: _logTag, error: e);
      if (hkey != null) _closeRegistryKey(hkey);
    }
  }
  
  /// 清理DNS备份
  static Future<void> _clearDnsBackup() async {
    if (!Platform.isWindows) return;
    
    try {
      // 删除整个备份键
      // 删除整个备份键
      const dnsBackupPath = r'Software\CFVpn\DnsBackup';
      final lpSubKey = dnsBackupPath.toNativeUtf16();
      
      try {
        RegDeleteKey(HKEY_CURRENT_USER, lpSubKey);
        await _log.debug('DNS备份已清理', tag: _logTag);
      } finally {
        free(lpSubKey);
      }
    } catch (e) {
      // 忽略删除失败
    }
  }
  
  /// 恢复DNS为默认（DHCP）
  static Future<void> _restoreDnsToDefault() async {
    if (!Platform.isWindows) return;
    
    final adapters = await _getActiveNetworkAdapters();
    for (final adapter in adapters) {
      try {
        await Process.run('netsh', [
          'interface', 'ip', 'set', 'dns',
          'name="$adapter"',
          'source=dhcp'
        ], runInShell: true);
      } catch (e) {
        // 忽略错误
      }
    }
  }
  
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
      
      // 先备份原始DNS设置
      await _backupDnsSettings();
      
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
  
  /// 恢复DNS设置
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
      
      // 2. 从备份恢复DNS设置
      await _restoreDnsFromBackup();
      
      // 3. 刷新DNS缓存和网络配置
      await _log.info('刷新DNS缓存', tag: _logTag);
      await Process.run('ipconfig', ['/flushdns']);
      
      // 4. 注册DNS
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
      
      // 备份原始值（通过重命名）
      await _log.info('备份原始代理设置', tag: _logTag);
      await _backupRegistryValue(hkey, 'ProxyEnable');
      await _backupRegistryValue(hkey, 'ProxyServer');
      await _backupRegistryValue(hkey, 'ProxyOverride');
      
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
      
      // 恢复原始值（从备份）
      await _log.info('恢复原始代理设置', tag: _logTag);
      await _restoreRegistryValue(hkey, 'ProxyEnable');
      await _restoreRegistryValue(hkey, 'ProxyServer');
      await _restoreRegistryValue(hkey, 'ProxyOverride');
      
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
