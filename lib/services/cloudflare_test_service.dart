import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';
import './v2ray_service.dart';

class CloudflareTestService {
  // Cloudflare IP 段
  static const List<String> cloudflareIpRanges = [
    '104.16.0.0/12',
    '172.64.0.0/13',
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
    '104.24.0.0/14',
  ];
  
  // 测试服务器 - 不再使用 cftest.exe
  static Future<List<ServerModel>> testServers({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'HKG',
  }) async {
    try {
      print('=== 开始测试 Cloudflare 节点 ===');
      print('参数: count=$count, maxLatency=$maxLatency');
      
      // 从 IP 段中采样
      final sampleIps = _sampleIpsFromRanges(testCount * 2); // 多采样一些以备筛选
      print('从 IP 段中采样了 ${sampleIps.length} 个 IP');
      
      // 批量测试延迟
      final latencyMap = await testLatency(sampleIps);
      
      // 筛选符合条件的服务器
      final validServers = <ServerModel>[];
      for (final entry in latencyMap.entries) {
        if (entry.value <= maxLatency) {
          validServers.add(ServerModel(
            id: '${DateTime.now().millisecondsSinceEpoch}_${entry.key.replaceAll('.', '')}',
            name: entry.key,
            location: location,
            ip: entry.key,
            port: 443,
            ping: entry.value,
          ));
        }
      }
      
      // 按延迟排序
      validServers.sort((a, b) => a.ping.compareTo(b.ping));
      
      if (validServers.isEmpty) {
        throw '未找到符合条件的节点\n请检查网络连接或降低筛选要求';
      }
      
      print('找到 ${validServers.length} 个符合条件的节点');
      
      // 返回请求的数量
      return validServers.take(count).toList();
      
    } catch (e) {
      print('Cloudflare 测试失败: $e');
      // 如果测试失败，返回备用服务器
      print('使用备用服务器列表');
      return getBackupServers(count: count);
    }
  }
  
  // 从 IP 段中随机采样
  static List<String> _sampleIpsFromRanges(int sampleCount) {
    final ips = <String>[];
    final random = Random();
    final samplesPerRange = max(10, sampleCount ~/ cloudflareIpRanges.length);
    
    for (final range in cloudflareIpRanges) {
      final rangeIps = _sampleFromCidr(range, samplesPerRange);
      ips.addAll(rangeIps);
      
      if (ips.length >= sampleCount) {
        break;
      }
    }
    
    // 打乱顺序
    ips.shuffle();
    
    return ips.take(sampleCount).toList();
  }
  
  // 从 CIDR 中随机采样 IP
  static List<String> _sampleFromCidr(String cidr, int count) {
    final ips = <String>[];
    
    try {
      final parts = cidr.split('/');
      final baseIp = parts[0];
      final prefixLength = int.parse(parts[1]);
      
      // 解析基础 IP（使用无符号右移避免负数）
      final ipParts = baseIp.split('.').map(int.parse).toList();
      final ipNum = ((ipParts[0] & 0xFF) << 24) | 
                    ((ipParts[1] & 0xFF) << 16) | 
                    ((ipParts[2] & 0xFF) << 8) | 
                    (ipParts[3] & 0xFF);
      
      // 计算可用 IP 数量
      final hostBits = 32 - prefixLength;
      final totalHosts = 1 << hostBits;
      
      // 随机采样
      final random = Random();
      final sampled = <int>{};
      
      while (sampled.length < count && sampled.length < totalHosts) {
        final offset = random.nextInt(totalHosts);
        if (sampled.add(offset)) {
          final sampledIpNum = ipNum + offset;
          final sampledIp = '${(sampledIpNum >> 24) & 0xFF}.${(sampledIpNum >> 16) & 0xFF}.${(sampledIpNum >> 8) & 0xFF}.${sampledIpNum & 0xFF}';
          ips.add(sampledIp);
        }
      }
    } catch (e) {
      print('解析 CIDR $cidr 失败: $e');
    }
    
    return ips;
  }
  
  // 获取备用 Cloudflare IP 列表
  static List<ServerModel> getBackupServers({int count = 5}) {
    // 一些已知的优质 Cloudflare IP
    final backupIPs = [
      {'ip': '172.67.182.2', 'ping': 50},
      {'ip': '104.21.48.84', 'ping': 55},
      {'ip': '172.67.70.89', 'ping': 60},
      {'ip': '104.25.191.12', 'ping': 65},
      {'ip': '104.25.190.12', 'ping': 70},
      {'ip': '172.67.161.89', 'ping': 75},
      {'ip': '104.19.45.12', 'ping': 80},
      {'ip': '104.19.46.12', 'ping': 85},
    ];
    
    final servers = <ServerModel>[];
    final selectedIPs = backupIPs.take(count);
    
    for (final ipInfo in selectedIPs) {
      servers.add(ServerModel(
        id: '${DateTime.now().millisecondsSinceEpoch}_${ipInfo['ip'].toString().replaceAll('.', '')}',
        name: ipInfo['ip'] as String, // 名称由调用方设置
        location: 'HKG',
        ip: ipInfo['ip'] as String,
        port: 443,
        ping: ipInfo['ping'] as int,
      ));
    }
    
    return servers;
  }

  // 批量测试IP延迟
  static Future<Map<String, int>> testLatency(List<String> ips) async {
    final latencyMap = <String, int>{};
    
    print('开始测试 ${ips.length} 个IP的延迟...');
    
    // 限制并发数量，避免过多连接
    const batchSize = 20;
    
    for (int i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize).toList();
      final futures = <Future>[];
      
      for (final ip in batch) {
        futures.add(_testSingleIpLatency(ip).then((latency) {
          latencyMap[ip] = latency;
          if (latency < 999) {
            print('IP $ip 延迟: ${latency}ms');
          }
        }).catchError((e) {
          latencyMap[ip] = 999; // 失败时设置为最大延迟
        }));
      }
      
      // 等待当前批次完成
      await Future.wait(futures);
      
      // 如果已经找到足够的低延迟节点，可以提前结束
      final goodNodes = latencyMap.values.where((latency) => latency < 200).length;
      if (goodNodes >= 10) {
        print('已找到足够的优质节点，提前结束测试');
        break;
      }
    }
    
    print('延迟测试完成，成功测试 ${latencyMap.length} 个IP');
    
    return latencyMap;
  }
  
  // 测试单个IP的延迟
  static Future<int> _testSingleIpLatency(String ip) async {
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 3);
      
      // 测试3次取平均值
      final latencies = <int>[];
      
      for (int i = 0; i < 3; i++) {
        final startTime = DateTime.now();
        
        try {
          // 使用Cloudflare的测试端点
          final uri = Uri(
            scheme: 'https',
            host: ip,
            port: 443,
            path: '/cdn-cgi/trace',
          );
          
          final request = await httpClient.getUrl(uri);
          // 设置SNI
          request.headers.set('Host', 'cloudflare.com');
          
          final response = await request.close();
          await response.drain(); // 读取并丢弃响应内容
          
          final endTime = DateTime.now();
          final latency = endTime.difference(startTime).inMilliseconds;
          
          if (response.statusCode == 200) {
            latencies.add(latency);
          }
        } catch (e) {
          // 单次测试失败，继续下一次
        }
        
        // 间隔一下再测试
        if (i < 2) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
      
      httpClient.close();
      
      // 如果所有测试都失败，返回最大延迟
      if (latencies.isEmpty) {
        return 999;
      }
      
      // 返回平均延迟
      final avgLatency = latencies.reduce((a, b) => a + b) ~/ latencies.length;
      return avgLatency;
      
    } catch (e) {
      return 999;
    }
  }
  
  // 获取可执行文件路径（保留此方法以兼容诊断工具）
  static Future<String> getExecutablePath(String executableName) async {
    return V2RayService.getExecutablePath(executableName);
  }
}
