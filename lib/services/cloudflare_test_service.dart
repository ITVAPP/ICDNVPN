import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';

class CloudflareTestService {
  // 从 ip.txt 文件读取 IP 段
  static Future<List<String>> _loadIpRanges() async {
    try {
      // 获取 ip.txt 文件路径（与可执行文件同目录）
      final exePath = Platform.resolvedExecutable;
      final workDir = path.dirname(exePath);
      final ipFilePath = path.join(workDir, 'ip.txt');
      
      final ipFile = File(ipFilePath);
      
      // 读取文件内容
      final lines = await ipFile.readAsLines();
      final ipRanges = <String>[];
      
      for (final line in lines) {
        final trimmed = line.trim();
        // 跳过空行和注释行
        if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
          ipRanges.add(trimmed);
        }
      }
      
      print('从 ip.txt 加载了 ${ipRanges.length} 个 IP 段');
      return ipRanges;
      
    } catch (e) {
      print('读取 ip.txt 失败: $e');
      // 返回最新的 Cloudflare 官方 IP 段（2025年版本）
      return [
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
        '104.16.0.0/13',
        '104.24.0.0/14',
        '172.64.0.0/13',
        '131.0.72.0/22',
      ];
    }
  }
  
  // 测试服务器
  static Future<List<ServerModel>> testServers({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'AUTO',
  }) async {
    try {
      print('=== 开始测试 Cloudflare 节点 ===');
      print('参数: count=$count, maxLatency=$maxLatency');
      
      // 从 IP 段中采样（按 /24 段采样，确保覆盖面）
      // 采样更多 IP 以确保能找到足够的优质节点
      final sampleIps = await _sampleIpsFromRanges(testCount * 5 > 200 ? 200 : testCount * 5); // 最多测试 200 个
      print('从 IP 段中采样了 ${sampleIps.length} 个 IP');
      
      // 批量测试延迟
      final latencyMap = await testLatency(sampleIps);
      
      // 筛选符合条件的服务器
      final validServers = <ServerModel>[];
      for (final entry in latencyMap.entries) {
        if (entry.value <= maxLatency) {
          // 根据IP地址判断大概位置（简化版）
          String detectedLocation = _detectLocationFromIp(entry.key);
          
          validServers.add(ServerModel(
            id: '${DateTime.now().millisecondsSinceEpoch}_${entry.key.replaceAll('.', '')}',
            name: entry.key,
            location: location == 'AUTO' ? detectedLocation : location,
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
      rethrow; // 直接抛出异常，不再使用备用服务器
    }
  }
  
  // 根据IP地址推测地理位置（返回国家代码）
  static String _detectLocationFromIp(String ip) {
    // 基于 Cloudflare IP 段的实际地理分布返回 ISO 3166-1 alpha-2 国家代码
    final ipParts = ip.split('.').map(int.parse).toList();
    final firstOctet = ipParts[0];
    final secondOctet = ipParts[1];
    
    // Cloudflare IP 段到国家代码的映射
    if (firstOctet == 104) {
      // 104.16.0.0/13 和 104.24.0.0/14 主要在美国
      return 'US';  // 美国
    } else if (firstOctet == 172 && secondOctet >= 64 && secondOctet <= 71) {
      // 172.64.0.0/13 分布全球
      if (secondOctet >= 64 && secondOctet <= 66) {
        return 'US';  // 美国
      } else if (secondOctet >= 67 && secondOctet <= 68) {
        return 'HK';  // 香港
      } else {
        return 'SG';  // 新加坡
      }
    } else if (firstOctet == 173 && secondOctet >= 245 && secondOctet <= 245) {
      // 173.245.48.0/20 美国
      return 'US';  // 美国
    } else if (firstOctet == 103) {
      // 103.21.244.0/22, 103.22.200.0/22 - 亚太地区
      if (secondOctet >= 21 && secondOctet <= 22) {
        return 'SG';  // 新加坡
      }
      // 103.31.4.0/22 - 东亚
      else if (secondOctet == 31) {
        return 'JP';  // 日本
      }
    } else if (firstOctet == 141 && secondOctet >= 101 && secondOctet <= 101) {
      // 141.101.64.0/18 美国
      return 'US';  // 美国
    } else if (firstOctet == 108 && secondOctet >= 162 && secondOctet <= 162) {
      // 108.162.192.0/18 美国
      return 'US';  // 美国
    } else if (firstOctet == 190 && secondOctet >= 93 && secondOctet <= 93) {
      // 190.93.240.0/20 南美
      return 'BR';  // 巴西
    } else if (firstOctet == 188 && secondOctet >= 114 && secondOctet <= 114) {
      // 188.114.96.0/20 欧洲
      return 'DE';  // 德国
    } else if (firstOctet == 197 && secondOctet >= 234 && secondOctet <= 234) {
      // 197.234.240.0/22 非洲
      return 'ZA';  // 南非
    } else if (firstOctet == 198 && secondOctet >= 41 && secondOctet <= 41) {
      // 198.41.128.0/17 美国
      return 'US';  // 美国
    } else if (firstOctet == 162 && secondOctet >= 158 && secondOctet <= 159) {
      // 162.158.0.0/15 全球分布
      if (secondOctet == 158) {
        return 'GB';  // 英国
      } else {
        return 'NL';  // 荷兰
      }
    } else if (firstOctet == 131 && secondOctet == 0) {
      // 131.0.72.0/22 美国
      return 'US';  // 美国
    }
    
    // 默认返回美国（Cloudflare 的主要节点分布地）
    return 'US';
  }
  
  // 从 CIDR 中按 /24 段采样 IP（匹配 CloudflareSpeedTest 算法）
  static List<String> _sampleFromCidr(String cidr, int count) {
    final ips = <String>[];
    
    try {
      final parts = cidr.split('/');
      final baseIp = parts[0];
      final prefixLength = int.parse(parts[1]);
      
      // 解析基础 IP（使用无符号右移避免负数）
      final ipParts = baseIp.split('.').map(int.parse).toList();
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
        final randomLast = random.nextInt(lastSegmentRange);
        final selectedIp = startIp + randomLast;
        final ip = '${(selectedIp >> 24) & 0xFF}.${(selectedIp >> 16) & 0xFF}.${(selectedIp >> 8) & 0xFF}.${selectedIp & 0xFF}';
        ips.add(ip);
        return ips;
      }
      
      // 对于大于 /24 的段，遍历每个 /24 子段
      var currentIp = startIp;
      while (currentIp <= endIp && ips.length < count) {
        // 确保当前 IP 在范围内
        if (currentIp > endIp) break;
        
        // 在当前 /24 段中随机选择一个 IP（最后一位随机 0-255）
        final randomLast = random.nextInt(256);
        final selectedIp = (currentIp & 0xFFFFFF00) | randomLast;
        
        // 确保选择的 IP 在原始 CIDR 范围内
        if (selectedIp >= startIp && selectedIp <= endIp) {
          final ip = '${(selectedIp >> 24) & 0xFF}.${(selectedIp >> 16) & 0xFF}.${(selectedIp >> 8) & 0xFF}.${selectedIp & 0xFF}';
          ips.add(ip);
        }
        
        // 移动到下一个 /24 段（第三段+1）
        currentIp = ((currentIp >> 8) + 1) << 8;
      }
    } catch (e) {
      print('解析 CIDR $cidr 失败: $e');
    }
    
    return ips;
  }
  
  // 从 IP 段中采样（优化算法：每个 /24 段采样一个）
  static Future<List<String>> _sampleIpsFromRanges(int targetCount) async {
    final ips = <String>[];
    
    // 加载 IP 段
    final cloudflareIpRanges = await _loadIpRanges();
    
    // 第一轮：每个 CIDR 按 /24 段采样
    for (final range in cloudflareIpRanges) {
      final rangeIps = _sampleFromCidr(range, targetCount);
      ips.addAll(rangeIps);
      
      if (ips.length >= targetCount) {
        break;
      }
    }
    
    // 如果第一轮采样不够，进行第二轮随机补充
    if (ips.length < targetCount) {
      print('第一轮采样获得 ${ips.length} 个IP，继续随机补充...');
      final random = Random();
      final additionalNeeded = targetCount - ips.length;
      
      // 从较大的 IP 段中额外采样
      final largeRanges = cloudflareIpRanges.where((range) => range.contains('/12') || range.contains('/13')).toList();
      
      for (final range in largeRanges) {
        final parts = range.split('/');
        final baseIp = parts[0];
        final prefixLength = int.parse(parts[1]);
        
        // 对于大段，每次多采样一些
        final samplesToTake = (additionalNeeded / largeRanges.length).ceil();
        
        for (int i = 0; i < samplesToTake && ips.length < targetCount; i++) {
          // 随机生成一个 IP
          final ipParts = baseIp.split('.').map(int.parse).toList();
          var ipNum = ((ipParts[0] & 0xFF) << 24) | 
                      ((ipParts[1] & 0xFF) << 16) | 
                      ((ipParts[2] & 0xFF) << 8) | 
                      (ipParts[3] & 0xFF);
          
          final hostBits = 32 - prefixLength;
          final offset = random.nextInt(1 << hostBits);
          final randomIpNum = ipNum + offset;
          
          final randomIp = '${(randomIpNum >> 24) & 0xFF}.${(randomIpNum >> 16) & 0xFF}.${(randomIpNum >> 8) & 0xFF}.${randomIpNum & 0xFF}';
          
          // 避免重复
          if (!ips.contains(randomIp)) {
            ips.add(randomIp);
          }
        }
      }
    }
    
    // 打乱顺序
    ips.shuffle();
    
    print('总共采样了 ${ips.length} 个IP进行测试');
    
    return ips.take(targetCount).toList();
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
      // 对于服务器列表中已有的节点，直接连接测试
      final socket = await Socket.connect(
        ip,
        443,
        timeout: const Duration(seconds: 3),
      );
      
      final startTime = DateTime.now();
      
      // 发送简单的TLS Client Hello来测试连接
      socket.add([
        0x16, 0x03, 0x01, 0x00, 0x04, // TLS Handshake
        0x01, 0x00, 0x00, 0x00 // Client Hello (简化版)
      ]);
      
      // 等待响应
      await socket.first.timeout(const Duration(seconds: 2));
      
      final endTime = DateTime.now();
      final latency = endTime.difference(startTime).inMilliseconds;
      
      socket.destroy();
      
      return latency;
      
    } catch (e) {
      // 如果Socket连接失败，尝试HTTP方式
      try {
        final httpClient = HttpClient();
        httpClient.connectionTimeout = const Duration(seconds: 3);
        httpClient.badCertificateCallback = (cert, host, port) => true;
        
        final startTime = DateTime.now();
        
        final uri = Uri(
          scheme: 'https',
          host: ip,
          port: 443,
          path: '/cdn-cgi/trace',
        );
        
        final request = await httpClient.getUrl(uri);
        request.headers.set('Host', 'cloudflare.com');
        
        final response = await request.close();
        await response.drain();
        
        final endTime = DateTime.now();
        final latency = endTime.difference(startTime).inMilliseconds;
        
        httpClient.close();
        
        if (response.statusCode == 200 || response.statusCode == 403) {
          return latency;
        }
        
        return 999;
      } catch (e2) {
        return 999;
      }
    }
  }
}