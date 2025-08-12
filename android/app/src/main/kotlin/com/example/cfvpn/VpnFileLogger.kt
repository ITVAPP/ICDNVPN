package com.example.cfvpn

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * VPN 文件日志记录器 - 性能优化版
 * 
 * 优化特性：
 * 1. 异步写入队列，避免I/O阻塞
 * 2. 批量flush策略，减少磁盘写入次数
 * 3. ThreadLocal解决SimpleDateFormat线程安全问题
 * 4. 优化日志开关检查逻辑
 * 
 * 设计原则：简单可靠，异步写入，内部控制开关
 */
object VpnFileLogger {
    
    private const val TAG = "VpnFileLogger"
    
    // ========== 日志开关 - 只在这里修改！ ==========
    // 开发环境：true
    // 生产环境：false
    private const val ENABLE_LOG = true  // <-- 生产环境改为 false
    // ===============================================
    
    // 批量写入配置
    private const val FLUSH_INTERVAL_MS = 100L  // 100ms批量刷新一次
    private const val FLUSH_BATCH_SIZE = 10     // 累积10条日志刷新一次
    
    private var logFile: File? = null
    private var writer: FileWriter? = null
    
    // 使用ThreadLocal解决SimpleDateFormat线程安全问题
    private val dateFormatThreadLocal = ThreadLocal.withInitial {
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
    }
    
    // 异步写入队列
    private val logQueue = LinkedBlockingQueue<LogEntry>(1000)  // 最大缓存1000条日志
    private var writerThread: Thread? = null
    private val isRunning = AtomicBoolean(false)
    
    // 日志条目数据类
    private data class LogEntry(
        val level: String,
        val tag: String,
        val message: String,
        val error: Throwable?,
        val timestamp: Long = System.currentTimeMillis()
    )
    
    /**
     * 初始化日志系统
     */
    fun init(context: Context) {
        // 提前检查日志开关，避免不必要的初始化
        if (!ENABLE_LOG) {
            Log.d(TAG, "日志系统已禁用")
            return
        }
        
        try {
            // 如果已经初始化，先关闭
            if (isRunning.get()) {
                close()
            }
            
            // 创建日志目录
            val logDir = File(context.filesDir, "logs")
            if (!logDir.exists()) {
                logDir.mkdirs()
            }
            
            // 创建日志文件
            val fileName = "vpn_${SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())}.log"
            logFile = File(logDir, fileName)
            
            // 打开文件写入器（追加模式）
            writer = FileWriter(logFile, true)
            
            // 写入会话开始标记
            writer?.apply {
                write("\n========== VPN日志开始 ${Date()} ==========\n")
                flush() // 初始化时立即刷新一次
            }
            
            // 启动异步写入线程
            startWriterThread()
            
            Log.d(TAG, "日志系统初始化成功: ${logFile?.absolutePath}")
            
        } catch (e: Exception) {
            Log.e(TAG, "初始化失败", e)
            // 初始化失败时禁用日志，避免后续错误
            isRunning.set(false)
        }
    }
    
    /**
     * 启动异步写入线程
     */
    private fun startWriterThread() {
        if (!ENABLE_LOG || isRunning.get()) {
            return
        }
        
        isRunning.set(true)
        
        writerThread = thread(name = "VpnLogger-Writer", isDaemon = true) {
            val pendingLogs = mutableListOf<LogEntry>()
            var lastFlushTime = System.currentTimeMillis()
            
            try {
                while (isRunning.get()) {
                    try {
                        // 从队列取日志（带超时）
                        val log = logQueue.poll(FLUSH_INTERVAL_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
                        
                        if (log != null) {
                            pendingLogs.add(log)
                        }
                        
                        val currentTime = System.currentTimeMillis()
                        val shouldFlush = pendingLogs.size >= FLUSH_BATCH_SIZE ||
                                (pendingLogs.isNotEmpty() && currentTime - lastFlushTime >= FLUSH_INTERVAL_MS)
                        
                        if (shouldFlush && pendingLogs.isNotEmpty()) {
                            flushPendingLogs(pendingLogs)
                            pendingLogs.clear()
                            lastFlushTime = currentTime
                        }
                        
                    } catch (e: InterruptedException) {
                        // 线程被中断，退出循环
                        break
                    } catch (e: Exception) {
                        Log.e(TAG, "写入线程异常", e)
                    }
                }
                
                // 退出前刷新剩余日志
                if (pendingLogs.isNotEmpty()) {
                    flushPendingLogs(pendingLogs)
                }
                
            } catch (e: Exception) {
                Log.e(TAG, "写入线程崩溃", e)
            }
        }
    }
    
    /**
     * 批量刷新待写入的日志
     */
    private fun flushPendingLogs(logs: List<LogEntry>) {
        try {
            writer?.apply {
                val dateFormat = dateFormatThreadLocal.get()
                val sb = StringBuilder(logs.size * 100)  // 预分配缓冲区
                
                for (log in logs) {
                    val timestamp = dateFormat.format(Date(log.timestamp))
                    sb.append("[").append(timestamp).append("] ")
                      .append("[").append(log.level).append("] ")
                      .append("[").append(log.tag).append("] ")
                      .append(log.message).append("\n")
                    
                    // 如果有异常，写入堆栈
                    if (log.error != null) {
                        sb.append("  Exception: ").append(log.error.message).append("\n")
                        log.error.stackTrace.take(5).forEach { 
                            sb.append("    at ").append(it).append("\n")
                        }
                    }
                }
                
                // 批量写入
                write(sb.toString())
                flush()  // 批量刷新
                
                // 同时输出到Logcat（可选，调试用）
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
            Log.e(TAG, "批量刷新失败", e)
        }
    }
    
    /**
     * 写入日志（异步方式）
     */
    private fun writeLog(level: String, tag: String, message: String, error: Throwable? = null) {
        // 如果日志系统未运行，只输出到Logcat
        if (!isRunning.get()) {
            when (level) {
                "D" -> Log.d(tag, message, error)
                "I" -> Log.i(tag, message, error)
                "W" -> Log.w(tag, message, error)
                "E" -> Log.e(tag, message, error)
            }
            return
        }
        
        // 添加到队列（非阻塞）
        val entry = LogEntry(level, tag, message, error)
        if (!logQueue.offer(entry)) {
            // 队列满了，直接输出到Logcat
            Log.w(TAG, "日志队列已满，丢弃日志: $message")
            when (level) {
                "E" -> Log.e(tag, message, error)  // 错误日志始终输出
                "W" -> Log.w(tag, message, error)  // 警告日志始终输出
            }
        }
    }
    
    // 便捷方法（优化：在方法入口检查日志开关）
    fun d(tag: String, message: String) {
        if (ENABLE_LOG) writeLog("D", tag, message)
    }
    
    fun i(tag: String, message: String) {
        if (ENABLE_LOG) writeLog("I", tag, message)
    }
    
    fun w(tag: String, message: String, error: Throwable? = null) {
        if (ENABLE_LOG) writeLog("W", tag, message, error)
    }
    
    fun e(tag: String, message: String, error: Throwable? = null) {
        if (ENABLE_LOG) writeLog("E", tag, message, error)
    }
    
    /**
     * 立即刷新日志缓冲区
     * 用于重要日志需要立即写入的场景
     */
    fun flushAll() {
        if (!ENABLE_LOG || !isRunning.get()) return
        
        try {
            // 等待队列清空（最多等待1秒）
            val startTime = System.currentTimeMillis()
            while (logQueue.isNotEmpty() && System.currentTimeMillis() - startTime < 1000) {
                Thread.sleep(10)
            }
            
            // 强制刷新文件
            writer?.flush()
        } catch (e: Exception) {
            Log.e(TAG, "刷新失败", e)
        }
    }
    
    /**
     * 关闭日志系统
     */
    fun close() {
        try {
            // 停止接收新日志
            isRunning.set(false)
            
            // 中断写入线程
            writerThread?.interrupt()
            
            // 等待线程结束（最多等待2秒）
            try {
                writerThread?.join(2000)
            } catch (e: InterruptedException) {
                // 忽略
            }
            
            // 处理剩余的日志
            val remainingLogs = mutableListOf<LogEntry>()
            logQueue.drainTo(remainingLogs)
            if (remainingLogs.isNotEmpty()) {
                flushPendingLogs(remainingLogs)
            }
            
            // 关闭文件写入器
            writer?.close()
            writer = null
            logFile = null
            writerThread = null
            
            Log.d(TAG, "日志系统已关闭")
            
        } catch (e: Exception) {
            Log.e(TAG, "关闭失败", e)
        }
    }
}