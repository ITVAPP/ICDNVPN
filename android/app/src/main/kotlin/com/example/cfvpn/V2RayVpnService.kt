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

// 正确的libv2ray导入
import go.Seq
import libv2ray.*

/**
 * V2Ray VPN服务实现
 * 使用libv2ray.aar提供VPN功能
 * 
 * 运行流程分析：
 * 1. onCreate -> 初始化Go运行时和V2Ray
 * 2. onStartCommand -> 接收启动意图，解析配置
 * 3. startV2Ray -> 建立VPN隧道，启动V2Ray核心
 * 4. 流量监控 -> 定期更新统计
 * 5. stopV2Ray -> 停止服务，清理资源
 */
class V2RayVpnService : VpnService(), V2RayVPNServiceSupportsSet {
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        
        // VPN配置常量
        private const val VPN_MTU = 1500
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        
        // 服务状态 - 线程安全
        @Volatile
        private var isRunning = false
        
        // 单例服务引用 - 用于获取流量统计
        @Volatile
        private var instance: V2RayVpnService? = null
        
        /**
         * 启动VPN服务
         * @param context 上下文
         * @param config V2Ray配置JSON
         * @param globalProxy 是否全局代理
         */
        fun startVpnService(context: Context, config: String, globalProxy: Boolean = false) {
            Log.d(TAG, "准备启动VPN服务，全局代理: $globalProxy")
            
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN"
                putExtra("config", config)
                putExtra("globalProxy", globalProxy)
            }
            
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "启动服务失败", e)
            }
        }
        
        /**
         * 停止VPN服务
         */
        fun stopVpnService(context: Context) {
            Log.d(TAG, "准备停止VPN服务")
            
            try {
                // 先发送停止广播
                context.sendBroadcast(Intent(ACTION_STOP_VPN))
                // 再停止服务
                context.stopService(Intent(context, V2RayVpnService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "停止服务失败", e)
            }
        }
        
        /**
         * 检查服务是否运行
         */
        fun isServiceRunning(): Boolean = isRunning
        
        /**
         * 获取流量统计
         */
        fun getTrafficStats(): Map<String, Long> {
            return instance?.getCurrentTrafficStats() ?: mapOf(
                "uploadTotal" to 0L,
                "downloadTotal" to 0L,
                "uploadSpeed" to 0L,
                "downloadSpeed" to 0L
            )
        }
    }
    
    // V2Ray核心对象 - 可能为null
    private var v2rayPoint: V2RayPoint? = null
    
    // VPN接口文件描述符 - 可能为null
    private var mInterface: ParcelFileDescriptor? = null
    
    // 配置内容
    private var configContent: String = ""
    private var globalProxy: Boolean = false
    
    // 协程作用域 - 用于管理异步任务
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计数据
    private var uploadBytes: Long = 0
    private var downloadBytes: Long = 0
    private var lastUploadBytes: Long = 0
    private var lastDownloadBytes: Long = 0
    private var lastQueryTime: Long = 0
    private var startTime: Long = 0
    
    // 统计任务
    private var statsJob: Job? = null
    
    // 广播接收器 - 接收停止命令
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                Log.d(TAG, "收到停止VPN广播")
                stopV2Ray()
            }
        }
    }
    
    /**
     * 服务创建时调用
     * 关键步骤：初始化Go运行时和V2Ray
     */
    override fun onCreate() {
        super.onCreate()
        
        Log.d(TAG, "VPN服务onCreate开始")
        
        // 保存实例引用
        instance = this
        
        // 步骤1：初始化Go运行时 - 必须在使用任何Go代码之前
        try {
            Seq.setContext(applicationContext)
            Log.d(TAG, "Go运行时初始化成功")
        } catch (e: Exception) {
            Log.e(TAG, "Go运行时初始化失败", e)
            // Go运行时初始化失败，服务无法工作
            stopSelf()
            return
        }
        
        // 步骤2：注册广播接收器
        try {
            registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
            Log.d(TAG, "广播接收器注册成功")
        } catch (e: Exception) {
            Log.e(TAG, "注册广播接收器失败", e)
        }
        
        // 步骤3：初始化V2Ray
        initializeV2Ray()
        
        Log.d(TAG, "VPN服务onCreate完成")
    }
    
    /**
     * 初始化V2Ray核心
     * 关键步骤：复制资源文件，创建V2RayPoint
     */
    private fun initializeV2Ray() {
        try {
            Log.d(TAG, "开始初始化V2Ray")
            
            // 步骤1：复制geo资源文件
            copyAssetFiles()
            
            // 步骤2：创建V2Ray点
            // 注意：NewV2RayPoint是libv2ray提供的工厂方法
            v2rayPoint = NewV2RayPoint(this)
            
            if (v2rayPoint == null) {
                Log.e(TAG, "创建V2RayPoint失败")
                return
            }
            
            // 步骤3：设置V2Ray属性
            // 使用安全的方式设置属性，避免空指针
            v2rayPoint?.let { point ->
                try {
                    // 设置包名
                    point.packageName = packageName
                    
                    // 设置代码路径（可选）
                    val assetPath = File(filesDir, "assets").absolutePath
                    point.packageCodePath = assetPath
                    
                    Log.d(TAG, "V2Ray属性设置成功: 包名=$packageName, 资源路径=$assetPath")
                } catch (e: Exception) {
                    Log.e(TAG, "设置V2Ray属性失败", e)
                }
            }
            
            Log.d(TAG, "V2Ray初始化成功")
        } catch (e: Exception) {
            Log.e(TAG, "V2Ray初始化失败", e)
            // 初始化失败不立即停止服务，等待onStartCommand处理
        }
    }
    
    /**
     * 服务启动命令
     * 验证：检查意图、配置、权限
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}, flags=$flags, startId=$startId")
        
        // 验证1：检查意图
        if (intent == null || intent.action != "START_VPN") {
            Log.w(TAG, "无效的启动意图: ${intent?.action}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 验证2：检查是否已在运行
        if (isRunning) {
            Log.w(TAG, "VPN服务已在运行，忽略重复启动")
            return START_STICKY
        }
        
        // 验证3：获取配置
        configContent = intent.getStringExtra("config") ?: ""
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        
        if (configContent.isEmpty()) {
            Log.e(TAG, "配置为空，无法启动")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 验证4：检查V2Ray是否初始化
        if (v2rayPoint == null) {
            Log.e(TAG, "V2Ray未初始化，尝试重新初始化")
            initializeV2Ray()
            
            if (v2rayPoint == null) {
                Log.e(TAG, "V2Ray初始化失败，无法启动")
                stopSelf()
                return START_NOT_STICKY
            }
        }
        
        // 步骤1：启动前台服务
        try {
            startForeground(NOTIFICATION_ID, createNotification())
            Log.d(TAG, "前台服务已启动")
        } catch (e: Exception) {
            Log.e(TAG, "启动前台服务失败", e)
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 步骤2：异步启动V2Ray
        serviceScope.launch {
            try {
                startV2Ray()
            } catch (e: Exception) {
                Log.e(TAG, "启动V2Ray失败", e)
                withContext(Dispatchers.Main) {
                    stopSelf()
                }
            }
        }
        
        return START_STICKY
    }
    
    /**
     * 复制资源文件到应用目录
     * 错误处理：单个文件失败不影响其他文件
     */
    private fun copyAssetFiles() {
        Log.d(TAG, "开始复制资源文件")
        
        // 创建目标目录
        val assetDir = File(filesDir, "assets")
        if (!assetDir.exists()) {
            if (!assetDir.mkdirs()) {
                Log.e(TAG, "创建资源目录失败: ${assetDir.absolutePath}")
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
                    Log.d(TAG, "文件已是最新，跳过: $fileName")
                }
            } catch (e: Exception) {
                Log.e(TAG, "处理文件失败: $fileName", e)
                // 继续处理其他文件
            }
        }
        
        Log.d(TAG, "资源文件复制完成")
    }
    
    /**
     * 检查文件是否需要更新
     * 策略：文件不存在或大小不同则更新
     */
    private fun shouldUpdateFile(assetName: String, targetFile: File): Boolean {
        if (!targetFile.exists()) {
            Log.d(TAG, "目标文件不存在: $assetName")
            return true
        }
        
        return try {
            val assetSize = assets.open(assetName).use { it.available() }
            val needUpdate = targetFile.length() != assetSize.toLong()
            if (needUpdate) {
                Log.d(TAG, "文件大小不匹配: $assetName (asset=$assetSize, target=${targetFile.length()})")
            }
            needUpdate
        } catch (e: Exception) {
            Log.e(TAG, "检查文件失败: $assetName", e)
            true // 出错时尝试更新
        }
    }
    
    /**
     * 复制单个资源文件
     * 错误处理：记录错误但不抛出异常
     */
    private fun copyAssetFile(assetName: String, targetFile: File) {
        try {
            Log.d(TAG, "正在复制文件: $assetName -> ${targetFile.absolutePath}")
            
            assets.open(assetName).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            
            Log.d(TAG, "文件复制成功: $assetName (${targetFile.length()} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "复制文件失败: $assetName", e)
            // 不抛出异常，允许继续运行
        }
    }
    
    /**
     * 启动V2Ray核心
     * 关键流程：建立VPN -> 配置V2Ray -> 启动核心 -> 监控流量
     */
    private suspend fun startV2Ray() = withContext(Dispatchers.IO) {
        Log.d(TAG, "开始启动V2Ray核心")
        
        try {
            // 步骤1：建立VPN隧道（必须在主线程权限已验证）
            Log.d(TAG, "步骤1: 建立VPN隧道")
            establishVpn()
            
            // 验证VPN隧道
            if (mInterface == null) {
                throw Exception("VPN隧道建立失败")
            }
            
            // 步骤2：配置V2Ray
            Log.d(TAG, "步骤2: 配置V2Ray")
            v2rayPoint?.let { point ->
                // 设置配置内容
                point.configureFileContent = configContent
                
                // 设置域名（从配置中解析）
                val domain = parseDomainFromConfig(configContent)
                if (domain.isNotEmpty()) {
                    point.domainName = domain
                    Log.d(TAG, "设置域名: $domain")
                }
                
                // 设置DNS和转发选项
                point.enableLocalDNS = true
                point.forwardIpv6 = false
                point.proxyOnly = false
                
                Log.d(TAG, "V2Ray配置完成")
            } ?: throw Exception("V2RayPoint为空")
            
            // 步骤3：启动V2Ray核心
            Log.d(TAG, "步骤3: 启动V2Ray核心")
            val startResult = v2rayPoint?.runLoop()
            
            // 验证启动结果
            if (startResult == null || startResult != 0) {
                throw Exception("V2Ray核心启动失败，返回码: $startResult")
            }
            
            // 步骤4：更新状态
            isRunning = true
            startTime = System.currentTimeMillis()
            
            Log.i(TAG, "V2Ray核心启动成功")
            
            // 步骤5：启动流量监控
            startTrafficMonitor()
            
        } catch (e: Exception) {
            Log.e(TAG, "启动V2Ray失败: ${e.message}", e)
            
            // 清理资源
            isRunning = false
            mInterface?.close()
            mInterface = null
            
            // 重新抛出异常
            throw e
        }
    }
    
    /**
     * 从配置中解析服务器域名
     * 容错：解析失败返回空字符串
     */
    private fun parseDomainFromConfig(config: String): String {
        return try {
            // 尝试匹配 "address": "domain.com" 格式
            val regex = """"address"\s*:\s*"([^"]+)"""".toRegex()
            val result = regex.find(config)?.groupValues?.get(1) ?: ""
            Log.d(TAG, "解析域名: $result")
            result
        } catch (e: Exception) {
            Log.w(TAG, "解析域名失败", e)
            ""
        }
    }
    
    /**
     * 建立VPN隧道
     * 关键配置：IP地址、DNS、路由规则
     */
    private fun establishVpn() {
        Log.d(TAG, "开始建立VPN隧道")
        
        // 关闭旧接口
        mInterface?.let {
            try {
                it.close()
                Log.d(TAG, "已关闭旧VPN接口")
            } catch (e: Exception) {
                Log.w(TAG, "关闭旧接口失败", e)
            }
        }
        mInterface = null
        
        // 创建VPN构建器
        val builder = Builder()
        
        // 基本配置
        builder.setSession("CFVPN")
        builder.setMtu(VPN_MTU)
        
        // IPv4地址
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        Log.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30")
        
        // IPv6地址（可选）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126)
                Log.d(TAG, "添加IPv6地址: $PRIVATE_VLAN6_CLIENT/126")
            } catch (e: Exception) {
                Log.w(TAG, "添加IPv6地址失败（可能不支持）", e)
            }
        }
        
        // DNS服务器配置
        val dnsServers = listOf("8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1")
        dnsServers.forEach { dns ->
            try {
                builder.addDnsServer(dns)
                Log.d(TAG, "添加DNS: $dns")
            } catch (e: Exception) {
                Log.w(TAG, "添加DNS失败: $dns", e)
            }
        }
        
        // 路由规则配置
        if (globalProxy) {
            Log.d(TAG, "配置全局代理路由")
            
            // IPv4全局路由
            builder.addRoute("0.0.0.0", 0)
            
            // IPv6全局路由（可选）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                try {
                    builder.addRoute("::", 0)
                    Log.d(TAG, "添加IPv6全局路由")
                } catch (e: Exception) {
                    Log.w(TAG, "添加IPv6路由失败", e)
                }
            }
        } else {
            Log.d(TAG, "配置智能分流路由")
            // 仅代理国外流量
            builder.addRoute("0.0.0.0", 0)
        }
        
        // 应用绕过规则（避免VPN循环）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addDisallowedApplication(packageName)
                Log.d(TAG, "设置绕过应用: $packageName")
            } catch (e: Exception) {
                Log.w(TAG, "设置绕过应用失败", e)
            }
        }
        
        // 建立VPN接口
        mInterface = builder.establish()
        
        if (mInterface == null) {
            throw Exception("VPN接口建立失败（可能没有权限）")
        }
        
        Log.d(TAG, "VPN隧道建立成功，FD: ${mInterface?.fd}")
    }
    
    /**
     * 停止V2Ray服务
     * 清理顺序：停止核心 -> 关闭接口 -> 清理状态
     */
    private fun stopV2Ray() {
        Log.d(TAG, "开始停止V2Ray服务")
        
        // 更新状态
        isRunning = false
        
        // 停止流量监控
        statsJob?.cancel()
        statsJob = null
        Log.d(TAG, "流量监控已停止")
        
        // 停止V2Ray核心
        try {
            v2rayPoint?.stopLoop()
            Log.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            Log.e(TAG, "停止V2Ray核心异常", e)
        }
        
        // 关闭VPN接口
        try {
            mInterface?.close()
            mInterface = null
            Log.d(TAG, "VPN接口已关闭")
        } catch (e: Exception) {
            Log.e(TAG, "关闭VPN接口异常", e)
        }
        
        // 停止前台服务
        stopForeground(true)
        
        // 停止服务自身
        stopSelf()
        
        Log.i(TAG, "V2Ray服务已完全停止")
    }
    
    /**
     * 创建前台服务通知
     */
    private fun createNotification(): android.app.Notification {
        // Android O及以上需要通知渠道
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "CFVPN服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "CFVPN服务运行状态"
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
            }
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
        
        // 创建停止动作
        val stopIntent = Intent(ACTION_STOP_VPN)
        val stopPendingIntent = PendingIntent.getBroadcast(
            this, 0, stopIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )
        
        // 创建点击动作（打开应用）
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
        
        // 构建通知
        val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("CFVPN")
            .setContentText(if (globalProxy) "全局代理模式" else "智能代理模式")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopPendingIntent)
        
        mainPendingIntent?.let {
            builder.setContentIntent(it)
        }
        
        return builder.build()
    }
    
    /**
     * 启动流量监控
     * 定期查询V2Ray统计信息
     */
    private fun startTrafficMonitor() {
        Log.d(TAG, "启动流量监控")
        
        // 取消旧任务
        statsJob?.cancel()
        
        // 创建新任务
        statsJob = serviceScope.launch {
            // 初始延迟
            delay(5000)
            
            while (isRunning && isActive) {
                try {
                    updateTrafficStats()
                } catch (e: Exception) {
                    Log.w(TAG, "更新流量统计异常", e)
                }
                
                // 间隔10秒
                delay(10000)
            }
        }
    }
    
    /**
     * 更新流量统计
     * 从V2Ray核心查询统计数据
     */
    private fun updateTrafficStats() {
        try {
            // 查询统计
            val stats = v2rayPoint?.queryStats("", true)
            
            if (stats.isNullOrEmpty()) {
                Log.d(TAG, "统计数据为空")
                return
            }
            
            // 解析统计
            parseTrafficStats(stats)
            
            // 更新通知（限制频率）
            val now = System.currentTimeMillis()
            if (now - lastQueryTime > 10000) {
                updateNotification()
                lastQueryTime = now
            }
        } catch (e: Exception) {
            Log.w(TAG, "查询流量统计失败", e)
        }
    }
    
    /**
     * 解析流量统计字符串
     * 格式：每行一个统计项
     */
    private fun parseTrafficStats(stats: String) {
        try {
            val previousUpload = uploadBytes
            val previousDownload = downloadBytes
            val previousTime = lastQueryTime
            
            var proxyUplink: Long = 0
            var proxyDownlink: Long = 0
            
            // 解析每行统计
            stats.split("\n").forEach { line ->
                when {
                    line.contains("outbound>>>proxy>>>traffic>>>uplink") -> {
                        val value = line.substringAfter(":").trim()
                        proxyUplink = value.toLongOrNull() ?: 0
                    }
                    line.contains("outbound>>>proxy>>>traffic>>>downlink") -> {
                        val value = line.substringAfter(":").trim()
                        proxyDownlink = value.toLongOrNull() ?: 0
                    }
                }
            }
            
            // 更新总量
            uploadBytes = proxyUplink
            downloadBytes = proxyDownlink
            
            // 计算速度
            val now = System.currentTimeMillis()
            if (previousTime > 0 && now > previousTime) {
                val timeDiff = (now - previousTime) / 1000.0
                if (timeDiff > 0) {
                    val uploadDiff = uploadBytes - previousUpload
                    val downloadDiff = downloadBytes - previousDownload
                    
                    // 确保速度非负
                    if (uploadDiff >= 0 && downloadDiff >= 0) {
                        lastUploadBytes = (uploadDiff / timeDiff).toLong()
                        lastDownloadBytes = (downloadDiff / timeDiff).toLong()
                    }
                }
            }
            
            lastQueryTime = now
            
            // 记录日志（仅在有变化时）
            if (uploadBytes != previousUpload || downloadBytes != previousDownload || 
                lastUploadBytes > 0 || lastDownloadBytes > 0) {
                Log.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)} " +
                          "速度: ↑${formatBytes(lastUploadBytes)}/s ↓${formatBytes(lastDownloadBytes)}/s")
            }
            
        } catch (e: Exception) {
            Log.w(TAG, "解析流量统计失败", e)
        }
    }
    
    /**
     * 更新通知显示流量信息
     */
    private fun updateNotification() {
        try {
            val duration = formatDuration(System.currentTimeMillis() - startTime)
            val upload = formatBytes(uploadBytes)
            val download = formatBytes(downloadBytes)
            
            val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle("CFVPN - 已连接")
                .setContentText("$duration | ↑ $upload ↓ $download")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .build()
            
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "更新通知失败", e)
        }
    }
    
    /**
     * 获取当前流量统计
     * 供外部查询使用
     */
    fun getCurrentTrafficStats(): Map<String, Long> {
        return mapOf(
            "uploadTotal" to uploadBytes,
            "downloadTotal" to downloadBytes,
            "uploadSpeed" to lastUploadBytes,
            "downloadSpeed" to lastDownloadBytes
        )
    }
    
    // ===== V2RayVPNServiceSupportsSet 接口实现 =====
    // 重要：这些方法由libv2ray的Go代码调用
    // 返回值：0表示成功，非0表示失败
    
    /**
     * V2Ray状态回调
     * @param level 日志级别
     * @param status 状态信息
     * @return 0成功，非0失败
     */
    override fun OnEmitStatus(level: Int, status: String?): Int {
        try {
            // 根据级别记录日志
            when (level) {
                0 -> Log.v(TAG, "V2Ray: $status")
                1 -> Log.d(TAG, "V2Ray: $status")
                2 -> Log.i(TAG, "V2Ray: $status")
                3 -> Log.w(TAG, "V2Ray: $status")
                4 -> Log.e(TAG, "V2Ray: $status")
                else -> Log.d(TAG, "V2Ray[$level]: $status")
            }
            return 0
        } catch (e: Exception) {
            Log.e(TAG, "OnEmitStatus异常", e)
            return -1
        }
    }
    
    /**
     * 设置VPN文件描述符
     * @param conf 配置（未使用）
     * @return 文件描述符，-1表示失败
     */
    override fun Setup(conf: String?): Int {
        return try {
            val fd = mInterface?.fd
            if (fd != null) {
                Log.d(TAG, "Setup返回FD: $fd")
                fd
            } else {
                Log.w(TAG, "Setup: mInterface为空")
                -1
            }
        } catch (e: Exception) {
            Log.e(TAG, "Setup异常", e)
            -1
        }
    }
    
    /**
     * 准备VPN服务
     * @return 0已准备，-1未准备
     */
    override fun Prepare(): Int {
        return try {
            val prepared = VpnService.prepare(this) == null
            Log.d(TAG, "Prepare: ${if (prepared) "已准备" else "未准备"}")
            if (prepared) 0 else -1
        } catch (e: Exception) {
            Log.e(TAG, "Prepare异常", e)
            -1
        }
    }
    
    /**
     * 保护socket不通过VPN
     * @param fd 文件描述符
     * @return 0成功，-1失败
     */
    override fun Protect(fd: Int): Int {
        return try {
            val protected = protect(fd)
            if (!protected) {
                Log.w(TAG, "保护socket失败: FD=$fd")
            }
            if (protected) 0 else -1
        } catch (e: Exception) {
            Log.e(TAG, "Protect异常: FD=$fd", e)
            -1
        }
    }
    
    /**
     * 关闭VPN服务
     * @return 0成功
     */
    override fun Shutdown(): Int {
        try {
            Log.d(TAG, "Shutdown被调用")
            stopV2Ray()
            return 0
        } catch (e: Exception) {
            Log.e(TAG, "Shutdown异常", e)
            return -1
        }
    }
    
    // ===== 工具方法 =====
    
    /**
     * 格式化字节数
     */
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
     * 格式化持续时间
     */
    private fun formatDuration(millis: Long): String {
        if (millis < 0) return "00:00:00"
        
        val seconds = (millis / 1000) % 60
        val minutes = (millis / (1000 * 60)) % 60
        val hours = millis / (1000 * 60 * 60)
        return String.format("%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    /**
     * 服务销毁时调用
     * 清理所有资源
     */
    override fun onDestroy() {
        super.onDestroy()
        
        Log.d(TAG, "onDestroy开始")
        
        // 清除实例引用
        instance = null
        
        // 取消所有协程
        serviceScope.cancel()
        
        // 注销广播接收器
        try {
            unregisterReceiver(stopReceiver)
            Log.d(TAG, "广播接收器已注销")
        } catch (e: Exception) {
            // 可能已经注销
        }
        
        // 如果还在运行，停止V2Ray
        if (isRunning) {
            stopV2Ray()
        }
        
        // 清理V2RayPoint
        v2rayPoint = null
        
        Log.d(TAG, "onDestroy完成，服务已销毁")
    }
}
