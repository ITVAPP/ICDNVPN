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
 * 
 * 核心原则：
 * 1. 配置处理完全由dart端负责
 * 2. Android端只负责VPN隧道建立和V2Ray核心启动
 * 3. 流量统计按需查询，用于通知栏显示
 * 4. 保持连接稳定性（WakeLock、电池优化等）
 * 
 * 简化改进：
 * - 移除 AppProxyMode 枚举
 * - 移除 blockedApps 参数
 * - 只使用 allowedApps：空列表=全部应用走VPN，非空=仅列表内应用走VPN
 * 
 * 主要功能:
 * - VPN隧道管理
 * - V2Ray核心生命周期管理
 * - tun2socks进程管理 (使用v2rayNG同款的badvpn-tun2socks)
 * - 流量统计和通知更新
 * - 分应用代理支持（简化版）
 * - 连接保持机制（WakeLock、Doze模式处理）
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
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        private const val PRIVATE_VLAN6_ROUTER = "da26:2626::2"
        
        // V2Ray端口默认值
        private const val DEFAULT_SOCKS_PORT = 7898
        
        // 流量统计配置
        private const val STATS_UPDATE_INTERVAL = 10000L  // 10秒更新一次
        
        // tun2socks重启限制
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L
        
        // tun2socks二进制文件名（与v2rayNG一致）
        private const val TUN2SOCKS = "libtun2socks.so"
        
        // 连接检查间隔
        private const val CONNECTION_CHECK_INTERVAL = 30000L  // 30秒检查一次
        
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
         * 返回当前通知栏显示的数据
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
    
    // 简化的流量统计数据（只用于通知栏显示）
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var uploadSpeed: Long = 0
    private var downloadSpeed: Long = 0
    private var lastUploadBytes: Long = 0
    private var lastDownloadBytes: Long = 0
    private var lastStatsTime: Long = 0
    private var startTime: Long = 0
    
    // 统计任务
    private var statsJob: Job? = null
    
    // 连接检查任务
    private var connectionCheckJob: Job? = null
    
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
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成")
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
            
            // 日志配置
            val log = config.optJSONObject("log")
            VpnFileLogger.d(TAG, "日志级别: ${log?.optString("loglevel", "warning")}")
            VpnFileLogger.d(TAG, "访问日志: ${log?.optString("access", "none")}")
            VpnFileLogger.d(TAG, "错误日志: ${log?.optString("error", "none")}")
            
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
     * 启动V2Ray(VPN模式)
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
            
            // 等待核心启动
            delay(1000)  // 增加等待时间
            
            // 验证运行状态
            val isRunningNow = coreController?.isRunning ?: false
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行")
            }
            
            VpnFileLogger.i(TAG, "V2Ray核心启动成功")
            
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
     * 启动V2Ray(仅代理模式)
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
            
            // 等待核心启动
            delay(1000)
            
            // 步骤3: 验证运行状态
            val isRunningNow = coreController?.isRunning ?: false
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行")
            }
            
            // 步骤4: 更新状态
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
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray(仅代理模式)失败", e)
            cleanupResources()
            sendStartResultBroadcast(false, e.message)
            throw e
        }
    }
    
    /**
     * 启动连接状态检查
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
                            if (shouldRestartTun2socks()) {
                                restartTun2socks()
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
     * 建立VPN隧道 - 简化版
     */
    private fun establishVpn() {
        VpnFileLogger.d(TAG, "开始建立VPN隧道")
        
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
        
        // DNS服务器配置 - 使用固定的公共DNS
        builder.addDnsServer("8.8.8.8")
        builder.addDnsServer("1.1.1.1")
        VpnFileLogger.d(TAG, "添加DNS: 8.8.8.8, 1.1.1.1")
        
        // 路由规则配置 - 根据globalProxy参数设置
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
            // 智能分流模式
            if (bypassSubnets.isNotEmpty()) {
                VpnFileLogger.d(TAG, "配置子网绕过: ${bypassSubnets.size}个")
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
                // 默认路由(V2Ray配置控制分流)
                builder.addRoute("0.0.0.0", 0)
                VpnFileLogger.d(TAG, "使用默认全局路由(V2Ray配置控制分流)")
            }
        }
        
        // ===== 简化的分应用代理 (Android 5.0+) =====
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // 始终排除自身
            try {
                builder.addDisallowedApplication(packageName)
                VpnFileLogger.d(TAG, "自动排除自身应用: $packageName")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "排除自身应用失败", e)
            }
            
            // 简化逻辑：只使用允许列表
            // - allowedApps为空 = 所有应用都走VPN（除了自身）
            // - allowedApps不为空 = 只有列表中的应用走VPN
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
     * 启动tun2socks进程 - 修复版：改进日志读取
     */
    private fun runTun2socks() {
        if (mode != ConnectionMode.VPN_TUN) {
            VpnFileLogger.d(TAG, "非VPN模式,跳过tun2socks")
            return
        }
        
        VpnFileLogger.d(TAG, "===== 启动tun2socks进程 (badvpn-tun2socks) =====")
        
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
            "--loglevel", "notice"
        )
        
        VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
        
        try {
            val proBuilder = ProcessBuilder(cmd)
            proBuilder.redirectErrorStream(true)  // 重要：合并错误流到标准输出
            process = proBuilder
                .directory(applicationContext.filesDir)
                .start()
            
            // 改进的日志读取 - 使用最小缓冲区并立即读取
            Thread {
                try {
                    VpnFileLogger.d(TAG, "开始读取${TUN2SOCKS}输出...")
                    
                    // 使用更小的缓冲区并立即刷新
                    val reader = BufferedReader(
                        InputStreamReader(process?.inputStream), 
                        1  // 最小缓冲区，确保立即读取
                    )
                    
                    var line: String?
                    var lineCount = 0
                    
                    // 持续读取直到进程结束
                    while (true) {
                        try {
                            line = reader.readLine()
                            if (line == null) {
                                VpnFileLogger.d(TAG, "${TUN2SOCKS}输出流结束")
                                break
                            }
                            
                            lineCount++
                            
                            // 记录所有输出
                            VpnFileLogger.d("tun2socks", "[$lineCount] $line")
                            
                            // 检查关键日志并高亮
                            when {
                                line.contains("ERROR", ignoreCase = true) -> {
                                    VpnFileLogger.e("tun2socks", "[ERROR] $line")
                                }
                                line.contains("WARNING", ignoreCase = true) || 
                                line.contains("WARN", ignoreCase = true) -> {
                                    VpnFileLogger.w("tun2socks", "[WARNING] $line")
                                }
                                line.contains("NOTICE", ignoreCase = true) || 
                                line.contains("INFO", ignoreCase = true) -> {
                                    VpnFileLogger.i("tun2socks", "[INFO] $line")
                                }
                                line.contains("initializing", ignoreCase = true) || 
                                line.contains("starting", ignoreCase = true) -> {
                                    VpnFileLogger.i("tun2socks", "[启动] $line")
                                }
                                line.contains("exiting", ignoreCase = true) || 
                                line.contains("stopping", ignoreCase = true) -> {
                                    VpnFileLogger.w("tun2socks", "[退出] $line")
                                }
                                line.contains("connected", ignoreCase = true) -> {
                                    VpnFileLogger.i("tun2socks", "[连接] $line")
                                }
                                line.contains("accepted", ignoreCase = true) -> {
                                    VpnFileLogger.i("tun2socks", "[接受] $line")
                                }
                            }
                            
                        } catch (e: Exception) {
                            if (process?.isAlive == true) {
                                VpnFileLogger.e(TAG, "读取${TUN2SOCKS}输出异常", e)
                            }
                            break
                        }
                    }
                    
                    VpnFileLogger.d(TAG, "${TUN2SOCKS}输出读取结束，共读取${lineCount}行")
                    
                    // 关闭reader
                    try {
                        reader.close()
                    } catch (e: Exception) {
                        // 忽略关闭异常
                    }
                    
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "tun2socks日志线程异常", e)
                }
            }.start()
            
            // 同时监控错误流（以防万一）
            Thread {
                try {
                    val errorReader = BufferedReader(
                        InputStreamReader(process?.errorStream),
                        1
                    )
                    var errorLine: String?
                    while (errorReader.readLine().also { errorLine = it } != null) {
                        VpnFileLogger.e("tun2socks-err", errorLine ?: "")
                    }
                } catch (e: Exception) {
                    // 忽略，可能errorStream已被合并
                }
            }.start()
            
            // 启动进程监控线程
            Thread {
                VpnFileLogger.d(TAG, "$TUN2SOCKS check")
                val exitCode = process?.waitFor()
                VpnFileLogger.d(TAG, "$TUN2SOCKS exited with code: $exitCode")
                
                if (currentState == V2RayState.CONNECTED) {
                    VpnFileLogger.e(TAG, "$TUN2SOCKS unexpectedly exited, exit code: $exitCode")
                    
                    // 尝试重启tun2socks
                    if (shouldRestartTun2socks()) {
                        VpnFileLogger.w(TAG, "尝试重启tun2socks (第${tun2socksRestartCount + 1}次)")
                        Thread.sleep(1000)
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
            
            VpnFileLogger.d(TAG, "tun2socks进程启动完成")
            
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
     * 重启tun2socks进程
     */
    private fun restartTun2socks() {
        try {
            tun2socksRestartCount++
            VpnFileLogger.d(TAG, "重启tun2socks，第${tun2socksRestartCount}次尝试")
            
            // 先停止当前进程
            stopTun2socks()
            
            // 等待一下
            Thread.sleep(500)
            
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
     * 启动简化的流量监控（只用于通知栏显示）
     * 采用v2rayNG验证过的简单方式
     */
    private fun startSimpleTrafficMonitor() {
        VpnFileLogger.d(TAG, "启动简化流量监控")
        
        statsJob?.cancel()
        
        statsJob = serviceScope.launch {
            delay(5000)  // 等待服务稳定
            
            while (currentState == V2RayState.CONNECTED && isActive) {
                try {
                    updateSimpleTrafficStats()
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "更新流量统计异常", e)
                }
                
                delay(STATS_UPDATE_INTERVAL)
            }
        }
    }
    
    /**
     * 简化的流量统计更新
     * 只维护通知栏显示所需的基本数据
     */
    private fun updateSimpleTrafficStats() {
        try {
            // 这里可以通过其他方式获取流量数据
            // v2rayNG使用的是简化配置，不依赖Stats API
            // 可以从系统或V2Ray核心的其他接口获取
            
            // 暂时使用模拟数据，实际可以从TrafficStats或其他来源获取
            val currentTime = System.currentTimeMillis()
            val timeDiff = (currentTime - lastStatsTime) / 1000.0
            
            if (timeDiff > 0 && lastStatsTime > 0) {
                // 简单的速度计算
                val uploadDiff = uploadBytes - lastUploadBytes
                val downloadDiff = downloadBytes - lastDownloadBytes
                
                if (uploadDiff >= 0 && downloadDiff >= 0) {
                    uploadSpeed = (uploadDiff / timeDiff).toLong()
                    downloadSpeed = (downloadDiff / timeDiff).toLong()
                }
            }
            
            lastUploadBytes = uploadBytes
            lastDownloadBytes = downloadBytes
            lastStatsTime = currentTime
            
            // 模拟流量增长（实际应从系统或V2Ray获取）
            uploadBytes += (Math.random() * 1024).toLong()
            downloadBytes += (Math.random() * 2048).toLong()
            
            if (enableAutoStats) {
                updateNotification()
            }
            
            VpnFileLogger.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "更新流量统计失败", e)
        }
    }
    
    /**
     * 获取当前流量统计（供dart端查询）
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
        VpnFileLogger.d(TAG, "========== CoreCallbackHandler.startup() 被调用 ==========")
        VpnFileLogger.i(TAG, "V2Ray核心启动完成通知")
        
        // 立即查询一次状态以验证
        try {
            val isRunning = coreController?.isRunning ?: false
            VpnFileLogger.d(TAG, "V2Ray核心运行状态(在startup回调中): $isRunning")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "查询V2Ray状态失败", e)
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
