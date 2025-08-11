package com.example.cfvpn

import android.Manifest
import android.app.Activity
import android.content.Intent
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
 * 增强版：支持分应用代理、子网绕过、延迟测试、Android 13+通知权限等功能
 */
class MainActivity: FlutterActivity() {
    
    companion object {
        private const val CHANNEL = "com.example.cfvpn/v2ray"
        private const val VPN_REQUEST_CODE = 100
        private const val NOTIFICATION_REQUEST_CODE = 101
        private const val TAG = "MainActivity"
    }
    
    private lateinit var channel: MethodChannel
    private val mainScope = MainScope()
    
    // 保存待处理的VPN启动请求
    private data class PendingVpnRequest(
        val config: String,
        val mode: String,
        val globalProxy: Boolean,
        val blockedApps: List<String>?,
        val allowedApps: List<String>?,
        val appProxyMode: String,
        val bypassSubnets: List<String>?,
        val result: MethodChannel.Result
    )
    private var pendingRequest: PendingVpnRequest? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 初始化文件日志系统
        VpnFileLogger.init(applicationContext)
        
        // 设置方法通道，处理Flutter调用
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    // 启动VPN（增强版：支持更多参数）
                    val config = call.argument<String>("config")
                    val mode = call.argument<String>("mode") ?: "VPN_TUN"
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    val blockedApps = call.argument<List<String>>("blockedApps")
                    val allowedApps = call.argument<List<String>>("allowedApps")
                    val appProxyMode = call.argument<String>("appProxyMode") ?: "EXCLUDE"
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets")
                    
                    if (config != null) {
                        // 检查通知权限（Android 13+）- 但不阻塞VPN启动
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (!checkNotificationPermission()) {
                                VpnFileLogger.w(TAG, "没有通知权限，但继续启动VPN")
                                requestNotificationPermission()
                                // 不等待权限结果，继续启动VPN
                            }
                        }
                        
                        startVpn(config, mode, globalProxy, blockedApps, allowedApps, appProxyMode, bypassSubnets, result)
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
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
                    // 获取流量统计（增强版：返回更详细的数据）
                    val stats = V2RayVpnService.getTrafficStats()
                    // 添加格式化的数据
                    val enhancedStats = stats.toMutableMap()
                    enhancedStats["uploadFormatted"] = formatBytes(stats["uploadTotal"] as? Long ?: 0L)
                    enhancedStats["downloadFormatted"] = formatBytes(stats["downloadTotal"] as? Long ?: 0L)
                    enhancedStats["uploadSpeedFormatted"] = "${formatBytes(stats["uploadSpeed"] as? Long ?: 0L)}/s"
                    enhancedStats["downloadSpeedFormatted"] = "${formatBytes(stats["downloadSpeed"] as? Long ?: 0L)}/s"
                    result.success(enhancedStats)
                }
                
                "checkPermission" -> {
                    // 检查VPN权限
                    val hasPermission = checkVpnPermission()
                    result.success(hasPermission)
                }
                
                // ===== 新增功能 =====
                
                "testConnectedDelay" -> {
                    // 测试已连接服务器的延迟
                    val testUrl = call.argument<String>("url") ?: "https://www.google.com/generate_204"
                    
                    mainScope.launch {
                        try {
                            val delay = V2RayVpnService.testConnectedDelay(testUrl)
                            result.success(delay)
                        } catch (e: Exception) {
                            VpnFileLogger.e(TAG, "测试延迟失败", e)
                            result.error("TEST_FAILED", e.message, null)
                        }
                    }
                }
                
                "testServerDelay" -> {
                    // 测试指定配置的服务器延迟（未连接状态）
                    val config = call.argument<String>("config")
                    val testUrl = call.argument<String>("url") ?: "https://www.google.com/generate_204"
                    
                    if (config != null) {
                        mainScope.launch {
                            try {
                                val delay = V2RayVpnService.testServerDelay(config, testUrl)
                                result.success(delay)
                            } catch (e: Exception) {
                                VpnFileLogger.e(TAG, "测试延迟失败", e)
                                result.error("TEST_FAILED", e.message, null)
                            }
                        }
                    } else {
                        result.error("INVALID_CONFIG", "配置为空", null)
                    }
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
                    // 保存代理配置（分应用代理、子网绕过等）
                    val blockedApps = call.argument<List<String>>("blockedApps") ?: emptyList()
                    val bypassSubnets = call.argument<List<String>>("bypassSubnets") ?: emptyList()
                    
                    saveProxyConfig(blockedApps, bypassSubnets)
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
                    AutoStartManager.setAutoStartEnabled(this, enabled)
                    result.success(true)
                }
                
                "isAutoStartEnabled" -> {
                    // 检查开机自启动是否启用
                    val enabled = AutoStartManager.isAutoStartEnabled(this)
                    result.success(enabled)
                }
                
                "saveAutoStartConfig" -> {
                    // 保存自启动配置
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
     * 启动VPN（增强版）
     */
    private fun startVpn(
        config: String,
        mode: String,
        globalProxy: Boolean,
        blockedApps: List<String>?,
        allowedApps: List<String>?,
        appProxyMode: String,
        bypassSubnets: List<String>?,
        result: MethodChannel.Result
    ) {
        mainScope.launch {
            try {
                // 检查是否已在运行
                if (V2RayVpnService.isServiceRunning()) {
                    VpnFileLogger.w(TAG, "VPN已在运行，先停止再启动")
                    V2RayVpnService.stopVpnService(this@MainActivity)
                    delay(500)
                }
                
                // PROXY_ONLY模式不需要VPN权限
                if (mode == "PROXY_ONLY") {
                    VpnFileLogger.d(TAG, "仅代理模式，无需VPN权限")
                    V2RayVpnService.startVpnService(
                        this@MainActivity,
                        config,
                        V2RayVpnService.ConnectionMode.PROXY_ONLY,
                        globalProxy,
                        blockedApps,
                        allowedApps,
                        V2RayVpnService.AppProxyMode.valueOf(appProxyMode),
                        bypassSubnets
                    )
                    
                    delay(1000)
                    
                    val isRunning = V2RayVpnService.isServiceRunning()
                    if (isRunning) {
                        result.success(true)
                        channel.invokeMethod("onVpnConnected", null)
                    } else {
                        result.error("START_FAILED", "服务启动失败", null)
                    }
                    return@launch
                }
                
                // VPN_TUN模式需要VPN权限
                val intent = VpnService.prepare(this@MainActivity)
                if (intent != null) {
                    VpnFileLogger.d(TAG, "需要请求VPN权限")
                    
                    pendingRequest = PendingVpnRequest(
                        config, mode, globalProxy, blockedApps, 
                        allowedApps, appProxyMode, bypassSubnets, result
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
                    V2RayVpnService.startVpnService(
                        this@MainActivity,
                        config,
                        V2RayVpnService.ConnectionMode.valueOf(mode),
                        globalProxy,
                        blockedApps,
                        allowedApps,
                        V2RayVpnService.AppProxyMode.valueOf(appProxyMode),
                        bypassSubnets
                    )
                    
                    delay(1000)
                    
                    val isRunning = V2RayVpnService.isServiceRunning()
                    if (isRunning) {
                        result.success(true)
                        channel.invokeMethod("onVpnConnected", null)
                    } else {
                        result.error("START_FAILED", "VPN服务启动失败", null)
                    }
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
        V2RayVpnService.stopVpnService(this)
        
        // 通知Flutter端断开连接
        mainScope.launch {
            delay(500) // 等待服务停止
            channel.invokeMethod("onVpnDisconnected", null)
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
     * 获取已安装应用列表（供分应用代理选择）
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
    private fun saveProxyConfig(blockedApps: List<String>, bypassSubnets: List<String>) {
        val prefs = getSharedPreferences("proxy_config", MODE_PRIVATE)
        prefs.edit().apply {
            putStringSet("blocked_apps", blockedApps.toSet())
            putStringSet("bypass_subnets", bypassSubnets.toSet())
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
            "blockedApps" to (prefs.getStringSet("blocked_apps", emptySet())?.toList() ?: emptyList()),
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
                            V2RayVpnService.startVpnService(
                                this@MainActivity,
                                request.config,
                                V2RayVpnService.ConnectionMode.valueOf(request.mode),
                                request.globalProxy,
                                request.blockedApps,
                                request.allowedApps,
                                V2RayVpnService.AppProxyMode.valueOf(request.appProxyMode),
                                request.bypassSubnets
                            )
                            
                            delay(1000)
                            
                            val isRunning = V2RayVpnService.isServiceRunning()
                            if (isRunning) {
                                request.result.success(true)
                                channel.invokeMethod("onVpnConnected", null)
                            } else {
                                request.result.error("START_FAILED", "VPN服务启动失败", null)
                            }
                        } catch (e: Exception) {
                            VpnFileLogger.e(TAG, "启动VPN服务失败", e)
                            request.result.error("START_FAILED", e.message, null)
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
        // 取消所有协程
        mainScope.cancel()
    }
}