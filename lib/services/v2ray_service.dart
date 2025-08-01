import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as path;

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
  
  static Future<String> getExecutablePath(String executableName) async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final directory = path.dirname(exePath);
      return path.join(directory, executableName);
    }
    throw 'Unsupported platform';
  }
  
  static Future<String> _getV2RayPath() async {
    return getExecutablePath(path.join('v2ray', 'v2ray.exe'));
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
      "stats": {}, // 启用统计功能
      "api": {
        "tag": "api",
        "services": [
          "StatsService"
        ]
      },
      "policy": {
        "levels": {
          "0": {
            "statsUserUplink": true,
            "statsUserDownlink": true
          }
        },
        "system": {
          "statsInboundUplink": true,
          "statsInboundDownlink": true,
          "statsOutboundUplink": true,
          "statsOutboundDownlink": true
        }
      },
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
            "destOverride": [
              "http",
              "tls"
            ],
            "routeOnly": false
          },
          "settings": {
            "auth": "noauth",
            "udp": true,
            "allowTransparent": false,
            "userLevel": 0
          }
        },
        {
          "tag": "api",
          "port": 10085,
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
          {
            "type": "field",
            "inboundTag": [
              "api"
            ],
            "outboundTag": "api"
          },
          {
            "type": "field",
            "outboundTag": "direct",
            "domain": [
              "domain:example-example.com",
              "domain:example-example2.com",
              "domain:3o91888o77.vicp.fun"
            ]
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
  }

  static Future<bool> isPortAvailable(int port) async {
    try {
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
      // 检查端口是否可用
      if (!await isPortAvailable(7898) || !await isPortAvailable(7899)) {
        throw 'Port 7898 or 7899 is already in use';
      }

      // 生成配置文件
      await generateConfig(serverIp: serverIp, serverPort: serverPort);

      final v2rayPath = await _getV2RayPath();
      if (!await File(v2rayPath).exists()) {
        throw 'v2ray.exe not found at: $v2rayPath';
      }

      // 启动 v2ray 进程
      _v2rayProcess = await Process.start(
        v2rayPath,
        ['run'],
        workingDirectory: path.dirname(v2rayPath),
        runInShell: true  // 在shell中运行以获取更高权限
      );

      // 等待一段时间检查进程是否正常运行
      await Future.delayed(const Duration(seconds: 2));
      
      if (_v2rayProcess == null) {
        throw 'Failed to start V2Ray process';
      }

      // 监听进程输出
      _v2rayProcess!.stdout.transform(utf8.decoder).listen((data) {
        print('V2Ray stdout: $data');
        if (data.contains('failed to')) {
          _isRunning = false;
        }
      });

      _v2rayProcess!.stderr.transform(utf8.decoder).listen((data) {
        print('V2Ray stderr: $data');
      });

      // 监听进程退出
      _v2rayProcess!.exitCode.then((code) {
        print('V2Ray process exited with code: $code');
        _isRunning = false;
        // 调用进程退出回调
        if (_onProcessExit != null) {
          _onProcessExit!();
        }
      });

      _isRunning = true;
      
      // 重置流量统计
      _uploadSpeed = 0;
      _downloadSpeed = 0;
      _uploadTotal = 0;
      _downloadTotal = 0;
      _lastUpdateTime = DateTime.now();
      
      // 启动流量统计定时器（每2分钟读取一次）
      _startStatsTimer();
      
      return true;
    } catch (e) {
      print('Failed to start V2Ray: $e');
      await stop();  // 确保清理
      return false;
    }
  }

  static Future<void> stop() async {
    // 停止流量统计定时器
    _stopStatsTimer();
    
    if (_v2rayProcess != null) {
      try {
        // 首先尝试优雅关闭（发送SIGTERM信号）
        print('Attempting graceful shutdown of V2Ray...');
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
              print('V2Ray process exited gracefully with code: $exitCode');
              break;
            }
          } catch (e) {
            // 进程还在运行
          }
        }
        
        // 如果进程还没有结束，强制终止
        if (!processExited) {
          print('Force killing V2Ray process...');
          _v2rayProcess!.kill(ProcessSignal.sigkill);
        }
      } catch (e) {
        print('Error stopping V2Ray: $e');
      } finally {
        _v2rayProcess = null;
        _isRunning = false;
      }
    }

    // 确保杀死可能残留的进程
    if (Platform.isWindows) {
      try {
        final result = await Process.run('taskkill', ['/F', '/IM', 'v2ray.exe'], 
          runInShell: true,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (result.exitCode == 0) {
          print('Successfully killed remaining V2Ray processes');
        }
      } catch (e) {
        print('Error killing V2Ray process: $e');
      }
    }
  }

  static bool get isRunning => _isRunning;
  
  // 启动流量统计定时器
  static void _startStatsTimer() {
    _stopStatsTimer(); // 确保没有重复的定时器
    
    // 立即执行一次
    _updateTrafficStatsFromAPI();
    
    // 每2分钟更新一次
    _statsTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      _updateTrafficStatsFromAPI();
    });
  }
  
  // 停止流量统计定时器
  static void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }
  
  // 从 V2Ray API 获取流量统计
  static Future<void> _updateTrafficStatsFromAPI() async {
    if (!_isRunning) return;
    
    try {
      // 获取 v2ray.exe 的路径
      final v2rayPath = await _getV2RayPath();
      final v2rayDir = path.dirname(v2rayPath);
      final v2ctlPath = path.join(v2rayDir, 'v2ctl.exe');
      
      // 检查 v2ctl.exe 是否存在，如果不存在则使用 v2ray.exe
      final executable = await File(v2ctlPath).exists() ? v2ctlPath : v2rayPath;
      
      // 使用 v2ray/v2ctl api 命令查询统计数据
      final result = await Process.run(
        executable,
        ['api', 'statsquery', '--server=127.0.0.1:10085'],
        runInShell: true,
        workingDirectory: v2rayDir,
      );
      
      if (result.exitCode == 0) {
        // 解析统计数据
        final output = result.stdout.toString();
        _parseStatsOutput(output);
      } else {
        print('获取流量统计失败: ${result.stderr}');
        // 如果 API 调用失败，尝试备用方法
        await _updateTrafficStatsFromAlternativeMethod();
      }
    } catch (e) {
      print('更新流量统计时出错: $e');
    }
  }
  
  // 备用方法：通过 HTTP API 获取流量统计
  static Future<void> _updateTrafficStatsFromAlternativeMethod() async {
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 2);
      
      // 尝试通过 HTTP 请求获取统计信息
      final request = await httpClient.post(
        '127.0.0.1',
        10085,
        '/v1/stats/query',
      );
      
      // 发送空的查询体以获取所有统计数据
      request.write('{"pattern": "", "reset": false}');
      
      final response = await request.close();
      
      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        // 解析 JSON 格式的响应
        _parseJSONStatsResponse(responseBody);
      }
      
      httpClient.close();
    } catch (e) {
      print('备用方法获取流量统计失败: $e');
    }
  }
  
  // 解析 v2ray api statsquery 的输出
  static void _parseStatsOutput(String output) {
    try {
      final lines = output.split('\n');
      int totalUplink = 0;
      int totalDownlink = 0;
      
      for (final line in lines) {
        // 查找格式如: "inbound>>>http>>>traffic>>>uplink" value: 12345
        if (line.contains('>>>traffic>>>')) {
          final match = RegExp(r'value:\s*(\d+)').firstMatch(line);
          if (match != null) {
            final value = int.parse(match.group(1)!);
            
            if (line.contains('>>>uplink')) {
              totalUplink += value;
            } else if (line.contains('>>>downlink')) {
              totalDownlink += value;
            }
          }
        }
      }
      
      // 计算速度
      final now = DateTime.now();
      final timeDiff = now.difference(_lastUpdateTime).inSeconds;
      
      if (timeDiff > 0) {
        _uploadSpeed = ((totalUplink - _uploadTotal) / timeDiff).round();
        _downloadSpeed = ((totalDownlink - _downloadTotal) / timeDiff).round();
        
        // 确保速度为非负数
        if (_uploadSpeed < 0) _uploadSpeed = 0;
        if (_downloadSpeed < 0) _downloadSpeed = 0;
      }
      
      _uploadTotal = totalUplink;
      _downloadTotal = totalDownlink;
      _lastUpdateTime = now;
      
      print('流量统计更新: 上传=${_formatBytes(_uploadTotal)}, 下载=${_formatBytes(_downloadTotal)}');
    } catch (e) {
      print('解析流量统计输出失败: $e');
    }
  }
  
  // 解析 JSON 格式的统计响应
  static void _parseJSONStatsResponse(String jsonStr) {
    try {
      final data = json.decode(jsonStr);
      int totalUplink = 0;
      int totalDownlink = 0;
      
      if (data['stat'] != null) {
        for (final stat in data['stat']) {
          final name = stat['name'] as String;
          final value = stat['value'] as int;
          
          if (name.contains('>>>traffic>>>')) {
            if (name.contains('>>>uplink')) {
              totalUplink += value;
            } else if (name.contains('>>>downlink')) {
              totalDownlink += value;
            }
          }
        }
      }
      
      // 计算速度
      final now = DateTime.now();
      final timeDiff = now.difference(_lastUpdateTime).inSeconds;
      
      if (timeDiff > 0) {
        _uploadSpeed = ((totalUplink - _uploadTotal) / timeDiff).round();
        _downloadSpeed = ((totalDownlink - _downloadTotal) / timeDiff).round();
        
        // 确保速度为非负数
        if (_uploadSpeed < 0) _uploadSpeed = 0;
        if (_downloadSpeed < 0) _downloadSpeed = 0;
      }
      
      _uploadTotal = totalUplink;
      _downloadTotal = totalDownlink;
      _lastUpdateTime = now;
    } catch (e) {
      print('解析 JSON 统计响应失败: $e');
    }
  }
  
  // 格式化字节数
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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