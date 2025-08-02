import 'dart:io';
import 'dart:convert';
import 'dart:math';
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
  static const int _bufferSize = 1024; // 下载缓冲区大小
  
  // HTTPing 模式相关配置
  static bool httping = false; // 是否启用 HTTPing 模式
  static int httpingStatusCode = 0; // 指定的 HTTP 状态码（0表示默认）
  static String httpingCFColo = ''; // 指定的地区过滤
  
  // 过滤条件
  static double maxLossRate = 1.0; // 丢包率上限（默认100%）
  static double minDownloadSpeed = 0.0; // 下载速度下限（MB/s）
  
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
  
  // 统一的测速方法（合并单独测速和批量测试）
  static Future<List<Map<String, dynamic>>> testLatencyUnified({
    required List<String> ips,
    int? port,
    bool singleTest = false,  // 是否单个测试
    bool useHttping = false,  // 是否使用HTTPing
    Function(int current, int total)? onProgress,  // 进度回调
  }) async {
    // HTTPing模式强制使用80端口，避免证书问题
    final testPort = port ?? (useHttping ? _httpPort : _defaultPort);
    final results = <Map<String, dynamic>>[];
    
    if (ips.isEmpty) {
      await _log.warn('没有IP需要测试', tag: _logTag);
      return results;
    }
    
    await _log.info('开始${useHttping ? "HTTPing" : "TCPing"}测试 ${ips.length} 个IP，端口: $testPort', tag: _logTag);
    
    // 单个测试时不需要批处理
    final batchSize = singleTest ? 1 : 30;
    int successCount = 0;
    int failCount = 0;
    int tested = 0;
    
    for (int i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize).toList();
      final futures = <Future>[];
      
      await _log.debug('测试批次 ${(i / batchSize).floor() + 1}/${((ips.length - 1) / batchSize).floor() + 1}，包含 ${batch.length} 个IP', tag: _logTag);
      
      for (final ip in batch) {
        final testMethod = useHttping 
            ? _testSingleHttping(ip, testPort)
            : _testSingleIpLatencyWithLossRate(ip, testPort);
            
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
      final goodNodes = results.where((r) => r['latency'] < 200 && r['lossRate'] < 0.1).length;
      if (goodNodes >= 10) {
        await _log.info('已找到 $goodNodes 个优质节点（<200ms，丢包率<10%），提前结束测试', tag: _logTag);
        break;
      }
    }
    
    await _log.info('延迟测试完成，成功测试 ${results.length} 个IP（成功: $successCount，失败: $failCount）', tag: _logTag);
    
    return results;
  }
  
  // HTTPing 模式测试单个IP（强制使用HTTP 80端口，避免证书问题）
  static Future<Map<String, dynamic>> _testSingleHttping(String ip, int port) async {
    await _log.debug('[HTTPing] 开始测试 $ip:$port', tag: _logTag);
    
    const int pingTimes = 3;
    List<int> latencies = [];
    int successCount = 0;
    String colo = '';
    
    final httpClient = HttpClient();
    httpClient.connectionTimeout = const Duration(seconds: 3);
    
    // HTTPing 强制使用 HTTP 协议（80端口），避免证书问题
    if (port != 80 && port != _httpPort) {
      await _log.warn('[HTTPing] 警告：HTTPing模式应使用80端口，当前端口: $port', tag: _logTag);
    }
    
    for (int i = 0; i < pingTimes; i++) {
      try {
        // HTTPing始终使用HTTP协议
        final uri = Uri(
          scheme: 'http',
          host: ip,
          port: port,
          path: '/',
        );
        
        await _log.debug('[HTTPing] 测试 ${i + 1}/$pingTimes: $uri', tag: _logTag);
        
        final stopwatch = Stopwatch()..start();
        
        // 使用HEAD请求减少数据传输
        final request = await httpClient.headUrl(uri);
        request.headers.set('Host', 'cloudflare.com');
        request.headers.set('User-Agent', 'CloudflareSpeedTest/Flutter');
        request.headers.set('Accept', '*/*');
        request.headers.set('Connection', 'close');
        
        final response = await request.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            throw TimeoutException('HTTP请求超时');
          },
        );
        
        stopwatch.stop();
        
        // 必须消费响应体
        await response.drain();
        
        await _log.debug('[HTTPing] 响应状态码: ${response.statusCode}, 耗时: ${stopwatch.elapsedMilliseconds}ms', tag: _logTag);
        
        // 检查HTTP状态码
        bool isValidResponse = false;
        if (httpingStatusCode == 0) {
          // 默认接受 200, 301, 302
          isValidResponse = response.statusCode == 200 || 
                           response.statusCode == 301 || 
                           response.statusCode == 302;
        } else {
          // 指定的状态码
          isValidResponse = response.statusCode == httpingStatusCode;
        }
        
        if (!isValidResponse) {
          await _log.debug('[HTTPing] 状态码无效: ${response.statusCode}', tag: _logTag);
          continue;
        }
        
        final latency = stopwatch.elapsedMilliseconds;
        latencies.add(latency);
        successCount++;
        
        // 获取地区信息（仅第一次）
        if (colo.isEmpty) {
          colo = _getColoFromHeaders(response.headers);
          await _log.debug('[HTTPing] 地区码: $colo', tag: _logTag);
          
          // 检查地区过滤
          if (httpingCFColo.isNotEmpty && colo.isNotEmpty) {
            final allowedColos = httpingCFColo.split(',')
                .map((c) => c.trim().toUpperCase()).toList();
            if (!allowedColos.contains(colo)) {
              await _log.info('[HTTPing] 地区 $colo 不在允许列表 $allowedColos 中，跳过', tag: _logTag);
              httpClient.close();
              return {
                'ip': ip,
                'latency': 999,
                'lossRate': 1.0,
                'colo': colo,
              };
            }
          }
        }
        
      } catch (e) {
        await _log.debug('[HTTPing] 测试失败: $e', tag: _logTag);
      }
      
      // 测试间隔
      if (i < pingTimes - 1) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    
    httpClient.close();
    
    // 计算结果
    final avgLatency = successCount > 0 
        ? latencies.reduce((a, b) => a + b) ~/ successCount 
        : 999;
    final lossRate = (pingTimes - successCount) / pingTimes.toDouble();
    
    await _log.info('[HTTPing] 完成 $ip - 平均延迟: ${avgLatency}ms, 丢包率: ${(lossRate * 100).toStringAsFixed(1)}%, 地区: $colo', tag: _logTag);
    
    return {
      'ip': ip,
      'latency': avgLatency,
      'lossRate': lossRate,
      'sent': pingTimes,
      'received': successCount,
      'colo': colo,
    };
  }
  
  // 保持原有的公共接口以兼容旧代码
  static Future<Map<String, int>> testLatency(List<String> ips, [int? port]) async {
    // 根据当前是否启用 HTTPing 来决定使用的端口
    final actualPort = port ?? (httping ? _httpPort : _defaultPort);
    
    final results = await testLatencyUnified(
      ips: ips,
      port: actualPort,
      useHttping: httping,
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
      
      await _log.info('=== 开始测试 Cloudflare 节点 ===', tag: _logTag);
      await _log.info('参数: count=$count, maxLatency=$maxLatency, speed=$speed, testCount=$testCount, location=$location', tag: _logTag);
      await _log.info('模式: ${httping ? "HTTPing" : "TCPing"}, 丢包率上限: ${(maxLossRate * 100).toStringAsFixed(1)}%, 下载速度下限: ${minDownloadSpeed.toStringAsFixed(1)}MB/s', tag: _logTag);
      
      // 定义测试端口 - HTTPing使用80端口
      final int testPort = httping ? _httpPort : _defaultPort;
      await _log.info('测试端口: $testPort', tag: _logTag);
      
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
      for (final result in pingResults) {
        final latency = result['latency'] as int;
        final lossRate = result['lossRate'] as double;
        
        if (lossRate >= 1.0) {
          latencyStats['失败'] = (latencyStats['失败'] ?? 0) + 1;
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
        }
      }
      await _log.info('延迟分布: $latencyStats', tag: _logTag);
      
      // 过滤有效服务器
      final validServers = <ServerModel>[];
      for (final result in pingResults) {
        final ip = result['ip'] as String;
        final latency = result['latency'] as int;
        final lossRate = result['lossRate'] as double;
        final colo = result['colo'] as String? ?? '';
        
        // 过滤条件：延迟小于等于上限，且丢包率小于指定值
        if (latency > 0 && latency <= maxLatency && lossRate < maxLossRate) {
          String detectedLocation = location;
          if (location == 'AUTO') {
            // 优先使用HTTPing获取的地区码
            detectedLocation = colo.isNotEmpty ? colo : _detectLocationFromIp(ip);
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
        await _log.error('''未找到符合条件的节点
建议：
  1. 检查网络连接是否正常
  2. 降低延迟要求（当前: $maxLatency ms）
  3. 提高丢包率容忍度（当前: ${(maxLossRate * 100).toStringAsFixed(1)}%）
  4. 增加测试数量（当前: $testCount）
  5. 检查防火墙是否阻止了${testPort}端口''', tag: _logTag);
        
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
      
      // 确定需要测速的数量（与开源项目逻辑一致）
      int downloadTestCount = count;
      if (validServers.length < count || minDownloadSpeed > 0) {
        // 如果指定了下载速度下限，需要测试更多服务器
        downloadTestCount = validServers.length;
      }
      
      await _log.info('开始下载测速（数量：$downloadTestCount）...', tag: _logTag);
      
      // 收集通过下载速度过滤的服务器
      final speedFilteredServers = <ServerModel>[];
      
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
        
        final downloadSpeed = await _testDownloadSpeed(server.ip, server.port);
        server.downloadSpeed = downloadSpeed;
        
        await _log.info('服务器 ${server.ip} - 下载速度: ${downloadSpeed.toStringAsFixed(2)} MB/s', tag: _logTag);
        
        // 下载速度过滤
        if (downloadSpeed >= minDownloadSpeed) {
          speedFilteredServers.add(server);
          // 如果已经找够了需要的数量，可以提前结束
          if (speedFilteredServers.length >= count && minDownloadSpeed > 0) {
            await _log.info('已找到 ${speedFilteredServers.length} 个满足速度要求的节点，提前结束测试', tag: _logTag);
            break;
          }
        }
      }
      
      // 如果没有指定下载速度下限，使用所有测试过的服务器
      final finalServers = minDownloadSpeed > 0 ? speedFilteredServers : validServers.take(downloadTestCount).toList();
      
      if (finalServers.isEmpty) {
        await _log.error('没有服务器满足下载速度要求（>=${minDownloadSpeed.toStringAsFixed(1)} MB/s）', tag: _logTag);
        throw TestException(
          messageKey: 'noServersMetSpeedRequirement',
          detailKey: 'lowerSpeedRequirement',
        );
      }
      
      // 最终排序（按下载速度排序）
      await _log.info('按下载速度排序...', tag: _logTag);
      finalServers.sort((a, b) => b.downloadSpeed.compareTo(a.downloadSpeed));
      
      // 记录最优的几个节点
      await _log.info('找到 ${finalServers.length} 个完成测速的节点', tag: _logTag);
      final topNodes = finalServers.take(5);
      for (final node in topNodes) {
        await _log.info('优质节点: ${node.ip} - ${node.ping}ms - ${node.downloadSpeed.toStringAsFixed(2)}MB/s - ${node.location}', tag: _logTag);
      }
      
      // 返回请求的数量
      final result = finalServers.take(count).toList();
      await _log.info('返回 ${result.length} 个节点', tag: _logTag);
      await _log.info('=== 测试完成 ===', tag: _logTag);
      
      // 步骤5：完成
      controller.add(TestProgress(
        step: totalSteps,
        totalSteps: totalSteps,
        messageKey: 'testCompleted',
        detailKey: 'foundQualityNodes',
        detailParams: {'count': result.length},
        progress: 1.0,
        servers: result,
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
      
      final random = Random();
      
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
      final random = Random();
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

  // 测试单个IP的延迟和丢包率 - TCPing模式（修复版）
  static Future<Map<String, dynamic>> _testSingleIpLatencyWithLossRate(String ip, [int? port]) async {
    final testPort = port ?? _defaultPort;
    const int pingTimes = 4; // 测试次数
    List<int> latencies = [];
    int successCount = 0;
    
    await _log.debug('[TCPing] 开始测试 $ip:$testPort', tag: _logTag);
    
    // 进行多次测试
    for (int i = 0; i < pingTimes; i++) {
      try {
        final stopwatch = Stopwatch()..start();
        
        // 建立TCP连接
        final socket = await Socket.connect(
          ip,
          testPort,
          timeout: const Duration(seconds: 2),
        );
        
        // 发送HTTP请求（模拟真实通信）
        final request = 'GET / HTTP/1.1\r\n'
            'Host: cloudflare.com\r\n'
            'User-Agent: CloudflareSpeedTest\r\n'
            'Connection: close\r\n'
            '\r\n';
        
        socket.add(utf8.encode(request));
        
        // 等待服务器响应
        final completer = Completer<void>();
        bool gotResponse = false;
        
        socket.listen(
          (List<int> data) {
            if (!gotResponse) {
              gotResponse = true;
              stopwatch.stop();
              // 收到第一个数据包就立即完成
              if (!completer.isCompleted) {
                completer.complete();
              }
            }
          },
          onError: (error) {
            if (!completer.isCompleted) {
              completer.completeError(error);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          cancelOnError: true,
        );
        
        // 等待响应或超时
        await completer.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            if (!stopwatch.isRunning) return;
            stopwatch.stop();
            throw TimeoutException('响应超时');
          },
        );
        
        // 关闭连接
        await socket.close();
        
        final latency = stopwatch.elapsedMilliseconds;
        
        await _log.debug('[TCPing] 测试 ${i + 1}/$pingTimes 成功: ${latency}ms', tag: _logTag);
        
        if (gotResponse && latency > 0 && latency < 2000) {
          latencies.add(latency);
          successCount++;
        }
        
      } catch (e) {
        await _log.debug('[TCPing] 测试 ${i + 1}/$pingTimes 失败: $e', tag: _logTag);
      }
      
      // 测试间隔
      if (i < pingTimes - 1) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    
    // 计算平均延迟（如果有3个以上样本，去除最高最低值）
    int avgLatency = 999;
    if (latencies.length >= 3) {
      latencies.sort();
      latencies.removeAt(0);
      latencies.removeAt(latencies.length - 1);
      avgLatency = latencies.reduce((a, b) => a + b) ~/ latencies.length;
    } else if (latencies.isNotEmpty) {
      avgLatency = latencies.reduce((a, b) => a + b) ~/ latencies.length;
    }
    
    final lossRate = (pingTimes - successCount) / pingTimes.toDouble();
    
    await _log.info('[TCPing] 完成 $ip - 平均延迟: ${avgLatency}ms, 丢包率: ${(lossRate * 100).toStringAsFixed(1)}%', tag: _logTag);
    
    return {
      'ip': ip,
      'latency': avgLatency,
      'lossRate': lossRate,
      'sent': pingTimes,
      'received': successCount,
      'colo': '', // TCPing模式无法获取地区信息
    };
  }
  
  // 从HTTP响应头获取地区信息
  static String _getColoFromHeaders(HttpHeaders headers) {
    // Cloudflare: cf-ray 头部包含地区信息
    final cfRay = headers.value('cf-ray');
    if (cfRay != null) {
      // 格式: 7bd32409eda7b020-SJC
      final parts = cfRay.split('-');
      if (parts.length >= 2) {
        final colo = parts.last.toUpperCase();
        _log.debug('[Headers] cf-ray地区码: $colo', tag: _logTag);
        return colo;
      }
    }
    
    // 备用：检查其他Cloudflare头部
    final cfIpCountry = headers.value('cf-ipcountry');
    if (cfIpCountry != null) {
      _log.debug('[Headers] cf-ipcountry: $cfIpCountry', tag: _logTag);
      return cfIpCountry.toUpperCase();
    }
    
    return '';
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
      
      // 创建直接连接到IP的URI - 根据URL协议选择正确端口
      final directUri = Uri(
        scheme: testUri.scheme,
        host: ip,
        port: testUri.scheme == 'http' ? 80 : 443,  // 关键：根据协议选择端口
        path: testUri.path,
        queryParameters: testUri.queryParameters,
      );
      
      await _log.debug('[下载测试] 连接到: $directUri', tag: _logTag);
      
      // 创建请求
      final request = await httpClient.getUrl(directUri);
      
      // 设置必要的请求头
      request.headers.set('Host', testUri.host); // 重要：设置正确的Host
      request.headers.set('User-Agent', 'CloudflareSpeedTest/Flutter');
      request.headers.set('Accept', '*/*');
      request.headers.set('Accept-Encoding', 'identity'); // 不使用压缩
      
      // 开始计时
      final startTime = DateTime.now();
      final response = await request.close();
      
      // 检查响应状态
      await _log.debug('[下载测试] 响应状态码: ${response.statusCode}', tag: _logTag);
      
      if (response.statusCode != 200) {
        // 尝试读取错误信息
        try {
          final body = await response.transform(utf8.decoder).take(500).join();
          await _log.warn('[下载测试] 错误响应: $body', tag: _logTag);
        } catch (e) {
          // 忽略
        }
        return 0.0;
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
  const CloudflareTestDialog({super.key});

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
      count: 6,
      maxLatency: 200,
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
    
    // 清空现有服务器并添加新的
    for (final server in servers) {
      await serverProvider.addServer(server);
    }
    
    setState(() {
      _isCompleted = true;
    });
    
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
