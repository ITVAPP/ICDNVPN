import 'dart:io';
import 'dart:async';
import 'package:path/path.dart' as path;

/// 日志服务 - 基于tag自动创建不同的日志文件
class LogService {
  static LogService? _instance;
  static LogService get instance => _instance ??= LogService._();
  
  LogService._();
  
  // 日志开关
  bool enabled = true;
  
  // 为每个tag维护独立的日志文件和流
  final Map<String, _LogContext> _logContexts = {};
  String? _logDir;
  
  // 默认tag（当没有指定tag时使用）
  static const String _defaultTag = 'app';
  
  // 并发控制 - 防止同时创建相同tag的多个流
  final Map<String, Completer<_LogContext?>> _pendingCreations = {};
  
  // 操作锁 - 防止清空和写入的并发冲突
  final Map<String, Completer<void>> _operationLocks = {};
  
  // 最大同时打开的日志文件数（防止文件句柄耗尽）
  static const int _maxOpenFiles = 10;
  
  // 定期检查计时器
  Timer? _dateCheckTimer;
  Timer? _autoFlushTimer;
  
  /// 日志上下文（包含文件、流和日期信息）
  class _LogContext {
    final File file;
    final IOSink sink;
    final String dateStr;
    final String tag;
    DateTime lastWriteTime;
    bool isClosed = false;
    
    _LogContext({
      required this.file,
      required this.sink,
      required this.dateStr,
      required this.tag,
    }) : lastWriteTime = DateTime.now();
    
    bool get isExpired {
      final now = DateTime.now();
      final currentDateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      return currentDateStr != dateStr;
    }
    
    void updateWriteTime() {
      lastWriteTime = DateTime.now();
    }
    
    Future<void> close() async {
      if (!isClosed) {
        isClosed = true;
        try {
          await sink.flush();
          await sink.close();
        } catch (e) {
          // 静默处理
        }
      }
    }
  }
  
  LogService._() {
    // 启动定期检查日期变更的计时器（每分钟检查一次）
    _dateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkAndRotateLogs();
    });
  }
  
  /// 获取操作锁，防止并发冲突
  Future<void> _acquireLock(String tag) async {
    final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
    
    // 如果有正在进行的操作，等待它完成
    final existingLock = _operationLocks[safeTag];
    if (existingLock != null) {
      await existingLock.future;
    }
    
    // 创建新的锁
    _operationLocks[safeTag] = Completer<void>();
  }
  
  /// 释放操作锁
  void _releaseLock(String tag) {
    final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
    final lock = _operationLocks[safeTag];
    if (lock != null && !lock.isCompleted) {
      lock.complete();
    }
    _operationLocks.remove(safeTag);
  }
  
  /// 检查并轮转过期的日志文件
  void _checkAndRotateLogs() {
    if (!enabled) return;
    
    final expiredTags = <String>[];
    _logContexts.forEach((tag, context) {
      if (context.isExpired) {
        expiredTags.add(tag);
      }
    });
    
    // 关闭并移除过期的日志上下文
    for (final tag in expiredTags) {
      _closeContext(tag);
    }
    
    // 如果打开的文件数过多，关闭最久未使用的
    if (_logContexts.length > _maxOpenFiles) {
      final sortedEntries = _logContexts.entries.toList()
        ..sort((a, b) => a.value.lastWriteTime.compareTo(b.value.lastWriteTime));
      
      final toClose = sortedEntries.take(_logContexts.length - _maxOpenFiles);
      for (final entry in toClose) {
        _closeContext(entry.key);
      }
    }
  }
  
  /// 关闭指定tag的日志上下文
  Future<void> _closeContext(String tag) async {
    final context = _logContexts.remove(tag);
    if (context != null) {
      await context.close();
    }
  }
  
  /// 获取或创建指定tag的日志上下文
  Future<_LogContext?> _getOrCreateLogContext(String tag) async {
    if (!enabled) return null;
    
    // 规范化tag：移除特殊字符，用于文件名
    final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
    
    // 检查是否正在被清空（有锁）
    if (_operationLocks.containsKey(safeTag)) {
      // 等待清空操作完成
      await _operationLocks[safeTag]?.future;
    }
    
    // 检查是否已存在且未过期
    final existing = _logContexts[safeTag];
    if (existing != null && !existing.isExpired && !existing.isClosed) {
      existing.updateWriteTime();
      return existing;
    }
    
    // 如果过期了或已关闭，先移除旧的
    if (existing != null && (existing.isExpired || existing.isClosed)) {
      await _closeContext(safeTag);
    }
    
    // 检查是否正在创建中（防止并发创建）
    final pending = _pendingCreations[safeTag];
    if (pending != null && !pending.isCompleted) {
      return await pending.future;
    }
    
    // 创建新的Completer来控制并发
    final completer = Completer<_LogContext?>();
    _pendingCreations[safeTag] = completer;
    
    try {
      // 确保日志目录存在
      if (_logDir == null) {
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;
        final logDir = Directory(path.join(exeDir, 'logs'));
        _logDir = logDir.path;
        
        if (!logDir.existsSync()) {
          logDir.createSync(recursive: true);
        }
      }
      
      // 创建日志文件 - 基于tag和日期命名
      final date = DateTime.now();
      final dateStr = '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
      final fileName = '${safeTag}_$dateStr.log';
      
      final logFile = File(path.join(_logDir!, fileName));
      
      // 检查文件是否是新创建的
      final isNewFile = !logFile.existsSync() || logFile.lengthSync() == 0;
      
      // 追加模式打开文件
      final logSink = logFile.openWrite(mode: FileMode.append);
      
      if (isNewFile) {
        // 写入分隔符，标记新的日志会话
        logSink.writeln('');
        logSink.writeln('=' * 50);
        logSink.writeln('=== 日志会话开始 ===');
        logSink.writeln('时间: ${date.toIso8601String()}');
        logSink.writeln('日志标签: $tag');
        logSink.writeln('=' * 50);
        logSink.writeln('');
        
        // 初始化时 flush 一次
        await logSink.flush();
      }
      
      // 创建上下文
      final context = _LogContext(
        file: logFile,
        sink: logSink,
        dateStr: dateStr,
        tag: safeTag,
      );
      
      _logContexts[safeTag] = context;
      completer.complete(context);
      
      return context;
    } catch (e) {
      // 静默处理错误
      completer.complete(null);
      return null;
    } finally {
      _pendingCreations.remove(safeTag);
    }
  }
  
  /// 初始化日志服务（保留接口兼容性）
  Future<void> init({
    required String prefix,
    required bool enableFile,
    required bool enableConsole,
  }) async {
    // 这个方法保留是为了兼容性
    enabled = enableFile;
  }
  
  /// 写入日志到文件
  Future<void> _writeLog(String level, String message, String? tag) async {
    if (!enabled) return;
    
    // 使用提供的tag或默认tag
    final effectiveTag = tag ?? _defaultTag;
    
    try {
      // 获取或创建对应的日志上下文
      final context = await _getOrCreateLogContext(effectiveTag);
      if (context == null || context.isClosed) return;
      
      // 格式化日志消息（不包含tag，因为文件名已经表明了来源）
      final timestamp = DateTime.now().toIso8601String();
      final logMessage = '[$timestamp] [$level] $message';
      
      // 写入日志
      context.sink.writeln(logMessage);
      context.updateWriteTime();
      
      // 对于ERROR级别，立即flush
      if (level == 'ERROR') {
        await context.sink.flush();
      }
    } catch (e) {
      // 静默处理错误
    }
  }
  
  /// 手动刷新指定tag的缓冲区
  Future<void> flush({String? tag}) async {
    if (!enabled) return;
    
    try {
      if (tag != null) {
        // 刷新指定tag的日志
        final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
        final context = _logContexts[safeTag];
        if (context != null && !context.isClosed) {
          await context.sink.flush();
        }
      } else {
        // 刷新所有日志
        final futures = <Future>[];
        for (final context in _logContexts.values) {
          if (!context.isClosed) {
            futures.add(context.sink.flush());
          }
        }
        await Future.wait(futures);
      }
    } catch (e) {
      // 静默处理
    }
  }
  
  /// CloudflareTestService 使用的日志方法
  Future<void> info(String message, {String? tag}) async {
    await _writeLog('INFO', message, tag);
  }
  
  Future<void> debug(String message, {String? tag}) async {
    await _writeLog('DEBUG', message, tag);
  }
  
  Future<void> warn(String message, {String? tag}) async {
    await _writeLog('WARN', message, tag);
  }
  
  Future<void> error(String message, {String? tag, Object? error, StackTrace? stackTrace}) async {
    await _writeLog('ERROR', message, tag);
    if (error != null) {
      await _writeLog('ERROR', '错误详情: $error', tag);
    }
    if (stackTrace != null) {
      await _writeLog('ERROR', '堆栈跟踪:\n$stackTrace', tag);
    }
  }
  
  /// 获取日志目录路径
  String? getLogDirectory() => _logDir;
  
  /// 获取指定tag的日志文件路径（当前日期的）
  String? getLogFile(String tag) {
    final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
    return _logContexts[safeTag]?.file.path;
  }
  
  /// 获取指定tag的所有日志文件（包括历史）
  List<String> getAllLogFilesForTag(String tag) {
    final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
    final files = <String>[];
    
    if (_logDir == null) return files;
    
    try {
      final dir = Directory(_logDir!);
      if (dir.existsSync()) {
        // 查找所有匹配的日志文件（tag_*.log）
        final pattern = RegExp('^${RegExp.escape(safeTag)}_\\d{8}\\.log\$');
        final entities = dir.listSync();
        
        for (final entity in entities) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            if (pattern.hasMatch(fileName)) {
              files.add(entity.path);
            }
          }
        }
      }
    } catch (e) {
      // 静默处理
    }
    
    return files;
  }
  
  /// 获取所有日志文件路径
  Map<String, List<String>> getAllLogFiles() {
    final result = <String, List<String>>{};
    
    if (_logDir == null) return result;
    
    try {
      final dir = Directory(_logDir!);
      if (dir.existsSync()) {
        // 匹配所有日志文件（*_YYYYMMDD.log）
        final pattern = RegExp(r'^(.+?)_(\d{8})\.log$');
        final entities = dir.listSync();
        
        for (final entity in entities) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            final match = pattern.firstMatch(fileName);
            if (match != null) {
              final tag = match.group(1)!;
              result.putIfAbsent(tag, () => []).add(entity.path);
            }
          }
        }
      }
    } catch (e) {
      // 静默处理
    }
    
    return result;
  }
  
  /// 清空指定tag的日志文件（包括所有历史文件）
  Future<void> clearLog(String tag) async {
    final safeTag = tag.replaceAll(RegExp(r'[^\w\-]'), '_');
    
    try {
      // 获取锁，防止并发操作
      await _acquireLock(safeTag);
      
      // 1. 先关闭并移除当前的上下文
      final context = _logContexts.remove(safeTag);
      if (context != null) {
        await context.close();
      }
      
      // 2. 确保没有正在创建的操作
      final pending = _pendingCreations[safeTag];
      if (pending != null && !pending.isCompleted) {
        // 等待创建完成，然后关闭
        final newContext = await pending.future;
        if (newContext != null) {
          await newContext.close();
          _logContexts.remove(safeTag);
        }
      }
      
      // 3. 删除所有相关的日志文件（包括历史文件）
      if (_logDir != null) {
        final dir = Directory(_logDir!);
        if (dir.existsSync()) {
          // 构建文件名匹配模式：tag_YYYYMMDD.log
          final pattern = RegExp('^${RegExp.escape(safeTag)}_\\d{8}\\.log\$');
          final entities = dir.listSync();
          
          for (final entity in entities) {
            if (entity is File) {
              final fileName = path.basename(entity.path);
              if (pattern.hasMatch(fileName)) {
                try {
                  // 找到匹配的文件，删除它
                  await entity.delete();
                } catch (e) {
                  // 如果删除失败（可能被占用），尝试清空内容
                  try {
                    await entity.writeAsString('');
                  } catch (e2) {
                    // 完全失败，静默处理
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      // 静默处理错误
    } finally {
      // 释放锁
      _releaseLock(safeTag);
    }
  }
  
  /// 清空所有日志文件
  Future<void> clearAllLogs() async {
    try {
      // 1. 获取所有tag
      final tags = _logContexts.keys.toList();
      final pendingTags = _pendingCreations.keys.toList();
      final allTags = {...tags, ...pendingTags}.toList();
      
      // 2. 依次清空每个tag（这样可以利用锁机制）
      for (final tag in allTags) {
        await clearLog(tag);
      }
      
      // 3. 清理日志目录下的任何遗留文件
      if (_logDir != null) {
        final dir = Directory(_logDir!);
        if (dir.existsSync()) {
          final entities = dir.listSync();
          for (final entity in entities) {
            try {
              if (entity is File && entity.path.endsWith('.log')) {
                await entity.delete();
              }
            } catch (e) {
              // 如果删除失败，尝试清空内容
              try {
                if (entity is File) {
                  await entity.writeAsString('');
                }
              } catch (e2) {
                // 完全失败，静默处理
              }
            }
          }
        }
      }
      
      // 4. 清空所有内部状态
      _logContexts.clear();
      _pendingCreations.clear();
      _operationLocks.clear();
    } catch (e) {
      // 静默处理
    }
  }
  
  /// 关闭日志服务
  Future<void> close() async {
    try {
      // 取消所有定时器
      _dateCheckTimer?.cancel();
      _dateCheckTimer = null;
      _autoFlushTimer?.cancel();
      _autoFlushTimer = null;
      
      // 等待所有锁释放
      final locks = _operationLocks.values.toList();
      for (final lock in locks) {
        if (!lock.isCompleted) {
          await lock.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
        }
      }
      
      // 刷新并关闭所有日志上下文
      final contexts = _logContexts.values.toList();
      final futures = <Future>[];
      for (final context in contexts) {
        futures.add(context.close());
      }
      await Future.wait(futures);
      
      // 清空所有状态
      _logContexts.clear();
      _pendingCreations.clear();
      _operationLocks.clear();
    } catch (e) {
      // 静默处理
    }
  }
  
  /// 定期刷新所有日志（可选功能）
  void startAutoFlush({Duration interval = const Duration(seconds: 30)}) {
    _autoFlushTimer?.cancel();
    _autoFlushTimer = Timer.periodic(interval, (_) async {
      await flush();
    });
  }
  
  void stopAutoFlush() {
    _autoFlushTimer?.cancel();
    _autoFlushTimer = null;
  }
}