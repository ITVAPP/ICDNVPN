import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';
import './v2ray_service.dart';

class CloudflareTestService {
  static Future<String> _getExecutablePath() async {
    return V2RayService.getExecutablePath('cftest.exe');
  }
  
  static Future<List<ServerModel>> testServers({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'HKG',
  }) async {
    final exePath = await _getExecutablePath();
    final resultPath = path.join(path.dirname(exePath), 'result.json');
    final ipFilePath = path.join(path.dirname(exePath), 'ip.txt');
    
    // 添加调试信息
    print('Starting Cloudflare test with parameters:');
    print('  Count: $count');
    print('  Max Latency: ${maxLatency}ms');
    print('  Min Speed: ${speed}MB/s');
    print('  Test Count: $testCount');
    print('  Location: $location');
    
    // 检查文件是否存在
    if (!await File(exePath).exists()) {
      throw 'cftest.exe 未找到，请确保程序文件完整';
    }
    if (!await File(ipFilePath).exists()) {
      throw 'ip.txt 配置文件未找到，请确保程序文件完整';
    }

    // 删除旧的结果文件
    final resultFile = File(resultPath);
    if (await resultFile.exists()) {
      await resultFile.delete();
    }

    try {
      final process = await Process.start(
        exePath,
        [
          '-f', ipFilePath,
          '-cfcolo', location,
          '-dn', '$count',
          '-tl', '$maxLatency',
          '-sl', '$speed',
          '-dm', '$testCount'
        ],
        workingDirectory: path.dirname(exePath),
        mode: ProcessStartMode.inheritStdio,
      );

      // 等待进程完成
      final exitCode = await process.exitCode;
      
      if (exitCode != 0) {
        throw '测试进程异常退出，错误代码: $exitCode';
      }

      // 等待结果文件生成
      await Future.delayed(const Duration(milliseconds: 500));

      // 读取结果文件
      if (!await resultFile.exists()) {
        throw '测试完成但未生成结果文件';
      }

      final String jsonContent = await resultFile.readAsString();
      
      // 解析结果
      List<dynamic> results;
      try {
        results = jsonDecode(jsonContent);
      } catch (e) {
        throw '解析测试结果失败: $e';
      }
      
      if (results.isEmpty) {
        throw '未找到符合条件的节点，请尝试降低要求';
      }
      
      // 转换为服务器列表
      final List<ServerModel> servers = [];
      final Set<String> addedIPs = {}; // 用于去重
      
      for (var result in results) {
        final ip = result['ip'] as String;
        
        // 跳过重复的IP
        if (addedIPs.contains(ip)) {
          continue;
        }
        addedIPs.add(ip);
        
        servers.add(ServerModel(
          id: DateTime.now().millisecondsSinceEpoch.toString() + '_${servers.length}',
          name: ip, // 名称将在调用方设置
          location: location,
          ip: ip,
          port: result['port'] ?? 443,
          ping: result['delay'] ?? 999,
        ));
      }

      print('Successfully tested and found ${servers.length} servers');
      return servers;
    } catch (e) {
      print('Cloudflare test failed: $e');
      throw '节点测试失败: $e';
    }
  }
  
  // 测试单个IP列表的延迟
  static Future<Map<String, int>> testLatency(List<String> ips) async {
    if (ips.isEmpty) return {};
    
    final exePath = await _getExecutablePath();
    final resultPath = path.join(path.dirname(exePath), 'result.json');
    
    try {
      // 删除旧的结果文件
      final resultFile = File(resultPath);
      if (await resultFile.exists()) {
        await resultFile.delete();
      }
      
      // 执行测试
      final process = await Process.start(
        exePath,
        ['-ip', ips.join(',')],
        workingDirectory: path.dirname(exePath),
        mode: ProcessStartMode.inheritStdio,
      );
      
      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw '延迟测试失败，错误代码: $exitCode';
      }
      
      // 读取结果
      if (!await resultFile.exists()) {
        throw '延迟测试完成但未生成结果文件';
      }
      
      final String jsonContent = await resultFile.readAsString();
      final List<dynamic> results = jsonDecode(jsonContent);
      
      // 转换为Map
      final Map<String, int> latencyMap = {};
      for (var result in results) {
        latencyMap[result['ip']] = result['delay'] ?? 999;
      }
      
      return latencyMap;
    } catch (e) {
      print('Latency test failed: $e');
      return {};
    }
  }
}