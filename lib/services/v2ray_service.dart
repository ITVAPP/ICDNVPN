import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;

class V2RayService {
  static Process? _v2rayProcess;
  static bool _isRunning = false;
  static Function? _onProcessExit; // 进程退出回调
  
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
    bool tunMode = false,   // TUN 模式
  }) async {
    print('v2ray print: generateConfig called with tunMode: $tunMode');
    serverPort = 443;//暂时写死443
    final v2rayPath = await _getV2RayPath();
    final configPath = path.join(
      path.dirname(v2rayPath),
      'config.json'
    );

    final inbounds = [];

    if (!tunMode) {
      inbounds.add({
        "port": localPort,
        "protocol": "socks",
        "settings": {
          "auth": "noauth",
          "udp": true
        }
      });
      inbounds.add({
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
          "allowTransparent": false
        }
      });
    } else {
      print('v2ray print: 开启TUN模式，tunMode值为: $tunMode');
      inbounds.add({
        "port": 7900,
        "protocol": "dokodemo-door",
        "settings": {
          "network": "tcp,udp",
          "followRedirect": true
        },
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls"],
          "routeOnly": false
        }
      });
    }

    final config = {
      "inbounds": inbounds,
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
    bool tunMode = false,
  }) async {
    print('v2ray print: start方法被调用，tunMode值为: $tunMode');
    if (_isRunning) {
      await stop();  // 确保先停止旧进程
    }

    try {
      // 检查端口是否可用
      if (!await isPortAvailable(7898) || !await isPortAvailable(7899)) {
        throw 'Port 7898 or 7899 is already in use';
      }

      // 生成配置文件
      await generateConfig(serverIp: serverIp, serverPort: serverPort, tunMode: tunMode);

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
      return true;
    } catch (e) {
      print('Failed to start V2Ray: $e');
      await stop();  // 确保清理
      return false;
    }
  }

  static Future<void> stop() async {
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
}