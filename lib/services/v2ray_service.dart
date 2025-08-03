import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart'; // 移动平台需要
import 'package:path/path.dart' as path;
import '../utils/ui_utils.dart';
import '../utils/log_service.dart';

/// V2Ray服务管理类
/// 
/// 支持的平台：
/// - Windows: v2ray.exe 放在程序目录/v2ray/下
/// - macOS/Linux: v2ray 优先使用系统路径，否则使用程序目录
/// - Android/iOS: 通过flutter_v2ray插件实现
class V2RayService {
  static Process? _v2rayProcess;
  static bool _isRunning = false;
  static Function? _onProcessExit; // 进程退出回调
  
  // 流量统计相关
  static int _uploadTotal = 0;
  static int _downloadTotal = 0;
  static Timer? _statsTimer;
  
  // 日志服务
  static final LogService _log = LogService.instance;
  static const String _logTag = 'V2RayService';
  
  // 移动平台通道
  static const MethodChannel _methodChannel = MethodChannel('flutter_v2ray');
  static const EventChannel _eventChannel = EventChannel('flutter_v2ray/status');
  static StreamSubscription? _statusSubscription;
  
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
    } else {
      // 移动平台不需要执行文件路径
      throw UnsupportedError('Mobile platforms use native integration');
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
      
      // 移动平台使用flutter_v2ray插件
      if (Platform.isAndroid || Platform.isIOS) {
        await _log.info('移动平台：初始化flutter_v2ray', tag: _logTag);
        
        // 设置流量监听
        _statusSubscription?.cancel();
        _statusSubscription = _eventChannel.receiveBroadcastStream().distinct().cast().listen((event) {
          if (event != null) {
            try {
              // flutter_v2ray的event格式：[duration, uploadSpeed, downloadSpeed, upload, download, state]
              _uploadTotal = int.parse(event[3].toString());
              _downloadTotal = int.parse(event[4].toString());
              
              _log.debug(
                '移动平台流量更新: 上传=${UIUtils.formatBytes(_uploadTotal)}, '
                '下载=${UIUtils.formatBytes(_downloadTotal)}',
                tag: _logTag
              );
            } catch (e) {
              _log.error('解析流量数据失败: $e', tag: _logTag);
            }
          }
        });
        
        // 初始化V2Ray
        await _methodChannel.invokeMethod('initializeV2Ray', {
          "notificationIconResourceType": "mipmap",
          "notificationIconResourceName": "ic_launcher",
        });
        
        // 生成配置
        final configMap = {
          "log": {"loglevel": "warning"},
          "stats": {},
          "api": {"tag": "api", "services": ["StatsService"]},
          "policy": {
            "system": {
              "statsOutboundDownlink": true,
              "statsOutboundUplink": true
            }
          },
          "inbounds": [
            {
              "tag": "socks",
              "port": 10808,
              "protocol": "socks",
              "settings": {"auth": "noauth", "udp": true}
            }
          ],
          "outbounds": [
            {
              "tag": "proxy",
              "protocol": "vless",
              "settings": {
                "vnext": [{
                  "address": serverIp,
                  "port": 443,
                  "users": [{
                    "id": "bc24baea-3e5c-4107-a231-416cf00504fe",
                    "encryption": "none"
                  }]
                }]
              },
              "streamSettings": {
                "network": "ws",
                "security": "tls",
                "tlsSettings": {
                  "serverName": "pages-vless-a9f.pages.dev"
                },
                "wsSettings": {
                  "path": "/",
                  "headers": {"Host": "pages-vless-a9f.pages.dev"}
                }
              }
            }
          ],
          "routing": {
            "rules": [
              {"type": "field", "inboundTag": ["api"], "outboundTag": "api"}
            ]
          }
        };
        
        // 启动V2Ray
        await _methodChannel.invokeMethod('startV2Ray', {
          "remark": "代理服务器",
          "config": jsonEncode(configMap),
          "blocked_apps": null,
          "bypass_subnets": null,
          "proxy_only": false,
          "notificationDisconnectButtonName": "断开",
          "notificationTitle": "V2Ray运行中",
        });
        
        _isRunning = true;
        await _log.info('移动平台：V2Ray启动成功', tag: _logTag);
        return true;
      }
      
      // 桌面平台原有逻辑
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
        // 停止流量统计
        _stopStatsTimer();
        // 调用进程退出回调
        if (_onProcessExit != null) {
          _onProcessExit!();
        }
      });

      _isRunning = true;
      await _log.info('V2Ray服务启动成功', tag: _logTag);
      
      // 重置流量统计
      _uploadTotal = 0;
      _downloadTotal = 0;
      
      // 启动流量统计定时器
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
    
    // 移动平台停止
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _methodChannel.invokeMethod('stopV2Ray');
        _statusSubscription?.cancel();
        _statusSubscription = null;
        _isRunning = false;
        await _log.info('移动平台：V2Ray已停止', tag: _logTag);
      } catch (e) {
        await _log.error('移动平台停止失败: $e', tag: _logTag);
      }
      return;
    }
    
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
        // 修复：不指定编码，让系统使用默认编码
        final result = await Process.run('taskkill', ['/F', '/IM', _v2rayExecutableName], 
          runInShell: true,
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
    }
    
    await _log.info('V2Ray服务已停止', tag: _logTag);
  }

  static bool get isRunning => _isRunning;
  
  // 启动流量统计定时器
  static void _startStatsTimer() {
    _stopStatsTimer(); // 确保没有重复的定时器
    
    // 移动平台通过EventChannel自动更新，不需要定时器
    if (Platform.isAndroid || Platform.isIOS) {
      _log.info('移动平台：流量统计通过EventChannel自动更新', tag: _logTag);
      return;
    }
    
    // 延迟5秒后开始统计，确保V2Ray完全启动
    Future.delayed(const Duration(seconds: 5), () {
      if (_isRunning) {
        _log.info('开始流量统计监控', tag: _logTag);
        
        // 立即执行一次
        _updateTrafficStatsFromAPI();
        
        // 每5秒更新一次
        _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          _updateTrafficStatsFromAPI();
        });
      }
    });
  }
  
  // 停止流量统计定时器
  static void _stopStatsTimer() {
    if (_statsTimer != null) {
      _statsTimer?.cancel();
      _statsTimer = null;
      _log.debug('流量统计监控已停止', tag: _logTag);
    }
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
      
      // 使用正确的命令参数格式
      List<String> apiCmd;
      Process result;
      
      if (hasV2ctl) {
        // v2ctl 使用标准格式
        apiCmd = [
          'api',
          '--server=127.0.0.1:10085',
          'StatsService.QueryStats',
          'pattern: "" reset: false'
        ];
        
        // 根据平台选择执行方式
        if (Platform.isWindows) {
          // Windows CMD 需要特殊处理
          await _log.debug('Windows平台：使用shell执行', tag: _logTag);
          
          // Windows下使用Process.run更稳定
          final processResult = await Process.run(
            apiExe,
            apiCmd,
            runInShell: true,  // 使用shell处理引号
            workingDirectory: v2rayDir,
            // 不指定编码，避免Windows编码问题
          );
          
          await _log.debug('API命令退出码: ${processResult.exitCode}', tag: _logTag);
          
          if (processResult.exitCode == 0) {
            // 修复关键点：智能处理输出类型
            String output;
            if (processResult.stdout is String) {
              // Windows使用shell时，stdout直接是String
              output = processResult.stdout as String;
              await _log.debug('输出类型: String', tag: _logTag);
            } else if (processResult.stdout is List<int>) {
              // 手动转换为UTF8
              output = utf8.decode(processResult.stdout as List<int>);
              await _log.debug('输出类型: List<int>', tag: _logTag);
            } else {
              output = processResult.stdout.toString();
              await _log.debug('输出类型: ${processResult.stdout.runtimeType}', tag: _logTag);
            }
            
            await _log.debug('V2Ray统计输出: $output', tag: _logTag);
            _parseStatsOutput(output);
          } else {
            // 同样处理错误输出
            String error;
            if (processResult.stderr is String) {
              error = processResult.stderr as String;
            } else if (processResult.stderr is List<int>) {
              error = utf8.decode(processResult.stderr as List<int>);
            } else {
              error = processResult.stderr.toString();
            }
            await _log.warn('获取流量统计失败: $error', tag: _logTag);
          }
        } else {
          // Linux/macOS 使用标准方式
          final processResult = await Process.run(
            apiExe,
            apiCmd,
            runInShell: false,
            workingDirectory: v2rayDir,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          
          await _log.debug('API命令退出码: ${processResult.exitCode}', tag: _logTag);
          
          if (processResult.exitCode == 0) {
            await _log.debug('V2Ray统计输出: ${processResult.stdout}', tag: _logTag);
            _parseStatsOutput(processResult.stdout.toString());
          } else {
            await _log.warn('获取流量统计失败: ${processResult.stderr}', tag: _logTag);
          }
        }
      } else {
        // 使用v2ray内置命令
        apiCmd = ['api', 'statsquery', '--server=127.0.0.1:10085'];
        
        final processResult = await Process.run(
          apiExe,
          apiCmd,
          runInShell: false,
          workingDirectory: v2rayDir,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        
        await _log.debug('API命令退出码: ${processResult.exitCode}', tag: _logTag);
        
        if (processResult.exitCode == 0) {
          await _log.debug('V2Ray统计输出: ${processResult.stdout}', tag: _logTag);
          _parseStatsOutput(processResult.stdout.toString());
        } else {
          await _log.warn('获取流量统计失败: ${processResult.stderr}', tag: _logTag);
        }
      }
    } catch (e, stackTrace) {
      await _log.error('更新流量统计时出错', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 解析流量统计输出
  static void _parseStatsOutput(String output) {
    try {
      _log.debug('开始解析流量统计输出，长度: ${output.length}', tag: _logTag);
      
      // 重置当前统计
      int currentUplink = 0;
      int currentDownlink = 0;
      int parsedCount = 0;
      
      // 分割成单个统计块
      final statBlocks = output.split('stat:');
      _log.debug('分割后得到 ${statBlocks.length} 个统计块', tag: _logTag);
      
      for (int i = 0; i < statBlocks.length; i++) {
        final block = statBlocks[i];
        if (block.trim().isEmpty) continue;
        
        _log.debug('处理第 $i 个统计块: $block', tag: _logTag);
        
        // 提取 name 和 value
        final nameMatch = RegExp(r'name:\s*"([^"]+)"').firstMatch(block);
        final valueMatch = RegExp(r'value:\s*(\d+)').firstMatch(block);
        
        if (nameMatch != null) {
          final name = nameMatch.group(1)!;
          final value = valueMatch != null ? int.parse(valueMatch.group(1)!) : 0;
          
          _log.debug('提取到: name="$name", value=$value', tag: _logTag);
          
          // 累加所有的 uplink 和 downlink
          if (name.contains('>>>traffic>>>')) {
            if (name.endsWith('>>>uplink')) {
              currentUplink += value;
              _log.debug('上行流量累加: +$value = $currentUplink', tag: _logTag);
            } else if (name.endsWith('>>>downlink')) {
              currentDownlink += value;
              _log.debug('下行流量累加: +$value = $currentDownlink', tag: _logTag);
            }
            parsedCount++;
          }
        } else {
          _log.debug('未能匹配到name，跳过此块', tag: _logTag);
        }
      }
      
      _log.debug('解析完成: 共解析 $parsedCount 个统计项', tag: _logTag);
      _log.debug('统计结果: 上传=$currentUplink, 下载=$currentDownlink', tag: _logTag);
      
      // 更新总量
      _uploadTotal = currentUplink;
      _downloadTotal = currentDownlink;
      
      _log.info('流量统计更新: 上传总量=${UIUtils.formatBytes(_uploadTotal)}, 下载总量=${UIUtils.formatBytes(_downloadTotal)}', tag: _logTag);
    } catch (e, stackTrace) {
      _log.error('解析流量统计失败', tag: _logTag, error: e, stackTrace: stackTrace);
    }
  }
  
  // 获取流量统计信息
  static Future<Map<String, int>> getTrafficStats() async {
    if (!_isRunning) {
      return {
        'uploadTotal': 0,
        'downloadTotal': 0,
      };
    }
    
    // 返回当前统计数据
    return {
      'uploadTotal': _uploadTotal,
      'downloadTotal': _downloadTotal,
    };
  }
}
