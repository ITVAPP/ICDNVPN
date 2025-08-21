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
 * 增强版：支持分应用代理、子网绕过、Android 13+通知权限等功能
 * 修改：支持国际化文字传递
 * 优化：实时流量统计查询
 * 
 * 简化版本：
 * - 不接收blockedApps（Dart端不传递）
 * - 不接收appProxyMode（Dart端不传递）
 * - 只使用allowedApps：空列表=全部应用走VPN，非空=仅列表内应用走VPN
 */
class MainActivity: FlutterActivity() {
    
    companion object {
        private const val CHANNEL = "com.example.cfvpn/v2ray"
        private const val VPN_REQUEST_CODE = 100
        private const val NOTIFICATION_REQUEST_CODE = 101
        private const val TAG = "MainActivity"
        
        // 新增：VPN启动结果广播
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"  // 新增：VPN停止广播
        private const val VPN_START_TIMEOUT = 10000L  // 10秒超时
    }
    
    private lateinit var channel: MethodChannel
    private val mainScope = MainScope()
    
    // 保存待处理的VPN启动请求（增加国际化文字参数）
    private data class PendingVpnRequest(
        val config: String,
        val globalProxy: Boolean,
        val allowedApps: List<String>?,
        val bypassSubnets: List<String>?,
        val localizedStrings: Map<String, String>,  // 新增：国际化文字
        val enableVirtualDns: Boolean,  // 新增：虚拟DNS开关
        val virtualDnsPort: Int,  // 新增：虚拟DNS端口
        val result: MethodChannel.Result
    )
    private var pendingRequest: PendingVpnRequest? = null
    
    // 修复：添加同步锁保护并发访问
    private val pendingResultLock = Any()
    private var pendingStartResult: MethodChannel.Result? = null
    private var startTimeoutJob: Job? = null
    
    // 新增：VPN启动结果广播接收器
    private val vpnStartResultReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_VPN_START_RESULT) {
                val success = intent.getBooleanExtra("success", false)
                val error = intent.getStringExtra("error")
                
                VpnFileLogger.d(TAG, "收到VPN启动结果广播: success=$success, error=$error")
                
                // 修复：使用同步锁保护并发访问
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
    
    // 新增：VPN停止广播接收器（用于通知栏停止按钮）
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
        
        // 注册VPN启动结果广播接收器
        registerReceiver(vpnStartResultReceiver, IntentFilter(ACTION_VPN_START_RESULT))
        
        // 注册VPN停止广播接收器（用于通知栏停止按钮）
        registerReceiver(vpnStoppedReceiver, IntentFilter(ACTION_VPN_STOPPED))
        
        // 设置方法通道，处理Flutter调用
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    // 修复：使用同步锁检查重复调用
                    synchronized(pendingResultLock) {
                        if (pendingStartResult != null) {
                            VpnFileLogger.w(TAG, "正在处理上一个VPN启动请求")
                            result.error("BUSY", "正在处理上一个连接请求", null)
                            return@setMethodCallHandler
                        }
                    }
                    
                    // 启动VPN（增强版：支持国际化文字）
                    val config = call.argument<String>("config")
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    
                    // 简化：只接收Dart端实际传递的参数
                    val allowedApps = call.argument<List<String>>("allowedApps")
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets")
                    
                    // 新增：提取虚拟DNS配置
                    val enableVirtualDns = call.argument<Boolean>("enableVirtualDns") ?: false
                    val virtualDnsPort = call.argument<Int>("virtualDnsPort") ?: 10853
                    
                    // 新增：接收国际化文字
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
                        // 检查通知权限（Android 13+）- 但不阻塞VPN启动
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (!checkNotificationPermission()) {
                                VpnFileLogger.w(TAG, "没有通知权限，但继续启动VPN")
                                requestNotificationPermission()
                                // 不等待权限结果，继续启动VPN
                            }
                        }
                        
                        startVpn(config, globalProxy, allowedApps, bypassSubnets, localizedStrings, enableVirtualDns, virtualDnsPort, result)
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
                    }
                }
                
                "updateNotificationStrings" -> {
                    // 更新通知栏文字（语言切换时）
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
                        
                        VpnFileLogger.d(TAG, "收到更新通知栏文字请求")
                        
                        // 调用服务的静态方法更新通知
                        val success = V2RayVpnService.updateNotificationStrings(localizedStrings)
                        
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
                    // 检查VPN是否连接
                    val isConnected = V2RayVpnService.isServiceRunning()
                    result.success(isConnected)
                }
                
"getTrafficStats" -> {
    // 简化版：直接返回V2RayVpnService的原始数据
    try {
        val stats = V2RayVpnService.getTrafficStats()
        VpnFileLogger.d(TAG, "返回流量统计: 上传=${stats["uploadTotal"]}, 下载=${stats["downloadTotal"]}")
        result.success(stats)
    } catch (e: Exception) {
        VpnFileLogger.e(TAG, "获取流量统计失败", e)
        result.error("GET_STATS_FAILED", e.message, null)
    }
}

"requestBatteryOptimization" -> {
    // 请求电池优化豁免
    try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val packageName = packageName
            
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                VpnFileLogger.d(TAG, "请求电池优化豁免")
                val intent = Intent().apply {
                    action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
                result.success(true)  // 需要请求
            } else {
                VpnFileLogger.d(TAG, "已有电池优化豁免权限")
                result.success(false)  // 不需要请求
            }
        } else {
            // 低版本不需要
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
                    // 获取已安装应用列表（供选择分应用代理）
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
                    // 保存代理配置（简化：只保存allowedApps和bypassSubnets）
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
                    // 清除自启动配置（可选功能）
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
     * 启动VPN（简化版）
     * 修复：等待Service真正启动完成后再返回结果
     */
    private fun startVpn(
        config: String,
        globalProxy: Boolean,
        allowedApps: List<String>?,
        bypassSubnets: List<String>?,
        localizedStrings: Map<String, String>,  // 新增：国际化文字
        enableVirtualDns: Boolean,  // 新增：虚拟DNS开关
        virtualDnsPort: Int,  // 新增：虚拟DNS端口
        result: MethodChannel.Result
    ) {
        mainScope.launch {
            try {
                // 检查是否已在运行
                if (V2RayVpnService.isServiceRunning()) {
                    VpnFileLogger.w(TAG, "VPN已在运行，先停止再启动")
                    
                    // 清理可能存在的pending状态
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
                        localizedStrings,  // 保存国际化文字
                        enableVirtualDns,  // 保存虚拟DNS开关
                        virtualDnsPort,  // 保存虚拟DNS端口
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
                    
                    // 修复：使用同步锁保护设置pendingStartResult
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
                    
                    // 启动服务（传递虚拟DNS配置）
                    V2RayVpnService.startVpnService(
                        this@MainActivity,
                        config,
                        globalProxy,
                        null,  // blockedApps始终为null（简化）
                        allowedApps,
                        V2RayVpnService.Companion.AppProxyMode.EXCLUDE,  // appProxyMode使用固定值（简化）
                        bypassSubnets,
                        true,  // enableAutoStats
                        localizedStrings["disconnectButtonName"] ?: "Disconnect",
                        localizedStrings,  // 传递国际化文字
                        enableVirtualDns,  // 传递虚拟DNS开关
                        virtualDnsPort  // 传递虚拟DNS端口
                    )
                    
                    // 等待Service通过广播返回结果
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动VPN失败", e)
                result.error("START_FAILED", e.message, null)
            }
        }
    }
    
    /**
     * 停止VPN
     * 修复：清理pending状态，不再主动通知Flutter（由Service广播通知）
     */
    private fun stopVpn() {
        VpnFileLogger.d(TAG, "停止VPN服务")
        
        // 如果正在连接，取消并返回错误
        cancelPendingStart("用户取消连接")
        
        V2RayVpnService.stopVpnService(this)
        
        // 移除：不再这里通知Flutter，改由Service广播通知
        // 这样避免重复通知，且通知栏停止也能正确通知Flutter
    }
    
    /**
     * 取消待处理的启动请求
     * 修复：使用同步锁保护并发访问
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
     * 保存代理配置（简化版）
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
     * 加载代理配置（简化版）
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
                            // 修复：使用同步锁保护设置pendingStartResult
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
                            
                            // 启动服务（传递虚拟DNS配置）
                            V2RayVpnService.startVpnService(
                                this@MainActivity,
                                request.config,
                                request.globalProxy,
                                null,  // blockedApps始终为null（简化）
                                request.allowedApps,
                                V2RayVpnService.Companion.AppProxyMode.EXCLUDE,  // appProxyMode使用固定值（简化）
                                request.bypassSubnets,
                                true,  // enableAutoStats
                                request.localizedStrings["disconnectButtonName"] ?: "Disconnect",
                                request.localizedStrings,  // 传递国际化文字
                                request.enableVirtualDns,  // 传递虚拟DNS开关
                                request.virtualDnsPort  // 传递虚拟DNS端口
                            )
                            
                            // 等待Service通过广播返回结果
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
        
        // 取消所有协程
        mainScope.cancel()
    }
}