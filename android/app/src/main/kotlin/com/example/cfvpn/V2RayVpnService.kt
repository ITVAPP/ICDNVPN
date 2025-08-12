package com.example.cfvpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileDescriptor
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.lang.ref.WeakReference

// 正确的导入(基于method_summary.md)
import go.Seq
import libv2ray.Libv2ray
import libv2ray.CoreController
import libv2ray.CoreCallbackHandler

/**
 * V2Ray VPN服务实现 - 优化版
 * 
 * 主要修复:
 * 1. 修正流量统计queryStats参数格式
 * 2. 流量统计改为按需查询,避免性能问题
 * 3. 提供手动和自动两种统计模式
 * 4. 修正CoreCallbackHandler实现
 * 5. 增强错误处理和容错能力
 * 6. 修复：使用WeakReference避免内存泄漏
 * 7. 修复：添加tun2socks重启次数限制
 * 
 * 功能特性:
 * - 完善的流量统计(可配置更新频率)
 * - 配置自动增强(添加stats配置)
 * - 分应用代理支持
 * - 子网绕过功能
 * - 服务器延迟测试
 * - 自动重启tun2socks(带限制)
 */
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    // 连接模式枚举(参考开源项目)
    enum class ConnectionMode {
        VPN_TUN,        // VPN隧道模式(全局)
        PROXY_ONLY      // 仅代理模式(局部,不创建VPN)
    }
    
    // 连接状态枚举(参考开源项目)
    enum class V2RayState {
        DISCONNECTED,
        CONNECTING,
        CONNECTED
    }
    
    // 应用代理模式
    enum class AppProxyMode {
        EXCLUDE,    // 排除模式:指定的应用不走代理
        INCLUDE     // 包含模式:仅指定的应用走代理
    }
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        
        // 新增:VPN启动结果广播
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        
        // 新增：VPN停止通知广播（通知MainActivity）
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"
        
        // VPN配置常量
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"    // VPN接口地址
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"    // tun2socks使用的地址
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        
        // V2Ray端口默认值
        private const val DEFAULT_SOCKS_PORT = 7898
        private const val DEFAULT_HTTP_PORT = 7899
        
        // 流量统计配置
        private const val STATS_UPDATE_INTERVAL = 10000L  // 10秒更新一次
        private const val ENABLE_AUTO_STATS = true       // 默认开启自动统计
        
        // 修复：tun2socks重启限制
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3  // 最大重启次数
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L  // 重启计数重置间隔(1分钟)
        
        // 服务状态
        @Volatile
        private var currentState: V2RayState = V2RayState.DISCONNECTED
        
        // 修复：使用WeakReference避免内存泄漏
        @Volatile
        private var instanceRef: WeakReference<V2RayVpnService>? = null
        
        // 通知按钮文本(可配置)
        private var notificationDisconnectButtonName = "停止"
        
        // 新增：国际化文字存储
        private var localizedStrings = mutableMapOf<String, String>()
        
        /**
         * 获取服务实例（使用WeakReference避免泄漏）
         */
        private val instance: V2RayVpnService?
            get() = instanceRef?.get()
        
        /**
         * 检查服务是否运行 - 只保留一个定义
         */
        @JvmStatic
        fun isServiceRunning(): Boolean = currentState == V2RayState.CONNECTED
        
        /**
         * 启动VPN服务(增强版，支持国际化)
         */
        @JvmStatic
        fun startVpnService(
            context: Context, 
            config: String,
            mode: ConnectionMode = ConnectionMode.VPN_TUN,
            globalProxy: Boolean = false,
            blockedApps: List<String>? = null,
            allowedApps: List<String>? = null,  // 新增:包含模式应用列表
            appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE,  // 新增:应用代理模式
            bypassSubnets: List<String>? = null,
            enableAutoStats: Boolean = ENABLE_AUTO_STATS,
            disconnectButtonName: String = "停止",  // 可配置的按钮文本
            localizedStrings: Map<String, String> = emptyMap()  // 新增：国际化文字
        ) {
            VpnFileLogger.d(TAG, "准备启动服务,模式: $mode, 全局代理: $globalProxy, 自动统计: $enableAutoStats")
            
            notificationDisconnectButtonName = disconnectButtonName
            
            // 保存国际化文字
            this.localizedStrings.clear()
            this.localizedStrings.putAll(localizedStrings)
            
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN"
                putExtra("config", config)
                putExtra("mode", mode.name)
                putExtra("globalProxy", globalProxy)
                putExtra("enableAutoStats", enableAutoStats)
                putExtra("appProxyMode", appProxyMode.name)
                putStringArrayListExtra("blockedApps", ArrayList(blockedApps ?: emptyList()))
                putStringArrayListExtra("allowedApps", ArrayList(allowedApps ?: emptyList()))
                putStringArrayListExtra("bypassSubnets", ArrayList(bypassSubnets ?: emptyList()))
                putExtra("disconnectButtonName", disconnectButtonName)
                
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
         * 获取流量统计(按需查询,不影响性能)
         */
        @JvmStatic
        fun getTrafficStats(): Map<String, Long> {
            // 如果没有启用自动统计,这里实时查询一次
            instance?.updateTrafficStatsOnDemand()
            return instance?.getCurrentTrafficStats() ?: mapOf(
                "uploadTotal" to 0L,
                "downloadTotal" to 0L,
                "uploadSpeed" to 0L,
                "downloadSpeed" to 0L
            )
        }
        
        /**
         * 测试已连接服务器延迟
         */
        @JvmStatic
        suspend fun testConnectedDelay(testUrl: String = "https://www.google.com/generate_204"): Long {
            return instance?.measureConnectedDelay(testUrl) ?: -1L
        }
        
        /**
         * 测试服务器延迟(未连接状态)
         * 参考开源项目的实现
         */
        @JvmStatic
        suspend fun testServerDelay(config: String, testUrl: String = "https://www.google.com/generate_204"): Long {
            return withContext(Dispatchers.IO) {
                try {
                    // 修改配置移除不必要的路由规则
                    val testConfig = try {
                        val configJson = JSONObject(config)
                        if (configJson.has("routing")) {
                            val routing = configJson.getJSONObject("routing")
                            routing.remove("rules")
                            configJson.put("routing", routing)
                        }
                        configJson.toString()
                    } catch (e: Exception) {
                        VpnFileLogger.w(TAG, "修改测试配置失败,使用原始配置", e)
                        config
                    }
                    
                    // 使用libv2ray的measureOutboundDelay方法
                    try {
                        val delay = Libv2ray.measureOutboundDelay(testConfig, testUrl)
                        VpnFileLogger.d(TAG, "服务器延迟测试结果: ${delay}ms")
                        delay
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "measureOutboundDelay调用失败", e)
                        -1L
                    }
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "测试服务器延迟失败", e)
                    -1L
                }
            }
        }
    }
    
    // ===== 内部类:配置解析器 =====
    private data class V2rayConfig(
        val originalConfig: String,
        val enhancedConfig: String,
        val serverAddress: String,
        val serverPort: Int,
        val localSocks5Port: Int,
        val localHttpPort: Int,
        val enableTrafficStats: Boolean,
        val dnsServers: List<String>,
        val remark: String = "CFVPN"
    )
    
    // V2Ray核心控制器
    private var coreController: CoreController? = null
    
    // VPN接口文件描述符
    private var mInterface: ParcelFileDescriptor? = null
    
    // tun2socks进程
    private var tun2socksProcess: java.lang.Process? = null
    
    // 修复：tun2socks重启控制
    private var tun2socksRestartCount = 0  // 重启计数
    private var tun2socksFirstRestartTime = 0L  // 第一次重启时间
    
    // 配置信息
    private var v2rayConfig: V2rayConfig? = null
    private var mode: ConnectionMode = ConnectionMode.VPN_TUN
    private var globalProxy: Boolean = false
    private var blockedApps: List<String> = emptyList()
    private var allowedApps: List<String> = emptyList()
    private var appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE
    private var bypassSubnets: List<String> = emptyList()
    private var enableAutoStats: Boolean = ENABLE_AUTO_STATS
    private var disconnectButtonName: String = "停止"
    
    // 新增：实例级的国际化文字存储
    private val instanceLocalizedStrings = mutableMapOf<String, String>()
    
    // 协程作用域
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计数据
    private var uploadBytes: Long = 0      // 上传总字节数
    private var downloadBytes: Long = 0    // 下载总字节数
    private var lastUploadTotal: Long = 0  // 上次的上传总量
    private var lastDownloadTotal: Long = 0 // 上次的下载总量
    private var uploadSpeed: Long = 0      // 当前上传速度
    private var downloadSpeed: Long = 0    // 当前下载速度
    private var lastQueryTime: Long = 0    // 上次查询时间
    private var startTime: Long = 0        // 连接开始时间
    private var lastOnDemandUpdateTime: Long = 0  // 修复：上次按需更新时间，用于节流
    
    // 统计任务
    private var statsJob: Job? = null
    
    // 广播接收器
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                VpnFileLogger.d(TAG, "收到停止VPN广播")
                stopV2Ray()
            }
        }
    }
    
    /**
     * 服务创建时调用
     * 初始化Go运行时和V2Ray环境
     */
    override fun onCreate() {
        super.onCreate()
        
        VpnFileLogger.init(applicationContext)
        VpnFileLogger.d(TAG, "VPN服务onCreate开始")
        
        // 修复：使用WeakReference保存实例
        instanceRef = WeakReference(this)
        
        // 步骤1:初始化Go运行时(必须)
        try {
            Seq.setContext(applicationContext)
            VpnFileLogger.d(TAG, "Go运行时初始化成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "Go运行时初始化失败", e)
            stopSelf()
            return
        }
        
        // 步骤2:注册广播接收器
        try {
            registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
            VpnFileLogger.d(TAG, "广播接收器注册成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "注册广播接收器失败", e)
        }
        
        // 步骤3:初始化V2Ray环境
        try {
            val envPath = filesDir.absolutePath
            // 根据method_summary.md,initCoreEnv接受两个String参数
            Libv2ray.initCoreEnv(envPath, "")
            VpnFileLogger.d(TAG, "V2Ray环境初始化成功: $envPath")
            
            // 获取版本信息
            val version = Libv2ray.checkVersionX()
            VpnFileLogger.i(TAG, "V2Ray版本: $version")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "V2Ray环境初始化失败", e)
        }
        
        // 步骤4:复制资源文件
        copyAssetFiles()
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成")
    }
    
    /**
     * 服务启动命令
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnFileLogger.d(TAG, "onStartCommand: action=${intent?.action}")
        
        if (intent == null || intent.action != "START_VPN") {
            VpnFileLogger.w(TAG, "无效的启动意图")
            stopSelf()
            return START_NOT_STICKY
        }
        
        if (currentState == V2RayState.CONNECTED) {
            VpnFileLogger.w(TAG, "VPN服务已在运行")
            return START_STICKY
        }
        
        // 更新状态
        currentState = V2RayState.CONNECTING
        
        // 获取配置
        val configContent = intent.getStringExtra("config") ?: ""
        mode = try {
            ConnectionMode.valueOf(intent.getStringExtra("mode") ?: ConnectionMode.VPN_TUN.name)
        } catch (e: Exception) {
            ConnectionMode.VPN_TUN
        }
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        enableAutoStats = intent.getBooleanExtra("enableAutoStats", ENABLE_AUTO_STATS)
        appProxyMode = try {
            AppProxyMode.valueOf(intent.getStringExtra("appProxyMode") ?: AppProxyMode.EXCLUDE.name)
        } catch (e: Exception) {
            AppProxyMode.EXCLUDE
        }
        blockedApps = intent.getStringArrayListExtra("blockedApps") ?: emptyList()
        allowedApps = intent.getStringArrayListExtra("allowedApps") ?: emptyList()
        bypassSubnets = intent.getStringArrayListExtra("bypassSubnets") ?: emptyList()
        disconnectButtonName = intent.getStringExtra("disconnectButtonName") ?: "停止"
        
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
        
        if (configContent.isEmpty()) {
            VpnFileLogger.e(TAG, "配置为空")
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "配置为空")  // 新增:发送失败广播
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 记录完整配置（开发环境调试用，生产环境应关闭日志）
        VpnFileLogger.d(TAG, "=====V2Ray完整配置开始=====")
        VpnFileLogger.d(TAG, configContent)
        VpnFileLogger.d(TAG, "=====V2Ray完整配置结束=====")
        VpnFileLogger.d(TAG, "配置参数: 模式=$mode, 全局代理=$globalProxy, " +
                "排除应用=$blockedApps, 包含应用=$allowedApps, " +
                "代理模式=$appProxyMode, 绕过子网=$bypassSubnets")
        
        // 解析和增强配置
        try {
            v2rayConfig = parseAndEnhanceConfig(configContent)
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "解析配置失败", e)
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "解析配置失败: ${e.message}")  // 新增:发送失败广播
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 启动前台服务
        try {
            val notification = createNotification()
            if (notification != null) {
                startForeground(NOTIFICATION_ID, notification)
                VpnFileLogger.d(TAG, "前台服务已启动")
            } else {
                VpnFileLogger.e(TAG, "无法创建通知,服务可能被系统终止")
                currentState = V2RayState.DISCONNECTED
                sendStartResultBroadcast(false, "无法创建通知")  // 新增:发送失败广播
                stopSelf()
                return START_NOT_STICKY
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动前台服务失败", e)
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "启动前台服务失败: ${e.message}")  // 新增:发送失败广播
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 根据模式启动
        serviceScope.launch {
            try {
                when (mode) {
                    ConnectionMode.VPN_TUN -> startV2RayWithVPN()
                    ConnectionMode.PROXY_ONLY -> startV2RayProxyOnly()
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动失败", e)
                currentState = V2RayState.DISCONNECTED
                sendStartResultBroadcast(false, "启动失败: ${e.message}")  // 新增:发送失败广播
                withContext(Dispatchers.Main) {
                    stopSelf()
                }
            }
        }
        
        return START_STICKY
    }
    
    /**
     * 解析和增强V2Ray配置
     * 增强容错:解析失败时使用原始配置
     */
    private fun parseAndEnhanceConfig(originalConfig: String): V2rayConfig {
        VpnFileLogger.d(TAG, "开始解析和增强配置")
        
        return try {
            val configJson = JSONObject(originalConfig)
            
            // 提取服务器信息(容错处理)
            var serverAddress = ""
            var serverPort = 0
            
            try {
                // 尝试从vnext提取(VMess等协议)
                val vnext = configJson.getJSONArray("outbounds")
                    .getJSONObject(0)
                    .getJSONObject("settings")
                    .getJSONArray("vnext")
                    .getJSONObject(0)
                
                serverAddress = vnext.getString("address")
                serverPort = vnext.getInt("port")
            } catch (e: Exception) {
                // 尝试从servers提取(Shadowsocks等协议)
                try {
                    val servers = configJson.getJSONArray("outbounds")
                        .getJSONObject(0)
                        .getJSONObject("settings")
                        .getJSONArray("servers")
                        .getJSONObject(0)
                    
                    serverAddress = servers.getString("address")
                    serverPort = servers.getInt("port")
                } catch (e2: Exception) {
                    VpnFileLogger.w(TAG, "无法提取服务器信息,使用默认值", e2)
                }
            }
            
            // 提取端口信息(容错处理)
            var socksPort = DEFAULT_SOCKS_PORT
            var httpPort = DEFAULT_HTTP_PORT
            
            try {
                val inbounds = configJson.getJSONArray("inbounds")
                for (i in 0 until inbounds.length()) {
                    val inbound = inbounds.getJSONObject(i)
                    when (inbound.optString("protocol", "")) {
                        "socks" -> socksPort = inbound.optInt("port", DEFAULT_SOCKS_PORT)
                        "http" -> httpPort = inbound.optInt("port", DEFAULT_HTTP_PORT)
                    }
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "提取端口失败,使用默认值", e)
            }
            
            // 提取DNS服务器(容错处理) - 修复:过滤掉非IP格式的DNS
            val dnsServers = mutableListOf<String>()
            try {
                val dns = configJson.optJSONObject("dns")
                val serversArray = dns?.optJSONArray("servers")
                if (serversArray != null) {
                    for (i in 0 until serversArray.length()) {
                        when (val server = serversArray.get(i)) {
                            is String -> {
                                // 检查是否为IP格式
                                if (isValidIpAddress(server)) {
                                    dnsServers.add(server)
                                } else {
                                    VpnFileLogger.d(TAG, "跳过非IP格式DNS: $server")
                                }
                            }
                            is JSONObject -> {
                                server.optString("address")?.let { addr ->
                                    if (addr.isNotEmpty() && isValidIpAddress(addr)) {
                                        dnsServers.add(addr)
                                    } else if (addr.isNotEmpty()) {
                                        VpnFileLogger.d(TAG, "跳过非IP格式DNS: $addr")
                                    }
                                    Unit  // 修复：明确这是语句块，不是表达式
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "提取DNS失败,使用默认值", e)
            }
            
            // 如果没有DNS,使用默认值
            if (dnsServers.isEmpty()) {
                dnsServers.addAll(listOf("8.8.8.8", "8.8.4.4", "1.1.1.1"))
            }
            
            // 添加流量统计配置(参考开源项目)
            val enableTrafficStats = true
            if (enableTrafficStats) {
                try {
                    // 移除旧的配置
                    configJson.remove("policy")
                    configJson.remove("stats")
                    
                    // 添加新的policy配置
                    val policy = JSONObject().apply {
                        put("levels", JSONObject().apply {
                            put("8", JSONObject().apply {
                                put("connIdle", 300)
                                put("downlinkOnly", 1)
                                put("handshake", 4)
                                put("uplinkOnly", 1)
                            })
                        })
                        put("system", JSONObject().apply {
                            put("statsOutboundUplink", true)
                            put("statsOutboundDownlink", true)
                        })
                    }
                    
                    configJson.put("policy", policy)
                    configJson.put("stats", JSONObject())
                    
                    VpnFileLogger.d(TAG, "已添加流量统计配置")
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "添加流量统计配置失败", e)
                }
            }
            
            V2rayConfig(
                originalConfig = originalConfig,
                enhancedConfig = configJson.toString(),
                serverAddress = serverAddress,
                serverPort = serverPort,
                localSocks5Port = socksPort,
                localHttpPort = httpPort,
                enableTrafficStats = enableTrafficStats,
                dnsServers = dnsServers,
                remark = instanceLocalizedStrings["appName"] ?: "CFVPN"
            ).also {
                // 记录解析后的关键信息（方便排查问题）
                VpnFileLogger.i(TAG, "配置解析成功: " +
                    "服务器=$serverAddress:$serverPort, " +
                    "SOCKS5端口=$socksPort, HTTP端口=$httpPort, " +
                    "DNS=${dnsServers.joinToString(",")}, " +
                    "流量统计=${if (enableTrafficStats) "启用" else "禁用"}")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "解析配置失败,使用原始配置", e)
            // 返回最小配置,使用原始JSON
            V2rayConfig(
                originalConfig = originalConfig,
                enhancedConfig = originalConfig,  // 使用原始配置
                serverAddress = "",
                serverPort = 0,
                localSocks5Port = DEFAULT_SOCKS_PORT,
                localHttpPort = DEFAULT_HTTP_PORT,
                enableTrafficStats = false,
                dnsServers = listOf("8.8.8.8", "8.8.4.4"),
                remark = instanceLocalizedStrings["appName"] ?: "CFVPN"
            )
        }
    }
    
    /**
     * 检查是否为有效的IP地址
     */
    private fun isValidIpAddress(address: String): Boolean {
        // 过滤掉URL格式的地址
        if (address.startsWith("http://") || address.startsWith("https://") || 
            address.startsWith("tcp://") || address.startsWith("udp://") ||
            address.contains("://")) {
            return false
        }
        
        // 检查IPv4格式
        if (address.matches(Regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"))) {
            return true
        }
        
        // 检查IPv6格式(简单检查,包含冒号且不包含其他协议标识)
        if (address.contains(":") && !address.contains("://") && !address.contains("/")) {
            return true
        }
        
        return false
    }
    
    /**
     * 复制资源文件到应用目录
     */
    private fun copyAssetFiles() {
        VpnFileLogger.d(TAG, "开始复制资源文件")
        
        val assetDir = filesDir
        if (!assetDir.exists()) {
            if (!assetDir.mkdirs()) {
                VpnFileLogger.e(TAG, "创建资源目录失败")
                return
            }
        }
        
        // geo文件列表
        val files = listOf("geoip.dat", "geoip-only-cn-private.dat", "geosite.dat")
        
        for (fileName in files) {
            try {
                val targetFile = File(assetDir, fileName)
                
                if (shouldUpdateFile(fileName, targetFile)) {
                    copyAssetFile(fileName, targetFile)
                } else {
                    VpnFileLogger.d(TAG, "文件已是最新,跳过: $fileName")
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "处理文件失败: $fileName", e)
                // 继续处理其他文件
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
     * 启动V2Ray(VPN模式)
     * 修复:添加广播通知
     */
    private suspend fun startV2RayWithVPN() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "开始启动V2Ray(VPN模式)")
        
        val config = v2rayConfig ?: throw Exception("配置为空")
        
        try {
            // 步骤1:先建立VPN隧道
            VpnFileLogger.d(TAG, "步骤1: 建立VPN隧道")
            withContext(Dispatchers.Main) {
                establishVpn()
            }
            
            if (mInterface == null) {
                throw Exception("VPN隧道建立失败")
            }
            
            // 步骤2:创建核心控制器
            VpnFileLogger.d(TAG, "步骤2: 创建核心控制器")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败")
            }
            
            // 步骤3:启动V2Ray核心
            VpnFileLogger.d(TAG, "步骤3: 启动V2Ray核心")
            coreController?.startLoop(config.enhancedConfig)
            
            // 步骤4:验证运行状态
            val isRunningNow = coreController?.isRunning ?: false
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行")
            }
            
            VpnFileLogger.i(TAG, "V2Ray核心启动成功,SOCKS5端口: ${config.localSocks5Port}")
            
            // 步骤5:启动tun2socks进程
            VpnFileLogger.d(TAG, "步骤5: 启动tun2socks进程")
            runTun2socks()
            
            // 步骤6:传递文件描述符
            VpnFileLogger.d(TAG, "步骤6: 传递文件描述符")
            val fdSuccess = sendFileDescriptor()
            if (!fdSuccess) {
                throw Exception("文件描述符传递失败")
            }
            
            // 步骤7:更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "V2Ray服务(VPN模式)完全启动成功")
            
            // 新增:发送启动成功广播
            sendStartResultBroadcast(true)
            
            // 步骤8:保存配置用于开机自启动(如果启用)
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        config.originalConfig,
                        mode.name,
                        globalProxy
                    )
                    VpnFileLogger.d(TAG, "已更新自启动配置")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存自启动配置失败", e)
            }
            
            // 步骤9:启动流量监控
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动自动流量统计")
                startTrafficMonitor()
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray(VPN模式)失败: ${e.message}", e)
            cleanupResources()
            
            // 新增:发送启动失败广播
            sendStartResultBroadcast(false, e.message)
            
            throw e
        }
    }
    
    /**
     * 启动V2Ray(仅代理模式)
     * 修复:添加广播通知
     * 参考开源项目的PROXY_ONLY模式
     */
    private suspend fun startV2RayProxyOnly() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "开始启动V2Ray(仅代理模式)")
        
        val config = v2rayConfig ?: throw Exception("配置为空")
        
        try {
            // 仅代理模式不需要建立VPN隧道
            
            // 步骤1:创建核心控制器
            VpnFileLogger.d(TAG, "步骤1: 创建核心控制器")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败")
            }
            
            // 步骤2:启动V2Ray核心
            VpnFileLogger.d(TAG, "步骤2: 启动V2Ray核心")
            coreController?.startLoop(config.enhancedConfig)
            
            // 步骤3:验证运行状态
            val isRunningNow = coreController?.isRunning ?: false
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行")
            }
            
            // 步骤4:更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "V2Ray服务(仅代理模式)启动成功")
            VpnFileLogger.i(TAG, "SOCKS5: 127.0.0.1:${config.localSocks5Port}")
            VpnFileLogger.i(TAG, "HTTP: 127.0.0.1:${config.localHttpPort}")
            
            // 新增:发送启动成功广播
            sendStartResultBroadcast(true)
            
            // 步骤5:保存配置用于开机自启动(如果启用)
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        config.originalConfig,
                        mode.name,
                        globalProxy
                    )
                    VpnFileLogger.d(TAG, "已更新自启动配置")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存自启动配置失败", e)
            }
            
            // 步骤6:启动流量监控
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动自动流量统计")
                startTrafficMonitor()
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray(仅代理模式)失败: ${e.message}", e)
            cleanupResources()
            
            // 新增:发送启动失败广播
            sendStartResultBroadcast(false, e.message)
            
            throw e
        }
    }
    
    /**
     * 新增:发送VPN启动结果广播
     */
    private fun sendStartResultBroadcast(success: Boolean, error: String? = null) {
        try {
            val intent = Intent(ACTION_VPN_START_RESULT).apply {
                putExtra("success", success)
                putExtra("error", error)
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
        stopTun2socks()
        mInterface?.close()
        mInterface = null
        
        try {
            coreController?.stopLoop()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "停止核心异常", e)
        }
        coreController = null
    }
    
    /**
     * 启动V2Ray核心(兼容旧方法名)
     */
    private suspend fun startV2Ray() = startV2RayWithVPN()
    
    /**
     * 建立VPN隧道
     * 支持分应用代理和子网绕过
     */
    private fun establishVpn() {
        VpnFileLogger.d(TAG, "开始建立VPN隧道")
        
        val config = v2rayConfig ?: return
        
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
        builder.setSession(config.remark)
        builder.setMtu(VPN_MTU)
        
        // IPv4地址(/30子网支持tun2socks)
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        VpnFileLogger.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30")
        
        // IPv6地址(可选)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126)
                VpnFileLogger.d(TAG, "添加IPv6地址: $PRIVATE_VLAN6_CLIENT/126")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加IPv6地址失败", e)
            }
        }
        
        // DNS服务器配置 - 修复:已经过滤过了,但还是再检查一次确保安全
        config.dnsServers.forEach { dns ->
            try {
                // 再次验证是否为IP地址
                if (isValidIpAddress(dns)) {
                    builder.addDnsServer(dns)
                    VpnFileLogger.d(TAG, "添加DNS: $dns")
                } else {
                    VpnFileLogger.d(TAG, "跳过非IP格式DNS: $dns")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加DNS失败: $dns", e)
            }
        }
        
        // 路由规则配置
        if (bypassSubnets.isNotEmpty()) {
            VpnFileLogger.d(TAG, "配置子网绕过: $bypassSubnets")
            bypassSubnets.forEach { subnet ->
                try {
                    val parts = subnet.split("/")
                    if (parts.size == 2) {
                        val address = parts[0]
                        val prefixLength = parts[1].toInt()
                        builder.addRoute(address, prefixLength)
                        VpnFileLogger.d(TAG, "添加路由: $address/$prefixLength")
                    }
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "添加路由失败: $subnet", e)
                }
            }
        } else {
            // 默认全局路由
            if (globalProxy) {
                VpnFileLogger.d(TAG, "配置全局代理路由")
                builder.addRoute("0.0.0.0", 0)
                
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    try {
                        builder.addRoute("::", 0)
                        VpnFileLogger.d(TAG, "添加IPv6全局路由")
                    } catch (e: Exception) {
                        VpnFileLogger.w(TAG, "添加IPv6路由失败", e)
                    }
                }
            } else {
                // 智能分流(目前默认全局)
                builder.addRoute("0.0.0.0", 0)
            }
        }
        
        // 分应用代理(Android 5.0+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            when (appProxyMode) {
                AppProxyMode.EXCLUDE -> {
                    // 排除模式:指定的应用不走代理
                    VpnFileLogger.d(TAG, "使用排除模式,用户指定排除${blockedApps.size}个应用")
                    
                    // 始终排除自身,避免VPN循环（这是必须的！）
                    try {
                        builder.addDisallowedApplication(packageName)
                        VpnFileLogger.d(TAG, "自动排除自身应用(防止VPN循环): $packageName")
                    } catch (e: Exception) {
                        VpnFileLogger.w(TAG, "排除自身应用失败", e)
                    }
                    
                    // 排除指定的应用
                    blockedApps.forEach { app ->
                        try {
                            builder.addDisallowedApplication(app)
                            VpnFileLogger.d(TAG, "排除应用: $app")
                        } catch (e: Exception) {
                            VpnFileLogger.w(TAG, "排除应用失败: $app", e)
                        }
                    }
                }
                
                AppProxyMode.INCLUDE -> {
                    // 包含模式:仅指定的应用走代理
                    if (allowedApps.isNotEmpty()) {
                        VpnFileLogger.d(TAG, "使用包含模式,包含${allowedApps.size}个应用")
                        allowedApps.forEach { app ->
                            try {
                                builder.addAllowedApplication(app)
                                VpnFileLogger.d(TAG, "包含应用: $app")
                            } catch (e: Exception) {
                                VpnFileLogger.w(TAG, "包含应用失败: $app", e)
                            }
                        }
                    } else {
                        // 如果没有指定应用,警告并使用默认行为
                        VpnFileLogger.e(TAG, "包含模式但未指定任何应用,VPN将不会路由任何流量!")
                        // 至少包含一个应用,避免VPN完全无效
                        // 可以考虑包含自身或返回错误
                    }
                }
            }
        }
        
        // 建立VPN接口
        mInterface = builder.establish()
        
        if (mInterface == null) {
            VpnFileLogger.e(TAG, "VPN接口建立失败(可能没有权限)")
        } else {
            VpnFileLogger.d(TAG, "VPN隧道建立成功,FD: ${mInterface?.fd}")
        }
    }
    
    /**
     * 启动tun2socks进程(仅VPN模式需要)
     */
    private suspend fun runTun2socks(): Unit = withContext(Dispatchers.IO) {
        // 仅在VPN模式下运行
        if (mode != ConnectionMode.VPN_TUN) {
            VpnFileLogger.d(TAG, "非VPN模式,跳过tun2socks")
            return@withContext
        }
        
        VpnFileLogger.d(TAG, "开始启动tun2socks进程")
        
        val config = v2rayConfig ?: throw Exception("配置为空")
        
        try {
            val libtun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
            
            if (!File(libtun2socksPath).exists()) {
                throw Exception("libtun2socks.so不存在: $libtun2socksPath")
            }
            
            val sockPath = File(filesDir, "sock_path").absolutePath
            
            // 删除旧的套接字文件
            try {
                File(sockPath).delete()
            } catch (e: Exception) {
                // 忽略
            }
            
            // 构建命令行参数
            val cmd = arrayListOf(
                libtun2socksPath,
                "--netif-ipaddr", PRIVATE_VLAN4_ROUTER,
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:${config.localSocks5Port}",
                "--tunmtu", VPN_MTU.toString(),
                "--sock-path", sockPath,
                "--enable-udprelay",
                "--loglevel", "error"
            )
            
            VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
            
            // 启动进程
            val processBuilder = ProcessBuilder(cmd).apply {
                redirectErrorStream(true)
                directory(filesDir)
            }
            
            val process = processBuilder.start()
            tun2socksProcess = process
            
            // 读取进程输出(用于调试) - 修复:优化日志记录
            serviceScope.launch {
                try {
                    process.inputStream?.bufferedReader()?.use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            // 只记录非空的输出
                            if (!line.isNullOrBlank()) {
                                VpnFileLogger.d(TAG, "tun2socks: $line")
                            }
                        }
                    }
                } catch (e: Exception) {
                    // 检查是否因为正常停止导致的中断
                    if (currentState != V2RayState.DISCONNECTED && tun2socksProcess?.isAlive == true) {
                        // 不是正常停止,记录警告
                        VpnFileLogger.w(TAG, "读取tun2socks输出失败", e)
                    }
                    // 如果是正常停止(状态已经是DISCONNECTED或进程已死),不记录警告
                }
            }
            
            // 监控进程状态
            serviceScope.launch {
                try {
                    val exitCode = process.waitFor()
                    // 检查是否为正常停止
                    if (currentState == V2RayState.DISCONNECTED) {
                        // 正常停止,只记录debug级别
                        VpnFileLogger.d(TAG, "tun2socks进程正常退出,退出码: $exitCode")
                    } else {
                        // 异常退出,记录警告
                        VpnFileLogger.w(TAG, "tun2socks进程异常退出,退出码: $exitCode")
                        
                        // 修复：添加重启限制逻辑
                        if (mode == ConnectionMode.VPN_TUN && shouldRestartTun2socks()) {
                            VpnFileLogger.d(TAG, "自动重启tun2socks进程 (第${tun2socksRestartCount + 1}次)")
                            delay(1000)
                            restartTun2socks()
                        } else if (tun2socksRestartCount >= MAX_TUN2SOCKS_RESTART_COUNT) {
                            VpnFileLogger.e(TAG, "tun2socks重启次数已达上限，停止服务")
                            stopV2Ray()
                        }
                    }
                } catch (e: Exception) {
                    if (currentState != V2RayState.DISCONNECTED) {
                        VpnFileLogger.e(TAG, "监控tun2socks进程失败", e)
                    }
                }
            }
            
            // 检查进程是否成功启动
            delay(100)
            if (!process.isAlive) {
                throw Exception("tun2socks进程启动后立即退出")
            }
            
            VpnFileLogger.d(TAG, "tun2socks进程已启动")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动tun2socks失败", e)
            throw e
        }
    }
    
    /**
     * 修复：检查是否应该重启tun2socks
     */
    private fun shouldRestartTun2socks(): Boolean {
        val now = System.currentTimeMillis()
        
        // 如果是第一次重启，记录时间
        if (tun2socksRestartCount == 0) {
            tun2socksFirstRestartTime = now
        }
        
        // 检查是否超过重置间隔，如果是则重置计数
        if (now - tun2socksFirstRestartTime > TUN2SOCKS_RESTART_RESET_INTERVAL) {
            tun2socksRestartCount = 0
            tun2socksFirstRestartTime = now
            VpnFileLogger.d(TAG, "tun2socks重启计数已重置")
        }
        
        // 检查是否还能重启
        return tun2socksRestartCount < MAX_TUN2SOCKS_RESTART_COUNT
    }
    
    /**
     * 重启tun2socks进程
     * 修复：增加重启计数
     */
    private suspend fun restartTun2socks(): Unit = withContext(Dispatchers.IO) {
        try {
            tun2socksRestartCount++  // 增加重启计数
            runTun2socks()
            val success = sendFileDescriptor()
            if (!success) {
                VpnFileLogger.e(TAG, "重启后文件描述符传递失败,停止服务")
                stopV2Ray()
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "重启tun2socks失败", e)
            stopV2Ray()
        }
    }
    
    /**
     * 传递文件描述符给tun2socks
     */
    private suspend fun sendFileDescriptor(): Boolean {
        VpnFileLogger.d(TAG, "开始传递文件描述符给tun2socks")
        
        return withContext(Dispatchers.IO) {
            val sockPath = File(filesDir, "sock_path").absolutePath
            val tunFd = mInterface?.fileDescriptor
            
            if (tunFd == null) {
                VpnFileLogger.e(TAG, "TUN文件描述符为空")
                return@withContext false
            }
            
            var tries = 0
            val maxTries = 6
            
            while (tries < maxTries) {
                try {
                    // 递增延迟
                    delay(50L * tries)
                    
                    VpnFileLogger.d(TAG, "尝试连接Unix域套接字 (第${tries + 1}次)")
                    
                    val clientSocket = LocalSocket()
                    clientSocket.connect(LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM))
                    
                    val outputStream = clientSocket.outputStream
                    clientSocket.setFileDescriptorsForSend(arrayOf(tunFd))
                    outputStream.write(32)
                    outputStream.flush()
                    
                    clientSocket.setFileDescriptorsForSend(null)
                    clientSocket.shutdownOutput()
                    clientSocket.close()
                    
                    VpnFileLogger.d(TAG, "文件描述符传递成功")
                    return@withContext true
                    
                } catch (e: Exception) {
                    tries++
                    if (tries >= maxTries) {
                        VpnFileLogger.e(TAG, "文件描述符传递失败,已达最大重试次数", e)
                        return@withContext false
                    } else {
                        VpnFileLogger.w(TAG, "文件描述符传递失败,将重试 (${tries}/$maxTries): ${e.message}")
                    }
                }
            }
            false
        }
    }
    
    /**
     * 停止tun2socks进程
     */
    private fun stopTun2socks() {
        VpnFileLogger.d(TAG, "停止tun2socks进程")
        
        // 重置重启计数
        tun2socksRestartCount = 0
        tun2socksFirstRestartTime = 0L
        
        try {
            val process = tun2socksProcess
            if (process != null) {
                process.destroy()
                tun2socksProcess = null
                VpnFileLogger.d(TAG, "tun2socks进程已停止")
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止tun2socks进程失败", e)
        }
    }
    
    /**
     * 启动流量监控(可配置)
     * 仅在enableAutoStats为true时启动
     */
    private fun startTrafficMonitor() {
        VpnFileLogger.d(TAG, "启动流量监控,更新间隔: ${STATS_UPDATE_INTERVAL}ms")
        
        statsJob?.cancel()
        
        statsJob = serviceScope.launch {
            delay(5000) // 修复：初始延迟5秒（原来是2秒太快了）
            
            while (currentState == V2RayState.CONNECTED && isActive) {
                try {
                    updateTrafficStats()
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "更新流量统计异常", e)
                }
                
                delay(STATS_UPDATE_INTERVAL) // 使用配置的间隔（10秒）
            }
        }
    }
    
    /**
     * 按需更新流量统计(供Flutter端查询时调用)
     * 修复：添加节流机制，避免频繁更新
     */
    private fun updateTrafficStatsOnDemand() {
        if (currentState != V2RayState.CONNECTED) return
        
        // 节流：1秒内最多更新一次
        val now = System.currentTimeMillis()
        if (now - lastOnDemandUpdateTime < 1000) {
            return  // 距离上次更新不足1秒，跳过
        }
        lastOnDemandUpdateTime = now
        
        try {
            updateTrafficStats()
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "按需更新流量统计失败", e)
        }
    }
    
    /**
     * 更新流量统计
     * 修复:使用正确的queryStats参数格式
     */
    private fun updateTrafficStats() {
        try {
            val controller = coreController ?: return
            
            // 修复:使用正确的查询格式(参考V2Ray开源项目)
            // 格式:outbound>>>标签>>>traffic>>>方向
            val proxyUplink = controller.queryStats("outbound>>>proxy>>>traffic>>>uplink", "")
            val proxyDownlink = controller.queryStats("outbound>>>proxy>>>traffic>>>downlink", "")
            
            // 可选:也查询其他出站的流量
            val directUplink = controller.queryStats("outbound>>>direct>>>traffic>>>uplink", "")
            val directDownlink = controller.queryStats("outbound>>>direct>>>traffic>>>downlink", "")
            val blockUplink = controller.queryStats("outbound>>>block>>>traffic>>>uplink", "")
            val blockDownlink = controller.queryStats("outbound>>>block>>>traffic>>>downlink", "")
            
            // 合并所有流量统计
            var currentUpload = proxyUplink + directUplink + blockUplink
            var currentDownload = proxyDownlink + directDownlink + blockDownlink
            
            // 如果proxy出站没有数据,尝试查询总量
            if (proxyUplink == 0L && proxyDownlink == 0L) {
                // 尝试查询所有出站的总量
                val totalUplink = controller.queryStats("outbound>>>traffic>>>uplink", "")
                val totalDownlink = controller.queryStats("outbound>>>traffic>>>downlink", "")
                
                if (totalUplink > 0 || totalDownlink > 0) {
                    currentUpload = totalUplink
                    currentDownload = totalDownlink
                }
            }
            
            // 更新总量
            uploadBytes = currentUpload
            downloadBytes = currentDownload
            
            // 计算速度
            val now = System.currentTimeMillis()
            if (lastQueryTime > 0 && now > lastQueryTime) {
                val timeDiff = (now - lastQueryTime) / 1000.0
                if (timeDiff > 0) {
                    val uploadDiff = uploadBytes - lastUploadTotal
                    val downloadDiff = downloadBytes - lastDownloadTotal
                    
                    if (uploadDiff >= 0 && downloadDiff >= 0) {
                        uploadSpeed = (uploadDiff / timeDiff).toLong()
                        downloadSpeed = (downloadDiff / timeDiff).toLong()
                    } else {
                        // 统计可能被重置
                        uploadSpeed = 0
                        downloadSpeed = 0
                    }
                }
            }
            
            // 保存本次查询的值
            lastQueryTime = now
            lastUploadTotal = uploadBytes
            lastDownloadTotal = downloadBytes
            
            // 仅在自动统计模式下更新通知和广播
            if (enableAutoStats) {
                // 更新通知（显示流量统计，不是速度）
                updateNotification()
                
                // 广播状态
                broadcastConnectionInfo()
            }
            
            VpnFileLogger.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}, " +
                      "速度: ↑${formatBytes(uploadSpeed)}/s ↓${formatBytes(downloadSpeed)}/s")
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "查询流量统计失败", e)
        }
    }
    
    /**
     * 广播连接信息(增强版)
     */
    private fun broadcastConnectionInfo() {
        val intent = Intent("V2RAY_CONNECTION_INFO").apply {
            putExtra("STATE", currentState.name)
            putExtra("MODE", mode.name)
            putExtra("DURATION", formatDuration(System.currentTimeMillis() - startTime))
            putExtra("UPLOAD_SPEED", uploadSpeed)
            putExtra("DOWNLOAD_SPEED", downloadSpeed)
            putExtra("UPLOAD_TRAFFIC", uploadBytes)
            putExtra("DOWNLOAD_TRAFFIC", downloadBytes)
        }
        
        sendBroadcast(intent)
    }
    
    /**
     * 测量已连接服务器的延迟
     * 根据method_summary.md: measureDelay(String)返回long
     */
    private suspend fun measureConnectedDelay(testUrl: String): Long = withContext(Dispatchers.IO) {
        return@withContext try {
            val controller = coreController
            if (controller != null && controller.isRunning) {
                val delay = controller.measureDelay(testUrl)
                VpnFileLogger.d(TAG, "服务器延迟: ${delay}ms")
                delay
            } else {
                -1L
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "测量延迟失败", e)
            -1L
        }
    }
    
    /**
     * 获取当前流量统计
     */
    fun getCurrentTrafficStats(): Map<String, Long> {
        return mapOf(
            "uploadTotal" to uploadBytes,
            "downloadTotal" to downloadBytes,
            "uploadSpeed" to uploadSpeed,
            "downloadSpeed" to downloadSpeed
        )
    }
    
    /**
     * 停止V2Ray服务
     */
    private fun stopV2Ray() {
        VpnFileLogger.d(TAG, "开始停止V2Ray服务")
        
        // 先设置状态,防止tun2socks监控线程重启
        currentState = V2RayState.DISCONNECTED
        
        // 停止流量监控
        statsJob?.cancel()
        statsJob = null
        
        // 广播断开状态
        val intent = Intent("V2RAY_CONNECTION_INFO").apply {
            putExtra("STATE", "DISCONNECTED")
            putExtra("DURATION", "00:00:00")
            putExtra("UPLOAD_SPEED", 0L)
            putExtra("DOWNLOAD_SPEED", 0L)
            putExtra("UPLOAD_TRAFFIC", 0L)
            putExtra("DOWNLOAD_TRAFFIC", 0L)
        }
        sendBroadcast(intent)
        
        // 新增：通知MainActivity服务已停止（用于通知栏停止按钮）
        sendBroadcast(Intent(ACTION_VPN_STOPPED))
        VpnFileLogger.d(TAG, "已发送VPN停止广播")
        
        // 停止tun2socks进程(仅VPN模式)
        if (mode == ConnectionMode.VPN_TUN) {
            stopTun2socks()
        }
        
        // 停止V2Ray核心
        try {
            coreController?.stopLoop()
            VpnFileLogger.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
        }
        
        // 关闭VPN接口(仅VPN模式)
        if (mode == ConnectionMode.VPN_TUN) {
            try {
                mInterface?.close()
                mInterface = null
                VpnFileLogger.d(TAG, "VPN接口已关闭")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
            }
        }
        
        // 停止前台服务
        stopForeground(true)
        
        // 停止服务自身
        stopSelf()
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止")
    }
    
    /**
     * 创建前台服务通知(支持国际化)
     * 处理通知权限缺失的情况
     */
    private fun createNotification(): android.app.Notification? {
        try {
            // 使用国际化的通知渠道名称和描述
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
            
            // 根据模式获取国际化的模式文本
            val modeText = when (mode) {
                ConnectionMode.VPN_TUN -> {
                    if (globalProxy) {
                        instanceLocalizedStrings["globalProxyMode"] ?: "全局代理模式"
                    } else {
                        instanceLocalizedStrings["smartProxyMode"] ?: "智能代理模式"
                    }
                }
                ConnectionMode.PROXY_ONLY -> {
                    instanceLocalizedStrings["proxyOnlyMode"] ?: "仅代理模式"
                }
            }
            
            // 构建标题：appName - 模式
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
            val title = "$appName - $modeText"
            
            // 初始内容：流量统计（初始为0）
            val content = formatTrafficStatsForNotification(0L, 0L)
            
            val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())  // 使用应用图标
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel, 
                    instanceLocalizedStrings["disconnectButtonName"] ?: "断开",
                    stopPendingIntent
                )
            
            mainPendingIntent?.let {
                builder.setContentIntent(it)
            }
            
            return builder.build()
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "创建通知失败", e)
            // 返回一个最小的通知
            return try {
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
     * 获取应用图标资源ID
     */
    private fun getAppIconResource(): Int {
        return try {
            // 尝试使用应用的launcher图标
            packageManager.getApplicationInfo(packageName, 0).icon
        } catch (e: Exception) {
            // 如果失败，使用默认图标
            android.R.drawable.ic_dialog_info
        }
    }
    
    /**
     * 格式化流量统计用于通知显示
     */
    private fun formatTrafficStatsForNotification(upload: Long, download: Long): String {
        val template = instanceLocalizedStrings["trafficStatsFormat"] ?: "流量: ↑%upload ↓%download"
        return template
            .replace("%upload", formatBytes(upload))
            .replace("%download", formatBytes(download))
    }
    
    /**
     * 更新通知显示流量信息（修改：显示流量统计而不是速度）
     */
    private fun updateNotification() {
        try {
            // 根据模式获取国际化的模式文本
            val modeText = when (mode) {
                ConnectionMode.VPN_TUN -> {
                    if (globalProxy) {
                        instanceLocalizedStrings["globalProxyMode"] ?: "全局代理模式"
                    } else {
                        instanceLocalizedStrings["smartProxyMode"] ?: "智能代理模式"
                    }
                }
                ConnectionMode.PROXY_ONLY -> {
                    instanceLocalizedStrings["proxyOnlyMode"] ?: "仅代理模式"
                }
            }
            
            // 构建标题：appName - 模式
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
            val title = "$appName - $modeText"
            
            // 内容：流量统计（不是速度）
            val content = formatTrafficStatsForNotification(uploadBytes, downloadBytes)
            
            val stopIntent = Intent(ACTION_STOP_VPN)
            val stopPendingIntent = PendingIntent.getBroadcast(
                this, 0, stopIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )
            
            val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())  // 使用应用图标
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    instanceLocalizedStrings["disconnectButtonName"] ?: "断开",
                    stopPendingIntent
                )
                .build()
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "更新通知失败", e)
        }
    }
    
    // ===== CoreCallbackHandler 接口实现 =====
    
    /**
     * V2Ray核心启动回调
     * 注意:这是核心启动完成后的通知,不是请求建立VPN
     * @return 0表示成功,-1表示失败
     */
    override fun startup(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.startup() 被调用")
        
        // 这里只是V2Ray核心启动完成的通知
        // VPN隧道已经在startV2Ray()中预先建立好了
        // 根据开源项目,这里可能需要保护V2Ray的socket
        
        try {
            // 如果V2Ray核心使用了网络连接,保护它避免走VPN
            // 但通常V2Ray作为本地SOCKS服务器不需要保护
            VpnFileLogger.d(TAG, "V2Ray核心启动完成通知")
            return 0L // 返回0表示成功
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "startup处理异常", e)
            return -1L
        }
    }
    
    /**
     * V2Ray核心关闭回调
     * @return 0表示成功
     */
    override fun shutdown(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.shutdown() 被调用")
        
        // 异步停止服务,避免阻塞Native线程
        serviceScope.launch {
            try {
                stopV2Ray()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "shutdown停止服务异常", e)
            }
        }
        
        return 0L
    }
    
    /**
     * V2Ray状态回调
     * @param level 日志级别 (0=Debug, 1=Info, 2=Warning, 3=Error, 4=Fatal)
     * @param status 状态信息
     * @return 0成功
     */
    override fun onEmitStatus(level: Long, status: String?): Long {
        try {
            // 根据级别记录日志
            when (level.toInt()) {
                0 -> VpnFileLogger.d(TAG, "V2Ray: $status")
                1 -> VpnFileLogger.i(TAG, "V2Ray: $status")
                2 -> VpnFileLogger.w(TAG, "V2Ray: $status")
                3 -> VpnFileLogger.e(TAG, "V2Ray: $status")
                4 -> VpnFileLogger.e(TAG, "V2Ray Fatal: $status")
                else -> VpnFileLogger.d(TAG, "V2Ray[$level]: $status")
            }
            return 0L
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "onEmitStatus异常", e)
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
    
    private fun formatDuration(millis: Long): String {
        if (millis < 0) return "00:00:00"
        
        val seconds = (millis / 1000) % 60
        val minutes = (millis / (1000 * 60)) % 60
        val hours = millis / (1000 * 60 * 60)
        return String.format("%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    /**
     * 服务销毁时调用
     */
    override fun onDestroy() {
        super.onDestroy()
        
        VpnFileLogger.d(TAG, "onDestroy开始")
        
        // 修复：清理WeakReference
        instanceRef?.clear()
        instanceRef = null
        
        // 取消所有协程
        serviceScope.cancel()
        
        // 注销广播接收器
        try {
            unregisterReceiver(stopReceiver)
            VpnFileLogger.d(TAG, "广播接收器已注销")
        } catch (e: Exception) {
            // 可能已经注销
        }
        
        // 如果还在运行,执行清理(避免与stopV2Ray重复)
        if (currentState != V2RayState.DISCONNECTED) {
            VpnFileLogger.d(TAG, "onDestroy时服务仍在运行,执行清理")
            
            // 更新状态
            currentState = V2RayState.DISCONNECTED
            
            // 停止流量监控
            statsJob?.cancel()
            statsJob = null
            
            // 停止tun2socks进程(如果是VPN模式)
            if (mode == ConnectionMode.VPN_TUN) {
                stopTun2socks()
            }
            
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
        
        // 清理引用
        coreController = null
        
        VpnFileLogger.d(TAG, "onDestroy完成,服务已销毁")
        
        // 刷新并关闭日志系统
        runBlocking {
            VpnFileLogger.flushAll()
        }
        VpnFileLogger.close()
    }
}