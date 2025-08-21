package com.example.cfvpn

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * VPN应用文件日志记录器
 * 提供异步批量写入和性能优化的日志功能
 */
object VpnFileLogger {
    
    private const val TAG = "VpnFileLogger"
    
    // 日志功能开关，生产环境建议设为false
    private const val ENABLE_LOG = true
    
    // 批量写入性能参数配置
    private const val FLUSH_INTERVAL_MS = 500L  // 日志刷新间隔毫秒数
    private const val FLUSH_BATCH_SIZE = 10     // 批量写入日志条数阈值
    
    // 日志文件相关对象
    private var logFile: File? = null
    private var writer: FileWriter? = null
    
    // 时间格式化器，单线程使用保证线程安全
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
    
    // 异步日志处理组件
    private val logQueue = LinkedBlockingQueue<LogEntry>(1000)  // 日志队列，容量1000条
    private var writerThread: Thread? = null                    // 后台写入线程
    private val isRunning = AtomicBoolean(false)               // 运行状态标志
    
    /**
     * 日志条目数据结构
     * 包含完整的日志信息和时间戳
     */
    private data class LogEntry(
        val level: String,          // 日志级别
        val tag: String,            // 日志标签
        val message: String,        // 日志内容
        val error: Throwable?,      // 异常对象
        val timestamp: Long = System.currentTimeMillis()  // 记录时间戳
    )
    
    /**
     * 初始化日志系统
     * 创建日志文件和异步写入线程
     * @param context Android上下文对象
     */
    fun init(context: Context) {
        if (!ENABLE_LOG) {
            Log.d(TAG, "日志系统已禁用")
            return
        }
        
        try {
            // 确保关闭现有日志系统
            if (isRunning.get()) close()
            
            // 创建应用日志目录
            val logDir = File(context.filesDir, "logs")
            if (!logDir.exists()) logDir.mkdirs()
            
            // 生成按日期命名的日志文件
            val fileName = "KT_${SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())}.log"
            logFile = File(logDir, fileName)
            
            // 初始化文件写入器并写入会话开始标记
            writer = FileWriter(logFile, true)
            writer?.apply {
                write("\n========== KT端日志开始 ${Date()} ==========\n")
                flush()
            }
            
            // 启动异步日志写入处理
            startWriterThread()
            
            Log.d(TAG, "日志系统初始化完成: ${logFile?.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "日志系统初始化失败", e)
            isRunning.set(false)
        }
    }
    
    /**
     * 启动异步写入线程
     * 处理日志队列中的条目并批量写入文件
     */
    private fun startWriterThread() {
        if (!ENABLE_LOG || isRunning.get()) return
        
        isRunning.set(true)
        
        writerThread = thread(name = "VpnLogger-Writer", isDaemon = true) {
            val pendingLogs = mutableListOf<LogEntry>()  // 待写入日志缓存
            var lastFlushTime = System.currentTimeMillis()
            
            try {
                while (isRunning.get()) {
                    try {
                        // 从队列获取日志条目，超时等待
                        val log = logQueue.poll(FLUSH_INTERVAL_MS, TimeUnit.MILLISECONDS)
                        
                        if (log != null) pendingLogs.add(log)
                        
                        val currentTime = System.currentTimeMillis()
                        // 检查批量写入触发条件：数量达标或时间到期
                        val shouldFlush = pendingLogs.size >= FLUSH_BATCH_SIZE ||
                                (pendingLogs.isNotEmpty() && currentTime - lastFlushTime >= FLUSH_INTERVAL_MS)
                        
                        // 执行批量日志写入
                        if (shouldFlush && pendingLogs.isNotEmpty()) {
                            flushPendingLogs(pendingLogs)
                            pendingLogs.clear()
                            lastFlushTime = currentTime
                        }
                    } catch (e: InterruptedException) {
                        break  // 线程中断，退出循环
                    } catch (e: Exception) {
                        Log.e(TAG, "写入线程处理异常", e)
                    }
                }
                
                // 处理剩余未写入的日志
                if (pendingLogs.isNotEmpty()) {
                    flushPendingLogs(pendingLogs)
                }
            } catch (e: Exception) {
                Log.e(TAG, "写入线程发生崩溃", e)
            }
        }
    }
    
    /**
     * 批量写入日志到文件
     * 同时输出到Android Logcat
     * @param logs 待写入的日志条目列表
     */
    private fun flushPendingLogs(logs: List<LogEntry>) {
        try {
            writer?.apply {
                // 预估字符串构建器容量，提升性能
                val estimatedSize = logs.size * 80
                val sb = StringBuilder(estimatedSize)
                
                // 格式化每条日志为标准格式
                for (log in logs) {
                    val timestamp = dateFormat.format(Date(log.timestamp))
                    sb.append("[$timestamp] [${log.level}] [${log.tag}] ${log.message}\n")
                    
                    // 附加异常堆栈信息
                    if (log.error != null) {
                        sb.append("  Exception: ${log.error.message}\n")
                        // 限制堆栈深度为5层，避免日志过长
                        log.error.stackTrace.take(5).forEach { 
                            sb.append("    at $it\n")
                        }
                    }
                }
                
                // 批量写入文件并强制刷新
                write(sb.toString())
                flush()
                
                // 同步输出到Android系统日志
                for (log in logs) {
                    when (log.level) {
                        "D" -> Log.d(log.tag, log.message, log.error)
                        "I" -> Log.i(log.tag, log.message, log.error)
                        "W" -> Log.w(log.tag, log.message, log.error)
                        "E" -> Log.e(log.tag, log.message, log.error)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "批量写入日志失败", e)
        }
    }
    
    /**
     * 异步写入日志条目
     * 日志系统未运行时降级为Logcat输出
     * @param level 日志级别
     * @param tag 日志标签
     * @param message 日志内容
     * @param error 可选的异常对象
     */
    private fun writeLog(level: String, tag: String, message: String, error: Throwable? = null) {
        if (!isRunning.get()) {
            // 日志系统未启动时直接输出到Logcat
            when (level) {
                "D" -> Log.d(tag, message, error)
                "I" -> Log.i(tag, message, error)
                "W" -> Log.w(tag, message, error)
                "E" -> Log.e(tag, message, error)
            }
            return
        }
        
        // 创建日志条目并尝试加入队列
        val entry = LogEntry(level, tag, message, error)
        if (!logQueue.offer(entry)) {
            Log.w(TAG, "日志队列已满，丢弃消息: $message")
            // 重要日志(警告和错误)强制输出到Logcat
            if (level == "E" || level == "W") {
                when (level) {
                    "E" -> Log.e(tag, message, error)
                    "W" -> Log.w(tag, message, error)
                }
            }
        }
    }
    
    /**
     * 记录调试级别日志
     * @param tag 日志标签
     * @param message 日志内容
     */
    fun d(tag: String, message: String) {
        if (ENABLE_LOG) writeLog("D", tag, message)
    }
    
    /**
     * 记录信息级别日志
     * @param tag 日志标签
     * @param message 日志内容
     */
    fun i(tag: String, message: String) {
        if (ENABLE_LOG) writeLog("I", tag, message)
    }
    
    /**
     * 记录警告级别日志
     * @param tag 日志标签
     * @param message 日志内容
     * @param error 可选的异常对象
     */
    fun w(tag: String, message: String, error: Throwable? = null) {
        if (ENABLE_LOG) writeLog("W", tag, message, error)
    }
    
    /**
     * 记录错误级别日志
     * @param tag 日志标签
     * @param message 日志内容
     * @param error 可选的异常对象
     */
    fun e(tag: String, message: String, error: Throwable? = null) {
        if (ENABLE_LOG) writeLog("E", tag, message, error)
    }
    
    /**
     * 强制刷新所有待写入日志
     * 等待队列清空并刷新文件缓冲区
     */
    fun flushAll() {
        if (!ENABLE_LOG || !isRunning.get()) return
        
        try {
            // 等待日志队列清空，最大等待1秒
            val startTime = System.currentTimeMillis()
            while (logQueue.isNotEmpty() && System.currentTimeMillis() - startTime < 1000) {
                Thread.sleep(10)
            }
            
            // 强制刷新文件写入器缓冲区
            writer?.flush()
        } catch (e: Exception) {
            Log.e(TAG, "强制刷新日志失败", e)
        }
    }
    
    /**
     * 关闭日志系统
     * 停止写入线程并处理剩余日志
     */
    fun close() {
        try {
            // 设置停止标志
            isRunning.set(false)
            
            // 中断后台写入线程
            writerThread?.interrupt()
            
            // 等待线程结束，最大等待2秒
            writerThread?.join(2000)
            
            // 处理队列中的剩余日志
            val remainingLogs = mutableListOf<LogEntry>()
            logQueue.drainTo(remainingLogs)
            if (remainingLogs.isNotEmpty()) flushPendingLogs(remainingLogs)
            
            // 关闭文件写入器并清理资源
            writer?.close()
            writer = null
            logFile = null
            writerThread = null
            
            Log.d(TAG, "日志系统已关闭")
        } catch (e: Exception) {
            Log.e(TAG, "关闭日志系统失败", e)
        }
    }
}