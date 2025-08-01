import 'dart:io';
import 'dart:convert';
import 'dart:async';

class SpeedTestService {
  static const List<String> testUrls = [
    'https://speed.cloudflare.com/__down?bytes=10000000', // 10MB
    'https://www.google.com/images/branding/googlelogo/1x/googlelogo_color_272x92dp.png',
    'https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png',
  ];

  // 测试下载速度
  static Future<double> testDownloadSpeed({
    required String proxyHost,
    required int proxyPort,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      // 创建代理客户端
      final httpClient = HttpClient();
      httpClient.connectionTimeout = timeout;
      httpClient.findProxy = (uri) {
        return 'PROXY $proxyHost:$proxyPort';
      };

      // 选择测试URL
      final testUrl = testUrls.first;
      final uri = Uri.parse(testUrl);
      
      // 开始计时
      final startTime = DateTime.now();
      
      // 发起请求
      final request = await httpClient.getUrl(uri);
      final response = await request.close();
      
      if (response.statusCode != 200) {
        throw '服务器返回错误: ${response.statusCode}';
      }

      // 读取数据
      int totalBytes = 0;
      await for (final chunk in response) {
        totalBytes += chunk.length;
      }
      
      // 计算时间和速度
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);
      final seconds = duration.inMilliseconds / 1000.0;
      
      // 计算速度 (MB/s)
      final speedMBps = (totalBytes / 1024 / 1024) / seconds;
      
      httpClient.close();
      
      return speedMBps;
    } catch (e) {
      print('速度测试失败: $e');
      return 0.0;
    }
  }

  // 测试延迟
  static Future<int> testLatency({
    required String proxyHost,
    required int proxyPort,
    int attempts = 3,
  }) async {
    try {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 5);
      httpClient.findProxy = (uri) {
        return 'PROXY $proxyHost:$proxyPort';
      };

      final latencies = <int>[];
      
      for (int i = 0; i < attempts; i++) {
        final startTime = DateTime.now();
        
        try {
          final request = await httpClient.getUrl(Uri.parse('https://www.google.com/generate_204'));
          final response = await request.close();
          await response.drain();
          
          final endTime = DateTime.now();
          final latency = endTime.difference(startTime).inMilliseconds;
          latencies.add(latency);
        } catch (e) {
          // 忽略单次失败
        }
        
        if (i < attempts - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      
      httpClient.close();
      
      if (latencies.isEmpty) {
        return 999;
      }
      
      // 返回平均延迟
      return (latencies.reduce((a, b) => a + b) / latencies.length).round();
    } catch (e) {
      print('延迟测试失败: $e');
      return 999;
    }
  }

  // 完整的连接测试
  static Future<Map<String, dynamic>> runSpeedTest({
    required bool isConnected,
    String proxyHost = '127.0.0.1',
    int proxyPort = 7899,
  }) async {
    if (!isConnected) {
      throw '请先连接代理';
    }

    final results = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'proxyHost': proxyHost,
      'proxyPort': proxyPort,
    };

    try {
      // 测试延迟
      results['latency'] = await testLatency(
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );

      // 测试下载速度
      results['downloadSpeed'] = await testDownloadSpeed(
        proxyHost: proxyHost,
        proxyPort: proxyPort,
      );

      results['success'] = true;
    } catch (e) {
      results['success'] = false;
      results['error'] = e.toString();
    }

    return results;
  }
}
