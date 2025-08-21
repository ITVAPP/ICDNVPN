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
 * V2Ray VPN服务实现 - 完整版（包含连接保持机制）
 */
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    // 连接状态枚举
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
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"
        
        // WakeLock标签
        private const val WAKELOCK_TAG = "cfvpn:v2ray"
        
        // ===== IPv6统一控制开关 =====
        // 设置为false时，完全禁用IPv6相关功能
        // 设置为true时，启用IPv6支持（需要网络环境支持）
        private const val ENABLE_IPV6 = false
        
        // VPN配置常量（与v2rayNG保持一致）
        // 优化2: MTU优化 - 增加MTU值以提高吞吐量（需要测试网络兼容性）
        private const val VPN_MTU = 1500  // 可根据网络环境调整，某些网络支持9000
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        private const val PRIVATE_VLAN6_ROUTER = "da26:2626::2"
        
        // V2Ray端口默认值
        private const val DEFAULT_SOCKS_PORT = 7898
        
        // 本地DNS配置常量
        private const val LOCAL_DNS_PORT = 10853
        private const val DNS_TAG_IN = "dns-in"
        private const val DNS_TAG_OUT = "dns-out"
        
        // 流量统计配置
        // 优化4: 流量统计优化 - 减少查询频率
        private const val STATS_UPDATE_INTERVAL = 5000L  // 修改为3秒，与v2rayNG一致
        
        // tun2socks重启限制
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L
        
        // tun2socks二进制文件名（与v2rayNG一致）
        private const val TUN2SOCKS = "libtun2socks.so"
        
        // 连接检查间隔
        private const val CONNECTION_CHECK_INTERVAL = 30000L 
        
        // 服务状态
        @Volatile
        private var currentState: V2RayState = V2RayState.DISCONNECTED
        
        @Volatile
        private var instanceRef: WeakReference<V2RayVpnService>? = null
        
        // 国际化文字存储
        private var localizedStrings = mutableMapOf<String, String>()
        
        private val instance: V2RayVpnService?
            get() = instanceRef?.get()
        
        @JvmStatic
        fun isServiceRunning(): Boolean = currentState == V2RayState.CONNECTED

        /**
         * 更新通知栏文字（语言切换时调用）
         * @return 是否更新成功
         */
        @JvmStatic
        fun updateNotificationStrings(newStrings: Map<String, String>): Boolean {
            return try {
                VpnFileLogger.d(TAG, "开始更新通知栏本地化文字")
                
                // 更新静态存储的本地化文字
                localizedStrings.clear()
                localizedStrings.putAll(newStrings)
                
                // 获取服务实例
                val service = instance?.get()
                if (service != null) {
                    // 更新实例的本地化文字
                    service.instanceLocalizedStrings.clear()
                    service.instanceLocalizedStrings.putAll(newStrings)
                    
                    // 只在已连接状态下更新通知栏
                    if (currentState == V2RayState.CONNECTED) {
                        VpnFileLogger.d(TAG, "服务已连接，更新通知栏显示")
                        
                        // 重新构建并更新通知
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
                        VpnFileLogger.d(TAG, "服务未连接，仅更新本地化字符串")
                        true
                    }
                } else {
                    VpnFileLogger.w(TAG, "服务实例不存在，仅更新静态本地化字符串")
                    // 即使服务不在运行，也保存字符串供下次使用
                    true
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "更新通知栏文字异常", e)
                false
            }
        }
        
        /**
         * 启动VPN服务 - 简化版（添加虚拟DNS参数）
         * 
         * @param allowedApps 允许走VPN的应用列表（空列表或null表示所有应用）
         * @param enableVirtualDns 是否启用虚拟DNS（防DNS泄露）
         * @param virtualDnsPort 虚拟DNS端口
         */
        @JvmStatic
        fun startVpnService(
            context: Context, 
            config: String,
            globalProxy: Boolean = false,
            blockedApps: List<String>? = null,  // 保留接口兼容性，但不使用
            allowedApps: List<String>? = null,  // 简化：只保留允许列表
            appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE,  // 保留接口兼容性，但不使用
            bypassSubnets: List<String>? = null,
            enableAutoStats: Boolean = true,
            disconnectButtonName: String = "停止",
            localizedStrings: Map<String, String> = emptyMap(),
            enableVirtualDns: Boolean = false,  // 新增：虚拟DNS开关
            virtualDnsPort: Int = 10853  // 新增：虚拟DNS端口
        ) {
            VpnFileLogger.d(TAG, "准备启动服务, 全局代理: $globalProxy, 虚拟DNS: $enableVirtualDns, IPv6: $ENABLE_IPV6")
            VpnFileLogger.d(TAG, "允许应用: ${allowedApps?.size ?: "全部"}")
            
            // 保存国际化文字
            this.localizedStrings.clear()
            this.localizedStrings.putAll(localizedStrings)
            
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN"
                putExtra("config", config)
                putExtra("globalProxy", globalProxy)
                putExtra("enableAutoStats", enableAutoStats)
                putExtra("enableVirtualDns", enableVirtualDns)  // 传递虚拟DNS开关
                putExtra("virtualDnsPort", virtualDnsPort)  // 传递虚拟DNS端口
                putStringArrayListExtra("allowedApps", ArrayList(allowedApps ?: emptyList()))
                putStringArrayListExtra("bypassSubnets", ArrayList(bypassSubnets ?: emptyList()))
                
                // 传递国际化文字
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
        
        // AppProxyMode枚举 - 保留以保持接口兼容性
        enum class AppProxyMode {
            EXCLUDE,
            INCLUDE
        }
        
        /**
         * 停止VPN服务
         */
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
        
        /**
         * 获取流量统计 - 简化版
         * 返回当前的代理流量数据（不包含直连流量）
         */
        @JvmStatic
        fun getTrafficStats(): Map<String, Long> {
            return instance?.getCurrentTrafficStats() ?: mapOf(
                "uploadTotal" to 0L,
                "downloadTotal" to 0L,
                "uploadSpeed" to 0L,
                "downloadSpeed" to 0L
            )
        }
    }
    
    // V2Ray核心控制器
    private var coreController: CoreController? = null
    
    // VPN接口文件描述符
    private var mInterface: ParcelFileDescriptor? = null
    
    // tun2socks进程（与v2rayNG一致）
    private var process: Process? = null
    
    // 网络回调（Android P及以上）
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null
    
    // WakeLock（保持CPU唤醒）
    private var wakeLock: PowerManager.WakeLock? = null
    
    // tun2socks重启控制
    private var tun2socksRestartCount = 0
    private var tun2socksFirstRestartTime = 0L
    
    // 配置信息
    private var configJson: String = ""  // 直接保存dart生成的JSON配置
    private var globalProxy: Boolean = false
    private var allowedApps: List<String> = emptyList()  // 简化：只保留允许列表
    private var bypassSubnets: List<String> = emptyList()
    private var enableAutoStats: Boolean = true
    
    // SOCKS端口（从配置中提取）- 修复：添加成员变量
    private var socksPort: Int = DEFAULT_SOCKS_PORT
    
    // 本地DNS端口（动态注入后的端口）
    private var localDnsPort: Int = -1
    
    // 虚拟DNS配置
    private var enableVirtualDns: Boolean = false
    private var configuredVirtualDnsPort: Int = 10853
    
    // 实例级的国际化文字存储
    private val instanceLocalizedStrings = mutableMapOf<String, String>()
    
    // 协程作用域
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计数据 - 修复：确保初始化正确
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var uploadSpeed: Long = 0
    private var downloadSpeed: Long = 0
    private var lastUploadBytes: Long = 0
    private var lastDownloadBytes: Long = 0
    private var lastStatsTime: Long = 0
    private var startTime: Long = 0
    
    // 修复：只统计真正的代理流量标签（不包括direct、block等）
    private val outboundTags = mutableListOf<String>()
    
    // 修复：添加累计流量变量（因为queryStats会重置计数器）
    private var totalUploadBytes: Long = 0
    private var totalDownloadBytes: Long = 0
    
    // 系统流量统计初始值（备用方案）
    private var initialUploadBytes: Long? = null
    private var initialDownloadBytes: Long? = null
    
    // 统计任务
    private var statsJob: Job? = null
    
    // 连接检查任务
    private var connectionCheckJob: Job? = null
    
    // tun2socks监控线程
    private var tun2socksMonitorThread: Thread? = null
    
    // 验证任务
    private var verificationJob: Job? = null
    
    // 添加启动完成标志
    @Volatile
    private var v2rayCoreStarted = false
    
    // 修复：startupLatch 改为可空类型，每次启动时创建新的，添加 @Volatile 确保线程安全
    @Volatile
    private var startupLatch: CompletableDeferred<Boolean>? = null
    
    // 广播接收器
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                VpnFileLogger.d(TAG, "收到停止VPN广播")
                stopV2Ray()
            }
        }
    }
    
    // ===== 🎯 新增：配置解析工具方法 =====
    
    /**
     * 解析V2Ray配置JSON - 统一入口，避免重复解析
     * 修复：正确处理domain和ip数组字段
     */
    private fun parseConfig(): JSONObject? {
        return try {
            val config = JSONObject(configJson)
            // 验证路由规则
            val routing = config.optJSONObject("routing")
            if (routing != null) {
                val rules = routing.optJSONArray("rules")
                var hasGeoRules = false
                for (i in 0 until (rules?.length() ?: 0)) {
                    val rule = rules.getJSONObject(i)
                    
                    // ✅ 修复：正确处理domain数组
                    val domainArray = rule.optJSONArray("domain")
                    if (domainArray != null) {
                        for (j in 0 until domainArray.length()) {
                            val domain = domainArray.getString(j)
                            if (domain.startsWith("geosite:")) {
                                hasGeoRules = true
                                VpnFileLogger.d(TAG, "找到geosite规则: $domain")
                            }
                        }
                    }
                    
                    // ✅ 修复：正确处理ip数组
                    val ipArray = rule.optJSONArray("ip")
                    if (ipArray != null) {
                        for (j in 0 until ipArray.length()) {
                            val ip = ipArray.getString(j)
                            if (ip.startsWith("geoip:")) {
                                hasGeoRules = true
                                VpnFileLogger.d(TAG, "找到geoip规则: $ip")
                            }
                        }
                    }
                }
                
                if (!hasGeoRules) {
                    VpnFileLogger.w(TAG, "警告：配置文件中未找到任何geosite或geoip规则")
                } else {
                    VpnFileLogger.i(TAG, "✓ 配置文件包含geo规则")
                }
            } else {
                VpnFileLogger.w(TAG, "警告：配置文件中未找到routing配置")
            }
            config
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "解析V2Ray配置失败", e)
            null
        }
    }
    
    /**
     * 从配置中提取指定标签的入站端口
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
    

    
    // ===== 🎯 新增：网络连接测试工具方法 =====
    
    /**
     * 测试TCP连接 - 统一的网络连接测试逻辑
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
                VpnFileLogger.i(TAG, "✓ $serviceName 端口 $port 连接正常")
                true
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗ $serviceName 端口 $port 无法连接: ${e.message}")
            false
        }
    }
    
    // ===== 🎯 修复：通知构建工具方法 - 支持连接中状态 =====
    
    /**
     * 构建通知 - 统一的通知构建逻辑
     * @param isConnecting 是否为连接中状态
     */
    private fun buildNotification(isConnecting: Boolean = false): android.app.Notification? {
        return try {
            val channelName = instanceLocalizedStrings["notificationChannelName"] ?: "VPN服务"
            val channelDesc = instanceLocalizedStrings["notificationChannelDesc"] ?: "VPN连接状态通知"
            
            // 创建通知渠道（Android O及以上）
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
            
            // 创建PendingIntent
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
            
            // 构建标题和内容 - 修复：根据连接状态显示不同内容
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
            
            // 构建通知
            val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(mainPendingIntent)
            
            // 连接中状态不显示断开按钮
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
            // 降级方案
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
     * 修复1：获取V2Ray资源路径（必须使用assets子目录）
     * 这是关键修复，V2Ray期望在特定的assets目录找到geo文件
     */
    private fun getV2RayAssetsPath(): String {
        // 方案1：优先使用外部存储的assets目录
        val extDir = getExternalFilesDir("assets")
        if (extDir != null) {
            if (!extDir.exists()) {
                extDir.mkdirs()
            }
            VpnFileLogger.d(TAG, "使用外部存储assets目录: ${extDir.absolutePath}")
            return extDir.absolutePath
        }
        
        // 方案2：使用内部存储的assets目录
        val intDir = getDir("assets", Context.MODE_PRIVATE)
        if (!intDir.exists()) {
            intDir.mkdirs()
        }
        VpnFileLogger.d(TAG, "使用内部存储assets目录: ${intDir.absolutePath}")
        return intDir.absolutePath
    }
    
/**
 * 服务创建时调用
 */
override fun onCreate() {
    super.onCreate()
    
    VpnFileLogger.init(applicationContext)
    VpnFileLogger.d(TAG, "VPN服务onCreate开始, IPv6支持: $ENABLE_IPV6")
    
    instanceRef = WeakReference(this)
    
    // 初始化Go运行时
    try {
        Seq.setContext(applicationContext)
        VpnFileLogger.d(TAG, "Go运行时初始化成功")
    } catch (e: Exception) {
        VpnFileLogger.e(TAG, "Go运行时初始化失败", e)
        stopSelf()
        return
    }
    
    // 注册广播接收器
    try {
        registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
        VpnFileLogger.d(TAG, "广播接收器注册成功")
    } catch (e: Exception) {
        VpnFileLogger.e(TAG, "注册广播接收器失败", e)
    }
    
    // 修复1：先复制资源文件到正确的assets目录
    copyAssetFiles()
    
    // 修复1：使用正确的assets路径初始化V2Ray环境
    try {
        val envPath = getV2RayAssetsPath()  // assets 目录路径
        
        // 验证geo文件是否存在
        val geoipFile = File(envPath, "geoip.dat")
        val geositeFile = File(envPath, "geosite.dat")
        VpnFileLogger.d(TAG, "验证Geo文件:")
        VpnFileLogger.d(TAG, "  geoip.dat - 存在: ${geoipFile.exists()}, 路径: ${geoipFile.absolutePath}, 大小: ${geoipFile.length()} bytes")
        VpnFileLogger.d(TAG, "  geosite.dat - 存在: ${geositeFile.exists()}, 路径: ${geositeFile.absolutePath}, 大小: ${geositeFile.length()} bytes")
        
        // ===== 关键修复点：传递目录路径而不是文件路径 =====
        // 原代码错误：Libv2ray.initCoreEnv(geoipPath, geositePath)
        // 修复后：传递包含geo文件的目录路径
        Libv2ray.initCoreEnv(envPath, envPath)  // 两个参数都传递同一个目录路径
        VpnFileLogger.d(TAG, "V2Ray环境初始化成功，资源目录: $envPath")
        
        val version = Libv2ray.checkVersionX()
        VpnFileLogger.i(TAG, "V2Ray版本: $version")
    } catch (e: Exception) {
        VpnFileLogger.e(TAG, "V2Ray环境初始化失败", e)
    }
    
    // 获取WakeLock
    acquireWakeLock()
    
    // 不在这里初始化统计缓存，改为在解析配置后初始化
    
    VpnFileLogger.d(TAG, "VPN服务onCreate完成")
}
    
    /**
     * 修复：从配置中提取outbound标签 - 只统计真正的代理流量
     * 不统计direct（直连）、block（屏蔽）、fragment相关标签
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
                        
                        // 修复：只统计真正的代理协议流量
                        // 排除：freedom（直连）、blackhole（屏蔽）、dns（DNS）
                        if (tag.isNotEmpty() && protocol !in listOf("freedom", "blackhole", "dns")) {
                            // 再次检查是否是fragment相关
                            val settings = outbound.optJSONObject("settings")
                            val hasFragment = settings?.has("fragment") == true
                            
                            if (!hasFragment) {
                                // 只统计代理协议：vless、vmess、trojan、shadowsocks、socks、http
                                if (protocol in listOf("vless", "vmess", "trojan", "shadowsocks", "socks", "http")) {
                                    outboundTags.add(tag)
                                    VpnFileLogger.d(TAG, "添加代理流量统计标签: $tag (protocol=$protocol)")
                                }
                            }
                        }
                    }
                }
                
                // 如果没有找到任何代理标签，默认添加proxy
                if (outboundTags.isEmpty()) {
                    outboundTags.add("proxy")
                    VpnFileLogger.w(TAG, "未找到代理outbound标签，使用默认标签: proxy")
                }
                
                VpnFileLogger.i(TAG, "流量统计将只监控代理流量，标签数: ${outboundTags.size}, 标签: $outboundTags")
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "提取outbound标签失败", e)
            // 使用默认标签
            outboundTags.add("proxy")
        }
    }
    
    /**
     * 获取WakeLock以保持CPU唤醒
     */
    private fun acquireWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                WAKELOCK_TAG
            ).apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L)  // 10分钟后自动释放，防止泄漏
            }
            VpnFileLogger.d(TAG, "WakeLock已获取")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "获取WakeLock失败", e)
        }
    }
    
    /**
     * 释放WakeLock
     */
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
    
    /**
     * 服务启动命令
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnFileLogger.d(TAG, "================== onStartCommand START ==================")
        VpnFileLogger.d(TAG, "Action: ${intent?.action}")
        VpnFileLogger.d(TAG, "Flags: $flags, StartId: $startId")
        VpnFileLogger.d(TAG, "IPv6支持状态: $ENABLE_IPV6")
        
        if (intent == null || intent.action != "START_VPN") {
            VpnFileLogger.e(TAG, "无效的启动意图: intent=$intent, action=${intent?.action}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 修复：防止在 CONNECTING 或 CONNECTED 状态时重复启动
        if (currentState != V2RayState.DISCONNECTED) {
            VpnFileLogger.w(TAG, "VPN服务已在运行或正在连接，当前状态: $currentState")
            return START_STICKY
        }
        
        currentState = V2RayState.CONNECTING
        
        // 重置启动标志
        v2rayCoreStarted = false
        
        // 获取虚拟DNS配置
        enableVirtualDns = intent.getBooleanExtra("enableVirtualDns", false)
        configuredVirtualDnsPort = intent.getIntExtra("virtualDnsPort", 10853)
        
        VpnFileLogger.d(TAG, "虚拟DNS配置: 启用=$enableVirtualDns, 端口=$configuredVirtualDnsPort")
        
        // 获取并记录完整配置
        configJson = intent.getStringExtra("config") ?: ""
        
        // 记录完整的V2Ray配置内容
        VpnFileLogger.d(TAG, configJson)
        VpnFileLogger.d(TAG, "=============== 配置结束 ===============")
        
        // 解析并验证配置
        try {
            parseConfig()?.let { config ->
                // 记录关键配置信息
                VpnFileLogger.d(TAG, "===== 配置解析 =====")
                
                // 修复：提取outbound标签用于流量统计
                extractOutboundTags()
                
                // 检查stats配置（流量统计必需）
                val hasStats = config.has("stats")
                VpnFileLogger.d(TAG, "Stats配置: ${if (hasStats) "已启用" else "未启用"}")
                
                // 检查policy配置（流量统计必需）
                val policy = config.optJSONObject("policy")
                if (policy != null) {
                    val system = policy.optJSONObject("system")
                    if (system != null) {
                        val statsOutboundUplink = system.optBoolean("statsOutboundUplink", false)
                        val statsOutboundDownlink = system.optBoolean("statsOutboundDownlink", false)
                        VpnFileLogger.d(TAG, "出站流量统计: 上行=$statsOutboundUplink, 下行=$statsOutboundDownlink")
                        VpnFileLogger.d(TAG, "注意：只统计代理流量(proxy)，不统计直连(direct)和屏蔽(block)流量")
                    }
                }
                
                // 只在启用虚拟DNS时检查本地DNS配置
                if (enableVirtualDns) {
                    localDnsPort = extractInboundPort(DNS_TAG_IN, configuredVirtualDnsPort)
                    val inbounds = config.optJSONArray("inbounds")
                    VpnFileLogger.d(TAG, "入站数量: ${inbounds?.length() ?: 0}")
                    for (i in 0 until (inbounds?.length() ?: 0)) {
                        val inbound = inbounds!!.getJSONObject(i)
                        val tag = inbound.optString("tag")
                        if (tag == DNS_TAG_IN) {
                            VpnFileLogger.i(TAG, "✓ 本地DNS服务已配置: 端口=$localDnsPort")
                        }
                    }
                    
                    // 检查DNS出站
                    val outbounds = config.optJSONArray("outbounds")
                    for (i in 0 until (outbounds?.length() ?: 0)) {
                        val outbound = outbounds!!.getJSONObject(i)
                        if (outbound.optString("protocol") == "dns") {
                            VpnFileLogger.i(TAG, "✓ DNS出站已配置: tag=${outbound.optString("tag")}")
                        }
                    }
                }
                
                // 日志配置
                val log = config.optJSONObject("log")
                VpnFileLogger.d(TAG, "日志级别: ${log?.optString("loglevel", "info")}")
                
                // DNS配置
                val dns = config.optJSONObject("dns")
                if (dns != null) {
                    VpnFileLogger.d(TAG, "DNS配置: ${dns.toString()}")
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "配置解析失败", e)
            VpnFileLogger.e(TAG, "原始配置: $configJson")
        }
        
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        enableAutoStats = intent.getBooleanExtra("enableAutoStats", true)
        
        // 简化：只获取允许列表
        allowedApps = intent.getStringArrayListExtra("allowedApps") ?: emptyList()
        bypassSubnets = intent.getStringArrayListExtra("bypassSubnets") ?: emptyList()
        
        VpnFileLogger.d(TAG, "===== 启动参数 =====")
        VpnFileLogger.d(TAG, "全局代理: $globalProxy")
        VpnFileLogger.d(TAG, "允许应用: ${if (allowedApps.isEmpty()) "全部" else "${allowedApps.size}个: $allowedApps"}")
        VpnFileLogger.d(TAG, "绕过子网: $bypassSubnets")
        VpnFileLogger.d(TAG, "自动统计: $enableAutoStats")
        VpnFileLogger.d(TAG, "虚拟DNS: $enableVirtualDns")
        if (enableVirtualDns) {
            VpnFileLogger.d(TAG, "本地DNS端口: $localDnsPort")
        }
        
        // 提取国际化文字
        instanceLocalizedStrings.clear()
        instanceLocalizedStrings["appName"] = intent.getStringExtra("l10n_appName") ?: "CFVPN"
        instanceLocalizedStrings["notificationChannelName"] = intent.getStringExtra("l10n_notificationChannelName") ?: "VPN服务"
        instanceLocalizedStrings["notificationChannelDesc"] = intent.getStringExtra("l10n_notificationChannelDesc") ?: "VPN连接状态通知"
        instanceLocalizedStrings["globalProxyMode"] = intent.getStringExtra("l10n_globalProxyMode") ?: "全局代理模式"
        instanceLocalizedStrings["smartProxyMode"] = intent.getStringExtra("l10n_smartProxyMode") ?: "智能代理模式"
        instanceLocalizedStrings["proxyOnlyMode"] = intent.getStringExtra("l10n_proxyOnlyMode") ?: "仅代理模式"
        instanceLocalizedStrings["disconnectButtonName"] = intent.getStringExtra("l10n_disconnectButtonName") ?: "断开"
        instanceLocalizedStrings["trafficStatsFormat"] = intent.getStringExtra("l10n_trafficStatsFormat") ?: "流量: ↑%upload ↓%download"
        
        if (configJson.isEmpty()) {
            VpnFileLogger.e(TAG, "配置为空")
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "配置为空")
            stopSelf()
            return START_NOT_STICKY
        }
        
        VpnFileLogger.d(TAG, "配置参数: 全局代理=$globalProxy, " +
                "允许应用=${allowedApps.size}个, 绕过子网=${bypassSubnets.size}个, 虚拟DNS=$enableVirtualDns")
        
        // 修复：先显示"正在连接"的通知，而不是"已连接"
        try {
            val connectingNotification = buildNotification(isConnecting = true)
            if (connectingNotification != null) {
                startForeground(NOTIFICATION_ID, connectingNotification)
                VpnFileLogger.d(TAG, "前台服务已启动（显示正在连接状态）")
            } else {
                VpnFileLogger.e(TAG, "无法创建通知")
                currentState = V2RayState.DISCONNECTED
                sendStartResultBroadcast(false, "无法创建通知")
                stopSelf()
                return START_NOT_STICKY
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动前台服务失败", e)
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "启动前台服务失败: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 检查VPN准备状态
        val prepare = prepare(this)
        if (prepare != null) {
            VpnFileLogger.e(TAG, "VPN未授权，需要用户授权")
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "需要VPN授权")
            // 这里可以启动授权Activity或返回错误
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 启动VPN
        serviceScope.launch {
            try {
                startV2RayWithVPN()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动失败", e)
                currentState = V2RayState.DISCONNECTED
                sendStartResultBroadcast(false, "启动失败: ${e.message}")
                withContext(Dispatchers.Main) {
                    stopSelf()
                }
            }
        }
        
        return START_STICKY
    }
    
    /**
     * 修复1：复制资源文件到正确的assets子目录
     */
    private fun copyAssetFiles() {
        VpnFileLogger.d(TAG, "开始复制资源文件")
        
        // 使用正确的assets子目录
        val assetDir = File(getV2RayAssetsPath())
        if (!assetDir.exists()) {
            assetDir.mkdirs()
        }
        
        VpnFileLogger.d(TAG, "资源目标目录: ${assetDir.absolutePath}")
        
        val files = listOf("geoip.dat", "geosite.dat")
        
        for (fileName in files) {
            try {
                val targetFile = File(assetDir, fileName)  // 复制到assets子目录
                
                if (shouldUpdateFile(fileName, targetFile)) {
                    copyAssetFile(fileName, targetFile)
                    if (targetFile.exists() && targetFile.length() < 1024) { // 假设最小 1KB
                        VpnFileLogger.e(TAG, "文件 $fileName 可能损坏，大小仅 ${targetFile.length()} bytes")
                    } else {
                        VpnFileLogger.d(TAG, "文件复制成功: $fileName -> ${targetFile.absolutePath} (${targetFile.length()} bytes)")
                    }
                } else {
                    VpnFileLogger.d(TAG, "文件已是最新,跳过: $fileName (${targetFile.length()} bytes)")
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "处理文件失败: $fileName", e)
            }
        }
        
        VpnFileLogger.d(TAG, "资源文件复制完成")
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
            VpnFileLogger.d(TAG, "正在复制文件: $assetName")
            
            assets.open(assetName).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            
            VpnFileLogger.d(TAG, "文件复制成功: $assetName (${targetFile.length()} bytes)")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "复制文件失败: $assetName", e)
        }
    }
    
    /**
     * 快速检查JSON语法（不验证V2Ray配置逻辑）
     * 仅用于提前发现明显的JSON格式错误
     */
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
     * 启动V2Ray(VPN模式) - 优化版
     * 流程：快速JSON检查→启动V2Ray→验证配置（通过启动结果）→建立VPN→启动tun2socks→验证转发
     * 
     * 修复：每次启动前创建新的 startupLatch
     */
    private suspend fun startV2RayWithVPN() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "================== startV2RayWithVPN START ==================")
        
        try {
            // 步骤0: 快速JSON语法检查（提前失败）
            if (!quickCheckJsonSyntax(configJson)) {
                throw Exception("配置文件JSON格式错误，请检查语法（如多余的逗号、引号等）")
            }
            
            // 修复：每次启动前创建新的 startupLatch
            startupLatch = CompletableDeferred<Boolean>()
            VpnFileLogger.d(TAG, "创建新的 startupLatch")
            
            // 步骤1: 创建核心控制器
            VpnFileLogger.d(TAG, "===== 步骤1: 创建核心控制器 =====")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                VpnFileLogger.e(TAG, "创建CoreController失败: 返回null")
                throw Exception("创建CoreController失败")
            }
            VpnFileLogger.d(TAG, "CoreController创建成功")
            
            // 步骤2: 启动V2Ray核心（配置验证在此步骤完成）
            VpnFileLogger.d(TAG, "===== 步骤2: 启动V2Ray核心（同时验证配置） =====")
            VpnFileLogger.d(TAG, "原始配置长度: ${configJson.length} 字符")
            
            VpnFileLogger.d(TAG, "调用 coreController.startLoop()...")
            try {
                coreController?.startLoop(configJson)
                VpnFileLogger.d(TAG, "coreController.startLoop() 调用完成")
            } catch (e: Exception) {
                // V2Ray启动失败，说明配置有错误
                VpnFileLogger.e(TAG, "V2Ray核心启动失败，配置可能有错误: ${e.message}")
                
                // 解析错误信息，提供更详细的错误提示
                val errorMsg = e.message ?: ""
                when {
                    errorMsg.contains("json", ignoreCase = true) -> {
                        throw Exception("配置文件JSON格式错误: $errorMsg")
                    }
                    errorMsg.contains("dns", ignoreCase = true) -> {
                        throw Exception("DNS配置错误: $errorMsg")
                    }
                    errorMsg.contains("outbound", ignoreCase = true) -> {
                        throw Exception("出站配置错误: $errorMsg")
                    }
                    errorMsg.contains("inbound", ignoreCase = true) -> {
                        throw Exception("入站配置错误: $errorMsg")
                    }
                    errorMsg.contains("routing", ignoreCase = true) -> {
                        throw Exception("路由配置错误: $errorMsg")
                    }
                    errorMsg.contains("port", ignoreCase = true) || 
                    errorMsg.contains("address already in use", ignoreCase = true) -> {
                        throw Exception("端口被占用: $errorMsg")
                    }
                    else -> {
                        throw Exception("V2Ray启动失败: $errorMsg")
                    }
                }
            }
            
            // 等待startup()回调确认启动成功
            VpnFileLogger.d(TAG, "等待V2Ray核心启动回调...")
            val startupSuccess = withTimeoutOrNull(5000L) {
                startupLatch?.await()  // 使用安全调用
            }
            
            if (startupSuccess != true) {
                VpnFileLogger.e(TAG, "V2Ray核心启动超时，配置可能有问题")
                throw Exception("V2Ray核心启动超时或失败，请检查配置文件")
            }
            
            // 步骤3: 验证V2Ray启动状态（配置验证的第二步）
            VpnFileLogger.d(TAG, "===== 步骤3: 验证V2Ray启动状态 =====")
            val isRunning = coreController?.isRunning ?: false
            if (!isRunning) {
                VpnFileLogger.e(TAG, "V2Ray核心未运行，配置验证失败")
                throw Exception("V2Ray核心未运行，配置可能有错误")
            }
            
            VpnFileLogger.i(TAG, "✓ V2Ray核心启动成功，配置验证通过")
            
            // 步骤4: 建立VPN隧道
            VpnFileLogger.d(TAG, "===== 步骤4: 建立VPN隧道 =====")
            withContext(Dispatchers.Main) {
                establishVpn()
            }
            
            if (mInterface == null) {
                VpnFileLogger.e(TAG, "VPN隧道建立失败: mInterface为null")
                throw Exception("VPN隧道建立失败")
            }
            
            VpnFileLogger.d(TAG, "VPN隧道建立成功, FD=${mInterface?.fd}")
            
            // 配置网络回调（Android P及以上）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                configureNetworkCallback()
            }
            
            // 步骤5: 启动tun2socks进程
            VpnFileLogger.d(TAG, "===== 步骤5: 启动tun2socks进程 (badvpn-tun2socks) =====")
            runTun2socks()
            
            // 步骤6: 验证转发（在sendFd中通过协程异步执行）
            VpnFileLogger.d(TAG, "===== 步骤6: 验证tun2socks转发（异步） =====")
            
            // 步骤7: 更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            // 修复：连接成功后，更新通知为"已连接"状态
            updateNotificationToConnected()
            
            VpnFileLogger.i(TAG, "================== V2Ray服务(VPN模式)完全启动成功 ==================")
            
            sendStartResultBroadcast(true)
            
            // 保存自启动配置
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    // 修改：传递虚拟DNS配置
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        configJson,
                        "VPN_TUN",  // 保留mode参数以兼容
                        globalProxy,
                        enableVirtualDns,  // 添加虚拟DNS开关
                        configuredVirtualDnsPort  // 添加虚拟DNS端口
                    )
                    VpnFileLogger.d(TAG, "已更新自启动配置，虚拟DNS: $enableVirtualDns")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存自启动配置失败", e)
            }
            
            // 启动简化的流量监控（只用于通知栏显示）
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动流量统计监控")
                startSimpleTrafficMonitor()
            }
            
            // 优化3: 启动连接保持检查
            startConnectionCheck()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray(VPN模式)失败: ${e.message}")
            // 清理 startupLatch
            startupLatch = null
            cleanupResources()
            sendStartResultBroadcast(false, e.message)
            throw e
        }
    }
    
    /**
     * 修复：更新通知为已连接状态
     */
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
    
    /**
     * 配置网络回调以处理网络切换
     */
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
                    VpnFileLogger.d(TAG, "网络能力变化: $network")
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
    
    /**
     * 优化3: 启动连接状态检查 - 改进的重连机制
     */
    private fun startConnectionCheck() {
        connectionCheckJob?.cancel()
        
        connectionCheckJob = serviceScope.launch {
            while (currentState == V2RayState.CONNECTED && isActive) {
                delay(CONNECTION_CHECK_INTERVAL)
                
                try {
                    // 检查V2Ray核心是否运行
                    val isRunning = coreController?.isRunning ?: false
                    if (!isRunning) {
                        VpnFileLogger.e(TAG, "V2Ray核心意外停止")
                        stopV2Ray()
                        break
                    }
                    
                    // 检查tun2socks进程（VPN模式）
                    val processAlive = process?.isAlive ?: false
                    if (!processAlive) {
                        VpnFileLogger.w(TAG, "tun2socks进程不存在，尝试重启")
                        
                        // 优化3: 改进的重启逻辑
                        if (shouldRestartTun2socks()) {
                            // 等待一段时间再重启，避免频繁重启
                            delay(2000)
                            
                            // 检查是否仍需要重启
                            if (currentState == V2RayState.CONNECTED && (process?.isAlive != true)) {
                                restartTun2socks()
                            }
                        } else {
                            VpnFileLogger.e(TAG, "tun2socks重启失败次数过多")
                            stopV2Ray()
                            break
                        }
                    }
                    
                    // 更新WakeLock（防止超时释放）
                    renewWakeLock()
                    
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "连接检查异常", e)
                }
            }
        }
    }
    
    /**
     * 更新WakeLock
     */
    private fun renewWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) {
                    it.acquire(10 * 60 * 1000L)  // 续期10分钟
                    VpnFileLogger.d(TAG, "WakeLock已续期")
                } else {
                    acquireWakeLock()
                }
            } ?: acquireWakeLock()
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "更新WakeLock失败", e)
        }
    }
    
    /**
     * 发送VPN启动结果广播
     * 包含详细的错误信息，方便用户排查问题
     */
    private fun sendStartResultBroadcast(success: Boolean, error: String? = null) {
        try {
            val intent = Intent(ACTION_VPN_START_RESULT).apply {
                putExtra("success", success)
                
                // 提供更友好的错误信息
                val userFriendlyError = when {
                    error == null -> null
                    error.contains("json", ignoreCase = true) -> "配置文件格式错误，请检查JSON语法"
                    error.contains("port", ignoreCase = true) || 
                    error.contains("address already in use", ignoreCase = true) -> "端口被占用，请检查是否有其他VPN在运行"
                    error.contains("dns", ignoreCase = true) -> "DNS配置错误，请检查DNS设置"
                    error.contains("outbound", ignoreCase = true) -> "出站配置错误，请检查服务器信息"
                    error.contains("inbound", ignoreCase = true) -> "入站配置错误，请检查本地端口设置"
                    error.contains("routing", ignoreCase = true) -> "路由配置错误，请检查路由规则"
                    error.contains("geoip", ignoreCase = true) || 
                    error.contains("geosite", ignoreCase = true) -> "geo数据文件错误，请重新安装应用"
                    error.contains("timeout", ignoreCase = true) -> "启动超时，配置可能有问题"
                    error.contains("permission", ignoreCase = true) -> "权限不足，请授予VPN权限"
                    else -> error
                }
                
                putExtra("error", userFriendlyError)
                
                // 保留原始错误信息供调试
                putExtra("error_detail", error)
            }
            sendBroadcast(intent)
            VpnFileLogger.d(TAG, "已发送VPN启动结果广播: success=$success, error=$error")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "发送启动结果广播失败", e)
        }
    }
    
    /**
     * 清理资源
     */
    private fun cleanupResources() {
        currentState = V2RayState.DISCONNECTED
        
        // 停止连接检查
        connectionCheckJob?.cancel()
        connectionCheckJob = null
        
        // 停止验证任务
        verificationJob?.cancel()
        verificationJob = null
        
        // 清理 startupLatch
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
        
        stopTun2socks()
        
        try {
            coreController?.stopLoop()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "停止核心异常", e)
        }
        coreController = null
        
        // 关闭VPN接口
        mInterface?.close()
        mInterface = null
        
        // 释放WakeLock
        releaseWakeLock()
    }
    
    /**
     * 建立VPN隧道 - 极简版本（支持虚拟DNS配置和IPv6控制）
     * 所有路由决策完全交给V2Ray的routing规则处理
     * VPN层只建立隧道，不做任何路由判断
     */
    private fun establishVpn() {
        VpnFileLogger.d(TAG, "开始建立VPN隧道（虚拟DNS: ${if(enableVirtualDns) "启用" else "禁用"}, IPv6: $ENABLE_IPV6）")
        
        // 关闭旧接口
        mInterface?.let {
            try {
                it.close()
                VpnFileLogger.d(TAG, "已关闭旧VPN接口")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "关闭旧接口失败", e)
            }
        }
        mInterface = null
        
        // 创建VPN构建器
        val builder = Builder()
        
        // 基本配置
        val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
        builder.setSession(appName)
        builder.setMtu(VPN_MTU)
        
        // IPv4地址（与v2rayNG保持一致）
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        VpnFileLogger.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30")
        
        // ===== 极简路由配置 =====
        VpnFileLogger.d(TAG, "===== 配置路由（极简版，IPv6: $ENABLE_IPV6） =====")
        
        // 核心理念：VPN层只建立隧道，所有路由决策由V2Ray的routing规则处理
        // 不管globalProxy是true还是false，dart端会生成相应的V2Ray配置
        // 全局代理模式下，dart也应该配置V2Ray不代理局域网
        builder.addRoute("0.0.0.0", 0)  // IPv4全部流量进入VPN隧道
        VpnFileLogger.d(TAG, "添加IPv4全局路由: 0.0.0.0/0 (所有流量进入VPN，由V2Ray routing决定最终去向)")
        
        // 修复：根据ENABLE_IPV6常量决定是否启用IPv6
        if (ENABLE_IPV6 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addRoute("::", 0)  // IPv6全部流量进入VPN隧道
                VpnFileLogger.d(TAG, "添加IPv6全局路由: ::/0 (IPv6已启用)")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加IPv6路由失败: ${e.message}")
            }
        } else {
            VpnFileLogger.d(TAG, "IPv6支持已禁用 (ENABLE_IPV6=$ENABLE_IPV6)")
        }
        
        // globalProxy仅用于通知栏显示，不影响实际路由
        VpnFileLogger.d(TAG, "模式: ${if (globalProxy) "全局代理" else "智能代理"} (仅用于显示，实际路由由V2Ray配置决定)")
        
        // ===== 分应用代理 (Android 5.0+) =====
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // 始终排除自身
            try {
                builder.addDisallowedApplication(packageName)
                VpnFileLogger.d(TAG, "自动排除自身应用: $packageName")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "排除自身应用失败", e)
            }
            
            // 处理允许列表
            if (allowedApps.isNotEmpty()) {
                // 过滤掉自身应用、空白字符串，避免冲突
                val filteredApps = allowedApps
                    .map { it.trim() }  // 去除首尾空白
                    .filter { app -> 
                        app.isNotEmpty() && app != packageName 
                    }
                    .distinct()  // 去重
                
                if (filteredApps.isNotEmpty()) {
                    VpnFileLogger.d(TAG, "使用包含模式，原始${allowedApps.size}个，过滤后${filteredApps.size}个应用走VPN")
                    filteredApps.forEach { app ->
                        try {
                            builder.addAllowedApplication(app)
                            VpnFileLogger.d(TAG, "允许应用: $app")
                        } catch (e: Exception) {
                            VpnFileLogger.w(TAG, "添加允许应用失败: $app - ${e.message}")
                        }
                    }
                } else {
                    // 过滤后为空，回退到全部应用模式
                    VpnFileLogger.w(TAG, "警告：过滤后无有效应用，回退到全局模式（除了自身）")
                }
            } else {
                // 空列表表示所有应用都走VPN（默认行为）
                VpnFileLogger.d(TAG, "所有应用都走VPN（除了自身）")
            }
        }
        
        // 建立VPN接口
        mInterface = builder.establish()
        
        if (mInterface == null) {
            VpnFileLogger.e(TAG, "VPN接口建立失败")
        } else {
            VpnFileLogger.d(TAG, "VPN隧道建立成功,FD: ${mInterface?.fd}")
        }
    }
    
    /**
     * 启动tun2socks进程 - 支持虚拟DNS配置
     * 改进：使用可管理的Thread和协程
     */
    private fun runTun2socks() {
        VpnFileLogger.d(TAG, "===== 启动tun2socks进程 (虚拟DNS: ${if(enableVirtualDns) "启用" else "禁用"}) =====")
        
        // 🎯 优化：使用配置解析工具方法提取SOCKS端口
        socksPort = extractInboundPort("socks", DEFAULT_SOCKS_PORT)
        VpnFileLogger.d(TAG, "SOCKS端口: $socksPort")
        
        // 构建命令行参数（与v2rayNG完全一致）
        val cmd = arrayListOf(
            File(applicationContext.applicationInfo.nativeLibraryDir, TUN2SOCKS).absolutePath,
            "--netif-ipaddr", PRIVATE_VLAN4_ROUTER,
            "--netif-netmask", "255.255.255.252",
            "--socks-server-addr", "127.0.0.1:$socksPort",
            "--tunmtu", VPN_MTU.toString(),
            "--sock-path", "sock_path",  // 相对路径，与v2rayNG一致
            "--enable-udprelay",
            "--loglevel", "error"  // 修改：只输出错误日志，减少资源消耗
        )
        
        // DNS 重定向配置
        if (enableVirtualDns && localDnsPort > 0) {
            cmd.add("--dnsgw")
            cmd.add("127.0.0.1:$localDnsPort") // 例如 10853
            VpnFileLogger.i(TAG, "✓ 启用虚拟DNS网关: 127.0.0.1:$localDnsPort")
        } else {
            cmd.add("--dnsgw")
            cmd.add("127.0.0.1:$socksPort")
            VpnFileLogger.i(TAG, "✓ 重定向 DNS 到 SOCKS 入站: 127.0.0.1:$socksPort")
        }
        
        VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
        
        try {
            val proBuilder = ProcessBuilder(cmd)
            proBuilder.redirectErrorStream(true)  // 合并错误流到标准输出
            process = proBuilder
                .directory(applicationContext.filesDir)
                .start()
            
            // 改进：使用可管理的Thread监控进程
            tun2socksMonitorThread = Thread {
                try {
                    VpnFileLogger.d(TAG, "$TUN2SOCKS 进程监控开始")
                    val exitCode = process?.waitFor()
                    VpnFileLogger.d(TAG, "$TUN2SOCKS 进程退出，退出码: $exitCode")
                    
                    // 只在服务仍连接时处理意外退出
                    if (currentState == V2RayState.CONNECTED) {
                        VpnFileLogger.e(TAG, "$TUN2SOCKS 意外退出，退出码: $exitCode")
                        
                        // 使用协程处理重启逻辑
                        serviceScope.launch {
                            if (shouldRestartTun2socks()) {
                                VpnFileLogger.w(TAG, "尝试重启tun2socks (第${tun2socksRestartCount + 1}次)")
                                delay(1000)  // 等待1秒再重启
                                if (currentState == V2RayState.CONNECTED && (process?.isAlive != true)) {
                                    restartTun2socks()
                                }
                            } else {
                                VpnFileLogger.e(TAG, "tun2socks重启次数达到上限，停止服务")
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
            
            // 检查进程是否成功启动（使用协程）
            serviceScope.launch {
                delay(1000)  // 给进程一秒钟启动时间
                if (process?.isAlive != true) {
                    VpnFileLogger.e(TAG, "${TUN2SOCKS}进程启动后立即退出")
                } else {
                    VpnFileLogger.i(TAG, "${TUN2SOCKS}进程运行正常")
                }
            }
            
            // 发送文件描述符（与v2rayNG一致）
            Thread.sleep(500)  // 等待tun2socks准备就绪
            sendFd()
            
            VpnFileLogger.d(TAG, "tun2socks进程启动完成（虚拟DNS配置: ${if(enableVirtualDns) "已启用" else "未启用"}）")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动tun2socks失败", e)
            throw e
        }
    }
    
    /**
     * 发送文件描述符给tun2socks（与v2rayNG完全一致）
     * 修复3：增加tun2socks转发验证（使用协程）
     */
    private fun sendFd() {
        val path = File(applicationContext.filesDir, "sock_path").absolutePath
        val localSocket = LocalSocket()
        
        try {
            // 最多尝试6次，每次间隔递增
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
                    
                    if (!localSocket.isBound) {
                        throw Exception("LocalSocket未绑定")
                    }
                    
                    // 发送文件描述符
                    localSocket.setFileDescriptorsForSend(arrayOf(mInterface!!.fileDescriptor))
                    localSocket.outputStream.write(42)  // 与v2rayNG一致，发送任意字节触发
                    localSocket.outputStream.flush()
                    
                    VpnFileLogger.d(TAG, "文件描述符发送成功")
                    
                    // 修复3：使用协程进行验证（不阻塞主流程）
                    verificationJob = serviceScope.launch {
                        verifyTun2socksForwarding()
                    }
                    
                    break
                    
                } catch (e: Exception) {
                    tries++
                    if (tries >= maxTries) {
                        VpnFileLogger.e(TAG, "发送文件描述符失败，已达最大重试次数", e)
                        throw e
                    } else {
                        VpnFileLogger.w(TAG, "发送文件描述符失败，将重试 ($tries/$maxTries): ${e.message}")
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
    
    /**
     * 🎯 优化：统一的网络验证方法 - 使用协程
     * 修复：根据ENABLE_IPV6常量控制DNS解析
     */
    private suspend fun verifyTun2socksForwarding() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "===== 开始验证tun2socks转发 (IPv6: $ENABLE_IPV6) =====")
        
        try {
            // 稍等一下让tun2socks完全启动
            delay(500)
            
            // 验证SOCKS5连接
            if (!testTcpConnection("127.0.0.1", socksPort, 2000, "SOCKS5")) {
                VpnFileLogger.e(TAG, "SOCKS5端口验证失败")
                return@withContext
            }
            
            // 只在启用虚拟DNS时测试本地DNS服务
            if (enableVirtualDns && localDnsPort > 0) {
                if (!testTcpConnection("127.0.0.1", localDnsPort, 2000, "虚拟DNS")) {
                    VpnFileLogger.w(TAG, "⚠ 虚拟DNS服务连接失败，但不影响基本代理功能")
                }
            }

            // 测试DNS解析，根据ENABLE_IPV6决定处理方式
            try {
                val testDomain = "www.google.com"
                
                if (ENABLE_IPV6) {
                    // IPv6启用时，获取所有地址
                    val addresses = InetAddress.getAllByName(testDomain)
                    addresses.forEach { addr ->
                        VpnFileLogger.d(TAG, "DNS解析结果: $testDomain -> ${addr.hostAddress} (${if (addr is Inet4Address) "IPv4" else "IPv6"})")
                    }
                    // 优先使用IPv4，但也接受IPv6
                    val addr = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
                    if (addr != null) {
                        VpnFileLogger.i(TAG, "✓ DNS解析成功: $testDomain -> ${addr.hostAddress}")
                    } else {
                        VpnFileLogger.w(TAG, "✗ DNS解析失败: 未找到有效地址")
                    }
                } else {
                    // IPv6禁用时，只获取IPv4地址
                    val addr = Inet4Address.getByName(testDomain)
                    VpnFileLogger.i(TAG, "✓ DNS解析成功(仅IPv4): $testDomain -> ${addr.hostAddress}")
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "✗ DNS解析失败: ${e.message}")
                // 尝试备用域名
                try {
                    val fallbackDomain = "example.com"
                    if (ENABLE_IPV6) {
                        val fallbackAddresses = InetAddress.getAllByName(fallbackDomain)
                        val fallbackAddr = fallbackAddresses.firstOrNull { it is Inet4Address } ?: fallbackAddresses.firstOrNull()
                        if (fallbackAddr != null) {
                            VpnFileLogger.i(TAG, "✓ DNS解析成功(备用): $fallbackDomain -> ${fallbackAddr.hostAddress}")
                        }
                    } else {
                        val fallbackAddr = Inet4Address.getByName(fallbackDomain)
                        VpnFileLogger.i(TAG, "✓ DNS解析成功(备用,仅IPv4): $fallbackDomain -> ${fallbackAddr.hostAddress}")
                    }
                } catch (e2: Exception) {
                    VpnFileLogger.e(TAG, "✗ DNS解析失败(备用): ${e2.message}")
                    return@withContext
                }
            }

            // 测试HTTP连接，使用SOCKS代理
            try {
                val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", socksPort))
                val testUrl = URL("http://www.google.com/generate_204") // 使用专为测试设计的端点
                val connection = testUrl.openConnection(proxy) as HttpURLConnection
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.instanceFollowRedirects = false
                connection.setRequestProperty("User-Agent", "V2Ray-Test")
                
                val responseCode = withContext(Dispatchers.IO) {
                    connection.responseCode
                }
                
                if (responseCode == 204 || responseCode == 200) {
                    VpnFileLogger.i(TAG, "✓ HTTP连接测试成功，响应码: $responseCode")
                } else {
                    VpnFileLogger.w(TAG, "✗ HTTP连接测试异常，响应码: $responseCode")
                    return@withContext
                }
                connection.disconnect()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "✗ HTTP连接测试失败: ${e.message}")
                return@withContext
            }

            VpnFileLogger.i(TAG, "===== tun2socks转发验证完成 - 全部测试通过 =====")
            VpnFileLogger.i(TAG, "IPv6支持: ${if (ENABLE_IPV6) "已启用" else "已禁用"}")
            if (enableVirtualDns && localDnsPort > 0) {
                VpnFileLogger.i(TAG, "✓ 虚拟DNS服务运行正常，DNS防泄露已启用")
            } else {
                VpnFileLogger.i(TAG, "✓ 使用公共DNS服务器（8.8.8.8, 1.1.1.1）")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "验证过程出现异常", e)
        }
    }
    
    /**
     * 检查是否应该重启tun2socks
     */
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
     * 优化3: 重启tun2socks进程 - 改进的重启逻辑
     */
    private fun restartTun2socks() {
        try {
            tun2socksRestartCount++
            VpnFileLogger.d(TAG, "重启tun2socks，第${tun2socksRestartCount}次尝试")
            
            // 先停止当前进程
            stopTun2socks()
            
            // 等待一下，确保资源释放
            Thread.sleep(1000)
            
            // 检查VPN接口是否还有效
            if (mInterface == null || mInterface?.fileDescriptor == null) {
                VpnFileLogger.e(TAG, "VPN接口无效，无法重启tun2socks")
                stopV2Ray()
                return
            }
            
            // 重新启动
            runTun2socks()
            
            VpnFileLogger.i(TAG, "tun2socks重启成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "重启tun2socks失败", e)
            stopV2Ray()
        }
    }
    
    /**
     * 停止tun2socks进程
     * 改进：正确清理监控线程
     */
    private fun stopTun2socks() {
        VpnFileLogger.d(TAG, "停止tun2socks进程")
        
        tun2socksRestartCount = 0
        tun2socksFirstRestartTime = 0L
        
        // 停止监控线程
        try {
            tun2socksMonitorThread?.interrupt()
            tun2socksMonitorThread = null
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "中断监控线程失败", e)
        }
        
        // 停止进程
        try {
            process?.let {
                it.destroy()
                // 给进程一点时间优雅退出
                if (!it.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) {
                    // 如果2秒内没有退出，强制终止
                    it.destroyForcibly()
                }
                process = null
                VpnFileLogger.d(TAG, "tun2socks进程已停止")
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止tun2socks进程失败", e)
        }
    }
    
    /**
     * 启动流量监控
     * 定期查询V2Ray核心的流量统计数据
     * 重要：只统计代理流量（proxy），不统计直连（direct）和屏蔽（block）流量
     * 因为用户关心的是消耗的VPN流量，而不是所有网络流量
     */
    private fun startSimpleTrafficMonitor() {
        VpnFileLogger.d(TAG, "启动流量统计监控（只统计代理流量）")
        
        statsJob?.cancel()
        
        // 初始化流量统计数据
        initializeTrafficStats()
        
        statsJob = serviceScope.launch {
            // 修复：立即执行一次，不要延迟
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
    
    /**
     * 🎯 新增：初始化流量统计数据
     */
    private fun initializeTrafficStats() {
        // 初始化累计流量
        totalUploadBytes = 0
        totalDownloadBytes = 0
        
        // 初始化系统流量统计基准值（备用方案）
        try {
            val uid = android.os.Process.myUid()
            initialUploadBytes = android.net.TrafficStats.getUidTxBytes(uid)
            initialDownloadBytes = android.net.TrafficStats.getUidRxBytes(uid)
            VpnFileLogger.d(TAG, "系统流量基准值: ↑${formatBytes(initialUploadBytes ?: 0)} ↓${formatBytes(initialDownloadBytes ?: 0)}")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "获取系统流量基准值失败", e)
        }
    }
    
    /**
     * 🎯 新增：获取代理流量数据
     */
    private fun getProxyTrafficData(): Pair<Long, Long> {
        var newUpload = 0L
        var newDownload = 0L
        
        // 修复：只遍历代理outbound标签查询流量
        for (tag in outboundTags) {
            // 查询上行流量 - queryStats会返回自上次查询以来的增量并重置计数器
            val uplink = coreController?.queryStats(tag, "uplink") ?: 0L
            // 查询下行流量 - queryStats会返回自上次查询以来的增量并重置计数器
            val downlink = coreController?.queryStats(tag, "downlink") ?: 0L
            
            // 安全检查：忽略负值
            if (uplink < 0 || downlink < 0) {
                VpnFileLogger.w(TAG, "异常流量值 [$tag]: ↑$uplink ↓$downlink")
                continue
            }
            
            newUpload += uplink
            newDownload += downlink
            
            if (uplink > 0 || downlink > 0) {
                VpnFileLogger.d(TAG, "代理标签[$tag] 新增流量: ↑${formatBytes(uplink)} ↓${formatBytes(downlink)}")
            }
        }
        
        return Pair(newUpload, newDownload)
    }
    
    /**
     * 🎯 新增：计算流量速度
     */
    private fun calculateTrafficSpeed(newUpload: Long, newDownload: Long) {
        val currentTime = System.currentTimeMillis()
        val timeDiff = (currentTime - lastStatsTime) / 1000.0
        
        if (timeDiff > 0 && lastStatsTime > 0) {
            uploadSpeed = (newUpload / timeDiff).toLong()
            downloadSpeed = (newDownload / timeDiff).toLong()
            
            // 防止负数速度
            if (uploadSpeed < 0) uploadSpeed = 0
            if (downloadSpeed < 0) downloadSpeed = 0
        }
        
        lastStatsTime = currentTime
    }
    
    /**
     * 🎯 新增：使用系统流量作为备用方案
     */
    private fun fallbackToSystemTraffic() {
        try {
            // 可以尝试使用Android系统的TrafficStats API作为备用
            // 但这只能获取整个应用的流量，不够精确
            val uid = android.os.Process.myUid()
            val sysUpload = android.net.TrafficStats.getUidTxBytes(uid)
            val sysDownload = android.net.TrafficStats.getUidRxBytes(uid)
            
            if (sysUpload != android.net.TrafficStats.UNSUPPORTED.toLong() &&
                sysDownload != android.net.TrafficStats.UNSUPPORTED.toLong()) {
                
                // 使用系统流量数据（从服务启动开始计算增量）
                if (startTime > 0) {
                    // 第一次记录初始值
                    if (initialUploadBytes == null) {
                        initialUploadBytes = sysUpload
                        initialDownloadBytes = sysDownload
                        VpnFileLogger.d(TAG, "记录系统流量初始值: ↑${formatBytes(sysUpload)} ↓${formatBytes(sysDownload)}")
                    }
                    
                    // 计算增量
                    uploadBytes = sysUpload - (initialUploadBytes ?: sysUpload)
                    downloadBytes = sysDownload - (initialDownloadBytes ?: sysDownload)
                    
                    VpnFileLogger.d(TAG, "备用流量统计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}")
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "备用流量统计也失败", e)
        }
    }
    
    /**
     * 🎯 重构：分解复杂的流量统计更新方法
     * 修复：真实的流量统计更新 - 只统计代理流量
     * 使用libv2ray.aar的queryStats方法获取实际代理流量数据
     * 
     * 重要说明：
     * - 只统计proxy等代理标签的流量（用户实际消耗的VPN流量）
     * - 不统计direct标签（直连国内网站，不消耗VPN流量）
     * - 不统计block标签（广告屏蔽，本地拦截）
     * - 不统计fragment相关标签（技术实现用途）
     */
    private fun updateTrafficStats() {
        try {
            // 获取代理流量数据
            val (newUpload, newDownload) = getProxyTrafficData()
            
            // 修复：累加到总流量（因为queryStats会重置计数器）
            totalUploadBytes += newUpload
            totalDownloadBytes += newDownload
            
            // 计算速度
            calculateTrafficSpeed(newUpload, newDownload)
            
            // 修复：更新显示值为累计流量
            uploadBytes = totalUploadBytes
            downloadBytes = totalDownloadBytes
            
            // 更新通知栏显示（显示总流量）
            if (enableAutoStats) {
                updateNotification()
            }
            
            // 只在流量有变化时记录日志
            if (newUpload > 0 || newDownload > 0) {
                VpnFileLogger.d(TAG, "代理流量更新 - 本次增量: ↑${formatBytes(newUpload)} ↓${formatBytes(newDownload)}, " +
                        "累计代理流量: ↑${formatBytes(totalUploadBytes)} ↓${formatBytes(totalDownloadBytes)}, " +
                        "速度: ↑${formatBytes(uploadSpeed)}/s ↓${formatBytes(downloadSpeed)}/s")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "查询流量统计失败，使用备用方案", e)
            fallbackToSystemTraffic()
        }
    }
    
    /**
     * 获取当前流量统计（供dart端查询）
     * 返回当前的代理流量数据（不包含直连流量）
     * 修复：返回累计流量而不是瞬时值
     */
    fun getCurrentTrafficStats(): Map<String, Long> {
        // 如果服务正在运行，尝试更新一次最新数据
        if (currentState == V2RayState.CONNECTED && coreController != null) {
            try {
                // 不执行查询，直接返回缓存值，避免重置计数器
                VpnFileLogger.d(TAG, "返回缓存代理流量统计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "获取流量统计异常，返回缓存数据", e)
            }
        }
        
        return mapOf(
            "uploadTotal" to uploadBytes,      // 累计代理上传流量
            "downloadTotal" to downloadBytes,  // 累计代理下载流量
            "uploadSpeed" to uploadSpeed,      // 当前上传速度
            "downloadSpeed" to downloadSpeed,  // 当前下载速度
            "startTime" to startTime           // 连接开始时间
        )
    }
    
    /**
     * 停止V2Ray服务
     */
    private fun stopV2Ray() {
        VpnFileLogger.d(TAG, "开始停止V2Ray服务")
        
        currentState = V2RayState.DISCONNECTED
        
        // 停止流量统计
        statsJob?.cancel()
        statsJob = null
        
        // 停止连接检查
        connectionCheckJob?.cancel()
        connectionCheckJob = null
        
        // 停止验证任务
        verificationJob?.cancel()
        verificationJob = null
        
        // 清理 startupLatch
        startupLatch = null
        
        // 通知MainActivity服务已停止
        sendBroadcast(Intent(ACTION_VPN_STOPPED))
        VpnFileLogger.d(TAG, "已发送VPN停止广播")
        
        // 注销网络回调（Android P及以上）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                defaultNetworkCallback?.let {
                    val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    connectivityManager.unregisterNetworkCallback(it)
                    VpnFileLogger.d(TAG, "网络回调已注销")
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
            VpnFileLogger.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
        }
        
        // 重要：stopSelf必须在mInterface.close()之前调用
        // v2rayNG的注释：stopSelf has to be called ahead of mInterface.close(). 
        // otherwise v2ray core cannot be stopped. It's strange but true.
        stopForeground(true)
        stopSelf()
        VpnFileLogger.d(TAG, "服务已停止")
        
        // 关闭VPN接口（在stopSelf之后）
        try {
            mInterface?.close()
            mInterface = null
            VpnFileLogger.d(TAG, "VPN接口已关闭")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
        }
        
        // 释放WakeLock
        releaseWakeLock()
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止")
    }
    
    /**
     * 获取应用图标资源ID
     */
    private fun getAppIconResource(): Int {
        return try {
            packageManager.getApplicationInfo(packageName, 0).icon
        } catch (e: Exception) {
            android.R.drawable.ic_dialog_info
        }
    }
    
    /**
     * 格式化流量统计用于通知显示
     * 修复：显示总流量而不是速度
     */
    private fun formatTrafficStatsForNotification(upload: Long, download: Long): String {
        val template = instanceLocalizedStrings["trafficStatsFormat"] ?: "流量: ↑%upload ↓%download"
        return template
            .replace("%upload", formatBytes(upload))
            .replace("%download", formatBytes(download))
    }
    
    /**
     * 🎯 重构：统一的通知更新方法
     * 修复：确保显示总流量
     */
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
    
    // ===== CoreCallbackHandler 接口实现 - 优化版 =====
    
    /**
     * 修复2：V2Ray核心启动完成回调
     * 此时配置已经验证成功（因为V2Ray成功启动了）
     * 
     * 修复：使用安全调用 startupLatch?.complete() 并防止重复调用
     */
    override fun startup(): Long {
        VpnFileLogger.d(TAG, "========== CoreCallbackHandler.startup() 被调用 ==========")
        VpnFileLogger.i(TAG, "V2Ray核心启动完成通知（配置验证成功）")
        
        // 立即查询一次状态以验证
        try {
            val isRunning = coreController?.isRunning ?: false
            VpnFileLogger.d(TAG, "V2Ray核心运行状态(在startup回调中): $isRunning")
            
            // 设置启动成功标志
            v2rayCoreStarted = true
            
            // 修复：安全地完成 startupLatch，防止重复调用
            try {
                startupLatch?.let { latch ->
                    if (!latch.isCompleted) {
                        latch.complete(true)
                        VpnFileLogger.d(TAG, "startupLatch 已完成")
                    } else {
                        VpnFileLogger.w(TAG, "startupLatch 已经完成，忽略重复调用")
                    }
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "完成 startupLatch 时出现异常（可能是重复调用）", e)
            }
            
            // 验证端口监听状态
            verifyV2RayPortsListening()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "查询V2Ray状态失败", e)
            // 修复：使用安全调用
            try {
                startupLatch?.let { latch ->
                    if (!latch.isCompleted) {
                        latch.complete(false)
                    }
                }
            } catch (ignored: Exception) {
                // 忽略重复 complete 的异常
            }
        }
        
        return 0L
    }
    
    /**
     * 验证V2Ray端口监听状态（简化版）
     * 在startup回调中执行，确认各个服务端口正常监听
     */
    private fun verifyV2RayPortsListening() {
        serviceScope.launch {
            delay(500)  // 稍等片刻让端口完全就绪
            
            try {
                VpnFileLogger.d(TAG, "===== 验证V2Ray端口监听状态 =====")
                
                // 验证SOCKS端口
                val socksPort = extractInboundPort("socks", DEFAULT_SOCKS_PORT)
                testTcpConnection("127.0.0.1", socksPort, 2000, "SOCKS5")
                
                // 验证HTTP端口（如果存在）
                val httpPort = extractInboundPort("http", -1)
                if (httpPort > 0) {
                    testTcpConnection("127.0.0.1", httpPort, 2000, "HTTP")
                }
                
                // 验证虚拟DNS端口（如果启用）
                if (enableVirtualDns && localDnsPort > 0) {
                    testTcpConnection("127.0.0.1", localDnsPort, 2000, "虚拟DNS")
                }
                
                // 验证API端口（如果存在）
                val apiPort = extractInboundPort("api", -1)
                if (apiPort > 0) {
                    testTcpConnection("127.0.0.1", apiPort, 2000, "API")
                }
                
                VpnFileLogger.i(TAG, "===== V2Ray端口验证完成 =====")
                
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "V2Ray端口验证异常", e)
            }
        }
    }
    
    override fun shutdown(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.shutdown() 被调用")
        
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
            
            // 记录所有V2Ray日志
            VpnFileLogger.d(TAG, "[V2Ray-$levelName] $status")
            
            // 对重要事件使用不同的日志级别
            if (status != null) {
                when {
                    // 配置错误检测
                    status.contains("config", ignoreCase = true) && 
                    (status.contains("failed", ignoreCase = true) || 
                     status.contains("error", ignoreCase = true) ||
                     status.contains("invalid", ignoreCase = true)) -> {
                        VpnFileLogger.e(TAG, "[V2Ray配置错误] $status")
                    }
                    
                    // 一般错误
                    status.contains("failed", ignoreCase = true) || 
                    status.contains("error", ignoreCase = true) -> {
                        VpnFileLogger.e(TAG, "[V2Ray错误] $status")
                        
                        // 特别检查 geo 文件相关错误
                        if (status.contains("geoip", ignoreCase = true) || 
                            status.contains("geosite", ignoreCase = true)) {
                            VpnFileLogger.e(TAG, "[V2Ray geo文件错误] $status")
                            VpnFileLogger.e(TAG, "请检查geoip.dat和geosite.dat文件是否存在")
                        }
                        
                        // 检查端口占用
                        if (status.contains("address already in use", ignoreCase = true) ||
                            status.contains("bind", ignoreCase = true)) {
                            VpnFileLogger.e(TAG, "[V2Ray端口占用] $status")
                            VpnFileLogger.e(TAG, "端口可能被其他程序占用，请检查配置")
                        }
                        
                        // 检查JSON错误
                        if (status.contains("json", ignoreCase = true) ||
                            status.contains("parse", ignoreCase = true)) {
                            VpnFileLogger.e(TAG, "[V2Ray JSON解析错误] $status")
                            VpnFileLogger.e(TAG, "配置文件JSON格式有误，请检查")
                        }
                    }
                    
                    // 警告
                    status.contains("warning", ignoreCase = true) -> {
                        VpnFileLogger.w(TAG, "[V2Ray警告] $status")
                    }
                    
                    // 重要信息
                    status.contains("started", ignoreCase = true) ||
                    status.contains("listening", ignoreCase = true) ||
                    status.contains("accepted", ignoreCase = true) ||
                    status.contains("connection", ignoreCase = true) -> {
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
    
    // ===== 工具方法 =====
    
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
     * 服务销毁时调用
     */
    override fun onDestroy() {
        super.onDestroy()
        
        VpnFileLogger.d(TAG, "onDestroy开始")
        
        instanceRef?.clear()
        instanceRef = null
        
        serviceScope.cancel()
        
        try {
            unregisterReceiver(stopReceiver)
            VpnFileLogger.d(TAG, "广播接收器已注销")
        } catch (e: Exception) {
            // 可能已经注销
        }
        
        if (currentState != V2RayState.DISCONNECTED) {
            VpnFileLogger.d(TAG, "onDestroy时服务仍在运行,执行清理")
            
            currentState = V2RayState.DISCONNECTED
            
            statsJob?.cancel()
            statsJob = null
            
            connectionCheckJob?.cancel()
            connectionCheckJob = null
            
            verificationJob?.cancel()
            verificationJob = null
            
            // 清理 startupLatch
            startupLatch = null
            
            // 注销网络回调
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    defaultNetworkCallback?.let {
                        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        connectivityManager.unregisterNetworkCallback(it)
                        VpnFileLogger.d(TAG, "网络回调已注销(onDestroy)")
                    }
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "注销网络回调失败(onDestroy)", e)
                }
                defaultNetworkCallback = null
            }
            
            // 停止tun2socks监控线程
            try {
                tun2socksMonitorThread?.interrupt()
                tun2socksMonitorThread = null
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "中断监控线程失败(onDestroy)", e)
            }
            
            stopTun2socks()
            
            try {
                coreController?.stopLoop()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
            }
            
            // 确保mInterface在最后关闭
            try {
                mInterface?.close()
                mInterface = null
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
            }
        }
        
        coreController = null
        
        // 释放WakeLock
        releaseWakeLock()
        
        VpnFileLogger.d(TAG, "onDestroy完成,服务已销毁")
        
        runBlocking {
            VpnFileLogger.flushAll()
        }
        VpnFileLogger.close()
    }
}
