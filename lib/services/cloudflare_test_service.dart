import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import '../models/server_model.dart';
import './v2ray_service.dart';

class CloudflareTestService {
  // 获取可执行文件路径
  static Future<String> _getExecutablePath() async {
    final exePath = await V2RayService.getExecutablePath('cftest.exe');
    
    // 验证文件是否存在
    if (!await File(exePath).exists()) {
      throw '找不到 cftest.exe，路径: $exePath';
    }
    
    return exePath;
  }
  
  // 检查 ip.txt 文件，不存在才创建
  static Future<void> _ensureIpFileExists(String ipFilePath) async {
    final ipFile = File(ipFilePath);
    
    // 只在文件不存在时创建
    if (!await ipFile.exists()) {
      print('ip.txt 不存在，创建默认配置...');
      
      // Cloudflare IP 段（使用常见的 Cloudflare IP）
      const defaultIps = '''104.16.0.0/12
172.64.0.0/13
173.245.48.0/20
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
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
''';
      
      await ipFile.writeAsString(defaultIps);
      print('已创建默认 ip.txt 文件');
    } else {
      print('ip.txt 文件已存在，使用现有配置');
    }
  }
  
  // 测试服务器
  static Future<List<ServerModel>> testServers({
    required int count,
    required int maxLatency,
    required int speed,
    required int testCount,
    String location = 'HKG',
  }) async {
    try {
      final exePath = await _getExecutablePath();
      final workDir = path.dirname(exePath);
      final resultPath = path.join(workDir, 'result.csv');
      final ipFilePath = path.join(workDir, 'ip.txt');
      
      // 确保 ip.txt 存在（只在不存在时创建）
      await _ensureIpFileExists(ipFilePath);
      
      // 添加调试信息
      print('=== Cloudflare 测试配置 ===');
      print('可执行文件: $exePath');
      print('工作目录: $workDir');
      print('IP配置文件: $ipFilePath');
      print('参数: count=$count, maxLatency=$maxLatency, speed=$speed, testCount=$testCount');
      
      // 删除旧的结果文件
      final resultFile = File(resultPath);
      if (await resultFile.exists()) {
        await resultFile.delete();
        print('已删除旧结果文件');
      }

      // 构建命令参数
      // 注意：根据 CloudflareSpeedTest 的实际参数格式调整
      final arguments = [
        '-f', ipFilePath,              // IP文件路径
        '-o', 'result.csv',            // 输出文件
        '-dd',                         // 禁用下载测试（加快速度）
        '-tl', '$maxLatency',          // 延迟上限
        '-sl', '$speed',               // 速度下限
        '-dn', '$count',               // 结果数量
        '-n', '$testCount',            // 测试次数
      ];

      print('执行命令: $exePath ${arguments.join(' ')}');

      // 执行测试
      final process = await Process.start(
        exePath,
        arguments,
        workingDirectory: workDir,
        mode: ProcessStartMode.inheritStdio, // 直接继承输入输出
      );

      // 等待进程完成
      final exitCode = await process.exitCode;
      
      print('进程退出代码: $exitCode');
      
      if (exitCode != 0) {
        // 尝试使用更简单的参数重试
        print('使用简化参数重试...');
        final simpleProcess = await Process.run(
          exePath,
          ['-f', ipFilePath, '-o', 'result.csv'],
          workingDirectory: workDir,
        );
        
        if (simpleProcess.exitCode != 0) {
          throw '测试进程异常退出\n错误代码: ${simpleProcess.exitCode}\n错误信息: ${simpleProcess.stderr}';
        }
      }

      // 等待结果文件生成
      await Future.delayed(const Duration(seconds: 1));

      // 读取结果文件
      if (!await resultFile.exists()) {
        throw '测试完成但未生成结果文件，请检查 cftest.exe 是否正常工作';
      }

      final csvContent = await resultFile.readAsString();
      final servers = _parseCsvResults(csvContent, location);
      
      if (servers.isEmpty) {
        throw '未找到符合条件的节点\n请检查网络连接或降低筛选要求';
      }
      
      print('成功获取 ${servers.length} 个节点');
      
      // 只返回请求的数量，并确保每个服务器有唯一ID
      return servers.take(count).map((server) => ServerModel(
        id: '${DateTime.now().millisecondsSinceEpoch}_${server.ip.replaceAll('.', '')}',
        name: server.name,
        location: server.location,
        ip: server.ip,
        port: server.port,
        ping: server.ping,
      )).toList();
      
    } catch (e) {
      print('Cloudflare 测试失败: $e');
      
      // 如果测试失败，返回备用服务器
      print('使用备用服务器列表');
      return getBackupServers(count: count);
    }
  }
  
  // 解析 CSV 结果（CloudflareSpeedTest 的标准格式）
  static List<ServerModel> _parseCsvResults(String csvContent, String location) {
    final servers = <ServerModel>[];
    final lines = csvContent.split('\n');
    final addedIPs = <String>{};
    
    // CloudflareSpeedTest CSV 格式通常是：IP,端口,延迟,下载速度
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      
      // 跳过可能的标题行
      if (i == 0 && line.toLowerCase().contains('ip')) continue;
      
      final parts = line.split(',');
      if (parts.length < 2) continue;
      
      final ip = parts[0].trim();
      if (ip.isEmpty || !RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(ip)) {
        continue;
      }
      
      if (addedIPs.contains(ip)) continue;
      
      addedIPs.add(ip);
      
      // 解析端口和延迟
      final port = parts.length > 1 ? (int.tryParse(parts[1].trim()) ?? 443) : 443;
      final ping = parts.length > 2 ? (int.tryParse(parts[2].trim()) ?? 999) : 999;
      
      servers.add(ServerModel(
        id: ip, // 临时ID，后续会重新生成
        name: ip,
        location: location,
        ip: ip,
        port: port,
        ping: ping,
      ));
    }
    
    // 按延迟排序
    servers.sort((a, b) => a.ping.compareTo(b.ping));
    
    return servers;
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
}
