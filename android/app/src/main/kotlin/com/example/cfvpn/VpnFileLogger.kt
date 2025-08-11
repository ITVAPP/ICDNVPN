package com.example.cfvpn

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.*

/**
 * VPN 文件日志记录器 - 精简版
 * 设计原则：简单可靠，同步写入，内部控制开关
 */
object VpnFileLogger {
    
    private const val TAG = "VpnFileLogger"
    
    // ========== 日志开关 - 只在这里修改！ ==========
    // 开发环境：true
    // 生产环境：false
    private const val ENABLE_LOG = true  // <-- 生产环境改为 false
    // ===============================================
    
    private var logFile: File? = null
    private var writer: FileWriter? = null
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
    
    /**
     * 初始化日志系统
     */
    fun init(context: Context) {
        if (!ENABLE_LOG) {
            return  // 日志关闭，直接返回
        }
        
        try {
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
                flush() // 立即刷新
            }
            
            Log.d(TAG, "日志系统初始化成功: ${logFile?.absolutePath}")
            
        } catch (e: Exception) {
            Log.e(TAG, "初始化失败", e)
        }
    }
    
    /**
     * 写入日志（同步方式）
     */
    private fun writeLog(level: String, tag: String, message: String, error: Throwable? = null) {
        // 检查日志开关
        if (!ENABLE_LOG) return
        
        // 同时输出到Logcat（调试用）
        when (level) {
            "D" -> Log.d(tag, message, error)
            "I" -> Log.i(tag, message, error)
            "W" -> Log.w(tag, message, error)
            "E" -> Log.e(tag, message, error)
        }
        
        // 写入文件
        try {
            writer?.apply {
                val timestamp = dateFormat.format(Date())
                write("[$timestamp] [$level] [$tag] $message\n")
                
                // 如果有异常，写入堆栈
                if (error != null) {
                    write("  Exception: ${error.message}\n")
                    error.stackTrace.take(5).forEach { 
                        write("    at $it\n")
                    }
                }
                
                flush() // 每次都刷新，确保写入磁盘
            }
        } catch (e: Exception) {
            Log.e(TAG, "写入日志失败", e)
        }
    }
    
    // 便捷方法
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
     * 刷新日志缓冲区
     */
    fun flushAll() {
        if (!ENABLE_LOG) return
        
        try {
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
            writer?.close()
            writer = null
            logFile = null
        } catch (e: Exception) {
            Log.e(TAG, "关闭失败", e)
        }
    }
}