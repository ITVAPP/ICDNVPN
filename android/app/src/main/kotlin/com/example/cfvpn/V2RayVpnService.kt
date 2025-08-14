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

// 正确的导入(基于method_summary.md)
import go.Seq
import libv2ray.Libv2ray
import libv2ray.CoreController
import libv2ray.CoreCallbackHandler

/**
 * V2Ray VPN服务实现 - 完整版（包含连接保持机制）
 * 优化版本：包含缓冲区优化、MTU优化、连接保持优化和流量统计优化
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
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"
        
        // WakeLock标签
        private const val WAKELOCK_TAG = "cfvpn:v2ray"
        
        // VPN配置常量（与v2rayNG保持一致）
        // 优化2: MTU优化 - 增加MTU值以提高吞吐量（需要测试网络兼容性）
        private const val VPN_MTU = 1500  // 可根据网络环境调整，某些网络支持9000
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        private const val PRIVATE_VLAN6_ROUTER = "da26:2626::2"
        
        // V2Ray端口默认值
        private const val DEFAULT_SOCKS_PORT = 7898
        
        // 流量统计配置
        // 优化4: 流量统计优化 - 减少查询频率
        private const val STATS_UPDATE_INTERVAL = 10000L 
        
        // tun2socks重启限制
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L
        
        // tun2socks二进制文件名（与v2rayNG一致）
        private const val TUN2SOCKS = "libtun2socks.so"
        
        // 连接检查间隔
        // 优化3: 连接保持优化 - 调整检查间隔为60秒
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
         * 启动VPN服务 - 简化版
         * 
         * @param allowedApps 允许走VPN的应用列表（空列表或null表示所有应用）
         */
        @JvmStatic
        fun startVpnService(
            context: Context, 
            config: String,
            mode: ConnectionMode = ConnectionMode.VPN_TUN,
            globalProxy: Boolean = false,
            blockedApps: List<String>? = null,  // 保留接口兼容性，但不使用
            allowedApps: List<String>? = null,  // 简化：只保留允许列表
            appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE,  // 保留接口兼容性，但不使用
            bypassSubnets: List<String>? = null,
            enableAutoStats: Boolean = true,
            disconnectButtonName: String = "停止",
            localizedStrings: Map<String, String> = emptyMap()
        ) {
            VpnFileLogger.d(TAG, "准备启动服务,模式: $mode, 全局代理: $globalProxy")
            VpnFileLogger.d(TAG, "允许应用: ${allowedApps?.size ?: "全部"}")
            
            // 保存国际化文字
            this.localizedStrings.clear()
            this.localizedStrings.putAll(localizedStrings)
            
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN"
                putExtra("config", config)
                putExtra("mode", mode.name)
                putExtra("globalProxy", globalProxy)
                putExtra("enableAutoStats", enableAutoStats)
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
         * 返回当前通知栏显示的实时流量数据
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
    private var mode: ConnectionMode = ConnectionMode.VPN_TUN
    private var globalProxy: Boolean = false
    private var allowedApps: List<String> = emptyList()  // 简化：只保留允许列表
    private var bypassSubnets: List<String> = emptyList()
    private var enableAutoStats: Boolean = true
    
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
    
    // 优化4: 批量查询缓存
    private data class StatsData(
        val tag: String,
        var uplink: Long = 0L,
        var downlink: Long = 0L
    )
    private val statsCache = mutableListOf<StatsData>()
    
    // 系统流量统计初始值（备用方案）
    private var initialUploadBytes: Long? = null
    private var initialDownloadBytes: Long? = null
    
    // 统计任务
    private var statsJob: Job? = null
    
    // 连接检查任务
    private var connectionCheckJob: Job? = null
    
    // 添加启动完成标志
    @Volatile
    private var v2rayCoreStarted = false
    private val startupLatch = CompletableDeferred<Boolean>()
    
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
        VpnFileLogger.d(TAG, "VPN服务onCreate开始")
        
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
        
        // 初始化V2Ray环境
        try {
            val envPath = filesDir.absolutePath
            Libv2ray.initCoreEnv(envPath, "")
            VpnFileLogger.d(TAG, "V2Ray环境初始化成功: $envPath")
            
            val version = Libv2ray.checkVersionX()
            VpnFileLogger.i(TAG, "V2Ray版本: $version")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "V2Ray环境初始化失败", e)
        }
        
        // 复制资源文件
        copyAssetFiles()
        
        // 获取WakeLock
        acquireWakeLock()
        
        // 优化4: 初始化统计缓存
        initStatsCache()
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成")
    }
    
    /**
     * 优化4: 初始化流量统计缓存
     */
    private fun initStatsCache() {
        statsCache.clear()
        // 预先添加需要查询的标签
        statsCache.add(StatsData("proxy"))
        statsCache.add(StatsData("direct"))
        statsCache.add(StatsData("block"))
        statsCache.add(StatsData("proxy3"))
        VpnFileLogger.d(TAG, "流量统计缓存初始化完成，监控${statsCache.size}个标签")
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
        
        if (intent == null || intent.action != "START_VPN") {
            VpnFileLogger.e(TAG, "无效的启动意图: intent=$intent, action=${intent?.action}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        if (currentState == V2RayState.CONNECTED) {
            VpnFileLogger.w(TAG, "VPN服务已在运行，当前状态: $currentState")
            return START_STICKY
        }
        
        currentState = V2RayState.CONNECTING
        
        // 重置启动标志
        v2rayCoreStarted = false
        
        // 获取并记录完整配置
        configJson = intent.getStringExtra("config") ?: ""
        
        // 记录完整的V2Ray配置内容
        VpnFileLogger.d(TAG, "=============== 完整V2Ray配置 ===============")
        VpnFileLogger.d(TAG, configJson)
        VpnFileLogger.d(TAG, "=============== 配置结束 ===============")
        
        // 解析并验证配置
        try {
            val config = JSONObject(configJson)
            
            // 记录关键配置信息
            VpnFileLogger.d(TAG, "===== 配置解析 =====")
            
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
                }
            }
            
            // 日志配置
            val log = config.optJSONObject("log")
            VpnFileLogger.d(TAG, "日志级别: ${log?.optString("loglevel", "info")}")
            VpnFileLogger.d(TAG, "访问日志: ${log?.optString("access", "info")}")
            VpnFileLogger.d(TAG, "错误日志: ${log?.optString("error", "info")}")
            
            // 入站配置
            val inbounds = config.optJSONArray("inbounds")
            VpnFileLogger.d(TAG, "入站数量: ${inbounds?.length() ?: 0}")
            for (i in 0 until (inbounds?.length() ?: 0)) {
                val inbound = inbounds!!.getJSONObject(i)
                VpnFileLogger.d(TAG, "入站[$i]: ${inbound.toString()}")
            }
            
            // 出站配置 - 完整记录
            val outbounds = config.optJSONArray("outbounds")
            VpnFileLogger.d(TAG, "出站数量: ${outbounds?.length() ?: 0}")
            for (i in 0 until (outbounds?.length() ?: 0)) {
                val outbound = outbounds!!.getJSONObject(i)
                VpnFileLogger.d(TAG, "出站[$i]: ${outbound.toString()}")
            }
            
            // 路由配置
            val routing = config.optJSONObject("routing")
            if (routing != null) {
                VpnFileLogger.d(TAG, "路由配置: ${routing.toString()}")
            }
            
            // DNS配置
            val dns = config.optJSONObject("dns")
            if (dns != null) {
                VpnFileLogger.d(TAG, "DNS配置: ${dns.toString()}")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "配置解析失败", e)
            VpnFileLogger.e(TAG, "原始配置: $configJson")
        }
        
        // 记录其他参数
        mode = try {
            ConnectionMode.valueOf(intent.getStringExtra("mode") ?: ConnectionMode.VPN_TUN.name)
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "解析mode失败: ${intent.getStringExtra("mode")}", e)
            ConnectionMode.VPN_TUN
        }
        
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        enableAutoStats = intent.getBooleanExtra("enableAutoStats", true)
        
        // 简化：只获取允许列表
        allowedApps = intent.getStringArrayListExtra("allowedApps") ?: emptyList()
        bypassSubnets = intent.getStringArrayListExtra("bypassSubnets") ?: emptyList()
        
        VpnFileLogger.d(TAG, "===== 启动参数 =====")
        VpnFileLogger.d(TAG, "模式: $mode")
        VpnFileLogger.d(TAG, "全局代理: $globalProxy")
        VpnFileLogger.d(TAG, "允许应用: ${if (allowedApps.isEmpty()) "全部" else "${allowedApps.size}个: $allowedApps"}")
        VpnFileLogger.d(TAG, "绕过子网: $bypassSubnets")
        VpnFileLogger.d(TAG, "自动统计: $enableAutoStats")
        
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
        
        VpnFileLogger.d(TAG, "配置参数: 模式=$mode, 全局代理=$globalProxy, " +
                "允许应用=${allowedApps.size}个, 绕过子网=${bypassSubnets.size}个")
        
        // 启动前台服务
        try {
            val notification = createNotification()
            if (notification != null) {
                startForeground(NOTIFICATION_ID, notification)
                VpnFileLogger.d(TAG, "前台服务已启动")
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
        if (mode == ConnectionMode.VPN_TUN) {
            val prepare = prepare(this)
            if (prepare != null) {
                VpnFileLogger.e(TAG, "VPN未授权，需要用户授权")
                currentState = V2RayState.DISCONNECTED
                sendStartResultBroadcast(false, "需要VPN授权")
                // 这里可以启动授权Activity或返回错误
                stopSelf()
                return START_NOT_STICKY
            }
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
                sendStartResultBroadcast(false, "启动失败: ${e.message}")
                withContext(Dispatchers.Main) {
                    stopSelf()
                }
            }
        }
        
        return START_STICKY
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
     * 启动V2Ray(VPN模式) - 优化版
     */
    private suspend fun startV2RayWithVPN() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "================== startV2RayWithVPN START ==================")
        
        try {
            // 调整启动顺序：先启动V2Ray核心，再建立VPN（与v2rayNG一致）
            
            // 步骤1: 创建核心控制器
            VpnFileLogger.d(TAG, "===== 步骤1: 创建核心控制器 =====")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                VpnFileLogger.e(TAG, "创建CoreController失败: 返回null")
                throw Exception("创建CoreController失败")
            }
            VpnFileLogger.d(TAG, "CoreController创建成功")
            
            // 步骤2: 启动V2Ray核心
            VpnFileLogger.d(TAG, "===== 步骤2: 启动V2Ray核心 =====")
            VpnFileLogger.d(TAG, "原始配置长度: ${configJson.length} 字符")
            
            VpnFileLogger.d(TAG, "调用 coreController.startLoop()...")
            coreController?.startLoop(configJson)
            VpnFileLogger.d(TAG, "coreController.startLoop() 调用完成")
            
            // 等待startup()回调确认启动成功
            VpnFileLogger.d(TAG, "等待V2Ray核心启动回调...")
            val startupSuccess = withTimeoutOrNull(5000L) {
                startupLatch.await()
            }
            
            if (startupSuccess != true) {
                throw Exception("V2Ray核心启动超时或失败")
            }
            
            VpnFileLogger.i(TAG, "V2Ray核心启动成功（已确认）")
            
            // 步骤3: 建立VPN隧道
            VpnFileLogger.d(TAG, "步骤3: 建立VPN隧道")
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
            
            // 步骤4: 启动tun2socks进程（与v2rayNG一致）
            VpnFileLogger.d(TAG, "===== 步骤4: 启动tun2socks进程 (badvpn-tun2socks) =====")
            runTun2socks()
            
            // 步骤5: 更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "================== V2Ray服务(VPN模式)完全启动成功 ==================")
            
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
            
            // 启动简化的流量监控（只用于通知栏显示）
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动流量统计监控")
                startSimpleTrafficMonitor()
            }
            
            // 优化3: 启动连接保持检查
            startConnectionCheck()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray(VPN模式)失败", e)
            cleanupResources()
            sendStartResultBroadcast(false, e.message)
            throw e
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
     * 启动V2Ray(仅代理模式) - 优化版
     */
    private suspend fun startV2RayProxyOnly() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "开始启动V2Ray(仅代理模式)")
        
        try {
            // 步骤1: 创建核心控制器
            VpnFileLogger.d(TAG, "步骤1: 创建核心控制器")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败")
            }
            
            // 步骤2: 启动V2Ray核心 - 直接使用dart生成的配置
            VpnFileLogger.d(TAG, "步骤2: 启动V2Ray核心")
            coreController?.startLoop(configJson)
            
            // 等待startup()回调确认启动成功
            VpnFileLogger.d(TAG, "等待V2Ray核心启动回调...")
            val startupSuccess = withTimeoutOrNull(5000L) {
                startupLatch.await()
            }
            
            if (startupSuccess != true) {
                throw Exception("V2Ray核心启动超时或失败")
            }
            
            // 步骤3: 更新状态
            currentState = V2RayState.CONNECTED
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "V2Ray服务(仅代理模式)启动成功")
            
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
            
            // 启动简化的流量监控
            if (enableAutoStats) {
                VpnFileLogger.d(TAG, "启动流量统计监控")
                startSimpleTrafficMonitor()
            }
            
            // 优化3: 启动连接保持检查
            startConnectionCheck()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray(仅代理模式)失败", e)
            cleanupResources()
            sendStartResultBroadcast(false, e.message)
            throw e
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
                    if (mode == ConnectionMode.VPN_TUN) {
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
        
        // 停止连接检查
        connectionCheckJob?.cancel()
        connectionCheckJob = null
        
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
     * 建立VPN隧道 - 简化DNS配置版
     */
    private fun establishVpn() {
        VpnFileLogger.d(TAG, "开始建立VPN隧道（简化DNS配置版）")
        
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
        
        // IPv6地址(可选)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126)
                VpnFileLogger.d(TAG, "添加IPv6地址: $PRIVATE_VLAN6_CLIENT/126")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加IPv6地址失败", e)
            }
        }
        
        // ===== 简化的DNS配置 =====
        VpnFileLogger.d(TAG, "===== 配置DNS（简化版） =====")
        
        // 直接使用可靠的公共DNS
        try {
            builder.addDnsServer("1.1.1.1")  // Cloudflare主DNS
            VpnFileLogger.d(TAG, "添加DNS: 1.1.1.1")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "添加Cloudflare DNS失败", e)
        }
        
        try {
            builder.addDnsServer("1.0.0.1")  // Cloudflare备DNS
            VpnFileLogger.d(TAG, "添加备用DNS: 1.0.0.1")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "添加Cloudflare备用DNS失败", e)
        }
        
        // 路由规则配置
        if (globalProxy) {
            // 全局代理模式：所有流量都走VPN
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
            // 智能分流模式 - 检查是否需要绕过局域网
            if (shouldBypassLan()) {
                VpnFileLogger.d(TAG, "智能分流模式：绕过局域网")
                // 根据v2rayNG的做法，添加需要代理的公网路由
                val routedIpList = listOf(
                    "0.0.0.0/5",
                    "8.0.0.0/7",
                    "11.0.0.0/8",
                    "12.0.0.0/6",
                    "16.0.0.0/4",
                    "32.0.0.0/3",
                    "64.0.0.0/2",
                    "128.0.0.0/3",
                    "160.0.0.0/5",
                    "168.0.0.0/6",
                    "172.0.0.0/12",
                    "172.32.0.0/11",
                    "172.64.0.0/10",
                    "172.128.0.0/9",
                    "173.0.0.0/8",
                    "174.0.0.0/7",
                    "176.0.0.0/4",
                    "192.0.0.0/9",
                    "192.128.0.0/11",
                    "192.160.0.0/13",
                    "192.169.0.0/16",
                    "192.170.0.0/15",
                    "192.172.0.0/14",
                    "192.176.0.0/12",
                    "192.192.0.0/10",
                    "193.0.0.0/8",
                    "194.0.0.0/7",
                    "196.0.0.0/6",
                    "200.0.0.0/5",
                    "208.0.0.0/4",
                    "240.0.0.0/4"
                )
                
                routedIpList.forEach { subnet ->
                    try {
                        val parts = subnet.split("/")
                        if (parts.size == 2) {
                            builder.addRoute(parts[0], parts[1].toInt())
                        }
                    } catch (e: Exception) {
                        VpnFileLogger.w(TAG, "添加路由失败: $subnet", e)
                    }
                }
            } else {
                // 不绕过局域网，所有流量都走VPN
                VpnFileLogger.d(TAG, "智能分流模式：所有流量走VPN")
                builder.addRoute("0.0.0.0", 0)
            }
        }
        
        // ===== 分应用代理 (Android 5.0+) =====
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // 始终排除自身
            try {
                builder.addDisallowedApplication(packageName)
                VpnFileLogger.d(TAG, "自动排除自身应用: $packageName")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "排除自身应用失败", e)
            }
            
            // 简化逻辑：只使用允许列表
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
     * 判断是否应该绕过局域网
     * 根据V2Ray配置中的路由规则判断
     */
    private fun shouldBypassLan(): Boolean {
        // 全局代理模式不绕过局域网
        if (globalProxy) {
            return false
        }
        
        try {
            val config = JSONObject(configJson)
            val routing = config.optJSONObject("routing")
            
            if (routing != null) {
                val rules = routing.optJSONArray("rules")
                if (rules != null) {
                    for (i in 0 until rules.length()) {
                        val rule = rules.getJSONObject(i)
                        // 查找是否有规则将私有IP设置为直连
                        if (rule.optString("outboundTag") == "direct") {
                            val ip = rule.optJSONArray("ip")
                            if (ip != null) {
                                for (j in 0 until ip.length()) {
                                    val ipRule = ip.getString(j)
                                    if (ipRule == "geoip:private") {
                                        VpnFileLogger.d(TAG, "配置中包含绕过局域网规则")
                                        return true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "判断是否绕过局域网失败", e)
        }
        
        // 默认绕过局域网（智能分流模式）
        return true
    }
    
    /**
     * 优化1: 启动tun2socks进程 - 添加缓冲区优化参数
     * 修复：移除日志读取线程，只监控进程状态
     */
    private fun runTun2socks() {
        if (mode != ConnectionMode.VPN_TUN) {
            VpnFileLogger.d(TAG, "非VPN模式,跳过tun2socks")
            return
        }
        
        VpnFileLogger.d(TAG, "===== 启动tun2socks进程 (badvpn-tun2socks) - 优化版 =====")
        
        // 从配置中提取SOCKS端口
        val socksPort = try {
            val config = JSONObject(configJson)
            val inbounds = config.getJSONArray("inbounds")
            var port = DEFAULT_SOCKS_PORT
            for (i in 0 until inbounds.length()) {
                val inbound = inbounds.getJSONObject(i)
                if (inbound.optString("tag") == "socks") {
                    port = inbound.optInt("port", DEFAULT_SOCKS_PORT)
                    VpnFileLogger.d(TAG, "找到SOCKS端口: $port")
                    break
                }
            }
            port
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "解析SOCKS端口失败，使用默认端口: $DEFAULT_SOCKS_PORT", e)
            DEFAULT_SOCKS_PORT
        }
        
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
        
        VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
        
        try {
            val proBuilder = ProcessBuilder(cmd)
            proBuilder.redirectErrorStream(true)  // 合并错误流到标准输出
            process = proBuilder
                .directory(applicationContext.filesDir)
                .start()
            
            // 修复：移除日志读取线程，只监控进程状态
            Thread {
                VpnFileLogger.d(TAG, "$TUN2SOCKS 进程监控开始")
                val exitCode = process?.waitFor()
                VpnFileLogger.d(TAG, "$TUN2SOCKS 进程退出，退出码: $exitCode")
                
                if (currentState == V2RayState.CONNECTED) {
                    VpnFileLogger.e(TAG, "$TUN2SOCKS 意外退出，退出码: $exitCode")
                    
                    // 优化3: 改进的重启逻辑
                    if (shouldRestartTun2socks()) {
                        VpnFileLogger.w(TAG, "尝试重启tun2socks (第${tun2socksRestartCount + 1}次)")
                        Thread.sleep(1000)  // 等待1秒再重启
                        restartTun2socks()
                    } else {
                        VpnFileLogger.e(TAG, "tun2socks重启次数达到上限，停止服务")
                        stopV2Ray()
                    }
                }
            }.start()
            
            // 检查进程是否成功启动
            Thread {
                Thread.sleep(1000)  // 给进程一秒钟启动时间
                if (process?.isAlive != true) {
                    VpnFileLogger.e(TAG, "${TUN2SOCKS}进程启动后立即退出")
                } else {
                    VpnFileLogger.i(TAG, "${TUN2SOCKS}进程运行正常")
                }
            }.start()
            
            // 发送文件描述符（与v2rayNG一致）
            Thread.sleep(500)  // 等待tun2socks准备就绪
            sendFd()
            
            VpnFileLogger.d(TAG, "tun2socks进程启动完成（优化版）")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动tun2socks失败", e)
            throw e
        }
    }
    
    /**
     * 发送文件描述符给tun2socks（与v2rayNG完全一致）
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
     */
    private fun stopTun2socks() {
        VpnFileLogger.d(TAG, "停止tun2socks进程")
        
        tun2socksRestartCount = 0
        tun2socksFirstRestartTime = 0L
        
        try {
            process?.let {
                it.destroy()
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
     */
    private fun startSimpleTrafficMonitor() {
        VpnFileLogger.d(TAG, "启动流量监控")
        
        statsJob?.cancel()
        
        // 初始化系统流量统计基准值（备用方案）
        try {
            val uid = android.os.Process.myUid()
            initialUploadBytes = android.net.TrafficStats.getUidTxBytes(uid)
            initialDownloadBytes = android.net.TrafficStats.getUidRxBytes(uid)
            VpnFileLogger.d(TAG, "系统流量基准值: ↑${formatBytes(initialUploadBytes ?: 0)} ↓${formatBytes(initialDownloadBytes ?: 0)}")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "获取系统流量基准值失败", e)
        }
        
        statsJob = serviceScope.launch {
            // 修复：立即执行一次，不要延迟
            updateSimpleTrafficStats()
            
            while (currentState == V2RayState.CONNECTED && isActive) {
                delay(STATS_UPDATE_INTERVAL)
                
                try {
                    updateSimpleTrafficStats()
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "更新流量统计异常", e)
                }
            }
        }
    }
    
    /**
     * 优化4: 真实的流量统计更新 - 批量查询优化
     * 使用libv2ray.aar的queryStats方法获取实际流量数据
     * 修复：确保流量数据正确更新
     */
    private fun updateSimpleTrafficStats() {
        try {
            // 优化4: 批量查询所有标签的流量，减少JNI调用
            var totalUpload = 0L
            var totalDownload = 0L
            
            // 一次性查询所有缓存的标签
            for (stats in statsCache) {
                // 查询上行流量
                val uplink = coreController?.queryStats(stats.tag, "uplink") ?: 0L
                // 查询下行流量
                val downlink = coreController?.queryStats(stats.tag, "downlink") ?: 0L
                
                stats.uplink = uplink
                stats.downlink = downlink
                
                totalUpload += uplink
                totalDownload += downlink
            }
            
            // 计算速度
            val currentTime = System.currentTimeMillis()
            val timeDiff = (currentTime - lastStatsTime) / 1000.0
            
            if (timeDiff > 0 && lastStatsTime > 0) {
                val uploadDiff = totalUpload - lastUploadBytes
                val downloadDiff = totalDownload - lastDownloadBytes
                
                if (uploadDiff >= 0 && downloadDiff >= 0) {
                    uploadSpeed = (uploadDiff / timeDiff).toLong()
                    downloadSpeed = (downloadDiff / timeDiff).toLong()
                }
            }
            
            // 修复：更新流量值（这是关键修复点）
            uploadBytes = totalUpload
            downloadBytes = totalDownload
            lastUploadBytes = totalUpload
            lastDownloadBytes = totalDownload
            lastStatsTime = currentTime
            
            // 更新通知栏显示（显示总流量）
            if (enableAutoStats) {
                updateNotification()
            }
            
            // 只在流量有变化时记录日志
            if (totalUpload > 0 || totalDownload > 0) {
                val statsLog = StringBuilder("流量统计 - ")
                for (stats in statsCache) {
                    if (stats.uplink > 0 || stats.downlink > 0) {
                        statsLog.append("${stats.tag}: ↑${formatBytes(stats.uplink)} ↓${formatBytes(stats.downlink)} | ")
                    }
                }
                statsLog.append("总计: ↑${formatBytes(totalUpload)} ↓${formatBytes(totalDownload)}")
                VpnFileLogger.d(TAG, statsLog.toString())
            }
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "查询流量统计失败，使用备用方案", e)
            
            // 备用方案：如果queryStats失败，尝试使用其他方法
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
            } catch (e2: Exception) {
                VpnFileLogger.e(TAG, "备用流量统计也失败", e2)
            }
        }
    }
    
    /**
     * 获取当前流量统计（供dart端查询）
     * 返回当前通知栏显示的实时流量数据
     * 修复：确保能立即返回有效数据
     */
    fun getCurrentTrafficStats(): Map<String, Long> {
        // 如果服务正在运行，尝试更新一次最新数据
        if (currentState == V2RayState.CONNECTED && coreController != null) {
            try {
                // 优化4: 快速查询一次最新流量（批量查询）
                var totalUpload = 0L
                var totalDownload = 0L
                
                for (stats in statsCache) {
                    totalUpload += coreController?.queryStats(stats.tag, "uplink") ?: 0L
                    totalDownload += coreController?.queryStats(stats.tag, "downlink") ?: 0L
                }
                
                // 修复：立即更新值
                if (totalUpload > 0 || totalDownload > 0) {
                    uploadBytes = totalUpload
                    downloadBytes = totalDownload
                }
                
                VpnFileLogger.d(TAG, "实时查询流量: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "实时查询流量失败，返回缓存数据", e)
            }
        }
        
        return mapOf(
            "uploadTotal" to uploadBytes,
            "downloadTotal" to downloadBytes,
            "uploadSpeed" to uploadSpeed,
            "downloadSpeed" to downloadSpeed,
            "startTime" to startTime  // 添加启动时间，供计算连接时长
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
        
        // 重要：stopSelf必须在mInterface.close()之前调用
        // v2rayNG的注释：stopSelf has to be called ahead of mInterface.close(). 
        // otherwise v2ray core cannot be stopped. It's strange but true.
        stopForeground(true)
        stopSelf()
        VpnFileLogger.d(TAG, "服务已停止")
        
        // 关闭VPN接口（在stopSelf之后）
        if (mode == ConnectionMode.VPN_TUN) {
            try {
                mInterface?.close()
                mInterface = null
                VpnFileLogger.d(TAG, "VPN接口已关闭")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
            }
        }
        
        // 释放WakeLock
        releaseWakeLock()
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止")
    }
    
    /**
     * 创建前台服务通知
     * 修复：初始显示时也显示流量（如果有的话）
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
            
            // 修复：初始也显示流量（总流量）
            val content = formatTrafficStatsForNotification(uploadBytes, downloadBytes)
            
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
     * 修复：显示总流量而不是速度
     */
    private fun formatTrafficStatsForNotification(upload: Long, download: Long): String {
        val template = instanceLocalizedStrings["trafficStatsFormat"] ?: "流量: ↑%upload ↓%download"
        return template
            .replace("%upload", formatBytes(upload))
            .replace("%download", formatBytes(download))
    }
    
    /**
     * 更新通知显示流量信息
     * 修复：确保显示总流量
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
            
            // 修复：显示总流量而不是速度
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
    
    // ===== CoreCallbackHandler 接口实现 - 优化版 =====
    
    override fun startup(): Long {
        VpnFileLogger.d(TAG, "========== CoreCallbackHandler.startup() 被调用 ==========")
        VpnFileLogger.i(TAG, "V2Ray核心启动完成通知")
        
        // 立即查询一次状态以验证
        try {
            val isRunning = coreController?.isRunning ?: false
            VpnFileLogger.d(TAG, "V2Ray核心运行状态(在startup回调中): $isRunning")
            
            // 设置启动成功标志
            v2rayCoreStarted = true
            startupLatch.complete(true)
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "查询V2Ray状态失败", e)
            startupLatch.complete(false)
        }
        
        return 0L
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
            
            // 记录所有V2Ray日志，不过滤
            VpnFileLogger.d(TAG, "[V2Ray-$levelName] $status")
            
            // 对重要事件使用不同的日志级别
            if (status != null) {
                when {
                    status.contains("failed", ignoreCase = true) || 
                    status.contains("error", ignoreCase = true) -> {
                        VpnFileLogger.e(TAG, "[V2Ray错误] $status")
                    }
                    status.contains("warning", ignoreCase = true) -> {
                        VpnFileLogger.w(TAG, "[V2Ray警告] $status")
                    }
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
            
            if (mode == ConnectionMode.VPN_TUN) {
                stopTun2socks()
            }
            
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
