package com.example.cfvpn

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri

/**
 * 用于跨进程共享VPN流量统计和连接状态的ContentProvider
 * 运行在:vpn进程中，与V2RayVpnService同进程
 * 
 * 修复版本：
 * 1. 移除权限限制，仅应用内访问
 * 2. 增加连接状态查询支持
 */
class TrafficStatsProvider : ContentProvider() {
    
    companion object {
        const val AUTHORITY = "com.example.cfvpn.trafficprovider"
        val CONTENT_URI: Uri = Uri.parse("content://$AUTHORITY/stats")
        
        // 同步锁
        private val statsLock = Any()
        
        // 流量数据（仅在:vpn进程中访问）
        @Volatile
        private var uploadBytes: Long = 0
        
        @Volatile
        private var downloadBytes: Long = 0
        
        @Volatile
        private var uploadSpeed: Long = 0
        
        @Volatile
        private var downloadSpeed: Long = 0
        
        @Volatile
        private var startTime: Long = 0
        
        /**
         * 由V2RayVpnService调用，更新流量数据
         * 因为在同一进程，可以直接调用
         * 
         * @param upload 总上传字节数
         * @param download 总下载字节数
         * @param upSpeed 上传速度（字节/秒）
         * @param downSpeed 下载速度（字节/秒）
         * @param start 连接开始时间（毫秒时间戳），0表示未连接
         */
        @JvmStatic
        fun updateStats(upload: Long, download: Long, upSpeed: Long, downSpeed: Long, start: Long) {
            synchronized(statsLock) {
                uploadBytes = upload
                downloadBytes = download
                uploadSpeed = upSpeed
                downloadSpeed = downSpeed
                startTime = start
                
                // 调试日志
                if (start > 0 && (upload > 0 || download > 0)) {
                    VpnFileLogger.d("TrafficStatsProvider", 
                        "更新流量统计: ↑${formatBytes(upload)} ↓${formatBytes(download)}")
                }
            }
        }
        
        /**
         * 重置统计数据
         * 在VPN断开时调用
         */
        @JvmStatic
        fun resetStats() {
            synchronized(statsLock) {
                uploadBytes = 0
                downloadBytes = 0
                uploadSpeed = 0
                downloadSpeed = 0
                startTime = 0
                
                VpnFileLogger.d("TrafficStatsProvider", "流量统计已重置")
            }
        }
        
        /**
         * 获取连接状态
         * 供V2RayVpnService内部使用
         * 
         * @return true表示已连接，false表示未连接
         */
        @JvmStatic
        fun isConnected(): Boolean {
            synchronized(statsLock) {
                // startTime > 0 表示已连接
                return startTime > 0
            }
        }
        
        /**
         * 获取当前统计数据
         * 供V2RayVpnService内部使用
         */
        @JvmStatic
        fun getCurrentStats(): TrafficStats {
            synchronized(statsLock) {
                return TrafficStats(
                    uploadBytes,
                    downloadBytes,
                    uploadSpeed,
                    downloadSpeed,
                    startTime
                )
            }
        }
        
        /**
         * 格式化字节数（内部使用）
         */
        private fun formatBytes(bytes: Long): String {
            return when {
                bytes < 0 -> "0 B"
                bytes < 1024 -> "$bytes B"
                bytes < 1024 * 1024 -> String.format("%.2f KB", bytes / 1024.0)
                bytes < 1024 * 1024 * 1024 -> String.format("%.2f MB", bytes / (1024.0 * 1024))
                else -> String.format("%.2f GB", bytes / (1024.0 * 1024 * 1024))
            }
        }
    }
    
    /**
     * 流量统计数据类
     */
    data class TrafficStats(
        val uploadBytes: Long,
        val downloadBytes: Long,
        val uploadSpeed: Long,
        val downloadSpeed: Long,
        val startTime: Long
    ) {
        val isConnected: Boolean
            get() = startTime > 0
            
        val connectionDuration: Long
            get() = if (startTime > 0) {
                System.currentTimeMillis() - startTime
            } else {
                0
            }
    }
    
    override fun onCreate(): Boolean {
        VpnFileLogger.d("TrafficStatsProvider", "ContentProvider创建")
        return true
    }
    
    /**
     * 查询流量统计数据
     * 供其他进程（如MainActivity）调用
     */
    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?
    ): Cursor {
        val cursor = MatrixCursor(arrayOf(
            "uploadTotal",    // 总上传字节数
            "downloadTotal",  // 总下载字节数
            "uploadSpeed",    // 上传速度
            "downloadSpeed",  // 下载速度
            "startTime"       // 连接开始时间（0表示未连接）
        ))
        
        synchronized(statsLock) {
            cursor.addRow(arrayOf(
                uploadBytes, 
                downloadBytes, 
                uploadSpeed, 
                downloadSpeed, 
                startTime
            ))
            
            // 调试日志（移除isDebugEnabled检查）
            // VpnFileLogger可能没有isDebugEnabled方法，直接记录日志即可
        }
        
        
        // 设置通知URI，以便数据更新时通知观察者
        cursor.setNotificationUri(context?.contentResolver, uri)
        
        return cursor
    }
    
    /**
     * 插入操作（不支持）
     */
    override fun insert(uri: Uri, values: ContentValues?): Uri? {
        // 不支持插入操作
        return null
    }
    
    /**
     * 更新操作（不支持）
     */
    override fun update(
        uri: Uri, 
        values: ContentValues?, 
        selection: String?, 
        selectionArgs: Array<String>?
    ): Int {
        // 不支持更新操作
        return 0
    }
    
    /**
     * 删除操作（不支持）
     */
    override fun delete(
        uri: Uri, 
        selection: String?, 
        selectionArgs: Array<String>?
    ): Int {
        // 不支持删除操作
        return 0
    }
    
    /**
     * 获取MIME类型
     */
    override fun getType(uri: Uri): String? {
        return "vnd.android.cursor.dir/vnd.com.example.cfvpn.stats"
    }
}
