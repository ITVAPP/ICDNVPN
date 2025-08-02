import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';
import '../utils/log_service.dart';

class CloudflareTestService {
  // 日志标签
  static const String _logTag = 'CloudflareTest';
  
  // 获取日志服务实例
  static LogService get _log => LogService.instance;
  
  // 添加缺失的常量定义
  static const int _defaultPort = 443; // HTTPS 标准端口
  static const Duration _tcpTimeout = Duration(seconds: 1); // TCP连接超时时间
  
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
  
  // 测试服务器 - 保持原有的公共接口
  static Future<List<ServerModel>> testServers({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'AUTO',
  }) async {
    try {
      await _log.info('=== 开始测试 Cloudflare 节点 ===', tag: _logTag);
      await _log.info('参数: count=$count, maxLatency=$maxLatency, speed=$speed, testCount=$testCount, location=$location', tag: _logTag);
      
      // 定义测试端口（使用HTTPS标准端口）
      const int testPort = 443;
      
      // 显示使用的IP段
      await _log.debug('Cloudflare IP段列表:', tag: _logTag);
      for (var i = 0; i < _cloudflareIpRanges.length; i++) {
        await _log.debug('  ${i + 1}. ${_cloudflareIpRanges[i]}', tag: _logTag);
      }
      
      // 从 IP 段中采样（按 /24 段采样，确保覆盖面）
      final targetSampleCount = testCount * 5 > 200 ? 200 : testCount * 5;
      await _log.info('目标采样数量: $targetSampleCount', tag: _logTag);
      
      final sampleIps = await _sampleIpsFromRanges(targetSampleCount);
      await _log.info('从 IP 段中采样了 ${sampleIps.length} 个 IP', tag: _logTag);
      
      if (sampleIps.isEmpty) {
        await _log.error('无法生成采样IP', tag: _logTag);
        throw '无法生成测试IP，请检查配置';
      }
      
      // 记录前10个采样IP作为示例
      if (sampleIps.isNotEmpty) {
        final examples = sampleIps.take(10).join(', ');
        await _log.debug('采样IP示例: $examples', tag: _logTag);
      }
      
      // 批量测试延迟
      await _log.info('开始批量测试延迟...', tag: _logTag);
      final latencyMap = await testLatency(sampleIps, testPort);
      await _log.info('延迟测试完成，获得 ${latencyMap.length} 个结果', tag: _logTag);
      
      // 统计延迟分布
      final latencyStats = <String, int>{};
      for (final latency in latencyMap.values) {
        if (latency < 0) {
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
      
      // 筛选符合条件的服务器
      final validServers = <ServerModel>[];
      for (final entry in latencyMap.entries) {
        if (entry.value > 0 && entry.value <= maxLatency) {
          // 修正：使用正确的变量名和方法名
          String detectedLocation = _detectLocationFromIp(entry.key);
          
          validServers.add(ServerModel(
            id: '${DateTime.now().millisecondsSinceEpoch}_${entry.key.replaceAll('.', '')}',
            name: entry.key,  // 修正：使用 entry.key 作为名称
            location: location == 'AUTO' ? detectedLocation : location,  // 修正：使用 detectedLocation
            ip: entry.key,    // 修正：使用 entry.key
            port: testPort,   // 使用配置的端口
            ping: entry.value, // 修正：使用 entry.value
          ));
        }
      }
      
      await _log.info('筛选后找到 ${validServers.length} 个符合条件的节点（延迟<=$maxLatency ms）', tag: _logTag);
      
      // 按延迟排序
      validServers.sort((a, b) => a.ping.compareTo(b.ping));
      
      if (validServers.isEmpty) {
        await _log.error('未找到符合条件的节点', tag: _logTag);
        await _log.warn('建议：', tag: _logTag);
        await _log.warn('  1. 检查网络连接是否正常', tag: _logTag);
        await _log.warn('  2. 降低延迟要求（当前: $maxLatency ms）', tag: _logTag);
        await _log.warn('  3. 增加测试数量（当前: $testCount）', tag: _logTag);
        await _log.warn('  4. 检查防火墙是否阻止了443端口', tag: _logTag);
        throw '未找到符合条件的节点\n请检查网络连接或降低筛选要求';
      }
      
      // 记录最优的几个节点
      await _log.info('找到 ${validServers.length} 个符合条件的节点', tag: _logTag);
      final topNodes = validServers.take(5);
      for (final node in topNodes) {
        await _log.info('优质节点: ${node.ip} - ${node.ping}ms - ${node.location}', tag: _logTag);
      }
      
      // 返回请求的数量
      final result = validServers.take(count).toList();
      await _log.info('返回 ${result.length} 个节点', tag: _logTag);
      await _log.info('=== 测试完成 ===', tag: _logTag);
      
      return result;
      
    } catch (e, stackTrace) {
      await _log.error('Cloudflare 测试失败', tag: _logTag, error: e, stackTrace: stackTrace);
      rethrow;
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
  
  // 从 IP 段中采样（保持原有方法）
  static Future<List<String>> _sampleIpsFromRanges(int targetCount) async {
    final ips = <String>[];
    
    // 使用内置的 Cloudflare IP 段常量
    final cloudflareIpRanges = _cloudflareIpRanges;
    await _log.debug('使用 ${cloudflareIpRanges.length} 个内置IP段', tag: _logTag);
    
    // 第一轮：每个 CIDR 按 /24 段采样
    for (final range in cloudflareIpRanges) {
      final rangeIps = _sampleFromCidr(range, targetCount);
      ips.addAll(rangeIps);
      
      if (ips.length >= targetCount) {
        break;
      }
    }
    
    await _log.debug('第一轮采样获得 ${ips.length} 个IP', tag: _logTag);
    
    // 如果第一轮采样不够，进行第二轮随机补充
    if (ips.length < targetCount) {
      await _log.debug('第一轮采样不足，需要 $targetCount 个，继续随机补充...', tag: _logTag);
      final random = Random();
      final additionalNeeded = targetCount - ips.length;
      
      // 从较大的 IP 段中额外采样
      final largeRanges = cloudflareIpRanges.where((range) {
        final prefix = int.parse(range.split('/')[1]);
        return prefix <= 18;  // 选择 /18 及更大的段进行额外采样
      }).toList();
      
      await _log.debug('从 ${largeRanges.length} 个大IP段中额外采样', tag: _logTag);
      
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
            await _log.warn('生成随机IP失败: $e', tag: _logTag);
          }
        }
      }
    }
    
    // 打乱顺序
    ips.shuffle();
    
    await _log.info('总共采样了 ${ips.length} 个IP进行测试', tag: _logTag);
    
    return ips.take(targetCount).toList();
  }

  // 批量测试IP延迟 - 保持原有的公共接口
  static Future<Map<String, int>> testLatency(List<String> ips, [int? port]) async {
    final testPort = port ?? _defaultPort;
    final latencyMap = <String, int>{};
    
    if (ips.isEmpty) {
      await _log.warn('没有IP需要测试', tag: _logTag);
      return latencyMap;
    }
    
    await _log.info('开始测试 ${ips.length} 个IP的延迟...', tag: _logTag);
    
    // 限制并发数量（与开源项目类似的并发控制）
    const batchSize = 30;  // 提高并发数
    int successCount = 0;
    int failCount = 0;
    
    for (int i = 0; i < ips.length; i += batchSize) {
      final batch = ips.skip(i).take(batchSize).toList();
      final futures = <Future>[];
      
      await _log.debug('测试批次 ${(i / batchSize).floor() + 1}/${((ips.length - 1) / batchSize).floor() + 1}，包含 ${batch.length} 个IP', tag: _logTag);
      
      for (final ip in batch) {
        futures.add(_testSingleIpLatency(ip, testPort).then((latency) {
          latencyMap[ip] = latency;
          if (latency > 0 && latency < 999) {
            successCount++;
            _log.debug('✓ IP $ip 延迟: ${latency}ms', tag: _logTag);
          } else {
            failCount++;
          }
        }).catchError((e) {
          failCount++;
          latencyMap[ip] = 999; // 失败时设置为最大延迟
          _log.debug('× IP $ip 测试异常: $e', tag: _logTag);
          return null;
        }));
      }
      
      // 等待当前批次完成
      try {
        await Future.wait(futures);
      } catch (e) {
        await _log.warn('批次测试出现异常: $e', tag: _logTag);
      }
      
      await _log.debug('当前进度: 成功 $successCount，失败 $failCount', tag: _logTag);
      
      // 如果已经找到足够的低延迟节点，可以提前结束
      final goodNodes = latencyMap.values.where((latency) => latency > 0 && latency < 200).length;
      if (goodNodes >= 10) {
        await _log.info('已找到 $goodNodes 个优质节点（<200ms），提前结束测试', tag: _logTag);
        break;
      }
      
      // 如果失败率太高，给出警告
      if (failCount > successCount && i > batchSize * 2) {
        await _log.warn('失败率过高（失败 $failCount，成功 $successCount），可能存在网络问题', tag: _logTag);
      }
    }
    
    await _log.info('延迟测试完成，成功测试 ${latencyMap.length} 个IP（成功: $successCount，失败: $failCount）', tag: _logTag);
    
    if (successCount == 0) {
      await _log.error('所有IP测试都失败了，请检查：', tag: _logTag);
      await _log.error('  1. 网络连接是否正常', tag: _logTag);
      await _log.error('  2. 防火墙是否阻止了443端口', tag: _logTag);
      await _log.error('  3. DNS解析是否正常', tag: _logTag);
    }
    
    return latencyMap;
  }
  
  // 测试单个IP的延迟 - 使用简单的TCP连接（类似开源项目）
  static Future<int> _testSingleIpLatency(String ip, [int? port]) async {
    final testPort = port ?? _defaultPort;
    const int pingTimes = 3; // 测试次数（与开源项目一致）
    int successCount = 0;
    int totalLatency = 0;
    
    // 进行多次测试取平均值（与开源项目一致）
    for (int i = 0; i < pingTimes; i++) {
      try {
        final stopwatch = Stopwatch()..start();
        
        // 简单的TCP连接测试（与开源项目一致）
        final socket = await Socket.connect(
          ip,
          testPort,
          timeout: _tcpTimeout,  // 1秒超时（与开源项目一致）
        );
        
        stopwatch.stop();
        socket.destroy();
        
        final latency = stopwatch.elapsedMilliseconds;
        if (latency > 0) {
          successCount++;
          totalLatency += latency;
        }
      } catch (e) {
        // 连接失败，继续下一次测试
        continue;
      }
    }
    
    // 如果一次都没成功，返回失败标记
    if (successCount == 0) {
      return 999;
    }
    
    // 返回平均延迟
    return totalLatency ~/ successCount;
  }
}
