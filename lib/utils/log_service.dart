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
  
  // 初始化标志
  bool _initialized = false;
  
  /// 初始化日志服务
  /// CloudflareTestService 调用的接口
  Future<void> init({
    required String prefix,
    required bool enableFile,
    required bool enableConsole,
  }) async {
    // 设置初始化标志
    _initialized = true;
    
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
      _writeLog('');
      _writeLog('=' * 50);
      _writeLog('=== 新日志会话开始 ===');
      _writeLog('时间: ${date.toIso8601String()}');
      _writeLog('=' * 50);
      
      // 初始化时 flush 一次
      await flush();
      
    } catch (e) {
      enabled = false;
    }
  }
  
  /// 写入日志到文件（不再自动 flush）
  void _writeLog(String message) {
    if (!enabled || _logSink == null) return;
    
    try {
      _logSink!.writeln(message);
    } catch (e) {
      // 静默处理
    }
  }
  
  /// 手动刷新缓冲区
  Future<void> flush() async {
    if (!enabled || _logSink == null) return;
    
    try {
      await _logSink!.flush();
    } catch (e) {
      // 静默处理
    }
  }
  
  /// CloudflareTestService 使用的日志方法
  Future<void> info(String message, {String? tag}) async {
    _log('INFO', message, tag);
  }
  
  Future<void> debug(String message, {String? tag}) async {
    _log('DEBUG', message, tag);
  }
  
  Future<void> warn(String message, {String? tag}) async {
    _log('WARN', message, tag);
  }
  
  Future<void> error(String message, {String? tag, Object? error, StackTrace? stackTrace}) async {
    _log('ERROR', message, tag);
    if (error != null) {
      _log('ERROR', '错误详情: $error', tag);
    }
    if (stackTrace != null) {
      _log('ERROR', '堆栈跟踪:\n$stackTrace', tag);
    }
    
    // 错误日志立即 flush
    await flush();
  }
  
  /// 统一的日志记录方法
  void _log(String level, String message, String? tag) {
    if (!enabled) return;
    
    // 自动初始化：如果未初始化且日志流为空，则自动初始化
    if (!_initialized && _logSink == null) {
      init(
        prefix: 'app',
        enableFile: true,
        enableConsole: false,
      ).then((_) {
        // 初始化完成后写入当前日志
        _writeLogMessage(level, message, tag);
      });
      return;
    }
    
    _writeLogMessage(level, message, tag);
  }
  
  /// 写入格式化的日志消息
  void _writeLogMessage(String level, String message, String? tag) {
    final timestamp = DateTime.now().toIso8601String();
    final tagStr = tag != null ? '[$tag]' : '';
    final logMessage = '[$timestamp] [$level] $tagStr $message';
    
    _writeLog(logMessage);
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
      await flush(); // 关闭前确保所有日志都写入
      await _logSink?.close();
      _logSink = null;
      _logFile = null;
    } catch (e) {
      // 静默处理
    }
  }
}