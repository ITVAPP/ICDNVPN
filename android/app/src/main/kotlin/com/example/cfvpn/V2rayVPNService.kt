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
import go.Seq
import kotlinx.coroutines.*
import libv2ray.Libv2ray
import libv2ray.V2RayPoint
import libv2ray.V2RayVPNServiceSupportsSet
import org.json.JSONObject
import java.io.File

/**
 * VPN服务实现 - 全局代理模式
 * 与开源项目的V2rayVPNService.java功能完全一致
 */
class V2rayVPNService : VpnService() {
    companion object {
        private const val TAG = "V2rayVPNService"
        private const val NOTIFICATION_ID = 2
        private const val CHANNEL_ID = "v2ray_vpn_channel"
        
        // 服务命令
        const val ACTION_START = "com.example.cfvpn.START_VPN"
        const val ACTION_STOP = "com.example.cfvpn.STOP_VPN"
        const val ACTION_QUERY_STATUS = "com.example.cfvpn.QUERY_VPN_STATUS"
        
        // 广播Action - 与代理服务共用
        const val BROADCAST_VPN_STATUS = "V2RAY_CONNECTION_INFO"
        
        // V2RayPoint单例
        @Volatile
        private var v2rayPoint: V2RayPoint? = null
        
        @Volatile
        var isRunning = false
            private set
            
        @Volatile
        var connectionState = "DISCONNECTED"
            private set
            
        // VPN接口
        private var mInterface: ParcelFileDescriptor? = null
        
        // tun2socks进程 - 明确使用java.lang.Process
        private var tun2socksProcess: java.lang.Process? = null
        
        // 配置信息
        private var serverAddress = ""
        private var serverPort = ""
        private var localSocksPort = 10808
        
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
    private var v2rayConfig: V2rayConfig? = null
    
    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "VPN Service onCreate")
        
        // 初始化Go序列化上下文
        try {
            Seq.setContext(applicationContext)
            Log.d(TAG, "Go Seq context initialized for VPN")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize Go Seq", e)
        }
        
        // 初始化V2Ray环境
        initializeV2RayEnvironment()
        
        // 创建通知渠道
        createNotificationChannel()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: ${intent?.action}")
        
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra("config")
                val remark = intent.getStringExtra("remark") ?: "VPN Server"
                val blockedApps = intent.getStringArrayListExtra("blocked_apps")
                val bypassSubnets = intent.getStringArrayListExtra("bypass_subnets")
                
                if (config != null) {
                    startVPN(config, remark, blockedApps, bypassSubnets)
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
    
    private fun initializeV2RayEnvironment() {
        try {
            // 复制geo文件
            copyAssetFiles()
            
            // 初始化V2Ray环境
            val v2rayPath = filesDir.absolutePath
            Libv2ray.initV2Env(v2rayPath, "")
            Log.d(TAG, "V2Ray environment initialized for VPN at: $v2rayPath")
            
            // 创建V2RayPoint - VPN模式
            if (v2rayPoint == null) {
                v2rayPoint = Libv2ray.newV2RayPoint(object : V2RayVPNServiceSupportsSet {
                    override fun shutdown(): Long {
                        Log.d(TAG, "V2RayPoint shutdown callback")
                        return 0
                    }
                    
                    override fun prepare(): Long {
                        return 0 // VPN权限已在MainActivity中请求
                    }
                    
                    override fun protect(socket: Long): Boolean {
                        // 保护socket不走VPN
                        return protect(socket.toInt())
                    }
                    
                    override fun onEmitStatus(status: Long, message: String?): Long {
                        Log.d(TAG, "V2Ray status: $status - $message")
                        return 0
                    }
                    
                    override fun setup(parameters: String?): Long {
                        try {
                            // 设置VPN
                            return if (setupVPN()) 0 else -1
                        } catch (e: Exception) {
                            Log.e(TAG, "Setup VPN failed", e)
                            return -1
                        }
                    }
                }, Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1)
                
                Log.d(TAG, "V2RayPoint created for VPN mode")
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
                val protocol = inbound.getString("protocol")
                when (protocol) {
                    "socks" -> {
                        v2Config.LOCAL_SOCKS5_PORT = inbound.getInt("port")
                        localSocksPort = v2Config.LOCAL_SOCKS5_PORT
                        Log.d(TAG, "SOCKS5 port: $localSocksPort")
                    }
                }
            }
            
            // 解析outbounds
            val outbounds = configJson.getJSONArray("outbounds")
            if (outbounds.length() > 0) {
                val outbound = outbounds.getJSONObject(0)
                val protocol = outbound.getString("protocol")
                val settings = outbound.getJSONObject("settings")
                
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
                
                serverAddress = v2Config.CONNECTED_V2RAY_SERVER_ADDRESS
                serverPort = v2Config.CONNECTED_V2RAY_SERVER_PORT
                
                // 设置域名
                v2rayPoint?.domainName = "$serverAddress:$serverPort"
                Log.d(TAG, "Server: $serverAddress:$serverPort")
            }
            
            // 添加流量统计配置
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
            
            v2Config.V2RAY_FULL_JSON_CONFIG = configJson.toString()
            
            // 设置配置内容
            v2rayPoint?.configureFileContent = v2Config.V2RAY_FULL_JSON_CONFIG
            
            return v2Config
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse config", e)
            return null
        }
    }
    
    private fun setupVPN(): Boolean {
        try {
            // 关闭旧接口
            mInterface?.close()
            
            // 创建VPN Builder
            val builder = Builder()
            builder.setSession(v2rayConfig?.REMARK ?: "CFVPN")
            builder.setMtu(1500)
            
            // 设置VPN IP地址
            builder.addAddress("10.10.10.2", 30)
            
            // DNS服务器
            builder.addDnsServer("8.8.8.8")
            builder.addDnsServer("8.8.4.4")
            builder.addDnsServer("1.1.1.1")
            
            // 路由配置
            if (v2rayConfig?.BYPASS_SUBNETS.isNullOrEmpty()) {
                // 全局代理 - 添加0.0.0.0/0路由
                builder.addRoute("0.0.0.0", 0)
            } else {
                // 添加默认路由但排除指定子网
                builder.addRoute("0.0.0.0", 0)
                // 注意：Android VPN API不支持直接排除路由，需要在应用层处理
            }
            
            // 应用过滤（黑名单模式）
            v2rayConfig?.BLOCKED_APPS?.forEach { packageName ->
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to add disallowed app: $packageName")
                }
            }
            
            // Android 10+ 设置为不计费
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }
            
            // 建立VPN接口
            mInterface = builder.establish()
            
            if (mInterface != null) {
                Log.d(TAG, "VPN interface established")
                // 启动tun2socks
                runTun2socks()
                return true
            } else {
                Log.e(TAG, "Failed to establish VPN interface")
                return false
            }
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to setup VPN", e)
            return false
        }
    }
    
    private fun runTun2socks() {
        try {
            // 检查tun2socks是否存在
            val tun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so")
            if (!tun2socksPath.exists()) {
                Log.e(TAG, "tun2socks not found at: ${tun2socksPath.absolutePath}")
                // 尝试使用V2Ray内置的TUN支持
                setupV2RayTun()
                return
            }
            
            // 创建socket文件路径
            val sockPath = File(filesDir, "sock_path")
            sockPath.delete() // 删除旧的socket文件
            
            // 构建tun2socks命令
            val cmd = ArrayList<String>().apply {
                add(tun2socksPath.absolutePath)
                add("--netif-ipaddr")
                add("10.10.10.2")
                add("--netif-netmask")
                add("255.255.255.252")
                add("--socks-server-addr")
                add("127.0.0.1:$localSocksPort")
                add("--tunmtu")
                add("1500")
                add("--sock-path")
                add(sockPath.absolutePath)
                add("--enable-udprelay")
                add("--loglevel")
                add("error")
            }
            
            Log.d(TAG, "Starting tun2socks with command: ${cmd.joinToString(" ")}")
            
            val processBuilder = ProcessBuilder(cmd)
            processBuilder.redirectErrorStream(true)
            processBuilder.directory(filesDir)
            processBuilder.environment()["LD_LIBRARY_PATH"] = applicationInfo.nativeLibraryDir
            
            tun2socksProcess = processBuilder.start()
            
            // 监控进程输出
            serviceScope.launch(Dispatchers.IO) {
                try {
                    tun2socksProcess?.inputStream?.bufferedReader()?.use { reader ->
                        reader.forEachLine { line ->
                            Log.d(TAG, "tun2socks: $line")
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error reading tun2socks output", e)
                }
            }
            
            // 发送文件描述符
            sendFileDescriptor(sockPath)
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks", e)
            // 尝试使用V2Ray内置的TUN支持
            setupV2RayTun()
        }
    }
    
    private fun setupV2RayTun() {
        // 如果tun2socks不可用，尝试使用V2Ray的内置TUN支持
        Log.w(TAG, "Falling back to V2Ray internal TUN support")
        // V2Ray v5+ 支持内置TUN
        // 这里需要修改V2Ray配置以启用TUN入站
    }
    
    private fun sendFileDescriptor(sockPath: File) {
        val tunFd = mInterface?.fileDescriptor ?: return
        
        serviceScope.launch {
            var retries = 0
            val maxRetries = 10
            
            while (retries < maxRetries && isRunning) {
                try {
                    delay(100L * (retries + 1)) // 递增延迟
                    
                    if (!sockPath.exists()) {
                        Log.d(TAG, "Socket file not yet created, waiting...")
                        retries++
                        continue
                    }
                    
                    val clientSocket = LocalSocket()
                    clientSocket.connect(LocalSocketAddress(
                        sockPath.absolutePath,
                        LocalSocketAddress.Namespace.FILESYSTEM
                    ))
                    
                    if (clientSocket.isConnected) {
                        Log.d(TAG, "Connected to tun2socks socket")
                        
                        val outputStream = clientSocket.outputStream
                        clientSocket.setFileDescriptorsForSend(arrayOf(tunFd))
                        outputStream.write(32) // Magic number
                        outputStream.flush()
                        clientSocket.close()
                        
                        Log.d(TAG, "File descriptor sent successfully")
                        break
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send FD, attempt ${retries + 1}/$maxRetries", e)
                    retries++
                }
            }
            
            if (retries >= maxRetries) {
                Log.e(TAG, "Failed to send file descriptor after $maxRetries attempts")
                // 可能需要停止服务
            }
        }
    }
    
    private fun startVPN(
        config: String,
        remark: String,
        blockedApps: ArrayList<String>?,
        bypassSubnets: ArrayList<String>?
    ) {
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
                    Log.d(TAG, "VPN already running, stopping first")
                    stopV2RayCore()
                    delay(500)
                }
                
                // 启动前台服务
                startForeground(NOTIFICATION_ID, createNotification(remark))
                
                // 更新状态
                connectionState = "CONNECTING"
                sendStatusBroadcast()
                
                // 解析配置
                v2rayConfig = parseV2rayConfig(config, remark, blockedApps, bypassSubnets)
                if (v2rayConfig == null) {
                    Log.e(TAG, "Failed to parse config")
                    connectionState = "ERROR"
                    sendStatusBroadcast()
                    stopSelf()
                    return@launch
                }
                
                // 启动V2Ray核心
                v2rayPoint?.runLoop(true) // true = VPN模式
                
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
                    
                    Log.d(TAG, "V2Ray VPN started successfully")
                    
                    // 启动状态监控
                    startStatusMonitoring()
                    
                } else {
                    Log.e(TAG, "V2Ray failed to start")
                    connectionState = "ERROR"
                    sendStatusBroadcast()
                    stopSelf()
                }
                
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start VPN", e)
                connectionState = "ERROR"
                sendStatusBroadcast()
                stopSelf()
            }
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
            connectionStartTime = 0
            lastUploadBytes = 0
            lastDownloadBytes = 0
            lastQueryTime = 0
            
            sendStatusBroadcast()
            
            stopForeground(true)
            
            Log.d(TAG, "VPN stopped")
            
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop VPN", e)
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
    
    private fun startStatusMonitoring() {
        stopStatusMonitoring()
        
        Log.d(TAG, "Starting VPN status monitoring")
        
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
            val intent = Intent(BROADCAST_VPN_STATUS)
            
            if (isRunning && v2rayPoint != null) {
                val currentTime = System.currentTimeMillis()
                
                // 查询流量统计
                val blockUplink = try {
                    v2rayPoint?.queryStats("block", "uplink") ?: 0L
                } catch (e: Exception) { 0L }
                
                val blockDownlink = try {
                    v2rayPoint?.queryStats("block", "downlink") ?: 0L
                } catch (e: Exception) { 0L }
                
                val proxyUplink = try {
                    v2rayPoint?.queryStats("proxy", "uplink") ?: 0L
                } catch (e: Exception) { 0L }
                
                val proxyDownlink = try {
                    v2rayPoint?.queryStats("proxy", "downlink") ?: 0L
                } catch (e: Exception) { 0L }
                
                val totalUpload = blockUplink + proxyUplink
                val totalDownload = blockDownlink + proxyDownlink
                
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
                
                intent.putExtra("DURATION", duration)
                intent.putExtra("UPLOAD_SPEED", uploadSpeed)
                intent.putExtra("DOWNLOAD_SPEED", downloadSpeed)
                intent.putExtra("UPLOAD_TRAFFIC", totalUpload)
                intent.putExtra("DOWNLOAD_TRAFFIC", totalDownload)
                intent.putExtra("STATE", AppConfigs.V2RAY_STATES.V2RAY_CONNECTED)
                
            } else {
                intent.putExtra("DURATION", "00:00:00")
                intent.putExtra("UPLOAD_SPEED", 0L)
                intent.putExtra("DOWNLOAD_SPEED", 0L)
                intent.putExtra("UPLOAD_TRAFFIC", 0L)
                intent.putExtra("DOWNLOAD_TRAFFIC", 0L)
                intent.putExtra("STATE", AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED)
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
            .setContentTitle("CFVPN - VPN Mode")
            .setContentText("Connected to $remark")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .setContentIntent(mainPendingIntent)
            .addAction(android.R.drawable.ic_delete, "Disconnect", stopPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
    
    // 数据类
    data class V2rayConfig(
        var CONNECTED_V2RAY_SERVER_ADDRESS: String = "",
        var CONNECTED_V2RAY_SERVER_PORT: String = "",
        var LOCAL_SOCKS5_PORT: Int = 10808,
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