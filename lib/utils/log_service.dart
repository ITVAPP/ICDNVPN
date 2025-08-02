import 'dart:io';
import 'package:path/path.dart' as path;

/// 日志服务 - 保存到安装目录的logs文件夹
class LogService {
  static LogService? _instance;
  static LogService get instance => _instance ??= LogService._();
  
  LogService._();
  
  // 日志开关
  bool enabled = true;
  
  // 日志文件
  File? _logFile;
  IOSink? _logSink;
  String? _logDir;
  
  /// 初始化日志服务
  /// CloudflareTestService 调用的接口
  Future<void> init({
    required String prefix,
    required bool enableFile,
    required bool enableConsole,
  }) async {
    // 这里只使用 enableFile 参数，忽略 enableConsole（根据您的要求不输出到控制台）
    if (!enabled || !enableFile) return;
    
    // 如果已经初始化，先关闭之前的日志
    if (_logSink != null) {
      await close();
    }
    
    try {
      // 获取安装目录下的logs文件夹
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent.path;
      final logDir = Directory(path.join(exeDir, 'logs'));
      _logDir = logDir.path;
      
      // 创建目录
      if (!logDir.existsSync()) {
        logDir.createSync(recursive: true);
      }
      
      // 创建日志文件 - 只使用日期命名
      final date = DateTime.now();
      final dateStr = '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
      final fileName = '${prefix}_$dateStr.log';
      
      _logFile = File(path.join(logDir.path, fileName));
      
      // 追加模式打开文件（文件存在则追加，不存在则创建）
      _logSink = _logFile!.openWrite(mode: FileMode.append);
      
      // 写入分隔符，标记新的日志会话
      await _writeLog('');
      await _writeLog('=' * 50);
      await _writeLog('=== 新日志会话开始 ===');
      await _writeLog('时间: ${date.toIso8601String()}');
      await _writeLog('=' * 50);
      
    } catch (e) {
      enabled = false;
    }
  }
  
  /// 写入日志到文件
  Future<void> _writeLog(String message) async {
    if (!enabled || _logSink == null) return;
    
    try {
      _logSink!.writeln(message);
      await _logSink!.flush();
    } catch (e) {
      // 静默处理
    }
  }
  
  /// CloudflareTestService 使用的日志方法
  Future<void> info(String message, {String? tag}) async {
    await _log('INFO', message, tag);
  }
  
  Future<void> debug(String message, {String? tag}) async {
    await _log('DEBUG', message, tag);
  }
  
  Future<void> warn(String message, {String? tag}) async {
    await _log('WARN', message, tag);
  }
  
  Future<void> error(String message, {String? tag, Object? error, StackTrace? stackTrace}) async {
    await _log('ERROR', message, tag);
    if (error != null) {
      await _log('ERROR', '错误详情: $error', tag);
    }
    if (stackTrace != null) {
      await _log('ERROR', '堆栈跟踪:\n$stackTrace', tag);
    }
  }
  
  /// 统一的日志记录方法
  Future<void> _log(String level, String message, String? tag) async {
    if (!enabled) return;
    
    final timestamp = DateTime.now().toIso8601String();
    final tagStr = tag != null ? '[$tag]' : '';
    final logMessage = '[$timestamp] [$level] $tagStr $message';
    
    await _writeLog(logMessage);
  }
  
  /// 获取日志目录路径
  String? getLogDirectory() => _logDir;
  
  /// 获取当前日志文件路径
  String? getCurrentLogFile() => _logFile?.path;
  
  /// 清空所有日志文件
  Future<void> clearAllLogs() async {
    try {
      // 先关闭当前日志文件
      await close();
      
      if (_logDir != null) {
        final dir = Directory(_logDir!);
        if (dir.existsSync()) {
          // 删除logs文件夹下的所有文件
          final entities = dir.listSync();
          for (final entity in entities) {
            try {
              if (entity is File) {
                entity.deleteSync();
              }
            } catch (e) {
              // 忽略单个文件删除失败
            }
          }
        }
      }
    } catch (e) {
      // 静默处理
    }
  }
  
  /// 关闭日志服务
  Future<void> close() async {
    try {
      await _logSink?.close();
      _logSink = null;
      _logFile = null;
    } catch (e) {
      // 静默处理
    }
  }
  
  /// 保留此方法以兼容 CloudflareTestService
  /// 实际不执行任何操作
  Future<void> cleanOldLogs({int keepDays = 7}) async {
    // 空实现，保持接口兼容性
  }
}
