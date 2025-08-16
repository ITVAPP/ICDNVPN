package com.example.cfvpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import kotlinx.coroutines.*

// 接收设备启动广播，自动连接VPN
class BootReceiver : BroadcastReceiver() {
    
    companion object {
        private const val TAG = "BootReceiver"
        private const val MAX_RETRY_COUNT = 3
        private const val INITIAL_DELAY = 10000L  // 延迟10秒等待系统启动
        private const val RETRY_DELAY = 5000L     // 重试间隔5秒
    }
    
    // 处理广播事件，启动VPN服务
    override fun onReceive(context: Context?, intent: Intent?) {
        // 验证上下文和意图非空
        if (context == null || intent == null) return
        
        // 仅处理开机完成或快速启动事件
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && 
            intent.action != "android.intent.action.QUICKBOOT_POWERON") return
        
        // 获取应用上下文防止泄漏
        val appContext = context.applicationContext
        
        // 初始化日志系统，捕获异常
        try {
            VpnFileLogger.init(appContext)
            VpnFileLogger.d(TAG, "接收开机广播: ${intent.action}")
        } catch (e: Exception) {
        }
        
        // 延长广播生命周期
        val pendingResult = goAsync()
        
        // 创建IO协程作用域
        val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        
        // 异步处理开机事件
        scope.launch {
            try {
                handleBootCompleted(appContext)
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "处理开机事件失败", e)
            } finally {
                // 完成异步操作
                try {
                    pendingResult.finish()
                } catch (e: Exception) {
                }
                // 取消协程作用域
                scope.cancel()
            }
        }
    }
    
    // 处理开机完成逻辑，检查配置并启动VPN
    private suspend fun handleBootCompleted(context: Context) {
        // 获取VPN设置
        val prefs = context.getSharedPreferences("vpn_settings", Context.MODE_PRIVATE)
        val autoStart = prefs.getBoolean("auto_start_on_boot", false)
        
        // 检查自启动是否启用
        if (!autoStart) {
            VpnFileLogger.d(TAG, "自启动未启用")
            return
        }
        
        // 获取上次VPN配置
        val lastConfig = prefs.getString("last_vpn_config", null)
        if (lastConfig.isNullOrEmpty()) {
            VpnFileLogger.w(TAG, "无有效VPN配置")
            return
        }
        
        // 获取代理设置和虚拟DNS配置
        val globalProxy = prefs.getBoolean("last_global_proxy", false)
        val enableVirtualDns = prefs.getBoolean("last_enable_virtual_dns", false)
        val virtualDnsPort = prefs.getInt("last_virtual_dns_port", 10853)
        
        VpnFileLogger.d(TAG, "准备启动VPN，全局代理: $globalProxy, 虚拟DNS: $enableVirtualDns")
        
        // 等待系统完全启动
        waitForSystemReady(context)
        
        // 检查VPN权限
        if (!checkVpnPermission(context)) {
            VpnFileLogger.w(TAG, "缺少VPN权限")
            sendNotification(context, "VPN自动连接失败", "请手动连接VPN")
            return
        }
        
        // 尝试启动VPN服务
        var retryCount = 0
        var success = false
        
        while (retryCount < MAX_RETRY_COUNT && !success) {
            try {
                if (retryCount > 0) {
                    VpnFileLogger.d(TAG, "重试启动VPN: ${retryCount + 1}次")
                    delay(RETRY_DELAY)
                }
                
                // 启动VPN服务
                startVpnService(context, lastConfig, globalProxy, enableVirtualDns, virtualDnsPort)
                
                // 等待服务响应
                delay(3000)
                
                // 验证服务状态
                success = V2RayVpnService.isServiceRunning()
                
                if (success) {
                    VpnFileLogger.i(TAG, "VPN启动成功")
                    sendNotification(context, "VPN已连接", "自动连接成功")
                }
                
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "VPN启动失败: ${retryCount + 1}/$MAX_RETRY_COUNT", e)
            }
            
            retryCount++
        }
        
        // 处理最终失败
        if (!success) {
            VpnFileLogger.e(TAG, "VPN启动失败，尝试次数: $MAX_RETRY_COUNT")
            sendNotification(context, "VPN自动连接失败", "请手动连接")
        }
    }
    
    // 等待系统进入交互状态
    private suspend fun waitForSystemReady(context: Context) {
        VpnFileLogger.d(TAG, "等待系统就绪")
        
        // 初始延迟
        delay(INITIAL_DELAY)
        
        // 检查设备交互状态
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (powerManager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            var waitTime = 0L
            var checkInterval = 1000L
            
            // 指数退避检查交互状态
            while (!powerManager.isInteractive && waitTime < 30000) {
                delay(checkInterval)
                waitTime += checkInterval
                checkInterval = minOf(checkInterval * 2, 4000L)
                VpnFileLogger.d(TAG, "等待交互状态: ${waitTime}ms")
            }
        }
        
        VpnFileLogger.d(TAG, "系统就绪")
    }
    
    // 检查VPN服务权限
    private fun checkVpnPermission(context: Context): Boolean {
        return try {
            VpnService.prepare(context) == null
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "VPN权限检查失败", e)
            false
        }
    }
    
    // 启动VPN服务并配置参数（修改以适配新API）
    private fun startVpnService(
        context: Context, 
        config: String, 
        globalProxy: Boolean,
        enableVirtualDns: Boolean,
        virtualDnsPort: Int
    ) {
        try {
            // 发起VPN服务（使用新的API签名）
            V2RayVpnService.startVpnService(
                context = context,
                config = config,
                globalProxy = globalProxy,
                blockedApps = null,  // 不使用
                allowedApps = null,  // 自启动时使用默认设置
                appProxyMode = V2RayVpnService.Companion.AppProxyMode.EXCLUDE,
                bypassSubnets = null,  // 使用默认设置
                enableAutoStats = false,  // 自启动时禁用流量统计
                disconnectButtonName = "停止",
                localizedStrings = emptyMap(),  // 自启动时使用默认文字
                enableVirtualDns = enableVirtualDns,  // 传递虚拟DNS设置
                virtualDnsPort = virtualDnsPort  // 传递虚拟DNS端口
            )
            
            VpnFileLogger.d(TAG, "VPN服务启动命令发送，虚拟DNS: $enableVirtualDns")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "VPN服务启动失败", e)
            throw e
        }
    }
    
    // 发送通知提示用户
    private fun sendNotification(context: Context, title: String, message: String) {
        try {
            // 检查通知权限（Android 13+）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val permission = context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                if (permission != PackageManager.PERMISSION_GRANTED) return
            }
            
            VpnFileLogger.i(TAG, "发送通知: $title - $message")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "通知发送失败", e)
        }
    }
}

// 管理VPN自启动配置
object AutoStartManager {
    
    private const val TAG = "AutoStartManager"
    private const val PREFS_NAME = "vpn_settings"
    
    // 保存VPN配置信息（修改以包含虚拟DNS配置）
    @JvmStatic
    fun saveAutoStartConfig(
        context: Context, 
        config: String, 
        mode: String,  // 保留参数以保持兼容性，但不再使用
        globalProxy: Boolean,
        enableVirtualDns: Boolean = false,
        virtualDnsPort: Int = 10853
    ) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putString("last_vpn_config", config)
                putString("last_mode", mode)  // 保留以兼容旧版本
                putBoolean("last_global_proxy", globalProxy)
                putBoolean("last_enable_virtual_dns", enableVirtualDns)
                putInt("last_virtual_dns_port", virtualDnsPort)
                putLong("last_save_time", System.currentTimeMillis())
                apply()
            }
            VpnFileLogger.d(TAG, "保存自启动配置: 全局代理=$globalProxy, 虚拟DNS=$enableVirtualDns")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "保存配置失败", e)
        }
    }
    
    // 保存VPN配置信息（重载方法，保持向后兼容）
    @JvmStatic
    fun saveAutoStartConfig(context: Context, config: String, mode: String, globalProxy: Boolean) {
        saveAutoStartConfig(context, config, mode, globalProxy, false, 10853)
    }
    
    // 设置开机自启动状态
    @JvmStatic
    fun setAutoStartEnabled(context: Context, enabled: Boolean) {
        try {
            // 保存自启动设置
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean("auto_start_on_boot", enabled).apply()
            
            // 设置接收器状态
            val receiver = android.content.ComponentName(context, BootReceiver::class.java)
            val pm = context.packageManager
            val newState = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            
            pm.setComponentEnabledSetting(receiver, newState, PackageManager.DONT_KILL_APP)
            VpnFileLogger.d(TAG, "设置BootReceiver: ${if (enabled) "启用" else "禁用"}")
            VpnFileLogger.i(TAG, "开机自启动: ${if (enabled) "启用" else "禁用"}")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "设置自启动失败", e)
            throw e
        }
    }
    
    // 检查自启动是否启用
    @JvmStatic
    fun isAutoStartEnabled(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("auto_start_on_boot", false)
            val pm = context.packageManager
            val receiver = android.content.ComponentName(context, BootReceiver::class.java)
            val componentState = pm.getComponentEnabledSetting(receiver)
            enabled && componentState == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "检查自启动状态失败", e)
            false
        }
    }
    
    // 清除自启动配置
    @JvmStatic
    fun clearAutoStartConfig(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                remove("last_vpn_config")
                remove("last_mode")
                remove("last_global_proxy")
                remove("last_enable_virtual_dns")
                remove("last_virtual_dns_port")
                remove("last_save_time")
                apply()
            }
            VpnFileLogger.d(TAG, "清除自启动配置")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "清除配置失败", e)
        }
    }
    
    // 获取配置保存时间
    @JvmStatic
    fun getLastSaveTime(context: Context): Long {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.getLong("last_save_time", 0L)
        } catch (e: Exception) {
            0L
        }
    }
    
    // 获取上次保存的虚拟DNS配置
    @JvmStatic
    fun getLastVirtualDnsConfig(context: Context): Pair<Boolean, Int> {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("last_enable_virtual_dns", false)
            val port = prefs.getInt("last_virtual_dns_port", 10853)
            Pair(enabled, port)
        } catch (e: Exception) {
            Pair(false, 10853)
        }
    }
}
