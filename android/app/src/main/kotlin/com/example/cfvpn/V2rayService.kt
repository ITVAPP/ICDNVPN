package com.example.cfvpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import go.Seq
import kotlinx.coroutines.*
import libv2ray.Libv2ray
import libv2ray.V2RayPoint
import libv2ray.V2RayVPNServiceSupportsSet
import org.json.JSONObject
import java.io.File

/**
 * 代理服务实现 - 仅代理模式（不使用VPN）
 * 用于不需要VPN权限的纯代理模式
 */
class V2rayService : Service() {
    companion object {
        private const val TAG = "V2rayService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "v2ray_proxy_channel"
        
        // 服务命令
        const val ACTION_START = "com.example.cfvpn.START_PROXY"
        const val ACTION_STOP = "com.example.cfvpn.STOP_PROXY"
        const val ACTION_QUERY_STATUS = "com.example.cfvpn.QUERY_STATUS"
        
        // 广播Action
        const val BROADCAST_STATUS = "V2RAY_CONNECTION_INFO"
        
        // V2RayPoint单例
        @Volatile
        private var v2rayPoint: V2RayPoint? = null
        
        @Volatile
        var isRunning = false
            private set
            
        @Volatile
        var connectionState = "DISCONNECTED"
            private set
            
        // 统计数据
        @Volatile
        private var lastUploadBytes = 0L
        @Volatile
        private var lastDownloadBytes = 0L
        @Volatile
        private var lastQueryTime = 0L
        @Volatile
        private var connectionStartTime = 0L
        
        // 计时
        private var seconds = 0
        private var minutes = 0
        private var hours = 0
    }
    
    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var statusUpdateJob: Job? = null
    
    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Proxy Service onCreate")
        
        // 初始化Go序列化上下文
        try {
            Seq.setContext(applicationContext)
            Log.d(TAG, "Go Seq context initialized")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize Go Seq", e)
        }
        
        // 初始化V2Ray环境
        initializeV2RayEnvironment()
        
        // 创建通知渠道
        createNotificationChannel()
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: ${intent?.action}")
        
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra("config")
                val remark = intent.getStringExtra("remark") ?: "Proxy Server"
                
                if (config != null) {
                    startProxy(config, remark)
                } else {
                    Log.e(TAG, "Config is null")
                    stopSelf()
                }
            }
            ACTION_STOP -> {
                stopProxy()
                stopSelf()
            }
            ACTION_QUERY_STATUS -> {
                sendStatusBroadcast()
            }
        }
        
        return START_STICKY
    }
    
    private fun initializeV2RayEnvironment() {
        try {
            // 复制geo文件
            copyAssetFiles()
            
            // 初始化V2Ray环境
            val v2rayPath = filesDir.absolutePath
            Libv2ray.initV2Env(v2rayPath, "")
            Log.d(TAG, "V2Ray environment initialized at: $v2rayPath")
            
            // 创建V2RayPoint - 代理模式
            if (v2rayPoint == null) {
                v2rayPoint = Libv2ray.newV2RayPoint(object : V2RayVPNServiceSupportsSet {
                    override fun shutdown(): Long {
                        Log.d(TAG, "V2RayPoint shutdown callback")
                        return 0
                    }
                    
                    override fun prepare(): Long {
                        return 0  // 代理模式不需要VPN权限
                    }
                    
                    override fun protect(socket: Long): Boolean {
                        return true  // 代理模式不需要保护socket
                    }
                    
                    override fun onEmitStatus(status: Long, message: String?): Long {
                        Log.d(TAG, "V2Ray status: $status - $message")
                        return 0
                    }
                    
                    override fun setup(parameters: String?): Long {
                        return 0  // 代理模式不需要设置VPN
                    }
                }, Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1)
                
                Log.d(TAG, "V2RayPoint created for proxy mode")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize V2Ray environment", e)
        }
    }
    
    private fun copyAssetFiles() {
        try {
            val files = listOf("geoip.dat", "geosite.dat")
            for (fileName in files) {
                val targetFile = File(filesDir, fileName)
                if (!targetFile.exists() || targetFile.length() == 0L) {
                    try {
                        assets.open(fileName).use { input ->
                            targetFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        Log.d(TAG, "Copied $fileName (${targetFile.length()} bytes)")
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to copy $fileName: ${e.message}")
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to copy asset files", e)
        }
    }
    
    private fun startProxy(config: String, remark: String) {
        serviceScope.launch {
            try {
                if (v2rayPoint == null) {
                    Log.e(TAG, "V2RayPoint is null, reinitializing...")
                    initializeV2RayEnvironment()
                    if (v2rayPoint == null) {
                        Log.e(TAG, "Failed to initialize V2RayPoint")
                        stopSelf()
                        return@launch
                    }
                }
                
                if (isRunning) {
                    Log.d(TAG, "Proxy already running, stopping first")
                    stopV2RayCore()
                    delay(500)
                }
                
                // 启动前台服务
                startForeground(NOTIFICATION_ID, createNotification(remark))
                
                // 更新状态
                connectionState = "CONNECTING"
                sendStatusBroadcast()
                
                // 修改配置以添加统计功能
                val configWithStats = addStatsToConfig(config)
                
                // 设置配置
                v2rayPoint?.configureFileContent = configWithStats
                
                // 设置服务器域名（用于DNS解析）
                val serverInfo = extractServerInfo(config)
                if (serverInfo != null) {
                    v2rayPoint?.domainName = "${serverInfo.first}:${serverInfo.second}"
                    Log.d(TAG, "Server: ${serverInfo.first}:${serverInfo.second}")
                }
                
                // 启动V2Ray核心 - false表示代理模式
                v2rayPoint?.runLoop(false)
                
                delay(1000) // 等待启动
                
                // 检查启动状态
                if (v2rayPoint?.isRunning == true) {
                    isRunning = true
                    connectionState = "CONNECTED"
                    connectionStartTime = System.currentTimeMillis()
                    lastQueryTime = System.currentTimeMillis()
                    
                    // 重置统计
                    lastUploadBytes = 0
                    lastDownloadBytes = 0
                    seconds = 0
                    minutes = 0
                    hours = 0
                    
                    Log.d(TAG, "V2Ray proxy started successfully")
                    
                    // 启动状态监控
                    startStatusMonitoring()
                    
                } else {
                    Log.e(TAG, "V2Ray failed to start")
                    connectionState = "ERROR"
                    sendStatusBroadcast()
                    stopSelf()
                }
                
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start proxy", e)
                connectionState = "ERROR"
                sendStatusBroadcast()
                stopSelf()
            }
        }
    }
    
    private fun stopProxy() {
        try {
            Log.d(TAG, "Stopping proxy...")
            
            stopStatusMonitoring()
            stopV2RayCore()
            
            isRunning = false
            connectionState = "DISCONNECTED"
            connectionStartTime = 0
            lastUploadBytes = 0
            lastDownloadBytes = 0
            lastQueryTime = 0
            
            sendStatusBroadcast()
            
            stopForeground(true)
            
            Log.d(TAG, "Proxy stopped")
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop proxy", e)
        }
    }
    
    private fun stopV2RayCore() {
        try {
            if (v2rayPoint?.isRunning == true) {
                v2rayPoint?.stopLoop()
                Log.d(TAG, "V2Ray core stopped")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping V2Ray core", e)
        }
    }
    
    private fun addStatsToConfig(config: String): String {
        return try {
            val configJson = JSONObject(config)
            
            // 添加统计配置
            if (!configJson.has("stats")) {
                configJson.put("stats", JSONObject())
            }
            
            if (!configJson.has("policy")) {
                val policy = JSONObject()
                val levels = JSONObject()
                levels.put("8", JSONObject()
                    .put("connIdle", 300)
                    .put("downlinkOnly", 1)
                    .put("handshake", 4)
                    .put("uplinkOnly", 1))
                val system = JSONObject()
                    .put("statsOutboundUplink", true)
                    .put("statsOutboundDownlink", true)
                policy.put("levels", levels)
                policy.put("system", system)
                configJson.put("policy", policy)
            }
            
            configJson.toString()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add stats to config", e)
            config
        }
    }
    
    private fun extractServerInfo(config: String): Pair<String, String>? {
        return try {
            val configJson = JSONObject(config)
            val outbounds = configJson.getJSONArray("outbounds")
            
            if (outbounds.length() > 0) {
                val outbound = outbounds.getJSONObject(0)
                val protocol = outbound.getString("protocol")
                val settings = outbound.getJSONObject("settings")
                
                when (protocol) {
                    "vmess", "vless" -> {
                        val vnext = settings.getJSONArray("vnext").getJSONObject(0)
                        Pair(vnext.getString("address"), vnext.getString("port"))
                    }
                    "shadowsocks", "trojan", "socks" -> {
                        val servers = settings.getJSONArray("servers").getJSONObject(0)
                        Pair(servers.getString("address"), servers.getString("port"))
                    }
                    else -> null
                }
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to extract server info", e)
            null
        }
    }
    
    private fun startStatusMonitoring() {
        stopStatusMonitoring()
        
        Log.d(TAG, "Starting status monitoring")
        
        statusUpdateJob = serviceScope.launch {
            while (isActive && isRunning) {
                updateConnectionTime()
                sendStatusBroadcast()
                delay(1000)
            }
        }
    }
    
    private fun stopStatusMonitoring() {
        statusUpdateJob?.cancel()
        statusUpdateJob = null
    }
    
    private fun updateConnectionTime() {
        seconds++
        if (seconds == 60) {
            minutes++
            seconds = 0
        }
        if (minutes == 60) {
            hours++
            minutes = 0
        }
    }
    
    private fun sendStatusBroadcast() {
        try {
            val intent = Intent(BROADCAST_STATUS)
            
            if (isRunning && v2rayPoint != null) {
                val currentTime = System.currentTimeMillis()
                
                // 查询流量统计
                val totalUpload = try {
                    val proxy = v2rayPoint?.queryStats("proxy", "uplink") ?: 0L
                    val direct = v2rayPoint?.queryStats("direct", "uplink") ?: 0L
                    val block = v2rayPoint?.queryStats("block", "uplink") ?: 0L
                    proxy + direct + block
                } catch (e: Exception) { 
                    0L 
                }
                
                val totalDownload = try {
                    val proxy = v2rayPoint?.queryStats("proxy", "downlink") ?: 0L
                    val direct = v2rayPoint?.queryStats("direct", "downlink") ?: 0L
                    val block = v2rayPoint?.queryStats("block", "downlink") ?: 0L
                    proxy + direct + block
                } catch (e: Exception) { 
                    0L 
                }
                
                // 计算速度
                var uploadSpeed = 0L
                var downloadSpeed = 0L
                
                if (lastQueryTime > 0) {
                    val timeDiff = (currentTime - lastQueryTime) / 1000.0
                    if (timeDiff > 0) {
                        uploadSpeed = ((totalUpload - lastUploadBytes) / timeDiff).toLong()
                        downloadSpeed = ((totalDownload - lastDownloadBytes) / timeDiff).toLong()
                    }
                }
                
                lastUploadBytes = totalUpload
                lastDownloadBytes = totalDownload
                lastQueryTime = currentTime
                
                val duration = String.format("%02d:%02d:%02d", hours, minutes, seconds)
                
                // 发送数据（与MainActivity期望的格式匹配）
                intent.putExtra("duration", duration)
                intent.putExtra("uploadSpeed", uploadSpeed.toString())
                intent.putExtra("downloadSpeed", downloadSpeed.toString())
                intent.putExtra("uploadTotal", totalUpload.toString())
                intent.putExtra("downloadTotal", totalDownload.toString())
                intent.putExtra("state", connectionState)
                
            } else {
                intent.putExtra("duration", "00:00:00")
                intent.putExtra("uploadSpeed", "0")
                intent.putExtra("downloadSpeed", "0")
                intent.putExtra("uploadTotal", "0")
                intent.putExtra("downloadTotal", "0")
                intent.putExtra("state", connectionState)
            }
            
            sendBroadcast(intent)
            
        } catch (e: Exception) {
            Log.e(TAG, "Error sending status broadcast", e)
        }
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "V2Ray Proxy Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "V2Ray proxy service notification"
                setShowBadge(false)
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        }
    }
    
    private fun createNotification(remark: String): android.app.Notification {
        val stopIntent = Intent(this, V2rayService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )
        
        val mainIntent = packageManager.getLaunchIntentForPackage(packageName)
        val mainPendingIntent = PendingIntent.getActivity(
            this, 0, mainIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CFVPN - Proxy Mode")
            .setContentText("Connected to $remark")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setContentIntent(mainPendingIntent)
            .addAction(android.R.drawable.ic_delete, "Disconnect", stopPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
    
    override fun onDestroy() {
        Log.d(TAG, "Proxy Service onDestroy")
        stopProxy()
        serviceScope.cancel()
        super.onDestroy()
    }
}