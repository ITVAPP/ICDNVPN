package com.example.cfvpn

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri

/**
 * 用于跨进程共享VPN流量统计的ContentProvider
 * 运行在:vpn进程中，与V2RayVpnService同进程
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
         */
        @JvmStatic
        fun updateStats(upload: Long, download: Long, upSpeed: Long, downSpeed: Long, start: Long) {
            synchronized(statsLock) {
                uploadBytes = upload
                downloadBytes = download
                uploadSpeed = upSpeed
                downloadSpeed = downSpeed
                startTime = start
            }
        }
        
        /**
         * 重置统计数据
         */
        @JvmStatic
        fun resetStats() {
            synchronized(statsLock) {
                uploadBytes = 0
                downloadBytes = 0
                uploadSpeed = 0
                downloadSpeed = 0
                startTime = 0
            }
        }
    }
    
    override fun onCreate(): Boolean = true
    
    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?
    ): Cursor {
        val cursor = MatrixCursor(arrayOf(
            "uploadTotal", "downloadTotal", "uploadSpeed", "downloadSpeed", "startTime"
        ))
        
        synchronized(statsLock) {
            cursor.addRow(arrayOf(
                uploadBytes, downloadBytes, uploadSpeed, downloadSpeed, startTime
            ))
        }
        
        return cursor
    }
    
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?): Int = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0
    override fun getType(uri: Uri): String? = null
}
