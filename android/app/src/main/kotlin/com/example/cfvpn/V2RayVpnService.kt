package com.example.cfvpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import java.io.File

// 导入libv2ray - 使用正确的包名
import go.Seq
import libv2ray.Libv2ray
import libv2ray.V2RayPoint
import libv2ray.V2RayVPNServiceSupportsSet

/**
 * V2Ray VPN服务实现
 * 使用libv2ray.aar提供VPN功能
 */
class V2RayVpnService : VpnService(), V2RayVPNServiceSupportsSet {
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        
        // VPN配置常量
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        
        // 服务状态
        @Volatile
        private var isRunning = false
        
        // 单例服务引用
        @Volatile
        private var instance: V2RayVpnService? = null
        
        /**
         * 启动VPN服务
         */
        fun startVpnService(context: Context, config: String, globalProxy: Boolean = false) {
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN"
                putExtra("config", config)
                putExtra("globalProxy", globalProxy)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
        
        /**
         * 停止VPN服务
         */
        fun stopVpnService(context: Context) {
            context.sendBroadcast(Intent(ACTION_STOP_VPN))
            context.stopService(Intent(context, V2RayVpnService::class.java))
        }
        
        /**
         * 检查服务是否运行
         */
        fun isServiceRunning(): Boolean = isRunning
        
        /**
         * 获取流量统计
         */
        fun getTrafficStats(): Map<String, Long> {
            return instance?.getCurrentTrafficStats() ?: mapOf(
                "uploadTotal" to 0L,
                "downloadTotal" to 0L,
                "uploadSpeed" to 0L,
                "downloadSpeed" to 0L
            )
        }
    }
    
    // V2Ray核心对象
    private var v2rayPoint: V2RayPoint? = null
    private var mInterface: ParcelFileDescriptor? = null
    
    // 配置
    private var configContent: String = ""
    private var globalProxy: Boolean = false
    
    // 协程作用域
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var lastUploadBytes: Long = 0
    private var lastDownloadBytes: Long = 0
    private var lastQueryTime: Long = 0
    private var startTime: Long = 0
    
    // 统计定时器
    private var statsJob: Job? = null
    
    // 广播接收器
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                Log.d(TAG, "收到停止VPN广播")
                stopV2Ray()
            }
        }
    }
    
    override fun onCreate() {
        super.onCreate()
        
        instance = this
        
        // 初始化Go运行时
        try {
            Seq.setContext(applicationContext)
            Log.d(TAG, "Go运行时初始化成功")
        } catch (e: Exception) {
            Log.e(TAG, "Go运行时初始化失败", e)
        }
        
        // 注册广播接收器
        registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
        
        // 初始化V2Ray
        initializeV2Ray()
        
        Log.d(TAG, "VPN服务已创建")
    }
    
    /**
     * 初始化V2Ray
     */
    private fun initializeV2Ray() {
        try {
            // 复制geo文件
            copyAssetFiles()
            
            // 创建V2Ray点
            val assetPath = File(filesDir, "assets").absolutePath
            v2rayPoint = Libv2ray.newV2RayPoint(this, assetPath)
            
            // 设置包名
            v2rayPoint?.packageName = packageName
            
            Log.d(TAG, "V2Ray初始化成功，资源路径: $assetPath")
        } catch (e: Exception) {
            Log.e(TAG, "V2Ray初始化失败", e)
        }
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action != "START_VPN") {
            Log.w(TAG, "无效的启动意图")
            return START_NOT_STICKY
        }
        
        if (isRunning) {
            Log.w(TAG, "VPN服务已在运行")
            return START_STICKY
        }
        
        configContent = intent.getStringExtra("config") ?: ""
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        
        if (configContent.isEmpty()) {
            Log.e(TAG, "配置为空")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 启动前台服务
        startForeground(NOTIFICATION_ID, createNotification())
        
        // 启动V2Ray
        serviceScope.launch {
            try {
                startV2Ray()
            } catch (e: Exception) {
                Log.e(TAG, "启动V2Ray失败", e)
                withContext(Dispatchers.Main) {
                    stopSelf()
                }
            }
        }
        
        return START_STICKY
    }
    
    /**
     * 复制资源文件
     */
    private fun copyAssetFiles() {
        val assetDir = File(filesDir, "assets")
        if (!assetDir.exists()) {
            assetDir.mkdirs()
        }
        
        val files = listOf("geoip.dat", "geoip-only-cn-private.dat", "geosite.dat")
        
        for (fileName in files) {
            val targetFile = File(assetDir, fileName)
            
            if (shouldUpdateFile(fileName, targetFile)) {
                copyAssetFile(fileName, targetFile)
            } else {
                Log.d(TAG, "文件已是最新: $fileName")
            }
        }
    }
    
    /**
     * 检查文件是否需要更新
     */
    private fun shouldUpdateFile(assetName: String, targetFile: File): Boolean {
        if (!targetFile.exists()) return true
        
        return try {
            val assetSize = assets.open(assetName).use { it.available() }
            targetFile.length() != assetSize.toLong()
        } catch (e: Exception) {
            true
        }
    }
    
    /**
     * 复制单个资源文件
     */
    private fun copyAssetFile(assetName: String, targetFile: File) {
        try {
            assets.open(assetName).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            Log.d(TAG, "成功复制文件: $assetName")
        } catch (e: Exception) {
            Log.e(TAG, "复制文件失败: $assetName", e)
        }
    }
    
    /**
     * 启动V2Ray核心
     */
    private suspend fun startV2Ray() = withContext(Dispatchers.IO) {
        try {
            Log.d(TAG, "开始启动V2Ray")
            
            // 建立VPN隧道
            establishVpn()
            
            // 设置配置
            v2rayPoint?.configureFileContent = configContent
            
            // 设置域名
            v2rayPoint?.domainName = parseDomainFromConfig(configContent)
            
            // 启动V2Ray核心
            val result = v2rayPoint?.runLoop(false) ?: -1L
            if (result != 0L) {
                throw Exception("V2Ray启动失败，错误码: $result")
            }
            
            isRunning = true
            startTime = System.currentTimeMillis()
            
            Log.i(TAG, "V2Ray启动成功")
            
            // 启动流量监控
            startTrafficMonitor()
            
        } catch (e: Exception) {
            Log.e(TAG, "启动V2Ray失败", e)
            isRunning = false
            throw e
        }
    }
    
    /**
     * 从配置中解析域名
     */
    private fun parseDomainFromConfig(config: String): String {
        return try {
            val regex = """"address"\s*:\s*"([^"]+)"""".toRegex()
            regex.find(config)?.groupValues?.get(1) ?: ""
        } catch (e: Exception) {
            ""
        }
    }
    
    /**
     * 建立VPN隧道
     */
    private fun establishVpn() {
        val builder = Builder()
        
        builder.setSession("CFVPN")
        builder.setMtu(VPN_MTU)
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126)
            } catch (e: Exception) {
                Log.w(TAG, "添加IPv6地址失败", e)
            }
        }
        
        // DNS服务器
        builder.addDnsServer("8.8.8.8")
        builder.addDnsServer("8.8.4.4")
        builder.addDnsServer("1.1.1.1")
        builder.addDnsServer("1.0.0.1")
        
        // 路由规则
        if (globalProxy) {
            Log.d(TAG, "设置全局代理路由")
            builder.addRoute("0.0.0.0", 0)
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                try {
                    builder.addRoute("::", 0)
                } catch (e: Exception) {
                    Log.w(TAG, "添加IPv6路由失败", e)
                }
            }
        } else {
            Log.d(TAG, "设置智能路由模式")
            builder.addRoute("0.0.0.0", 0)
        }
        
        // 绕过VPN的应用
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                Log.w(TAG, "设置绕过应用失败", e)
            }
        }
        
        mInterface?.close()
        mInterface = builder.establish() ?: throw Exception("建立VPN隧道失败")
        
        Log.d(TAG, "VPN隧道已建立，FD: ${mInterface?.fd}")
    }
    
    /**
     * 停止V2Ray
     */
    private fun stopV2Ray() {
        Log.d(TAG, "正在停止V2Ray...")
        
        isRunning = false
        statsJob?.cancel()
        statsJob = null
        
        try {
            v2rayPoint?.stopLoop()
            Log.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            Log.e(TAG, "停止V2Ray核心失败", e)
        }
        
        try {
            mInterface?.close()
            mInterface = null
            Log.d(TAG, "VPN接口已关闭")
        } catch (e: Exception) {
            Log.e(TAG, "关闭VPN接口失败", e)
        }
        
        stopForeground(true)
        stopSelf()
        
        Log.i(TAG, "V2Ray服务已停止")
    }
    
    /**
     * 创建通知
     */
    private fun createNotification(): android.app.Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "CFVPN服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "CFVPN服务运行状态"
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
        
        val stopIntent = Intent(ACTION_STOP_VPN)
        val stopPendingIntent = PendingIntent.getBroadcast(
            this, 0, stopIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )
        
        val mainIntent = packageManager.getLaunchIntentForPackage(packageName)
        val mainPendingIntent = if (mainIntent != null) {
            PendingIntent.getActivity(
                this, 0, mainIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )
        } else {
            null
        }
        
        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("CFVPN")
            .setContentText(if (globalProxy) "全局代理模式" else "智能代理模式")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopPendingIntent)
        
        if (mainPendingIntent != null) {
            builder.setContentIntent(mainPendingIntent)
        }
        
        return builder.build()
    }
    
    /**
     * 启动流量监控
     */
    private fun startTrafficMonitor() {
        statsJob?.cancel()
        
        statsJob = serviceScope.launch {
            delay(5000)
            
            while (isRunning) {
                try {
                    updateTrafficStats()
                } catch (e: Exception) {
                    Log.w(TAG, "更新流量统计失败", e)
                }
                
                delay(10000)
            }
        }
    }
    
    /**
     * 更新流量统计
     */
    private fun updateTrafficStats() {
        try {
            val stats = v2rayPoint?.queryStats("", true)
            
            if (!stats.isNullOrEmpty()) {
                parseTrafficStats(stats)
                
                val now = System.currentTimeMillis()
                if (now - lastQueryTime > 10000) {
                    updateNotification()
                    lastQueryTime = now
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "查询流量统计失败", e)
        }
    }
    
    /**
     * 解析流量统计
     */
    private fun parseTrafficStats(stats: String) {
        try {
            val previousUpload = uploadBytes
            val previousDownload = downloadBytes
            val previousTime = lastQueryTime
            
            var proxyUplink: Long = 0
            var proxyDownlink: Long = 0
            
            stats.split("\n").forEach { line ->
                when {
                    line.contains("outbound>>>proxy>>>traffic>>>uplink") -> {
                        val value = line.substringAfter(":").trim()
                        proxyUplink = value.toLongOrNull() ?: 0
                    }
                    line.contains("outbound>>>proxy>>>traffic>>>downlink") -> {
                        val value = line.substringAfter(":").trim()
                        proxyDownlink = value.toLongOrNull() ?: 0
                    }
                }
            }
            
            uploadBytes = proxyUplink
            downloadBytes = proxyDownlink
            
            val now = System.currentTimeMillis()
            if (previousTime > 0 && now > previousTime) {
                val timeDiff = (now - previousTime) / 1000.0
                if (timeDiff > 0) {
                    val uploadDiff = uploadBytes - previousUpload
                    val downloadDiff = downloadBytes - previousDownload
                    
                    if (uploadDiff >= 0 && downloadDiff >= 0) {
                        lastUploadBytes = (uploadDiff / timeDiff).toLong()
                        lastDownloadBytes = (downloadDiff / timeDiff).toLong()
                    }
                }
            }
            
            lastQueryTime = now
            
            if (uploadBytes != previousUpload || downloadBytes != previousDownload || 
                lastUploadBytes > 0 || lastDownloadBytes > 0) {
                Log.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)} " +
                          "速度: ↑${formatBytes(lastUploadBytes)}/s ↓${formatBytes(lastDownloadBytes)}/s")
            }
            
        } catch (e: Exception) {
            Log.w(TAG, "解析流量统计失败", e)
        }
    }
    
    /**
     * 更新通知显示流量信息
     */
    private fun updateNotification() {
        val duration = formatDuration(System.currentTimeMillis() - startTime)
        val upload = formatBytes(uploadBytes)
        val download = formatBytes(downloadBytes)
        
        val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("CFVPN - 已连接")
            .setContentText("$duration | ↑ $upload ↓ $download")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
        
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, notification)
    }
    
    /**
     * 获取当前流量统计
     */
    fun getCurrentTrafficStats(): Map<String, Long> {
        return mapOf(
            "uploadTotal" to uploadBytes,
            "downloadTotal" to downloadBytes,
            "uploadSpeed" to lastUploadBytes,
            "downloadSpeed" to lastDownloadBytes
        )
    }
    
    // ===== V2RayVPNServiceSupportsSet 接口实现 =====
    
    override fun onEmitStatus(status: String?): Boolean {
        Log.d(TAG, "V2Ray状态: $status")
        return true
    }
    
    override fun setup(parameters: String?): Long {
        // 返回VPN文件描述符
        return mInterface?.fd?.toLong() ?: -1
    }
    
    override fun prepare(): Boolean {
        // 检查VPN权限
        return VpnService.prepare(this) == null
    }
    
    override fun protect(fd: Long): Boolean {
        // 保护socket不通过VPN
        return protect(fd.toInt())
    }
    
    override fun shutdown(): Boolean {
        stopV2Ray()
        return true
    }
    
    // ===== 工具方法 =====
    
    private fun formatBytes(bytes: Long): String {
        return when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> String.format("%.2f KB", bytes / 1024.0)
            bytes < 1024 * 1024 * 1024 -> String.format("%.2f MB", bytes / (1024.0 * 1024))
            else -> String.format("%.2f GB", bytes / (1024.0 * 1024 * 1024))
        }
    }
    
    private fun formatDuration(millis: Long): String {
        val seconds = (millis / 1000) % 60
        val minutes = (millis / (1000 * 60)) % 60
        val hours = millis / (1000 * 60 * 60)
        return String.format("%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    override fun onDestroy() {
        super.onDestroy()
        
        instance = null
        serviceScope.cancel()
        
        try {
            unregisterReceiver(stopReceiver)
        } catch (e: Exception) {
            // 忽略
        }
        
        if (isRunning) {
            stopV2Ray()
        }
        
        Log.d(TAG, "VPN服务已销毁")
    }
}
