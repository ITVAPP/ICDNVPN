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

// 正确的导入 - 基于实际的 AAR 分析
import go.Seq
import libv2ray.Libv2ray
import libv2ray.CoreController
import libv2ray.CoreCallbackHandler

/**
 * V2Ray VPN服务实现
 * 使用 libv2ray.aar (2dust/AndroidLibV2rayLite)
 */
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        
        @Volatile
        private var isRunning = false
        
        fun startVpnService(context: Context, config: String, globalProxy: Boolean = false) {
            Log.d(TAG, "Starting VPN service")
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
        
        fun stopVpnService(context: Context) {
            Log.d(TAG, "Stopping VPN service")
            context.sendBroadcast(Intent(ACTION_STOP_VPN))
            context.stopService(Intent(context, V2RayVpnService::class.java))
        }
    }
    
    // V2Ray 核心控制器
    private var coreController: CoreController? = null
    
    // VPN 接口
    private var mInterface: ParcelFileDescriptor? = null
    
    // 配置
    private var configContent: String = ""
    private var globalProxy: Boolean = false
    
    // 协程作用域
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var startTime: Long = 0
    
    // 广播接收器
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                Log.d(TAG, "Received stop VPN broadcast")
                stopV2Ray()
            }
        }
    }
    
    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate")
        
        try {
            // 初始化 Go 运行时
            Seq.setContext(applicationContext)
            Log.d(TAG, "Go runtime initialized")
            
            // 初始化 V2Ray 核心环境
            val assetPath = File(filesDir, "").absolutePath
            Libv2ray.initCoreEnv(assetPath, "")
            Log.d(TAG, "V2Ray core environment initialized")
            
            // 注册广播接收器
            registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
            
            // 复制资源文件
            copyAssetFiles()
            
        } catch (e: Exception) {
            Log.e(TAG, "Initialization failed", e)
        }
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: ${intent?.action}")
        
        if (intent?.action != "START_VPN") {
            stopSelf()
            return START_NOT_STICKY
        }
        
        if (isRunning) {
            Log.w(TAG, "VPN already running")
            return START_STICKY
        }
        
        configContent = intent.getStringExtra("config") ?: ""
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        
        if (configContent.isEmpty()) {
            Log.e(TAG, "No config provided")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 启动前台服务
        startForeground(NOTIFICATION_ID, createNotification())
        
        // 异步启动 V2Ray
        serviceScope.launch {
            startV2Ray()
        }
        
        return START_STICKY
    }
    
    private suspend fun startV2Ray() = withContext(Dispatchers.IO) {
        try {
            Log.d(TAG, "Starting V2Ray core")
            
            // 建立 VPN 隧道
            establishVpn()
            
            if (mInterface == null) {
                throw Exception("Failed to establish VPN tunnel")
            }
            
            // 创建核心控制器
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            // 启动 V2Ray 核心
            coreController?.let { controller ->
                controller.startLoop(configContent)
                isRunning = controller.isRunning
                
                if (isRunning) {
                    startTime = System.currentTimeMillis()
                    Log.i(TAG, "V2Ray core started successfully")
                    
                    // 启动流量监控
                    startTrafficMonitor()
                } else {
                    throw Exception("Failed to start V2Ray core")
                }
            } ?: throw Exception("CoreController is null")
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start V2Ray", e)
            isRunning = false
            mInterface?.close()
            mInterface = null
            stopSelf()
        }
    }
    
    private fun establishVpn() {
        Log.d(TAG, "Establishing VPN tunnel")
        
        mInterface?.close()
        mInterface = null
        
        val builder = Builder()
        builder.setSession("CFVPN")
        builder.setMtu(VPN_MTU)
        
        // IPv4 地址
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        
        // 路由规则
        if (globalProxy) {
            builder.addRoute("0.0.0.0", 0)
        } else {
            // 智能分流
            builder.addRoute("0.0.0.0", 0)
        }
        
        // DNS 服务器
        builder.addDnsServer("8.8.8.8")
        builder.addDnsServer("8.8.4.4")
        builder.addDnsServer("1.1.1.1")
        builder.addDnsServer("1.0.0.1")
        
        // 绕过自己的应用
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to add disallowed application", e)
            }
        }
        
        mInterface = builder.establish()
        Log.d(TAG, "VPN tunnel established: FD=${mInterface?.fd}")
    }
    
    private fun stopV2Ray() {
        Log.d(TAG, "Stopping V2Ray")
        
        isRunning = false
        
        // 停止核心控制器
        try {
            coreController?.stopLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping core controller", e)
        }
        coreController = null
        
        // 关闭 VPN 接口
        mInterface?.close()
        mInterface = null
        
        // 停止服务
        stopForeground(true)
        stopSelf()
    }
    
    // ===== CoreCallbackHandler 接口实现 =====
    
    override fun startup(): Long {
        Log.d(TAG, "CoreCallbackHandler.startup()")
        
        // 返回 VPN 文件描述符
        val fd = mInterface?.fd ?: -1
        
        // 保护 socket
        if (fd > 0) {
            protect(fd)
        }
        
        return fd.toLong()
    }
    
    override fun shutdown(): Long {
        Log.d(TAG, "CoreCallbackHandler.shutdown()")
        stopV2Ray()
        return 0
    }
    
    override fun onEmitStatus(level: Long, status: String?): Long {
        // 日志级别: 0=Debug, 1=Info, 2=Warning, 3=Error
        when (level.toInt()) {
            0 -> Log.d(TAG, "V2Ray: $status")
            1 -> Log.i(TAG, "V2Ray: $status")
            2 -> Log.w(TAG, "V2Ray: $status")
            3 -> Log.e(TAG, "V2Ray: $status")
            else -> Log.v(TAG, "V2Ray[$level]: $status")
        }
        return 0
    }
    
    // ===== 流量监控 =====
    
    private fun startTrafficMonitor() {
        serviceScope.launch {
            while (isRunning) {
                try {
                    updateTrafficStats()
                } catch (e: Exception) {
                    Log.w(TAG, "Error updating traffic stats", e)
                }
                delay(5000) // 5秒更新一次
            }
        }
    }
    
    private fun updateTrafficStats() {
        coreController?.let { controller ->
            // 查询流量统计
            uploadBytes = controller.queryStats("proxy", "uplink")
            downloadBytes = controller.queryStats("proxy", "downlink")
            
            Log.d(TAG, "Traffic - Upload: ${formatBytes(uploadBytes)}, Download: ${formatBytes(downloadBytes)}")
            
            // 更新通知
            updateNotification()
        }
    }
    
    private fun updateNotification() {
        val duration = formatDuration(System.currentTimeMillis() - startTime)
        val upload = formatBytes(uploadBytes)
        val download = formatBytes(downloadBytes)
        
        val notification = createNotification("Connected • $duration • ↑$upload ↓$download")
        
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, notification)
    }
    
    // ===== 辅助方法 =====
    
    private fun copyAssetFiles() {
        val files = listOf("geoip.dat", "geosite.dat", "geoip-only-cn-private.dat")
        
        for (fileName in files) {
            try {
                val targetFile = File(filesDir, fileName)
                if (!targetFile.exists() || shouldUpdateFile(fileName, targetFile)) {
                    assets.open(fileName).use { input ->
                        targetFile.outputStream().use { output ->
                            input.copyTo(output)
                        }
                    }
                    Log.d(TAG, "Copied asset: $fileName")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to copy $fileName: ${e.message}")
            }
        }
    }
    
    private fun shouldUpdateFile(assetName: String, targetFile: File): Boolean {
        return try {
            val assetSize = assets.open(assetName).use { it.available() }
            targetFile.length() != assetSize.toLong()
        } catch (e: Exception) {
            true
        }
    }
    
    private fun createNotification(text: String = "VPN is running"): android.app.Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "CFVPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
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
        
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("CFVPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPendingIntent)
            .build()
    }
    
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
        Log.d(TAG, "onDestroy")
        
        serviceScope.cancel()
        
        try {
            unregisterReceiver(stopReceiver)
        } catch (e: Exception) {
            // Already unregistered
        }
        
        if (isRunning) {
            stopV2Ray()
        }
    }
}
