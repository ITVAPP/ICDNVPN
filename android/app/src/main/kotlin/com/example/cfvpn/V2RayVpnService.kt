package com.example.cfvpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import java.io.File
import java.io.FileDescriptor
import java.io.OutputStream

// 正确的导入
import go.Seq
import libv2ray.Libv2ray
import libv2ray.CoreController
import libv2ray.CoreCallbackHandler

/**
 * V2Ray VPN服务实现
 * 使用libv2ray.aar提供VPN功能，通过tun2socks转发数据包
 * 
 * 运行流程分析：
 * 1. onCreate -> 初始化Go运行时和V2Ray
 * 2. onStartCommand -> 接收启动意图，解析配置
 * 3. startV2Ray -> 启动V2Ray核心，建立VPN隧道，启动tun2socks进程
 * 4. 流量监控 -> 定期更新统计
 * 5. stopV2Ray -> 停止服务，清理资源
 */
class V2RayVpnService : VpnService(), CoreCallbackHandler {
    
    companion object {
        private const val TAG = "V2RayVpnService"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL_ID = "v2ray_vpn_channel"
        private const val ACTION_STOP_VPN = "com.example.cfvpn.STOP_VPN"
        
        // VPN配置常量
        private const val VPN_MTU = 1500
        // 修改为/30子网，支持tun2socks
        private const val PRIVATE_VLAN4_CLIENT = "26.26.26.1"    // VPN接口地址
        private const val PRIVATE_VLAN4_ROUTER = "26.26.26.2"    // tun2socks使用的地址
        private const val PRIVATE_VLAN6_CLIENT = "da26:2626::1"
        
        // V2Ray SOCKS5端口（从app_config.dart中的配置）
        private const val SOCKS_PORT = 7898
        
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
            VpnFileLogger.d(TAG, "准备启动VPN服务，全局代理: $globalProxy")
            
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
                VpnFileLogger.e(TAG, "启动服务失败", e)
            }
        }
        
        /**
         * 停止VPN服务
         */
        fun stopVpnService(context: Context) {
            VpnFileLogger.d(TAG, "准备停止VPN服务")
            
            try {
                // 先发送停止广播
                context.sendBroadcast(Intent(ACTION_STOP_VPN))
                // 再停止服务
                context.stopService(Intent(context, V2RayVpnService::class.java))
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "停止服务失败", e)
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
    
    // V2Ray核心控制器
    private var coreController: CoreController? = null
    
    // VPN接口文件描述符
    private var mInterface: ParcelFileDescriptor? = null
    
    // tun2socks进程 - 使用java.lang.Process
    private var tun2socksProcess: java.lang.Process? = null
    
    // 配置内容
    private var configContent: String = ""
    private var globalProxy: Boolean = false
    
    // 协程作用域 - 用于管理异步任务
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    // 流量统计数据 - 修正：分离总量和速度
    private var uploadBytes: Long = 0      // 上传总字节数
    private var downloadBytes: Long = 0    // 下载总字节数
    private var lastUploadTotal: Long = 0  // 上次的上传总量（用于计算速度）
    private var lastDownloadTotal: Long = 0 // 上次的下载总量（用于计算速度）
    private var uploadSpeed: Long = 0      // 当前上传速度
    private var downloadSpeed: Long = 0    // 当前下载速度
    private var lastQueryTime: Long = 0    // 上次查询时间
    private var startTime: Long = 0        // 连接开始时间
    
    // 统计任务
    private var statsJob: Job? = null
    
    // 广播接收器 - 接收停止命令
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
     * 关键步骤：初始化Go运行时和V2Ray
     */
    override fun onCreate() {
        super.onCreate()
        
        // 初始化文件日志系统（从配置读取是否启用，默认启用）
        val enableFileLog = true  // TODO: 从配置文件读取
        VpnFileLogger.init(applicationContext)
        
        VpnFileLogger.d(TAG, "VPN服务onCreate开始")
        
        // 保存实例引用
        instance = this
        
        // 步骤1：初始化Go运行时 - 必须在使用任何Go代码之前
        try {
            Seq.setContext(applicationContext)
            VpnFileLogger.d(TAG, "Go运行时初始化成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "Go运行时初始化失败", e)
            // Go运行时初始化失败，服务无法工作
            stopSelf()
            return
        }
        
        // 步骤2：注册广播接收器
        try {
            registerReceiver(stopReceiver, IntentFilter(ACTION_STOP_VPN))
            VpnFileLogger.d(TAG, "广播接收器注册成功")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "注册广播接收器失败", e)
        }
        
        // 步骤3：初始化V2Ray环境
        try {
            val envPath = filesDir.absolutePath
            Libv2ray.initCoreEnv(envPath, "")
            VpnFileLogger.d(TAG, "V2Ray环境初始化成功: $envPath")
            
            // 获取版本信息
            val version = Libv2ray.checkVersionX()
            VpnFileLogger.i(TAG, "V2Ray版本: $version")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "V2Ray环境初始化失败", e)
        }
        
        // 步骤4：复制资源文件
        copyAssetFiles()
        
        VpnFileLogger.d(TAG, "VPN服务onCreate完成")
    }
    
    /**
     * 服务启动命令
     * 验证：检查意图、配置、权限
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VpnFileLogger.d(TAG, "onStartCommand: action=${intent?.action}, flags=$flags, startId=$startId")
        
        // 验证1：检查意图
        if (intent == null || intent.action != "START_VPN") {
            VpnFileLogger.w(TAG, "无效的启动意图: ${intent?.action}")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 验证2：检查是否已在运行
        if (isRunning) {
            VpnFileLogger.w(TAG, "VPN服务已在运行，忽略重复启动")
            return START_STICKY
        }
        
        // 验证3：获取配置
        configContent = intent.getStringExtra("config") ?: ""
        globalProxy = intent.getBooleanExtra("globalProxy", false)
        
        if (configContent.isEmpty()) {
            VpnFileLogger.e(TAG, "配置为空，无法启动")
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 步骤1：启动前台服务
        try {
            startForeground(NOTIFICATION_ID, createNotification())
            VpnFileLogger.d(TAG, "前台服务已启动")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动前台服务失败", e)
            stopSelf()
            return START_NOT_STICKY
        }
        
        // 步骤2：异步启动V2Ray
        serviceScope.launch {
            try {
                startV2Ray()
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "启动V2Ray失败", e)
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
        VpnFileLogger.d(TAG, "开始复制资源文件")
        
        // 创建目标目录
        val assetDir = filesDir
        if (!assetDir.exists()) {
            if (!assetDir.mkdirs()) {
                VpnFileLogger.e(TAG, "创建资源目录失败: ${assetDir.absolutePath}")
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
                    VpnFileLogger.d(TAG, "文件已是最新，跳过: $fileName")
                }
            } catch (e: Exception) {
                VpnFileLogger.e(TAG, "处理文件失败: $fileName", e)
                // 继续处理其他文件
            }
        }
        
        VpnFileLogger.d(TAG, "资源文件复制完成")
    }
    
    /**
     * 检查文件是否需要更新
     * 策略：文件不存在或大小不同则更新
     */
    private fun shouldUpdateFile(assetName: String, targetFile: File): Boolean {
        if (!targetFile.exists()) {
            VpnFileLogger.d(TAG, "目标文件不存在: $assetName")
            return true
        }
        
        return try {
            val assetSize = assets.open(assetName).use { it.available() }
            val needUpdate = targetFile.length() != assetSize.toLong()
            if (needUpdate) {
                VpnFileLogger.d(TAG, "文件大小不匹配: $assetName (asset=$assetSize, target=${targetFile.length()})")
            }
            needUpdate
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "检查文件失败: $assetName", e)
            true // 出错时尝试更新
        }
    }
    
    /**
     * 复制单个资源文件
     * 错误处理：记录错误但不抛出异常
     */
    private fun copyAssetFile(assetName: String, targetFile: File) {
        try {
            VpnFileLogger.d(TAG, "正在复制文件: $assetName -> ${targetFile.absolutePath}")
            
            assets.open(assetName).use { input ->
                targetFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            
            VpnFileLogger.d(TAG, "文件复制成功: $assetName (${targetFile.length()} bytes)")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "复制文件失败: $assetName", e)
            // 不抛出异常，允许继续运行
        }
    }
    
    /**
     * 启动V2Ray核心
     * 关键流程：启动V2Ray核心 -> 建立VPN -> 启动tun2socks -> 传递文件描述符
     */
    private suspend fun startV2Ray() = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "开始启动V2Ray核心")
        
        try {
            // 步骤1：创建核心控制器并启动V2Ray核心（先启动SOCKS5服务）
            VpnFileLogger.d(TAG, "步骤1: 创建核心控制器")
            coreController = Libv2ray.newCoreController(this@V2RayVpnService)
            
            if (coreController == null) {
                throw Exception("创建CoreController失败")
            }
            
            // 步骤2：启动V2Ray核心
            VpnFileLogger.d(TAG, "步骤2: 启动V2Ray核心")
            coreController?.startLoop(configContent)
            
            // 步骤3：验证运行状态
            val isRunningNow = coreController?.isRunning ?: false
            if (!isRunningNow) {
                throw Exception("V2Ray核心未运行")
            }
            
            VpnFileLogger.i(TAG, "V2Ray核心启动成功，SOCKS5端口: $SOCKS_PORT")
            
            // 步骤4：建立VPN隧道
            VpnFileLogger.d(TAG, "步骤4: 建立VPN隧道")
            withContext(Dispatchers.Main) {
                establishVpn()
            }
            
            // 验证VPN隧道
            if (mInterface == null) {
                throw Exception("VPN隧道建立失败")
            }
            
            // 步骤5：启动tun2socks进程
            VpnFileLogger.d(TAG, "步骤5: 启动tun2socks进程")
            runTun2socks()
            
            // 步骤6：传递文件描述符给tun2socks
            VpnFileLogger.d(TAG, "步骤6: 传递文件描述符")
            val fdSuccess = sendFileDescriptor()
            if (!fdSuccess) {
                throw Exception("文件描述符传递失败，VPN无法工作")
            }
            
            // 步骤7：更新状态
            isRunning = true
            startTime = System.currentTimeMillis()
            
            VpnFileLogger.i(TAG, "V2Ray服务完全启动成功")
            
            // 步骤8：启动流量监控
            startTrafficMonitor()
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动V2Ray失败: ${e.message}", e)
            
            // 清理资源
            isRunning = false
            stopTun2socks()
            mInterface?.close()
            mInterface = null
            coreController = null
            
            // 重新抛出异常
            throw e
        }
    }
    
    /**
     * 启动tun2socks进程
     * 将TUN接口流量转发到V2Ray的SOCKS5端口
     */
    private suspend fun runTun2socks(): Unit = withContext(Dispatchers.IO) {
        VpnFileLogger.d(TAG, "开始启动tun2socks进程")
        
        try {
            // 获取libtun2socks.so的路径
            val libtun2socksPath = File(applicationInfo.nativeLibraryDir, "libtun2socks.so").absolutePath
            
            // 检查文件是否存在
            if (!File(libtun2socksPath).exists()) {
                throw Exception("libtun2socks.so不存在: $libtun2socksPath")
            }
            
            VpnFileLogger.d(TAG, "libtun2socks路径: $libtun2socksPath")
            
            // Unix域套接字文件路径（使用绝对路径）
            val sockPath = File(filesDir, "sock_path").absolutePath
            
            // 删除旧的套接字文件（如果存在）
            try {
                File(sockPath).delete()
            } catch (e: Exception) {
                // 忽略删除失败
            }
            
            // 构建命令行参数
            val cmd = arrayListOf(
                libtun2socksPath,
                "--netif-ipaddr", PRIVATE_VLAN4_ROUTER,        // tun2socks使用的IP地址
                "--netif-netmask", "255.255.255.252",          // /30子网掩码
                "--socks-server-addr", "127.0.0.1:$SOCKS_PORT", // V2Ray SOCKS5地址
                "--tunmtu", VPN_MTU.toString(),                // MTU大小
                "--sock-path", sockPath,                       // Unix域套接字路径（绝对路径）
                "--enable-udprelay",                            // 启用UDP转发
                "--loglevel", "error"                          // 日志级别
            )
            
            VpnFileLogger.d(TAG, "tun2socks命令: ${cmd.joinToString(" ")}")
            
            // 启动进程
            val processBuilder = ProcessBuilder(cmd).apply {
                redirectErrorStream(true)  // 将错误流重定向到标准输出
                directory(filesDir)        // 设置工作目录
            }
            
            val process = processBuilder.start()
            tun2socksProcess = process
            
            // 读取进程输出（用于调试）
            serviceScope.launch {
                try {
                    process.inputStream?.bufferedReader()?.use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            VpnFileLogger.d(TAG, "tun2socks: $line")
                        }
                    }
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "读取tun2socks输出失败", e)
                }
            }
            
            // 监控进程状态，支持自动重启
            serviceScope.launch {
                try {
                    val exitCode = process.waitFor()
                    VpnFileLogger.w(TAG, "tun2socks进程退出，退出码: $exitCode")
                    
                    // 如果服务仍在运行，自动重启tun2socks
                    if (isRunning) {
                        VpnFileLogger.d(TAG, "自动重启tun2socks进程")
                        delay(1000)
                        // 调用重启方法而不是递归调用
                        restartTun2socks()
                    }
                } catch (e: Exception) {
                    VpnFileLogger.e(TAG, "监控tun2socks进程失败", e)
                }
            }
            
            // 检查进程是否成功启动
            delay(100)
            if (!process.isAlive) {
                throw Exception("tun2socks进程启动后立即退出")
            }
            
            VpnFileLogger.d(TAG, "tun2socks进程已启动")
            
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "启动tun2socks失败", e)
            throw e
        }
    }
    
    /**
     * 重启tun2socks进程（避免递归类型推断）
     */
    private suspend fun restartTun2socks(): Unit = withContext(Dispatchers.IO) {
        try {
            runTun2socks()
            val success = sendFileDescriptor()
            if (!success) {
                VpnFileLogger.e(TAG, "重启后文件描述符传递失败，停止服务")
                stopV2Ray()
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "重启tun2socks失败", e)
            stopV2Ray()
        }
    }
    
    /**
     * 通过Unix域套接字传递TUN设备的文件描述符给tun2socks
     * 这是Android特有的机制，用于跨进程共享TUN设备
     */
    private suspend fun sendFileDescriptor(): Boolean {
        VpnFileLogger.d(TAG, "开始传递文件描述符给tun2socks")
        
        return withContext(Dispatchers.IO) {
            val sockPath = File(filesDir, "sock_path").absolutePath
            val tunFd = mInterface?.fileDescriptor
            
            if (tunFd == null) {
                VpnFileLogger.e(TAG, "TUN文件描述符为空")
                return@withContext false
            }
            
            var tries = 0
            val maxTries = 6
            
            while (tries < maxTries) {
                try {
                    // 递增延迟：0ms, 50ms, 100ms, 150ms, 200ms, 250ms
                    delay(50L * tries)
                    
                    VpnFileLogger.d(TAG, "尝试连接Unix域套接字 (第${tries + 1}次)")
                    
                    // 创建本地套接字并连接到tun2socks
                    val clientSocket = LocalSocket()
                    clientSocket.connect(LocalSocketAddress(sockPath, LocalSocketAddress.Namespace.FILESYSTEM))
                    
                    // 发送文件描述符
                    val outputStream = clientSocket.outputStream
                    clientSocket.setFileDescriptorsForSend(arrayOf(tunFd))
                    outputStream.write(32)  // 发送一个字节触发传输
                    outputStream.flush()
                    
                    // 清理
                    clientSocket.setFileDescriptorsForSend(null)
                    clientSocket.shutdownOutput()
                    clientSocket.close()
                    
                    VpnFileLogger.d(TAG, "文件描述符传递成功")
                    return@withContext true
                    
                } catch (e: Exception) {
                    tries++
                    if (tries >= maxTries) {
                        VpnFileLogger.e(TAG, "文件描述符传递失败，已达最大重试次数", e)
                        return@withContext false
                    } else {
                        VpnFileLogger.w(TAG, "文件描述符传递失败，将重试 (${tries}/$maxTries): ${e.message}")
                    }
                }
            }
            false
        }
    }
    
    /**
     * 停止tun2socks进程
     */
    private fun stopTun2socks() {
        VpnFileLogger.d(TAG, "停止tun2socks进程")
        
        try {
            val process = tun2socksProcess
            if (process != null) {
                process.destroy()
                tun2socksProcess = null
                VpnFileLogger.d(TAG, "tun2socks进程已停止")
            }
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止tun2socks进程失败", e)
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
            VpnFileLogger.d(TAG, "解析域名: $result")
            result
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "解析域名失败", e)
            ""
        }
    }
    
    /**
     * 建立VPN隧道
     * 关键配置：IP地址、DNS、路由规则
     * 修改为/30子网以支持tun2socks
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
        builder.setSession("CFVPN")
        builder.setMtu(VPN_MTU)
        
        // IPv4地址 - 使用/30子网
        builder.addAddress(PRIVATE_VLAN4_CLIENT, 30)
        VpnFileLogger.d(TAG, "添加IPv4地址: $PRIVATE_VLAN4_CLIENT/30")
        
        // IPv6地址（可选）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addAddress(PRIVATE_VLAN6_CLIENT, 126)
                VpnFileLogger.d(TAG, "添加IPv6地址: $PRIVATE_VLAN6_CLIENT/126")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加IPv6地址失败（可能不支持）", e)
            }
        }
        
        // DNS服务器配置
        val dnsServers = listOf("8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1")
        dnsServers.forEach { dns ->
            try {
                builder.addDnsServer(dns)
                VpnFileLogger.d(TAG, "添加DNS: $dns")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "添加DNS失败: $dns", e)
            }
        }
        
        // 路由规则配置
        if (globalProxy) {
            VpnFileLogger.d(TAG, "配置全局代理路由")
            
            // IPv4全局路由
            builder.addRoute("0.0.0.0", 0)
            
            // IPv6全局路由（可选）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                try {
                    builder.addRoute("::", 0)
                    VpnFileLogger.d(TAG, "添加IPv6全局路由")
                } catch (e: Exception) {
                    VpnFileLogger.w(TAG, "添加IPv6路由失败", e)
                }
            }
        } else {
            VpnFileLogger.d(TAG, "配置智能分流路由")
            // 仅代理国外流量 - 目前设置为全局，后续可以根据需要添加分流规则
            builder.addRoute("0.0.0.0", 0)
        }
        
        // 应用绕过规则（避免VPN循环）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                builder.addDisallowedApplication(packageName)
                VpnFileLogger.d(TAG, "设置绕过应用: $packageName")
            } catch (e: Exception) {
                VpnFileLogger.w(TAG, "设置绕过应用失败", e)
            }
        }
        
        // 建立VPN接口
        mInterface = builder.establish()
        
        if (mInterface == null) {
            VpnFileLogger.e(TAG, "VPN接口建立失败（可能没有权限）")
        } else {
            VpnFileLogger.d(TAG, "VPN隧道建立成功，FD: ${mInterface?.fd}")
        }
    }
    
    /**
     * 停止V2Ray服务
     * 清理顺序：停止tun2socks -> 停止核心 -> 关闭接口 -> 清理状态
     */
    private fun stopV2Ray() {
        VpnFileLogger.d(TAG, "开始停止V2Ray服务")
        
        // 更新状态
        isRunning = false
        
        // 停止流量监控
        statsJob?.cancel()
        statsJob = null
        VpnFileLogger.d(TAG, "流量监控已停止")
        
        // 停止tun2socks进程
        stopTun2socks()
        
        // 停止V2Ray核心
        try {
            coreController?.stopLoop()
            VpnFileLogger.d(TAG, "V2Ray核心已停止")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "停止V2Ray核心异常", e)
        }
        
        // 关闭VPN接口
        try {
            mInterface?.close()
            mInterface = null
            VpnFileLogger.d(TAG, "VPN接口已关闭")
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "关闭VPN接口异常", e)
        }
        
        // 停止前台服务
        stopForeground(true)
        
        // 停止服务自身
        stopSelf()
        
        VpnFileLogger.i(TAG, "V2Ray服务已完全停止")
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
        VpnFileLogger.d(TAG, "启动流量监控")
        
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
                    VpnFileLogger.w(TAG, "更新流量统计异常", e)
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
            val controller = coreController ?: return
            
            // 查询流量（尝试不同的参数格式）
            var upload = controller.queryStats("", "uplink")
            var download = controller.queryStats("", "downlink")
            
            // 如果返回0，尝试其他格式
            if (upload == 0L && download == 0L) {
                upload = controller.queryStats("proxy", "uplink")
                download = controller.queryStats("proxy", "downlink")
            }
            
            // 更新总量
            uploadBytes = upload
            downloadBytes = download
            
            // 计算速度
            val now = System.currentTimeMillis()
            if (lastQueryTime > 0 && now > lastQueryTime) {
                val timeDiff = (now - lastQueryTime) / 1000.0
                if (timeDiff > 0) {
                    val uploadDiff = uploadBytes - lastUploadTotal
                    val downloadDiff = downloadBytes - lastDownloadTotal
                    
                    if (uploadDiff >= 0 && downloadDiff >= 0) {
                        // 正确计算速度
                        uploadSpeed = (uploadDiff / timeDiff).toLong()
                        downloadSpeed = (downloadDiff / timeDiff).toLong()
                    } else {
                        // 如果差值为负（可能是重置了），速度归零
                        uploadSpeed = 0
                        downloadSpeed = 0
                    }
                }
            }
            
            // 保存本次查询的值，用于下次计算速度
            lastQueryTime = now
            lastUploadTotal = uploadBytes
            lastDownloadTotal = downloadBytes
            
            // 更新通知（限制频率）
            if (now - startTime > 10000) {
                updateNotification()
            }
            
            VpnFileLogger.d(TAG, "流量统计 - 总计: ↑${formatBytes(uploadBytes)} ↓${formatBytes(downloadBytes)}, " +
                      "速度: ↑${formatBytes(uploadSpeed)}/s ↓${formatBytes(downloadSpeed)}/s")
            
        } catch (e: Exception) {
            VpnFileLogger.w(TAG, "查询流量统计失败", e)
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
            VpnFileLogger.w(TAG, "更新通知失败", e)
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
            "uploadSpeed" to uploadSpeed,      // 返回真正的速度值
            "downloadSpeed" to downloadSpeed   // 返回真正的速度值
        )
    }
    
    // ===== CoreCallbackHandler 接口实现 =====
    
    /**
     * V2Ray核心启动回调
     * 注意：这是在V2Ray核心启动后的通知，不是请求建立VPN
     * @return 0表示成功，-1表示失败
     */
    override fun startup(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.startup() 被调用")
        
        // 这里只是记录状态，VPN已经在startV2Ray中建立
        return if (mInterface != null) {
            VpnFileLogger.d(TAG, "startup: VPN隧道已就绪")
            // 如果需要，这里可以保护V2Ray的socket
            val fd = mInterface?.fd
            if (fd != null && fd > 0) {
                protect(fd)
            }
            0L
        } else {
            VpnFileLogger.e(TAG, "startup: VPN隧道未就绪")
            -1L
        }
    }
    
    /**
     * V2Ray核心关闭回调
     * @return 0表示成功
     */
    override fun shutdown(): Long {
        VpnFileLogger.d(TAG, "CoreCallbackHandler.shutdown() 被调用")
        
        // 异步停止服务，避免阻塞Native线程
        serviceScope.launch {
            stopV2Ray()
        }
        
        return 0L
    }
    
    /**
     * V2Ray状态回调
     * @param level 日志级别 (0=Debug, 1=Info, 2=Warning, 3=Error, 4=Fatal)
     * @param status 状态信息
     * @return 0成功
     */
    override fun onEmitStatus(level: Long, status: String?): Long {
        try {
            // 根据级别记录日志到文件
            when (level.toInt()) {
                0 -> VpnFileLogger.d(TAG, "V2Ray: $status")
                1 -> VpnFileLogger.i(TAG, "V2Ray: $status")
                2 -> VpnFileLogger.i(TAG, "V2Ray: $status")
                3 -> VpnFileLogger.w(TAG, "V2Ray: $status")
                4 -> VpnFileLogger.e(TAG, "V2Ray: $status")
                else -> VpnFileLogger.d(TAG, "V2Ray[$level]: $status")
            }
            return 0L
        } catch (e: Exception) {
            VpnFileLogger.e(TAG, "onEmitStatus异常", e)
            return -1L
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
        
        VpnFileLogger.d(TAG, "onDestroy开始")
        
        // 清除实例引用
        instance = null
        
        // 取消所有协程
        serviceScope.cancel()
        
        // 注销广播接收器
        try {
            unregisterReceiver(stopReceiver)
            VpnFileLogger.d(TAG, "广播接收器已注销")
        } catch (e: Exception) {
            // 可能已经注销
        }
        
        // 如果还在运行，停止V2Ray
        if (isRunning) {
            stopV2Ray()
        }
        
        // 停止tun2socks进程
        stopTun2socks()
        
        // 清理CoreController
        coreController = null
        
        VpnFileLogger.d(TAG, "onDestroy完成，服务已销毁")
        
        // 刷新并关闭日志系统
        runBlocking {
            VpnFileLogger.flushAll()
        }
        VpnFileLogger.close()
    }
}
