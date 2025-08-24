package com.example.cfvpn

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.provider.Settings
import android.net.VpnService
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

/**
 * 主Activity - 处理Flutter与原生的通信
 * 修复版本：解决跨进程状态查询问题
 */
class MainActivity: FlutterActivity() {
    
    companion object {
        private const val CHANNEL = "com.example.cfvpn/v2ray"
        private const val VPN_REQUEST_CODE = 100
        private const val NOTIFICATION_REQUEST_CODE = 101
        private const val TAG = "MainActivity"
        
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"
        private const val VPN_START_TIMEOUT = 15000L  // 15秒超时
    }
    
    private lateinit var channel: MethodChannel
    private val mainScope = MainScope()
    
    // 保存待处理的VPN启动请求
    private data class PendingVpnRequest(
        val config: String,
        val globalProxy: Boolean,
        val allowedApps: List<String>?,
        val bypassSubnets: List<String>?,
        val localizedStrings: Map<String, String>,
        val enableVirtualDns: Boolean,
        val virtualDnsPort: Int,
        val result: MethodChannel.Result
    )
    private var pendingRequest: PendingVpnRequest? = null
    
    private val pendingResultLock = Any()
    private var pendingStartResult: MethodChannel.Result? = null
    private var startTimeoutJob: Job? = null
    
    @Volatile
    private var receiversRegistered = false
    
    // VPN启动结果广播接收器
    private val vpnStartResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_VPN_START_RESULT) {
                val success = intent.getBooleanExtra("success", false)
                val error = intent.getStringExtra("error")
                
                VpnFileLogger.d(TAG, "收到VPN启动结果广播: success=$success, error=$error")
                
                synchronized(pendingResultLock) {
                    // 取消超时任务
                    startTimeoutJob?.cancel()
                    startTimeoutJob = null
                    
                    // 返回结果给Flutter
                    pendingStartResult?.let { result ->
                        if (success) {
                            result.success(true)
                            channel.invokeMethod("onVpnConnected", null)
                        } else {
                            result.error("START_FAILED", error ?: "VPN服务启动失败", null)
                        }
                        pendingStartResult = null
                    }
                }
            }
        }
    }
    
    // VPN停止广播接收器
    private val vpnStoppedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_VPN_STOPPED) {
                VpnFileLogger.d(TAG, "收到VPN停止广播（来自通知栏）")
                // 通知Flutter端VPN已断开
                channel.invokeMethod("onVpnDisconnected", null)
            }
        }
    }
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 初始化文件日志系统
        VpnFileLogger.init(applicationContext)
        
        // 注册广播接收器
        registerReceivers()
        
        // 设置方法通道，处理Flutter调用
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    synchronized(pendingResultLock) {
                        if (pendingStartResult != null) {
                            VpnFileLogger.w(TAG, "正在处理上一个VPN启动请求")
                            result.error("BUSY", "正在处理上一个连接请求", null)
                            return@setMethodCallHandler
                        }
                    }
                    
                    // 启动VPN
                    val config = call.argument<String>("config")
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    val allowedApps = call.argument<List<String>>("allowedApps")
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets")
                    val enableVirtualDns = call.argument<Boolean>("enableVirtualDns") ?: false
                    val virtualDnsPort = call.argument<Int>("virtualDnsPort") ?: 10853
                    
                    // 接收国际化文字
                    val localizedStrings = mutableMapOf<String, String>()
                    localizedStrings["appName"] = call.argument<String>("appName") ?: "CFVPN"
                    localizedStrings["notificationChannelName"] = call.argument<String>("notificationChannelName") ?: "VPN Service"
                    localizedStrings["notificationChannelDesc"] = call.argument<String>("notificationChannelDesc") ?: "VPN connection status"
                    localizedStrings["globalProxyMode"] = call.argument<String>("globalProxyMode") ?: "Global Proxy"
                    localizedStrings["smartProxyMode"] = call.argument<String>("smartProxyMode") ?: "Smart Proxy"
                    localizedStrings["proxyOnlyMode"] = call.argument<String>("proxyOnlyMode") ?: "Proxy Only"
                    localizedStrings["disconnectButtonName"] = call.argument<String>("disconnectButtonName") ?: "Disconnect"
                    localizedStrings["trafficStatsFormat"] = call.argument<String>("trafficStatsFormat") ?: "Traffic: ↑%upload ↓%download"
                    
                    if (config != null) {
                        // 检查通知权限（Android 13+）
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (!checkNotificationPermission()) {
                                VpnFileLogger.w(TAG, "没有通知权限，但继续启动VPN")
                                requestNotificationPermission()
                            }
                        }
                        
                        startVpn(config, globalProxy, allowedApps, bypassSubnets, localizedStrings, enableVirtualDns, virtualDnsPort, result)
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
                    }
                }
                
                "updateNotificationStrings" -> {
                    // 【修复】通过广播更新通知栏文字
                    try {
                        val localizedStrings = mutableMapOf<String, String>()
                        localizedStrings["appName"] = call.argument<String>("appName") ?: "CFVPN"
                        localizedStrings["notificationChannelName"] = call.argument<String>("notificationChannelName") ?: "VPN Service"
                        localizedStrings["notificationChannelDesc"] = call.argument<String>("notificationChannelDesc") ?: "VPN connection status"
                        localizedStrings["globalProxyMode"] = call.argument<String>("globalProxyMode") ?: "Global Proxy"
                        localizedStrings["smartProxyMode"] = call.argument<String>("smartProxyMode") ?: "Smart Proxy"
                        localizedStrings["proxyOnlyMode"] = call.argument<String>("proxyOnlyMode") ?: "Proxy Only"
                        localizedStrings["disconnectButtonName"] = call.argument<String>("disconnectButtonName") ?: "Disconnect"
                        localizedStrings["trafficStatsFormat"] = call.argument<String>("trafficStatsFormat") ?: "Traffic: ↑%upload ↓%download"
                        
                        VpnFileLogger.d(TAG, "发送更新通知栏文字广播")
                        
                        // 【修复】调用修正后的静态方法，传入context
                        val success = V2RayVpnService.updateNotificationStrings(this@MainActivity, localizedStrings)
                        
                        VpnFileLogger.d(TAG, "通知栏文字更新结果: $success")
                        result.success(success)
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "更新通知栏文字失败", e)
                        result.error("UPDATE_NOTIFICATION_FAILED", e.message, null)
                    }
                }
                
                "stopVpn" -> {
                    // 停止VPN
                    stopVpn()
                    result.success(true)
                }
                
                "isVpnConnected" -> {
                    // 【修复】通过ContentProvider查询VPN连接状态
                    val isConnected = isServiceRunning()
                    result.success(isConnected)
                }
                
                "getTrafficStats" -> {
                    // 从ContentProvider获取流量统计
                    try {
                        val cursor = contentResolver.query(
                            TrafficStatsProvider.CONTENT_URI,
                            null, null, null, null
                        )
                        
                        cursor?.use {
                            if (it.moveToFirst()) {
                                val uploadTotal = it.getLong(0)
                                val downloadTotal = it.getLong(1)
                                val uploadSpeed = it.getLong(2)
                                val downloadSpeed = it.getLong(3)
                                val startTime = it.getLong(4)
                                
                                val stats = mapOf(
                                    "uploadTotal" to java.lang.Long.valueOf(uploadTotal),
                                    "downloadTotal" to java.lang.Long.valueOf(downloadTotal),
                                    "uploadSpeed" to java.lang.Long.valueOf(uploadSpeed),
                                    "downloadSpeed" to java.lang.Long.valueOf(downloadSpeed),
                                    "startTime" to java.lang.Long.valueOf(startTime)
                                )
                                
                                VpnFileLogger.d(TAG, "返回流量统计: 上传=$uploadTotal, 下载=$downloadTotal")
                                result.success(stats)
                            } else {
                                val defaultStats = mapOf(
                                    "uploadTotal" to java.lang.Long.valueOf(0L),
                                    "downloadTotal" to java.lang.Long.valueOf(0L),
                                    "uploadSpeed" to java.lang.Long.valueOf(0L),
                                    "downloadSpeed" to java.lang.Long.valueOf(0L),
                                    "startTime" to java.lang.Long.valueOf(0L)
                                )
                                result.success(defaultStats)
                            }
                        } ?: run {
                            val defaultStats = mapOf(
                                "uploadTotal" to java.lang.Long.valueOf(0L),
                                "downloadTotal" to java.lang.Long.valueOf(0L),
                                "uploadSpeed" to java.lang.Long.valueOf(0L),
                                "downloadSpeed" to java.lang.Long.valueOf(0L),
                                "startTime" to java.lang.Long.valueOf(0L)
                            )
                            result.success(defaultStats)
                        }
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "获取流量统计失败", e)
                        val fallbackStats = mapOf(
                            "uploadTotal" to java.lang.Long.valueOf(0L),
                            "downloadTotal" to java.lang.Long.valueOf(0L),
                            "uploadSpeed" to java.lang.Long.valueOf(0L),
                            "downloadSpeed" to java.lang.Long.valueOf(0L),
                            "startTime" to java.lang.Long.valueOf(0L)
                        )
                        result.success(fallbackStats)
                    }
                }
                
                "requestBatteryOptimization" -> {
                    // 请求电池优化豁免
                    val onlyCheck = call.argument<Boolean>("onlyCheck") ?: false
                    
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            val packageName = packageName
                            
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                if (onlyCheck) {
                                    VpnFileLogger.d(TAG, "电池优化检查：需要权限")
                                    result.success(true)
                                } else {
                                    VpnFileLogger.d(TAG, "打开电池优化设置页面")
                                    val intent = Intent().apply {
                                        action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                                        data = Uri.parse("package:$packageName")
                                    }
                                    startActivity(intent)
                                    result.success(true)
                                }
                            } else {
                                VpnFileLogger.d(TAG, "已有电池优化豁免权限")
                                result.success(false)
                            }
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "请求电池优化豁免失败", e)
                        result.error("BATTERY_OPTIMIZATION_FAILED", e.message, null)
                    }
                }
                
                "checkPermission" -> {
                    // 检查VPN权限
                    val hasPermission = checkVpnPermission()
                    result.success(hasPermission)
                }
                
                "getInstalledApps" -> {
                    // 获取已安装应用列表
                    mainScope.launch {
                        try {
                            val apps = getInstalledApps()
                            result.success(apps)
                        } catch (e: Exception) {
                            VpnFileLogger.e(TAG, "获取应用列表失败", e)
                            result.error("GET_APPS_FAILED", e.message, null)
                        }
                    }
                }
                
                "saveProxyConfig" -> {
                    // 保存代理配置
                    val allowedApps = call.argument<List<String>>("allowedApps") ?: emptyList()
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets") ?: emptyList()
                    
                    saveProxyConfig(allowedApps, bypassSubnets)
                    result.success(true)
                }
                
                "loadProxyConfig" -> {
                    // 加载代理配置
                    val config = loadProxyConfig()
                    result.success(config)
                }
                
                // ===== 开机自启动相关 =====
                
                "setAutoStartEnabled" -> {
                    // 设置开机自启动
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        AutoStartManager.setAutoStartEnabled(this, enabled)
                        result.success(true)
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "设置开机自启动失败", e)
                        result.error("SET_AUTOSTART_FAILED", e.message, null)
                    }
                }
                
                "isAutoStartEnabled" -> {
                    // 检查开机自启动是否启用
                    val enabled = AutoStartManager.isAutoStartEnabled(this)
                    result.success(enabled)
                }
                
                "saveAutoStartConfig" -> {
                    // 保存自启动配置
                    val config = call.argument<String>("config")
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    
                    if (config != null) {
                        AutoStartManager.saveAutoStartConfig(this, config, "VPN_TUN", globalProxy)
                        result.success(true)
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
                    }
                }
                
                "clearAutoStartConfig" -> {
                    // 清除自启动配置
                    AutoStartManager.clearAutoStartConfig(this)
                    result.success(true)
                }
                
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
    
    /**
     * 【修复】检查VPN服务是否正在运行
     * 通过ContentProvider查询状态，替代跨进程不可靠的静态方法调用
     * 
     * @return true表示VPN服务正在运行，false表示未运行
     */
    private fun isServiceRunning(): Boolean {
        return try {
            // 首先尝试查询ContentProvider
            val cursor = contentResolver.query(
                TrafficStatsProvider.CONTENT_URI,
                null, null, null, null
            )
            
            cursor?.use {
                if (it.moveToFirst()) {
                    // startTime > 0 表示VPN已连接
                    val startTime = it.getLong(4)
                    val isConnected = startTime > 0
                    
                    // 额外验证：如果显示已连接但时间过长，可能进程已死
                    if (isConnected) {
                        val duration = System.currentTimeMillis() - startTime
                        // 如果连接时间超过24小时，建议重新验证
                        if (duration > 24 * 60 * 60 * 1000) {
                            VpnFileLogger.w(TAG, "VPN连接时间过长: ${duration/1000}秒，建议重新连接")
                        }
                    }
                    
                    isConnected
                } else {
                    false
                }
            } ?: false
        } catch (e: Exception) {
            // ContentProvider不可用，说明:vpn进程不存在
            VpnFileLogger.e(TAG, "查询VPN状态失败，进程可能已停止", e)
            false
        }
    }
    
    /**
     * 安全注册广播接收器
     */
    private fun registerReceivers() {
        if (!receiversRegistered) {
            try {
                registerReceiver(vpnStartResultReceiver, IntentFilter(ACTION_VPN_START_RESULT))
                registerReceiver(vpnStoppedReceiver, IntentFilter(ACTION_VPN_STOPPED))
                receiversRegistered = true
                VpnFileLogger.d(TAG, "广播接收器注册成功")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "注册广播接收器失败", e)
            }
        }
    }
    
    /**
     * 安全注销广播接收器
     */
    private fun unregisterReceivers() {
        if (receiversRegistered) {
            try {
                unregisterReceiver(vpnStartResultReceiver)
            } catch (e: Exception) {
                // 忽略异常
            }
            
            try {
                unregisterReceiver(vpnStoppedReceiver)
            } catch (e: Exception) {
                // 忽略异常
            }
            
            receiversRegistered = false
            VpnFileLogger.d(TAG, "广播接收器注销成功")
        }
    }
    
    /**
     * 检查通知权限（Android 13+）
     */
    private fun checkNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }
    
    /**
     * 请求通知权限（Android 13+）
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_REQUEST_CODE
            )
        }
    }
    
    /**
     * 启动VPN
     */
    private fun startVpn(
        config: String,
        globalProxy: Boolean,
        allowedApps: List<String>?,
        bypassSubnets: List<String>?,
        localizedStrings: Map<String, String>,
        enableVirtualDns: Boolean,
        virtualDnsPort: Int,
        result: MethodChannel.Result
    ) {
        mainScope.launch {
            try {
                // 检查是否已在运行（通过ContentProvider）
                if (isServiceRunning()) {
                    VpnFileLogger.w(TAG, "VPN已在运行，先停止再启动")
                    
                    cancelPendingStart("服务重启")
                    
                    V2RayVpnService.stopVpnService(this@MainActivity)
                    delay(500)
                }
                
                // VPN_TUN模式需要VPN权限
                val intent = VpnService.prepare(this@MainActivity)
                if (intent != null) {
                    VpnFileLogger.d(TAG, "需要请求VPN权限")
                    
                    pendingRequest = PendingVpnRequest(
                        config, globalProxy, 
                        allowedApps, bypassSubnets, 
                        localizedStrings,
                        enableVirtualDns,
                        virtualDnsPort,
                        result
                    )
                    
                    try {
                        startActivityForResult(intent, VPN_REQUEST_CODE)
                    } catch (e: Exception) {
                        VpnFileLogger.e(TAG, "无法请求VPN权限", e)
                        pendingRequest = null
                        result.error("PERMISSION_REQUEST_FAILED", "无法请求VPN权限: ${e.message}", null)
                    }
                } else {
                    VpnFileLogger.d(TAG, "已有VPN权限，直接启动服务")
                    
                    synchronized(pendingResultLock) {
                        pendingStartResult = result
                        
                        // 设置超时保护
                        startTimeoutJob = mainScope.launch {
                            delay(VPN_START_TIMEOUT)
                            synchronized(pendingResultLock) {
                                pendingStartResult?.let {
                                    VpnFileLogger.e(TAG, "VPN启动超时")
                                    it.error("TIMEOUT", "VPN启动超时", null)
                                    pendingStartResult = null
                                }
                            }
                        }
                    }
                    
                    // 启动服务
                    V2RayVpnService.startVpnService(
                        this@MainActivity,
                        config,
                        globalProxy,
                        null,  // blockedApps始终为null
                        allowedApps,
                        V2RayVpnService.Companion.AppProxyMode.EXCLUDE,
                        bypassSubnets,
                        true,  // enableAutoStats
                        localizedStrings["disconnectButtonName"] ?: "Disconnect",
                        localizedStrings,
                        enableVirtualDns,
                        virtualDnsPort
                    )
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动VPN失败", e)
                result.error("START_FAILED", e.message, null)
            }
        }
    }
    
    /**
     * 停止VPN
     */
    private fun stopVpn() {
        VpnFileLogger.d(TAG, "停止VPN服务")
        
        cancelPendingStart("用户取消连接")
        
        V2RayVpnService.stopVpnService(this)
    }
    
    /**
     * 取消待处理的启动请求
     */
    private fun cancelPendingStart(reason: String) {
        synchronized(pendingResultLock) {
            pendingStartResult?.let {
                VpnFileLogger.d(TAG, "取消待处理的启动请求: $reason")
                it.error("CANCELLED", reason, null)
                pendingStartResult = null
            }
            startTimeoutJob?.cancel()
            startTimeoutJob = null
        }
    }
    
    /**
     * 检查是否有VPN权限
     */
    private fun checkVpnPermission(): Boolean {
        return try {
            VpnService.prepare(this) == null
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "检查VPN权限失败", e)
            false
        }
    }
    
    /**
     * 获取已安装应用列表（供选择分应用代理）
     */
    private suspend fun getInstalledApps(): List<Map<String, Any>> = withContext(Dispatchers.IO) {
        val apps = mutableListOf<Map<String, Any>>()
        val pm = packageManager
        
        try {
            val packages = pm.getInstalledApplications(0)
            packages.forEach { appInfo ->
                // 过滤系统应用（可选）
                val isSystemApp = (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                
                // 排除自身
                if (appInfo.packageName != packageName) {
                    apps.add(mapOf(
                        "packageName" to appInfo.packageName,
                        "appName" to (appInfo.loadLabel(pm).toString()),
                        "isSystemApp" to isSystemApp
                    ))
                }
            }
            
            // 按名称排序
            apps.sortBy { it["appName"] as String }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "获取应用列表失败", e)
        }
        
        return@withContext apps
    }
    
    /**
     * 保存代理配置
     */
    private fun saveProxyConfig(allowedApps: List<String>, bypassSubnets: List<String>) {
        val prefs = getSharedPreferences("proxy_config", MODE_PRIVATE)
        prefs.edit().apply {
            // 只保存allowedApps和bypassSubnets
            putStringSet("allowed_apps", allowedApps.toSet())
            putStringSet("bypass_subnets", bypassSubnets.toSet())
            
            // 清理旧的blocked_apps数据（如果存在）
            remove("blocked_apps")
            apply()
        }
        VpnFileLogger.d(TAG, "代理配置已保存")
    }
    
    /**
     * 加载代理配置
     */
    private fun loadProxyConfig(): Map<String, List<String>> {
        val prefs = getSharedPreferences("proxy_config", MODE_PRIVATE)
        
        // 默认绕过子网（私有网络）
        val defaultBypassSubnets = setOf(
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "127.0.0.0/8"
        )
        
        return mapOf(
            "allowedApps" to (prefs.getStringSet("allowed_apps", emptySet())?.toList() ?: emptyList()),
            "bypassSubnets" to (prefs.getStringSet("bypass_subnets", defaultBypassSubnets)?.toList() ?: defaultBypassSubnets.toList())
        )
    }
    
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
     * 格式化时长
     */
    private fun formatDuration(millis: Long): String {
        val seconds = (millis / 1000) % 60
        val minutes = (millis / (1000 * 60)) % 60
        val hours = millis / (1000 * 60 * 60)
        
        return when {
            hours > 0 -> String.format("%d:%02d:%02d", hours, minutes, seconds)
            minutes > 0 -> String.format("%d:%02d", minutes, seconds)
            else -> String.format("%d秒", seconds)
        }
    }
    
    /**
     * 处理权限请求结果
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        when (requestCode) {
            VPN_REQUEST_CODE -> {
                val request = pendingRequest
                pendingRequest = null
                
                if (request == null) {
                    VpnFileLogger.w(TAG, "没有待处理的VPN请求")
                    return
                }
                
                if (resultCode == Activity.RESULT_OK) {
                    VpnFileLogger.d(TAG, "VPN权限获取成功")
                    
                    channel.invokeMethod("onVpnPermissionGranted", null)
                    
                    mainScope.launch {
                        try {
                            synchronized(pendingResultLock) {
                                pendingStartResult = request.result
                                
                                // 设置超时保护
                                startTimeoutJob = mainScope.launch {
                                    delay(VPN_START_TIMEOUT)
                                    synchronized(pendingResultLock) {
                                        pendingStartResult?.let {
                                            VpnFileLogger.e(TAG, "VPN启动超时")
                                            it.error("TIMEOUT", "VPN启动超时", null)
                                            pendingStartResult = null
                                        }
                                    }
                                }
                            }
                            
                            // 启动服务
                            V2RayVpnService.startVpnService(
                                this@MainActivity,
                                request.config,
                                request.globalProxy,
                                null,  // blockedApps始终为null
                                request.allowedApps,
                                V2RayVpnService.Companion.AppProxyMode.EXCLUDE,
                                request.bypassSubnets,
                                true,  // enableAutoStats
                                request.localizedStrings["disconnectButtonName"] ?: "Disconnect",
                                request.localizedStrings,
                                request.enableVirtualDns,
                                request.virtualDnsPort
                            )
                        } catch (e: Exception) {
                            VpnFileLogger.e(TAG, "启动VPN服务失败", e)
                            request.result.error("START_FAILED", e.message, null)
                            synchronized(pendingResultLock) {
                                pendingStartResult = null
                                startTimeoutJob?.cancel()
                            }
                        }
                    }
                } else {
                    VpnFileLogger.d(TAG, "VPN权限被拒绝")
                    channel.invokeMethod("onVpnPermissionDenied", null)
                    request.result.error("PERMISSION_DENIED", "用户拒绝了VPN权限", null)
                }
            }
        }
    }
    
    /**
     * 处理权限请求结果（Android 13+通知权限）
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        
        when (requestCode) {
            NOTIFICATION_REQUEST_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    VpnFileLogger.d(TAG, "通知权限已授予")
                    channel.invokeMethod("onNotificationPermissionGranted", null)
                } else {
                    VpnFileLogger.w(TAG, "通知权限被拒绝")
                    channel.invokeMethod("onNotificationPermissionDenied", null)
                }
            }
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        
        // 清理pending状态
        cancelPendingStart("Activity销毁")
        
        // 注销广播接收器
        unregisterReceivers()
        
        // 取消所有协程
        mainScope.cancel()
    }
}
