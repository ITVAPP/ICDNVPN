import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as path;
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';

/// V2Ray服务管理类
/// 
/// 支持的平台：
/// - Windows: v2ray.exe 放在程序目录/v2ray/下
/// - macOS/Linux: v2ray 优先使用系统路径，否则使用程序目录
/// - Android: v2ray 放在应用私有目录/files/v2ray/下（需要path_provider）
/// - iOS: v2ray 放在应用沙盒Documents/v2ray/下（需要path_provider）
/// 
/// 注意：移动平台需要额外处理：
/// 1. 使用path_provider获取正确的应用目录
/// 2. 确保v2ray二进制文件有执行权限（chmod +x）
/// 3. iOS需要签名和权限配置
class V2RayService {
  static Process? _v2rayProcess;
  static bool _isRunning = false;
  static Function? _onProcessExit; // 进程退出回调
  
  // 流量统计相关
  static int _uploadSpeed = 0;
  static int _downloadSpeed = 0;
  static int _uploadTotal = 0;
  static int _downloadTotal = 0;
  static DateTime _lastUpdateTime = DateTime.now();
  static Timer? _statsTimer;
  
  // 日志服务
  static final LogService _log = LogService.instance;
  static const String _logTag = 'V2RayService';
  
  // 根据平台获取可执行文件名
  static String get _v2rayExecutableName {
    if (Platform.isWindows) {
      return 'v2ray.exe';
    } else {
      return 'v2ray';
    }
  }
  
  static String get _v2ctlExecutableName {
    if (Platform.isWindows) {
      return 'v2ctl.exe';
    } else {
      return 'v2ctl';
    }
  }
  
  static Future<String> getExecutablePath(String executableName) async {
    if (Platform.isWindows) {
      // Windows: 在程序目录下
      final exePath = Platform.resolvedExecutable;
      final directory = path.dirname(exePath);
      return path.join(directory, executableName);
    } else if (Platform.isMacOS || Platform.isLinux) {
      // macOS/Linux: 优先检查系统路径
      final systemPath = path.join('/usr/local/bin', executableName);
      if (await File(systemPath).exists()) {
        return systemPath;
      }
      
      // 否则检查程序目录
      final exePath = Platform.resolvedExecutable;
      final directory = path.dirname(exePath);
      return path.join(directory, executableName);
    } else if (Platform.isAndroid) {
      // Android: 使用应用私有目录
      // 注意：实际路径需要使用 path_provider 插件获取
      // 这里提供一个标准路径供将来实现参考
      // 实际实现时应该使用: 
      // final appDir = await getApplicationSupportDirectory();
      // return path.join(appDir.path, executableName);
      // 
      // 临时方案：假设v2ray在/data/local/tmp/（需要root或特殊权限）
      return path.join('/data/local/tmp', executableName);
    } else if (Platform.isIOS) {
      // iOS: 使用应用沙盒内的Documents目录
      // 注意：实际路径需要使用 path_provider 插件获取
      // 这里提供一个标准路径供将来实现参考
      // 实际实现时应该使用:
      // final appDir = await getApplicationDocumentsDirectory();
      // return path.join(appDir.path, executableName);
      //
      // 临时方案：返回一个示例路径
      return path.join('/var/mobile/Documents', executableName);
    } else {
      throw 'Unsupported platform: ${Platform.operatingSystem}';
    }
  }
  
  static Future<String> _getV2RayPath() async {
    return getExecutablePath(path.join('v2ray', _v2rayExecutableName));
  }
  
  // 设置进程退出回调
  static void setOnProcessExit(Function callback) {
    _onProcessExit = callback;
  }
  
  static Future<void> generateConfig({
    required String serverIp,
    required int serverPort,
    int localPort = 7898,  // SOCKS5 代理端口
    int httpPort = 7899,   // HTTP 代理端口
  }) async {
    serverPort = 443;//暂时写死443
    final v2rayPath = await _getV2RayPath();
    final configPath = path.join(
      path.dirname(v2rayPath),
      'config.json'
    );

    final config = {
      // 日志配置 - 仅保留警告级别，减少日志输出
      "log": {
        "loglevel": "warning"
      },
      
      // 如果需要流量统计功能，必须保留以下配置
      "stats": {},
      "api": {
        "tag": "api",
        "services": ["StatsService"]
      },
      "policy": {
        "levels": {
          "0": {
           // 连接设置
           "handshake": 5,        // 握手超时（秒）
           "connIdle": 300,       // 连接空闲超时（秒）
           "uplinkOnly": 3,       // 下行关闭后的上行超时（秒）
           "downlinkOnly": 5,     // 上行关闭后的下行超时（秒）
      
           // 统计设置
           "statsUserUplink": true,
           "statsUserDownlink": true,
      
           // 内存优化设置
           "bufferSize": 8        // 缓存大小，单位KB（默认512KB）
          }
        },
        "system": {
          "statsInboundUplink": true,
          "statsInboundDownlink": true,
          "statsOutboundUplink": true,
          "statsOutboundDownlink": true
        }
      },
      
      // 入站配置
      "inbounds": [
        {
          "tag": "socks",
          "port": localPort,
          "protocol": "socks",
          "settings": {
            "auth": "noauth",
            "udp": true,
            "userLevel": 0
          }
        },
        {
          "tag": "http",
          "port": httpPort,
          "protocol": "http",
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": false
          },
          "settings": {
            "auth": "noauth",
            "udp": true,
            "allowTransparent": false,
            "userLevel": 0
          }
        },
        // API入站 - 用于流量统计
        {
          "tag": "api",
          "port": 10085,
          "listen": "127.0.0.1",
          "protocol": "dokodemo-door",
          "settings": {
            "address": "127.0.0.1"
          }
        }
      ],
      "outbounds": [
        {
          "tag": "proxy",
          "protocol": "vless",
          "settings": {
            "vnext": [
              {
                "address": serverIp,
                "port": serverPort,
                "users": [
                  {
                    "id": "bc24baea-3e5c-4107-a231-416cf00504fe",
                    "alterId": 0,
                    "email": "t@t.tt",
                    "security": "auto",
                    "encryption": "none"
                  }
                ]
              }
            ]
          },
          "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
              "allowInsecure": false,
              "serverName": "pages-vless-a9f.pages.dev",
              "fingerprint": "randomized"
            },
            "wsSettings": {
              "path": "/",
              "headers": {
                "Host": "pages-vless-a9f.pages.dev"
              }
            },
            "sockopt": {
              "dialerProxy": "proxy3"
            }
          },
          "mux": {
            "enabled": false,
            "concurrency": -1
          }
        },
        {
          "tag": "direct",
          "protocol": "freedom",
          "settings": {}
        },
        {
          "tag": "block",
          "protocol": "blackhole",
          "settings": {
            "response": {
              "type": "http"
            }
          }
        },
        {
          "tag": "proxy3",
          "protocol": "freedom",
          "settings": {
            "fragment": {
              "packets": "tlshello",
              "length": "100-200",
              "interval": "10-20"
            }
          }
        }
      ],
      "dns": {
        "hosts": {
          "dns.google": "8.8.8.8",
          "proxy.example.com": "127.0.0.1"
        },
        "servers": [
          {
            "address": "223.5.5.5",
            "domains": [
              "geosite:cn",
              "geosite:geolocation-cn"
            ],
            "expectIPs": [
              "geoip:cn"
            ]
          },
          "1.1.1.1",
          "8.8.8.8",
          "https://dns.google/dns-query"
        ]
      },
      "routing": {
        "domainStrategy": "AsIs",
        "rules": [
          // 修复关键点：添加API路由规则，必须在第一位
          {
            "type": "field",
            "inboundTag": [
              "api"
            ],
            "outboundTag": "api"
          },
          {
            "type": "field",
            "port": "443",
            "network": "udp",
            "outboundTag": "block"
          },
          {
            "type": "field",
            "outboundTag": "block",
            "domain": [
              "geosite:category-ads-all"
            ]
          },
          {
            "type": "field",
            "outboundTag": "direct",
            "domain": [
              "domain:dns.alidns.com",
              "domain:doh.pub",
              "domain:dot.pub",
              "domain:doh.360.cn",
              "domain:dot.360.cn",
              "geosite:cn",
              "geosite:geolocation-cn"
            ]
          },
          {
            "type": "field",
            "outboundTag": "direct",
            "ip": [
              "223.5.5.5/32",
              "223.6.6.6/32",
              "2400:3200::1/128",
              "2400:3200:baba::1/128",
              "119.29.29.29/32",
              "1.12.12.12/32",
              "120.53.53.53/32",
              "2402:4e00::/128",
              "2402:4e00:1::/128",
              "180.76.76.76/32",
              "2400:da00::6666/128",
              "114.114.114.114/32",
              "114.114.115.115/32",
              "180.184.1.1/32",
              "180.184.2.2/32",
              "101.226.4.6/32",
              "218.30.118.6/32",
              "123.125.81.6/32",
              "140.207.198.6/32",
              "geoip:private",
              "geoip:cn"
            ]
          },
          {
            "type": "field",
            "port": "0-65535",
            "outboundTag": "proxy"
          }
        ]
      }
    };

    await File(configPath).writeAsString(jsonEncode(config));
    await _log.info('配置文件已生成: $configPath', tag: _logTag);
  }

  static Future<bool> isPortAvailable(int port) async {
    try {
      // 移动平台可能需要特殊处理
      if (Platform.isAndroid || Platform.isIOS) {
        // 移动平台通常不需要检查端口，因为应用有独立的网络空间
        await _log.debug('移动平台跳过端口检查', tag: _logTag);
        return true;
      }
      
      final socket = await ServerSocket.bind('127.0.0.1', port, shared: true);
      await socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }
  
  static Future<bool> start({
    required String serverIp,
    required int serverPort,
  }) async {
    if (_isRunning) {
      await stop();  // 确保先停止旧进程
    }

    try {
      await _log.info('开始启动V2Ray服务 - 服务器: $serverIp:$serverPort', tag: _logTag);
      
      // 检查端口是否可用
      if (!await isPortAvailable(7898) || !await isPortAvailable(7899)) {
        await _log.error('端口 7898 或 7899 已被占用', tag: _logTag);
        throw 'Port 7898 or 7899 is already in use';
      }

      // 生成配置文件
      await generateConfig(serverIp: serverIp, serverPort: serverPort);

      final v2rayPath = await _getV2RayPath();
      if (!await File(v2rayPath).exists()) {
        await _log.error('$_v2rayExecutableName 未找到: $v2rayPath', tag: _logTag);
        throw '$_v2rayExecutableName not found at: $v2rayPath';
      }

      await _log.info('启动V2Ray进程: $v2rayPath', tag: _logTag);
      
      // 准备进程启动参数
      final Map<String, String> environment = {};
      
      // Android平台可能需要设置环境变量
      if (Platform.isAndroid) {
        // 设置LD_LIBRARY_PATH以加载动态库
        final libDir = path.dirname(v2rayPath);
        environment['LD_LIBRARY_PATH'] = libDir;
        await _log.debug('Android平台设置LD_LIBRARY_PATH: $libDir', tag: _logTag);
      }
      
      // 启动 v2ray 进程
      _v2rayProcess = await Process.start(
        v2rayPath,
        ['run'],
        workingDirectory: path.dirname(v2rayPath),
        runInShell: true,  // 在shell中运行以获取更高权限
        environment: environment.isNotEmpty ? environment : null,
      );

      // 等待一段时间检查进程是否正常运行
      await Future.delayed(const Duration(seconds: 2));
      
      if (_v2rayProcess == null) {
        await _log.error('V2Ray进程启动失败', tag: _logTag);
        throw 'Failed to start V2Ray process';
      }

      // 监听进程输出 - 修复：改进错误判断逻辑
      _v2rayProcess!.stdout.transform(utf8.decoder).listen((data) {
        _log.debug('V2Ray stdout: $data', tag: _logTag);
        
        // 只检测真正的启动失败
        if (data.toLowerCase().contains('failed to start') || 
            data.toLowerCase().contains('panic:') ||
            data.toLowerCase().contains('fatal error')) {
          _isRunning = false;
          _log.error('V2Ray启动失败: $data', tag: _logTag);
        }
      });

      _v2rayProcess!.stderr.transform(utf8.decoder).listen((data) {
        _log.warn('V2Ray stderr: $data', tag: _logTag);
      });

      // 监听进程退出
      _v2rayProcess!.exitCode.then((code) {
        _log.info('V2Ray进程退出，退出码: $code', tag: _logTag);
        _isRunning = false;
        // 调用进程退出回调
        if (_onProcessExit != null) {
          _onProcessExit!();
        }
      });

      _isRunning = true;
      await _log.info('V2Ray服务启动成功', tag: _logTag);
      
      // 重置流量统计
      _uploadSpeed = 0;
      _downloadSpeed = 0;
      _uploadTotal = 0;
      _downloadTotal = 0;
      _lastUpdateTime = DateTime.now();
      
      // 启动流量统计定时器（每秒更新一次）
      _startStatsTimer();
      
      return true;
    } catch (e, stackTrace) {
      await _log.error('启动V2Ray失败', tag: _logTag, error: e, stackTrace: stackTrace);
      await stop();  // 确保清理
      return false;
    }
  }

  static Future<void> stop() async {
    await _log.info('开始停止V2Ray服务', tag: _logTag);
    
    // 停止流量统计定时器
    _stopStatsTimer();
    
    if (_v2rayProcess != null) {
      try {
        // 首先尝试优雅关闭（发送SIGTERM信号）
        await _log.debug('尝试优雅关闭V2Ray进程', tag: _logTag);
        _v2rayProcess!.kill(ProcessSignal.sigterm);
        
        // 等待进程结束，最多等待3秒
        bool processExited = false;
        for (int i = 0; i < 6; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          try {
            // 检查进程是否还在运行
            // 如果进程已经结束，exitCode会立即返回
            final exitCode = await _v2rayProcess!.exitCode.timeout(
              const Duration(milliseconds: 100),
              onTimeout: () => -1,
            );
            if (exitCode != -1) {
              processExited = true;
              await _log.info('V2Ray进程已优雅退出，退出码: $exitCode', tag: _logTag);
              break;
            }
          } catch (e) {
            // 进程还在运行
          }
        }
        
        // 如果进程还没有结束，强制终止
        if (!processExited) {
          await _log.warn('V2Ray进程未能优雅退出，强制终止', tag: _logTag);
          _v2rayProcess!.kill(ProcessSignal.sigkill);
        }
      } catch (e) {
        await _log.error('停止V2Ray进程时出错', tag: _logTag, error: e);
      } finally {
        _v2rayProcess = null;
        _isRunning = false;
      }
    }

    // 确保杀死可能残留的进程（根据平台选择方法）
    if (Platform.isWindows) {
      try {
        final result = await Process.run('taskkill', ['/F', '/IM', _v2rayExecutableName], 
          runInShell: true,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (result.exitCode == 0) {
          await _log.info('成功清理残留的V2Ray进程', tag: _logTag);
        }
      } catch (e) {
        await _log.error('清理V2Ray进程失败', tag: _logTag, error: e);
      }
    } else if (Platform.isLinux || Platform.isMacOS) {
      // Linux/macOS 使用 pkill
      try {
        final result = await Process.run('pkill', ['-f', _v2rayExecutableName], 
          runInShell: true,
        );
        if (result.exitCode == 0) {
          await _log.info('成功清理残留的V2Ray进程', tag: _logTag);
        }
      } catch (e) {
        // pkill 可能不存在，忽略错误
        await _log.debug('pkill命令执行失败，可能不存在', tag: _logTag);
      }
    } else if (Platform.isAndroid) {
      // Android: 使用 kill 命令（需要知道PID）
      // 注意：Android上通常不需要手动清理，因为进程在应用沙盒内
      await _log.debug('Android平台依赖系统管理进程生命周期', tag: _logTag);
    } else if (Platform.isIOS) {
      // iOS: 不支持手动杀进程，依赖系统管理
      await _log.debug('iOS平台不支持手动终止进程', tag: _logTag);
    }
    
    await _log.info('V2Ray服务已停止', tag: _logTag);
  }

  static bool get isRunning => _isRunning;
  
  // 启动流量统计定时器
  static void _startStatsTimer() {
    _stopStatsTimer(); // 确保没有重复的定时器
    
    // 延迟5秒后开始统计，确保V2Ray完全启动（与UI同步）
    Future.delayed(const Duration(seconds: 5), () {
      if (_isRunning) {
        _log.info('开始流量统计监控', tag: _logTag);
        
        // 立即执行一次
        _updateTrafficStatsFromAPI();
        
        // 每5秒更新一次，平衡性能和实时性
        _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          _updateTrafficStatsFromAPI();
        });
      }
    });
  }
  
  // 停止流量统计定时器
  static void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _log.debug('流量统计监控已停止', tag: _logTag);
  }
  
  // 从 V2Ray API 获取流量统计 - 修复版本
  static Future<void> _updateTrafficStatsFromAPI() async {
    if (!_isRunning) return;
    
    try {
      await _log.debug('开始更新流量统计', tag: _logTag);
      
      // 获取 v2ray 的路径
      final v2rayPath = await _getV2RayPath();
      final v2rayDir = path.dirname(v2rayPath);
      
      // 检查是否有 v2ctl（某些版本的V2Ray使用v2ctl来执行API命令）
      final v2ctlPath = path.join(v2rayDir, _v2ctlExecutableName);
      final hasV2ctl = await File(v2ctlPath).exists();
      
      await _log.debug('V2Ray目录: $v2rayDir', tag: _logTag);
      await _log.debug('$_v2ctlExecutableName 存在: $hasV2ctl', tag: _logTag);
      
      // 使用正确的可执行文件
      final apiExe = hasV2ctl ? v2ctlPath : v2rayPath;
      
      // Windows平台特殊处理命令参数
      List<String> apiCmd;
      if (Platform.isWindows && hasV2ctl) {
        // Windows下使用v2ctl时的特殊格式
        // 参考官方文档：Windows CMD需要四个引号来表示一个引号
        apiCmd = [
          'api',
          '--server=127.0.0.1:10085',
          'StatsService.QueryStats',
          '"pattern: """" reset: false"'  // Windows正确的引号格式
        ];
      } else if (hasV2ctl) {
        // 非Windows平台使用v2ctl
        apiCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.QueryStats', 'pattern: ""', 'reset: false'];
      } else {
        // 使用v2ray内置命令
        apiCmd = ['api', 'statsquery', '--server=127.0.0.1:10085'];
      }
      
      await _log.debug('执行API命令: $apiExe ${apiCmd.join(' ')}', tag: _logTag);
      
      // 使用 v2ray/v2ctl api 命令查询统计数据
      final result = await Process.run(
        apiExe,
        apiCmd,
        runInShell: true,
        workingDirectory: v2rayDir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      
      await _log.debug('API命令退出码: ${result.exitCode}', tag: _logTag);
      
      if (result.exitCode == 0) {
        // 解析统计数据
        final output = result.stdout.toString();
        await _log.debug('V2Ray统计输出: $output', tag: _logTag);
        _parseStatsOutput(output);
      } else {
        await _log.warn('获取流量统计失败: ${result.stderr}', tag: _logTag);
        await _log.debug('stdout: ${result.stdout}', tag: _logTag);
        
        // 如果statsquery失败，尝试使用不同的方法
        await _querySpecificStats();
      }
    } catch (e, stackTrace) {
      await _log.error('更新流量统计时出错', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 查询特定的统计项
  static Future<void> _querySpecificStats() async {
    if (!_isRunning) return;
    
    try {
      await _log.debug('尝试查询特定统计项', tag: _logTag);
      
      final v2rayPath = await _getV2RayPath();
      final v2rayDir = path.dirname(v2rayPath);
      
      // 检查是否有 v2ctl
      final v2ctlPath = path.join(v2rayDir, _v2ctlExecutableName);
      final hasV2ctl = await File(v2ctlPath).exists();
      final apiExe = hasV2ctl ? v2ctlPath : v2rayPath;
      
      // 查询入站流量统计
      final tags = ['socks', 'http', 'proxy'];
      int totalUplink = 0;
      int totalDownlink = 0;
      
      for (final tag in tags) {
        // 查询上行流量
        final uplinkName = 'inbound>>>$tag>>>traffic>>>uplink';
        List<String> uplinkCmd;
        
        if (Platform.isWindows && hasV2ctl) {
          // Windows特殊格式 - 使用四个引号表示一个引号
          uplinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', '"name: """"$uplinkName"""" reset: false"'];
        } else if (hasV2ctl) {
          uplinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', 'name: "$uplinkName"', 'reset: false'];
        } else {
          uplinkCmd = ['api', 'stats', '--server=127.0.0.1:10085', 'name: "$uplinkName"'];
        }
          
        final uplinkResult = await Process.run(
          apiExe,
          uplinkCmd,
          runInShell: true,
          workingDirectory: v2rayDir,
        );
        
        if (uplinkResult.exitCode == 0) {
          final match = RegExp(r'value:\s*(\d+)').firstMatch(uplinkResult.stdout.toString());
          if (match != null) {
            totalUplink += int.parse(match.group(1)!);
            await _log.debug('$uplinkName: ${match.group(1)}', tag: _logTag);
          }
        }
        
        // 查询下行流量
        final downlinkName = 'inbound>>>$tag>>>traffic>>>downlink';
        List<String> downlinkCmd;
        
        if (Platform.isWindows && hasV2ctl) {
          downlinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', '"name: """"$downlinkName"""" reset: false"'];
        } else if (hasV2ctl) {
          downlinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', 'name: "$downlinkName"', 'reset: false'];
        } else {
          downlinkCmd = ['api', 'stats', '--server=127.0.0.1:10085', 'name: "$downlinkName"'];
        }
          
        final downlinkResult = await Process.run(
          apiExe,
          downlinkCmd,
          runInShell: true,
          workingDirectory: v2rayDir,
        );
        
        if (downlinkResult.exitCode == 0) {
          final match = RegExp(r'value:\s*(\d+)').firstMatch(downlinkResult.stdout.toString());
          if (match != null) {
            totalDownlink += int.parse(match.group(1)!);
            await _log.debug('$downlinkName: ${match.group(1)}', tag: _logTag);
          }
        }
      }
      
      // 查询出站流量统计
      for (final tag in ['proxy', 'direct']) {
        // 查询上行流量
        final uplinkName = 'outbound>>>$tag>>>traffic>>>uplink';
        List<String> uplinkCmd;
        
        if (Platform.isWindows && hasV2ctl) {
          uplinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', '"name: """"$uplinkName"""" reset: false"'];
        } else if (hasV2ctl) {
          uplinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', 'name: "$uplinkName"', 'reset: false'];
        } else {
          uplinkCmd = ['api', 'stats', '--server=127.0.0.1:10085', 'name: "$uplinkName"'];
        }
          
        final uplinkResult = await Process.run(
          apiExe,
          uplinkCmd,
          runInShell: true,
          workingDirectory: v2rayDir,
        );
        
        if (uplinkResult.exitCode == 0) {
          final match = RegExp(r'value:\s*(\d+)').firstMatch(uplinkResult.stdout.toString());
          if (match != null) {
            totalUplink += int.parse(match.group(1)!);
            await _log.debug('$uplinkName: ${match.group(1)}', tag: _logTag);
          }
        }
        
        // 查询下行流量
        final downlinkName = 'outbound>>>$tag>>>traffic>>>downlink';
        List<String> downlinkCmd;
        
        if (Platform.isWindows && hasV2ctl) {
          downlinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', '"name: """"$downlinkName"""" reset: false"'];
        } else if (hasV2ctl) {
          downlinkCmd = ['api', '--server=127.0.0.1:10085', 'StatsService.GetStats', 'name: "$downlinkName"', 'reset: false'];
        } else {
          downlinkCmd = ['api', 'stats', '--server=127.0.0.1:10085', 'name: "$downlinkName"'];
        }
          
        final downlinkResult = await Process.run(
          apiExe,
          downlinkCmd,
          runInShell: true,
          workingDirectory: v2rayDir,
        );
        
        if (downlinkResult.exitCode == 0) {
          final match = RegExp(r'value:\s*(\d+)').firstMatch(downlinkResult.stdout.toString());
          if (match != null) {
            totalDownlink += int.parse(match.group(1)!);
            await _log.debug('$downlinkName: ${match.group(1)}', tag: _logTag);
          }
        }
      }
      
      // 更新统计数据
      final now = DateTime.now();
      final timeDiff = now.difference(_lastUpdateTime).inSeconds;
      
      if (timeDiff > 0 && (_uploadTotal > 0 || _downloadTotal > 0)) {
        _uploadSpeed = ((totalUplink - _uploadTotal) / timeDiff).round();
        _downloadSpeed = ((totalDownlink - _downloadTotal) / timeDiff).round();
        
        // 确保速度为非负数
        if (_uploadSpeed < 0) _uploadSpeed = 0;
        if (_downloadSpeed < 0) _downloadSpeed = 0;
      }
      
      _uploadTotal = totalUplink;
      _downloadTotal = totalDownlink;
      _lastUpdateTime = now;
      
      if (_uploadSpeed > 0 || _downloadSpeed > 0) {
        await _log.info('流量统计: 上传=${UIUtils.formatBytes(_uploadSpeed)}/s, 下载=${UIUtils.formatBytes(_downloadSpeed)}/s', tag: _logTag);
      }
    } catch (e, stackTrace) {
      await _log.error('查询特定统计项失败', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 解析流量统计输出
  static void _parseStatsOutput(String output) {
    try {
      _log.debug('开始解析流量统计输出，长度: ${output.length}', tag: _logTag);
      
      final now = DateTime.now();
      final timeDiff = now.difference(_lastUpdateTime).inSeconds;
      
      // 重置当前统计
      int currentUplink = 0;
      int currentDownlink = 0;
      
      // 解析输出
      // V2Ray 统计输出格式: stat: <name: "inbound>>>socks>>>traffic>>>uplink" value: 12345 >
      final lines = output.split('\n');
      int parsedCount = 0;
      
      for (final line in lines) {
        if (line.contains('stat:') && line.contains('>>>traffic>>>')) {
          // 提取统计名称和值
          final nameMatch = RegExp(r'name:\s*"([^"]+)"').firstMatch(line);
          final valueMatch = RegExp(r'value:\s*(\d+)').firstMatch(line);
          
          if (nameMatch != null && valueMatch != null) {
            final name = nameMatch.group(1)!;
            final value = int.parse(valueMatch.group(1)!);
            
            // 累加所有入站和出站的上行和下行流量
            if (name.contains('>>>uplink')) {
              currentUplink += value;
            } else if (name.contains('>>>downlink')) {
              currentDownlink += value;
            }
            
            parsedCount++;
            _log.debug('解析统计项: $name = $value', tag: _logTag);
          }
        }
      }
      
      _log.debug('共解析 $parsedCount 个统计项', tag: _logTag);
      
      // 计算速度（字节/秒）
      if (timeDiff > 0 && (_uploadTotal > 0 || _downloadTotal > 0)) {
        _uploadSpeed = ((currentUplink - _uploadTotal) / timeDiff).round();
        _downloadSpeed = ((currentDownlink - _downloadTotal) / timeDiff).round();
        
        // 确保速度为非负数
        if (_uploadSpeed < 0) _uploadSpeed = 0;
        if (_downloadSpeed < 0) _downloadSpeed = 0;
      }
      
      // 更新总量
      _uploadTotal = currentUplink;
      _downloadTotal = currentDownlink;
      _lastUpdateTime = now;
      
      _log.info('流量统计更新: 上传总量=${UIUtils.formatBytes(_uploadTotal)}, 下载总量=${UIUtils.formatBytes(_downloadTotal)}', tag: _logTag);
      _log.info('当前速度: 上传=${UIUtils.formatBytes(_uploadSpeed)}/s, 下载=${UIUtils.formatBytes(_downloadSpeed)}/s', tag: _logTag);
    } catch (e, stackTrace) {
      _log.error('解析流量统计失败', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 获取流量统计信息
  static Future<Map<String, int>> getTrafficStats() async {
    if (!_isRunning) {
      return {
        'uploadSpeed': 0,
        'downloadSpeed': 0,
        'uploadTotal': 0,
        'downloadTotal': 0,
      };
    }
    
    // 返回当前统计数据
    return {
      'uploadSpeed': _uploadSpeed,
      'downloadSpeed': _downloadSpeed,
      'uploadTotal': _uploadTotal,
      'downloadTotal': _downloadTotal,
    };
  }
}
