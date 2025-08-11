package com.example.cfvpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import kotlinx.coroutines.*

/**
 * 主Activity - 处理Flutter与原生的通信
 * 主要负责VPN权限请求和服务控制
 */
class MainActivity: FlutterActivity() {
    
    companion object {
        private const val CHANNEL = "com.example.cfvpn/v2ray"
        private const val VPN_REQUEST_CODE = 100
        private const val TAG = "MainActivity"
    }
    
    private lateinit var channel: MethodChannel
    private val mainScope = MainScope() // 使用MainScope确保正确的生命周期管理
    
    // 保存待处理的VPN启动请求
    private data class PendingVpnRequest(
        val config: String,
        val globalProxy: Boolean,
        val result: MethodChannel.Result
    )
    private var pendingRequest: PendingVpnRequest? = null
    
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // 设置方法通道，处理Flutter调用
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    // 启动VPN
                    val config = call.argument<String>("config")
                    val globalProxy = call.argument<Boolean>("globalProxy") ?: false
                    
                    if (config != null) {
                        startVpn(config, globalProxy, result)
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
                    // 获取流量统计
                    val stats = V2RayVpnService.getTrafficStats()
                    result.success(stats)
                }
                
                "checkPermission" -> {
                    // 检查VPN权限
                    val hasPermission = checkVpnPermission()
                    result.success(hasPermission)
                }
                
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
    
    /**
     * 启动VPN
     */
    private fun startVpn(config: String, globalProxy: Boolean, result: MethodChannel.Result) {
        mainScope.launch {
            try {
                // 检查是否已在运行
                if (V2RayVpnService.isServiceRunning()) {
                    Log.w(TAG, "VPN已在运行，先停止再启动")
                    V2RayVpnService.stopVpnService(this@MainActivity)
                    delay(500) // 等待服务停止
                }
                
                // 检查VPN权限
                val intent = VpnService.prepare(this@MainActivity)
                if (intent != null) {
                    // 需要请求VPN权限
                    Log.d(TAG, "需要请求VPN权限")
                    
                    // 保存待处理的请求
                    pendingRequest = PendingVpnRequest(config, globalProxy, result)
                    
                    // 启动权限请求
                    try {
                        startActivityForResult(intent, VPN_REQUEST_CODE)
                    } catch (e: Exception) {
                        Log.e(TAG, "无法请求VPN权限", e)
                        pendingRequest = null
                        result.error("PERMISSION_REQUEST_FAILED", "无法请求VPN权限: ${e.message}", null)
                    }
                } else {
                    // 已有权限，直接启动VPN服务
                    Log.d(TAG, "已有VPN权限，直接启动服务")
                    V2RayVpnService.startVpnService(this@MainActivity, config, globalProxy)
                    
                    // 等待服务启动
                    delay(1000)
                    
                    // 检查服务状态
                    val isRunning = V2RayVpnService.isServiceRunning()
                    if (isRunning) {
                        result.success(true)
                        // 通知Flutter端连接成功
                        channel.invokeMethod("onVpnConnected", null)
                    } else {
                        result.error("START_FAILED", "VPN服务启动失败", null)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "启动VPN失败", e)
                result.error("START_FAILED", e.message, null)
            }
        }
    }
    
    /**
     * 停止VPN
     */
    private fun stopVpn() {
        Log.d(TAG, "停止VPN服务")
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
            Log.e(TAG, "检查VPN权限失败", e)
            false
        }
    }
    
    /**
     * 处理权限请求结果
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == VPN_REQUEST_CODE) {
            val request = pendingRequest
            pendingRequest = null // 清理待处理请求
            
            if (request == null) {
                Log.w(TAG, "没有待处理的VPN请求")
                return
            }
            
            if (resultCode == Activity.RESULT_OK) {
                // VPN权限获取成功
                Log.d(TAG, "VPN权限获取成功")
                
                // 通知Flutter端权限已授予
                channel.invokeMethod("onVpnPermissionGranted", null)
                
                // 启动VPN服务
                mainScope.launch {
                    try {
                        V2RayVpnService.startVpnService(
                            this@MainActivity, 
                            request.config, 
                            request.globalProxy
                        )
                        
                        // 等待服务启动
                        delay(1000)
                        
                        // 检查服务状态
                        val isRunning = V2RayVpnService.isServiceRunning()
                        if (isRunning) {
                            request.result.success(true)
                            // 通知Flutter端连接成功
                            channel.invokeMethod("onVpnConnected", null)
                        } else {
                            request.result.error("START_FAILED", "VPN服务启动失败", null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "启动VPN服务失败", e)
                        request.result.error("START_FAILED", e.message, null)
                    }
                }
            } else {
                // VPN权限被拒绝
                Log.d(TAG, "VPN权限被拒绝")
                
                // 通知Flutter端权限被拒绝
                channel.invokeMethod("onVpnPermissionDenied", null)
                
                // 返回失败结果
                request.result.error("PERMISSION_DENIED", "用户拒绝了VPN权限", null)
            }
        }
    }
    
    override fun onDestroy() {
        super.onDestroy()
        // 取消所有协程
        mainScope.cancel()
    }
}
