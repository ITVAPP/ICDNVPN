package com.example.cfvpn

import android.content.Context
import kotlinx.coroutines.*
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.CoroutineContext

/**
 * VPN 文件日志记录器
 * 将日志写入本地文件，支持按标签分类和日期轮转
 * 与 Dart 端的 LogService 保持一致的实现
 */
object VpnFileLogger : CoroutineScope {
    
    // 日志开关 - 默认开启，可通过配置关闭
    @Volatile
    var isEnabled = true
        private set
    
    // 协程相关
    private val job = SupervisorJob()
    override val coroutineContext: CoroutineContext
        get() = Dispatchers.IO + job
    
    // 日志级别
    enum class LogLevel {
        DEBUG, INFO, WARN, ERROR
    }
    
    // 日志上下文
    private data class LogContext(
        val file: File,
        val writer: BufferedWriter,
        val dateStr: String,
        val tag: String,
        var lastWriteTime: Long = System.currentTimeMillis(),
        var isClosed: Boolean = false
    ) {
        fun isExpired(): Boolean {
            val currentDateStr = SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())
            return currentDateStr != dateStr
        }
        
        fun updateWriteTime() {
            lastWriteTime = System.currentTimeMillis()
        }
        
        suspend fun close() {
            if (!isClosed) {
                isClosed = true
                withContext(Dispatchers.IO) {
                    try {
                        writer.flush()
                        writer.close()
                    } catch (e: Exception) {
                        // 静默处理
                    }
                }
            }
        }
    }
    
    // 存储每个标签的日志上下文
    private val logContexts = ConcurrentHashMap<String, LogContext>()
    
    // 日志目录
    private var logDir: File? = null
    
    // 默认标签
    private const val DEFAULT_TAG = "vpn"
    
    // 最大同时打开的文件数
    private const val MAX_OPEN_FILES = 10
    
    // 日期格式化
    private val dateFormat = SimpleDateFormat("yyyyMMdd", Locale.US)
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    
    // 定期检查任务
    private var checkJob: Job? = null
    private var flushJob: Job? = null
    
    /**
     * 初始化日志系统
     * @param context 应用上下文
     * @param enabled 是否启用日志
     */
    fun init(context: Context, enabled: Boolean = true) {
        isEnabled = enabled
        
        if (!isEnabled) {
            // 如果禁用，清理现有资源并返回
            cleanup()
            return
        }
        
        // 设置日志目录
        logDir = File(context.filesDir, "logs").apply {
            if (!exists()) {
                mkdirs()
            }
        }
        
        // 启动定期检查任务（每分钟检查一次日期变更）
        checkJob?.cancel()
        checkJob = launch {
            while (isActive) {
                delay(60_000) // 1分钟
                checkAndRotateLogs()
            }
        }
        
        // 启动自动刷新任务（每30秒刷新一次）
        flushJob?.cancel()
        flushJob = launch {
            while (isActive) {
                delay(30_000) // 30秒
                flushAll()
            }
        }
    }
    
    /**
     * 记录日志
     * @param level 日志级别
     * @param tag 日志标签
     * @param message 日志消息
     * @param error 异常对象（可选）
     */
    fun log(
        level: LogLevel,
        tag: String,
        message: String,
        error: Throwable? = null
    ) {
        if (!isEnabled) return
        
        launch {
            writeLog(level, tag, message, error)
        }
    }
    
    /**
     * 便捷方法 - DEBUG 级别
     */
    fun d(tag: String, message: String) {
        log(LogLevel.DEBUG, tag, message)
    }
    
    /**
     * 便捷方法 - INFO 级别
     */
    fun i(tag: String, message: String) {
        log(LogLevel.INFO, tag, message)
    }
    
    /**
     * 便捷方法 - WARN 级别
     */
    fun w(tag: String, message: String, error: Throwable? = null) {
        log(LogLevel.WARN, tag, message, error)
    }
    
    /**
     * 便捷方法 - ERROR 级别
     */
    fun e(tag: String, message: String, error: Throwable? = null) {
        log(LogLevel.ERROR, tag, message, error)
    }
    
    /**
     * 写入日志到文件
     */
    private suspend fun writeLog(
        level: LogLevel,
        tag: String,
        message: String,
        error: Throwable? = null
    ) = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext
        
        try {
            val context = getOrCreateLogContext(tag) ?: return@withContext
            
            // 格式化日志消息
            val timestamp = timestampFormat.format(Date())
            val logMessage = "[$timestamp] [${level.name}] $message"
            
            // 写入日志
            context.writer.write(logMessage)
            context.writer.newLine()
            
            // 如果有异常，写入异常信息
            if (error != null) {
                context.writer.write("[$timestamp] [${level.name}] Exception: ${error.message}")
                context.writer.newLine()
                error.stackTrace.forEach { element ->
                    context.writer.write("    at $element")
                    context.writer.newLine()
                }
            }
            
            context.updateWriteTime()
            
            // ERROR 级别立即刷新
            if (level == LogLevel.ERROR) {
                context.writer.flush()
            }
        } catch (e: Exception) {
            // 静默处理错误
        }
    }
    
    /**
     * 获取或创建日志上下文
     */
    private suspend fun getOrCreateLogContext(tag: String): LogContext? = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext null
        
        // 规范化标签
        val safeTag = tag.replace(Regex("[^\\w\\-]"), "_")
        
        // 检查现有上下文
        var context = logContexts[safeTag]
        
        // 如果上下文存在且未过期
        if (context != null && !context.isExpired() && !context.isClosed) {
            context.updateWriteTime()
            return@withContext context
        }
        
        // 如果过期或已关闭，先移除旧的
        if (context != null) {
            context.close()
            logContexts.remove(safeTag)
        }
        
        // 创建新的上下文
        try {
            val dir = logDir ?: return@withContext null
            
            val dateStr = dateFormat.format(Date())
            val fileName = "${safeTag}_$dateStr.log"
            val logFile = File(dir, fileName)
            
            // 检查是否是新文件
            val isNewFile = !logFile.exists() || logFile.length() == 0L
            
            // 创建写入器（追加模式）
            val writer = BufferedWriter(FileWriter(logFile, true))
            
            if (isNewFile) {
                // 写入文件头
                writer.write("=" .repeat(50))
                writer.newLine()
                writer.write("=== 日志会话开始 ===")
                writer.newLine()
                writer.write("时间: ${Date()}")
                writer.newLine()
                writer.write("标签: $tag")
                writer.newLine()
                writer.write("=" .repeat(50))
                writer.newLine()
                writer.newLine()
                writer.flush()
            }
            
            // 创建新上下文
            val newContext = LogContext(
                file = logFile,
                writer = writer,
                dateStr = dateStr,
                tag = safeTag
            )
            
            logContexts[safeTag] = newContext
            
            // 如果打开的文件过多，关闭最久未使用的
            if (logContexts.size > MAX_OPEN_FILES) {
                closeOldestContext()
            }
            
            newContext
        } catch (e: Exception) {
            null
        }
    }
    
    /**
     * 检查并轮转日志
     */
    private suspend fun checkAndRotateLogs() = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext
        
        val expiredTags = mutableListOf<String>()
        
        logContexts.forEach { (tag, context) ->
            if (context.isExpired()) {
                expiredTags.add(tag)
            }
        }
        
        // 关闭过期的上下文
        expiredTags.forEach { tag ->
            val context = logContexts.remove(tag)
            context?.close()
        }
    }
    
    /**
     * 关闭最久未使用的上下文
     */
    private suspend fun closeOldestContext() = withContext(Dispatchers.IO) {
        val oldest = logContexts.entries
            .minByOrNull { it.value.lastWriteTime }
        
        if (oldest != null) {
            val context = logContexts.remove(oldest.key)
            context?.close()
        }
    }
    
    /**
     * 刷新所有日志缓冲区
     */
    suspend fun flushAll() = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext
        
        logContexts.values.forEach { context ->
            if (!context.isClosed) {
                try {
                    context.writer.flush()
                } catch (e: Exception) {
                    // 静默处理
                }
            }
        }
    }
    
    /**
     * 刷新指定标签的日志
     */
    suspend fun flush(tag: String) = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext
        
        val safeTag = tag.replace(Regex("[^\\w\\-]"), "_")
        val context = logContexts[safeTag]
        
        if (context != null && !context.isClosed) {
            try {
                context.writer.flush()
            } catch (e: Exception) {
                // 静默处理
            }
        }
    }
    
    /**
     * 清空指定标签的日志文件
     */
    suspend fun clearLog(tag: String) = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext
        
        val safeTag = tag.replace(Regex("[^\\w\\-]"), "_")
        
        // 关闭现有上下文
        val context = logContexts.remove(safeTag)
        context?.close()
        
        // 删除所有相关文件
        val dir = logDir ?: return@withContext
        
        dir.listFiles()?.forEach { file ->
            if (file.name.startsWith("${safeTag}_") && file.name.endsWith(".log")) {
                try {
                    file.delete()
                } catch (e: Exception) {
                    // 尝试清空内容
                    try {
                        file.writeText("")
                    } catch (e2: Exception) {
                        // 静默处理
                    }
                }
            }
        }
    }
    
    /**
     * 清空所有日志
     */
    suspend fun clearAllLogs() = withContext(Dispatchers.IO) {
        if (!isEnabled) return@withContext
        
        // 关闭所有上下文
        logContexts.values.forEach { it.close() }
        logContexts.clear()
        
        // 删除所有日志文件
        val dir = logDir ?: return@withContext
        
        dir.listFiles()?.forEach { file ->
            if (file.name.endsWith(".log")) {
                try {
                    file.delete()
                } catch (e: Exception) {
                    // 尝试清空内容
                    try {
                        file.writeText("")
                    } catch (e2: Exception) {
                        // 静默处理
                    }
                }
            }
        }
    }
    
    /**
     * 获取日志目录路径
     */
    fun getLogDirectory(): String? = logDir?.absolutePath
    
    /**
     * 获取指定标签的当前日志文件路径
     */
    fun getLogFile(tag: String): String? {
        val safeTag = tag.replace(Regex("[^\\w\\-]"), "_")
        return logContexts[safeTag]?.file?.absolutePath
    }
    
    /**
     * 获取指定标签的所有日志文件
     */
    fun getAllLogFilesForTag(tag: String): List<String> {
        val safeTag = tag.replace(Regex("[^\\w\\-]"), "_")
        val files = mutableListOf<String>()
        
        val dir = logDir ?: return files
        
        dir.listFiles()?.forEach { file ->
            if (file.name.startsWith("${safeTag}_") && file.name.endsWith(".log")) {
                files.add(file.absolutePath)
            }
        }
        
        return files
    }
    
    /**
     * 设置日志开关
     * @param enabled true 启用，false 禁用
     */
    fun setEnabled(enabled: Boolean) {
        if (isEnabled == enabled) return
        
        isEnabled = enabled
        
        if (!isEnabled) {
            // 禁用时清理资源
            cleanup()
        }
    }
    
    /**
     * 清理资源
     */
    private fun cleanup() {
        runBlocking {
            // 取消定时任务
            checkJob?.cancel()
            checkJob = null
            flushJob?.cancel()
            flushJob = null
            
            // 关闭所有日志上下文
            logContexts.values.forEach { it.close() }
            logContexts.clear()
        }
    }
    
    /**
     * 关闭日志系统
     */
    fun close() {
        cleanup()
        job.cancel()
    }
}
