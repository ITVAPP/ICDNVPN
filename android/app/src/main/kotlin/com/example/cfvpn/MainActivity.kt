package com.example.cfvpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

class MainActivity: FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
        private const val CHANNEL = "flutter_v2ray"
        private const val EVENT_CHANNEL = "flutter_v2ray/status"
        private const val VPN_REQUEST_CODE = 1001
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var pendingResult: MethodChannel.Result? = null
    
    private val mainScope = MainScope()
    private var statusReceiver: BroadcastReceiver? = null
    
    // 当前模式
    private var isVPNMode = false
    private var currentConfig: String? = null
    private var currentRemark: String? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler { call, result ->
            Log.d(TAG, "Method called: ${call.method}")
            
            when (call.method) {
                "requestPermission" -> {
                    // 修正：兼容Dart代码，不依赖proxy_only参数
                    // 默认请求VPN权限（因为Dart代码在需要时才调用）
                    Log.d(TAG, "Requesting VPN permission")
                    requestVPNPermission(result)
                }
                
                "initializeV2Ray" -> {
                    // 初始化在Service中完成
                    Log.d(TAG, "V2Ray initialization called")
                    result.success(true)
                }
                
                "startV2Ray" -> {
                    val args = call.arguments as? Map<*, *>
                    currentConfig = args?.get("config") as? String
                    currentRemark = args?.get("remark") as? String ?: "Proxy Server"
                    
                    // 修正：正确解析proxy_only，默认值改为false（VPN模式）以匹配Dart代码
                    val proxyOnly = args?.get("proxy_only") as? Boolean ?: false
                    
                    // 解析应用过滤和子网绕过
                    val blockedApps = args?.get("blocked_apps") as? ArrayList<String>
                    val bypassSubnets = args?.get("bypass_subnets") as? ArrayList<String>
                    
                    Log.d(TAG, "Starting V2Ray - proxy_only: $proxyOnly, remark: $currentRemark")
                    
                    if (currentConfig != null) {
                        isVPNMode = !proxyOnly
                        
                        if (proxyOnly) {
                            // 代理模式
                            Log.d(TAG, "Starting in PROXY mode")
                            startProxyService(currentConfig!!, currentRemark!!)
                        } else {
                            // VPN模式
                            Log.d(TAG, "Starting in VPN mode")
                            
                            // 检查VPN权限
                            val intent = VpnService.prepare(this)
                            if (intent != null) {
                                // 需要请求权限
                                Log.w(TAG, "VPN permission not granted, requesting...")
                                pendingResult = result
                                startActivityForResult(intent, VPN_REQUEST_CODE)
                                return@setMethodCallHandler
                            }
                            
                            // 已有权限，直接启动
                            startVPNService(currentConfig!!, currentRemark!!, blockedApps, bypassSubnets)
                        }
                        result.success(null)
                    } else {
                        result.error("INVALID_CONFIG", "Config is required", null)
                    }
                }
                
                "stopV2Ray" -> {
                    Log.d(TAG, "Stopping V2Ray - isVPNMode: $isVPNMode")
                    if (isVPNMode) {
                        stopVPNService()
                    } else {
                        stopProxyService()
                    }
                    result.success(null)
                }
                
                "getV2rayStatus" -> {
                    val state = if (isVPNMode) {
                        when(V2rayVPNService.connectionState) {
                            "CONNECTED" -> "V2RAY_CONNECTED"
                            "CONNECTING" -> "V2RAY_CONNECTING"
                            "ERROR" -> "V2RAY_ERROR"
                            else -> "V2RAY_DISCONNECTED"
                        }
                    } else {
                        when(V2rayService.connectionState) {
                            "CONNECTED" -> "V2RAY_CONNECTED"
                            "CONNECTING" -> "V2RAY_CONNECTING"
                            "ERROR" -> "V2RAY_ERROR"
                            else -> "V2RAY_DISCONNECTED"
                        }
                    }
                    Log.d(TAG, "Returning status: $state")
                    result.success(state)
                }
                
                "getServerDelay" -> {
                    mainScope.launch {
                        try {
                            val config = call.argument<String>("config")
                            val url = call.argument<String>("url") ?: "https://www.google.com"
                            
                            val delay = if (config != null) {
                                withContext(Dispatchers.IO) {
                                    try {
                                        libv2ray.Libv2ray.measureOutboundDelay(config, url)
                                    } catch (e: Exception) {
                                        Log.e(TAG, "Delay test failed", e)
                                        -1L
                                    }
                                }
                            } else {
                                -1L
                            }
                            
                            withContext(Dispatchers.Main) {
                                result.success(delay)
                            }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) {
                                result.success(-1L)
                            }
                        }
                    }
                }
                
                "getConnectedServerDelay" -> {
                    // 暂不实现
                    result.success(-1L)
                }
                
                "getCoreVersion" -> {
                    try {
                        val version = libv2ray.Libv2ray.checkVersionX()
                        result.success(version)
                    } catch (e: Exception) {
                        result.success("Unknown")
                    }
                }
                
                else -> {
                    Log.w(TAG, "Unknown method: ${call.method}")
                    result.notImplemented()
                }
            }
        }
        
        // Event Channel
        eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                Log.d(TAG, "EventChannel onListen")
                eventSink = events
                registerStatusReceiver()
                sendCurrentStatus()
            }

            override fun onCancel(arguments: Any?) {
                Log.d(TAG, "EventChannel onCancel")
                eventSink = null
                unregisterStatusReceiver()
            }
        })
    }
    
    private fun requestVPNPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            // 已有权限
            result.success(true)
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == VPN_REQUEST_CODE) {
            val granted = (resultCode == Activity.RESULT_OK)
            Log.d(TAG, "VPN permission result: $granted")
            
            pendingResult?.let {
                it.success(granted)
                pendingResult = null
            }
            
            // 如果权限被授予且有待启动的配置，继续启动VPN
            if (granted && currentConfig != null && isVPNMode) {
                startVPNService(currentConfig!!, currentRemark!!, null, null)
            }
        }
    }
    
    private fun startProxyService(config: String, remark: String) {
        val intent = Intent(this, V2rayService::class.java).apply {
            action = V2rayService.ACTION_START
            putExtra("config", config)
            putExtra("remark", remark)
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
    
    private fun stopProxyService() {
        val intent = Intent(this, V2rayService::class.java).apply {
            action = V2rayService.ACTION_STOP
        }
        startService(intent)
    }
    
    private fun startVPNService(
        config: String,
        remark: String,
        blockedApps: ArrayList<String>?,
        bypassSubnets: ArrayList<String>?
    ) {
        val intent = Intent(this, V2rayVPNService::class.java).apply {
            action = V2rayVPNService.ACTION_START
            putExtra("config", config)
            putExtra("remark", remark)
            putStringArrayListExtra("blocked_apps", blockedApps)
            putStringArrayListExtra("bypass_subnets", bypassSubnets)
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
    
    private fun stopVPNService() {
        val intent = Intent(this, V2rayVPNService::class.java).apply {
            action = V2rayVPNService.ACTION_STOP
        }
        startService(intent)
    }
    
    private fun registerStatusReceiver() {
        if (statusReceiver != null) return
        
        statusReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                // 支持两个服务的不同广播
                val action = intent?.action
                if (action == V2rayService.BROADCAST_STATUS || action == V2rayVPNService.BROADCAST_VPN_STATUS) {
                    
                    // 根据当前模式解析数据
                    val duration: String
                    val uploadSpeed: String
                    val downloadSpeed: String
                    val uploadTotal: String
                    val downloadTotal: String
                    val state: String
                    
                    if (isVPNMode) {
                        // VPN模式数据
                        duration = intent.getStringExtra("DURATION") ?: "00:00:00"
                        uploadSpeed = intent.getLongExtra("UPLOAD_SPEED", 0).toString()
                        downloadSpeed = intent.getLongExtra("DOWNLOAD_SPEED", 0).toString()
                        uploadTotal = intent.getLongExtra("UPLOAD_TRAFFIC", 0).toString()
                        downloadTotal = intent.getLongExtra("DOWNLOAD_TRAFFIC", 0).toString()
                        
                        val stateEnum = intent.getSerializableExtra("STATE") as? V2rayVPNService.AppConfigs.V2RAY_STATES
                        state = when(stateEnum) {
                            V2rayVPNService.AppConfigs.V2RAY_STATES.V2RAY_CONNECTED -> "CONNECTED"
                            V2rayVPNService.AppConfigs.V2RAY_STATES.V2RAY_CONNECTING -> "CONNECTING"
                            else -> "DISCONNECTED"
                        }
                    } else {
                        // 代理模式数据
                        duration = intent.getStringExtra("duration") ?: "00:00:00"
                        uploadSpeed = intent.getStringExtra("uploadSpeed") ?: "0"
                        downloadSpeed = intent.getStringExtra("downloadSpeed") ?: "0"
                        uploadTotal = intent.getStringExtra("uploadTotal") ?: "0"
                        downloadTotal = intent.getStringExtra("downloadTotal") ?: "0"
                        state = intent.getStringExtra("state") ?: "DISCONNECTED"
                    }
                    
                    // 构建数据列表（与Dart期望的格式一致）
                    val statusList = ArrayList<Any>()
                    statusList.add(duration)              // 0: duration (String)
                    statusList.add(uploadSpeed)            // 1: uploadSpeed (String -> Dart会解析)
                    statusList.add(downloadSpeed)          // 2: downloadSpeed (String -> Dart会解析)
                    statusList.add(uploadTotal)            // 3: upload (String -> Dart会解析)
                    statusList.add(downloadTotal)          // 4: download (String -> Dart会解析)
                    statusList.add(state)                  // 5: state (String)
                    
                    eventSink?.success(statusList)
                    
                    Log.v(TAG, "Status sent: $state, Mode: ${if (isVPNMode) "VPN" else "Proxy"}")
                }
            }
        }
        
        // 注册两个广播
        val filter = IntentFilter().apply {
            addAction(V2rayService.BROADCAST_STATUS)
            addAction(V2rayVPNService.BROADCAST_VPN_STATUS)
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusReceiver, filter)
        }
        
        // 请求当前状态
        val intent = if (isVPNMode) {
            Intent(this, V2rayVPNService::class.java).apply {
                action = V2rayVPNService.ACTION_QUERY_STATUS
            }
        } else {
            Intent(this, V2rayService::class.java).apply {
                action = V2rayService.ACTION_QUERY_STATUS
            }
        }
        startService(intent)
    }
    
    private fun unregisterStatusReceiver() {
        statusReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to unregister receiver", e)
            }
            statusReceiver = null
        }
    }
    
    private fun sendCurrentStatus() {
        // 发送初始状态（与Dart期望的格式一致）
        val statusList = ArrayList<Any>()
        statusList.add("00:00:00")  // duration
        statusList.add("0")          // uploadSpeed
        statusList.add("0")          // downloadSpeed
        statusList.add("0")          // upload
        statusList.add("0")          // download
        
        val state = if (isVPNMode) {
            when(V2rayVPNService.connectionState) {
                "CONNECTED" -> "CONNECTED"
                "CONNECTING" -> "CONNECTING"
                "ERROR" -> "ERROR"
                else -> "DISCONNECTED"
            }
        } else {
            when(V2rayService.connectionState) {
                "CONNECTED" -> "CONNECTED"
                "CONNECTING" -> "CONNECTING"
                "ERROR" -> "ERROR"
                else -> "DISCONNECTED"
            }
        }
        
        statusList.add(state)
        eventSink?.success(statusList)
    }

    override fun onDestroy() {
        Log.d(TAG, "MainActivity onDestroy")
        unregisterStatusReceiver()
        mainScope.cancel()
        super.onDestroy()
    }
}