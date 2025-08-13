package com.example.cfvpn

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

/**
 * 主Activity - 处理Flutter与原生的通信
 * 
 * 版本：简化后的分应用代理
 * - 保持接口向后兼容（接收blockedApps但不使用）
 * - 内部只使用allowedApps：空列表=全部应用走VPN，非空=仅列表内应用走VPN
 * - 支持国际化文字传递
 * - 支持Android 13+通知权限
 */
class MainActivity: FlutterActivity() {
    
    companion object {
        private const val CHANNEL = "com.example.cfvpn/v2ray"
        private const val VPN_REQUEST_CODE = 100
        private const val NOTIFICATION_REQUEST_CODE = 101
        private const val TAG = "MainActivity"
        
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"
        private const val VPN_START_TIMEOUT = 10000L  // 10秒超时
    }
    
    private lateinit var channel: MethodChannel
    private val mainScope = MainScope()
    
    // 保持完整的请求数据结构（向后兼容）
    private data class PendingVpnRequest(
        val config: String,
        val mode: String,
        val globalProxy: Boolean,
        val blockedApps: List<String>?,  // 保留字段以兼容，但传递时为null
        val allowedApps: List<String>?,
        val appProxyMode: String,  // 保留字段以兼容
        val bypassSubnets: List<String>?,
        val localizedStrings: Map<String, String>,
        val result: MethodChannel.Result
    )
    private var pendingRequest: PendingVpnRequest? = null
    
    private val pendingResultLock = Any()
    private var pendingStartResult: MethodChannel.Result? = null
    private var startTimeoutJob: Job? = null
    
    // VPN启动结果广播接收器
    private val vpnStartResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_VPN_START_RESULT) {
                val success = intent.getBooleanExtra("success", false)
                val error = intent.getStringExtra("error")
                
                VpnFileLogger.d(TAG, "收到VPN启动结果广播: success=$success, error=$error")
                
                synchronized(pendingResultLock) {
                    startTimeoutJob?.cancel()
                    startTimeoutJob = null
                    
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
                channel.invokeMethod("onVpnDisconnected", null)
            }
        }
    }
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        VpnFileLogger.init(applicationContext)
        
        registerReceiver(vpnStartResultReceiver, IntentFilter(ACTION_VPN_START_RESULT))
        registerReceiver(vpnStoppedReceiver, IntentFilter(ACTION_VPN_STOPPED))
        
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
                    
                    val config = call.argument<String>("config")
                    val mode = call.argument<String>("mode") ?: "VPN_TUN"
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    
                    // 接收所有参数以保持兼容性
                    val blockedApps = call.argument<List<String>>("blockedApps")  // 接收但不使用
                    val allowedApps = call.argument<List<String>>("allowedApps")
                    val appProxyMode = call.argument<String>("appProxyMode") ?: "EXCLUDE"  // 接收但使用默认值
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets")
                    
                    // 国际化文字
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
                        // Android 13+通知权限检查
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (!checkNotificationPermission()) {
                                VpnFileLogger.w(TAG, "没有通知权限，但继续启动VPN")
                                requestNotificationPermission()
                            }
                        }
                        
                        startVpn(
                            config, mode, globalProxy, 
                            blockedApps,  // 传递以保持兼容
                            allowedApps, 
                            appProxyMode,  // 传递以保持兼容
                            bypassSubnets, 
                            localizedStrings, 
                            result
                        )
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
                    }
                }
                
                "stopVpn" -> {
                    stopVpn()
                    result.success(true)
                }
                
                "isVpnConnected" -> {
                    val isConnected = V2RayVpnService.isServiceRunning()
                    result.success(isConnected)
                }
                
                "getTrafficStats" -> {
                    val stats = V2RayVpnService.getTrafficStats()
                    val enhancedStats = mutableMapOf<String, Any>()
                    
                    enhancedStats.putAll(stats)
                    enhancedStats["uploadFormatted"] = formatBytes(stats["uploadTotal"] ?: 0L)
                    enhancedStats["downloadFormatted"] = formatBytes(stats["downloadTotal"] ?: 0L)
                    enhancedStats["uploadSpeedFormatted"] = "${formatBytes(stats["uploadSpeed"] ?: 0L)}/s"
                    enhancedStats["downloadSpeedFormatted"] = "${formatBytes(stats["downloadSpeed"] ?: 0L)}/s"
                    
                    result.success(enhancedStats)
                }
                
                "checkPermission" -> {
                    val hasPermission = checkVpnPermission()
                    result.success(hasPermission)
                }
                
                "getInstalledApps" -> {
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
                    // 接收所有参数以保持兼容
                    val blockedApps = call.argument<List<String>>("blockedApps") ?: emptyList()
                    val allowedApps = call.argument<List<String>>("allowedApps") ?: emptyList()
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets") ?: emptyList()
                    
                    // 内部只保存allowedApps和bypassSubnets
                    saveProxyConfig(allowedApps, bypassSubnets)
                    result.success(true)
                }
                
                "loadProxyConfig" -> {
                    val config = loadProxyConfig()
                    result.success(config)
                }
                
                // 开机自启动相关
                "setAutoStartEnabled" -> {
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
                    val enabled = AutoStartManager.isAutoStartEnabled(this)
                    result.success(enabled)
                }
                
                "saveAutoStartConfig" -> {
                    val config = call.argument<String>("config")
                    val mode = call.argument<String>("mode") ?: "VPN_TUN"
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    
                    if (config != null) {
                        AutoStartManager.saveAutoStartConfig(this, config, mode, globalProxy)
                        result.success(true)
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
                    }
                }
                
                "clearAutoStartConfig" -> {
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
     * 保持完整参数列表以兼容，但内部简化逻辑
     */
    private fun startVpn(
        config: String,
        mode: String,
        globalProxy: Boolean,
        blockedApps: List<String>?,  // 接收但传null给Service
        allowedApps: List<String>?,
        appProxyMode: String,  // 接收但使用默认值
        bypassSubnets: List<String>?,
        localizedStrings: Map<String, String>,
        result: MethodChannel.Result
    ) {
        mainScope.launch {
            try {
                // 检查是否已在运行
                if (V2RayVpnService.isServiceRunning()) {
                    VpnFileLogger.w(TAG, "VPN已在运行，先停止再启动")
                    cancelPendingStart("服务重启")
                    V2RayVpnService.stopVpnService(this@MainActivity)
                    delay(500)
                }
                
                // PROXY_ONLY模式不需要VPN权限
                if (mode == "PROXY_ONLY") {
                    VpnFileLogger.d(TAG, "仅代理模式，无需VPN权限")
                    
                    synchronized(pendingResultLock) {
                        pendingStartResult = result
                        
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
                        context = this@MainActivity,
                        config = config,
                        mode = V2RayVpnService.ConnectionMode.PROXY_ONLY,
                        globalProxy = globalProxy,
                        blockedApps = null,  // 简化：始终传null
                        allowedApps = allowedApps,
                        appProxyMode = V2RayVpnService.Companion.AppProxyMode.EXCLUDE,  // 使用默认值
                        bypassSubnets = bypassSubnets,
                        enableAutoStats = true,
                        disconnectButtonName = localizedStrings["disconnectButtonName"] ?: "Disconnect",
                        localizedStrings = localizedStrings
                    )
                    
                    return@launch
                }
                
                // VPN_TUN模式需要VPN权限
                val intent = VpnService.prepare(this@MainActivity)
                if (intent != null) {
                    VpnFileLogger.d(TAG, "需要请求VPN权限")
                    
                    pendingRequest = PendingVpnRequest(
                        config, mode, globalProxy,
                        blockedApps,  // 保存原始值以兼容
                        allowedApps, 
                        appProxyMode,  // 保存原始值以兼容
                        bypassSubnets,
                        localizedStrings,
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
                        context = this@MainActivity,
                        config = config,
                        mode = V2RayVpnService.ConnectionMode.valueOf(mode),
                        globalProxy = globalProxy,
                        blockedApps = null,  // 简化：始终传null
                        allowedApps = allowedApps,
                        appProxyMode = V2RayVpnService.Companion.AppProxyMode.EXCLUDE,  // 使用默认值
                        bypassSubnets = bypassSubnets,
                        enableAutoStats = true,
                        disconnectButtonName = localizedStrings["disconnectButtonName"] ?: "Disconnect",
                        localizedStrings = localizedStrings
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
     * 检查VPN权限
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
     * 获取已安装应用列表
     */
    private suspend fun getInstalledApps(): List<Map<String, Any>> = withContext(Dispatchers.IO) {
        val apps = mutableListOf<Map<String, Any>>()
        val pm = packageManager
        
        try {
            val packages = pm.getInstalledApplications(0)
            packages.forEach { appInfo ->
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
            
            apps.sortBy { it["appName"] as String }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "获取应用列表失败", e)
        }
        
        return@withContext apps
    }
    
    /**
     * 保存代理配置
     * 内部只保存allowedApps，但保持向后兼容
     */
    private fun saveProxyConfig(allowedApps: List<String>, bypassSubnets: List<String>) {
        val prefs = getSharedPreferences("proxy_config", MODE_PRIVATE)
        prefs.edit().apply {
            putStringSet("allowed_apps", allowedApps.toSet())
            putStringSet("bypass_subnets", bypassSubnets.toSet())
            
            // 清理旧数据
            remove("blocked_apps")
            apply()
        }
        VpnFileLogger.d(TAG, "代理配置已保存")
    }
    
    /**
     * 加载代理配置
     * 返回兼容的结构（包含空的blockedApps）
     */
    private fun loadProxyConfig(): Map<String, List<String>> {
        val prefs = getSharedPreferences("proxy_config", MODE_PRIVATE)
        
        val defaultBypassSubnets = setOf(
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "127.0.0.0/8"
        )
        
        return mapOf(
            "blockedApps" to emptyList(),  // 返回空列表以保持兼容
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
     * 处理VPN权限请求结果
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
                            
                            // 启动服务（使用保存的参数）
                            V2RayVpnService.startVpnService(
                                context = this@MainActivity,
                                config = request.config,
                                mode = V2RayVpnService.ConnectionMode.valueOf(request.mode),
                                globalProxy = request.globalProxy,
                                blockedApps = null,  // 简化：始终传null
                                allowedApps = request.allowedApps,
                                appProxyMode = V2RayVpnService.Companion.AppProxyMode.EXCLUDE,  // 使用默认值
                                bypassSubnets = request.bypassSubnets,
                                enableAutoStats = true,
                                disconnectButtonName = request.localizedStrings["disconnectButtonName"] ?: "Disconnect",
                                localizedStrings = request.localizedStrings
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
     * 处理通知权限请求结果（Android 13+）
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
        
        cancelPendingStart("Activity销毁")
        
        try {
            unregisterReceiver(vpnStartResultReceiver)
        } catch (e: Exception) {
            // 可能已经注销
        }
        
        try {
            unregisterReceiver(vpnStoppedReceiver)
        } catch (e: Exception) {
            // 可能已经注销
        }
        
        mainScope.cancel()
    }
}
