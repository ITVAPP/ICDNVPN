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

// 记录KT端日志
object VpnFileLogger {
    
    private const val TAG = "VpnFileLogger"
    
    // 日志开关，控制日志输出
    private const val ENABLE_LOG = true  // 生产环境设为false
    
    // 批量写入配置
    private const val FLUSH_INTERVAL_MS = 100L  // 每100ms刷新一次
    private const val FLUSH_BATCH_SIZE = 10     // 累积10条日志刷新
    
    private var logFile: File? = null
    private var writer: FileWriter? = null
    
    // 线程安全的日期格式化
    private val dateFormatThreadLocal = ThreadLocal.withInitial {
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
    }
    
    // 异步日志队列，容量1000
    private val logQueue = LinkedBlockingQueue<LogEntry>(1000)
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
    
    // 初始化日志系统，创建日志文件
    fun init(context: Context) {
        if (!ENABLE_LOG) {
            Log.d(TAG, "日志系统禁用")
            return
        }
        
        try {
            // 关闭已有日志系统
            if (isRunning.get()) close()
            
            // 创建日志目录
            val logDir = File(context.filesDir, "logs")
            if (!logDir.exists()) logDir.mkdirs()
            
            // 创建日志文件
            val fileName = "KT_${SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())}.log"
            logFile = File(logDir, fileName)
            
            // 初始化文件写入器
            writer = FileWriter(logFile, true)
            writer?.apply {
                write("\n========== KT端日志开始 ${Date()} ==========\n")
                flush()
            }
            
            // 启动异步写入线程
            startWriterThread()
            
            Log.d(TAG, "日志系统初始化: ${logFile?.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "日志初始化失败", e)
            isRunning.set(false)
        }
    }
    
    // 启动异步写入线程
    private fun startWriterThread() {
        if (!ENABLE_LOG || isRunning.get()) return
        
        isRunning.set(true)
        
        writerThread = thread(name = "VpnLogger-Writer", isDaemon = true) {
            val pendingLogs = mutableListOf<LogEntry>()
            var lastFlushTime = System.currentTimeMillis()
            
            try {
                while (isRunning.get()) {
                    try {
                        // 从队列获取日志
                        val log = logQueue.poll(FLUSH_INTERVAL_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
                        
                        if (log != null) pendingLogs.add(log)
                        
                        val currentTime = System.currentTimeMillis()
                        val shouldFlush = pendingLogs.size >= FLUSH_BATCH_SIZE ||
                                (pendingLogs.isNotEmpty() && currentTime - lastFlushTime >= FLUSH_INTERVAL_MS)
                        
                        // 批量刷新日志
                        if (shouldFlush && pendingLogs.isNotEmpty()) {
                            flushPendingLogs(pendingLogs)
                            pendingLogs.clear()
                            lastFlushTime = currentTime
                        }
                    } catch (e: InterruptedException) {
                        break
                    } catch (e: Exception) {
                        Log.e(TAG, "写入线程异常", e)
                    }
                }
                
                // 刷新剩余日志
                if (pendingLogs.isNotEmpty()) flushPendingLogs(pendingLogs)
            } catch (e: Exception) {
                Log.e(TAG, "写入线程崩溃", e)
            }
        }
    }
    
    // 批量写入日志到文件
    private fun flushPendingLogs(logs: List<LogEntry>) {
        try {
            writer?.apply {
                val dateFormat = dateFormatThreadLocal.get()
                val sb = StringBuilder(logs.size * 100)
                
                for (log in logs) {
                    val timestamp = dateFormat.format(Date(log.timestamp))
                    sb.append("[$timestamp] [${log.level}] [${log.tag}] ${log.message}\n")
                    
                    // 写入异常堆栈
                    if (log.error != null) {
                        sb.append("  Exception: ${log.error.message}\n")
                        log.error.stackTrace.take(5).forEach { 
                            sb.append("    at $it\n")
                        }
                    }
                }
                
                // 批量写入并刷新
                write(sb.toString())
                flush()
                
                // 输出到Logcat
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
            Log.e(TAG, "批量写入失败", e)
        }
    }
    
    // 异步写入日志
    private fun writeLog(level: String, tag: String, message: String, error: Throwable? = null) {
        if (!isRunning.get()) {
            // 未运行时仅输出到Logcat
            when (level) {
                "D" -> Log.d(tag, message, error)
                "I" -> Log.i(tag, message, error)
                "W" -> Log.w(tag, message, error)
                "E" -> Log.e(tag, message, error)
            }
            return
        }
        
        // 添加日志到队列
        val entry = LogEntry(level, tag, message, error)
        if (!logQueue.offer(entry)) {
            Log.w(TAG, "日志队列已满: $message")
            if (level == "E" || level == "W") {
                when (level) {
                    "E" -> Log.e(tag, message, error)
                    "W" -> Log.w(tag, message, error)
                }
            }
        }
    }
    
    // 记录调试日志
    fun d(tag: String, message: String) {
        if (ENABLE_LOG) writeLog("D", tag, message)
    }
    
    // 记录信息日志
    fun i(tag: String, message: String) {
        if (ENABLE_LOG) writeLog("I", tag, message)
    }
    
    // 记录警告日志
    fun w(tag: String, message: String, error: Throwable? = null) {
        if (ENABLE_LOG) writeLog("W", tag, message, error)
    }
    
    // 记录错误日志
    fun e(tag: String, message: String, error: Throwable? = null) {
        if (ENABLE_LOG) writeLog("E", tag, message, error)
    }
    
    // 强制刷新日志缓冲区
    fun flushAll() {
        if (!ENABLE_LOG || !isRunning.get()) return
        
        try {
            // 等待队列清空
            val startTime = System.currentTimeMillis()
            while (logQueue.isNotEmpty() && System.currentTimeMillis() - startTime < 1000) {
                Thread.sleep(10)
            }
            
            // 刷新文件
            writer?.flush()
        } catch (e: Exception) {
            Log.e(TAG, "强制刷新失败", e)
        }
    }
    
    // 关闭日志系统
    fun close() {
        try {
            // 停止日志系统
            isRunning.set(false)
            
            // 中断写入线程
            writerThread?.interrupt()
            
            // 等待线程结束
            writerThread?.join(2000)
            
            // 处理剩余日志
            val remainingLogs = mutableListOf<LogEntry>()
            logQueue.drainTo(remainingLogs)
            if (remainingLogs.isNotEmpty()) flushPendingLogs(remainingLogs)
            
            // 关闭文件写入器
            writer?.close()
            writer = null
            logFile = null
            writerThread = null
            
            Log.d(TAG, "日志系统关闭")
        } catch (e: Exception) {
            Log.e(TAG, "关闭日志失败", e)
        }
    }
}