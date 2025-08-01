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
      
      // 如果文件不存在，创建默认的 ip.txt
      if (!await ipFile.exists()) {
        print('ip.txt 不存在，创建默认配置...');
        
        // 默认的 Cloudflare IP 段
        const defaultIpRanges = '''173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/12
172.64.0.0/13
131.0.72.0/22
''';
        
        await ipFile.writeAsString(defaultIpRanges);
        print('已创建默认 ip.txt 文件');
      }
      
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
      // 如果读取失败，返回默认的 IP 段
      return [
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
        '131.0.72.0/22',
      ];
    }
  }
  
  // 测试服务器 - 不再使用 cftest.exe
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
      // 如果测试失败，返回备用服务器
      print('使用备用服务器列表');
      return getBackupServers(count: count);
    }
  }
  
  // 根据IP地址推测地理位置（简化版）
  static String _detectLocationFromIp(String ip) {
    // 这是一个简化的实现，实际上需要更复杂的IP地理位置数据库
    // 这里只是根据一些已知的Cloudflare IP段进行粗略判断
    
    final ipParts = ip.split('.').map(int.parse).toList();
    final firstOctet = ipParts[0];
    final secondOctet = ipParts[1];
    
    // 根据IP段判断大概区域
    if (firstOctet == 104) {
      if (secondOctet >= 16 && secondOctet <= 31) {
        return 'LAX'; // 美国洛杉矶
      } else if (secondOctet >= 32 && secondOctet <= 47) {
        return 'SFO'; // 美国旧金山
      }
    } else if (firstOctet == 172) {
      if (secondOctet >= 64 && secondOctet <= 71) {
        return 'HKG'; // 香港
      }
    } else if (firstOctet == 103) {
      if (secondOctet >= 21 && secondOctet <= 22) {
        return 'SIN'; // 新加坡
      } else if (secondOctet >= 31 && secondOctet <= 31) {
        return 'NRT'; // 日本
      }
    } else if (firstOctet == 141 || firstOctet == 108) {
      return 'LAX'; // 美国
    } else if (firstOctet == 188 || firstOctet == 190) {
      return 'LHR'; // 英国伦敦
    } else if (firstOctet == 197 || firstOctet == 198) {
      return 'FRA'; // 德国法兰克福
    }
    
    // 默认返回香港
    return 'HKG';
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
  
  // 获取备用 Cloudflare IP 列表
  static List<ServerModel> getBackupServers({int count = 5}) {
    // 一些已知的优质 Cloudflare IP，带有实际的地理位置
    final backupIPs = [
      {'ip': '172.67.182.2', 'ping': 50, 'location': 'HKG'},
      {'ip': '104.21.48.84', 'ping': 55, 'location': 'LAX'},
      {'ip': '172.67.70.89', 'ping': 60, 'location': 'HKG'},
      {'ip': '104.25.191.12', 'ping': 65, 'location': 'SFO'},
      {'ip': '104.25.190.12', 'ping': 70, 'location': 'SFO'},
      {'ip': '172.67.161.89', 'ping': 75, 'location': 'SIN'},
      {'ip': '104.19.45.12', 'ping': 80, 'location': 'NRT'},
      {'ip': '104.19.46.12', 'ping': 85, 'location': 'NRT'},
    ];
    
    final servers = <ServerModel>[];
    final selectedIPs = backupIPs.take(count);
    
    for (final ipInfo in selectedIPs) {
      servers.add(ServerModel(
        id: '${DateTime.now().millisecondsSinceEpoch}_${ipInfo['ip'].toString().replaceAll('.', '')}',
        name: ipInfo['ip'] as String, // 名称由调用方设置
        location: ipInfo['location'] as String,
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
}