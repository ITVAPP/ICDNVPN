package com.example.cfvpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import org.json.JSONObject
import org.json.JSONArray
import java.io.File

// ===== 关键：添加缺失的imports =====
import go.Seq
import libv2ray.Libv2ray
import libv2ray.V2RayPoint
import libv2ray.V2RayVPNServiceSupportsSet

/**
 * VPN服务实现 - 全局代理模式
 */
class V2rayVPNService : VpnService() {
    companion object {
        private const val TAG = "V2rayVPNService"
        private const val NOTIFICATION_ID = 2
        private const val CHANNEL_ID = "v2ray_vpn_channel"
        
        const val ACTION_START = "com.example.cfvpn.START_VPN"
        const val ACTION_STOP = "com.example.cfvpn.STOP_VPN"
        const val ACTION_QUERY_STATUS = "com.example.cfvpn.QUERY_VPN_STATUS"
        
        const val BROADCAST_VPN_STATUS = "V2RAY_CONNECTION_INFO"
        
        @Volatile
        var isRunning = false
            private set
            
        @Volatile
        var connectionState = "DISCONNECTED"
            private set
            
        // V2RayPoint单例
        @Volatile
        private var v2rayPoint: V2RayPoint? = null
        
        // 统计数据
        private var lastUploadBytes = 0L
        private var lastDownloadBytes = 0L
        private var seconds = 0
        private var minutes = 0
        private var hours = 0
    }
    
    private var mInterface: ParcelFileDescriptor? = null
    private var tun2socksProcess: Process? = null
    private var v2rayConfig: V2rayConfig? = null
    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private var statusUpdateJob: Job? = null
    
    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "VPN Service onCreate")
        
        // 初始化V2Ray环境
        initializeV2Ray()
        
        // 创建通知渠道
        createNotificationChannel()
    }
    
    private fun initializeV2Ray() {
        try {
            // 设置Go序列化上下文
            Seq.setContext(applicationContext)
            Log.d(TAG, "Go Seq context set")
            
            // 复制geo文件
            copyAssetFiles()
            
            // 初始化V2Ray环境
            val v2rayPath = filesDir.absolutePath
            Libv2ray.initV2Env(v2rayPath, "")
            Log.d(TAG, "V2Ray environment initialized at: $v2rayPath")
            
            // 创建V2RayPoint - 只创建一次
            if (v2rayPoint == null) {
                v2rayPoint = Libv2ray.newV2RayPoint(object : V2RayVPNServiceSupportsSet {
                    override fun shutdown(): Long {
                        Log.d(TAG, "V2RayPoint shutdown")
                        return 0
                    }
                    
                    override fun prepare(): Long {
                        return 0  // VPN权限已在MainActivity请求
                    }
                    
                    override fun protect(socket: Long): Boolean {
                        return protect(socket.toInt())
                    }
                    
                    override fun onEmitStatus(status: Long, message: String?): Long {
                        Log.d(TAG, "V2Ray status: $status - $message")
                        return 0
                    }
                    
                    override fun setup(parameters: String?): Long {
                        // 注意：使用runLoop(false)时，这个回调不会被调用
                        return 0
                    }
                }, Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1)
                
                Log.d(TAG, "V2RayPoint created successfully")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize V2Ray", e)
            e.printStackTrace()
        }
    }
    
    private fun copyAssetFiles() {
        val files = listOf("geoip.dat", "geosite.dat")
        for (fileName in files) {
            val targetFile = File(filesDir, fileName)
            if (!targetFile.exists()) {
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
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: ${intent?.action}")
        
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra("config")
                val remark = intent.getStringExtra("remark") ?: "VPN Server"
                val blockedApps = intent.getStringArrayListExtra("blocked_apps")
                val bypassSubnets = intent.getStringArrayListExtra("bypass_subnets")
                
                Log.d(TAG, "Starting VPN with remark: $remark")
                
                if (config != null) {
                    serviceScope.launch {
                        try {
                            startVPN(config, remark, blockedApps, bypassSubnets)
                        } catch (e: Exception) {
                            Log.e(TAG, "Error in startVPN coroutine", e)
                        }
                    }
                } else {
                    Log.e(TAG, "Config is null")
                    stopSelf()
                }
            }
            ACTION_STOP -> {
                stopVPN()
                stopSelf()
            }
            ACTION_QUERY_STATUS -> {
                sendStatusBroadcast()
            }
        }
        
        return START_STICKY
    }
    
    private suspend fun startVPN(
        config: String,
        remark: String,
        blockedApps: ArrayList<String>?,
        bypassSubnets: ArrayList<String>?
    ) {
        try {
            Log.d(TAG, "startVPN: Begin")
            
            // 停止现有连接
            if (isRunning) {
                Log.d(TAG, "Stopping existing connection")
                stopV2RayCore()
                delay(500)
            }
            
            // 启动前台服务
            Log.d(TAG, "Starting foreground service")
            startForeground(NOTIFICATION_ID, createNotification(remark))
            
            // 更新状态
            connectionState = "CONNECTING"
            sendStatusBroadcast()
            
            // 解析配置
            Log.d(TAG, "Parsing V2Ray config")
            v2rayConfig = parseV2rayConfig(config, remark, blockedApps, bypassSubnets)
            if (v2rayConfig == null) {
                throw Exception("Failed to parse config")
            }
            
            // 关键步骤1：先建立VPN接口
            Log.d(TAG, "Setting up VPN interface...")
            if (!setupVPN()) {
                throw Exception("Failed to setup VPN interface")
            }
            
            // 等待tun2socks初始化
            delay(500)
            
            // 关键步骤2：启动V2Ray核心
            Log.d(TAG, "Starting V2Ray core...")
            if (!startV2RayCore()) {
                throw Exception("Failed to start V2Ray core")
            }
            
            // 等待V2Ray启动
            delay(1000)
            
            // 验证状态
            if (v2rayPoint?.isRunning == true) {
                isRunning = true
                connectionState = "CONNECTED"
                Log.d(TAG, "VPN started successfully")
                
                // 启动状态监控
                startStatusMonitoring()
                
                // 发送连接成功广播
                sendStatusBroadcast()
            } else {
                throw Exception("V2Ray is not running after start")
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VPN: ${e.message}", e)
            e.printStackTrace()
            connectionState = "ERROR"
            sendStatusBroadcast()
            stopVPN()
            stopSelf()
        }
    }
    
    private fun parseV2rayConfig(
        config: String,
        remark: String,
        blockedApps: ArrayList<String>?,
        bypassSubnets: ArrayList<String>?
    ): V2rayConfig? {
        try {
            val configJson = JSONObject(config)
            val v2Config = V2rayConfig()
            
            v2Config.REMARK = remark
            v2Config.BLOCKED_APPS = blockedApps
            v2Config.BYPASS_SUBNETS = bypassSubnets
            
            // 解析inbounds
            val inbounds = configJson.getJSONArray("inbounds")
            for (i in 0 until inbounds.length()) {
                val inbound = inbounds.getJSONObject(i)
                when (inbound.getString("protocol")) {
                    "socks" -> {
                        v2Config.LOCAL_SOCKS5_PORT = inbound.getInt("port")
                        Log.d(TAG, "SOCKS5 port: ${v2Config.LOCAL_SOCKS5_PORT}")
                    }
                    "http" -> {
                        v2Config.LOCAL_HTTP_PORT = inbound.getInt("port")
                        Log.d(TAG, "HTTP port: ${v2Config.LOCAL_HTTP_PORT}")
                    }
                }
            }
            
            // 解析outbounds - 支持所有协议
            val outbounds = configJson.getJSONArray("outbounds")
            if (outbounds.length() > 0) {
                val firstOutbound = outbounds.getJSONObject(0)
                val protocol = firstOutbound.getString("protocol")
                val settings = firstOutbound.getJSONObject("settings")
                
                Log.d(TAG, "Outbound protocol: $protocol")
                
                when (protocol) {
                    "vmess", "vless" -> {
                        val vnext = settings.getJSONArray("vnext").getJSONObject(0)
                        v2Config.CONNECTED_V2RAY_SERVER_ADDRESS = vnext.getString("address")
                        v2Config.CONNECTED_V2RAY_SERVER_PORT = vnext.getString("port")
                    }
                    "shadowsocks", "trojan", "socks" -> {
                        val servers = settings.getJSONArray("servers").getJSONObject(0)
                        v2Config.CONNECTED_V2RAY_SERVER_ADDRESS = servers.getString("address")
                        v2Config.CONNECTED_V2RAY_SERVER_PORT = servers.getString("port")
                    }
                }
                
                Log.d(TAG, "Server: ${v2Config.CONNECTED_V2RAY_SERVER_ADDRESS}:${v2Config.CONNECTED_V2RAY_SERVER_PORT}")
            }
            
            // 添加流量统计配置
            if (!configJson.has("stats")) {
                configJson.put("stats", JSONObject())
            }
            if (!configJson.has("policy")) {
                val policy = JSONObject()
                val system = JSONObject()
                    .put("statsOutboundUplink", true)
                    .put("statsOutboundDownlink", true)
                policy.put("system", system)
                configJson.put("policy", policy)
            }
            
            v2Config.V2RAY_FULL_JSON_CONFIG = configJson.toString()
            return v2Config
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse config", e)
            e.printStackTrace()
            return null
        }
    }
    
    private fun setupVPN(): Boolean {
        try {
            Log.d(TAG, "setupVPN: Starting")
            
            // 关闭旧接口
            mInterface?.close()
            
            val builder = Builder()
            builder.setSession(v2rayConfig?.REMARK ?: "CFVPN")
            builder.setMtu(1500)
            builder.addAddress("10.10.10.2", 30)
            
            // DNS
            builder.addDnsServer("8.8.8.8")
            builder.addDnsServer("8.8.4.4")
            builder.addDnsServer("1.1.1.1")
            
            // 路由 - 全局代理
            builder.addRoute("0.0.0.0", 0)
            
            // 应用过滤
            v2rayConfig?.BLOCKED_APPS?.forEach { pkg ->
                try {
                    builder.addDisallowedApplication(pkg)
                    Log.d(TAG, "Excluded app: $pkg")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to exclude app: $pkg")
                }
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            
            // 建立VPN接口
            Log.d(TAG, "Establishing VPN interface...")
            mInterface = builder.establish()
            
            if (mInterface != null) {
                Log.d(TAG, "VPN interface established successfully")
                
                // 启动tun2socks
                val tun2socksStarted = runTun2socks()
                if (!tun2socksStarted) {
                    Log.w(TAG, "tun2socks not available, continuing anyway")
                }
                
                return true
            } else {
                Log.e(TAG, "Failed to establish VPN interface - builder.establish() returned null")
                return false
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to setup VPN", e)
            e.printStackTrace()
            return false
        }
    }
    
    private fun runTun2socks(): Boolean {
        val tun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so")
        
        Log.d(TAG, "Looking for tun2socks at: ${tun2socksPath.absolutePath}")
        
        if (!tun2socksPath.exists()) {
            Log.e(TAG, "tun2socks not found! This may cause connection issues.")
            // 继续运行，因为某些V2Ray版本可能有内置TUN支持
            return false
        }
        
        try {
            val sockPath = File(filesDir, "sock_path")
            sockPath.delete()
            
            val socksPort = v2rayConfig?.LOCAL_SOCKS5_PORT ?: 10808
            
            val cmd = arrayListOf(
                tun2socksPath.absolutePath,
                "--netif-ipaddr", "10.10.10.2",
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:$socksPort",
                "--tunmtu", "1500",
                "--sock-path", sockPath.absolutePath,
                "--enable-udprelay",
                "--loglevel", "warning"
            )
            
            Log.d(TAG, "Starting tun2socks with SOCKS5 port: $socksPort")
            
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(true)
            pb.directory(filesDir)
            tun2socksProcess = pb.start()
            
            Log.d(TAG, "tun2socks process started")
            
            // 发送文件描述符
            sendFileDescriptor(sockPath)
            
            // 监控进程
            serviceScope.launch {
                try {
                    val exitCode = tun2socksProcess?.waitFor()
                    Log.w(TAG, "tun2socks exited with code: $exitCode")
                    if (isRunning) {
                        delay(1000)
                        runTun2socks()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "tun2socks monitor error", e)
                }
            }
            
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
            e.printStackTrace()
            return false
        }
    }
    
    private fun sendFileDescriptor(sockPath: File) {
        val tunFd = mInterface?.fileDescriptor ?: run {
            Log.e(TAG, "No file descriptor available")
            return
        }
        
        serviceScope.launch {
            repeat(10) { attempt ->
                try {
                    delay(100L * (attempt + 1))
                    
                    if (!sockPath.exists()) {
                        Log.d(TAG, "Waiting for socket file... (attempt ${attempt + 1})")
                        return@repeat
                    }
                    
                    val socket = LocalSocket()
                    socket.connect(LocalSocketAddress(
                        sockPath.absolutePath,
                        LocalSocketAddress.Namespace.FILESYSTEM
                    ))
                    
                    if (socket.isConnected) {
                        socket.setFileDescriptorsForSend(arrayOf(tunFd))
                        socket.outputStream.write(32)
                        socket.close()
                        Log.d(TAG, "File descriptor sent successfully")
                        return@launch
                    }
                } catch (e: Exception) {
                    if (attempt == 9) {
                        Log.e(TAG, "Failed to send FD after 10 attempts", e)
                    }
                }
            }
        }
    }
    
    private fun startV2RayCore(): Boolean {
        try {
            Log.d(TAG, "startV2RayCore: Begin")
            
            if (v2rayPoint == null) {
                Log.e(TAG, "V2RayPoint is null, trying to reinitialize")
                initializeV2Ray()
                if (v2rayPoint == null) {
                    Log.e(TAG, "Failed to initialize V2RayPoint")
                    return false
                }
            }
            
            // 设置配置
            v2rayPoint?.configureFileContent = v2rayConfig?.V2RAY_FULL_JSON_CONFIG
            Log.d(TAG, "V2Ray config set")
            
            // 设置域名
            val serverAddress = v2rayConfig?.CONNECTED_V2RAY_SERVER_ADDRESS ?: ""
            val serverPort = v2rayConfig?.CONNECTED_V2RAY_SERVER_PORT ?: ""
            v2rayPoint?.domainName = "$serverAddress:$serverPort"
            Log.d(TAG, "V2Ray domain set: $serverAddress:$serverPort")
            
            // 启动V2Ray - false表示不需要V2Ray管理VPN
            Log.d(TAG, "Starting V2Ray runLoop...")
            v2rayPoint?.runLoop(false)
            
            Log.d(TAG, "V2Ray core started successfully")
            return true
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start V2Ray core", e)
            e.printStackTrace()
            return false
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
    
    private fun stopVPN() {
        try {
            Log.d(TAG, "Stopping VPN...")
            
            stopStatusMonitoring()
            
            // 停止tun2socks
            tun2socksProcess?.destroyForcibly()
            tun2socksProcess = null
            
            // 停止V2Ray
            stopV2RayCore()
            
            // 关闭VPN接口
            mInterface?.close()
            mInterface = null
            
            isRunning = false
            connectionState = "DISCONNECTED"
            
            sendStatusBroadcast()
            stopForeground(true)
            
            Log.d(TAG, "VPN stopped")
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop VPN", e)
        }
    }
    
    private fun startStatusMonitoring() {
        stopStatusMonitoring()
        
        Log.d(TAG, "Starting status monitoring")
        
        statusUpdateJob = serviceScope.launch {
            while (isActive && isRunning) {
                updateStats()
                sendStatusBroadcast()
                delay(1000)
            }
        }
    }
    
    private fun stopStatusMonitoring() {
        statusUpdateJob?.cancel()
        statusUpdateJob = null
    }
    
    private fun updateStats() {
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
            val intent = Intent(BROADCAST_VPN_STATUS)
            
            if (isRunning && v2rayPoint != null) {
                // 查询流量统计
                val uploadTotal = try {
                    (v2rayPoint?.queryStats("proxy", "uplink") ?: 0) +
                    (v2rayPoint?.queryStats("direct", "uplink") ?: 0) +
                    (v2rayPoint?.queryStats("block", "uplink") ?: 0)
                } catch (e: Exception) { 0L }
                
                val downloadTotal = try {
                    (v2rayPoint?.queryStats("proxy", "downlink") ?: 0) +
                    (v2rayPoint?.queryStats("direct", "downlink") ?: 0) +
                    (v2rayPoint?.queryStats("block", "downlink") ?: 0)
                } catch (e: Exception) { 0L }
                
                // 计算速度
                val uploadSpeed = uploadTotal - lastUploadBytes
                val downloadSpeed = downloadTotal - lastDownloadBytes
                
                lastUploadBytes = uploadTotal
                lastDownloadBytes = downloadTotal
                
                val duration = String.format("%02d:%02d:%02d", hours, minutes, seconds)
                
                // 与MainActivity期望的格式匹配
                intent.putExtra("DURATION", duration)
                intent.putExtra("UPLOAD_SPEED", uploadSpeed)
                intent.putExtra("DOWNLOAD_SPEED", downloadSpeed)
                intent.putExtra("UPLOAD_TRAFFIC", uploadTotal)
                intent.putExtra("DOWNLOAD_TRAFFIC", downloadTotal)
                intent.putExtra("STATE", V2RAY_STATES.V2RAY_CONNECTED)
            } else {
                intent.putExtra("DURATION", "00:00:00")
                intent.putExtra("UPLOAD_SPEED", 0L)
                intent.putExtra("DOWNLOAD_SPEED", 0L)
                intent.putExtra("UPLOAD_TRAFFIC", 0L)
                intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
                intent.putExtra("STATE", when(connectionState) {
                    "CONNECTING" -> V2RAY_STATES.V2RAY_CONNECTING
                    "CONNECTED" -> V2RAY_STATES.V2RAY_CONNECTED
                    else -> V2RAY_STATES.V2RAY_DISCONNECTED
                })
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
                "V2Ray VPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "V2Ray VPN service notification"
                setShowBadge(false)
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)
        }
    }
    
    private fun createNotification(remark: String): android.app.Notification {
        val stopIntent = Intent(this, V2rayVPNService::class.java).apply {
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
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CFVPN - VPN Mode")
            .setContentText("Connected to $remark")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_delete, "Disconnect", stopPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
    
    // 数据类
    data class V2rayConfig(
        var CONNECTED_V2RAY_SERVER_ADDRESS: String = "",
        var CONNECTED_V2RAY_SERVER_PORT: String = "",
        var LOCAL_SOCKS5_PORT: Int = 10808,
        var LOCAL_HTTP_PORT: Int = 10809,
        var BLOCKED_APPS: ArrayList<String>? = null,
        var BYPASS_SUBNETS: ArrayList<String>? = null,
        var V2RAY_FULL_JSON_CONFIG: String? = null,
        var REMARK: String = ""
    )
    
    // 状态枚举
    object AppConfigs {
        enum class V2RAY_STATES {
            V2RAY_CONNECTED,
            V2RAY_DISCONNECTED,
            V2RAY_CONNECTING
        }
    }
    
    // 使用内部的枚举别名，方便使用
    typealias V2RAY_STATES = AppConfigs.V2RAY_STATES
    
    override fun onRevoke() {
        Log.d(TAG, "VPN permission revoked")
        stopVPN()
        stopSelf()
    }
    
    override fun onDestroy() {
        Log.d(TAG, "VPN Service onDestroy")
        stopVPN()
        serviceScope.cancel()
        super.onDestroy()
    }
}