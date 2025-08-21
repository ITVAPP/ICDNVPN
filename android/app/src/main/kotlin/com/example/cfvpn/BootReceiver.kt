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
 * VPN开机自启动广播接收器
 * 监听系统启动完成事件，自动连接VPN服务
 */
class BootReceiver : BroadcastReceiver() {
    
    companion object {
        private const val TAG = "BootReceiver"
        private const val MAX_RETRY_COUNT = 3           // VPN启动最大重试次数
        private const val INITIAL_DELAY = 10000L        // 系统启动完成后延迟时间
        private const val RETRY_DELAY = 5000L           // VPN启动失败重试间隔
        
        // 支持的开机广播动作类型
        private const val ACTION_BOOT_COMPLETED = Intent.ACTION_BOOT_COMPLETED
        private const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
    
    /**
     * 处理开机广播事件
     * 接收系统启动完成信号并启动VPN服务
     */
    override fun onReceive(context: Context?, intent: Intent?) {
        // 验证广播参数有效性
        if (context == null || intent == null) return
        
        // 过滤非开机相关的广播动作
        if (intent.action != ACTION_BOOT_COMPLETED && 
            intent.action != ACTION_QUICKBOOT_POWERON) return
        
        // 获取应用级上下文，避免内存泄漏
        val appContext = context.applicationContext
        
        // 初始化日志系统并记录广播接收
        try {
            VpnFileLogger.init(appContext)
            VpnFileLogger.d(TAG, "接收开机广播事件: ${intent.action}")
        } catch (e: Exception) {
            // 日志初始化失败时静默处理，不影响主流程
        }
        
        // 获取异步操作句柄，延长广播生命周期
        val pendingResult = goAsync()
        
        // 创建IO协程作用域处理耗时操作
        val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        
        // 异步执行开机启动处理逻辑
        scope.launch {
            try {
                handleBootCompleted(appContext)
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "开机启动处理异常", e)
            } finally {
                // 完成异步广播处理
                try {
                    pendingResult.finish()
                } catch (e: Exception) {
                    // 忽略finish异常
                }
                // 取消协程作用域释放资源
                scope.cancel()
            }
        }
    }
    
    /**
     * VPN配置数据结构
     * 缓存所有相关配置参数，减少重复IO操作
     */
    private data class VpnConfig(
        val autoStart: Boolean,         // 是否启用自启动
        val lastConfig: String?,        // 上次保存的VPN配置
        val globalProxy: Boolean,       // 全局代理模式开关
        val enableVirtualDns: Boolean,  // 虚拟DNS功能开关
        val virtualDnsPort: Int         // 虚拟DNS监听端口
    )
    
    /**
     * 一次性加载所有VPN配置
     * 批量读取SharedPreferences，提升性能
     * @param context Android上下文
     * @return VPN配置对象
     */
    private fun loadVpnConfig(context: Context): VpnConfig {
        val prefs = context.getSharedPreferences("vpn_settings", Context.MODE_PRIVATE)
        return VpnConfig(
            autoStart = prefs.getBoolean("auto_start_on_boot", false),
            lastConfig = prefs.getString("last_vpn_config", null),
            globalProxy = prefs.getBoolean("last_global_proxy", false),
            enableVirtualDns = prefs.getBoolean("last_enable_virtual_dns", false),
            virtualDnsPort = prefs.getInt("last_virtual_dns_port", 10853)
        )
    }
    
    /**
     * 处理开机完成后的VPN启动流程
     * 检查配置、权限并重试启动VPN服务
     * @param context Android上下文
     */
    private suspend fun handleBootCompleted(context: Context) {
        // 批量加载VPN配置参数
        val config = loadVpnConfig(context)
        
        // 检查自启动功能是否启用
        if (!config.autoStart) {
            VpnFileLogger.d(TAG, "VPN自启动功能未启用")
            return
        }
        
        // 验证VPN配置文件存在性
        if (config.lastConfig.isNullOrEmpty()) {
            VpnFileLogger.w(TAG, "未找到有效的VPN配置文件")
            return
        }
        
        VpnFileLogger.d(TAG, "开始VPN自启动流程，全局代理: ${config.globalProxy}, 虚拟DNS: ${config.enableVirtualDns}")
        
        // 等待系统完全启动并进入交互状态
        waitForSystemReady(context)
        
        // 检查VPN服务所需权限
        if (!checkVpnPermission(context)) {
            VpnFileLogger.w(TAG, "VPN权限检查失败，无法自动启动")
            sendNotification(context, "VPN自动连接失败", "请手动连接VPN")
            return
        }
        
        // 执行VPN启动重试逻辑
        var retryCount = 0
        var success = false
        
        while (retryCount < MAX_RETRY_COUNT && !success) {
            try {
                if (retryCount > 0) {
                    VpnFileLogger.d(TAG, "VPN启动重试: 第${retryCount + 1}次")
                    delay(RETRY_DELAY)
                }
                
                // 调用VPN服务启动接口
                startVpnService(context, config.lastConfig, config.globalProxy, 
                              config.enableVirtualDns, config.virtualDnsPort)
                
                // 等待服务启动响应
                delay(3000)
                
                // 验证VPN服务运行状态
                success = V2RayVpnService.isServiceRunning()
                
                if (success) {
                    VpnFileLogger.i(TAG, "VPN服务启动成功")
                    sendNotification(context, "VPN已连接", "自动连接成功")
                }
                
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "VPN启动失败: 第${retryCount + 1}次", e)
            }
            
            retryCount++
        }
        
        // 处理所有重试失败的情况
        if (!success) {
            VpnFileLogger.e(TAG, "VPN自启动最终失败，已重试次数：$MAX_RETRY_COUNT")
            sendNotification(context, "VPN自动连接失败", "请手动连接")
        }
    }
    
    /**
     * 等待系统完全启动并进入交互状态
     * 使用指数退避算法检查设备交互状态
     * @param context Android上下文
     */
    private suspend fun waitForSystemReady(context: Context) {
        VpnFileLogger.d(TAG, "等待系统启动完成")
        
        // 初始固定延迟，确保基础系统服务可用
        delay(INITIAL_DELAY)
        
        // 检查设备是否进入交互状态
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (powerManager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            var waitTime = 0L
            var checkInterval = 1000L
            
            // 使用指数退避检查交互状态，最大等待30秒
            while (!powerManager.isInteractive && waitTime < 30000) {
                delay(checkInterval)
                waitTime += checkInterval
                checkInterval = minOf(checkInterval * 2, 4000L)  // 最大间隔4秒
                VpnFileLogger.d(TAG, "等待设备交互状态: ${waitTime}ms")
            }
        }
        
        VpnFileLogger.d(TAG, "系统启动完成，可以启动VPN")
    }
    
    /**
     * 检查VPN服务权限状态
     * 验证应用是否具备创建VPN连接的权限
     * @param context Android上下文
     * @return 权限检查结果
     */
    private fun checkVpnPermission(context: Context): Boolean {
        return try {
            VpnService.prepare(context) == null
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "VPN权限检查发生异常", e)
            false
        }
    }
    
    /**
     * 启动VPN服务并传递配置参数
     * 调用V2RayVpnService启动接口
     * @param context Android上下文
     * @param config VPN配置字符串
     * @param globalProxy 全局代理开关
     * @param enableVirtualDns 虚拟DNS开关
     * @param virtualDnsPort 虚拟DNS端口
     */
    private fun startVpnService(
        context: Context, 
        config: String, 
        globalProxy: Boolean,
        enableVirtualDns: Boolean,
        virtualDnsPort: Int
    ) {
        try {
            // 调用VPN服务启动接口，传递完整配置
            V2RayVpnService.startVpnService(
                context = context,
                config = config,
                globalProxy = globalProxy,
                blockedApps = null,                                             // 自启动不使用应用屏蔽
                allowedApps = null,                                             // 使用默认应用白名单
                appProxyMode = V2RayVpnService.Companion.AppProxyMode.EXCLUDE, // 排除模式
                bypassSubnets = null,                                           // 使用默认绕过子网
                enableAutoStats = false,                                        // 自启动禁用流量统计
                disconnectButtonName = "停止",
                localizedStrings = emptyMap(),                                  // 使用默认本地化文本
                enableVirtualDns = enableVirtualDns,                            // 传递虚拟DNS配置
                virtualDnsPort = virtualDnsPort                                 // 传递虚拟DNS端口
            )
            
            VpnFileLogger.d(TAG, "VPN服务启动命令已发送，虚拟DNS状态: $enableVirtualDns")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "VPN服务启动命令发送失败", e)
            throw e
        }
    }
    
    /**
     * 发送系统通知提示用户
     * 检查通知权限后发送状态通知
     * @param context Android上下文
     * @param title 通知标题
     * @param message 通知内容
     */
    private fun sendNotification(context: Context, title: String, message: String) {
        try {
            // Android 13+需要检查通知权限
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val permission = context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                if (permission != PackageManager.PERMISSION_GRANTED) return
            }
            
            VpnFileLogger.i(TAG, "发送系统通知: $title - $message")
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "系统通知发送失败", e)
        }
    }
}

/**
 * VPN自启动配置管理器
 * 管理开机自启动相关配置的保存和读取
 */
object AutoStartManager {
    
    private const val TAG = "AutoStartManager"
    private const val PREFS_NAME = "vpn_settings"  // SharedPreferences文件名
    
    /**
     * 保存VPN自启动配置参数
     * 包含完整的VPN配置和虚拟DNS设置
     * @param context Android上下文
     * @param config VPN配置字符串
     * @param mode 兼容性参数(已废弃)
     * @param globalProxy 全局代理开关
     * @param enableVirtualDns 虚拟DNS开关
     * @param virtualDnsPort 虚拟DNS端口
     */
    @JvmStatic
    fun saveAutoStartConfig(
        context: Context, 
        config: String, 
        mode: String,  // 保留兼容性参数
        globalProxy: Boolean,
        enableVirtualDns: Boolean = false,
        virtualDnsPort: Int = 10853
    ) {
        try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().apply {
                putString("last_vpn_config", config)
                putString("last_mode", mode)                                    // 向后兼容保留
                putBoolean("last_global_proxy", globalProxy)
                putBoolean("last_enable_virtual_dns", enableVirtualDns)
                putInt("last_virtual_dns_port", virtualDnsPort)
                putLong("last_save_time", System.currentTimeMillis())          // 记录保存时间
                apply()
            }
            VpnFileLogger.d(TAG, "保存自启动配置: 全局代理=$globalProxy, 虚拟DNS=$enableVirtualDns")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "保存自启动配置失败", e)
        }
    }
    
    /**
     * 保存VPN自启动配置(向后兼容重载)
     */
    @JvmStatic
    fun saveAutoStartConfig(context: Context, config: String, mode: String, globalProxy: Boolean) {
        saveAutoStartConfig(context, config, mode, globalProxy, false, 10853)
    }
    
    /**
     * 设置开机自启动功能开关
     * 同时控制SharedPreferences配置和广播接收器状态
     * @param context Android上下文
     * @param enabled 启用状态
     */
    @JvmStatic
    fun setAutoStartEnabled(context: Context, enabled: Boolean) {
        try {
            // 保存自启动开关状态到SharedPreferences
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit().putBoolean("auto_start_on_boot", enabled).apply()
            
            // 动态启用或禁用BootReceiver组件
            val receiver = android.content.ComponentName(context, BootReceiver::class.java)
            val pm = context.packageManager
            val newState = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            
            pm.setComponentEnabledSetting(receiver, newState, PackageManager.DONT_KILL_APP)
            VpnFileLogger.d(TAG, "BootReceiver组件状态: ${if (enabled) "启用" else "禁用"}")
            VpnFileLogger.i(TAG, "开机自启动功能: ${if (enabled) "启用" else "禁用"}")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "设置自启动状态失败", e)
            throw e
        }
    }
    
    /**
     * 检查自启动功能是否启用
     * 同时检查配置开关和组件状态
     * @param context Android上下文
     * @return 自启动状态
     */
    @JvmStatic
    fun isAutoStartEnabled(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("auto_start_on_boot", false)
            val pm = context.packageManager
            val receiver = android.content.ComponentName(context, BootReceiver::class.java)
            val componentState = pm.getComponentEnabledSetting(receiver)
            // 两个条件都满足才认为自启动启用
            enabled && componentState == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "检查自启动状态异常", e)
            false
        }
    }
    
    /**
     * 清除所有自启动配置数据
     * 从SharedPreferences中移除相关配置
     * @param context Android上下文
     */
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
            VpnFileLogger.d(TAG, "自启动配置已清除")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "清除自启动配置失败", e)
        }
    }
    
    /**
     * 获取配置最后保存时间
     * 用于检查配置的新旧程度
     * @param context Android上下文
     * @return 时间戳(毫秒)
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
    
    /**
     * 获取上次保存的虚拟DNS配置
     * 返回虚拟DNS的启用状态和端口号
     * @param context Android上下文
     * @return 虚拟DNS配置对(启用状态, 端口号)
     */
    @JvmStatic
    fun getLastVirtualDnsConfig(context: Context): Pair<Boolean, Int> {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val enabled = prefs.getBoolean("last_enable_virtual_dns", false)
            val port = prefs.getInt("last_virtual_dns_port", 10853)
            Pair(enabled, port)
        } catch (e: Exception) {
            Pair(false, 10853)  // 返回默认配置
        }
    }

}
