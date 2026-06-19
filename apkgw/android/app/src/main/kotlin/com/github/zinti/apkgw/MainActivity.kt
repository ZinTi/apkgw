package com.github.zinti.apkgw

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface


class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.github.zinti.apkgw/service"
    private val EVENT_CHANNEL = "com.github.zinti.apkgw/events"
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---------- MethodChannel: 处理Dart调用 ----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val port = call.argument<Int>("port") ?: 8888
                        val intent = Intent(this, ProxyForegroundService::class.java)
                        intent.action = ProxyForegroundService.ACTION_START
                        intent.putExtra("PORT", port)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success("Service started")
                    }
                    "stopService" -> {
                        val intent = Intent(this, ProxyForegroundService::class.java)
                        intent.action = ProxyForegroundService.ACTION_STOP
                        startService(intent) // 通过Service自身处理stop
                        result.success("Service stopped")
                    }
                    "getHotspotIp" -> {
                        result.success(getHotspotIp())
                    }
                    else -> result.notImplemented()
                }
            }

        // ---------- EventChannel: 预留事件流（如需Native推数据） ----------
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    /**
     * 获取Wi-Fi热点（SoftAP）的IPv4地址。
     * 通常热点网卡名为 wlan0，若无法获取则返回默认 192.168.43.1
     */
    private fun getHotspotIp(): String {
        return try {
            val networkInterface = NetworkInterface.getByName("wlan0")
            networkInterface?.inetAddresses?.asSequence()
                ?.find { it.isSiteLocalAddress && !it.isLoopbackAddress && it.hostAddress?.contains(":") == false }
                ?.hostAddress ?: "192.168.43.1"
        } catch (e: Exception) {
            e.printStackTrace()
            "192.168.43.1"
        }
    }
}
