import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';

class CloudflareTestService {
  // 日志文件
  static File? _logFile;
  static IOSink? _logSink;
  
  // 初始化日志文件
  static Future<void> _initLog() async {
    try {
      if (_logFile == null) {
        // 获取日志目录（优先级：用户主目录 > 临时目录 > 当前目录）
        Directory logDir;
        
        try {
          // 尝试使用平台特定的目录
          if (Platform.isWindows) {
            final appData = Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'];
            if (appData != null) {
              logDir = Directory(path.join(appData, 'CloudflareTest', 'logs'));
            } else {
              logDir = Directory(path.join(Directory.current.path, 'logs'));
            }
          } else if (Platform.isMacOS || Platform.isLinux) {
            final home = Platform.environment['HOME'];
            if (home != null) {
              logDir = Directory(path.join(home, '.cloudflare_test', 'logs'));
            } else {
              logDir = Directory(path.join(Directory.current.path, 'logs'));
            }
          } else if (Platform.isAndroid || Platform.isIOS) {
            // 移动平台使用临时目录
            logDir = Directory(path.join(Directory.systemTemp.path, 'cloudflare_test', 'logs'));
          } else {
            // 其他平台使用当前目录
            logDir = Directory(path.join(Directory.current.path, 'logs'));
          }
        } catch (e) {
          // 如果上述都失败，使用当前目录
          logDir = Directory(path.join(Directory.current.path, 'logs'));
        }
        
        if (!await logDir.exists()) {
          await logDir.create(recursive: true);
        }
        
        // 创建带时间戳的日志文件
        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
        _logFile = File(path.join(logDir.path, 'cloudflare_test_$timestamp.log'));
        _logSink = _logFile!.openWrite(mode: FileMode.append);
        
        await _log('=== Cloudflare测试日志开始 ===');
        await _log('日志文件: ${_logFile!.path}');
        await _log('平台: ${Platform.operatingSystem}');
        await _log('Dart版本: ${Platform.version}');
      }
    } catch (e) {
      print('初始化日志失败: $e');
      print('将仅使用控制台输出');
    }
  }
  
  // 写入日志（同时输出到控制台和文件）
  static Future<void> _log(String message) async {
    final timestamp = DateTime.now().toIso8601String();
    final logMessage = '[$timestamp] $message';
    
    // 输出到控制台
    print(logMessage);
    
    // 写入文件
    try {
      if (_logSink != null) {
        _logSink!.writeln(logMessage);
        await _logSink!.flush();
      }
    } catch (e) {
      print('写入日志失败: $e');
    }
  }
  
  // 关闭日志文件
  static Future<void> _closeLog() async {
    try {
      await _logSink?.close();
      _logSink = null;
      _logFile = null;
    } catch (e) {
      print('关闭日志失败: $e');
    }
  }
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
  
  // 测试服务器
  static Future<List<ServerModel>> testServers({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'AUTO',
  }) async {
    // 初始化日志
    await _initLog();
    
    try {
      await _log('=== 开始测试 Cloudflare 节点 ===');
      await _log('参数: count=$count, maxLatency=$maxLatency, speed=$speed, testCount=$testCount, location=$location');
      
      // 显示使用的IP段
      await _log('Cloudflare IP段列表:');
      for (var i = 0; i < _cloudflareIpRanges.length; i++) {
        await _log('  ${i + 1}. ${_cloudflareIpRanges[i]}');
      }
      
      // 从 IP 段中采样（按 /24 段采样，确保覆盖面）
      // 采样更多 IP 以确保能找到足够的优质节点
      final targetSampleCount = testCount * 5 > 200 ? 200 : testCount * 5;
      await _log('目标采样数量: $targetSampleCount');
      
      final sampleIps = await _sampleIpsFromRanges(targetSampleCount); // 最多测试 200 个
      await _log('从 IP 段中采样了 ${sampleIps.length} 个 IP');
      
      if (sampleIps.isEmpty) {
        await _log('错误：无法生成采样IP');
        await _closeLog();
        throw '无法生成测试IP，请检查配置';
      }
      
      // 记录前10个采样IP作为示例
      if (sampleIps.isNotEmpty) {
        final examples = sampleIps.take(10).join(', ');
        await _log('采样IP示例: $examples');
      }
      
      // 批量测试延迟
      await _log('开始批量测试延迟...');
      final latencyMap = await testLatency(sampleIps);
      await _log('延迟测试完成，获得 ${latencyMap.length} 个结果');
      
      // 统计延迟分布
      final latencyStats = <String, int>{};
      for (final latency in latencyMap.values) {
        if (latency < 100) {
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
      await _log('延迟分布: $latencyStats');
      
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
      
      await _log('筛选后找到 ${validServers.length} 个符合条件的节点（延迟<=$maxLatency ms）');
      
      // 按延迟排序
      validServers.sort((a, b) => a.ping.compareTo(b.ping));
      
      if (validServers.isEmpty) {
        await _log('错误：未找到符合条件的节点');
        await _log('建议：');
        await _log('  1. 检查网络连接是否正常');
        await _log('  2. 降低延迟要求（当前: $maxLatency ms）');
        await _log('  3. 增加测试数量（当前: $testCount）');
        await _log('  4. 检查防火墙是否阻止了443端口');
        await _closeLog();
        throw '未找到符合条件的节点\n请检查网络连接或降低筛选要求';
      }
      
      // 记录最优的几个节点
      await _log('找到 ${validServers.length} 个符合条件的节点');
      final topNodes = validServers.take(5);
      for (final node in topNodes) {
        await _log('优质节点: ${node.ip} - ${node.ping}ms - ${node.location}');
      }
      
      // 返回请求的数量
      final result = validServers.take(count).toList();
      await _log('返回 ${result.length} 个节点');
      await _log('=== 测试完成 ===');
      await _closeLog();
      
      return result;
      
    } catch (e) {
      await _log('Cloudflare 测试失败: $e');
      await _log('错误堆栈: ${StackTrace.current}');
      await _closeLog();
      rethrow; // 直接抛出异常，不再使用备用服务器
    }
  }
  
  // 根据IP地址推测地理位置（返回国家代码）
  static String _detectLocationFromIp(String ip) {
    // 基于 Cloudflare IP 段的实际地理分布返回 ISO 3166-1 alpha-2 国家代码
    final ipParts = ip.split('.').map(int.parse).toList();
    final firstOctet = ipParts[0];
    final secondOctet = ipParts[1];
    
    // Cloudflare IP 段到国家代码的映射（基于2025年最新数据）
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
    } else if (firstOctet == 141 && secondOctet >= 101) {
      // 141.101.64.0/18 美国
      return 'US';  // 美国
    } else if (firstOctet == 108 && secondOctet >= 162) {
      // 108.162.192.0/18 美国
      return 'US';  // 美国
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
      return 'US';  // 美国
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
      if (parts.length != 2) {
        _log('无效的CIDR格式: $cidr');
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
        _log('无效的IP格式: $baseIp');
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
      _log('解析 CIDR $cidr 失败: $e'); // 不使用await
    }
    
    return ips;
  }
  
  // 从 IP 段中采样（优化算法：每个 /24 段采样一个）
  static Future<List<String>> _sampleIpsFromRanges(int targetCount) async {
    final ips = <String>[];
    
    // 使用内置的 Cloudflare IP 段常量
    final cloudflareIpRanges = _cloudflareIpRanges;
    await _log('使用 ${cloudflareIpRanges.length} 个内置IP段');
    
    // 第一轮：每个 CIDR 按 /24 段采样
    for (final range in cloudflareIpRanges) {
      final rangeIps = _sampleFromCidr(range, targetCount);
      ips.addAll(rangeIps);
      
      if (ips.length >= targetCount) {
        break;
      }
    }
    
    await _log('第一轮采样获得 ${ips.length} 个IP');
    
    // 如果第一轮采样不够，进行第二轮随机补充
    if (ips.length < targetCount) {
      await _log('第一轮采样不足，需要 $targetCount 个，继续随机补充...');
      final random = Random();
      final additionalNeeded = targetCount - ips.length;
      
      // 从较大的 IP 段中额外采样
      final largeRanges = cloudflareIpRanges.where((range) {
        final prefix = int.parse(range.split('/')[1]);
        return prefix <= 18;  // 选择 /18 及更大的段进行额外采样
      }).toList();
      
      await _log('从 ${largeRanges.length} 个大IP段中额外采样');
      
      for (final range in largeRanges) {
        final parts = range.split('/');
        final baseIp = parts[0];
        final prefixLength = int.parse(parts[1]);
        
        // 对于大段，每次多采样一些
        final samplesToTake = (additionalNeeded / largeRanges.length).ceil();
        
        for (int i = 0; i < samplesToTake && ips.length < targetCount; i++) {
          try {
            // 随机生成一个 IP
            final ipParts = baseIp.split('.').map(int.parse).toList();
            var ipNum = ((ipParts[0] & 0xFF) << 24) | 
                        ((ipParts[1] & 0xFF) << 16) | 
                        ((ipParts[2] & 0xFF) << 8) | 
                        (ipParts[3] & 0xFF);
            
            final hostBits = 32 - prefixLength;
            if (hostBits > 0 && hostBits <= 32) {
              final mask = prefixLength == 0 ? 0 : (0xFFFFFFFF << hostBits) & 0xFFFFFFFF;
              final maxOffset = (1 << hostBits) - 1;
              final offset = random.nextInt(maxOffset + 1);
              final randomIpNum = (ipNum & mask) | offset;  // 使用掩码确保在范围内
              
              // 确保生成的IP有效
              if (randomIpNum >= 0 && randomIpNum <= 0xFFFFFFFF) {
                final randomIp = '${(randomIpNum >> 24) & 0xFF}.${(randomIpNum >> 16) & 0xFF}.${(randomIpNum >> 8) & 0xFF}.${randomIpNum & 0xFF}';
                
                // 避免重复和特殊地址
                if (!ips.contains(randomIp) && (randomIpNum & 0xFF) != 0 && (randomIpNum & 0xFF) != 255) {
                  ips.add(randomIp);
                }
              }
            }
          } catch (e) {
            await _log('生成随机IP失败: $e');
          }
        }
      }
    }
    
    // 打乱顺序
    ips.shuffle();
    
    await _log('总共采样了 ${ips.length} 个IP进行测试');
    
    return ips.take(targetCount).toList();
  }

  // 批量测试IP延迟
  static Future<Map<String, int>> testLatency(List<String> ips) async {
    final latencyMap = <String, int>{};
    
    if (ips.isEmpty) {
      await _log('警告：没有IP需要测试');
      return latencyMap;
    }
    
    await _log('开始测试 ${ips.length} 个IP的延迟...');
    
    // 限制并发数量，避免过多连接
    const batchSize = 20;
    int successCount = 0;
    int failCount = 0;
    
    for (int i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize).toList();
      final futures = <Future>[];
      
      await _log('测试批次 ${(i / batchSize).floor() + 1}/${((ips.length - 1) / batchSize).floor() + 1}，包含 ${batch.length} 个IP');
      
      for (final ip in batch) {
        futures.add(_testSingleIpLatency(ip).then((latency) {
          latencyMap[ip] = latency;
          if (latency < 999) {
            successCount++;
            _log('✓ IP $ip 延迟: ${latency}ms'); // 不使用await
          } else {
            failCount++;
          }
        }).catchError((e) {
          failCount++;
          latencyMap[ip] = 999; // 失败时设置为最大延迟
          _log('× IP $ip 测试异常: $e');
          return null;
        }));
      }
      
      // 等待当前批次完成
      try {
        await Future.wait(futures);
      } catch (e) {
        await _log('批次测试出现异常: $e');
      }
      
      await _log('当前进度: 成功 $successCount，失败 $failCount');
      
      // 如果已经找到足够的低延迟节点，可以提前结束
      final goodNodes = latencyMap.values.where((latency) => latency < 200).length;
      if (goodNodes >= 10) {
        await _log('已找到 $goodNodes 个优质节点（<200ms），提前结束测试');
        break;
      }
      
      // 如果失败率太高，给出警告
      if (failCount > successCount && i > batchSize * 2) {
        await _log('警告：失败率过高（失败 $failCount，成功 $successCount），可能存在网络问题');
      }
    }
    
    await _log('延迟测试完成，成功测试 ${latencyMap.length} 个IP（成功: $successCount，失败: $failCount）');
    
    if (successCount == 0) {
      await _log('错误：所有IP测试都失败了，请检查：');
      await _log('  1. 网络连接是否正常');
      await _log('  2. 防火墙是否阻止了443端口');
      await _log('  3. DNS解析是否正常');
    }
    
    return latencyMap;
  }
  
  // 测试单个IP的延迟
  static Future<int> _testSingleIpLatency(String ip) async {
    Socket? socket;
    
    try {
      // 对于服务器列表中已有的节点，直接连接测试
      socket = await Socket.connect(
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
      // 确保socket被关闭
      socket?.destroy();
      
      // 记录Socket连接失败的详细信息
      await _log('× Socket连接 $ip:443 失败: ${e.runtimeType} - $e');
      
      // 如果Socket连接失败，尝试HTTP方式
      HttpClient? httpClient;
      try {
        await _log('尝试HTTP方式测试 $ip');
        httpClient = HttpClient();
        httpClient.connectionTimeout = const Duration(seconds: 3);
        httpClient.badCertificateCallback = (cert, host, port) => true;
        
        final startTime = DateTime.now();
        
        final uri = Uri(
          scheme: 'https',
          host: ip,
          port: 443,
          path: '/cdn-cgi/trace',
        );
        
        await _log('请求URL: $uri');
        
        final request = await httpClient.getUrl(uri);
        request.headers.set('Host', 'cloudflare.com');
        request.headers.set('User-Agent', 'CloudflareSpeedTest/1.0');
        
        final response = await request.close();
        await response.drain();
        
        final endTime = DateTime.now();
        final latency = endTime.difference(startTime).inMilliseconds;
        
        httpClient.close();
        
        if (response.statusCode == 200 || response.statusCode == 403) {
          await _log('✓ HTTP测试 $ip 成功，状态码: ${response.statusCode}，延迟: ${latency}ms');
          return latency;
        }
        
        await _log('× HTTP测试 $ip 返回异常状态码: ${response.statusCode}');
        return 999;
      } catch (e2) {
        // 确保httpClient被关闭
        httpClient?.close();
        await _log('× HTTP测试 $ip 失败: ${e2.runtimeType} - $e2');
        return 999;
      }
    }
  }
}
