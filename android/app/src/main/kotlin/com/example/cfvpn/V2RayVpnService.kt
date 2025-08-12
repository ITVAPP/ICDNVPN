package com.example.cfvpn;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import androidx.core.app.NotificationCompat;
import kotlinx.coroutines.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileDescriptor;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URL;
import java.lang.ref.WeakReference;
import go.Seq;
import libv2ray.Libv2ray;
import libv2ray.CoreController;
import libv2ray.CoreCallbackHandler;

// 实现V2Ray VPN服务，提供全局或局部代理功能
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    // 定义连接模式枚举
    enum class ConnectionMode {
        VPN_TUN,        // 使用VPN隧道进行全局代理
        PROXY_ONLY      // 仅使用代理，不创建VPN
    }
    
    // 定义连接状态枚举
    enum class V2RayState {
        DISCONNECTED,   // 服务未连接
        CONNECTING,     // 服务连接中
        CONNECTED       // 服务已连接
    }
    
    // 定义应用代理模式枚举
    enum class AppProxyMode {
        EXCLUDE,        // 排除指定应用不走代理
        INCLUDE         // 仅允许指定应用走代理
    }
    
    companion object {
        private const val TAG = "V2RayVpnService"; // 日志标签
        private const val NOTIFICATION_ID = 1; // 通知ID
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"; // 通知渠道ID
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"; // 停止VPN的广播动作
        private const val ACTION_VPN_START_RESULT = "com.example.cfvpn.VPN_START_RESULT"; // VPN启动结果广播动作
        private const val ACTION_VPN_STOPPED = "com.example.cfvpn.VPN_STOPPED"; // VPN停止广播动作
        private const val VPN_MTU = 1500; // VPN最大传输单元
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"; // VPN接口IPv4地址
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"; // tun2socks使用的IPv4地址
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"; // VPN接口IPv6地址
        private const val DEFAULT_SOCKS_PORT = 7898; // 默认SOCKS5端口
        private const val DEFAULT_HTTP_PORT = 7899; // 默认HTTP端口
        private const val STATS_UPDATE_INTERVAL = 10000L; // 流量统计更新间隔（10秒）
        private const val ENABLE_AUTO_STATS = true; // 默认启用自动流量统计
        private const val MAX_TUN2SOCKS_RESTART_COUNT = 3; // tun2socks最大重启次数
        private const val TUN2SOCKS_RESTART_RESET_INTERVAL = 60000L; // 重启计数重置间隔（1分钟）
        
        @Volatile
        private var currentState: V2RayState = V2RayState.DISCONNECTED; // 当前服务状态
        @Volatile
        private var instanceRef: WeakReference<V2RayVpnService>? = null; // 服务实例弱引用
        private var notificationDisconnectButtonName = "停止"; // 通知断开按钮文本
        private var localizedStrings = mutableMapOf<String, String>(); // 国际化文本存储
        
        // 检查服务是否运行
        @JvmStatic
        fun isServiceRunning(): Boolean = currentState == V2RayState.CONNECTED;
        
        // 启动VPN服务
        @JvmStatic
        fun startVpnService(
            context: Context, 
            config: String,
            mode: ConnectionMode = ConnectionMode.VPN_TUN,
            globalProxy: Boolean = false,
            blockedApps: List<String>? = null,
            allowedApps: List<String>? = null,
            appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE,
            bypassSubnets: List<String>? = null,
            enableAutoStats: Boolean = ENABLE_AUTO_STATS,
            disconnectButtonName: String = "停止",
            localizedStrings: Map<String, String> = emptyMap()
        ) {
            
            VpnFileLogger.d(TAG, "准备启动服务,模式: $mode, 全局代理: $globalProxy, 自动统计: $enableAutoStats");
            
            notificationDisconnectButtonName = disconnectButtonName;
            this.localizedStrings.clear();
            this.localizedStrings.putAll(localizedStrings);
            
            // 创建启动意图
            val intent = Intent(context, V2RayVpnService::class.java).apply {
                action = "START_VPN";
                putExtra("config", config);
                putExtra("mode", mode.name);
                putExtra("globalProxy", globalProxy);
                putExtra("enableAutoStats", enableAutoStats);
                putExtra("appProxyMode", appProxyMode.name);
                putStringArrayListExtra("blockedApps", ArrayList(blockedApps ?: emptyList()));
                putStringArrayListExtra("allowedApps", ArrayList(allowedApps ?: emptyList()));
                putStringArrayListExtra("bypassSubnets", ArrayList(bypassSubnets ?: emptyList()));
                putExtra("disconnectButtonName", disconnectButtonName);
                localizedStrings.forEach { (key, value) -> putExtra("l10n_$key", value) };
            };
            
            // 启动前台服务或普通服务
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent);
                } else {
                    context.startService(intent);
                }
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "启动服务失败", e);
            }
        }
        
        // 停止VPN服务
        @JvmStatic
        fun stopVpnService(context: Context) {
            
            VpnFileLogger.d(TAG, "准备停止VPN服务");
            
            try {
                context.sendBroadcast(Intent(ACTION_STOP_VPN));
                context.stopService(Intent(context, V2RayVpnService::class.java));
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "停止服务失败", e);
            }
        }
        
        // 获取当前流量统计
        @JvmStatic
        fun getTrafficStats(): Map<String, Long> {
            instance?.updateTrafficStatsOnDemand();
            return instance?.getCurrentTrafficStats() ?: mapOf(
                "uploadTotal" to 0L,
                "downloadTotal" to 0L,
                "uploadSpeed" to 0L,
                "downloadSpeed" to 0L
            );
        }
        
        // 测试已连接服务器延迟
        @JvmStatic
        suspend fun testConnectedDelay(testUrl: String = "https://www.google.com/generate_204"): Long {
            return instance?.measureConnectedDelay(testUrl) ?: -1L;
        }
        
        // 测试未连接状态下服务器延迟
        @JvmStatic
        suspend fun testServerDelay(config: String, testUrl: String = "https://www.google.com/generate_204"): Long {
            return withContext(Dispatchers.IO) {
                try {
                    // 修改配置移除路由规则
                    val testConfig = try {
                        val configJson = JSONObject(config);
                        if (configJson.has("routing")) {
                            val routing = configJson.getJSONObject("routing");
                            routing.remove("rules");
                            configJson.put("routing", routing);
                        }
                        configJson.toString();
                    } catch (e: Exception) {
                        
                        VpnFileLogger.w(TAG, "修改测试配置失败,使用原始配置", e);
                        config;
                    };
                    
                    // 调用libv2ray测延迟
                    try {
                        val delay = Libv2ray.measureOutboundDelay(testConfig, testUrl);
                        // 记录延迟测试结果
                        VpnFileLogger.d(TAG, "服务器延迟测试结果: ${delay}ms");
                        delay;
                    } catch (e: Exception) {
                        
                        VpnFileLogger.e(TAG, "measureOutboundDelay调用失败", e);
                        -1L;
                    }
                } catch (e: Exception) {
                    
                    VpnFileLogger.e(TAG, "测试服务器延迟失败", e);
                    -1L;
                }
            };
        }
    }
    
    // 定义V2Ray配置数据类
    private data class V2rayConfig(
        val originalConfig: String, // 原始配置内容
        val enhancedConfig: String, // 增强后的配置内容
        val serverAddress: String, // 服务器地址
        val serverPort: Int, // 服务器端口
        val localSocks5Port: Int, // 本地SOCKS5端口
        val localHttpPort: Int, // 本地HTTP端口
        val enableTrafficStats: Boolean, // 是否启用流量统计
        val dnsServers: List<String>, // DNS服务器列表
        val remark: String = "CFVPN" // 配置备注
    );
    
    private var coreController: CoreController? = null; // V2Ray核心控制器
    private var mInterface: ParcelFileDescriptor? = null; // VPN接口文件描述符
    private var tun2socksProcess: java.lang.Process? = null; // tun2socks进程
    private var tun2socksRestartCount = 0; // tun2socks重启计数
    private var tun2socksFirstRestartTime = 0L; // tun2socks首次重启时间
    private var v2rayConfig: V2rayConfig? = null; // V2Ray配置
    private var mode: ConnectionMode = ConnectionMode.VPN_TUN; // 当前连接模式
    private var globalProxy: Boolean = false; // 是否全局代理
    private var blockedApps: List<String> = emptyList(); // 排除代理的应用列表
    private var allowedApps: List<String> = emptyList(); // 允许代理的应用列表
    private var appProxyMode: AppProxyMode = AppProxyMode.EXCLUDE; // 应用代理模式
    private var bypassSubnets: List<String> = emptyList(); // 绕过代理的子网列表
    private var enableAutoStats: Boolean = ENABLE_AUTO_STATS; // 是否启用自动流量统计
    private var disconnectButtonName: String = "停止"; // 断开按钮名称
    private val instanceLocalizedStrings = mutableMapOf<String, String>(); // 实例级国际化文本
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob()); // 协程作用域
    private var uploadBytes: Long = 0; // 总上传字节数
    private var downloadBytes: Long = 0; // 总下载字节数
    private var lastUploadTotal: Long = 0; // 上次上传总量
    private var lastDownloadTotal: Long = 0; // 上次下载总量
    private var uploadSpeed: Long = 0; // 当前上传速度
    private var downloadSpeed: Long = 0; // 当前下载速度
    private var lastQueryTime: Long = 0; // 上次流量查询时间
    private var startTime: Long = 0; // 连接开始时间
    private var lastOnDemandUpdateTime: Long = 0; // 上次按需更新时间
    private var statsJob: Job? = null; // 流量统计协程任务
    
    // 定义广播接收器处理停止VPN请求
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_VPN) {
                
                VpnFileLogger.d(TAG, "收到停止VPN广播");
                stopV2Ray();
            }
        }
    };
    
    // 初始化服务，设置Go运行时和V2Ray环境
    override fun onCreate() {
        super.onCreate();
        
        // 初始化日志系统
        VpnFileLogger.init(applicationContext);
        
        VpnFileLogger.d(TAG, "VPN服务onCreate开始");
        
        // 保存服务实例弱引用
        instanceRef = WeakReference(this);
        
        // 初始化Go运行时
        try {
            Seq.setContext(applicationContext);
            
            VpnFileLogger.d(TAG, "Go运行时初始化成功");
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "Go运行时初始化失败", e);
            stopSelf();
            return;
        }
        
        // 注册广播接收器
        try {
            registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN));
            
            VpnFileLogger.d(TAG, "广播接收器注册成功");
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "注册广播接收器失败", e);
        }
        
        // 初始化V2Ray环境
        try {
            val envPath = filesDir.absolutePath;
            Libv2ray.initCoreEnv(envPath, "");
            
            VpnFileLogger.d(TAG, "V2Ray环境初始化成功: $envPath");
            
            // 获取并记录V2Ray版本
            val version = Libv2ray.checkVersionX();
            VpnFileLogger.i(TAG, "V2Ray版本: $version");
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "V2Ray环境初始化失败", e);
        }
        
        // 复制资源文件
        copyAssetFiles();
        
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成");
    }
    
    // 处理服务启动命令
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        
        VpnFileLogger.d(TAG, "onStartCommand: action=${intent?.action}");
        
        // 验证启动意图
        if (intent == null || intent.action != "START_VPN") {
            
            VpnFileLogger.w(TAG, "无效的启动意图");
            stopSelf();
            return START_NOT_STICKY;
        }
        
        // 检查服务是否已运行
        if (currentState == V2RayState.CONNECTED) {
            
            VpnFileLogger.w(TAG, "VPN服务已在运行");
            return START_STICKY;
        }
        
        // 更新服务状态为连接中
        currentState = V2RayState.CONNECTING;
        
        // 获取配置参数
        val configContent = intent.getStringExtra("config") ?: "";
        mode = try {
            ConnectionMode.valueOf(intent.getStringExtra("mode") ?: ConnectionMode.VPN_TUN.name);
        } catch (e: Exception) {
            ConnectionMode.VPN_TUN;
        };
        globalProxy = intent.getBooleanExtra("globalProxy", false);
        enableAutoStats = intent.getBooleanExtra("enableAutoStats", ENABLE_AUTO_STATS);
        appProxyMode = try {
            AppProxyMode.valueOf(intent.getStringExtra("appProxyMode") ?: AppProxyMode.EXCLUDE.name);
        } catch (e: Exception) {
            AppProxyMode.EXCLUDE;
        };
        blockedApps = intent.getStringArrayListExtra("blockedApps") ?: emptyList();
        allowedApps = intent.getStringArrayListExtra("allowedApps") ?: emptyList();
        bypassSubnets = intent.getStringArrayListExtra("bypassSubnets") ?: emptyList();
        disconnectButtonName = intent.getStringExtra("disconnectButtonName") ?: "停止";
        
        // 提取国际化文本
        instanceLocalizedStrings.clear();
        instanceLocalizedStrings["appName"] = intent.getStringExtra("l10n_appName") ?: "CFVPN";
        instanceLocalizedStrings["notificationChannelName"] = intent.getStringExtra("l10n_notificationChannelName") ?: "VPN服务";
        instanceLocalizedStrings["notificationChannelDesc"] = intent.getStringExtra("l10n_notificationChannelDesc") ?: "VPN连接状态通知";
        instanceLocalizedStrings["globalProxyMode"] = intent.getStringExtra("l10n_globalProxyMode") ?: "全局代理模式";
        instanceLocalizedStrings["smartProxyMode"] = intent.getStringExtra("l10n_smartProxyMode") ?: "智能代理模式";
        instanceLocalizedStrings["proxyOnlyMode"] = intent.getStringExtra("l10n_proxyOnlyMode") ?: "仅代理模式";
        instanceLocalizedStrings["disconnectButtonName"] = intent.getStringExtra("l10n_disconnectButtonName") ?: "断开";
        instanceLocalizedStrings["trafficStatsFormat"] = intent.getStringExtra("l10n_trafficStatsFormat") ?: "流量: ↑%upload ↓%download";
        
        // 验证配置内容
        if (configContent.isEmpty()) {
            
            VpnFileLogger.e(TAG, "配置为空");
            currentState = V2RayState.DISCONNECTED;
            sendStartResultBroadcast(false, "配置为空");
            stopSelf();
            return START_NOT_STICKY;
        }
        
        
        VpnFileLogger.d(TAG, "=====V2Ray完整配置开始=====");
        VpnFileLogger.d(TAG, configContent);
        VpnFileLogger.d(TAG, "=====V2Ray完整配置结束=====");
        VpnFileLogger.d(TAG, "配置参数: 模式=$mode, 全局代理=$globalProxy, " +
                "排除应用=$blockedApps, 包含应用=$allowedApps, " +
                "代理模式=$appProxyMode, 绕过子网=$bypassSubnets");
        
        // 解析并增强配置
        try {
            v2rayConfig = parseAndEnhanceConfig(configContent);
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "解析配置失败", e);
            currentState = V2RayState.DISCONNECTED;
            sendStartResultBroadcast(false, "解析配置失败: ${e.message}");
            stopSelf();
            return START_NOT_STICKY;
        }
        
        // 启动前台服务
        try {
            val notification = createNotification();
            if (notification != null) {
                startForeground(NOTIFICATION_ID, notification);
                
                VpnFileLogger.d(TAG, "前台服务已启动");
            } else {
                
                VpnFileLogger.e(TAG, "无法创建通知,服务可能被系统终止");
                currentState = V2RayState.DISCONNECTED;
                sendStartResultBroadcast(false, "无法创建通知");
                stopSelf();
                return START_NOT_STICKY;
            }
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "启动前台服务失败", e);
            currentState = V2RayState.DISCONNECTED;
            sendStartResultBroadcast(false, "启动前台服务失败: ${e.message}");
            stopSelf();
            return START_NOT_STICKY;
        }
        
        // 根据模式启动服务
        serviceScope.launch {
            try {
                when (mode) {
                    ConnectionMode.VPN_TUN -> startV2RayWithVPN();
                    ConnectionMode.PROXY_ONLY -> startV2RayProxyOnly();
                }
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "启动失败", e);
                currentState = V2RayState.DISCONNECTED;
                sendStartResultBroadcast(false, "启动失败: ${e.message}");
                withContext(Dispatchers.Main) {
                    stopSelf();
                }
            }
        };
        
        return START_STICKY;
    }
    
    // 解析并增强V2Ray配置
    private fun parseAndEnhanceConfig(originalConfig: String): V2rayConfig {
        
        VpnFileLogger.d(TAG, "开始解析和增强配置");
        
        return try {
            val configJson = JSONObject(originalConfig);
            
            // 提取服务器信息
            var serverAddress = "";
            var serverPort = 0;
            try {
                val vnext = configJson.getJSONArray("outbounds")
                    .getJSONObject(0)
                    .getJSONObject("settings")
                    .getJSONArray("vnext")
                    .getJSONObject(0);
                serverAddress = vnext.getString("address");
                serverPort = vnext.getInt("port");
            } catch (e: Exception) {
                try {
                    val servers = configJson.getJSONArray("outbounds")
                        .getJSONObject(0)
                        .getJSONObject("settings")
                        .getJSONArray("servers")
                        .getJSONObject(0);
                    serverAddress = servers.getString("address");
                    serverPort = servers.getInt("port");
                } catch (e2: Exception) {
                    
                    VpnFileLogger.w(TAG, "无法提取服务器信息,使用默认值", e2);
                }
            }
            
            // 提取端口信息
            var socksPort = DEFAULT_SOCKS_PORT;
            var httpPort = DEFAULT_HTTP_PORT;
            try {
                val inbounds = configJson.getJSONArray("inbounds");
                for (i in 0 until inbounds.length()) {
                    val inbound = inbounds.getJSONObject(i);
                    when (inbound.optString("protocol", "")) {
                        "socks" -> socksPort = inbound.optInt("port", DEFAULT_SOCKS_PORT);
                        "http" -> httpPort = inbound.optInt("port", DEFAULT_HTTP_PORT);
                    }
                }
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "提取端口失败,使用默认值", e);
            }
            
            // 提取DNS服务器
            val dnsServers = mutableListOf<String>();
            try {
                val dns = configJson.optJSONObject("dns");
                val serversArray = dns?.optJSONArray("servers");
                if (serversArray != null) {
                    for (i in 0 until serversArray.length()) {
                        when (val server = serversArray.get(i)) {
                            is String -> {
                                if (isValidIpAddress(server)) {
                                    dnsServers.add(server);
                                } else {
                                    
                                    VpnFileLogger.d(TAG, "跳过非IP格式DNS: $server");
                                }
                            }
                            is JSONObject -> {
                                server.optString("address")?.let { addr ->
                                    if (addr.isNotEmpty() && isValidIpAddress(addr)) {
                                        dnsServers.add(addr);
                                    } else if (addr.isNotEmpty()) {
                                        
                                        VpnFileLogger.d(TAG, "跳过非IP格式DNS: $addr");
                                    }
                                };
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "提取DNS失败,使用默认值", e);
            }
            
            // 使用默认DNS服务器
            if (dnsServers.isEmpty()) {
                dnsServers.addAll(listOf("8.8.8.8", "8.8.4.4", "1.1.1.1"));
            }
            
            // 添加流量统计配置
            val enableTrafficStats = true;
            if (enableTrafficStats) {
                try {
                    configJson.remove("policy");
                    configJson.remove("stats");
                    val policy = JSONObject().apply {
                        put("levels", JSONObject().apply {
                            put("8", JSONObject().apply {
                                put("connIdle", 300);
                                put("downlinkOnly", 1);
                                put("handshake", 4);
                                put("uplinkOnly", 1);
                            });
                        });
                        put("system", JSONObject().apply {
                            put("statsOutboundUplink", true);
                            put("statsOutboundDownlink", true);
                        });
                    };
                    configJson.put("policy", policy);
                    configJson.put("stats", JSONObject());
                    
                    VpnFileLogger.d(TAG, "已添加流量统计配置");
                } catch (e: Exception) {
                    
                    VpnFileLogger.w(TAG, "添加流量统计配置失败", e);
                }
            }
            
            // 创建并返回配置对象
            V2rayConfig(
                originalConfig = originalConfig,
                enhancedConfig = configJson.toString(),
                serverAddress = serverAddress,
                serverPort = serverPort,
                localSocks5Port = socksPort,
                localHttpPort = httpPort,
                enableTrafficStats = enableTrafficStats,
                dnsServers = dnsServers,
                remark = instanceLocalizedStrings["appName"] ?: "CFVPN"
            ).also {
                
                VpnFileLogger.i(TAG, "配置解析成功: " +
                    "服务器=$serverAddress:$serverPort, " +
                    "SOCKS5端口=$socksPort, HTTP端口=$httpPort, " +
                    "DNS=${dnsServers.joinToString(",")}, " +
                    "流量统计=${if (enableTrafficStats) "启用" else "禁用"}");
            }
        } catch (e: Exception) {
            并返回默认配置
            VpnFileLogger.e(TAG, "解析配置失败,使用原始配置", e);
            V2rayConfig(
                originalConfig = originalConfig,
                enhancedConfig = originalConfig,
                serverAddress = "",
                serverPort = 0,
                localSocks5Port = DEFAULT_SOCKS_PORT,
                localHttpPort = DEFAULT_HTTP_PORT,
                enableTrafficStats = false,
                dnsServers = listOf("8.8.8.8", "8.8.4.4"),
                remark = instanceLocalizedStrings["appName"] ?: "CFVPN"
            );
        }
    }
    
    // 验证IP地址格式
    private fun isValidIpAddress(address: String): Boolean {
        if (address.startsWith("http://") || address.startsWith("https://") || 
            address.startsWith("tcp://") || address.startsWith("udp://") ||
            address.contains("://")) {
            return false;
        }
        if (address.matches(Regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"))) {
            return true;
        }
        if (address.contains(":") && !address.contains("://") && !address.contains("/")) {
            return true;
        }
        return false;
    }
    
    // 复制资源文件到应用目录
    private fun copyAssetFiles() {
        
        VpnFileLogger.d(TAG, "开始复制资源文件");
        
        val assetDir = filesDir;
        if (!assetDir.exists()) {
            if (!assetDir.mkdirs()) {
                
                VpnFileLogger.e(TAG, "创建资源目录失败");
                return;
            }
        }
        
        // 定义需要复制的资源文件列表
        val files = listOf("geoip.dat", "geoip-only-cn-private.dat", "geosite.dat");
        
        for (fileName in files) {
            try {
                val targetFile = File(assetDir, fileName);
                if (shouldUpdateFile(fileName, targetFile)) {
                    copyAssetFile(fileName, targetFile);
                } else {
                    
                    VpnFileLogger.d(TAG, "文件已是最新,跳过: $fileName");
                }
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "处理文件失败: $fileName", e);
            }
        }
        
        
        VpnFileLogger.d(TAG, "资源文件复制完成");
    }
    
    // 检查是否需要更新文件
    private fun shouldUpdateFile(assetName: String, targetFile: File): Boolean {
        if (!targetFile.exists()) {
            return true;
        }
        return try {
            val assetSize = assets.open(assetName).use { it.available() };
            targetFile.length() != assetSize.toLong();
        } catch (e: Exception) {
            true;
        }
    }
    
    // 复制单个资源文件
    private fun copyAssetFile(assetName: String, targetFile: File) {
        try {
            
            VpnFileLogger.d(TAG, "正在复制文件: $assetName");
            assets.open(assetName).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output);
                }
            }
            
            VpnFileLogger.d(TAG, "文件复制成功: $assetName (${targetFile.length()} bytes)");
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "复制文件失败: $assetName", e);
        }
    }
    
    // 启动V2Ray服务（VPN模式）
    private suspend fun startV2RayWithVPN() = withContext(Dispatchers.IO) {
        
        VpnFileLogger.d(TAG, "开始启动V2Ray(VPN模式)");
        
        val config = v2rayConfig ?: throw Exception("配置为空");
        
        try {
            // 建立VPN隧道
            VpnFileLogger.d(TAG, "步骤1: 建立VPN隧道");
            withContext(Dispatchers.Main) {
                establishVpn();
            }
            
            if (mInterface == null) {
                throw Exception("VPN隧道建立失败");
            }
            
            // 创建V2Ray核心控制器
            VpnFileLogger.d(TAG, "步骤2: 创建核心控制器");
            coreController = Libv2ray.newCoreController(this@V2RayVpnService);
            
            if (coreController == null) {
                throw Exception("创建CoreController失败");
            }
            
            // 启动V2Ray核心
            VpnFileLogger.d(TAG, "步骤3: 启动V2Ray核心");
            coreController?.startLoop(config.enhancedConfig);
            
            // 验证核心运行状态
            val isRunningNow = coreController?.isRunning ?: false;
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行");
            }
            
            
            VpnFileLogger.i(TAG, "V2Ray核心启动成功,SOCKS5端口: ${config.localSocks5Port}");
            
            // 启动tun2socks进程
            VpnFileLogger.d(TAG, "步骤5: 启动tun2socks进程");
            runTun2socks();
            
            // 传递文件描述符
            VpnFileLogger.d(TAG, "步骤6: 传递文件描述符");
            val fdSuccess = sendFileDescriptor();
            if (!fdSuccess) {
                throw Exception("文件描述符传递失败");
            }
            
            // 更新服务状态
            currentState = V2RayState.CONNECTED;
            startTime = System.currentTimeMillis();
            
            
            VpnFileLogger.i(TAG, "V2Ray服务(VPN模式)完全启动成功");
            
            // 发送启动成功广播
            sendStartResultBroadcast(true);
            
            // 保存自启动配置
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        config.originalConfig,
                        mode.name,
                        globalProxy
                    );
                    
                    VpnFileLogger.d(TAG, "已更新自启动配置");
                }
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "保存自启动配置失败", e);
            }
            
            // 启动流量监控
            if (enableAutoStats) {
                
                VpnFileLogger.d(TAG, "启动自动流量统计");
                startTrafficMonitor();
            }
            
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "启动V2Ray(VPN模式)失败: ${e.message}", e);
            cleanupResources();
            sendStartResultBroadcast(false, e.message);
            throw e;
        }
    }
    
    // 启动V2Ray服务（仅代理模式）
    private suspend fun startV2RayProxyOnly() = withContext(Dispatchers.IO) {
        
        VpnFileLogger.d(TAG, "开始启动V2Ray(仅代理模式)");
        
        val config = v2rayConfig ?: throw Exception("配置为空");
        
        try {
            // 创建核心控制器
            VpnFileLogger.d(TAG, "步骤1: 创建核心控制器");
            coreController = Libv2ray.newCoreController(this@V2RayVpnService);
            
            if (coreController == null) {
                throw Exception("创建CoreController失败");
            }
            
            // 启动V2Ray核心
            VpnFileLogger.d(TAG, "步骤2: 启动V2Ray核心");
            coreController?.startLoop(config.enhancedConfig);
            
            // 验证核心运行状态
            val isRunningNow = coreController?.isRunning ?: false;
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行");
            }
            
            // 更新服务状态
            currentState = V2RayState.CONNECTED;
            startTime = System.currentTimeMillis();
            
            
            VpnFileLogger.i(TAG, "V2Ray服务(仅代理模式)启动成功");
            VpnFileLogger.i(TAG, "SOCKS5: 127.0.0.1:${config.localSocks5Port}");
            VpnFileLogger.i(TAG, "HTTP: 127.0.0.1:${config.localHttpPort}");
            
            // 发送启动成功广播
            sendStartResultBroadcast(true);
            
            // 保存自启动配置
            try {
                if (AutoStartManager.isAutoStartEnabled(this@V2RayVpnService)) {
                    AutoStartManager.saveAutoStartConfig(
                        this@V2RayVpnService,
                        config.originalConfig,
                        mode.name,
                        globalProxy
                    );
                    
                    VpnFileLogger.d(TAG, "已更新自启动配置");
                }
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "保存自启动配置失败", e);
            }
            
            // 启动流量监控
            if (enableAutoStats) {
                
                VpnFileLogger.d(TAG, "启动自动流量统计");
                startTrafficMonitor();
            }
            
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "启动V2Ray(仅代理模式)失败: ${e.message}", e);
            cleanupResources();
            sendStartResultBroadcast(false, e.message);
            throw e;
        }
    }
    
    // 发送VPN启动结果广播
    private fun sendStartResultBroadcast(success: Boolean, error: String? = null) {
        try {
            val intent = Intent(ACTION_VPN_START_RESULT).apply {
                putExtra("success", success);
                putExtra("error", error);
            };
            sendBroadcast(intent);
            
            VpnFileLogger.d(TAG, "已发送VPN启动结果广播: success=$success, error=$error");
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "发送启动结果广播失败", e);
        }
    }
    
    // 清理服务资源
    private fun cleanupResources() {
        currentState = V2RayState.DISCONNECTED;
        stopTun2socks();
        mInterface?.close();
        mInterface = null;
        try {
            coreController?.stopLoop();
        } catch (e: Exception) {
            
            VpnFileLogger.w(TAG, "停止核心异常", e);
        }
        coreController = null;
    }
    
    // 启动V2Ray核心（兼容旧方法）
    private suspend fun startV2Ray() = startV2RayWithVPN();
    
    // 建立VPN隧道，支持分应用代理和子网绕过
    private fun establishVpn() {
        
        VpnFileLogger.d(TAG, "开始建立VPN隧道");
        
        val config = v2rayConfig ?: return;
        
        // 关闭旧VPN接口
        mInterface?.let {
            try {
                it.close();
                
                VpnFileLogger.d(TAG, "已关闭旧VPN接口");
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "关闭旧接口失败", e);
            }
        };
        mInterface = null;
        
        // 创建VPN构建器
        val builder = Builder();
        
        // 设置VPN基本配置
        builder.setSession(config.remark);
        builder.setMtu(VPN_MTU);
        
        // 添加IPv4地址
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30);
        
        VpnFileLogger.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30");
        
        // 添加IPv6地址
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126);
                
                VpnFileLogger.d(TAG, "添加IPv6地址: $PRIVATE_VLAN6_CLIENT/126");
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "添加IPv6地址失败", e);
            }
        }
        
        // 配置DNS服务器
        config.dnsServers.forEach { dns ->
            try {
                if (isValidIpAddress(dns)) {
                    builder.addDnsServer(dns);
                    
                    VpnFileLogger.d(TAG, "添加DNS: $dns");
                } else {
                    
                    VpnFileLogger.d(TAG, "跳过非IP格式DNS: $dns");
                }
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "添加DNS失败: $dns", e);
            }
        };
        
        // 配置路由规则
        if (bypassSubnets.isNotEmpty()) {
            
            VpnFileLogger.d(TAG, "配置子网绕过: $bypassSubnets");
            bypassSubnets.forEach { subnet ->
                try {
                    val parts = subnet.split("/");
                    if (parts.size == 2) {
                        val address = parts[0];
                        val prefixLength = parts[1].toInt();
                        builder.addRoute(address, prefixLength);
                        
                        VpnFileLogger.d(TAG, "添加路由: $address/$prefixLength");
                    }
                } catch (e: Exception) {
                    
                    VpnFileLogger.w(TAG, "添加路由失败: $subnet", e);
                }
            };
        } else {
            if (globalProxy) {
                
                VpnFileLogger.d(TAG, "配置全局代理路由");
                builder.addRoute("0.0.0.0", 0);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    try {
                        builder.addRoute("::", 0);
                        
                        VpnFileLogger.d(TAG, "添加IPv6全局路由");
                    } catch (e: Exception) {
                        
                        VpnFileLogger.w(TAG, "添加IPv6路由失败", e);
                    }
                }
            } else {
                builder.addRoute("0.0.0.0", 0);
            }
        }
        
        // 配置分应用代理
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            when (appProxyMode) {
                AppProxyMode.EXCLUDE -> {
                    
                    VpnFileLogger.d(TAG, "使用排除模式,用户指定排除${blockedApps.size}个应用");
                    try {
                        builder.addDisallowedApplication(packageName);
                        
                        VpnFileLogger.d(TAG, "自动排除自身应用(防止VPN循环): $packageName");
                    } catch (e: Exception) {
                        
                        VpnFileLogger.w(TAG, "排除自身应用失败", e);
                    }
                    blockedApps.forEach { app ->
                        try {
                            builder.addDisallowedApplication(app);
                            
                            VpnFileLogger.d(TAG, "排除应用: $app");
                        } catch (e: Exception) {
                            
                            VpnFileLogger.w(TAG, "排除应用失败: $app", e);
                        }
                    };
                }
                AppProxyMode.INCLUDE -> {
                    if (allowedApps.isNotEmpty()) {
                        
                        VpnFileLogger.d(TAG, "使用包含模式,包含${allowedApps.size}个应用");
                        allowedApps.forEach { app ->
                            try {
                                builder.addAllowedApplication(app);
                                
                                VpnFileLogger.d(TAG, "包含应用: $app");
                            } catch (e: Exception) {
                                
                                VpnFileLogger.w(TAG, "包含应用失败: $app", e);
                            }
                        };
                    } else {
                        
                        VpnFileLogger.e(TAG, "包含模式但未指定任何应用,VPN将不会路由任何流量!");
                    }
                }
            }
        }
        
        // 建立VPN接口
        mInterface = builder.establish();
        
        if (mInterface == null) {
            
            VpnFileLogger.e(TAG, "VPN接口建立失败(可能没有权限)");
        } else {
            
            VpnFileLogger.d(TAG, "VPN隧道建立成功,FD: ${mInterface?.fd}");
        }
    }
    
    // 启动tun2socks进程（仅VPN模式）
    private suspend fun runTun2socks(): Unit = withContext(Dispatchers.IO) {
        if (mode != ConnectionMode.VPN_TUN) {
            
            VpnFileLogger.d(TAG, "非VPN模式,跳过tun2socks");
            return@withContext;
        }
        
        
        VpnFileLogger.d(TAG, "开始启动tun2socks进程");
        
        val config = v2rayConfig ?: throw Exception("配置为空");
        
        try {
            val libtun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath;
            if (!File(libtun2socksPath).exists()) {
                throw Exception("libtun2socks.so不存在: $libtun2socksPath");
            }
            
            val sockPath = File(filesDir, "sock_path").absolutePath;
            File(sockPath).delete();
            
            // 构建tun2socks命令
            val cmd = arrayListOf(
                libtun2socksPath,
                "--netif-ipaddr", PRIVATE_VLAN4_ROUTER,
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:${config.localSocks5Port}",
                "--tunmtu", VPN_MTU.toString(),
                "--sock-path", sockPath,
                "--enable-udprelay",
                "--loglevel", "error"
            );
            
            
            VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}");
            
            // 启动tun2socks进程
            val processBuilder = ProcessBuilder(cmd).apply {
                redirectErrorStream(true);
                directory(filesDir);
            };
            
            val process = processBuilder.start();
            tun2socksProcess = process;
            
            // 读取tun2socks输出
            serviceScope.launch {
                try {
                    process.inputStream?.bufferedReader()?.use { reader ->
                        var line: String?;
                        while (reader.readLine().also { line = it } != null) {
                            if (!line.isNullOrBlank()) {
                                
                                VpnFileLogger.d(TAG, "tun2socks: $line");
                            }
                        }
                    }
                } catch (e: Exception) {
                    if (currentState != V2RayState.DISCONNECTED && tun2socksProcess?.isAlive == true) {
                        
                        VpnFileLogger.w(TAG, "读取tun2socks输出失败", e);
                    }
                }
            };
            
            // 监控tun2socks进程状态
            serviceScope.launch {
                try {
                    val exitCode = process.waitFor();
                    if (currentState == V2RayState.DISCONNECTED) {
                        
                        VpnFileLogger.d(TAG, "tun2socks进程正常退出,退出码: $exitCode");
                    } else {
                        
                        VpnFileLogger.w(TAG, "tun2socks进程异常退出,退出码: $exitCode");
                        if (mode == ConnectionMode.VPN_TUN && shouldRestartTun2socks()) {
                            
                            VpnFileLogger.d(TAG, "自动重启tun2socks进程 (第${tun2socksRestartCount + 1}次)");
                            delay(1000);
                            restartTun2socks();
                        } else if (tun2socksRestartCount >= MAX_TUN2SOCKS_RESTART_COUNT) {
                            
                            VpnFileLogger.e(TAG, "tun2socks重启次数已达上限，停止服务");
                            stopV2Ray();
                        }
                    }
                } catch (e: Exception) {
                    if (currentState != V2RayState.DISCONNECTED) {
                        
                        VpnFileLogger.e(TAG, "监控tun2socks进程失败", e);
                    }
                }
            };
            
            // 验证tun2socks启动
            delay(100);
            if (!process.isAlive) {
                throw Exception("tun2socks进程启动后立即退出");
            }
            
            
            VpnFileLogger.d(TAG, "tun2socks进程已启动");
            
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "启动tun2socks失败", e);
            throw e;
        }
    }
    
    // 检查是否可重启tun2socks
    private fun shouldRestartTun2socks(): Boolean {
        val now = System.currentTimeMillis();
        if (tun2socksRestartCount == 0) {
            tun2socksFirstRestartTime = now;
        }
        if (now - tun2socksFirstRestartTime > TUN2SOCKS_RESTART_RESET_INTERVAL) {
            tun2socksRestartCount = 0;
            tun2socksFirstRestartTime = now;
            
            VpnFileLogger.d(TAG, "tun2socks重启计数已重置");
        }
        return tun2socksRestartCount < MAX_TUN2SOCKS_RESTART_COUNT;
    }
    
    // 重启tun2socks进程
    private suspend fun restartTun2socks(): Unit = withContext(Dispatchers.IO) {
        try {
            tun2socksRestartCount++;
            runTun2socks();
            val success = sendFileDescriptor();
            if (!success) {
                
                VpnFileLogger.e(TAG, "重启后文件描述符传递失败,停止服务");
                stopV2Ray();
            }
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "重启tun2socks失败", e);
            stopV2Ray();
        }
    }
    
    // 传递文件描述符给tun2socks
    private suspend fun sendFileDescriptor(): Boolean {
        
        VpnFileLogger.d(TAG, "开始传递文件描述符给tun2socks");
        
        return withContext(Dispatchers.IO) {
            val sockPath = File(filesDir, "sock_path").absolutePath;
            val tunFd = mInterface?.fileDescriptor;
            
            if (tunFd == null) {
                
                VpnFileLogger.e(TAG, "TUN文件描述符为空");
                return@withContext false;
            }
            
            var tries = 0;
            val maxTries = 6;
            
            while (tries < maxTries) {
                try {
                    delay(50L * tries);
                    
                    VpnFileLogger.d(TAG, "尝试连接Unix域套接字 (第${tries + 1}次)");
                    
                    val clientSocket = LocalSocket();
                    clientSocket.connect(LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM));
                    
                    val outputStream = clientSocket.outputStream;
                    clientSocket.setFileDescriptorsForSend(arrayOf(tunFd));
                    outputStream.write(32);
                    outputStream.flush();
                    
                    clientSocket.setFileDescriptorsForSend(null);
                    clientSocket.shutdownOutput();
                    clientSocket.close();
                    
                    
                    VpnFileLogger.d(TAG, "文件描述符传递成功");
                    return@withContext true;
                } catch (e: Exception) {
                    tries++;
                    if (tries >= maxTries) {
                        
                        VpnFileLogger.e(TAG, "文件描述符传递失败,已达最大重试次数", e);
                        return@withContext false;
                    } else {
                        
                        VpnFileLogger.w(TAG, "文件描述符传递失败,将重试 (${tries}/$maxTries): ${e.message}");
                    }
                }
            }
            false;
        }
    }
    
    // 停止tun2socks进程
    private fun stopTun2socks() {
        
        VpnFileLogger.d(TAG, "停止tun2socks进程");
        
        tun2socksRestartCount = 0;
        tun2socksFirstRestartTime = 0L;
        
        try {
            val process = tun2socksProcess;
            if (process != null) {
                process.destroy();
                tun2socksProcess = null;
                
                VpnFileLogger.d(TAG, "tun2socks进程已停止");
            }
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "停止tun2socks进程失败", e);
        }
    }
    
    // 启动流量监控
    private fun startTrafficMonitor() {
        
        VpnFileLogger.d(TAG, "启动流量监控,更新间隔: ${STATS_UPDATE_INTERVAL}ms");
        
        statsJob?.cancel();
        statsJob = serviceScope.launch {
            delay(5000);
            while (currentState == V2RayState.CONNECTED && isActive) {
                try {
                    updateTrafficStats();
                } catch (e: Exception) {
                    
                    VpnFileLogger.w(TAG, "更新流量统计异常", e);
                }
                delay(STATS_UPDATE_INTERVAL);
            }
        };
    }
    
    // 按需更新流量统计
    private fun updateTrafficStatsOnDemand() {
        if (currentState != V2RayState.CONNECTED) return;
        
        val now = System.currentTimeMillis();
        if (now - lastOnDemandUpdateTime < 1000) {
            return;
        }
        lastOnDemandUpdateTime = now;
        
        try {
            updateTrafficStats();
        } catch (e: Exception) {
            
            VpnFileLogger.w(TAG, "按需更新流量统计失败", e);
        }
    }
    
    // 更新流量统计数据
    private fun updateTrafficStats() {
        try {
            val controller = coreController ?: return;
            
            // 查询各出站流量
            val proxyUplink = controller.queryStats("outbound>>>proxy>>>traffic>>>uplink", "");
            val proxyDownlink = controller.queryStats("outbound>>>proxy>>>traffic>>>downlink", "");
            val directUplink = controller.queryStats("outbound>>>direct>>>traffic>>>uplink", "");
            val directDownlink = controller.queryStats("outbound>>>direct>>>traffic>>>downlink", "");
            val blockUplink = controller.queryStats("outbound>>>block>>>traffic>>>uplink", "");
            val blockDownlink = controller.queryStats("outbound>>>block>>>traffic>>>downlink", "");
            
            // 合并流量统计
            var currentUpload = proxyUplink + directUplink + blockUplink;
            var currentDownload = proxyDownlink + directDownlink + blockDownlink;
            
            // 查询总流量
            if (proxyUplink == 0L && proxyDownlink == 0L) {
                val totalUplink = controller.queryStats("outbound>>>traffic>>>uplink", "");
                val totalDownlink = controller.queryStats("outbound>>>traffic>>>downlink", "");
                if (totalUplink > 0 || totalDownlink > 0) {
                    currentUpload = totalUplink;
                    currentDownload = totalDownlink;
                }
            }
            
            // 更新流量数据
            uploadBytes = currentUpload;
            downloadBytes = currentDownload;
            
            // 计算当前速度
            val now = System.currentTimeMillis();
            if (lastQueryTime > 0 && now > lastQueryTime) {
                val timeDiff = (now - lastQueryTime) / 1000.0;
                if (timeDiff > 0) {
                    val uploadDiff = uploadBytes - lastUploadTotal;
                    val downloadDiff = downloadBytes - lastDownloadTotal;
                    if (uploadDiff >= 0 && downloadDiff >= 0) {
                        uploadSpeed = (uploadDiff / timeDiff).toLong();
                        downloadSpeed = (downloadDiff / timeDiff).toLong();
                    } else {
                        uploadSpeed = 0;
                        downloadSpeed = 0;
                    }
                }
            }
            
            // 更新查询时间和流量数据
            lastQueryTime = now;
            lastUploadTotal = uploadBytes;
            lastDownloadTotal = downloadBytes;
            
            // 更新通知和广播
            if (enableAutoStats) {
                updateNotification();
                broadcastConnectionInfo();
            }
            
            
            VpnFileLogger.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}, " +
                      "速度: ↑${formatBytes(uploadSpeed)}/s ↓${formatBytes(downloadSpeed)}/s");
            
        } catch (e: Exception) {
            
            VpnFileLogger.w(TAG, "查询流量统计失败", e);
        }
    }
    
    // 广播连接信息
    private fun broadcastConnectionInfo() {
        val intent = Intent("V2RAY_CONNECTION_INFO").apply {
            putExtra("STATE", currentState.name);
            putExtra("MODE", mode.name);
            putExtra("DURATION", formatDuration(System.currentTimeMillis() - startTime));
            putExtra("UPLOAD_SPEED", uploadSpeed);
            putExtra("DOWNLOAD_SPEED", downloadSpeed);
            putExtra("UPLOAD_TRAFFIC", uploadBytes);
            putExtra("DOWNLOAD_TRAFFIC", downloadBytes);
        };
        sendBroadcast(intent);
    }
    
    // 测量已连接服务器延迟
    private suspend fun measureConnectedDelay(testUrl: String): Long = withContext(Dispatchers.IO) {
        return@withContext try {
            val controller = coreController;
            if (controller != null && controller.isRunning) {
                val delay = controller.measureDelay(testUrl);
                
                VpnFileLogger.d(TAG, "服务器延迟: ${delay}ms");
                delay;
            } else {
                -1L;
            }
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "测量延迟失败", e);
            -1L;
        }
    }
    
    // 获取当前流量统计数据
    fun getCurrentTrafficStats(): Map<String, Long> {
        return mapOf(
            "uploadTotal" to uploadBytes,
            "downloadTotal" to downloadBytes,
            "uploadSpeed" to uploadSpeed,
            "downloadSpeed" to downloadSpeed
        );
    }
    
    // 停止V2Ray服务
    private fun stopV2Ray() {
        
        VpnFileLogger.d(TAG, "开始停止V2Ray服务");
        
        currentState = V2RayState.DISCONNECTED;
        statsJob?.cancel();
        statsJob = null;
        
        // 广播断开状态
        val intent = Intent("V2RAY_CONNECTION_INFO").apply {
            putExtra("STATE", "DISCONNECTED");
            putExtra("DURATION", "00:00:00");
            putExtra("UPLOAD_SPEED", 0L);
            putExtra("DOWNLOAD_SPEED", 0L);
            putExtra("UPLOAD_TRAFFIC", 0L);
            putExtra("DOWNLOAD_TRAFFIC", 0L);
        };
        sendBroadcast(intent);
        
        // 发送服务停止广播
        sendBroadcast(Intent(ACTION_VPN_STOPPED));
        
        VpnFileLogger.d(TAG, "已发送VPN停止广播");
        
        // 停止tun2socks进程
        if (mode == ConnectionMode.VPN_TUN) {
            stopTun2socks();
        }
        
        // 停止V2Ray核心
        try {
            coreController?.stopLoop();
            
            VpnFileLogger.d(TAG, "V2Ray核心已停止");
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "停止V2Ray核心异常", e);
        }
        
        // 关闭VPN接口
        if (mode == ConnectionMode.VPN_TUN) {
            try {
                mInterface?.close();
                mInterface = null;
                
                VpnFileLogger.d(TAG, "VPN接口已关闭");
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e);
            }
        }
        
        // 停止前台服务
        stopForeground(true);
        
        // 停止服务
        stopSelf();
        
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止");
    }
    
    // 创建前台服务通知
    private fun createNotification(): android.app.Notification? {
        try {
            val channelName = instanceLocalizedStrings["notificationChannelName"] ?: "VPN服务";
            val channelDesc = instanceLocalizedStrings["notificationChannelDesc"] ?: "VPN连接状态通知";
            
            // 创建通知渠道
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    channelName,
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = channelDesc;
                    setShowBadge(false);
                    enableLights(false);
                    enableVibration(false);
                };
                val notificationManager = getSystemService(NotificationManager::class.java);
                notificationManager.createNotificationChannel(channel);
            }
            
            // 创建停止意图
            val stopIntent = Intent(ACTION_STOP_VPN);
            val stopPendingIntent = PendingIntent.getBroadcast(
                this, 0, stopIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            );
            
            // 创建返回应用意图
            val mainPendingIntent = try {
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName);
                if (launchIntent != null) {
                    PendingIntent.getActivity(
                        this, 0, launchIntent,
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        } else {
                            PendingIntent.FLAG_UPDATE_CURRENT
                        }
                    );
                } else {
                    val mainIntent = Intent(this, Class.forName("com.example.cfvpn.MainActivity"));
                    mainIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP;
                    PendingIntent.getActivity(
                        this, 0, mainIntent,
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        } else {
                            PendingIntent.FLAG_UPDATE_CURRENT
                        }
                    );
                }
            } catch (e: Exception) {
                
                VpnFileLogger.w(TAG, "创建返回应用Intent失败", e);
                null;
            };
            
            // 获取模式文本
            val modeText = when (mode) {
                ConnectionMode.VPN_TUN -> {
                    if (globalProxy) {
                        instanceLocalizedStrings["globalProxyMode"] ?: "全局代理模式";
                    } else {
                        instanceLocalizedStrings["smartProxyMode"] ?: "智能代理模式";
                    }
                }
                ConnectionMode.PROXY_ONLY -> {
                    instanceLocalizedStrings["proxyOnlyMode"] ?: "仅代理模式";
                }
            };
            
            // 构建通知标题
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN";
            val title = "$appName - $modeText";
            
            // 格式化通知内容
            val content = formatTrafficStatsForNotification(0L, 0L);
            
            // 创建通知
            val builder = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel, 
                    instanceLocalizedStrings["disconnectButtonName"] ?: "断开",
                    stopPendingIntent
                );
            
            mainPendingIntent?.let {
                builder.setContentIntent(it);
            };
            
            return builder.build();
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "创建通知失败", e);
            return try {
                NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                    .setContentTitle(instanceLocalizedStrings["appName"] ?: "CFVPN")
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .build();
            } catch (e2: Exception) {
                null;
            }
        }
    }
    
    // 获取应用图标资源ID
    private fun getAppIconResource(): Int {
        return try {
            packageManager.getApplicationInfo(packageName, 0).icon;
        } catch (e: Exception) {
            android.R.drawable.ic_dialog_info;
        }
    }
    
    // 格式化通知显示的流量统计
    private fun formatTrafficStatsForNotification(upload: Long, download: Long): String {
        val template = instanceLocalizedStrings["trafficStatsFormat"] ?: "流量: ↑%upload ↓%download";
        return template
            .replace("%upload", formatBytes(upload))
            .replace("%download", formatBytes(download));
    }
    
    // 更新通知显示内容
    private fun updateNotification() {
        try {
            val modeText = when (mode) {
                ConnectionMode.VPN_TUN -> {
                    if (globalProxy) {
                        instanceLocalizedStrings["globalProxyMode"] ?: "全局代理模式";
                    } else {
                        instanceLocalizedStrings["smartProxyMode"] ?: "智能代理模式";
                    }
                }
                ConnectionMode.PROXY_ONLY -> {
                    instanceLocalizedStrings["proxyOnlyMode"] ?: "仅代理模式";
                }
            };
            
            val appName = instanceLocalizedStrings["appName"] ?: "CFVPN";
            val title = "$appName - $modeText";
            val content = formatTrafficStatsForNotification(uploadBytes, downloadBytes);
            
            val stopIntent = Intent(ACTION_STOP_VPN);
            val stopPendingIntent = PendingIntent.getBroadcast(
                this, 0, stopIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            );
            
            val notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(content)
                .setSmallIcon(getAppIconResource())
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setShowWhen(false)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    instanceLocalizedStrings["disconnectButtonName"] ?: "断开",
                    stopPendingIntent
                )
                .build();
            
            val notificationManager = getSystemService(NotificationManager::class.java);
            notificationManager.notify(NOTIFICATION_ID, notification);
        } catch (e: Exception) {
            
            VpnFileLogger.w(TAG, "更新通知失败", e);
        }
    }
    
    // 处理V2Ray核心启动回调
    override fun startup(): Long {
        
        VpnFileLogger.d(TAG, "CoreCallbackHandler.startup() 被调用");
        
        try {
            
            VpnFileLogger.d(TAG, "V2Ray核心启动完成通知");
            return 0L;
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "startup处理异常", e);
            return -1L;
        }
    }
    
    // 处理V2Ray核心关闭回调
    override fun shutdown(): Long {
        
        VpnFileLogger.d(TAG, "CoreCallbackHandler.shutdown() 被调用");
        
        serviceScope.launch {
            try {
                stopV2Ray();
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "shutdown停止服务异常", e);
            }
        };
        
        return 0L;
    }
    
    // 处理V2Ray状态回调
    override fun onEmitStatus(level: Long, status: String?): Long {
        try {
            when (level.toInt()) {
                0 -> VpnFileLogger.d(TAG, "V2Ray: $status");
                1 -> VpnFileLogger.i(TAG, "V2Ray: $status");
                2 -> VpnFileLogger.w(TAG, "V2Ray: $status");
                3 -> VpnFileLogger.e(TAG, "V2Ray: $status");
                4 -> VpnFileLogger.e(TAG, "V2Ray Fatal: $status");
                else -> VpnFileLogger.d(TAG, "V2Ray[$level]: $status");
            }
            return 0L;
        } catch (e: Exception) {
            
            VpnFileLogger.e(TAG, "onEmitStatus异常", e);
            return -1L;
        }
    }
    
    // 格式化字节数为可读格式
    private fun formatBytes(bytes: Long): String {
        return when {
            bytes < 0 -> "0 B";
            bytes < 1024 -> "$bytes B";
            bytes < 1024 * 1024 -> String.format("%.2f KB", bytes / 1024.0);
            bytes < 1024 * 1024 * 1024 -> String.format("%.2f MB", bytes / (1024.0 * 1024));
            else -> String.format("%.2f GB", bytes / (1024.0 * 1024 * 1024));
        }
    }
    
    // 格式化时间间隔为可读格式
    private fun formatDuration(millis: Long): String {
        if (millis < 0) return "00:00:00";
        val seconds = (millis / 1000) % 60;
        val minutes = (millis / (1000 * 60)) % 60;
        val hours = millis / (1000 * 60 * 60);
        return String.format("%02d:%02d:%02d", hours, minutes, seconds);
    }
    
    // 处理服务销毁
    override fun onDestroy() {
        super.onDestroy();
        
        
        VpnFileLogger.d(TAG, "onDestroy开始");
        
        instanceRef?.clear();
        instanceRef = null;
        serviceScope.cancel();
        
        // 注销广播接收器
        try {
            unregisterReceiver(stopReceiver);
            
            VpnFileLogger.d(TAG, "广播接收器已注销");
        } catch (e: Exception) {
        }
        
        // 清理运行中的服务
        if (currentState != V2RayState.DISCONNECTED) {
            
            VpnFileLogger.d(TAG, "onDestroy时服务仍在运行,执行清理");
            currentState = V2RayState.DISCONNECTED;
            statsJob?.cancel();
            statsJob = null;
            if (mode == ConnectionMode.VPN_TUN) {
                stopTun2socks();
            }
            try {
                coreController?.stopLoop();
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "停止V2Ray核心异常", e);
            }
            try {
                mInterface?.close();
                mInterface = null;
            } catch (e: Exception) {
                
                VpnFileLogger.e(TAG, "关闭VPN接口异常", e);
            }
        }
        
        coreController = null;
        
        
        VpnFileLogger.d(TAG, "onDestroy完成,服务已销毁");
        
        // 刷新并关闭日志系统
        runBlocking {
            VpnFileLogger.flushAll();
        }
        VpnFileLogger.close();
    }
}