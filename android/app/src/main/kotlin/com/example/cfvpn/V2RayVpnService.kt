package com.example.cfvpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.system.Os
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONException
import java.io.File
import java.io.FileDescriptor
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.lang.ref.WeakReference
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Socket
import java.net.InetAddress
import java.net.Inet4Address

// 正确的导入(基于method_summary.md)
import go.Seq
import libv2ray.Libv2ray
import libv2ray.CoreController
import libv2ray.CoreCallbackHandler

/**
 * V2Ray VPN服务实现
 */
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    enum class V2RayState {
        DISCONNECTED,
        CONNECTING,
        CONNECTED
    }
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"  // VPN停止广播
        private const val ACTION_UPDATE_NOTIFICATION = "com.example.cfvpn.UPDATE_NOTIFICATION"  // 通知栏更新广播
        private const val WAKELOCK_TAG = "cfvpn:v2ray"
        private const val ENABLE_IPV6 = false
        
        // VPN配置常量
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val DEFAULT_SOCKS_PORT = 7898
        private const val LOCAL_DNS_PORT = 10853
        private const val DNS_TAG_IN = "dns-in"
        private const val DNS_TAG_OUT = "dns-out"
        private const val STATS_UPDATE_INTERVAL = 5000L
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L
        private const val TUN2SOCKS = "libtun2socks.so"
        private const val CONNECTION_CHECK_INTERVAL = 30000L
        
        // 跨进程通过 SharedPreferences 同步状态
        @Volatile
        private var currentState: V2RayState = V2RayState.DISCONNECTED
        
        @Volatile
        private var instanceRef: WeakReference<V2RayVpnService>? = null
        
        // 本地化字符串仅用于静态方法内部传递
        private var localizedStrings = mutableMapOf<String, String>()
        
        private val instance: V2RayVpnService?
            get() = instanceRef?.get()
        
        // 【删除】移除静态流量统计变量，改用 SharedPreferences
        // 以下变量已移至实例变量
        
        @JvmStatic
        fun isServiceRunning(): Boolean {
            // 这个方法从主进程调用时无法获取正确状态
            // 主进程应该使用 SharedPreferences 或 ActivityManager 检查
            return currentState == V2RayState.CONNECTED
        }

        @JvmStatic
        fun updateNotificationStrings(newStrings: Map<String, String>): Boolean {
            return try {
                VpnFileLogger.d(TAG, "开始更新通知栏本地化文字")
                
                // 跨进程调用时 instance 为 null，改用 SharedPreferences + 广播
                val service = instance
                if (service != null) {
                    // 同进程内直接更新
                    service.instanceLocalizedStrings.clear()
                    service.instanceLocalizedStrings.putAll(newStrings)
                    
                    if (currentState == V2RayState.CONNECTED) {
                        val notification = service.buildNotification(isConnecting = false)
                        if (notification != null) {
                            val notificationManager = service.getSystemService(NotificationManager::class.java)
                            notificationManager.notify(NOTIFICATION_ID, notification)
                            VpnFileLogger.d(TAG, "通知栏更新成功")
                            true
                        } else {
                            VpnFileLogger.w(TAG, "构建通知失败")
                            false
                        }
                    } else {
                        true
                    }
                } else {
                    // 跨进程场景：返回 false，让调用方使用其他方式
                    VpnFileLogger.w(TAG, "服务实例不存在（跨进程调用）")
                    false
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "更新通知栏文字异常", e)
                false
            }
        }
        
        /**
         * 启动VPN服务
         */
        @JvmStatic
        fun startVpnService(
            context: Context, 
            config: String,
            globalProxy: Boolean = false,
            blockedApps: List<String>? = null,  // 保留接口兼容性
            allowedApps: List<String>? = null,
            appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE,  // 保留接口兼容性
            bypassSubnets: List<String>? = null,
            enableAutoStats: Boolean = true,
            disconnectButtonName: String = "停止",
            localizedStrings: Map<String, String> = emptyMap(),
            enableVirtualDns: Boolean = false,
            virtualDnsPort: Int = 10853
        ) {
            VpnFileLogger.d(TAG, "准备启动服务, 全局代理: $globalProxy, 虚拟DNS: $enableVirtualDns")
            
            this.localizedStrings.clear()
            this.localizedStrings.putAll(localizedStrings)
            
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN"
                putExtra("config", config)
                putExtra("globalProxy", globalProxy)
                putExtra("enableAutoStats", enableAutoStats)
                putExtra("enableVirtualDns", enableVirtualDns)
                putExtra("virtualDnsPort", virtualDnsPort)
                putStringArrayListExtra("allowedApps", ArrayList(allowedApps ?: emptyList()))
                putStringArrayListExtra("bypassSubnets", ArrayList(bypassSubnets ?: emptyList()))
                
                localizedStrings.forEach { (key, value) ->
                    putExtra("l10n_$key", value)
                }
            }
            
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动服务失败", e)
            }
        }
        
        // 保留枚举以保持接口兼容性
        enum class AppProxyMode {
            EXCLUDE,
            INCLUDE
        }
        
        @JvmStatic
        fun stopVpnService(context: Context) {
            VpnFileLogger.d(TAG, "准备停止VPN服务")
            try {
                context.sendBroadcast(Intent(ACTION_STOP_VPN))
                context.stopService(Intent(context, V2RayVpnService::class.java))
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "停止服务失败", e)
            }
        }
        
        @JvmStatic
        fun getTrafficStats(): Map<String, Long> {
            // 【修改】跨进程调用时无法获取数据，返回空Map
            // 主进程应该从 SharedPreferences 读取
            return emptyMap()
        }
    }
    
    // 核心组件
    private var coreController: CoreController? = null
    private var mInterface: ParcelFileDescriptor? = null
    private var process: Process? = null
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var wakeLock: PowerManager.WakeLock? = null
    
    // tun2socks重启控制
    private var tun2socksRestartCount = 0
    private var tun2socksFirstRestartTime = 0L
    
    // 修复：添加重启状态标记防止死循环
    @Volatile
    private var isRestartingTun2socks = false
    
    // 配置信息
    private var configJson: String = ""
    private var configCache: JSONObject? = null  // 配置缓存
    private var globalProxy: Boolean = false
    private var allowedApps: List<String> = emptyList()
    private var bypassSubnets: List<String> = emptyList()
    private var enableAutoStats: Boolean = true
    private var socksPort: Int = DEFAULT_SOCKS_PORT
    private var localDnsPort: Int = -1
    private var enableVirtualDns: Boolean = false
    private var configuredVirtualDnsPort: Int = 10853
    
    private val instanceLocalizedStrings = mutableMapOf<String, String>()
    
    // 修复：添加异常处理器
    private val exceptionHandler = CoroutineExceptionHandler { _, exception ->
        VpnFileLogger.e(TAG, "协程异常", exception)
    }
    
    // 修复：使用SupervisorJob防止级联取消
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob() + exceptionHandler)
    
    // 流量统计实例变量（跨进程通过SharedPreferences同步）
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var uploadSpeed: Long = 0
    private var downloadSpeed: Long = 0
    private var startTime: Long = 0
    private var totalUploadBytes: Long = 0
    private var totalDownloadBytes: Long = 0
    
    // 流量统计 - 保留这个用于内部计算
    private var lastStatsTime: Long = 0
    private val outboundTags = mutableListOf<String>()
    
    // 任务管理
    private var statsJob: Job? = null
    private var connectionCheckJob: Job? = null
    private var tun2socksMonitorThread: Thread? = null
    
    @Volatile
    private var v2rayCoreStarted = false
    
    @Volatile
    private var startupLatch: CompletableDeferred<Boolean>? = null
    
    // 修复：添加广播接收器注册状态
    @Volatile
    private var stopReceiverRegistered = false
    
    // 通知栏更新广播接收器状态
    @Volatile
    private var notificationReceiverRegistered = false
    
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                VpnFileLogger.d(TAG, "收到停止VPN广播")
                stopV2Ray()
            }
        }
    }
    
    // 通知栏更新接收器
    private val notificationUpdateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_UPDATE_NOTIFICATION) {
                VpnFileLogger.d(TAG, "收到更新通知栏广播")
                updateNotificationFromPrefs()
            }
        }
    }
    
    /**
     * 从 SharedPreferences 更新通知栏
     */
    private fun updateNotificationFromPrefs() {
        try {
            val prefs = getSharedPreferences("notification_strings", Context.MODE_PRIVATE)
            
            // 【简化】直接读取，不检查时间戳
            instanceLocalizedStrings.clear()
            
            // 读取所有本地化字符串
            val keys = listOf(
                "appName", "notificationChannelName", "notificationChannelDesc",
                "globalProxyMode", "smartProxyMode", "disconnectButtonName", 
                "trafficStatsFormat"
            )
            
            keys.forEach { key ->
                prefs.getString(key, null)?.let {
                    instanceLocalizedStrings[key] = it
                }
            }
            
            // 更新通知栏
            if (currentState == V2RayState.CONNECTED) {
                val notification = buildNotification(isConnecting = false)
                if (notification != null) {
                    val notificationManager = getSystemService(NotificationManager::class.java)
                    notificationManager.notify(NOTIFICATION_ID, notification)
                    VpnFileLogger.d(TAG, "通知栏已从SharedPreferences更新")
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "从SharedPreferences更新通知栏失败", e)
        }
    }
    
    /**
     * 更新服务状态到 SharedPreferences
     */
    private fun updateServiceState(newState: V2RayState) {
        currentState = newState
        
        try {
            val prefs = getSharedPreferences("vpn_service_state", Context.MODE_PRIVATE)
            prefs.edit().apply {
                putBoolean("isConnected", newState == V2RayState.CONNECTED)
                putString("state", newState.name)
                apply()
            }
            VpnFileLogger.d(TAG, "服务状态已更新到SharedPreferences: $newState")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "保存服务状态失败", e)
        }
    }
    
    /**
     * 解析V2Ray配置JSON - 带缓存
     */
    private fun parseConfig(): JSONObject? {
        if (configCache != null) {
            return configCache
        }
        
        return try {
            val config = JSONObject(configJson)
            // 已删除validateGeoRules调用
            configCache = config
            config
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "解析V2Ray配置失败", e)
            null
        }
    }
    
    /**
     * 从配置中提取端口
     */
    private fun extractInboundPort(tag: String, defaultPort: Int = -1): Int {
        return try {
            parseConfig()?.let { config ->
                val inbounds = config.getJSONArray("inbounds")
                for (i in 0 until inbounds.length()) {
                    val inbound = inbounds.getJSONObject(i)
                    if (inbound.optString("tag") == tag) {
                        return inbound.optInt("port", defaultPort)
                    }
                }
                defaultPort
            } ?: defaultPort
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "提取端口失败: $tag", e)
            defaultPort
        }
    }
    
    /**
     * 测试TCP连接
     */
    private fun testTcpConnection(
        host: String, 
        port: Int, 
        timeout: Int = 2000,
        serviceName: String = "服务"
    ): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), timeout)
                VpnFileLogger.i(TAG, "✔ $serviceName 端口 $port 连接正常")
                true
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗ $serviceName 端口 $port 无法连接: ${e.message}")
            false
        }
    }
    
    /**
     * 构建通知
     */
    private fun buildNotification(isConnecting: Boolean = false): android.app.Notification? {
        return try {
            val channelName = instanceLocalizedStrings["notificationChannelName"] ?: "VPN服务"
            val channelDesc = instanceLocalizedStrings["notificationChannelDesc"] ?: "VPN连接状态通知"
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    channelName,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = channelDesc
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
            
            val mainIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val mainPendingIntent = PendingIntent.getActivity(
                this, 0, mainIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )
            
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
            val title = if (isConnecting) {
                "$appName - ......"
            } else {
                val modeText = if (globalProxy) {
                    instanceLocalizedStrings["globalProxyMode"] ?: "全局代理模式"
                } else {
                    instanceLocalizedStrings["smartProxyMode"] ?: "智能代理模式"
                }
                "$appName - $modeText"
            }
            
            val content = if (isConnecting) {
                "......"
            } else {
                formatTrafficStatsForNotification(uploadBytes, downloadBytes)
            }
            
            val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(mainPendingIntent)
            
            if (!isConnecting) {
                builder.addAction(
                    android.R.drawable.ic_menu_close_clear_cancel, 
                    instanceLocalizedStrings["disconnectButtonName"] ?: "断开",
                    stopPendingIntent
                )
            }
            
            builder.build()
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "构建通知失败", e)
            try {
                NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                    .setContentTitle(instanceLocalizedStrings["appName"] ?: "CFVPN")
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .build()
            } catch (e2: Exception) {
                null
            }
        }
    }
    
    /**
     * 获取V2Ray资源路径
     */
    private fun getV2RayAssetsPath(): String {
        val extDir = getExternalFilesDir("assets")
        if (extDir != null) {
            if (!extDir.exists()) {
                extDir.mkdirs()
            }
            VpnFileLogger.d(TAG, "使用外部存储assets目录: ${extDir.absolutePath}")
            return extDir.absolutePath
        }
        
        val intDir = getDir("assets", Context.MODE_PRIVATE)
        if (!intDir.exists()) {
            intDir.mkdirs()
        }
        VpnFileLogger.d(TAG, "使用内部存储assets目录: ${intDir.absolutePath}")
        return intDir.absolutePath
    }
    
    override fun onCreate() {
        super.onCreate()
        
        VpnFileLogger.init(applicationContext)
        VpnFileLogger.d(TAG, "VPN服务onCreate开始")
        
        instanceRef = WeakReference(this)
        
        try {
            Seq.setContext(applicationContext)
            VpnFileLogger.d(TAG, "Go运行时初始化成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "Go运行时初始化失败", e)
            stopSelf()
            return
        }
        
        // 修复：安全注册广播接收器
        registerStopReceiver()
        registerNotificationReceiver()
        
        copyAssetFiles()
        
        try {
            val envPath = getV2RayAssetsPath()
            
            Libv2ray.initCoreEnv(envPath, envPath)
            VpnFileLogger.d(TAG, "V2Ray环境初始化成功")
            
            val version = Libv2ray.checkVersionX()
            VpnFileLogger.i(TAG, "V2Ray版本: $version")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "V2Ray环境初始化失败", e)
        }
        
        acquireWakeLock()
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成")
    }
    
    /**
     * 修复：安全注册停止广播接收器
     */
    private fun registerStopReceiver() {
        if (!stopReceiverRegistered) {
            try {
                registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
                stopReceiverRegistered = true
                VpnFileLogger.d(TAG, "停止广播接收器注册成功")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "注册停止广播接收器失败", e)
            }
        }
    }
    
    /**
     * 注册通知栏更新广播接收器
     */
    private fun registerNotificationReceiver() {
        if (!notificationReceiverRegistered) {
            try {
                registerReceiver(notificationUpdateReceiver, IntentFilter(ACTION_UPDATE_NOTIFICATION))
                notificationReceiverRegistered = true
                VpnFileLogger.d(TAG, "通知栏更新广播接收器注册成功")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "注册通知栏更新广播接收器失败", e)
            }
        }
    }
    
    /**
     * 修复：安全注销停止广播接收器
     */
    private fun unregisterStopReceiver() {
        if (stopReceiverRegistered) {
            try {
                unregisterReceiver(stopReceiver)
                stopReceiverRegistered = false
                VpnFileLogger.d(TAG, "停止广播接收器注销成功")
            } catch (e: Exception) {
                // 忽略异常
            }
        }
    }
    
    /**
     * 注销通知栏更新广播接收器
     */
    private fun unregisterNotificationReceiver() {
        if (notificationReceiverRegistered) {
            try {
                unregisterReceiver(notificationUpdateReceiver)
                notificationReceiverRegistered = false
                VpnFileLogger.d(TAG, "通知栏更新广播接收器注销成功")
            } catch (e: Exception) {
                // 忽略异常
            }
        }
    }
    
    /**
     * 提取outbound标签
     */
    private fun extractOutboundTags() {
        outboundTags.clear()
        
        try {
            parseConfig()?.let { config ->
                val outbounds = config.optJSONArray("outbounds")
                if (outbounds != null) {
                    for (i in 0 until outbounds.length()) {
                        val outbound = outbounds.getJSONObject(i)
                        val tag = outbound.optString("tag")
                        val protocol = outbound.optString("protocol")
                        
                        if (tag.isNotEmpty() && protocol !in listOf("freedom", "blackhole", "dns")) {
                            val settings = outbound.optJSONObject("settings")
                            val hasFragment = settings?.has("fragment") == true
                            
                            if (!hasFragment) {
                                if (protocol in listOf("vless", "vmess", "trojan", "shadowsocks", "socks", "http")) {
                                    outboundTags.add(tag)
                                    VpnFileLogger.d(TAG, "添加代理流量统计标签: $tag (protocol=$protocol)")
                                }
                            }
                        }
                    }
                }
                
                if (outboundTags.isEmpty()) {
                    outboundTags.add("proxy")
                    VpnFileLogger.w(TAG, "未找到代理outbound标签，使用默认标签: proxy")
                }
                
                VpnFileLogger.i(TAG, "流量统计标签: $outboundTags")
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "提取outbound标签失败", e)
            outboundTags.add("proxy")
        }
    }
    
    private fun acquireWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                WAKELOCK_TAG
            ).apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L)
            }
            VpnFileLogger.d(TAG, "WakeLock已获取")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "获取WakeLock失败", e)
        }
    }
    
    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.release()
                    VpnFileLogger.d(TAG, "WakeLock已释放")
                }
            }
            wakeLock = null
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "释放WakeLock失败", e)
        }
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnFileLogger.d(TAG, "onStartCommand: action=${intent?.action}")
        
        if (intent == null || intent.action != "START_VPN") {
            VpnFileLogger.e(TAG, "无效的启动意图")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 【修复】从SharedPreferences检查是否已在运行，避免跨进程时检查失效
        val prefs = getSharedPreferences("vpn_service_state", Context.MODE_PRIVATE)
        val savedState = prefs.getString("state", "DISCONNECTED")
        if (savedState != "DISCONNECTED") {
            VpnFileLogger.w(TAG, "VPN服务已在运行或正在连接: $savedState")
            // 不发送失败广播，避免误导调用方
            return START_STICKY
        }
        
        updateServiceState(V2RayState.CONNECTING)  // 使用新方法更新状态
        v2rayCoreStarted = false
        configCache = null  // 清除配置缓存
        isRestartingTun2socks = false  // 重置重启标记
        
        // 获取配置
        enableVirtualDns = intent.getBooleanExtra("enableVirtualDns", false)
        configuredVirtualDnsPort = intent.getIntExtra("virtualDnsPort", 10853)
        configJson = intent.getStringExtra("config") ?: ""
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        enableAutoStats = intent.getBooleanExtra("enableAutoStats", true)
        allowedApps = intent.getStringArrayListExtra("allowedApps") ?: emptyList()
        bypassSubnets = intent.getStringArrayListExtra("bypassSubnets") ?: emptyList()
        
        VpnFileLogger.d(TAG, "配置参数: 全局代理=$globalProxy, 虚拟DNS=$enableVirtualDns")
        
        // 解析配置
        parseConfig()?.let { config ->
            extractOutboundTags()
            
            if (enableVirtualDns) {
                localDnsPort = extractInboundPort(DNS_TAG_IN, configuredVirtualDnsPort)
            }
        }
        
        // 提取国际化文字
        instanceLocalizedStrings.clear()
        instanceLocalizedStrings["appName"] = intent.getStringExtra("l10n_appName") ?: "CFVPN"
        instanceLocalizedStrings["notificationChannelName"] = intent.getStringExtra("l10n_notificationChannelName") ?: "VPN服务"
        instanceLocalizedStrings["notificationChannelDesc"] = intent.getStringExtra("l10n_notificationChannelDesc") ?: "VPN连接状态通知"
        instanceLocalizedStrings["globalProxyMode"] = intent.getStringExtra("l10n_globalProxyMode") ?: "全局代理模式"
        instanceLocalizedStrings["smartProxyMode"] = intent.getStringExtra("l10n_smartProxyMode") ?: "智能代理模式"
        instanceLocalizedStrings["disconnectButtonName"] = intent.getStringExtra("l10n_disconnectButtonName") ?: "断开"
        instanceLocalizedStrings["trafficStatsFormat"] = intent.getStringExtra("l10n_trafficStatsFormat") ?: "流量: ↑%upload ↓%download"
        
        if (configJson.isEmpty()) {
            VpnFileLogger.e(TAG, "配置为空")
            updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
            sendStartResultBroadcast(false, "配置为空")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 显示"正在连接"通知
        try {
            val connectingNotification = buildNotification(isConnecting = true)
            if (connectingNotification != null) {
                startForeground(NOTIFICATION_ID, connectingNotification)
                VpnFileLogger.d(TAG, "前台服务已启动")
            } else {
                VpnFileLogger.e(TAG, "无法创建通知")
                updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
                sendStartResultBroadcast(false, "无法创建通知")
                stopSelf()
                return START_NOT_STICKY
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动前台服务失败", e)
            updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
            sendStartResultBroadcast(false, "启动前台服务失败: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 检查VPN权限
        val prepare = prepare(this)
        if (prepare != null) {
            VpnFileLogger.e(TAG, "VPN未授权")
            updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
            sendStartResultBroadcast(false, "需要VPN授权")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 启动VPN
        serviceScope.launch {
            try {
                startV2RayWithVPN()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动失败", e)
                updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
                sendStartResultBroadcast(false, "启动失败: ${e.message}")
                withContext(Dispatchers.Main) {
                    stopSelf()
                }
            }
        }
        
        return START_STICKY
    }
    
    private fun copyAssetFiles() {
        VpnFileLogger.d(TAG, "开始复制资源文件")
        
        val assetDir = File(getV2RayAssetsPath())
        if (!assetDir.exists()) {
            assetDir.mkdirs()
        }
        
        val files = listOf("geoip.dat", "geosite.dat")
        
        for (fileName in files) {
            try {
                val targetFile = File(assetDir, fileName)
                
                if (shouldUpdateFile(fileName, targetFile)) {
                    copyAssetFile(fileName, targetFile)
                    VpnFileLogger.d(TAG, "文件复制成功: $fileName (${targetFile.length()} bytes)")
                } else {
                    VpnFileLogger.d(TAG, "文件已是最新: $fileName")
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "处理文件失败: $fileName", e)
            }
        }
    }
    
    private fun shouldUpdateFile(assetName: String, targetFile: File): Boolean {
        if (!targetFile.exists()) {
            return true
        }
        
        return try {
            val assetSize = assets.open(assetName).use { it.available() }
            targetFile.length() != assetSize.toLong()
        } catch (e: Exception) {
            true
        }
    }
    
    private fun copyAssetFile(assetName: String, targetFile: File) {
        try {
            assets.open(assetName).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "复制文件失败: $assetName", e)
        }
    }
    
    private fun quickCheckJsonSyntax(configJson: String): Boolean {
        return try {
            JSONObject(configJson)
            true
        } catch (e: JSONException) {
            VpnFileLogger.e(TAG, "JSON语法错误: ${e.message}")
            false
        }
    }
    
    /**
     * 启动V2Ray(VPN模式)
     * 修改：添加同步的连接测试，测试成功后才返回成功
     */
    private suspend fun startV2RayWithVPN() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "startV2RayWithVPN开始")
        
        try {
            // 快速JSON语法检查
            if (!quickCheckJsonSyntax(configJson)) {
                throw Exception("配置文件JSON格式错误")
            }
            
            startupLatch = CompletableDeferred<Boolean>()
            
            // 创建核心控制器
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败")
            }
            VpnFileLogger.d(TAG, "CoreController创建成功")
            
            // 启动V2Ray核心
            VpnFileLogger.d(TAG, "启动V2Ray核心")
            try {
                coreController?.startLoop(configJson)
            } catch (e: Exception) {
                val errorMsg = e.message ?: ""
                val detailedError = when {
                    errorMsg.contains("json", ignoreCase = true) -> "配置文件JSON格式错误: $errorMsg"
                    errorMsg.contains("dns", ignoreCase = true) -> "DNS配置错误: $errorMsg"
                    errorMsg.contains("outbound", ignoreCase = true) -> "出站配置错误: $errorMsg"
                    errorMsg.contains("inbound", ignoreCase = true) -> "入站配置错误: $errorMsg"
                    errorMsg.contains("routing", ignoreCase = true) -> "路由配置错误: $errorMsg"
                    errorMsg.contains("port", ignoreCase = true) || 
                    errorMsg.contains("address already in use", ignoreCase = true) -> "端口被占用: $errorMsg"
                    else -> "V2Ray启动失败: $errorMsg"
                }
                throw Exception(detailedError)
            }
            
            // 等待startup()回调
            val startupSuccess = withTimeoutOrNull(5000L) {
                startupLatch?.await()
            }
            
            if (startupSuccess != true) {
                throw Exception("V2Ray核心启动超时或失败")
            }
            
            // 验证V2Ray启动状态
            val isRunning = coreController?.isRunning ?: false
            if (!isRunning) {
                throw Exception("V2Ray核心未运行")
            }
            
            VpnFileLogger.i(TAG, "V2Ray核心启动成功")
            
            // 建立VPN隧道
            withContext(Dispatchers.Main) {
                establishVpn()
            }
            
            if (mInterface == null) {
                throw Exception("VPN隧道建立失败")
            }
            
            VpnFileLogger.d(TAG, "VPN隧道建立成功")
            
            // 配置网络回调
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                configureNetworkCallback()
            }
            
            // 启动tun2socks
            runTun2socks()
            
            // 【关键修改】等待并验证连接是否真正可用
            VpnFileLogger.d(TAG, "开始验证远程服务器连接...")
            val connectionTestSuccess = verifyRemoteConnection()
            
            if (!connectionTestSuccess) {
                throw Exception("Unable to connect to remote server")
            }
            
            VpnFileLogger.i(TAG, "远程服务器连接验证成功")
            
            // 连接测试成功后才更新状态
            updateServiceState(V2RayState.CONNECTED)  // 使用新方法更新状态
            startTime = System.currentTimeMillis()
            
            updateNotificationToConnected()
            
            VpnFileLogger.i(TAG, "V2Ray服务完全启动成功")
            
            // 现在才发送成功广播
            sendStartResultBroadcast(true)
            
            // 保存自启动配置
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        configJson,
                        "VPN_TUN",
                        globalProxy,
                        enableVirtualDns,
                        configuredVirtualDnsPort
                    )
                    VpnFileLogger.d(TAG, "已更新自启动配置")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存自启动配置失败", e)
            }
            
            // 启动流量监控
            if (enableAutoStats) {
                startSimpleTrafficMonitor()
            }
            
            // 启动连接检查
            startConnectionCheck()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray失败: ${e.message}")
            
            // 修复：确保资源清理
            try {
                cleanupResources()
            } catch (cleanupError: Exception) {
                VpnFileLogger.e(TAG, "清理资源失败", cleanupError)
            }
            
            sendStartResultBroadcast(false, e.message)
            throw e
        } finally {
            startupLatch = null
        }
    }
    
    /**
     * 简化的远程连接验证
     * 只测试必要的项目：通过SOCKS代理访问远程服务器
     */
    private suspend fun verifyRemoteConnection(): Boolean = withContext(Dispatchers.IO) {
        try {
            // 等待服务稳定
            delay(500)
            
            // 测试通过SOCKS代理访问远程服务器
            val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", socksPort))
            val testUrl = URL("http://www.google.com/generate_204")
            
            val connection = testUrl.openConnection(proxy) as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.instanceFollowRedirects = false
            
            val responseCode = connection.responseCode
            connection.disconnect()
            
            val success = (responseCode == 204 || responseCode == 200)
            
            if (success) {
                VpnFileLogger.i(TAG, "✅ 远程服务器连接测试成功，响应码: $responseCode")
            } else {
                VpnFileLogger.e(TAG, "❌ 远程服务器连接测试失败，响应码: $responseCode")
            }
            
            return@withContext success
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "❌ 远程服务器连接测试异常: ${e.message}")
            return@withContext false
        }
    }
    
    private fun updateNotificationToConnected() {
        try {
            val connectedNotification = buildNotification(isConnecting = false)
            if (connectedNotification != null) {
                val notificationManager = getSystemService(NotificationManager::class.java)
                notificationManager.notify(NOTIFICATION_ID, connectedNotification)
                VpnFileLogger.d(TAG, "通知已更新为已连接状态")
            }
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "更新通知失败", e)
        }
    }
    
    @android.annotation.TargetApi(Build.VERSION_CODES.P)
    private fun configureNetworkCallback() {
        try {
            val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                .build()
            
            defaultNetworkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    super.onAvailable(network)
                    VpnFileLogger.d(TAG, "网络可用: $network")
                    try {
                        setUnderlyingNetworks(arrayOf(network))
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "设置底层网络失败", e)
                    }
                }
                
                override fun onCapabilitiesChanged(
                    network: Network,
                    networkCapabilities: NetworkCapabilities
                ) {
                    super.onCapabilitiesChanged(network, networkCapabilities)
                    try {
                        setUnderlyingNetworks(arrayOf(network))
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "更新底层网络失败", e)
                    }
                }
                
                override fun onLost(network: Network) {
                    super.onLost(network)
                    VpnFileLogger.d(TAG, "网络丢失: $network")
                    try {
                        setUnderlyingNetworks(null)
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "清除底层网络失败", e)
                    }
                }
            }
            
            connectivityManager.requestNetwork(request, defaultNetworkCallback!!)
            VpnFileLogger.d(TAG, "网络回调已注册")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "配置网络回调失败", e)
        }
    }
    
    private fun startConnectionCheck() {
        connectionCheckJob?.cancel()
        
        connectionCheckJob = serviceScope.launch {
            while (currentState == V2RayState.CONNECTED && isActive) {
                delay(CONNECTION_CHECK_INTERVAL)
                
                try {
                    val isRunning = coreController?.isRunning ?: false
                    if (!isRunning) {
                        VpnFileLogger.e(TAG, "V2Ray核心意外停止")
                        stopV2Ray()
                        break
                    }
                    
                    val processAlive = process?.isAlive ?: false
                    if (!processAlive && !isRestartingTun2socks) {
                        VpnFileLogger.w(TAG, "tun2socks进程不存在，尝试重启")
                        
                        if (shouldRestartTun2socks()) {
                            delay(2000)
                            
                            if (currentState == V2RayState.CONNECTED && (process?.isAlive != true)) {
                                restartTun2socks()
                            }
                        } else {
                            VpnFileLogger.e(TAG, "tun2socks重启失败次数过多")
                            stopV2Ray()
                            break
                        }
                    }
                    
                    renewWakeLock()
                    
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "连接检查异常", e)
                }
            }
        }
    }
    
    private fun renewWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.acquire(10 * 60 * 1000L)
                } else {
                    acquireWakeLock()
                }
            } ?: acquireWakeLock()
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "更新WakeLock失败", e)
        }
    }
    
    private fun sendStartResultBroadcast(success: Boolean, error: String? = null) {
        try {
            val intent = Intent(ACTION_VPN_START_RESULT).apply {
                putExtra("success", success)
                
                val userFriendlyError = when {
                    error == null -> null
                    error.contains("json", ignoreCase = true) -> "配置文件格式错误"
                    error.contains("port", ignoreCase = true) || 
                    error.contains("address already in use", ignoreCase = true) -> "端口被占用"
                    error.contains("dns", ignoreCase = true) -> "DNS配置错误"
                    error.contains("outbound", ignoreCase = true) -> "出站配置错误"
                    error.contains("inbound", ignoreCase = true) -> "入站配置错误"
                    error.contains("routing", ignoreCase = true) -> "路由配置错误"
                    error.contains("timeout", ignoreCase = true) -> "启动超时"
                    error.contains("permission", ignoreCase = true) -> "权限不足"
                    error.contains("Unable to connect to remote server") -> "Unable to connect to remote server"
                    else -> error
                }
                
                putExtra("error", userFriendlyError)
                putExtra("error_detail", error)
            }
            sendBroadcast(intent)
            VpnFileLogger.d(TAG, "已发送VPN启动结果广播: success=$success")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "发送启动结果广播失败", e)
        }
    }
    
    /**
     * 修复：改进资源清理顺序
     */
    private fun cleanupResources() {
        updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
        
        // 先取消所有协程任务
        connectionCheckJob?.cancel()
        connectionCheckJob = null
        
        statsJob?.cancel()
        statsJob = null
        
        startupLatch = null
        
        // 注销网络回调
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                defaultNetworkCallback?.let {
                    val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    connectivityManager.unregisterNetworkCallback(it)
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "注销网络回调失败", e)
            }
            defaultNetworkCallback = null
        }
        
        // 停止tun2socks
        stopTun2socks()
        
        // 停止V2Ray核心
        try {
            coreController?.stopLoop()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "停止核心异常", e)
        }
        coreController = null
        
        // 关闭VPN接口
        try {
            mInterface?.close()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "关闭VPN接口异常", e)
        }
        mInterface = null
        
        // 释放WakeLock
        releaseWakeLock()
    }
    
    /**
     * 建立VPN隧道
     */
    private fun establishVpn() {
        VpnFileLogger.d(TAG, "开始建立VPN隧道")
        
        mInterface?.let {
            try {
                it.close()
                VpnFileLogger.d(TAG, "已关闭旧VPN接口")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "关闭旧接口失败", e)
            }
        }
        mInterface = null
        
        val builder = Builder()
        
        val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
        builder.setSession(appName)
        builder.setMtu(VPN_MTU)
        
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        VpnFileLogger.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30")
        
        builder.addRoute("0.0.0.0", 0)
        VpnFileLogger.d(TAG, "添加IPv4全局路由")
        
        // 简化：ENABLE_IPV6为false时不添加IPv6路由
        if (ENABLE_IPV6 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addRoute("::", 0)
                VpnFileLogger.d(TAG, "添加IPv6全局路由")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加IPv6路由失败: ${e.message}")
            }
        }
        
        // 分应用代理
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addDisallowedApplication(packageName)
                VpnFileLogger.d(TAG, "排除自身应用: $packageName")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "排除自身应用失败", e)
            }
            
            if (allowedApps.isNotEmpty()) {
                val filteredApps = allowedApps
                    .map { it.trim() }
                    .filter { app -> app.isNotEmpty() && app != packageName }
                    .distinct()
                
                if (filteredApps.isNotEmpty()) {
                    VpnFileLogger.d(TAG, "使用包含模式，${filteredApps.size}个应用走VPN")
                    filteredApps.forEach { app ->
                        try {
                            builder.addAllowedApplication(app)
                        } catch (e: Exception) {
                            VpnFileLogger.w(TAG, "添加允许应用失败: $app", e)
                        }
                    }
                }
            }
        }
        
        mInterface = builder.establish()
        
        if (mInterface == null) {
            VpnFileLogger.e(TAG, "VPN接口建立失败")
        } else {
            VpnFileLogger.d(TAG, "VPN隧道建立成功")
        }
    }
    
    /**
     * 启动tun2socks进程
     */
    private fun runTun2socks() {
        VpnFileLogger.d(TAG, "启动tun2socks进程")
        
        socksPort = extractInboundPort("socks", DEFAULT_SOCKS_PORT)
        
        val cmd = arrayListOf(
            File(applicationContext.applicationInfo.nativeLibraryDir, TUN2SOCKS).absolutePath,
            "--netif-ipaddr", PRIVATE_VLAN4_ROUTER,
            "--netif-netmask", "255.255.255.252",
            "--socks-server-addr", "127.0.0.1:$socksPort",
            "--tunmtu", VPN_MTU.toString(),
            "--sock-path", "sock_path",
            "--enable-udprelay",
            "--loglevel", "error"
        )
        
        if (enableVirtualDns && localDnsPort > 0) {
            cmd.add("--dnsgw")
            cmd.add("127.0.0.1:$localDnsPort")
            VpnFileLogger.i(TAG, "启用虚拟DNS网关: 127.0.0.1:$localDnsPort")
        } else {
            cmd.add("--dnsgw")
            cmd.add("127.0.0.1:$socksPort")
        }
        
        VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
        
        try {
            val proBuilder = ProcessBuilder(cmd)
            proBuilder.redirectErrorStream(true)
            process = proBuilder
                .directory(applicationContext.filesDir)
                .start()
            
            tun2socksMonitorThread = Thread {
                try {
                    val exitCode = process?.waitFor()
                    VpnFileLogger.d(TAG, "tun2socks进程退出，退出码: $exitCode")
                    
                    if (currentState == V2RayState.CONNECTED && !isRestartingTun2socks) {
                        VpnFileLogger.e(TAG, "tun2socks意外退出")
                        
                        serviceScope.launch {
                            if (shouldRestartTun2socks()) {
                                VpnFileLogger.w(TAG, "尝试重启tun2socks")
                                delay(1000)
                                if (currentState == V2RayState.CONNECTED && (process?.isAlive != true)) {
                                    restartTun2socks()
                                }
                            } else {
                                VpnFileLogger.e(TAG, "tun2socks重启次数达到上限")
                                stopV2Ray()
                            }
                        }
                    }
                } catch (e: InterruptedException) {
                    VpnFileLogger.d(TAG, "tun2socks监控线程被中断")
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "tun2socks监控异常", e)
                }
            }.apply {
                name = "tun2socks-monitor"
                isDaemon = true
                start()
            }
            
            serviceScope.launch {
                delay(1000)
                if (process?.isAlive != true) {
                    VpnFileLogger.e(TAG, "tun2socks进程启动后立即退出")
                } else {
                    VpnFileLogger.i(TAG, "tun2socks进程运行正常")
                }
            }
            
            Thread.sleep(500)
            sendFd()
            
            VpnFileLogger.d(TAG, "tun2socks进程启动完成")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动tun2socks失败", e)
            throw e
        }
    }
    
    private fun sendFd() {
        val path = File(applicationContext.filesDir, "sock_path").absolutePath
        val localSocket = LocalSocket()
        
        try {
            var tries = 0
            val maxTries = 6
            
            while (tries < maxTries) {
                try {
                    Thread.sleep(50L * tries)
                    
                    VpnFileLogger.d(TAG, "尝试连接Unix域套接字 (第${tries + 1}次)")
                    
                    localSocket.connect(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
                    
                    if (!localSocket.isConnected) {
                        throw Exception("LocalSocket连接失败")
                    }
                    
                    localSocket.setFileDescriptorsForSend(arrayOf(mInterface!!.fileDescriptor))
                    localSocket.outputStream.write(42)
                    localSocket.outputStream.flush()
                    
                    VpnFileLogger.d(TAG, "文件描述符发送成功")
                    
                    break
                    
                } catch (e: Exception) {
                    tries++
                    if (tries >= maxTries) {
                        VpnFileLogger.e(TAG, "发送文件描述符失败", e)
                        throw e
                    } else {
                        VpnFileLogger.w(TAG, "发送文件描述符失败，将重试: ${e.message}")
                    }
                }
            }
        } finally {
            try {
                localSocket.close()
            } catch (e: Exception) {
                // 忽略关闭异常
            }
        }
    }
    
    private fun shouldRestartTun2socks(): Boolean {
        val now = System.currentTimeMillis()
        
        if (tun2socksRestartCount == 0) {
            tun2socksFirstRestartTime = now
        }
        
        if (now - tun2socksFirstRestartTime > TUN2SOCKS_RESTART_RESET_INTERVAL) {
            tun2socksRestartCount = 0
            tun2socksFirstRestartTime = now
            VpnFileLogger.d(TAG, "tun2socks重启计数已重置")
        }
        
        return tun2socksRestartCount < MAX_TUN2SOCKS_RESTART_COUNT
    }
    
    /**
     * 修复：防止重启死循环
     */
    private fun restartTun2socks() {
        if (isRestartingTun2socks) {
            VpnFileLogger.w(TAG, "tun2socks正在重启中，跳过重复重启")
            return
        }
        
        try {
            isRestartingTun2socks = true
            tun2socksRestartCount++
            VpnFileLogger.d(TAG, "重启tun2socks，第${tun2socksRestartCount}次尝试")
            
            stopTun2socks()
            Thread.sleep(1000)
            
            // 检查服务状态
            if (currentState != V2RayState.CONNECTED) {
                VpnFileLogger.w(TAG, "服务已断开，取消tun2socks重启")
                return
            }
            
            if (mInterface == null || mInterface?.fileDescriptor == null) {
                VpnFileLogger.e(TAG, "VPN接口无效，无法重启tun2socks")
                // 不调用stopV2Ray()避免死循环
                return
            }
            
            runTun2socks()
            
            VpnFileLogger.i(TAG, "tun2socks重启成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "重启tun2socks失败", e)
            // 不调用stopV2Ray()避免死循环
        } finally {
            isRestartingTun2socks = false
        }
    }
    
    private fun stopTun2socks() {
        VpnFileLogger.d(TAG, "停止tun2socks进程")
        
        tun2socksRestartCount = 0
        tun2socksFirstRestartTime = 0L
        
        try {
            tun2socksMonitorThread?.interrupt()
            tun2socksMonitorThread = null
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "中断监控线程失败", e)
        }
        
        try {
            process?.let {
                it.destroy()
                if (!it.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) {
                    it.destroyForcibly()
                }
                process = null
                VpnFileLogger.d(TAG, "tun2socks进程已停止")
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止tun2socks进程失败", e)
        }
    }
    
    private fun startSimpleTrafficMonitor() {
        VpnFileLogger.d(TAG, "启动流量统计监控")
        
        statsJob?.cancel()
        
        // 初始化流量统计
        totalUploadBytes = 0
        totalDownloadBytes = 0
        
        statsJob = serviceScope.launch {
            updateTrafficStats()
            
            while (currentState == V2RayState.CONNECTED && isActive) {
                delay(STATS_UPDATE_INTERVAL)
                
                try {
                    updateTrafficStats()
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "更新流量统计异常", e)
                }
            }
        }
    }
    
    private fun updateTrafficStats() {
        try {
            var newUpload = 0L
            var newDownload = 0L
            
            for (tag in outboundTags) {
                val uplink = coreController?.queryStats(tag, "uplink") ?: 0L
                val downlink = coreController?.queryStats(tag, "downlink") ?: 0L
                
                if (uplink >= 0 && downlink >= 0) {
                    newUpload += uplink
                    newDownload += downlink
                }
            }
            
            totalUploadBytes += newUpload
            totalDownloadBytes += newDownload
            
            // 计算速度
            val currentTime = System.currentTimeMillis()
            val timeDiff = (currentTime - lastStatsTime) / 1000.0
            
            if (timeDiff > 0 && lastStatsTime > 0) {
                uploadSpeed = (newUpload / timeDiff).toLong()
                downloadSpeed = (newDownload / timeDiff).toLong()
            }
            
            lastStatsTime = currentTime
            
            // 更新实例变量
            uploadBytes = totalUploadBytes
            downloadBytes = totalDownloadBytes
            
            // 【简化】保存到 SharedPreferences 供主进程读取，不保存时间戳
            try {
                val prefs = getSharedPreferences("vpn_traffic_stats", Context.MODE_PRIVATE)
                prefs.edit().apply {
                    putLong("uploadTotal", totalUploadBytes)
                    putLong("downloadTotal", totalDownloadBytes)
                    putLong("uploadSpeed", uploadSpeed)
                    putLong("downloadSpeed", downloadSpeed)
                    putLong("startTime", startTime)
                    apply()
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存流量统计到SharedPreferences失败", e)
            }
            
            if (enableAutoStats) {
                updateNotification()
            }
            
            if (newUpload > 0 || newDownload > 0) {
                VpnFileLogger.d(TAG, "流量更新: ↑${formatBytes(totalUploadBytes)} ↓${formatBytes(totalDownloadBytes)}")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "查询流量统计失败", e)
        }
    }
    
    /**
     * 修复：防止重复调用stopV2Ray
     */
    private fun stopV2Ray() {
        if (currentState == V2RayState.DISCONNECTED) {
            VpnFileLogger.d(TAG, "服务已停止，跳过重复停止")
            return
        }
        
        VpnFileLogger.d(TAG, "开始停止V2Ray服务")
        
        updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
        isRestartingTun2socks = false
        
        statsJob?.cancel()
        statsJob = null
        
        connectionCheckJob?.cancel()
        connectionCheckJob = null
        
        startupLatch = null
        
        sendBroadcast(Intent(ACTION_VPN_STOPPED))
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                defaultNetworkCallback?.let {
                    val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    connectivityManager.unregisterNetworkCallback(it)
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "注销网络回调失败", e)
            }
            defaultNetworkCallback = null
        }
        
        stopTun2socks()
        
        try {
            coreController?.stopLoop()
            VpnFileLogger.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
        }
        
        stopForeground(true)
        stopSelf()
        
        try {
            mInterface?.close()
            mInterface = null
            VpnFileLogger.d(TAG, "VPN接口已关闭")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
        }
        
        releaseWakeLock()
        
        // 【三重清理机制】清理所有 SharedPreferences 数据
        try {
            // 清理流量统计
            getSharedPreferences("vpn_traffic_stats", Context.MODE_PRIVATE)
                .edit().clear().apply()
            
            // 清理服务状态
            getSharedPreferences("vpn_service_state", Context.MODE_PRIVATE)
                .edit().clear().apply()
            
            VpnFileLogger.d(TAG, "SharedPreferences数据已清理")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "清理SharedPreferences失败", e)
        }
        
        // 重置所有流量统计变量
        uploadBytes = 0
        downloadBytes = 0
        uploadSpeed = 0
        downloadSpeed = 0
        startTime = 0
        totalUploadBytes = 0
        totalDownloadBytes = 0
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止")
    }
    
    private fun getAppIconResource(): Int {
        return try {
            packageManager.getApplicationInfo(packageName, 0).icon
        } catch (e: Exception) {
            android.R.drawable.ic_dialog_info
        }
    }
    
    private fun formatTrafficStatsForNotification(upload: Long, download: Long): String {
        val template = instanceLocalizedStrings["trafficStatsFormat"] ?: "流量: ↑%upload ↓%download"
        return template
            .replace("%upload", formatBytes(upload))
            .replace("%download", formatBytes(download))
    }
    
    private fun updateNotification() {
        try {
            val notification = buildNotification(isConnecting = false)
            if (notification != null) {
                val notificationManager = getSystemService(NotificationManager::class.java)
                notificationManager.notify(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "更新通知失败", e)
        }
    }
    
    // CoreCallbackHandler 接口实现
    
    override fun startup(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.startup()被调用")
        
        try {
            val isRunning = coreController?.isRunning ?: false
            VpnFileLogger.d(TAG, "V2Ray核心运行状态: $isRunning")
            
            v2rayCoreStarted = true
            
            try {
                startupLatch?.let { latch ->
                    if (!latch.isCompleted) {
                        latch.complete(true)
                        VpnFileLogger.d(TAG, "startupLatch已完成")
                    }
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "完成startupLatch时出现异常", e)
            }
            
            verifyV2RayPortsListening()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "查询V2Ray状态失败", e)
            try {
                startupLatch?.let { latch ->
                    if (!latch.isCompleted) {
                        latch.complete(false)
                    }
                }
            } catch (ignored: Exception) {
            }
        }
        
        return 0L
    }
    
    private fun verifyV2RayPortsListening() {
        serviceScope.launch {
            delay(500)
            
            try {
                VpnFileLogger.d(TAG, "验证V2Ray端口监听状态")
                
                val socksPort = extractInboundPort("socks", DEFAULT_SOCKS_PORT)
                testTcpConnection("127.0.0.1", socksPort, 2000, "SOCKS5")
                
                val httpPort = extractInboundPort("http", -1)
                if (httpPort > 0) {
                    testTcpConnection("127.0.0.1", httpPort, 2000, "HTTP")
                }
                
                if (enableVirtualDns && localDnsPort > 0) {
                    testTcpConnection("127.0.0.1", localDnsPort, 2000, "虚拟DNS")
                }
                
                VpnFileLogger.i(TAG, "V2Ray端口验证完成")
                
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "V2Ray端口验证异常", e)
            }
        }
    }
    
    override fun shutdown(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.shutdown()被调用")
        
        serviceScope.launch {
            try {
                stopV2Ray()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "shutdown停止服务异常", e)
            }
        }
        
        return 0L
    }
    
    override fun onEmitStatus(level: Long, status: String?): Long {
        try {
            val levelName = when (level.toInt()) {
                0 -> "DEBUG"
                1 -> "INFO"
                2 -> "WARNING"
                3 -> "ERROR"
                4 -> "FATAL"
                else -> "LEVEL$level"
            }
            
            VpnFileLogger.d(TAG, "[V2Ray-$levelName] $status")
            
            if (status != null) {
                when {
                    status.contains("config", ignoreCase = true) && 
                    (status.contains("failed", ignoreCase = true) || 
                     status.contains("error", ignoreCase = true)) -> {
                        VpnFileLogger.e(TAG, "[V2Ray配置错误] $status")
                    }
                    
                    status.contains("failed", ignoreCase = true) || 
                    status.contains("error", ignoreCase = true) -> {
                        VpnFileLogger.e(TAG, "[V2Ray错误] $status")
                        
                        if (status.contains("address already in use", ignoreCase = true)) {
                            VpnFileLogger.e(TAG, "端口被占用")
                        }
                    }
                    
                    status.contains("warning", ignoreCase = true) -> {
                        VpnFileLogger.w(TAG, "[V2Ray警告] $status")
                    }
                    
                    status.contains("started", ignoreCase = true) ||
                    status.contains("listening", ignoreCase = true) -> {
                        VpnFileLogger.i(TAG, "[V2Ray信息] $status")
                    }
                }
            }
            
            return 0L
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "处理V2Ray状态回调异常", e)
            return -1L
        }
    }
    
    // 工具方法
    
    private fun formatBytes(bytes: Long): String {
        return when {
            bytes < 0 -> "0 B"
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> String.format("%.2f KB", bytes / 1024.0)
            bytes < 1024 * 1024 * 1024 -> String.format("%.2f MB", bytes / (1024.0 * 1024))
            else -> String.format("%.2f GB", bytes / (1024.0 * 1024 * 1024))
        }
    }
    
    /**
     * 修复：改进onDestroy确保资源正确释放
     */
    override fun onDestroy() {
        super.onDestroy()
        
        VpnFileLogger.d(TAG, "onDestroy开始")
        
        // 清除实例引用
        instanceRef?.clear()
        instanceRef = null
        
        // 取消所有协程
        try {
            serviceScope.cancel()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "取消协程作用域失败", e)
        }
        
        // 修复：安全注销广播接收器
        unregisterStopReceiver()
        unregisterNotificationReceiver()
        
        // 如果服务还在运行，执行清理
        if (currentState != V2RayState.DISCONNECTED) {
            updateServiceState(V2RayState.DISCONNECTED)  // 使用新方法更新状态
            
            // 取消所有任务
            statsJob?.cancel()
            statsJob = null
            
            connectionCheckJob?.cancel()
            connectionCheckJob = null
            
            startupLatch = null
            
            // 注销网络回调
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    defaultNetworkCallback?.let {
                        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        connectivityManager.unregisterNetworkCallback(it)
                    }
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "注销网络回调失败", e)
                }
                defaultNetworkCallback = null
            }
            
            // 中断监控线程
            try {
                tun2socksMonitorThread?.interrupt()
                tun2socksMonitorThread = null
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "中断监控线程失败", e)
            }
            
            // 停止tun2socks
            stopTun2socks()
            
            // 停止V2Ray核心
            try {
                coreController?.stopLoop()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
            }
            
            // 关闭VPN接口
            try {
                mInterface?.close()
                mInterface = null
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
            }
        }
        
        // 清空核心控制器引用
        coreController = null
        
        // 释放WakeLock
        releaseWakeLock()
        
        // 【三重清理机制】清理 SharedPreferences
        try {
            getSharedPreferences("vpn_traffic_stats", Context.MODE_PRIVATE)
                .edit().clear().apply()
            getSharedPreferences("vpn_service_state", Context.MODE_PRIVATE)
                .edit().clear().apply()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "清理SharedPreferences失败", e)
        }
        
        // 重置所有流量统计变量
        uploadBytes = 0
        downloadBytes = 0
        uploadSpeed = 0
        downloadSpeed = 0
        startTime = 0
        totalUploadBytes = 0
        totalDownloadBytes = 0
        
        VpnFileLogger.d(TAG, "onDestroy完成")
        
        // 刷新日志并关闭
        runBlocking {
            VpnFileLogger.flushAll()
        }
        VpnFileLogger.close()
    }
}
