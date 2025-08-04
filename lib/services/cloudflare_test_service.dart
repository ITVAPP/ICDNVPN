import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';
import '../utils/log_service.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';

class CloudflareTestService {
  // 日志标签
  static const String _logTag = 'CloudflareTest';
  
  // 获取日志服务实例
  static LogService get _log => LogService.instance;
  
  // 添加缺失的常量定义
  static const int _defaultPort = 443; // HTTPS 标准端口
  static const int _httpPort = 80; // HTTP 端口（HTTPing使用）
  static const Duration _tcpTimeout = Duration(seconds: 1); // TCP连接超时时间
  
  // 下载测试相关常量 - 使用HTTP协议避免证书问题
  static const String _downloadTestUrl = 'http://speed.cloudflare.com/__down?bytes=2000000'; // 2MB，使用HTTP
  static const Duration _downloadTimeout = Duration(seconds: 3); // 优化为3秒
  static const int _bufferSize = 65536; // 修改：从1KB提升到64KB，提高下载性能
  
  // HTTPing 模式相关配置
  static bool httping = false; // 是否启用 HTTPing 模式
  static int httpingStatusCode = 0; // 指定的 HTTP 状态码（0表示默认）
  
  // 过滤条件
  static double maxLossRate = 1.0; // 丢包率上限（默认100%）
  static double minDownloadSpeed = 0.0; // 下载速度下限（MB/s）
  
  // 诊断模式控制
  static bool _enableDiagnosis = false; // 是否启用诊断模式
  static int _diagnosisCount = 0; // 已诊断的IP数量
  static const int _maxDiagnosisCount = 3; // 最多诊断的IP数量
  
  // Cloudflare 官方 IP 段（2025年最新版本）- 直接定义为静态常量
  static const List<String> _cloudflareIpRanges = [
    '173.245.48.0/20',
    '103.21.244.0/22',
    '103.22.200.0/22',
    '103.31.4.0/22',
    '141.101.64.0/18',
    '108.162.192.0/18',
    '190.93.240.0/20',
    '188.114.96.0/20',
    '197.234.240.0/22',
    '198.41.128.0/17',
    '162.158.0.0/15',
    '104.16.0.0/12',
    '172.64.0.0/17',
    '172.64.128.0/18',
    '172.64.192.0/19',
    '172.64.224.0/22',
    '172.64.229.0/24',
    '172.64.230.0/23',
    '172.64.232.0/21',
    '172.64.240.0/21',
    '172.64.248.0/21',
    '172.65.0.0/16',
    '172.66.0.0/16',
    '172.67.0.0/16',
    '131.0.72.0/22',
  ];
  
  // 获取真实的本地IP地址
  static Future<String> _getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: true,
      );
      
      // 按优先级查找网络接口
      // 1. 首先查找WiFi接口
      for (final interface in interfaces) {
        if (interface.name.toLowerCase().contains('wlan') || 
            interface.name.toLowerCase().contains('wifi') ||
            interface.name.toLowerCase().contains('en0')) { // iOS WiFi
          for (final addr in interface.addresses) {
            if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
              await _log.info('找到WiFi接口本地IP: ${addr.address}', tag: _logTag);
              return addr.address;
            }
          }
        }
      }
      
      // 2. 查找以太网接口
      for (final interface in interfaces) {
        if (interface.name.toLowerCase().contains('eth') ||
            interface.name.toLowerCase().contains('en')) {
          for (final addr in interface.addresses) {
            if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
              await _log.info('找到以太网接口本地IP: ${addr.address}', tag: _logTag);
              return addr.address;
            }
          }
        }
      }
      
      // 3. 查找任何非回环接口
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && 
              addr.type == InternetAddressType.IPv4 &&
              !addr.address.startsWith('169.254')) { // 排除链路本地地址
            await _log.info('找到其他接口本地IP: ${addr.address}', tag: _logTag);
            return addr.address;
          }
        }
      }
      
      return '未知';
    } catch (e) {
      await _log.error('获取本地IP失败: $e', tag: _logTag);
      return '未知';
    }
  }
  
  // TCP连接诊断方法（修复版）
  static Future<void> _diagnoseTcpConnection(String ip, int port) async {
    await _log.info('\n=== TCP 连接诊断 ===', tag: _logTag);
    await _log.info('目标: $ip:$port', tag: _logTag);
    
    try {
      // 测试1：基础连接时间
      final sw1 = Stopwatch()..start();
      final socket = await Socket.connect(
        ip, 
        port,
        timeout: const Duration(seconds: 5), // 诊断时使用较长超时
      );
      sw1.stop();
      await _log.info('1. Socket.connect 返回: ${sw1.elapsedMilliseconds}ms', tag: _logTag);
      
      // 测试2：检查连接属性（修复版）
      try {
        // 获取真实的本地IP
        final realLocalIp = await _getLocalIpAddress();
        await _log.info('2. 真实本地地址: $realLocalIp:${socket.port}', tag: _logTag);
        
        // 显示socket返回的地址（可能有bug）
        await _log.warn('   socket.address返回: ${socket.address.address} (这是Flutter的bug)', tag: _logTag);
        
        // 远程地址
        await _log.info('3. 远程地址: ${socket.remoteAddress.address}:${socket.remotePort}', tag: _logTag);
        
        // 检测bug情况
        if (socket.address.address == socket.remoteAddress.address) {
          await _log.error('⚠️ 检测到Flutter Socket bug: 本地地址与远程地址相同！', tag: _logTag);
        }
      } catch (e) {
        await _log.warn('获取地址失败: $e', tag: _logTag);
      }
      
      // 测试3：发送1字节并flush
      final sw2 = Stopwatch()..start();
      socket.add([0x00]);
      await socket.flush();
      sw2.stop();
      await _log.info('4. 发送1字节+flush: ${sw2.elapsedMilliseconds}ms', tag: _logTag);
      
      // 测试4：检测连接真实性
      bool isRealConnection = false;
      try {
        // 尝试获取远程端口，如果失败说明连接可能是假的
        final remotePort = socket.remotePort;
        if (remotePort == port) {
          isRealConnection = true;
        }
      } catch (e) {
        await _log.error('获取远程端口失败，连接可能是假的: $e', tag: _logTag);
      }
      
      // 测试5：等待任何响应（100ms超时）
      final sw3 = Stopwatch()..start();
      final completer = Completer<String>();
      socket.listen(
        (data) => completer.complete('收到${data.length}字节'),
        onError: (e) => completer.complete('错误: $e'),
        onDone: () => completer.complete('连接关闭'),
      );
      
      final result = await completer.future.timeout(
        const Duration(milliseconds: 100),
        onTimeout: () => '100ms内无响应',
      );
      sw3.stop();
      await _log.info('5. 等待响应: ${sw3.elapsedMilliseconds}ms - $result', tag: _logTag);
      
      // 测试6：诊断结论
      await _log.info('6. 诊断结论:', tag: _logTag);
      if (!isRealConnection) {
        await _log.error('   - 连接可能是假的或被拦截', tag: _logTag);
      }
      if (sw1.elapsedMilliseconds < 5) {
        await _log.warn('   - 连接时间异常快(<5ms)，可能连接到本地代理', tag: _logTag);
      }
      if (result.contains('无响应')) {
        await _log.warn('   - 服务器未响应，可能端口错误或被防火墙阻止', tag: _logTag);
      }
      
      socket.destroy();
      await _log.info('=== 诊断完成 ===\n', tag: _logTag);
    } catch (e) {
      await _log.error('诊断过程出错: $e', tag: _logTag);
      await _log.info('=== 诊断异常结束 ===\n', tag: _logTag);
    }
  }
  
  // 统一的测速方法（合并单独测速和批量测试）
  static Future<List<Map<String, dynamic>>> testLatencyUnified({
    required List<String> ips,
    int? port,
    bool singleTest = false,  // 是否单个测试
    bool useHttping = false,  // 是否使用HTTPing
    Function(int current, int total)? onProgress,  // 进度回调
    int maxLatency = 300,  // 最大延迟，用于优化超时设置
  }) async {
    // HTTPing模式强制使用80端口，避免证书问题
    final testPort = port ?? (useHttping ? _httpPort : _defaultPort);
    final results = <Map<String, dynamic>>[];
    
    if (ips.isEmpty) {
      await _log.warn('没有IP需要测试', tag: _logTag);
      return results;
    }
    
    await _log.info('开始${useHttping ? "HTTPing" : "TCPing"}测试 ${ips.length} 个IP，端口: $testPort', tag: _logTag);
    
    // 单个测试时不需要批处理，批量测试时根据maxLatency动态调整并发数
    final batchSize = singleTest ? 1 : math.min(20, math.max(5, 1000 ~/ maxLatency));
    await _log.debug('批处理大小: $batchSize (基于maxLatency: ${maxLatency}ms)', tag: _logTag);
    int successCount = 0;
    int failCount = 0;
    int tested = 0;
    
    for (int i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize).toList();
      final futures = <Future>[];
      
      await _log.debug('测试批次 ${(i / batchSize).floor() + 1}/${((ips.length - 1) / batchSize).floor() + 1}，包含 ${batch.length} 个IP', tag: _logTag);
      
      for (final ip in batch) {
        final testMethod = useHttping 
            ? _testSingleHttping(ip, testPort, maxLatency)
            : _testSingleIpLatencyWithLossRate(ip, testPort, maxLatency);
            
        futures.add(testMethod.then((result) {
          results.add(result);
          tested++;
          
          final latency = result['latency'] as int;
          final lossRate = result['lossRate'] as double;
          
          if (latency > 0 && latency < 999 && lossRate < 1.0) {
            successCount++;
            _log.debug('✓ IP $ip 延迟: ${latency}ms, 丢包率: ${(lossRate * 100).toStringAsFixed(2)}%', tag: _logTag);
          } else {
            failCount++;
          }
          
          // 进度回调
          onProgress?.call(tested, ips.length);
          
        }).catchError((e) {
          failCount++;
          tested++;
          results.add({
            'ip': ip,
            'latency': 999,
            'lossRate': 1.0,
            'colo': '',
          });
          _log.debug('× IP $ip 测试异常: $e', tag: _logTag);
          
          // 进度回调
          onProgress?.call(tested, ips.length);
          return null;
        }));
      }
      
      await Future.wait(futures);
      
      // 单个测试完成后立即返回
      if (singleTest) break;
      
      // 如果已经找到足够的低延迟节点，可以提前结束
      final goodNodes = results.where((r) => r['latency'] < 300 && r['lossRate'] < 0.1).length;
      if (goodNodes >= 10) {
        await _log.info('已找到 $goodNodes 个优质节点（<300ms，丢包率<10%），提前结束测试', tag: _logTag);
        break;
      }
    }
    
    await _log.info('延迟测试完成，成功测试 ${results.length} 个IP（成功: $successCount，失败: $failCount）', tag: _logTag);
    
    return results;
  }
  
  // HTTPing 模式测试单个IP（优化版：单一超时控制，成功即返回）
  static Future<Map<String, dynamic>> _testSingleHttping(String ip, int port, [int maxLatency = 300]) async {
    await _log.debug('[HTTPing] 开始测试 $ip:$port (超时: ${maxLatency}ms)', tag: _logTag);
    
    const int maxAttempts = 3;  // 最大尝试次数
    int attempts = 0;
    int successLatency = 0;
    
    final httpClient = HttpClient();
    // 使用单一超时控制
    httpClient.connectionTimeout = Duration(milliseconds: maxLatency);
    await _log.debug('[HTTPing] 连接超时设置: ${maxLatency}ms', tag: _logTag);
    
    // HTTPing 强制使用 HTTP 协议（80端口），避免证书问题
    if (port != 80 && port != _httpPort) {
      await _log.warn('[HTTPing] 警告：HTTPing模式应使用80端口，当前端口: $port', tag: _logTag);
    }
    
    // 最多尝试3次，但成功一次就足够
    for (int i = 0; i < maxAttempts; i++) {
      attempts++;
      
      try {
        // HTTPing始终使用HTTP协议
        final uri = Uri(
          scheme: 'http',
          host: ip,
          port: port,
          path: '/cdn-cgi/trace',  // 使用官方诊断端点
        );
        
        await _log.debug('[HTTPing] 尝试 ${i + 1}/$maxAttempts: GET $uri', tag: _logTag);
        
        final stopwatch = Stopwatch()..start();
        
        // 使用GET请求（trace端点需要GET请求）
        final request = await httpClient.getUrl(uri);
        request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
        request.headers.set('Accept', 'text/plain');
        request.headers.set('Connection', 'close');
        
        final connectTime = stopwatch.elapsedMilliseconds;
        await _log.debug('[HTTPing] 连接成功，耗时: ${connectTime}ms', tag: _logTag);
        
        // 计算剩余时间
        final remainingTime = maxLatency - connectTime;
        
        if (remainingTime <= 10) {
          await _log.debug('[HTTPing] 剩余时间不足，跳过响应等待', tag: _logTag);
          request.close(); // 关闭请求
          continue; // 尝试下一次
        }
        
        await _log.debug('[HTTPing] 发送请求，等待响应（剩余时间: ${remainingTime}ms）', tag: _logTag);
        
        // 发送请求并获取响应流
        final responseStream = await request.close();
        
        // 创建completer等待第一个字节
        final completer = Completer<void>();
        bool receivedData = false;
        int statusCode = 0;
        
        // 监听响应流
        StreamSubscription? subscription;
        subscription = responseStream.listen(
          (data) {
            if (!receivedData && data.isNotEmpty) {
              receivedData = true;
              stopwatch.stop();  // 收到第一个字节就停止计时
              statusCode = responseStream.statusCode;
              _log.debug('[HTTPing] 收到响应，状态码: $statusCode', tag: _logTag);
              
              // 立即检查状态码
              if (httpingStatusCode == 0) {
                // 默认只接受 200
                if (statusCode == 200) {
                  if (!completer.isCompleted) {
                    completer.complete();
                  }
                } else {
                  // 非200状态码，立即失败
                  if (!completer.isCompleted) {
                    completer.completeError('无效状态码: $statusCode');
                  }
                }
              } else {
                // 检查指定的状态码
                if (statusCode == httpingStatusCode) {
                  if (!completer.isCompleted) {
                    completer.complete();
                  }
                } else {
                  if (!completer.isCompleted) {
                    completer.completeError('状态码不匹配: $statusCode != $httpingStatusCode');
                  }
                }
              }
              
              subscription?.cancel();
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.completeError('连接关闭，未收到数据');
            }
          },
          onError: (e) {
            if (!completer.isCompleted) {
              completer.completeError(e);
            }
          },
          cancelOnError: true,
        );
        
        // 等待第一个字节或超时
        await completer.future.timeout(
          Duration(milliseconds: remainingTime),
          onTimeout: () {
            subscription?.cancel();
            throw TimeoutException('HTTP响应超时');
          },
        );
        
        final latency = stopwatch.elapsedMilliseconds;
        await _log.debug('[HTTPing] 成功，延迟: ${latency}ms', tag: _logTag);
        
        // 消费剩余的响应数据（避免连接泄漏）
        responseStream.listen((_) {}).cancel();
        
        // 验证延迟值并记录
        if (latency > 0 && latency < maxLatency) {
          successLatency = latency;
          await _log.info('[HTTPing] 测试成功，延迟: ${latency}ms，立即返回结果', tag: _logTag);
          break;  // 成功一次就足够，立即退出循环
        } else {
          await _log.warn('[HTTPing] 延迟异常: ${latency}ms', tag: _logTag);
        }
        
      } catch (e) {
        // 统一的错误日志处理
        String errorDetail = '';
        if (e is SocketException) {
          errorDetail = '网络错误: ${e.message}';
        } else if (e is TimeoutException) {
          errorDetail = '请求超时';
        } else if (e is HttpException) {
          errorDetail = 'HTTP错误: ${e.message}';
        } else if (e.toString().contains('状态码')) {
          errorDetail = e.toString();
        } else {
          errorDetail = '未知错误: $e';
        }
        
        await _log.debug('[HTTPing] 尝试 ${i + 1} 失败: $errorDetail', tag: _logTag);
      }
      
      // 测试间隔（除非是最后一次）
      if (i < maxAttempts - 1) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    
    httpClient.close();
    
    // 计算结果
    final success = successLatency > 0;
    final avgLatency = success ? successLatency : 999;
    final lossRate = success ? 0.0 : 1.0;
    
    await _log.info('[HTTPing] 完成 $ip - 平均延迟: ${avgLatency}ms, 丢包率: ${(lossRate * 100).toStringAsFixed(1)}%, 尝试次数: $attempts', tag: _logTag);
    
    return {
      'ip': ip,
      'latency': avgLatency,
      'lossRate': lossRate,
      'sent': attempts,
      'received': success ? 1 : 0,
      'colo': '',  // 统一返回空，让上层使用_detectLocationFromIp
    };
  }
  
  // 保持原有的公共接口以兼容旧代码
  static Future<Map<String, int>> testLatency(List<String> ips, [int? port, int maxLatency = 300]) async {
    // 根据当前是否启用 HTTPing 来决定使用的端口
    final actualPort = port ?? (httping ? _httpPort : _defaultPort);
    
    final results = await testLatencyUnified(
      ips: ips,
      port: actualPort,
      useHttping: httping,
      maxLatency: maxLatency,
    );
    final latencyMap = <String, int>{};
    
    for (final result in results) {
      latencyMap[result['ip']] = result['latency'];
    }
    
    return latencyMap;
  }
  
  // 测试进度数据类 - 使用 StreamController 替代 async*
  static Stream<TestProgress> testServersWithProgress({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'AUTO',
    bool useHttping = false,
    double? lossRateLimit,
    double? speedLimit,
  }) {
    final controller = StreamController<TestProgress>();
    
    // 在后台执行测试
    executeTestWithProgress(
      controller: controller,
      count: count,
      maxLatency: maxLatency,
      speed: speed,
      testCount: testCount,
      location: location,
      useHttping: useHttping,
      lossRateLimit: lossRateLimit,
      speedLimit: speedLimit,
    );
    
    return controller.stream;
  }
  
  // Cloudflare连接验证
  static Future<void> _verifyCloudflareConnection() async {
    await _log.info('\n=== Cloudflare连接验证 ===', tag: _logTag);
    
    try {
      // 测试1：DNS解析
      await _log.info('1. DNS解析测试:', tag: _logTag);
      try {
        final addresses = await InternetAddress.lookup('cloudflare.com');
        for (final addr in addresses) {
          await _log.info('   - cloudflare.com -> ${addr.address} (${addr.type.name})', tag: _logTag);
        }
      } catch (e) {
        await _log.error('   DNS解析失败: $e', tag: _logTag);
      }
      
      // 测试2：HTTP请求测试
      await _log.info('2. HTTP请求测试:', tag: _logTag);
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 5);
      
      try {
        final uri = Uri.parse('http://1.1.1.1/cdn-cgi/trace');
        final request = await httpClient.getUrl(uri);
        final response = await request.close();
        await _log.info('   - 状态码: ${response.statusCode}', tag: _logTag);
        
        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          final lines = responseBody.split('\n').take(3);
          for (final line in lines) {
            if (line.isNotEmpty) {
              await _log.info('   - $line', tag: _logTag);
            }
          }
        }
      } catch (e) {
        await _log.error('   HTTP请求失败: $e', tag: _logTag);
      } finally {
        httpClient.close();
      }
      
      await _log.info('=== 验证完成 ===\n', tag: _logTag);
    } catch (e) {
      await _log.error('验证过程出错: $e', tag: _logTag);
    }
  }
  
  // 实际执行测试的方法 - 改为公共方法
  static Future<void> executeTestWithProgress({
    required StreamController<TestProgress> controller,
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'AUTO',
    bool useHttping = false,
    double? lossRateLimit,
    double? speedLimit,
  }) async {
    try {
      // 设置测试参数
      httping = useHttping;
      if (lossRateLimit != null) maxLossRate = lossRateLimit;
      if (speedLimit != null) minDownloadSpeed = speedLimit;
      
      // 重置诊断计数器
      _diagnosisCount = 0;
      _enableDiagnosis = false;
      
      await _log.info('=== 开始测试 Cloudflare 节点 ===', tag: _logTag);
      await _log.info('参数: count=$count, maxLatency=$maxLatency, speed=$speed, testCount=$testCount, location=$location', tag: _logTag);
      await _log.info('模式: ${httping ? "HTTPing" : "TCPing"}, 丢包率上限: ${(maxLossRate * 100).toStringAsFixed(1)}%, 下载速度下限: ${minDownloadSpeed.toStringAsFixed(1)}MB/s', tag: _logTag);
      
      // 首先验证Cloudflare连接
      await _verifyCloudflareConnection();
      
      // 定义测试端口 - HTTPing使用80端口，TCPing测试443端口但下载使用80端口
      final int testPort = httping ? _httpPort : _defaultPort;
      final int downloadPort = _httpPort; // 下载始终使用80端口
      await _log.info('测试端口: $testPort (延迟测试), $downloadPort (下载测试)', tag: _logTag);
      
      // 显示使用的IP段
      await _log.debug('Cloudflare IP段列表:', tag: _logTag);
      for (var i = 0; i < _cloudflareIpRanges.length; i++) {
        await _log.debug('  ${i + 1}. ${_cloudflareIpRanges[i]}', tag: _logTag);
      }
      
      // 总步骤数
      const totalSteps = 5;
      var currentStep = 0;
      
      // 步骤1：准备阶段
      controller.add(TestProgress(
        step: ++currentStep,
        totalSteps: totalSteps,
        messageKey: 'preparingTestEnvironment',
        detailKey: 'initializing',
        progress: currentStep / totalSteps,
      ));
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      // 步骤2：IP采样
      controller.add(TestProgress(
        step: ++currentStep,
        totalSteps: totalSteps,
        messageKey: 'generatingTestIPs',
        detailKey: 'ipRanges',
        detailParams: {'count': _cloudflareIpRanges.length},
        progress: currentStep / totalSteps,
      ));
      
      await _log.info('目标采样数量: $testCount', tag: _logTag);
      
      final sampleIps = await _sampleIpsFromRanges(testCount);
      await _log.info('从 IP 段中采样了 ${sampleIps.length} 个 IP', tag: _logTag);
      
      if (sampleIps.isEmpty) {
        await _log.error('无法生成采样IP', tag: _logTag);
        throw TestException(
          messageKey: 'testFailed',
          detailKey: 'noQualifiedNodes',
        );
      }
      
      // 记录前10个采样IP作为示例
      if (sampleIps.isNotEmpty) {
        final examples = sampleIps.take(10).join(', ');
        await _log.debug('采样IP示例: $examples', tag: _logTag);
      }
      
      // 步骤3：延迟测速（带子进度）
      currentStep++;
      controller.add(TestProgress(
        step: currentStep,
        totalSteps: totalSteps,
        messageKey: 'testingDelay',
        detailKey: 'nodeProgress',
        detailParams: {'current': 0, 'total': sampleIps.length},
        progress: currentStep / totalSteps,
        subProgress: 0.0,
      ));
      
      await _log.info('开始${httping ? "HTTPing" : "TCPing"}延迟测速...', tag: _logTag);
      final pingResults = await testLatencyUnified(
        ips: sampleIps,
        port: testPort,
        useHttping: httping,
        maxLatency: maxLatency,  // 传递maxLatency参数
        onProgress: (current, total) {
          controller.add(TestProgress(
            step: currentStep,
            totalSteps: totalSteps,
            messageKey: 'testingDelay',
            detailKey: 'nodeProgress',
            detailParams: {'current': current, 'total': total},
            progress: (currentStep - 1 + current / total) / totalSteps,
            subProgress: current / total,
          ));
        },
      );
      await _log.info('延迟测速完成，获得 ${pingResults.length} 个结果', tag: _logTag);
      
      // 统计延迟分布
      final latencyStats = <String, int>{};
      int totalFailures = 0;
      int fakeConnections = 0;
      for (final result in pingResults) {
        final latency = result['latency'] as int;
        final lossRate = result['lossRate'] as double;
        final isFake = result['fakeConnection'] ?? false;
        
        if (isFake) {
          fakeConnections++;
          totalFailures++;
          latencyStats['假连接'] = (latencyStats['假连接'] ?? 0) + 1;
        } else if (lossRate >= 1.0) {
          latencyStats['失败'] = (latencyStats['失败'] ?? 0) + 1;
          totalFailures++;
        } else if (latency < 100) {
          latencyStats['<100ms'] = (latencyStats['<100ms'] ?? 0) + 1;
        } else if (latency < 200) {
          latencyStats['100-200ms'] = (latencyStats['100-200ms'] ?? 0) + 1;
        } else if (latency < 300) {
          latencyStats['200-300ms'] = (latencyStats['200-300ms'] ?? 0) + 1;
        } else if (latency < 500) {
          latencyStats['300-500ms'] = (latencyStats['300-500ms'] ?? 0) + 1;
        } else if (latency < 999) {
          latencyStats['500-999ms'] = (latencyStats['500-999ms'] ?? 0) + 1;
        } else {
          latencyStats['失败'] = (latencyStats['失败'] ?? 0) + 1;
          totalFailures++;
        }
      }
      await _log.info('延迟分布: $latencyStats', tag: _logTag);
      
      // 如果检测到大量假连接，记录警告
      if (fakeConnections > 0) {
        await _log.error('⚠️ 检测到 $fakeConnections 个假连接！这是Flutter Socket的已知bug。', tag: _logTag);
        await _log.error('   参考: https://github.com/flutter/flutter/issues/155740', tag: _logTag);
        await _log.error('   建议: 尝试重启应用或使用HTTPing模式', tag: _logTag);
      }
      
      // 检查失败率，决定是否启用诊断
      if (pingResults.isNotEmpty) {
        final failureRate = totalFailures / pingResults.length;
        if (failureRate > 0.5) { // 失败率超过50%
          await _log.warn('检测到高失败率: ${(failureRate * 100).toStringAsFixed(1)}%，启用诊断模式', tag: _logTag);
          _enableDiagnosis = true;
          
          // 对几个失败的IP进行诊断
          final failedIps = pingResults
              .where((r) => r['lossRate'] >= 1.0)
              .take(3)
              .map((r) => r['ip'] as String)
              .toList();
              
          for (final ip in failedIps) {
            await _log.info('对失败IP进行诊断: $ip', tag: _logTag);
            await _diagnoseTcpConnection(ip, testPort);
          }
        }
      }
      
      // 过滤有效服务器
      final validServers = <ServerModel>[];
      for (final result in pingResults) {
        final ip = result['ip'] as String;
        final latency = result['latency'] as int;
        final lossRate = result['lossRate'] as double;
        final isFake = result['fakeConnection'] ?? false;
        
        // 排除假连接
        if (isFake) {
          await _log.debug('跳过假连接: $ip', tag: _logTag);
          continue;
        }
        
        // 过滤条件：延迟小于等于上限，且丢包率小于指定值
        if (latency > 0 && latency <= maxLatency && lossRate < maxLossRate) {
          // 统一使用IP地址推测地理位置
          String detectedLocation = location;
          if (location == 'AUTO') {
            detectedLocation = _detectLocationFromIp(ip);
          }
          
          validServers.add(ServerModel(
            id: '${DateTime.now().millisecondsSinceEpoch}_${ip.replaceAll('.', '')}',
            name: ip,
            location: detectedLocation,
            ip: ip,
            port: testPort,
            ping: latency,
          ));
        }
      }
      
      await _log.info('初步过滤后找到 ${validServers.length} 个符合条件的节点（延迟<=$maxLatency ms，丢包率<${(maxLossRate * 100).toStringAsFixed(1)}%）', tag: _logTag);
      
      if (validServers.isEmpty) {
        // 检查是否都是假连接
        final allFakeConnections = pingResults.where((r) => r['fakeConnection'] == true).length;
        if (allFakeConnections > 0) {
          await _log.error('''检测到Flutter Socket bug导致所有连接失败！
          
这是一个已知的Flutter bug：socket.address返回了错误的地址。
参考：https://github.com/flutter/flutter/issues/155740

解决方案：
  1. 尝试使用HTTPing模式（使用80端口）
  2. 重启应用
  3. 在不同的网络环境下测试
  4. 等待Flutter修复此bug''', tag: _logTag);
        } else {
          await _log.error('''未找到符合条件的节点
建议：
  1. 检查网络连接是否正常
  2. 降低延迟要求（当前: $maxLatency ms）
  3. 提高丢包率容忍度（当前: ${(maxLossRate * 100).toStringAsFixed(1)}%）
  4. 增加测试数量（当前: $testCount）
  5. 检查防火墙是否阻止了${testPort}端口''', tag: _logTag);
        }
        
        throw TestException(
          messageKey: 'noQualifiedNodes',
          detailKey: 'checkNetworkOrRequirements',
        );
      }
      
      // 按延迟排序（与开源项目一致，先按丢包率，再按延迟）
      validServers.sort((a, b) => a.ping.compareTo(b.ping));
      
      // 步骤4：下载测速
      currentStep++;
      controller.add(TestProgress(
        step: currentStep,
        totalSteps: totalSteps,
        messageKey: 'testingDownloadSpeed',
        detailKey: 'startingSpeedTest',
        progress: currentStep / totalSteps,
      ));
      
      // 收集最终的服务器列表
      final finalServers = <ServerModel>[];
      
      // 新逻辑：根据节点数量决定测速策略
      if (validServers.length <= count) {
        // 节点不足，跳过测速，直接使用所有节点
        await _log.info('找到 ${validServers.length} 个节点，不足 $count 个，跳过下载测速', tag: _logTag);
        finalServers.addAll(validServers);
        
        // 更新进度到100%
        controller.add(TestProgress(
          step: currentStep,
          totalSteps: totalSteps,
          messageKey: 'testingDownloadSpeed',
          detailKey: 'nodeProgress',
          detailParams: {
            'current': validServers.length,
            'total': validServers.length,
          },
          progress: currentStep / totalSteps,
          subProgress: 1.0,
        ));
      } else {
        // 节点充足，测试策略调整
        int downloadTestCount;
        
        if (minDownloadSpeed > 0) {
          // 如果指定了下载速度下限，需要测试更多服务器以确保找到足够的合格节点
          downloadTestCount = validServers.length;
          await _log.info('指定了最小下载速度 ${minDownloadSpeed}MB/s，将测试全部 $downloadTestCount 个节点', tag: _logTag);
        } else {
          // 默认测试2倍数量的节点（最多10个），以便有更多选择
          downloadTestCount = math.min(validServers.length, math.max(count * 2, 10));
          await _log.info('开始下载测速，将测试前 $downloadTestCount 个低延迟节点', tag: _logTag);
        }
        
        // 临时列表，用于存储测速后的节点
        final testedServers = <ServerModel>[];
        
        // 对服务器进行下载测速
        for (int i = 0; i < downloadTestCount; i++) {
          final server = validServers[i];
          await _log.debug('测试服务器 ${i + 1}/$downloadTestCount: ${server.ip}', tag: _logTag);
          
          controller.add(TestProgress(
            step: currentStep,
            totalSteps: totalSteps,
            messageKey: 'testingDownloadSpeed',
            detailKey: 'nodeProgress',
            detailParams: {
              'current': i + 1,
              'total': downloadTestCount,
              'ip': server.ip
            },
            progress: (currentStep - 1 + (i + 1) / downloadTestCount) / totalSteps,
            subProgress: (i + 1) / downloadTestCount,
          ));
          
          final downloadSpeed = await _testDownloadSpeed(server.ip, downloadPort);  // 使用下载端口
          server.downloadSpeed = downloadSpeed;
          
          await _log.info('节点 ${server.ip} - 延迟: ${server.ping}ms, 下载: ${downloadSpeed.toStringAsFixed(2)}MB/s', tag: _logTag);
          
          // 根据是否有速度要求决定是否加入结果
          if (downloadSpeed >= minDownloadSpeed) {
            testedServers.add(server);
            
            // 如果设置了速度下限且已找够数量，可以提前结束
            if (minDownloadSpeed > 0 && testedServers.length >= count) {
              await _log.info('已找到 ${testedServers.length} 个满足速度要求的节点，提前结束测试', tag: _logTag);
              break;
            }
          } else if (minDownloadSpeed == 0) {
            // 没有速度要求时，所有测试过的节点都保留
            testedServers.add(server);
          }
        }
        
        // 处理测试结果
        if (minDownloadSpeed > 0 && testedServers.isEmpty) {
          // 没有节点满足速度要求
          await _log.error('没有服务器满足下载速度要求（>=${minDownloadSpeed}MB/s）', tag: _logTag);
          throw TestException(
            messageKey: 'noServersMetSpeedRequirement',
            detailKey: 'lowerSpeedRequirement',
          );
        }
        
        // 按下载速度排序（从高到低）
        await _log.info('按下载速度重新排序...', tag: _logTag);
        testedServers.sort((a, b) => b.downloadSpeed.compareTo(a.downloadSpeed));
        
        // 取速度最快的节点
        finalServers.addAll(testedServers.take(count));
      }
      

      
      // 记录最优的几个节点
      await _log.info('找到 ${finalServers.length} 个节点（从 ${validServers.length} 个低延迟节点中选出）', tag: _logTag);
      final topNodes = finalServers.take(math.min(5, finalServers.length));
      for (final node in topNodes) {
        await _log.info('最终节点: ${node.ip} - ${node.ping}ms - ${node.downloadSpeed.toStringAsFixed(2)}MB/s - ${node.location}', tag: _logTag);
      }
      
      await _log.info('=== 测试完成 ===', tag: _logTag);
      
      // 步骤5：完成
      controller.add(TestProgress(
        step: totalSteps,
        totalSteps: totalSteps,
        messageKey: 'testCompleted',
        detailKey: 'foundQualityNodes',
        detailParams: {'count': finalServers.length},
        progress: 1.0,
        servers: finalServers,
      ));
      
    } catch (e, stackTrace) {
      if (e is TestException) {
        await _log.error('Cloudflare 测试失败: ${e.messageKey} - ${e.detailKey}', tag: _logTag);
        controller.add(TestProgress(
          step: -1,
          totalSteps: 5,
          messageKey: e.messageKey,
          detailKey: e.detailKey,
          progress: 0,
          error: e,
        ));
      } else {
        await _log.error('Cloudflare 测试失败', tag: _logTag, error: e, stackTrace: stackTrace);
        controller.add(TestProgress(
          step: -1,
          totalSteps: 5,
          messageKey: 'testFailed',
          detailKey: e.toString(),
          progress: 0,
          error: e,
        ));
      }
    } finally {
      await controller.close();
    }
  }
  
  // 根据IP地址推测地理位置（基于Cloudflare IP段的实际分布）
  static String _detectLocationFromIp(String ip) {
    final ipParts = ip.split('.').map(int.parse).toList();
    final firstOctet = ipParts[0];
    final secondOctet = ipParts[1];
    
    // 基于 Cloudflare 官方 IP 段的地理分布映射
    if (firstOctet == 104) {
      // 104.16.0.0/12 主要在美国，部分在欧洲
      if (secondOctet >= 16 && secondOctet <= 31) {
        return 'US';  // 美国（主要）
      }
      return 'GB';  // 英国（部分）
    } else if (firstOctet == 172) {
      // 172.64-67 段的精确映射
      if (secondOctet == 64) {
        // 172.64.0.0/17 及其子网段 - 分布在亚太和美洲
        if (ipParts[2] < 64) {
          return 'US';  // 美国
        } else if (ipParts[2] < 128) {
          return 'SG';  // 新加坡
        } else if (ipParts[2] < 192) {
          return 'JP';  // 日本
        } else {
          return 'HK';  // 香港
        }
      } else if (secondOctet == 65) {
        // 172.65.0.0/16 - 主要在欧洲和美洲
        if (ipParts[2] < 128) {
          return 'DE';  // 德国
        } else {
          return 'US';  // 美国
        }
      } else if (secondOctet == 66) {
        // 172.66.0.0/16 - 主要在亚太地区
        if (ipParts[2] < 64) {
          return 'SG';  // 新加坡
        } else if (ipParts[2] < 128) {
          return 'AU';  // 澳大利亚
        } else if (ipParts[2] < 192) {
          return 'JP';  // 日本
        } else {
          return 'KR';  // 韩国
        }
      } else if (secondOctet == 67) {
        // 172.67.0.0/16 - 全球分布
        if (ipParts[2] < 64) {
          return 'US';  // 美国
        } else if (ipParts[2] < 128) {
          return 'GB';  // 英国
        } else if (ipParts[2] < 192) {
          return 'SG';  // 新加坡
        } else {
          return 'BR';  // 巴西
        }
      }
    } else if (firstOctet == 173 && secondOctet >= 245) {
      // 173.245.48.0/20 美国
      return 'US';
    } else if (firstOctet == 103) {
      // 103.21.244.0/22, 103.22.200.0/22 - 亚太地区
      if (secondOctet >= 21 && secondOctet <= 22) {
        return 'SG';  // 新加坡
      }
      // 103.31.4.0/22 - 东亚
      else if (secondOctet == 31) {
        return 'JP';  // 日本
      }
    } else if (firstOctet == 141 && secondOctet >= 101) {
      // 141.101.64.0/18 美国
      return 'US';
    } else if (firstOctet == 108 && secondOctet >= 162) {
      // 108.162.192.0/18 美国
      return 'US';
    } else if (firstOctet == 190 && secondOctet >= 93) {
      // 190.93.240.0/20 南美
      return 'BR';  // 巴西
    } else if (firstOctet == 188 && secondOctet >= 114) {
      // 188.114.96.0/20 欧洲
      return 'DE';  // 德国
    } else if (firstOctet == 197 && secondOctet >= 234) {
      // 197.234.240.0/22 非洲
      return 'ZA';  // 南非
    } else if (firstOctet == 198 && secondOctet >= 41) {
      // 198.41.128.0/17 美国
      return 'US';
    } else if (firstOctet == 162 && secondOctet >= 158 && secondOctet <= 159) {
      // 162.158.0.0/15 全球分布
      if (secondOctet == 158) {
        if (ipParts[2] < 128) {
          return 'US';  // 美国
        } else {
          return 'GB';  // 英国
        }
      } else {  // 159
        if (ipParts[2] < 128) {
          return 'NL';  // 荷兰
        } else {
          return 'FR';  // 法国
        }
      }
    } else if (firstOctet == 131 && secondOctet == 0) {
      // 131.0.72.0/22 美国
      return 'US';
    }
    
    // 默认返回美国（Cloudflare 的主要节点分布地）
    return 'US';
  }
  
  // 从 CIDR 中按 /24 段采样 IP（保持原有方法）
  static List<String> _sampleFromCidr(String cidr, int count) {
    final ips = <String>[];
    
    try {
      final parts = cidr.split('/');
      if (parts.length != 2) {
        _log.warn('无效的CIDR格式: $cidr', tag: _logTag);
        return ips;
      }
      
      final baseIp = parts[0];
      final prefixLength = int.parse(parts[1]);
      
      // 验证IP格式
      final ipParts = baseIp.split('.').map((p) {
        final num = int.tryParse(p);
        if (num == null || num < 0 || num > 255) {
          throw FormatException('无效的IP部分: $p');
        }
        return num;
      }).toList();
      
      if (ipParts.length != 4) {
        _log.warn('无效的IP格式: $baseIp', tag: _logTag);
        return ips;
      }
      
      // 解析基础 IP（使用无符号右移避免负数）
      var ipNum = ((ipParts[0] & 0xFF) << 24) | 
                  ((ipParts[1] & 0xFF) << 16) | 
                  ((ipParts[2] & 0xFF) << 8) | 
                  (ipParts[3] & 0xFF);
      
      // 计算 IP 段范围
      final hostBits = 32 - prefixLength;
      final mask = prefixLength == 0 ? 0 : (0xFFFFFFFF << hostBits) & 0xFFFFFFFF;
      final startIp = ipNum & mask;
      final endIp = startIp | (~mask & 0xFFFFFFFF);
      
      final random = math.Random();
      
      // 如果是 /32 单个 IP，直接添加
      if (prefixLength == 32) {
        final ip = '${(ipNum >> 24) & 0xFF}.${(ipNum >> 16) & 0xFF}.${(ipNum >> 8) & 0xFF}.${ipNum & 0xFF}';
        ips.add(ip);
        return ips;
      }
      
      // 如果是 /24 或更小的段，每个段随机一个
      if (prefixLength >= 24) {
        // 在最后一段中随机
        final lastSegmentRange = (endIp & 0xFF) - (startIp & 0xFF) + 1;
        if (lastSegmentRange > 0) {
          final randomLast = random.nextInt(lastSegmentRange);
          final selectedIp = startIp + randomLast;
          final ip = '${(selectedIp >> 24) & 0xFF}.${(selectedIp >> 16) & 0xFF}.${(selectedIp >> 8) & 0xFF}.${selectedIp & 0xFF}';
          ips.add(ip);
        }
        return ips;
      }
      
      // 对于大于 /24 的段，遍历每个 /24 子段
      var currentIp = startIp;
      var sampledCount = 0;
      var iterations = 0;
      final maxIterations = 1000; // 防止无限循环
      
      while (currentIp <= endIp && sampledCount < count && iterations < maxIterations) {
        iterations++;
        
        // 确保当前 IP 在范围内
        if (currentIp > endIp || currentIp < 0) break;
        
        // 在当前 /24 段中随机选择一个 IP（最后一位随机 1-254，避免.0和.255）
        final randomLast = random.nextInt(254) + 1;  // 1-254
        final selectedIp = (currentIp & 0xFFFFFF00) | randomLast;
        
        // 确保选择的 IP 在原始 CIDR 范围内
        if (selectedIp >= startIp && selectedIp <= endIp) {
          final ip = '${(selectedIp >> 24) & 0xFF}.${(selectedIp >> 16) & 0xFF}.${(selectedIp >> 8) & 0xFF}.${selectedIp & 0xFF}';
          ips.add(ip);
          sampledCount++;
        }
        
        // 移动到下一个 /24 段（第三段+1）
        final nextIp = ((currentIp >> 8) + 1) << 8;
        if (nextIp <= currentIp) break; // 防止溢出
        currentIp = nextIp;
      }
    } catch (e) {
      _log.error('解析 CIDR $cidr 失败', tag: _logTag, error: e);
    }
    
    return ips;
  }
  
  // 从 IP 段中采样 - 简化版本
  static Future<List<String>> _sampleIpsFromRanges(int targetCount) async {
    final ips = <String>[];
    
    // 使用内置的 Cloudflare IP 段常量
    final cloudflareIpRanges = _cloudflareIpRanges;
    await _log.debug('使用 ${cloudflareIpRanges.length} 个内置IP段', tag: _logTag);
    
    // 计算每个IP段需要采样的数量
    final samplesPerRange = (targetCount / cloudflareIpRanges.length).ceil();
    
    // 从每个 CIDR 段采样
    for (final range in cloudflareIpRanges) {
      final rangeIps = _sampleFromCidr(range, samplesPerRange);
      ips.addAll(rangeIps);
      
      if (ips.length >= targetCount) {
        break;
      }
    }
    
    await _log.debug('采样获得 ${ips.length} 个IP', tag: _logTag);
    
    // 如果采样不够，从大的IP段补充
    if (ips.length < targetCount) {
      final random = math.Random();
      final additionalNeeded = targetCount - ips.length;
      
      // 从较大的 IP 段中额外采样
      final largeRanges = cloudflareIpRanges.where((range) {
        final prefix = int.parse(range.split('/')[1]);
        return prefix <= 18;  // 选择 /18 及更大的段进行额外采样
      }).toList();
      
      await _log.debug('从 ${largeRanges.length} 个大IP段中额外采样 $additionalNeeded 个', tag: _logTag);
      
      for (int i = 0; i < additionalNeeded && ips.length < targetCount; i++) {
        final range = largeRanges[random.nextInt(largeRanges.length)];
        final rangeIps = _sampleFromCidr(range, 1);
        if (rangeIps.isNotEmpty && !ips.contains(rangeIps.first)) {
          ips.add(rangeIps.first);
        }
      }
    }
    
    // 打乱顺序
    ips.shuffle();
    
    await _log.info('总共采样了 ${ips.length} 个IP进行测试', tag: _logTag);
    
    return ips.take(targetCount).toList();
  }

  // 测试单个IP的延迟和丢包率 - TCPing模式（修复版：检测假连接）
  static Future<Map<String, dynamic>> _testSingleIpLatencyWithLossRate(String ip, int port, [int maxLatency = 300]) async {
    const int pingTimes = 3; // 测试次数
    List<int> latencies = [];
    int successCount = 0;
    bool isFakeConnection = false; // 检测是否是假连接
    
    await _log.debug('[TCPing] 开始测试 $ip:$port (超时: ${maxLatency}ms)', tag: _logTag);
    
    // 进行多次测试
    for (int i = 0; i < pingTimes; i++) {
      await _log.debug('[TCPing] 第 ${i + 1}/$pingTimes 次测试', tag: _logTag);
      
      try {
        final stopwatch = Stopwatch()..start();
        
        // TCP连接 - 使用总超时时间
        final socket = await Socket.connect(
          ip,
          port,
          timeout: Duration(milliseconds: maxLatency),
        );
        
        final connectTime = stopwatch.elapsedMilliseconds;
        await _log.debug('[TCPing] 连接成功，耗时: ${connectTime}ms', tag: _logTag);
        
        // 检测是否是假连接（Flutter bug）
        try {
          if (socket.address.address == socket.remoteAddress.address) {
            isFakeConnection = true;
            await _log.warn('[TCPing] 检测到Flutter Socket bug: 本地地址与远程地址相同！', tag: _logTag);
          }
        } catch (e) {
          // 忽略地址获取错误
        }
        
        try {
          // 发送测试数据
          if (port == 80 || port == _httpPort) {
            // HTTP端口：发送完整的最小HTTP请求
            socket.write('HEAD / HTTP/1.0\r\nHost: speed.cloudflare.com\r\n\r\n');
            await socket.flush();
            await _log.debug('[TCPing] 已发送HTTP HEAD请求', tag: _logTag);
          } else if (port == 443 || port == _defaultPort) {
            // HTTPS端口：对于Cloudflare，我们只需要测试TCP连接
            // 不发送任何数据，因为TLS握手很复杂
            await _log.debug('[TCPing] HTTPS端口，仅测试TCP连接', tag: _logTag);
            // 直接等待一小段时间看连接是否保持
            await Future.delayed(const Duration(milliseconds: 10));
          } else {
            // 其他端口：发送简单数据
            socket.add([0x00]);
            await socket.flush();
            await _log.debug('[TCPing] 已发送测试数据', tag: _logTag);
          }
          
          // 计算剩余时间
          final remainingTime = maxLatency - connectTime;
          
          // 对于HTTPS端口，连接成功就算成功
          if (port == 443 || port == _defaultPort) {
            // 如果没有停止计时器，现在停止
            if (stopwatch.isRunning) {
              stopwatch.stop();
            }
            
            final latency = stopwatch.elapsedMilliseconds;
            await _log.debug('[TCPing] HTTPS端口测试完成，延迟: ${latency}ms', tag: _logTag);
            
            // 记录有效延迟（但如果是假连接，标记为失败）
            if (latency > 0 && latency <= maxLatency && !isFakeConnection) {
              latencies.add(latency);
              successCount++;
              await _log.debug('[TCPing] 延迟值有效，已记录', tag: _logTag);
            } else if (isFakeConnection) {
              await _log.warn('[TCPing] 由于检测到假连接，标记为失败', tag: _logTag);
            }
          } else if (remainingTime > 10) {
            // 对于HTTP端口，等待响应
            final responseCompleter = Completer<void>();
            bool receivedData = false;
            StreamSubscription? subscription;
            
            subscription = socket.listen(
              (data) {
                if (!receivedData && data.isNotEmpty) {
                  receivedData = true;
                  stopwatch.stop();
                  _log.debug('[TCPing] 收到响应，${data.length}字节', tag: _logTag);
                  if (!responseCompleter.isCompleted) {
                    responseCompleter.complete();
                  }
                }
              },
              onDone: () {
                if (!responseCompleter.isCompleted) {
                  responseCompleter.completeError('连接关闭');
                }
              },
              onError: (e) {
                if (!responseCompleter.isCompleted) {
                  responseCompleter.completeError(e);
                }
              },
              cancelOnError: true,
            );
            
            // 等待响应或超时
            await responseCompleter.future.timeout(
              Duration(milliseconds: remainingTime),
              onTimeout: () {
                subscription?.cancel();
                // 移除重复的日志，timeout本身就说明了问题
                return null; // 超时不抛异常，继续处理
              },
            );
            
            subscription?.cancel();
          } else {
            await _log.debug('[TCPing] 剩余时间不足(${remainingTime}ms)，跳过等待响应', tag: _logTag);
          }
          
          // 如果没有停止计时器，现在停止
          if (stopwatch.isRunning) {
            stopwatch.stop();
          }
          
          final latency = stopwatch.elapsedMilliseconds;
          await _log.debug('[TCPing] 测试完成，延迟: ${latency}ms', tag: _logTag);
          
          // 记录有效延迟
          if (latency > 0 && latency <= maxLatency) {
            latencies.add(latency);
            successCount++;
            await _log.debug('[TCPing] 延迟值有效，已记录', tag: _logTag);
          } else {
            await _log.warn('[TCPing] 延迟值异常: ${latency}ms', tag: _logTag);
          }
          
        } finally {
          // 强制关闭socket
          socket.destroy();
          await _log.debug('[TCPing] Socket已关闭', tag: _logTag);
        }
        
      } catch (e) {
        // 统一的错误日志处理
        String errorDetail = '';
        if (e is SocketException) {
          errorDetail = '网络错误: ${e.message}';
          if (e.osError != null) {
            errorDetail += ' (OS: ${e.osError!.errorCode} - ${e.osError!.message})';
          }
        } else if (e is TimeoutException) {
          errorDetail = '连接超时';
        } else {
          errorDetail = e.toString();
        }
        
        await _log.debug('[TCPing] 第 ${i + 1}/$pingTimes 次测试失败: $errorDetail', tag: _logTag);
        
        // 优化：连续失败提前退出
        if (successCount == 0 && i >= 1) {
          await _log.debug('[TCPing] 连续失败，提前结束测试', tag: _logTag);
          break;
        }
      }
      
      // 测试间隔
      if (i < pingTimes - 1) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    
    // 计算结果
    final avgLatency = successCount > 0 
        ? latencies.reduce((a, b) => a + b) ~/ successCount 
        : 999;
    
    // 实际测试次数
    final actualPingTimes = successCount > 0 ? pingTimes : math.min(2, pingTimes);
    final lossRate = (actualPingTimes - successCount) / actualPingTimes.toDouble();
    
    // 如果检测到假连接，强制标记为失败
    if (isFakeConnection) {
      await _log.error('[TCPing] 检测到Flutter Socket bug，连接被标记为失败', tag: _logTag);
      return {
        'ip': ip,
        'latency': 999,
        'lossRate': 1.0,
        'sent': actualPingTimes,
        'received': 0,
        'colo': '',
        'fakeConnection': true, // 标记为假连接
      };
    }
    
    await _log.info('[TCPing] 完成 $ip - 平均延迟: ${avgLatency}ms, 丢包率: ${(lossRate * 100).toStringAsFixed(1)}%', tag: _logTag);
    await _log.debug('[TCPing] 统计 - 成功: $successCount, 实际测试: $actualPingTimes, 延迟列表: $latencies', tag: _logTag);
    
    // 如果启用诊断模式且失败率高，进行诊断
    if (_enableDiagnosis && lossRate >= 1.0 && _diagnosisCount < _maxDiagnosisCount) {
      _diagnosisCount++;
      await _log.warn('[TCPing] 检测到失败率100%，启动诊断模式 (${_diagnosisCount}/$_maxDiagnosisCount)', tag: _logTag);
      await _diagnoseTcpConnection(ip, port);
    }
    
    return {
      'ip': ip,
      'latency': avgLatency,
      'lossRate': lossRate,
      'sent': actualPingTimes,
      'received': successCount,
      'colo': '', // TCPing模式无法获取地区信息
      'fakeConnection': false,
    };
  }
  
  // 下载速度测试（修复版）
  static Future<double> _testDownloadSpeed(String ip, int port) async {
    HttpClient? httpClient;
    
    try {
      await _log.debug('[下载测试] 开始测试 $ip:$port', tag: _logTag);
      await _log.debug('[下载测试] 使用URL: $_downloadTestUrl', tag: _logTag);
      
      // 创建HttpClient
      httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 5);
      httpClient.idleTimeout = const Duration(seconds: 10);
      
      // 支持SNI（如果需要HTTPS）
      httpClient.badCertificateCallback = (cert, host, port) => true;
      
      // 解析测试URL
      final testUri = Uri.parse(_downloadTestUrl);
      
      // 修复：下载测试始终使用80端口，忽略传入的port参数
      final directUri = Uri(
        scheme: testUri.scheme,
        host: ip,
        port: 80,  // 修复：始终使用80端口进行HTTP下载测试
        path: testUri.path,
        queryParameters: testUri.queryParameters,
      );
      
      await _log.debug('[下载测试] 连接到: $directUri', tag: _logTag);
      
      // 创建请求
      final request = await httpClient.getUrl(directUri);
      
      // 设置必要的请求头
      request.headers.set('Host', testUri.host); // 重要：设置正确的Host
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      request.headers.set('Accept', '*/*');
      request.headers.set('Accept-Encoding', 'identity'); // 不使用压缩
      
      // 开始计时
      final startTime = DateTime.now();
      final response = await request.close();
      
      // 检查响应状态
      await _log.debug('[下载测试] 响应状态码: ${response.statusCode}', tag: _logTag);
      
      if (response.statusCode != 200) {
        await _log.warn('[下载测试] 错误响应码: ${response.statusCode}，跳过该节点', tag: _logTag);
        return 0.0;  // 直接返回，不尝试读取响应体
      }
      
      // 下载数据并计算速度
      int totalBytes = 0;
      final endTime = startTime.add(_downloadTimeout);
      
      // 使用流式读取
      await for (final chunk in response) {
        totalBytes += chunk.length;
        
        // 定期日志
        if (totalBytes % (512 * 1024) == 0) {
          await _log.debug('[下载测试] 已下载: ${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB', tag: _logTag);
        }
        
        // 检查是否超时
        if (DateTime.now().isAfter(endTime)) {
          await _log.debug('[下载测试] 超时，停止下载', tag: _logTag);
          break;
        }
      }
      
      final duration = DateTime.now().difference(startTime);
      
      // 计算速度（MB/s）
      if (duration.inMilliseconds > 0 && totalBytes > 0) {
        final speedMBps = (totalBytes / 1024 / 1024) / (duration.inMilliseconds / 1000);
        await _log.info('[下载测试] 完成 - 下载: ${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB, 耗时: ${duration.inMilliseconds} ms, 速度: ${speedMBps.toStringAsFixed(2)} MB/s', tag: _logTag);
        return speedMBps;
      }
      
      return 0.0;
      
    } catch (e, stackTrace) {
      await _log.error('[下载测试] 异常', tag: _logTag, error: e, stackTrace: stackTrace);
      return 0.0;
    } finally {
      httpClient?.close();
    }
  }
}

// 进度数据类 - 修改为使用国际化键
class TestProgress {
  final int step;
  final int totalSteps;
  final String messageKey;  // 国际化键
  final String? detailKey;  // 国际化键
  final Map<String, dynamic>? detailParams;  // 详情参数
  final double progress;  // 0.0 - 1.0
  final double? subProgress;  // 子进度
  final dynamic error;
  final List<ServerModel>? servers; // 最终结果
  
  TestProgress({
    required this.step,
    required this.totalSteps,
    required this.messageKey,
    this.detailKey,
    this.detailParams,
    required this.progress,
    this.subProgress,
    this.error,
    this.servers,
  });
  
  // 为了兼容性保留原有属性
  String get message => messageKey;
  String get detail => detailKey ?? '';
  
  // 获取整体百分比
  int get percentage => (progress * 100).round();
  
  // 是否失败
  bool get hasError => error != null;
  
  // 是否完成
  bool get isCompleted => step == totalSteps;
}

// 自定义测试异常类
class TestException implements Exception {
  final String messageKey;
  final String detailKey;
  
  TestException({
    required this.messageKey,
    required this.detailKey,
  });
  
  @override
  String toString() => '$messageKey: $detailKey';
}

// ===== Cloudflare 测试对话框（更新使用新的进度系统） =====
class CloudflareTestDialog extends StatefulWidget {
  final VoidCallback? onComplete;
  final VoidCallback? onError;
  
  const CloudflareTestDialog({
    super.key,
    this.onComplete,
    this.onError,
  });

  @override
  State<CloudflareTestDialog> createState() => _CloudflareTestDialogState();
}

class _CloudflareTestDialogState extends State<CloudflareTestDialog> {
  StreamSubscription<TestProgress>? _progressSubscription;
  TestProgress? _currentProgress;
  bool _isCompleted = false;

  @override
  void initState() {
    super.initState();
    _startTest();
  }

  Future<void> _startTest() async {
    final l10n = AppLocalizations.of(context);
    final connectionProvider = context.read<ConnectionProvider>();
    
    // 如果已连接，先断开连接
    if (connectionProvider.isConnected) {
      setState(() {
        _currentProgress = TestProgress(
          step: 1,
          totalSteps: 5,
          messageKey: 'disconnecting',
          progress: 0.1,
        );
      });
      
      try {
        await connectionProvider.disconnect();
      } catch (e) {
        print('断开连接失败: $e');
      }
    }

    // 使用新的带进度的测试方法
    final stream = CloudflareTestService.testServersWithProgress(
      count: 5,
      maxLatency: 300,
      speed: 5,
      testCount: 500,
      location: 'AUTO',
      useHttping: false, // 使用TCPing
    );
    
    _progressSubscription = stream.listen(
      (progress) {
        setState(() {
          _currentProgress = progress;
        });
        
        if (progress.hasError) {
          // 处理错误
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${l10n.testFailed}: ${_getLocalizedDetail(progress)}'),
              backgroundColor: Colors.red,
            ),
          );
          // 调用错误回调
          widget.onError?.call();
        } else if (progress.isCompleted && progress.servers != null) {
          // 测试完成，保存结果
          _saveResults(progress.servers!);
        }
      },
      onError: (error) {
        setState(() {
          _currentProgress = TestProgress(
            step: -1,
            totalSteps: 5,
            messageKey: 'testFailed',
            detailKey: error.toString(),
            progress: 0,
            error: error,
          );
        });
        // 调用错误回调
        widget.onError?.call();
      },
    );
  }
  
  // 获取本地化的消息
  String _getLocalizedMessage(TestProgress progress) {
    final l10n = AppLocalizations.of(context);
    
    // 使用反射或映射来获取对应的本地化文本
    switch (progress.messageKey) {
      case 'preparingTestEnvironment':
        return l10n.preparingTestEnvironment;
      case 'generatingTestIPs':
        return l10n.generatingTestIPs;
      case 'testingDelay':
        return l10n.testingDelay;
      case 'testingDownloadSpeed':
        return l10n.testingDownloadSpeed;
      case 'testCompleted':
        return l10n.testCompleted;
      case 'disconnecting':
        return l10n.disconnecting;
      case 'testFailed':
        return l10n.testFailed;
      case 'noQualifiedNodes':
        return l10n.noQualifiedNodes;
      case 'noServersMetSpeedRequirement':
        return l10n.noServersMetSpeedRequirement;
      default:
        return progress.messageKey;
    }
  }
  
  // 获取本地化的详情
  String _getLocalizedDetail(TestProgress progress) {
    if (progress.detailKey == null) return '';
    
    final l10n = AppLocalizations.of(context);
    
    switch (progress.detailKey!) {
      case 'initializing':
        return l10n.initializing;
      case 'startingSpeedTest':
        return l10n.startingSpeedTest;
      case 'checkNetworkOrRequirements':
        return l10n.checkNetworkOrRequirements;
      case 'lowerSpeedRequirement':
        return l10n.lowerSpeedRequirement;
      case 'ipRanges':
        final count = progress.detailParams?['count'] ?? 0;
        return l10n.samplingFromRanges(count);
      case 'nodeProgress':
        final current = progress.detailParams?['current'] ?? 0;
        final total = progress.detailParams?['total'] ?? 0;
        final ip = progress.detailParams?['ip'] ?? '';
        if (ip.isNotEmpty) {
          return '$current/$total - $ip';
        }
        return '$current/$total';
      case 'foundQualityNodes':
        final count = progress.detailParams?['count'] ?? 0;
        return l10n.foundNodes(count);
      default:
        return progress.detailKey!;
    }
  }
  
  void _saveResults(List<ServerModel> servers) async {
    final l10n = AppLocalizations.of(context);
    final serverProvider = context.read<ServerProvider>();
    
    // 先清空所有旧节点
    await serverProvider.clearAllServers();
    
    // 再逐个添加新节点
    for (final server in servers) {
      await serverProvider.addServer(server);
    }
    
    setState(() {
      _isCompleted = true;
    });
    
    // 调用完成回调
    widget.onComplete?.call();
    
    // 延迟关闭对话框
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (!mounted) return;
    Navigator.of(context).pop();
    
    // 显示成功消息
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${l10n.serverAdded} ${servers.length} 个')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        // 圆形进度条
        SizedBox(
          width: 60,
          height: 60,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: _currentProgress?.progress,
                strokeWidth: 4,
                valueColor: AlwaysStoppedAnimation<Color>(
                  _currentProgress?.hasError == true
                      ? Colors.red
                      : Theme.of(context).primaryColor,
                ),
              ),
              if (_currentProgress != null)
                Text(
                  '${_currentProgress!.percentage}%',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // 主要信息
        Text(
          _currentProgress != null 
              ? _getLocalizedMessage(_currentProgress!)
              : l10n.preparing,
          style: const TextStyle(
            fontSize: 16, 
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        // 详细信息
        if (_currentProgress != null)
          Text(
            _getLocalizedDetail(_currentProgress!),
            style: TextStyle(
              fontSize: 14,
              color: _currentProgress?.hasError == true
                  ? Colors.red
                  : Theme.of(context).textTheme.bodySmall?.color,
            ),
            textAlign: TextAlign.center,
          ),
        // 子进度条（如延迟测试的详细进度）
        if (_currentProgress?.subProgress != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: _currentProgress!.subProgress,
                minHeight: 2,
              ),
            ),
          ),
        const SizedBox(height: 20),
        // 完成图标
        if (_isCompleted)
          Icon(
            Icons.check_circle,
            size: 48,
            color: Colors.green[400],
          ),
      ],
    );
  }
  
  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }
}