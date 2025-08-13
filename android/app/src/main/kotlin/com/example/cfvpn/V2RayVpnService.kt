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
 * V2Ray VPN服务实现 - 增强日志版
 * 
 * 核心原则：
 * 1. 配置处理完全由dart端负责
 * 2. Android端只负责VPN隧道建立和V2Ray核心启动
 * 3. 流量统计按需查询，用于通知栏显示
 * 
 * 主要功能:
 * - VPN隧道管理
 * - V2Ray核心生命周期管理
 * - tun2socks进程管理
 * - 流量统计和通知更新
 * - 分应用代理支持
 */
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    // 连接模式枚举
    enum class ConnectionMode {
        VPN_TUN,        // VPN隧道模式(全局)
        PROXY_ONLY      // 仅代理模式(局部,不创建VPN)
    }
    
    // 连接状态枚举
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
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"
        
        // VPN配置常量
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        
        // V2Ray端口默认值
        private const val DEFAULT_SOCKS_PORT = 7898
        
        // 流量统计配置
        private const val STATS_UPDATE_INTERVAL = 10000L  // 10秒更新一次
        
        // tun2socks重启限制
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L
        
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
         * 启动VPN服务
         */
        @JvmStatic
        fun startVpnService(
            context: Context, 
            config: String,
            mode: ConnectionMode = ConnectionMode.VPN_TUN,
            globalProxy: Boolean = false,
            blockedApps: List<String>? = null,
            allowedApps: List<String>? = null,
            appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE,
            bypassSubnets: List<String>? = null,
            enableAutoStats: Boolean = true,
            disconnectButtonName: String = "停止",
            localizedStrings: Map<String, String> = emptyMap()
        ) {
            VpnFileLogger.d(TAG, "========== 准备启动VPN服务 ==========")
            VpnFileLogger.d(TAG, "模式: $mode, 全局代理: $globalProxy")
            VpnFileLogger.d(TAG, "配置长度: ${config.length} 字符")
            
            // 保存配置到文件用于调试
            try {
                val configFile = File(context.filesDir, "last_config.json")
                configFile.writeText(config)
                VpnFileLogger.d(TAG, "配置已保存到: ${configFile.absolutePath}")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存配置文件失败", e)
            }
            
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
                VpnFileLogger.d(TAG, "服务启动命令已发送")
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
         * 获取流量统计
         */
        @JvmStatic
        fun getTrafficStats(): Map<String, Long> {
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
         */
        @JvmStatic
        suspend fun testServerDelay(config: String, testUrl: String = "https://www.google.com/generate_204"): Long {
            return withContext(Dispatchers.IO) {
                try {
                    VpnFileLogger.d(TAG, "开始测试服务器延迟: $testUrl")
                    val delay = Libv2ray.measureOutboundDelay(config, testUrl)
                    VpnFileLogger.d(TAG, "服务器延迟测试结果: ${delay}ms")
                    delay
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "测试服务器延迟失败", e)
                    -1L
                }
            }
        }
    }
    
    // V2Ray核心控制器
    private var coreController: CoreController? = null
    
    // VPN接口文件描述符
    private var mInterface: ParcelFileDescriptor? = null
    
    // tun2socks进程
    private var tun2socksProcess: java.lang.Process? = null
    
    // tun2socks重启控制
    private var tun2socksRestartCount = 0
    private var tun2socksFirstRestartTime = 0L
    
    // 配置信息
    private var configJson: String = ""  // 直接保存dart生成的JSON配置
    private var mode: ConnectionMode = ConnectionMode.VPN_TUN
    private var globalProxy: Boolean = false
    private var blockedApps: List<String> = emptyList()
    private var allowedApps: List<String> = emptyList()
    private var appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE
    private var bypassSubnets: List<String> = emptyList()
    private var enableAutoStats: Boolean = true
    
    // 实例级的国际化文字存储
    private val instanceLocalizedStrings = mutableMapOf<String, String>()
    
    // 协程作用域
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计数据
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var lastUploadTotal: Long = 0
    private var lastDownloadTotal: Long = 0
    private var uploadSpeed: Long = 0
    private var downloadSpeed: Long = 0
    private var lastQueryTime: Long = 0
    private var startTime: Long = 0
    private var lastOnDemandUpdateTime: Long = 0
    
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
     */
    override fun onCreate() {
        super.onCreate()
        
        VpnFileLogger.init(applicationContext)
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "VPN服务onCreate开始")
        VpnFileLogger.d(TAG, "========================================")
        
        instanceRef = WeakReference(this)
        
        // 初始化Go运行时
        try {
            Seq.setContext(applicationContext)
            VpnFileLogger.d(TAG, "✓ Go运行时初始化成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗ Go运行时初始化失败", e)
            stopSelf()
            return
        }
        
        // 注册广播接收器
        try {
            registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
            VpnFileLogger.d(TAG, "✓ 广播接收器注册成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗ 注册广播接收器失败", e)
        }
        
        // 初始化V2Ray环境
        try {
            val envPath = filesDir.absolutePath
            Libv2ray.initCoreEnv(envPath, "")
            VpnFileLogger.d(TAG, "✓ V2Ray环境初始化成功: $envPath")
            
            val version = Libv2ray.checkVersionX()
            VpnFileLogger.i(TAG, "V2Ray版本信息: $version")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗ V2Ray环境初始化失败", e)
        }
        
        // 复制资源文件
        copyAssetFiles()
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成")
    }
    
    /**
     * 服务启动命令
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "onStartCommand开始")
        VpnFileLogger.d(TAG, "action=${intent?.action}, flags=$flags, startId=$startId")
        VpnFileLogger.d(TAG, "========================================")
        
        if (intent == null || intent.action != "START_VPN") {
            VpnFileLogger.w(TAG, "无效的启动意图: action=${intent?.action}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        if (currentState == V2RayState.CONNECTED) {
            VpnFileLogger.w(TAG, "VPN服务已在运行,忽略重复请求")
            return START_STICKY
        }
        
        currentState = V2RayState.CONNECTING
        
        // 获取配置
        configJson = intent.getStringExtra("config") ?: ""
        mode = try {
            ConnectionMode.valueOf(intent.getStringExtra("mode") ?: ConnectionMode.VPN_TUN.name)
        } catch (e: Exception) {
            ConnectionMode.VPN_TUN
        }
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        enableAutoStats = intent.getBooleanExtra("enableAutoStats", true)
        appProxyMode = try {
            AppProxyMode.valueOf(intent.getStringExtra("appProxyMode") ?: AppProxyMode.EXCLUDE.name)
        } catch (e: Exception) {
            AppProxyMode.EXCLUDE
        }
        blockedApps = intent.getStringArrayListExtra("blockedApps") ?: emptyList()
        allowedApps = intent.getStringArrayListExtra("allowedApps") ?: emptyList()
        bypassSubnets = intent.getStringArrayListExtra("bypassSubnets") ?: emptyList()
        
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
            VpnFileLogger.e(TAG, "✗ 配置为空")
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "配置为空")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 记录配置参数
        VpnFileLogger.d(TAG, "----------------------------------------")
        VpnFileLogger.d(TAG, "配置参数:")
        VpnFileLogger.d(TAG, "  模式: $mode")
        VpnFileLogger.d(TAG, "  全局代理: $globalProxy")
        VpnFileLogger.d(TAG, "  代理模式: $appProxyMode")
        VpnFileLogger.d(TAG, "  排除应用: ${blockedApps.size}个")
        VpnFileLogger.d(TAG, "  包含应用: ${allowedApps.size}个")
        VpnFileLogger.d(TAG, "  绕过子网: ${bypassSubnets.size}个")
        VpnFileLogger.d(TAG, "  自动统计: $enableAutoStats")
        VpnFileLogger.d(TAG, "  配置长度: ${configJson.length}字符")
        VpnFileLogger.d(TAG, "----------------------------------------")
        
        // 解析并记录V2Ray配置的关键信息
        parseAndLogV2RayConfig()
        
        // 启动前台服务
        try {
            val notification = createNotification()
            if (notification != null) {
                startForeground(NOTIFICATION_ID, notification)
                VpnFileLogger.d(TAG, "✓ 前台服务已启动")
            } else {
                VpnFileLogger.e(TAG, "✗ 无法创建通知")
                currentState = V2RayState.DISCONNECTED
                sendStartResultBroadcast(false, "无法创建通知")
                stopSelf()
                return START_NOT_STICKY
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗ 启动前台服务失败", e)
            currentState = V2RayState.DISCONNECTED
            sendStartResultBroadcast(false, "启动前台服务失败: ${e.message}")
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
                VpnFileLogger.e(TAG, "✗ 启动失败", e)
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
     * 解析并记录V2Ray配置的关键信息
     */
    private fun parseAndLogV2RayConfig() {
        try {
            val config = JSONObject(configJson)
            VpnFileLogger.d(TAG, "========================================")
            VpnFileLogger.d(TAG, "V2Ray配置解析:")
            VpnFileLogger.d(TAG, "========================================")
            
            // 记录入站配置
            if (config.has("inbounds")) {
                val inbounds = config.getJSONArray("inbounds")
                VpnFileLogger.d(TAG, "【入站配置】数量: ${inbounds.length()}")
                for (i in 0 until inbounds.length()) {
                    val inbound = inbounds.getJSONObject(i)
                    val tag = inbound.optString("tag", "未命名")
                    val protocol = inbound.optString("protocol", "未知")
                    val port = inbound.optInt("port", 0)
                    val listen = inbound.optString("listen", "127.0.0.1")
                    VpnFileLogger.d(TAG, "  [$i] $tag: $protocol://$listen:$port")
                    
                    // SOCKS配置详情
                    if (protocol == "socks") {
                        val settings = inbound.optJSONObject("settings")
                        if (settings != null) {
                            val auth = settings.optString("auth", "noauth")
                            val udp = settings.optBoolean("udp", false)
                            VpnFileLogger.d(TAG, "      认证: $auth, UDP: $udp")
                        }
                    }
                }
            }
            
            // 记录出站配置
            if (config.has("outbounds")) {
                val outbounds = config.getJSONArray("outbounds")
                VpnFileLogger.d(TAG, "【出站配置】数量: ${outbounds.length()}")
                for (i in 0 until outbounds.length()) {
                    val outbound = outbounds.getJSONObject(i)
                    val tag = outbound.optString("tag", "未命名")
                    val protocol = outbound.optString("protocol", "未知")
                    VpnFileLogger.d(TAG, "  [$i] $tag: $protocol")
                    
                    // 主要代理配置
                    if (tag == "proxy") {
                        when (protocol) {
                            "vless" -> logVlessConfig(outbound)
                            "vmess" -> logVmessConfig(outbound)
                            "shadowsocks" -> logShadowsocksConfig(outbound)
                            "trojan" -> logTrojanConfig(outbound)
                        }
                    }
                }
            }
            
            // 记录路由配置
            if (config.has("routing")) {
                val routing = config.getJSONObject("routing")
                val domainStrategy = routing.optString("domainStrategy", "AsIs")
                val domainMatcher = routing.optString("domainMatcher", "hybrid")
                VpnFileLogger.d(TAG, "【路由配置】")
                VpnFileLogger.d(TAG, "  域名策略: $domainStrategy")
                VpnFileLogger.d(TAG, "  域名匹配器: $domainMatcher")
                
                val rules = routing.optJSONArray("rules")
                if (rules != null) {
                    VpnFileLogger.d(TAG, "  规则数量: ${rules.length()}")
                    for (i in 0 until Math.min(5, rules.length())) {
                        val rule = rules.getJSONObject(i)
                        val type = rule.optString("type", "field")
                        val outboundTag = rule.optString("outboundTag", "")
                        val domains = rule.optJSONArray("domain")
                        val ips = rule.optJSONArray("ip")
                        
                        var ruleDesc = "    [$i] -> $outboundTag"
                        if (domains != null && domains.length() > 0) {
                            ruleDesc += " (域名规则×${domains.length()})"
                        }
                        if (ips != null && ips.length() > 0) {
                            ruleDesc += " (IP规则×${ips.length()})"
                        }
                        VpnFileLogger.d(TAG, ruleDesc)
                    }
                }
            }
            
            // 记录DNS配置
            if (config.has("dns")) {
                val dns = config.getJSONObject("dns")
                VpnFileLogger.d(TAG, "【DNS配置】")
                val servers = dns.optJSONArray("servers")
                if (servers != null) {
                    VpnFileLogger.d(TAG, "  服务器数量: ${servers.length()}")
                    for (i in 0 until Math.min(3, servers.length())) {
                        val server = servers.get(i)
                        if (server is String) {
                            VpnFileLogger.d(TAG, "    [$i] $server")
                        } else if (server is JSONObject) {
                            val address = server.optString("address", "")
                            val domains = server.optJSONArray("domains")
                            VpnFileLogger.d(TAG, "    [$i] $address (域名规则×${domains?.length() ?: 0})")
                        }
                    }
                }
            }
            
            // 记录统计配置
            if (config.has("stats")) {
                VpnFileLogger.d(TAG, "【统计】已启用")
            }
            
            // 记录策略配置
            if (config.has("policy")) {
                val policy = config.getJSONObject("policy")
                VpnFileLogger.d(TAG, "【策略配置】")
                val system = policy.optJSONObject("system")
                if (system != null) {
                    val statsInboundUplink = system.optBoolean("statsInboundUplink", false)
                    val statsInboundDownlink = system.optBoolean("statsInboundDownlink", false)
                    val statsOutboundUplink = system.optBoolean("statsOutboundUplink", false)
                    val statsOutboundDownlink = system.optBoolean("statsOutboundDownlink", false)
                    VpnFileLogger.d(TAG, "  统计入站上行: $statsInboundUplink")
                    VpnFileLogger.d(TAG, "  统计入站下行: $statsInboundDownlink")
                    VpnFileLogger.d(TAG, "  统计出站上行: $statsOutboundUplink")
                    VpnFileLogger.d(TAG, "  统计出站下行: $statsOutboundDownlink")
                }
            }
            
            VpnFileLogger.d(TAG, "========================================")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "解析V2Ray配置失败", e)
            // 记录原始配置的前500个字符用于调试
            VpnFileLogger.d(TAG, "配置前500字符: ${configJson.take(500)}")
        }
    }
    
    /**
     * 记录VLESS配置详情
     */
    private fun logVlessConfig(outbound: JSONObject) {
        try {
            val settings = outbound.optJSONObject("settings") ?: return
            val vnext = settings.optJSONArray("vnext") ?: return
            if (vnext.length() == 0) return
            
            val server = vnext.getJSONObject(0)
            val address = server.optString("address", "")
            val port = server.optInt("port", 0)
            VpnFileLogger.d(TAG, "      服务器: $address:$port")
            
            val users = server.optJSONArray("users")
            if (users != null && users.length() > 0) {
                val user = users.getJSONObject(0)
                val uuid = user.optString("id", "")
                val flow = user.optString("flow", "无")
                val encryption = user.optString("encryption", "none")
                VpnFileLogger.d(TAG, "      UUID: ${uuid.take(8)}...")
                VpnFileLogger.d(TAG, "      流控: $flow")
                VpnFileLogger.d(TAG, "      加密: $encryption")
            }
            
            val streamSettings = outbound.optJSONObject("streamSettings")
            if (streamSettings != null) {
                val network = streamSettings.optString("network", "tcp")
                val security = streamSettings.optString("security", "none")
                VpnFileLogger.d(TAG, "      传输: $network, 安全: $security")
                
                // TLS配置
                if (security == "tls") {
                    val tlsSettings = streamSettings.optJSONObject("tlsSettings")
                    if (tlsSettings != null) {
                        val serverName = tlsSettings.optString("serverName", "")
                        val alpn = tlsSettings.optJSONArray("alpn")
                        val allowInsecure = tlsSettings.optBoolean("allowInsecure", false)
                        VpnFileLogger.d(TAG, "      SNI: $serverName")
                        if (alpn != null && alpn.length() > 0) {
                            val alpnList = (0 until alpn.length()).map { alpn.getString(it) }
                            VpnFileLogger.d(TAG, "      ALPN: ${alpnList.joinToString(", ")}")
                        }
                        VpnFileLogger.d(TAG, "      允许不安全: $allowInsecure")
                    }
                }
                
                // WebSocket配置
                if (network == "ws") {
                    val wsSettings = streamSettings.optJSONObject("wsSettings")
                    if (wsSettings != null) {
                        val path = wsSettings.optString("path", "/")
                        val headers = wsSettings.optJSONObject("headers")
                        val host = headers?.optString("Host", "") ?: ""
                        VpnFileLogger.d(TAG, "      WS路径: $path")
                        if (host.isNotEmpty()) {
                            VpnFileLogger.d(TAG, "      WS Host: $host")
                        }
                    }
                }
                
                // gRPC配置
                if (network == "grpc") {
                    val grpcSettings = streamSettings.optJSONObject("grpcSettings")
                    if (grpcSettings != null) {
                        val serviceName = grpcSettings.optString("serviceName", "")
                        val multiMode = grpcSettings.optBoolean("multiMode", false)
                        VpnFileLogger.d(TAG, "      gRPC服务名: $serviceName")
                        VpnFileLogger.d(TAG, "      gRPC多路复用: $multiMode")
                    }
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "记录VLESS配置失败", e)
        }
    }
    
    /**
     * 记录VMess配置详情
     */
    private fun logVmessConfig(outbound: JSONObject) {
        try {
            val settings = outbound.optJSONObject("settings") ?: return
            val vnext = settings.optJSONArray("vnext") ?: return
            if (vnext.length() == 0) return
            
            val server = vnext.getJSONObject(0)
            val address = server.optString("address", "")
            val port = server.optInt("port", 0)
            VpnFileLogger.d(TAG, "      服务器: $address:$port")
            
            val users = server.optJSONArray("users")
            if (users != null && users.length() > 0) {
                val user = users.getJSONObject(0)
                val uuid = user.optString("id", "")
                val alterId = user.optInt("alterId", 0)
                val security = user.optString("security", "auto")
                VpnFileLogger.d(TAG, "      UUID: ${uuid.take(8)}...")
                VpnFileLogger.d(TAG, "      额外ID: $alterId")
                VpnFileLogger.d(TAG, "      加密: $security")
            }
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "记录VMess配置失败", e)
        }
    }
    
    /**
     * 记录Shadowsocks配置详情
     */
    private fun logShadowsocksConfig(outbound: JSONObject) {
        try {
            val settings = outbound.optJSONObject("settings") ?: return
            val servers = settings.optJSONArray("servers") ?: return
            if (servers.length() == 0) return
            
            val server = servers.getJSONObject(0)
            val address = server.optString("address", "")
            val port = server.optInt("port", 0)
            val method = server.optString("method", "")
            VpnFileLogger.d(TAG, "      服务器: $address:$port")
            VpnFileLogger.d(TAG, "      加密方式: $method")
            VpnFileLogger.d(TAG, "      密码: ***")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "记录Shadowsocks配置失败", e)
        }
    }
    
    /**
     * 记录Trojan配置详情
     */
    private fun logTrojanConfig(outbound: JSONObject) {
        try {
            val settings = outbound.optJSONObject("settings") ?: return
            val servers = settings.optJSONArray("servers") ?: return
            if (servers.length() == 0) return
            
            val server = servers.getJSONObject(0)
            val address = server.optString("address", "")
            val port = server.optInt("port", 0)
            VpnFileLogger.d(TAG, "      服务器: $address:$port")
            VpnFileLogger.d(TAG, "      密码: ***")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "记录Trojan配置失败", e)
        }
    }
    
    /**
     * 复制资源文件到应用目录
     */
    private fun copyAssetFiles() {
        VpnFileLogger.d(TAG, "开始复制资源文件")
        
        val assetDir = filesDir
        if (!assetDir.exists()) {
            assetDir.mkdirs()
        }
        
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
     */
    private suspend fun startV2RayWithVPN() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "开始启动V2Ray(VPN模式)")
        VpnFileLogger.d(TAG, "========================================")
        
        try {
            // 步骤1:建立VPN隧道
            VpnFileLogger.d(TAG, "[步骤1] 建立VPN隧道...")
            withContext(Dispatchers.Main) {
                establishVpn()
            }
            
            if (mInterface == null) {
                throw Exception("VPN隧道建立失败: mInterface为null")
            }
            VpnFileLogger.d(TAG, "✓ VPN隧道建立成功")
            
            // 步骤2:创建核心控制器
            VpnFileLogger.d(TAG, "[步骤2] 创建V2Ray核心控制器...")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败: 返回null")
            }
            VpnFileLogger.d(TAG, "✓ CoreController创建成功")
            
            // 步骤3:启动V2Ray核心
            VpnFileLogger.d(TAG, "[步骤3] 启动V2Ray核心...")
            VpnFileLogger.d(TAG, "配置长度: ${configJson.length}字符")
            
            // 启动核心
            coreController?.startLoop(configJson)
            VpnFileLogger.d(TAG, "startLoop调用完成，等待核心稳定...")
            
            // 等待核心启动
            delay(1000)
            
            // 步骤4:验证运行状态
            VpnFileLogger.d(TAG, "[步骤4] 验证V2Ray核心状态...")
            val isRunningNow = coreController?.isRunning ?: false
            VpnFileLogger.d(TAG, "isRunning = $isRunningNow")
            
            if (!isRunningNow) {
                // 尝试查询版本信息来验证核心状态
                try {
                    val version = Libv2ray.checkVersionX()
                    VpnFileLogger.d(TAG, "核心版本: $version")
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "无法获取核心版本", e)
                }
                throw Exception("V2Ray核心未运行: isRunning返回false")
            }
            
            VpnFileLogger.i(TAG, "✓ V2Ray核心启动成功")
            
            // 步骤5:启动tun2socks进程
            VpnFileLogger.d(TAG, "[步骤5] 启动tun2socks进程...")
            runTun2socks()
            VpnFileLogger.d(TAG, "✓ tun2socks启动成功")
            
            // 步骤6:传递文件描述符
            VpnFileLogger.d(TAG, "[步骤6] 传递文件描述符...")
            val fdSuccess = sendFileDescriptor()
            if (!fdSuccess) {
                throw Exception("文件描述符传递失败")
            }
            VpnFileLogger.d(TAG, "✓ 文件描述符传递成功")
            
            // 步骤7:更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "========================================")
            VpnFileLogger.i(TAG, "✓✓✓ V2Ray服务(VPN模式)完全启动成功 ✓✓✓")
            VpnFileLogger.i(TAG, "========================================")
            
            sendStartResultBroadcast(true)
            
            // 保存自启动配置
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        configJson,
                        mode.name,
                        globalProxy
                    )
                    VpnFileLogger.d(TAG, "已更新自启动配置")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存自启动配置失败", e)
            }
            
            // 启动流量监控
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动自动流量统计")
                startTrafficMonitor()
            }
            
            // 延迟后进行连接测试
            serviceScope.launch {
                delay(3000)
                performConnectionTest()
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗✗✗ 启动V2Ray(VPN模式)失败 ✗✗✗", e)
            VpnFileLogger.e(TAG, "错误详情: ${e.message}")
            VpnFileLogger.e(TAG, "堆栈跟踪:", e)
            cleanupResources()
            sendStartResultBroadcast(false, e.message)
            throw e
        }
    }
    
    /**
     * 启动V2Ray(仅代理模式)
     */
    private suspend fun startV2RayProxyOnly() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "开始启动V2Ray(仅代理模式)")
        VpnFileLogger.d(TAG, "========================================")
        
        try {
            // 步骤1:创建核心控制器
            VpnFileLogger.d(TAG, "[步骤1] 创建核心控制器...")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败")
            }
            VpnFileLogger.d(TAG, "✓ CoreController创建成功")
            
            // 步骤2:启动V2Ray核心
            VpnFileLogger.d(TAG, "[步骤2] 启动V2Ray核心...")
            coreController?.startLoop(configJson)
            
            // 等待核心启动
            delay(1000)
            
            // 步骤3:验证运行状态
            VpnFileLogger.d(TAG, "[步骤3] 验证运行状态...")
            val isRunningNow = coreController?.isRunning ?: false
            VpnFileLogger.d(TAG, "isRunning = $isRunningNow")
            
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行")
            }
            
            // 步骤4:更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "========================================")
            VpnFileLogger.i(TAG, "✓✓✓ V2Ray服务(仅代理模式)启动成功 ✓✓✓")
            VpnFileLogger.i(TAG, "========================================")
            
            sendStartResultBroadcast(true)
            
            // 保存自启动配置
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        configJson,
                        mode.name,
                        globalProxy
                    )
                    VpnFileLogger.d(TAG, "已更新自启动配置")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "保存自启动配置失败", e)
            }
            
            // 启动流量监控
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动自动流量统计")
                startTrafficMonitor()
            }
            
            // 延迟后进行连接测试
            serviceScope.launch {
                delay(3000)
                performConnectionTest()
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "✗✗✗ 启动V2Ray(仅代理模式)失败 ✗✗✗", e)
            cleanupResources()
            sendStartResultBroadcast(false, e.message)
            throw e
        }
    }
    
    /**
     * 执行连接测试
     */
    private suspend fun performConnectionTest() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "开始连接测试")
        VpnFileLogger.d(TAG, "========================================")
        
        try {
            // 获取SOCKS端口
            var socksPort = DEFAULT_SOCKS_PORT
            try {
                val config = JSONObject(configJson)
                val inbounds = config.getJSONArray("inbounds")
                for (i in 0 until inbounds.length()) {
                    val inbound = inbounds.getJSONObject(i)
                    if (inbound.optString("tag", "") == "socks") {
                        socksPort = inbound.optInt("port", DEFAULT_SOCKS_PORT)
                        break
                    }
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "无法解析SOCKS端口,使用默认值", e)
            }
            
            VpnFileLogger.d(TAG, "SOCKS代理端口: $socksPort")
            
            // 测试1: 检查端口是否监听
            VpnFileLogger.d(TAG, "[测试1] 检查SOCKS端口监听状态...")
            try {
                val socket = java.net.Socket()
                socket.connect(InetSocketAddress("127.0.0.1", socksPort), 1000)
                socket.close()
                VpnFileLogger.d(TAG, "✓ SOCKS端口($socksPort)正在监听")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "✗ SOCKS端口($socksPort)未监听", e)
            }
            
            // 测试2: HTTP请求测试
            VpnFileLogger.d(TAG, "[测试2] 通过代理进行HTTP请求...")
            try {
                val testUrl = URL("http://www.google.com/generate_204")
                val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", socksPort))
                val connection = testUrl.openConnection(proxy) as HttpURLConnection
                connection.connectTimeout = 5000
                connection.readTimeout = 5000
                connection.requestMethod = "GET"
                connection.setRequestProperty("User-Agent", "V2RayTest/1.0")
                
                val startTime = System.currentTimeMillis()
                val responseCode = connection.responseCode
                val latency = System.currentTimeMillis() - startTime
                
                VpnFileLogger.d(TAG, "HTTP响应码: $responseCode, 延迟: ${latency}ms")
                
                if (responseCode == 204) {
                    VpnFileLogger.i(TAG, "✓ 代理连接测试成功!")
                } else {
                    VpnFileLogger.w(TAG, "⚠ 代理连接异常,响应码: $responseCode")
                }
                
                connection.disconnect()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "✗ 代理连接测试失败", e)
            }
            
            // 测试3: V2Ray统计功能
            VpnFileLogger.d(TAG, "[测试3] 检查V2Ray统计功能...")
            try {
                val controller = coreController
                if (controller != null) {
                    // 尝试查询一个基本的统计项
                    val testStat = controller.queryStats("", "")
                    VpnFileLogger.d(TAG, "✓ V2Ray统计功能正常")
                    
                    // 查询具体的统计数据
                    val proxyUplink = controller.queryStats("outbound>>>proxy>>>traffic>>>uplink", "")
                    val proxyDownlink = controller.queryStats("outbound>>>proxy>>>traffic>>>downlink", "")
                    VpnFileLogger.d(TAG, "当前流量: 上行=${proxyUplink}B, 下行=${proxyDownlink}B")
                }
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "⚠ V2Ray统计功能异常", e)
            }
            
            // 测试4: DNS解析测试
            VpnFileLogger.d(TAG, "[测试4] DNS解析测试...")
            try {
                val host = java.net.InetAddress.getByName("www.google.com")
                VpnFileLogger.d(TAG, "✓ DNS解析成功: www.google.com -> ${host.hostAddress}")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "⚠ DNS解析失败", e)
            }
            
            VpnFileLogger.d(TAG, "========================================")
            VpnFileLogger.d(TAG, "连接测试完成")
            VpnFileLogger.d(TAG, "========================================")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "连接测试异常", e)
        }
    }
    
    /**
     * 发送VPN启动结果广播
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
        VpnFileLogger.d(TAG, "开始清理资源...")
        currentState = V2RayState.DISCONNECTED
        stopTun2socks()
        mInterface?.close()
        mInterface = null
        
        try {
            coreController?.stopLoop()
            VpnFileLogger.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "停止核心异常", e)
        }
        coreController = null
        VpnFileLogger.d(TAG, "资源清理完成")
    }
    
    /**
     * 建立VPN隧道
     */
    private fun establishVpn() {
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "开始建立VPN隧道")
        VpnFileLogger.d(TAG, "========================================")
        
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
        VpnFileLogger.d(TAG, "设置会话: $appName")
        VpnFileLogger.d(TAG, "设置MTU: $VPN_MTU")
        
        // IPv4地址
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        VpnFileLogger.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30")
        
        // IPv6地址(可选)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126)
                VpnFileLogger.d(TAG, "添加IPv6地址: $PRIVATE_VLAN6_CLIENT/126")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加IPv6地址失败(设备可能不支持IPv6)", e)
            }
        }
        
        // DNS服务器配置 - 使用固定的公共DNS
        builder.addDnsServer("8.8.8.8")
        builder.addDnsServer("1.1.1.1")
        VpnFileLogger.d(TAG, "添加DNS: 8.8.8.8, 1.1.1.1")
        
        // 路由规则配置 - 根据globalProxy参数设置
        VpnFileLogger.d(TAG, "配置路由规则...")
        if (globalProxy) {
            // 全局代理模式：所有流量都走VPN
            VpnFileLogger.d(TAG, "使用全局代理路由")
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
            // 智能分流模式
            if (bypassSubnets.isNotEmpty()) {
                VpnFileLogger.d(TAG, "配置子网绕过，数量: ${bypassSubnets.size}")
                bypassSubnets.forEach { subnet ->
                    try {
                        val parts = subnet.split("/")
                        if (parts.size == 2) {
                            val address = parts[0]
                            val prefixLength = parts[1].toInt()
                            builder.addRoute(address, prefixLength)
                            VpnFileLogger.d(TAG, "  添加路由: $address/$prefixLength")
                        }
                    } catch (e: Exception) {
                        VpnFileLogger.w(TAG, "  添加路由失败: $subnet", e)
                    }
                }
            } else {
                // 默认路由(V2Ray配置控制分流)
                builder.addRoute("0.0.0.0", 0)
                VpnFileLogger.d(TAG, "使用默认全局路由(由V2Ray配置控制分流)")
            }
        }
        
        // 分应用代理(Android 5.0+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // 始终排除自身
            try {
                builder.addDisallowedApplication(packageName)
                VpnFileLogger.d(TAG, "自动排除自身应用: $packageName")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "排除自身应用失败", e)
            }
            
            when (appProxyMode) {
                AppProxyMode.EXCLUDE -> {
                    VpnFileLogger.d(TAG, "使用排除模式，排除${blockedApps.size}个应用")
                    blockedApps.forEach { app ->
                        try {
                            builder.addDisallowedApplication(app)
                            VpnFileLogger.d(TAG, "  排除应用: $app")
                        } catch (e: Exception) {
                            VpnFileLogger.w(TAG, "  排除应用失败: $app - ${e.message}")
                        }
                    }
                }
                
                AppProxyMode.INCLUDE -> {
                    if (allowedApps.isNotEmpty()) {
                        VpnFileLogger.d(TAG, "使用包含模式，包含${allowedApps.size}个应用")
                        allowedApps.forEach { app ->
                            try {
                                builder.addAllowedApplication(app)
                                VpnFileLogger.d(TAG, "  包含应用: $app")
                            } catch (e: Exception) {
                                VpnFileLogger.w(TAG, "  包含应用失败: $app - ${e.message}")
                            }
                        }
                    } else {
                        VpnFileLogger.e(TAG, "包含模式但未指定任何应用!")
                    }
                }
            }
        }
        
        // 建立VPN接口
        VpnFileLogger.d(TAG, "调用Builder.establish()...")
        mInterface = builder.establish()
        
        if (mInterface == null) {
            VpnFileLogger.e(TAG, "✗ VPN接口建立失败(establish返回null)")
        } else {
            VpnFileLogger.d(TAG, "✓ VPN隧道建立成功")
            VpnFileLogger.d(TAG, "  文件描述符: ${mInterface?.fd}")
            VpnFileLogger.d(TAG, "  文件描述符有效: ${mInterface?.fileDescriptor?.valid()}")
        }
        
        VpnFileLogger.d(TAG, "========================================")
    }
    
    /**
     * 启动tun2socks进程
     */
    private suspend fun runTun2socks(): Unit = withContext(Dispatchers.IO) {
        if (mode != ConnectionMode.VPN_TUN) {
            VpnFileLogger.d(TAG, "非VPN模式,跳过tun2socks")
            return@withContext
        }
        
        VpnFileLogger.d(TAG, "开始启动tun2socks进程")
        
        // 从配置中提取SOCKS端口
        var socksPort = DEFAULT_SOCKS_PORT
        try {
            val config = JSONObject(configJson)
            val inbounds = config.getJSONArray("inbounds")
            for (i in 0 until inbounds.length()) {
                val inbound = inbounds.getJSONObject(i)
                if (inbound.optString("tag", "") == "socks") {
                    socksPort = inbound.optInt("port", DEFAULT_SOCKS_PORT)
                    break
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "无法从配置提取SOCKS端口,使用默认值: $socksPort", e)
        }
        
        VpnFileLogger.d(TAG, "SOCKS端口: $socksPort")
        
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
            
            // 构建命令行参数 - 使用info级别日志
            val cmd = arrayListOf(
                libtun2socksPath,
                "--netif-ipaddr", PRIVATE_VLAN4_ROUTER,
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:$socksPort",
                "--tunmtu", VPN_MTU.toString(),
                "--sock-path", sockPath,
                "--enable-udprelay",
                "--loglevel", "info"  // 改为info级别以获取更多信息
            )
            
            VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
            
            // 启动进程
            val processBuilder = ProcessBuilder(cmd).apply {
                redirectErrorStream(true)
                directory(filesDir)
            }
            
            val process = processBuilder.start()
            tun2socksProcess = process
            
            // 读取进程输出
            serviceScope.launch {
                try {
                    process.inputStream?.bufferedReader()?.use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            if (!line.isNullOrBlank()) {
                                VpnFileLogger.d(TAG, "tun2socks: $line")
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (currentState != V2RayState.DISCONNECTED && tun2socksProcess?.isAlive == true) {
                        VpnFileLogger.w(TAG, "读取tun2socks输出失败", e)
                    }
                }
            }
            
            // 监控进程状态
            serviceScope.launch {
                try {
                    val exitCode = process.waitFor()
                    if (currentState == V2RayState.DISCONNECTED) {
                        VpnFileLogger.d(TAG, "tun2socks进程正常退出,退出码: $exitCode")
                    } else {
                        VpnFileLogger.w(TAG, "tun2socks进程异常退出,退出码: $exitCode")
                        
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
            
            VpnFileLogger.d(TAG, "tun2socks进程已启动,PID: ${process.toString()}")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动tun2socks失败", e)
            throw e
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
     * 重启tun2socks进程
     */
    private suspend fun restartTun2socks(): Unit = withContext(Dispatchers.IO) {
        try {
            tun2socksRestartCount++
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
            
            VpnFileLogger.d(TAG, "TUN FD: $tunFd, Socket路径: $sockPath")
            
            var tries = 0
            val maxTries = 10  // 增加重试次数
            
            while (tries < maxTries) {
                try {
                    delay(100L * tries)  // 逐渐增加延迟
                    
                    VpnFileLogger.d(TAG, "尝试连接Unix域套接字 (第${tries + 1}/$maxTries次)")
                    
                    val clientSocket = LocalSocket()
                    clientSocket.connect(LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM))
                    
                    VpnFileLogger.d(TAG, "Unix域套接字连接成功,发送文件描述符...")
                    
                    val outputStream = clientSocket.outputStream
                    clientSocket.setFileDescriptorsForSend(arrayOf(tunFd))
                    outputStream.write(32)  // 发送一个字节触发传输
                    outputStream.flush()
                    
                    clientSocket.setFileDescriptorsForSend(null)
                    clientSocket.shutdownOutput()
                    clientSocket.close()
                    
                    VpnFileLogger.d(TAG, "✓ 文件描述符传递成功")
                    return@withContext true
                    
                } catch (e: Exception) {
                    tries++
                    if (tries >= maxTries) {
                        VpnFileLogger.e(TAG, "✗ 文件描述符传递失败,已达最大重试次数", e)
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
     * 启动流量监控
     */
    private fun startTrafficMonitor() {
        VpnFileLogger.d(TAG, "启动流量监控,更新间隔: ${STATS_UPDATE_INTERVAL}ms")
        
        statsJob?.cancel()
        
        statsJob = serviceScope.launch {
            delay(5000)  // 延迟5秒开始
            
            while (currentState == V2RayState.CONNECTED && isActive) {
                try {
                    updateTrafficStats()
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "更新流量统计异常", e)
                }
                
                delay(STATS_UPDATE_INTERVAL)
            }
        }
    }
    
    /**
     * 按需更新流量统计
     */
    private fun updateTrafficStatsOnDemand() {
        if (currentState != V2RayState.CONNECTED) return
        
        val now = System.currentTimeMillis()
        if (now - lastOnDemandUpdateTime < 1000) {
            return
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
     */
    private fun updateTrafficStats() {
        try {
            val controller = coreController ?: return
            
            // 查询流量统计 - 记录详细的查询结果
            val proxyUplink = controller.queryStats("outbound>>>proxy>>>traffic>>>uplink", "")
            val proxyDownlink = controller.queryStats("outbound>>>proxy>>>traffic>>>downlink", "")
            
            val directUplink = controller.queryStats("outbound>>>direct>>>traffic>>>uplink", "")
            val directDownlink = controller.queryStats("outbound>>>direct>>>traffic>>>downlink", "")
            val blockUplink = controller.queryStats("outbound>>>block>>>traffic>>>uplink", "")
            val blockDownlink = controller.queryStats("outbound>>>block>>>traffic>>>downlink", "")
            
            // 记录各个出站的流量
            if (proxyUplink > 0 || proxyDownlink > 0) {
                VpnFileLogger.d(TAG, "代理流量: ↑${formatBytes(proxyUplink)} ↓${formatBytes(proxyDownlink)}")
            }
            if (directUplink > 0 || directDownlink > 0) {
                VpnFileLogger.d(TAG, "直连流量: ↑${formatBytes(directUplink)} ↓${formatBytes(directDownlink)}")
            }
            if (blockUplink > 0 || blockDownlink > 0) {
                VpnFileLogger.d(TAG, "阻止流量: ↑${formatBytes(blockUplink)} ↓${formatBytes(blockDownlink)}")
            }
            
            var currentUpload = proxyUplink + directUplink + blockUplink
            var currentDownload = proxyDownlink + directDownlink + blockDownlink
            
            // 如果没有分类统计，尝试获取总统计
            if (proxyUplink == 0L && proxyDownlink == 0L) {
                val totalUplink = controller.queryStats("outbound>>>traffic>>>uplink", "")
                val totalDownlink = controller.queryStats("outbound>>>traffic>>>downlink", "")
                
                if (totalUplink > 0 || totalDownlink > 0) {
                    currentUpload = totalUplink
                    currentDownload = totalDownlink
                    VpnFileLogger.d(TAG, "总流量: ↑${formatBytes(totalUplink)} ↓${formatBytes(totalDownlink)}")
                }
            }
            
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
                        uploadSpeed = 0
                        downloadSpeed = 0
                    }
                }
            }
            
            lastQueryTime = now
            lastUploadTotal = uploadBytes
            lastDownloadTotal = downloadBytes
            
            if (enableAutoStats) {
                updateNotification()
            }
            
            // 只在有流量时记录
            if (uploadBytes > 0 || downloadBytes > 0 || uploadSpeed > 0 || downloadSpeed > 0) {
                VpnFileLogger.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}, " +
                          "速度: ↑${formatBytes(uploadSpeed)}/s ↓${formatBytes(downloadSpeed)}/s")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "查询流量统计失败", e)
        }
    }
    
    /**
     * 测量已连接服务器的延迟
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
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "开始停止V2Ray服务")
        VpnFileLogger.d(TAG, "========================================")
        
        currentState = V2RayState.DISCONNECTED
        
        // 取消统计任务
        statsJob?.cancel()
        statsJob = null
        
        // 通知MainActivity服务已停止
        sendBroadcast(Intent(ACTION_VPN_STOPPED))
        VpnFileLogger.d(TAG, "已发送VPN停止广播")
        
        // 停止tun2socks
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
        
        // 关闭VPN接口
        if (mode == ConnectionMode.VPN_TUN) {
            try {
                mInterface?.close()
                mInterface = null
                VpnFileLogger.d(TAG, "VPN接口已关闭")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
            }
        }
        
        stopForeground(true)
        stopSelf()
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止")
    }
    
    /**
     * 创建前台服务通知
     */
    private fun createNotification(): android.app.Notification? {
        try {
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
            
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
            val title = "$appName - $modeText"
            
            val content = formatTrafficStatsForNotification(0L, 0L)
            
            val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(mainPendingIntent)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel, 
                    instanceLocalizedStrings["disconnectButtonName"] ?: "断开",
                    stopPendingIntent
                )
            
            return builder.build()
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "创建通知失败", e)
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
            packageManager.getApplicationInfo(packageName, 0).icon
        } catch (e: Exception) {
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
     * 更新通知显示流量信息
     */
    private fun updateNotification() {
        try {
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
            
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN"
            val title = "$appName - $modeText"
            
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
            
            val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .setContentIntent(mainPendingIntent)
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
    
    override fun startup(): Long {
        VpnFileLogger.d(TAG, "【CoreCallback】startup() 被调用")
        VpnFileLogger.d(TAG, "V2Ray核心启动完成通知")
        return 0L
    }
    
    override fun shutdown(): Long {
        VpnFileLogger.d(TAG, "【CoreCallback】shutdown() 被调用")
        
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
            // 增强V2Ray核心日志记录
            val levelName = when (level.toInt()) {
                0 -> "DEBUG"
                1 -> "INFO"
                2 -> "WARN"
                3 -> "ERROR"
                4 -> "FATAL"
                else -> "LEVEL$level"
            }
            
            val message = "[V2Ray-$levelName] $status"
            
            when (level.toInt()) {
                0 -> VpnFileLogger.d(TAG, message)
                1 -> VpnFileLogger.i(TAG, message)
                2 -> VpnFileLogger.w(TAG, message)
                3 -> VpnFileLogger.e(TAG, message)
                4 -> VpnFileLogger.e(TAG, message)
                else -> VpnFileLogger.d(TAG, message)
            }
            
            // 记录关键状态变化
            if (status != null) {
                if (status.contains("started", ignoreCase = true)) {
                    VpnFileLogger.i(TAG, "★ V2Ray核心已启动")
                } else if (status.contains("stopped", ignoreCase = true)) {
                    VpnFileLogger.i(TAG, "★ V2Ray核心已停止")
                } else if (status.contains("failed", ignoreCase = true) || 
                           status.contains("error", ignoreCase = true)) {
                    VpnFileLogger.e(TAG, "★ V2Ray核心错误: $status")
                }
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
        
        VpnFileLogger.d(TAG, "========================================")
        VpnFileLogger.d(TAG, "onDestroy开始")
        VpnFileLogger.d(TAG, "========================================")
        
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
            
            if (mode == ConnectionMode.VPN_TUN) {
                stopTun2socks()
            }
            
            try {
                coreController?.stopLoop()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
            }
            
            try {
                mInterface?.close()
                mInterface = null
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
            }
        }
        
        coreController = null
        
        VpnFileLogger.d(TAG, "onDestroy完成,服务已销毁")
        VpnFileLogger.d(TAG, "========================================")
        
        runBlocking {
            VpnFileLogger.flushAll()
        }
        VpnFileLogger.close()
    }
}
