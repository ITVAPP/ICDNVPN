package com.example.cfvpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import kotlinx.coroutines.*

/**
 * 开机自启动接收器
 * 用于在设备启动后自动连接VPN
 * 
 * 设计原则：
 * 1. 使用goAsync()延长接收器生命周期
 * 2. 避免使用GlobalScope
 * 3. 添加重试机制
 * 4. 完善错误处理
 */
class BootReceiver : BroadcastReceiver() {
    
    companion object {
        private const val TAG = "BootReceiver"
        private const val MAX_RETRY_COUNT = 3
        private const val INITIAL_DELAY = 10000L  // 10秒初始延迟
        private const val RETRY_DELAY = 5000L     // 5秒重试延迟
    }
    
    override fun onReceive(context: Context?, intent: Intent?) {
        // 验证context和intent
        if (context == null || intent == null) {
            return
        }
        
        // 只处理开机完成事件
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && 
            intent.action != "android.intent.action.QUICKBOOT_POWERON") {
            return
        }
        
        // 使用applicationContext避免context泄漏
        val appContext = context.applicationContext
        
        // 初始化日志系统（带错误保护）
        try {
            VpnFileLogger.init(appContext)
            VpnFileLogger.d(TAG, "收到开机广播: ${intent.action}")
        } catch (e: Exception) {
            // 日志系统初始化失败，继续执行但不记录日志
        }
        
        // 使用goAsync()延长BroadcastReceiver的生命周期
        val pendingResult = goAsync()
        
        // 创建独立的协程作用域（不使用GlobalScope）
        val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        
        scope.launch {
            try {
                handleBootCompleted(appContext)
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "处理开机启动失败", e)
            } finally {
                // 完成异步操作
                try {
                    pendingResult.finish()
                } catch (e: Exception) {
                    // 忽略finish异常
                }
                // 取消协程作用域
                scope.cancel()
            }
        }
    }
    
    /**
     * 处理开机完成事件
     */
    private suspend fun handleBootCompleted(context: Context) {
        try {
            // 检查是否启用了开机自启动
            val prefs = context.getSharedPreferences("vpn_settings", Context.MODE_PRIVATE)
            val autoStart = prefs.getBoolean("auto_start_on_boot", false)
            
            if (!autoStart) {
                VpnFileLogger.d(TAG, "开机自启动未启用")
                return
            }
            
            // 获取保存的配置
            val lastConfig = prefs.getString("last_vpn_config", null)
            if (lastConfig.isNullOrEmpty()) {
                VpnFileLogger.w(TAG, "没有保存的VPN配置")
                return
            }
            
            val mode = prefs.getString("last_mode", "VPN_TUN") ?: "VPN_TUN"
            val globalProxy = prefs.getBoolean("last_global_proxy", false)
            
            VpnFileLogger.d(TAG, "准备自动启动VPN，模式: $mode")
            
            // 等待系统完全就绪
            waitForSystemReady(context)
            
            // 如果是VPN_TUN模式，检查VPN权限
            if (mode == "VPN_TUN" && !checkVpnPermission(context)) {
                VpnFileLogger.w(TAG, "没有VPN权限，无法自动启动")
                // 可以发送通知提醒用户手动连接
                sendNotification(context, "VPN自动连接失败", "请手动打开应用连接VPN")
                return
            }
            
            // 尝试启动VPN服务（带重试机制）
            var retryCount = 0
            var success = false
            
            while (retryCount < MAX_RETRY_COUNT && !success) {
                try {
                    if (retryCount > 0) {
                        VpnFileLogger.d(TAG, "第${retryCount + 1}次重试启动VPN")
                        delay(RETRY_DELAY)
                    }
                    
                    startVpnService(context, lastConfig, mode, globalProxy)
                    
                    // 等待服务启动
                    delay(3000)
                    
                    // 检查服务是否成功启动
                    success = V2RayVpnService.isServiceRunning()
                    
                    if (success) {
                        VpnFileLogger.i(TAG, "VPN自动启动成功")
                        // 可以发送成功通知
                        sendNotification(context, "VPN已连接", "开机自动连接成功")
                    }
                    
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "启动VPN失败 (尝试 ${retryCount + 1}/$MAX_RETRY_COUNT)", e)
                }
                
                retryCount++
            }
            
            if (!success) {
                VpnFileLogger.e(TAG, "VPN自动启动失败，已尝试$MAX_RETRY_COUNT次")
                sendNotification(context, "VPN自动连接失败", "请手动打开应用连接")
            }
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "handleBootCompleted异常", e)
        }
    }
    
    /**
     * 等待系统完全就绪
     * 某些设备需要更长时间才能完全启动
     */
    private suspend fun waitForSystemReady(context: Context) {
        VpnFileLogger.d(TAG, "等待系统就绪...")
        
        // 初始延迟
        delay(INITIAL_DELAY)
        
        // 检查系统是否已经完全启动
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (powerManager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // 等待设备进入交互状态
            var waitTime = 0L
            while (!powerManager.isInteractive && waitTime < 30000) {
                delay(1000)
                waitTime += 1000
            }
        }
        
        VpnFileLogger.d(TAG, "系统已就绪")
    }
    
    /**
     * 检查VPN权限
     */
    private fun checkVpnPermission(context: Context): Boolean {
        return try {
            VpnService.prepare(context) == null
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "检查VPN权限失败", e)
            false
        }
    }
    
    /**
     * 启动VPN服务
     */
    private fun startVpnService(
        context: Context,
        config: String,
        mode: String,
        globalProxy: Boolean
    ) {
        try {
            val connectionMode = try {
                V2RayVpnService.ConnectionMode.valueOf(mode)
            } catch (e: Exception) {
                V2RayVpnService.ConnectionMode.VPN_TUN
            }
            
            V2RayVpnService.startVpnService(
                context = context,
                config = config,
                mode = connectionMode,
                globalProxy = globalProxy,
                enableAutoStats = false  // 开机自启动时不启用自动统计
            )
            
            VpnFileLogger.d(TAG, "VPN服务启动命令已发送")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "发送启动命令失败", e)
            throw e
        }
    }
    
    /**
     * 发送通知（可选功能）
     */
    private fun sendNotification(context: Context, title: String, message: String) {
        try {
            // Android 13+需要通知权限
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val permission = context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                if (permission != PackageManager.PERMISSION_GRANTED) {
                    return
                }
            }
            
            // 这里可以实现通知发送逻辑
            // 为了简化，暂时只记录日志
            VpnFileLogger.i(TAG, "通知: $title - $message")
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "发送通知失败", e)
        }
    }
}

/**
 * 自动启动管理器
 * 用于保存和管理自动启动配置
 */
object AutoStartManager {
    
    private const val TAG = "AutoStartManager"
    private const val PREFS_NAME = "vpn_settings"
    
    /**
     * 保存VPN配置（用于自启动）
     */
    @JvmStatic
    fun saveAutoStartConfig(
        context: Context,
        config: String,
        mode: String,
        globalProxy: Boolean
    ) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putString("last_vpn_config", config)
                putString("last_mode", mode)
                putBoolean("last_global_proxy", globalProxy)
                putLong("last_save_time", System.currentTimeMillis())
                apply()
            }
            VpnFileLogger.d(TAG, "已保存自启动配置，模式: $mode")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "保存自启动配置失败", e)
        }
    }
    
    /**
     * 设置是否开机自启动
     */
    @JvmStatic
    fun setAutoStartEnabled(context: Context, enabled: Boolean) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean("auto_start_on_boot", enabled).apply()
            
            // 启用/禁用BootReceiver
            val receiver = android.content.ComponentName(context, BootReceiver::class.java)
            val pm = context.packageManager
            
            val newState = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            
            try {
                pm.setComponentEnabledSetting(
                    receiver,
                    newState,
                    PackageManager.DONT_KILL_APP
                )
                VpnFileLogger.d(TAG, "BootReceiver ${if (enabled) "已启用" else "已禁用"}")
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "设置BootReceiver状态失败", e)
                throw e
            }
            
            VpnFileLogger.i(TAG, "开机自启动${if (enabled) "已启用" else "已禁用"}")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "设置开机自启动失败", e)
            throw e
        }
    }
    
    /**
     * 检查是否启用了开机自启动
     */
    @JvmStatic
    fun isAutoStartEnabled(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("auto_start_on_boot", false)
            
            // 同时检查组件状态
            val pm = context.packageManager
            val receiver = android.content.ComponentName(context, BootReceiver::class.java)
            val componentState = pm.getComponentEnabledSetting(receiver)
            
            // 只有当配置和组件状态都启用时才返回true
            enabled && componentState == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "检查开机自启动状态失败", e)
            false
        }
    }
    
    /**
     * 清除自启动配置
     */
    @JvmStatic
    fun clearAutoStartConfig(context: Context) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                remove("last_vpn_config")
                remove("last_mode")
                remove("last_global_proxy")
                remove("last_save_time")
                apply()
            }
            VpnFileLogger.d(TAG, "已清除自启动配置")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "清除自启动配置失败", e)
        }
    }
    
    /**
     * 获取上次保存的配置时间
     */
    @JvmStatic
    fun getLastSaveTime(context: Context): Long {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.getLong("last_save_time", 0L)
        } catch (e: Exception) {
            0L
        }
    }
}